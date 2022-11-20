#!perl
use 5.020;
use feature 'signatures';
no warnings 'experimental::signatures';

use File::Temp 'tempdir';
use Cwd;
use File::Basename;
use HTTP::Tiny;
use File::Spec;
use Config '%Config';

=head1 NAME

    blead-installtest.pl - build a Perl and test that modules install

=head1 DESCRIPTION

This program automates parts of the Perl release managers guide (RMG) as
outlined at L<https://metacpan.org/pod/distribution/perl/Porting/release_managers_guide.pod#Install-the-Inline-module-with-CPAN-and-test-it>

It assumes a built and ready-to-install Perl and then installs that in a
temporary directory and tests that L<DBD::SQLite> (and L<DBI>) and L<Inline::C>
onstall and that Inline::C can run some example code.

It could maybe also be given a premade tarball to test.

It also tests that microperl can be compiled.

=cut

our $libdir;
our $perldir;
our $builddir;
our $perltoolstr;
BEGIN {
    $libdir = tempdir( CLEANUP => 1 );
    #$libdir = tempdir( );
    $perldir = dirname($^X);
    ($] * 1_000_000) =~/^(\d+)(\d{3})(\d{3})$/
        and $perltoolstr = sprintf "%d.%d.%d", $1, $2, $3;
    warn "Using tools from '$perltoolstr'";
};

delete @ENV{qw( PERL5LIB PERL_MB_OPT PERL_LOCAL_LIB_ROOT PERL_MM_OPT )};

# Remove all other Perl paths from $ENV{PATH}
my $envsep = $^O eq 'MSWin32' ? ';' : ':';
$ENV{PATH} = join $envsep, grep { !/perl/i } File::Spec->path;

use Test::More;

plan tests => 3;

=head1 SYNOPSIS

    # Configure, test and install bleadperl
    export  PERL_TEST_HARNESS_ASAP=1; export HARNESS_OPTIONS=j8 ; export MAKEFLAGS=-j12
    sh ./Configure -des -Dprefix='/tmp/perl' -Dusedevel ; make test_prep -j 12 ; HARNESS_OPTIONS=j12 make test_harness && make install

    # Run the RMG installation tests
    /tmp/perl/bin/perl5.33.5 ../blead-installtest.pl

Alternatively, run this script using the included

    run-blead-installtest.sh

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

# Maybe this should be a link to the most recent version?!
my $ll_content = HTTP::Tiny->new()->get('http://cpan.metacpan.org/authors/id/H/HA/HAARG/local-lib-2.000029.tar.gz');
my $ll = "$libdir/ll.tar.gz";
open my $fh, '>:raw', $ll
    or die "'$ll': $!";
print $fh $ll_content->{content};
#use Data::Dumper;
#say Dumper $ll_content;
close $fh;

sub run( @cmd ) {
    note "Running [@cmd]";
    return system( @cmd )
}

sub run_or_die( @cmd ) {
    run(@cmd) == 0 or die $?;
}

chdir $libdir or die "'$libdir': $!";
run("tar", "xf", "ll.tar.gz");
chdir "$libdir/local-lib-2.000029/" or die "'$libdir': $!";
# Install local::lib into $libdir ( a temp directory )
run_or_die( $^X, "Makefile.PL", "--bootstrap=$libdir" );
run_or_die( $Config{make}, "install" );

unshift @INC, "$libdir/local-lib-2.000029/lib";

# Set up our private local::lib in the temporary directory
require local::lib;
local::lib->import( $libdir );
local::lib->setup_env_hash_for( $libdir );
push @INC, local::lib->lib_paths_for($libdir);
$ENV{PERL5LIB} = join ":", local::lib->lib_paths_for($libdir);

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

ok system( $cpanm, '-l', $libdir, '--notest', 'DBD::SQLite' ) == 0, "DBD::SQLite installs (with DBI, via cpanm)";
ok system( $cpanm, '-l', $libdir, '--notest', 'Sereal' ) == 0, "Sereal (via cpanm)";

# I don't know where on my system this still gets found, so we force-reinstall it locally
run( $cpanm, '-l', $libdir, "--notest", '--reinstall', "Parse::RecDescent" );
ok run( $cpanm, '-l', $libdir, "--notest", "Parse::RecDescent", "Inline::C" ) == 0, "Inline::C installs"
    or diag "Failed: $! / $?";

chdir($libdir);
# use Cwd;

# Inline::C
ok run( "$perldir/perl$perltoolstr", "-lwe", q{use Inline C => q[int f() { return 42;}]; print f}) == 0,
    "Inline::C works";
#    42

# Check that PERL5LIB= ./perl -Ilib -V looks as expected
# Summary of my perl5 (revision 5 version 33 subversion 5) configuration

# When built from a git directory, it should be
# This is perl 5, version X, subversion Y (v5.X.Y (v5.X.Z-NNN-gdeadbeef))
chdir( $builddir );
#ok(system("$Config{make} -f Makefile.micro") == 0, "We can create microperl");

done_testing;

# So File::Temp can clean up
chdir "/" or die "chdir '/': $!";


