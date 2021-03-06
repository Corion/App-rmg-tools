#!perl
use 5.020;
use File::Temp 'tempdir';
use File::Basename;
use HTTP::Tiny;
use Config '%Config';

=head1 NAME

    blead-installtest.pl - build a Perl and test that modules install

=head1 DESCRIPTION

This program automates parts of the Perl release managers guide (RMG) as
outlined at L<https://metacpan.org/pod/distribution/perl/Porting/release_managers_guide.pod#Install-the-Inline-module-with-CPAN-and-test-it>

It assumes a built and ready-to-install Perl and then installs that in a
temporary directory and tests that L<DBD::SQLite> (and L<DBI>) and L<Inline::C>
install and that Inline::C can run some example code.

It could maybe also be given a premade tarball to test.

=cut

our $libdir;
our $perldir;
our $builddir;
our $perltoolstr;
BEGIN {
    $libdir = tempdir();
    $perldir = dirname($^X);
    #$perldir = tempdir();
    ($] * 1_000_000) =~/^(\d+)(\d{3})(\d{3})$/
        and $perltoolstr = sprintf "%d.%d.%d", $1, $2, $3;
};

delete @ENV{qw( PERL5LIB PERL_MB_OPT PERL_LOCAL_LIB_ROOT PERL_MM_OPT )};

use Test::More;

plan tests => 3;

=head1 SYNOPSIS

    # Configure, test and install bleadperl
    export  PERL_TEST_HARNESS_ASAP=1; export HARNESS_OPTIONS=j8 ; export MAKEFLAGS=-j12
    sh ./Configure -des -Dprefix='/tmp/perl' -Dusedevel ; make test_prep -j 12 ; HARNESS_OPTIONS=j12 make test_harness install

    # Run the RMG installation tests
    /tmp/perl/bin/perl5.33.5 ../blead-installtest.pl

Run this script with the freshly installed bleadperl to test installing

    local::lib
    DBI and DBD::SQLite
    Inline::C

All module installations will be made into a temporary directory to keep
your main bleadperl installation clean.

=cut

# Build/test a tarball before all that and relaunch ourselves with the fresh
# Perl instead?

diag "Running with $^X";

my $ll_content = HTTP::Tiny->new()->get('http://cpan.metacpan.org/authors/id/H/HA/HAARG/local-lib-2.000024.tar.gz');
my $ll = "$libdir/ll.tar.gz";
open my $fh, '>:raw', $ll
    or die "'$ll': $!";
print $fh $ll_content->{content};
#use Data::Dumper;
#say Dumper $ll_content;
close $fh;

chdir $libdir or die "'$libdir': $!";
system("tar", "xf", "ll.tar.gz");
chdir "$libdir/local-lib-2.000024/" or die "'$libdir': $!";
system( $^X, "Makefile.PL", "--bootstrap", $libdir );
system( $Config{make}, "install" );

unshift @INC, "$libdir/local-lib-2.000024/lib";

# Set up our private local::lib in the temporary directory
require local::lib;
local::lib->import( $libdir );
local::lib->setup_env_hash_for( $libdir );

sub run {
    note "@_";
    system( @_ )
}

my $cpanm_content = HTTP::Tiny->new()->get('http://cpanmin.us');
my $cpanm = "$libdir/bin/cpanm";
open my $fh, '>:raw', $cpanm
    or die "'$cpanm': $!";
print $fh $cpanm_content->{content};
close $fh;

chmod 0775, $cpanm;
my $cpan = "$perldir/cpan$perltoolstr";
#ok system( $cpan, 'App::cpm' ) == 0, "App::cpm installs (via cpan)";

#my $cpm = "$libdir/bin/cpm";
#ok -x $cpm, "cpm binary exists";

ok system( $cpanm, 'DBD::SQLite' ) == 0, "DBD::SQLite installs (with DBI, via cpanm)";

ok run( $cpanm, install => "Inline::C", '--global' ) == 0, "Inline::C installs"
    or diag "Failed: $! / $?";
# Inline::C
ok run( "$perldir/perl$perltoolstr", "-Ilib", "-lwe", q{use Inline C => q[int f() { return 42;}]; print f}) == 0,
    "Inline::C works";
#    42

# Check that PERL5LIB= ./perl -Ilib -V looks as expected
# Summary of my perl5 (revision 5 version 33 subversion 5) configuration

# When built from a git directory, it should be
# This is perl 5, version X, subversion Y (v5.X.Y (v5.X.Z-NNN-gdeadbeef))

done_testing;
