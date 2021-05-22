#!perl
use 5.020;
use strict;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use POSIX 'strftime';
use charnames ':full'; # for CHECK MARK
use Data::Dumper;
use Getopt::Long;
use IPC::Run3;
use Text::Table;

GetOptions(
    'build-dir|d=s' => \my $build_dir,
    'version=s' => \my $our_version,
    'prev-version=s' => \my $previous_version,
    'date=s' => \my $our_rundate,
    'git-remote=s' => \my $git_remote,
);

my $today = strftime '%Y-%m-%d', localtime;
$our_rundate //= $today;

$build_dir //= '.';
$git_remote //= 'github';

sub file_exists( $fn, $dir = $build_dir ) {
    if( $fn =~ m!^/! ) {
        # absolute filename, sorry Windows users
    } else {
        -f "$build_dir/$fn"
    }
}

sub trimmed(@lines) {
    s!\s+$!! for @lines;
    return @lines;
}

sub lines($file) {
    open my $fh, '<:raw:utf8', $file
        or die "Couldn't read '$file': $!";
    return trimmed(<$fh>);
}

sub run(@command) {
    run3(\@command, \undef, \my @stdout, \my @stderr)
        or die "Command [@command] failed: $! / $?";
    return trimmed(@stdout);
}

sub git(@command) {
    return run(git => @command)
}

sub commit_message_exists($message) {
    # this is pretty ugly - I think we want a more structured approach to parsing
    # a git commit. Some other day
    # Also, we only want to list the commits since the previous release tag
    my @list =
        map { my @items=split /#/, $_;
            +{
                ref     => $items[0],
                date    => $items[1],
                author  => $items[2],
                subject => $items[3],
            };
        }
        git('log', '--pretty=format:%C(auto)%h#%as#%an#%s', '--grep', $message);
    return @list
}

sub parse_release_schedule($dir=$build_dir,$file="Porting/release_schedule.pod") {
    # This currently silently skips versions with an undeterminate release
    # date like
    #   2021-0?-??  5.34.1          ?
    return
        map { /^\s+(20\d\d-[01]\d-[0123]\d)\s+(\d+\.\d+\.\d+)\s+(\s|\N{CHECK MARK})\s+(.*)$/
                  ? { date => $1, version => $2, name => $4, released => $3 eq "\N{CHECK MARK}" }
                  : ()
            }
        lines("$build_dir/Porting/release_schedule.pod");
}

sub git_branch {
    git(branch => '--show-current')
}

sub http_exists( $url ) {
    return 0
}

my @tag = git('describe','--abbrev=0');
my $current_tag = $tag[0];
my $our_tag;
my $tag_date = git('tag', '-l', '--format=%(refname:short) %(taggerdate:short)', $current_tag);

# See if we already bumped the version:
if( ! $our_version ) {
    if( $today eq $tag_date ) {
        # This will fail horribly on the date we actually try this?!
        $our_tag = $current_tag;
    } else {
        # Tag not created today, bump it by one
        $our_tag = $current_tag =~ s/(\d+)$/$1+1/re;
    };
    $our_version //= $our_tag =~ s/^v//r;
} else {
    $previous_version = $our_version =~ s/(\d+)$/$1-1/re;
    $our_tag = "v$our_version";
}
say "Previous release is $previous_version, our version will be $our_version";

# Do a sanity check agsint Porting/release_schedule.pod
(my $planned_release) = grep { $_->{version} eq $our_version }
                      parse_release_schedule($build_dir);
if( ! $planned_release ) {
    my $username = $ENV{LOGNAME} || $ENV{USER} || getpwuid($<);
    $planned_release = {
        name => $username,

    };
    say "Couldn't find a release plan for $our_version, guessing as $planned_release->{name}";
} else {
    say "Your name in Porting/release_schedule.pod is $planned_release->{name}";
};

my $our_tarball_xz = "perl-$our_version.tar.xz";

my @boards = (
    {
        name => 'CPAN modules newer than blead',
        list => sub {
            my @items = run("./perl", "Porting/core-cpan-diff", "-x", "-a");
            my %items;
            my $curr;
            my @res;
            for (@items) {
                if( /^\s*$/ ) {
                    push @res, $curr if $curr and $curr->{name};
                    $curr = {};
                } elsif( /^([\w:]+):$/ ) {
                    $curr->{name} = $1;
                } elsif( /^\s+Perl: (.*?)$/ ) {
                    $curr->{perl} = $1;
                } elsif( /^\s+CPAN: (.*?)$/ ) {
                    $curr->{cpan} = $1;
                } else {
                    warn "Unknown line: [$_]";
                }
            };
            push @res, $curr if $curr and $curr->{name};

            return ['Module','Perl','CPAN'], [map { [$_->{name}, $_->{perl}, $_->{cpan}] } @res]
        },
    },
);

my @steps = (
    {
        name => 'Release branch created',
        test => sub {
            git_branch() eq $our_tag
        },
    },
    {
        name => 'Configure was run',
        test => sub {
                file_exists( 'config.sh', $build_dir )
            and file_exists( 'Policy.sh', $build_dir )
        },
    },
    {
        name => 'make was run',
        test => sub {
                file_exists( 'perl', $build_dir )
        },
    },
    {
        name => 'make test was run',
        test => sub {
                file_exists( 't/rantests', $build_dir )
        },
    },
    {
        name => 'Module::CoreList was updated',
        test => sub {
                commit_message_exists( "Update Module::CoreList for $our_tag" )
        },
    },
    {
        name => 'perldelta was edited',
        test => sub {
                commit_message_exists( "perldelta for $our_tag" )
        },
    },
    {
        name => 'perldelta is clean',
        test => sub {
                ! grep { /\bXXX\b/ } lines('pod/perldelta.pod');
        },
    },
    {
        name => "tag for $our_tag is created",
        test => sub {
                git( tag => '-l', $our_tag );
        },
    },
    {
        name => "release tarball exists",
        test => sub {
            # Well, this should also be newer than all other
            # files here
                file_exists( "../$our_tarball_xz" );
        },
    },
    {
        name => "local installation of $our_version exists at /tmp/perl-$our_version",
        test => sub {
            # Well, this should also be newer than all other
            # files here
            my $target = "/tmp/perl-$our_version/bin/perl$our_version";
                file_exists( $target )
            and -x $target;
        },
    },
    {
        name => "release tarball published for testing",
        test => sub {
            # Do we want to make an HTTP call every time?!
            # Or only do that if the release tarball exists, and then
            # check that they are identical!
                http_exists("https://datenzoo.de/$our_tarball_xz")
        },
    },
    {
        name => "release tarball published on CPAN",
        test => sub {
            # Do we want to make an HTTP call every time?!
            # Or only do that if the release tarball exists, and then
            # check that they are identical!
                http_exists("https://www.cpan.org/authors/id/C/CO/CORION/$our_tarball_xz")
        },
    },
    {
        name => 'Release schedule ticked and committed',
        test => sub {
            my $line =
                $planned_release->{released}
                and commit_message_exists( "release_.*$our_tag" )

        },
    },
    {
        name => 'Release branch merged back to blead',
        test => sub {
            my $branch = git_branch();
                $branch eq 'blead'
            and git( tag => '-l', $our_tag );
        },
    },
    {
        name => 'Release tag pushed upstream',
        test => sub {
            my $branch = git_branch();
                $branch eq 'blead'
            and git( tag => '-l', $our_tag )
            and git( 'ls-remote', '--tags', $git_remote );
        },
    },
);

binmode STDOUT, ':encoding(UTF-8)';

for my $board (@boards) {
    my ($header,$items) = $board->{list}->();

    say $board->{name};
    if( @$items ) {
        my $table = Text::Table->new( @$header );
        $table->load( @$items );
        say $table;
    } else {
        say "- none -";
    };
}

binmode STDOUT, ':encoding(UTF-8)';
for my $step (@steps) {
    my $done = $step->{test}->();
    my $v_done = $done ? "[\N{CHECK MARK}]" : "[ ]";
    say "$v_done $step->{name}";
}
