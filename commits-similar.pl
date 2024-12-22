#!perl
use 5.020;
use feature 'signatures';
no warnings 'experimental::signatures';

use IPC::Run3;
use Text::Table;
use List::Util 'max';
use Data::Dumper;

use Getopt::Long;

GetOptions(
    'r|repo=s' => \my $repo_dir,
);
$repo_dir //= '.';

our @reference_commits => (
    {
        commit => '84a028ef5433b2dbbb52bbecfb1c944232f1b8b4',
                description => 'Version bump',
                type => 'BLEAD-POINT',
                title_re => 'Bump the perl version in various places for 5\.\d+\.\d+',
        },
        {
                commit => 'c9ea04646e91d0599f09fd69d0fca9598611739c',
                description => 'Version bump',
                type => 'MAINT-POINT',
        },
);

sub trimmed(@lines) {
    s!\s+$!! for @lines;
    return @lines;
}

sub run(@command) {
    run3(\@command, \undef, \my @stdout, \my @stderr, {
        return_if_system_error => 1,
        binmode_stdout => ':utf8',
    }) == -1 and warn "Command [@command] failed: $! / $?";
    return trimmed(@stdout);
}

sub git(@command) {
    return run(git => '-C' => $repo_dir, @command)
}

sub changed_files_by_commit( $this_commit ) {
        return git("diff-tree" => '--name-only', '--no-commit-id', '-r', $this_commit)
}

# Check that two commits touch the same files, with fairly identical changes
sub commit_file_diff($this_commit, $other_commit) {
        my @l = changed_files_by_commit($this_commit);
        my @r = changed_files_by_commit($other_commit);
        my %l; @l{ @l } = (1) x @l;
        my %r; @r{ @r } = (1) x @r;
        delete @l{@r};
        delete @r{@l};

        return {
                scalar keys %l ? (left  => [sort keys %l]) : (),
                scalar keys %r ? (right => [sort keys %r]) : (),
        }
}

# Check that two commits touch the same files, with fairly identical changes
sub commit_files_unlike($this_commit, $other_commit) {
    my $d = commit_file_diff($this_commit, $other_commit);
    return keys %$d ? $d : ();
}

sub commit_file_diff_vis( $title1, $title2, $diff ) {
    my $table = Text::Table->new($title1,$title2);
    $diff->{left} //= [];
    $diff->{right} //= [];
    my $rowcount = max scalar $diff->{left}->@*, scalar $diff->{right}->@*;
    my @rows = map {
        [$diff->{left}->[$_] // '',$diff->{right}->[$_]//'']
    } 0..$rowcount -1;
    $table->load(@rows);
    return "$table";
}

sub raw_commit( $commit ) {
    my @commit = git('--no-pager', log => '-U0', '--patch', '-n', 1, '--no-decorate', $commit);
    # Strip off the commit message since I don't know how to make `git log` do it
    while( $commit[0] !~ /^index/ ) {
            shift @commit;
    }
    return @commit
}

# This shouldn't be _unlike but just "commit_diff" or something
sub commit_unlike( $this, $that, $unifier_cb, $l, $r ) {
   my @left  = raw_commit( $this );
   my @right = raw_commit( $that );
   my @cmp_left  = map { $unifier_cb->($_, $l) } @left;
   my @cmp_right = map { $unifier_cb->($_, $r) } @right;

   my @diff;

    my $lines = max( scalar @left, scalar @right );
    for( 0..$lines-1 ) {
        my $l = $cmp_left[ $_ ];
        my $r = $cmp_right[ $_ ];
        if( $l ne $r ) {
            say "old:$l\nnew:$r";
            push @diff, [$left[$_], $right[$_]];
        }
    }

    return @diff;
}

=head1 Future API

  commit_like($h1, $h2, { same_files => 1 } )
  <-> commit_touches_only()

  commit_touches($h1, { files => [...] )
  <-> commit_files_unlike()

  commit_touches_only($h1, { files => [...] )
  <-> commit_files_unlike()

=cut

my $d;
#$d = commit_files_unlike('4ab96809c99e944e70c21779641e4b1c9a00df41','4ab96809c99e944e70c21779641e4b1c9a00df41');
#say commit_file_diff_vis( 'old', 'new', $d );
#$d = commit_files_unlike('1ef54df4bdf39e1d2ef626673002bbc7886b7bb3','4ab96809c99e944e70c21779641e4b1c9a00df41');
#say commit_file_diff_vis( 'old', 'new', $d );
#$d = commit_files_unlike('1ef54df4bdf39e1d2ef626673002bbc7886b7bb3','f2582f5b18658f945a763f2edc110cdc7c5220e7');
#say commit_file_diff_vis( 'old', 'new', $d );
$d = commit_files_unlike('1ef54df4bdf39e1d2ef626673002bbc7886b7bb3','1b50c3488f6aa548e5063f22d145d9ae6ee1ba40');
say commit_file_diff_vis( 'old', 'new', $d );

my $ref_v  = [[ '5.37.4' => 'old' ], => [ '5.37.5' => 'next' ]];
my $this_v = [[ '5.41.4' => 'old' ], => [ '5.41.5' => 'next' ]];

# This is highly Perl 5 specific - a template approach might be more generic
sub make_repl_version( $v ) {
    my ($version, $moniker) = $v->@*;
    my ($major, $minor, $sub) = split /\./, $version;
    my $decimal = sprintf '%i.%03d%03d', $major, $minor, $sub;

    my @res = (
        { perl_version    => [qr/\bperl\Q$version\E\b/  => "perl{maj-$moniker}.{min-$moniker}.{sub-$moniker}"] },
        { perl_version    => [qr/\bperl-\Q$version\E\b/ => "perl-{maj-$moniker}.{min-$moniker}.{sub-$moniker}"] },
        { perl_version    => [qr/\bperl-\Q$major^.$minor^.$sub\E\b/ => "perl-{maj-$moniker}^.{min-$moniker}^.{sub-$moniker}"] },
        { full_version    => [qr/\b\Q$version\E\b/      => "{maj-$moniker}.{min-$moniker}.{sub-$moniker}"] },
        { decimal_version => [qr/\b\Q$decimal\E\b/      => "{maj-$moniker}.{min_sub-$moniker}"] },
        { api_version     => [qr/\b$minor\b/            => "{min-$moniker}"] },
        { api_subversion  => [qr/\b$sub\b/              => "{sub-$moniker}"] },
    );

    return @res;
}

sub make_repl( $versions ) {
    return [
        map { [ make_repl_version( $_ ) ] } $versions->@*
    ]
}

sub fudge_line( $line, $ref ) {
    for my $repl ($ref->@*) {
        for my $k (sort keys $repl->%*) {
            $line =~ s!$repl->{$k}->[0]!$repl->{$k}->[1]!g;
        }
    }
    return $line
}

sub fudge_version_number($line, $ref) {

    if( $line =~ /^---/ ) {
        $line = '---';

    } elsif( $line =~ /^\+\+\+/ ) {
        $line = '+++';

    } elsif( $line =~ /^\@\@/ ) {
        $line = '@@';

    } elsif( $line =~ /^index / ) {
        $line = 'index';


    } elsif( $line =~ /^-/ ) {
        $line = fudge_line( $line, $ref->[0] );

    } elsif( $line =~ /^\+/ ) {
        $line = fudge_line( $line, $ref->[1] );

    }
    return $line
};

#my @diff = commit_unlike( '1ef54df4bdf39e1d2ef626673002bbc7886b7bb3','4ab96809c99e944e70c21779641e4b1c9a00df41', \&fudge_version_number );
#my $repl_ref = make_repl( $ref_v );
#my $repl_this = make_repl( $this_v );

#my @diff = commit_unlike( '1ef54df4bdf39e1d2ef626673002bbc7886b7bb3','0f4efa6f1c7cddb31d9c8c24d1af539cd12776e7', \&fudge_version_number, $repl_ref, $repl_this );
#if( @diff ) {
#    use Data::Dumper;
#    warn Dumper \@diff;
#}

sub per_file_diff( $lines ) {
    my $files = {};
    my $fn;
    for ($lines->@*) {
        if( /^\+\+\+ (.+)/ ) {
            $fn = $1;
        } elsif( /^--- (.+)/ ) {
            # ignore
        } elsif( /^diff (.+)/ ) {
            # ignore
        } elsif( /^index (.+)/ ) {
            # ignore
        } elsif( /^\@\@ (.+)/ ) {
            # ignore
            # a new chunk in this file starts, re-align the diff?!
        } else {
            push $files->{ $fn }->@*, $_;
        }
    }
    return $files;
}

sub extract_prefix( $l, $r ) {
    my $map = $l ^ $r;
    $map =~ /^(\0*)/;
    return substr( $l, 0, length( $1 ));
}

# We assume a single change per line, which makes sense given our data
sub line_template( $line1, $line2, $name='XXX' ) {

    if( $line1 eq $line2 ) {
        return [ $line1, {} ]
    }

    my $prefix = extract_prefix( $line1, $line2 );
    my $suffix = reverse extract_prefix( scalar reverse($line1), scalar reverse($line2));

    my $template = $prefix . "{$name}" . $suffix;

    my ($pre, $suf) = (length($prefix),length($suffix));

    my $values = [
        substr( $line1, $pre, length($line1)-$pre-$suf),
        substr( $line2, $pre, length($line2)-$pre-$suf),
    ];

    return [$template, $values];
}

sub gen_template( $diff1, $diff2 ) {
    # Rearrange sequences of + / - side-by-side
    my $hunk_length = 1;
    while( substr( $diff1->[$hunk_length],0,1 ) eq '-' ) {
        $hunk_length++;
    }

    my $i = 2;
    return [
        [line_template( substr($diff1->[$i],1), substr($diff2->[$i],1),'xxx' )],
        [line_template( substr($diff1->[$i],1), substr($diff1->[$i+$hunk_length],1),'yyy' )],
    ]
}

# Generate a template from two (or more) commits, line by line
sub template_from_commits( $orig, @commits ) {
    my $left  = per_file_diff( [raw_commit( $orig )]);
    my $right = per_file_diff( [raw_commit( $commits[0] )]);

    my $fn = "b/win32/Makefile";
    my $fn = "b/Cross/config.sh-arm-linux";
    my $r = gen_template( $left->{$fn}, $right->{$fn});

    return { $fn => $r };
}

say Dumper template_from_commits( '1ef54df4bdf39e1d2ef626673002bbc7886b7bb3','0f4efa6f1c7cddb31d9c8c24d1af539cd12776e7' );