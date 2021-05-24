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
use JSON::PP;

GetOptions(
    'build-dir|d=s' => \my $build_dir,
    'version=s' => \my $our_version,
    'prev-version=s' => \my $previous_version,
    'date=s' => \my $our_rundate,
    'git-remote=s' => \my $git_remote,
    'cpan-user=s' => \my $cpan_user,
    'git-author=s' => \my $git_author,
    'formst=s' => \my $output_format,
);

=head1 SYNOPSIS

  watch -n 10 /usr/bin/perl ../App-rmg-tools/rmg-progress-dashboard.pl --version 5.35.1

=cut

my $today = strftime '%Y-%m-%d', localtime;
$our_rundate //= $today;

$build_dir //= '.';
$git_remote //= 'github';
$cpan_user //= 'CORION';
$git_author //= 'corion@corion.net';
$output_format //= 'text';

my $cpan_author_url = join "/", substr($cpan_user,0,1), substr($cpan_user,0,2), $cpan_user;

sub file_exists( $fn, $dir = $build_dir ) {
    if( $fn =~ m!^/! ) {
        # absolute filename, sorry Windows users
    } else {
        -f "$build_dir/$fn"
    }
}

sub file_newer_than( $fn, $reference ) {
    if( ! ref $reference ) {
        $reference = [$reference]
    };
    if( ! ref $fn ) {
        $fn = [$fn]
    };
    # Yay quadratic behaviour
    map {
        my $f = $_;
        grep { -M $f >= -M $_ } @$reference
    } @$fn
}

sub trimmed(@lines) {
    s!\s+$!! for @lines;
    return @lines;
}

sub lines($file) {
    if( open my $fh, '<:raw:utf8', $file) {
        return trimmed(<$fh>);
    }
    return ()
}

sub run(@command) {
    run3(\@command, \undef, \my @stdout, \my @stderr, {
        return_if_system_error => 1,
        binmode_stdout => ':utf8',
    }) == -1 and warn "Command [@command] failed: $! / $?";
    return trimmed(@stdout);
}

sub exitcode_zero(@command) {
    run(@command);
    return $? == 0
}

sub git(@command) {
    return run(git => @command)
}

sub commit_message_exists($message, %options) {
    # this is pretty ugly - I think we want a more structured approach to parsing
    # a git commit. Some other day
    # Also, we only want to list the commits since the previous release tag


    my @opts;
    if( my $since = $options{ since } ) {
        push @opts, join '..', $since, 'HEAD';
    };

    if( my $author = $options{ author }) {
        push @opts, "--author=$author";
    }

    my @list =
        map { my @items=split /#/, $_;
            +{
                ref     => $items[0],
                date    => $items[1],
                author  => $items[2],
                subject => $items[3],
            };
        }
        git('log', @opts, '--pretty=format:%C(auto)%h#%as#%an#%s', '--grep', $message);
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
    [git(branch => '--show-current')]->[0]
}

sub uncommited_changes(@files) {
    git(status => '--porcelain=v2', '--', @files)
}

sub pod_section( $filename, $section ) {
    my @lines = lines($filename);

    my @section =
        grep { /^=head1\s+$section/.../^=/ } @lines;

    # Trim the section
    if( @section ) {
        pop @section if $section[-1] =~ /^=/;
        shift @section; # remove the hading
        pop @section
            while $section[-1] =~ /^\s*$/;
        shift @section
            while $section[0] =~ /^\s*$/;
    };

    @section = map { $_ =~ s!^=\w+\s+!!; $_ } @section;
    return join "\n", @section;
}

sub http_exists( $url ) {
    return 0
}

my @tag = git('describe','--abbrev=0');
my $current_tag = $tag[0];
my $our_tag;
my $tag_date = git('tag', '-l', '--format=%(refname:short) %(taggerdate:short)', $current_tag);
my $our_version_num;
my $previous_tag;

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

    $previous_version //= $our_version =~ s/(\d+)$/$1-1/re;
} else {
    $previous_version //= $our_version =~ s/(\d+)$/$1-1/re;
    $our_tag = "v$our_version";
}
$our_version =~ /(\d+)\.(\d+)\.(\d+)/
    or die "Weirdo version number '$our_version'";
$our_version_num = sprintf "%d.%03d%03d", $1,$2,$3;
my $next_version =  sprintf "%d.%d.%d", $1,$2,$3+1;
$previous_tag = "v$previous_version";

my $release_branch = "release-$our_version";

my @info;
push @info, "Previous release is $previous_version, our version will be $our_version";

# Do a sanity check agsint Porting/release_schedule.pod
(my $planned_release) = grep { $_->{version} eq $our_version }
                      parse_release_schedule($build_dir);
if( ! $planned_release ) {
    my $username = $ENV{LOGNAME} || $ENV{USER} || getpwuid($<);
    $planned_release = {
        name => $username,

    };
    push @info, "Couldn't find a release plan for $our_version, guessing as $planned_release->{name}";
} else {
    push @info, "Your name in Porting/release_schedule.pod is $planned_release->{name}";
};

my $our_tarball_xz = "perl-$our_version.tar.xz";

my @boards = (
    {
        name => 'CPAN modules newer than blead',
        reference => 'dual life CPAN module synchronisation',
        list => sub {
            my @items = run("./perl", "-Ilib", "Porting/core-cpan-diff", "-x", "-a");
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
        reference => 'create a release branch',
        test => sub( $self ) {
            my $branch = git_branch();
            $branch ne $release_branch
                and return "Create branch $release_branch"
        },
    },
    {
        name => 'Configure was run',
        reference => 'build a clean perl',
        files => [qw[config.sh Policy.sh Makefile]],
        action => sub( $self ) {
            run('sh ./Configure -Dusedevel -des');
        },
        test => sub( $self ) {
            for my $file (@{ $self->{files}}) {
                if( !file_exists( $file, $build_dir )) {
                    return "Run ./Configure -Dusedevel -des"
                }
            };
            if( -f "$build_dir/perl" ) {
                # should we check that the files are older than ./perl?
            };
            ()
        },
    },
    {
        name => "Perl $our_version was built",
        files => ["perl"],
        test => sub($self) {
            # This will fail on Windows ...
            if( !file_exists( 'perl', $build_dir )) {
                return "Run make";
            };

            if( my @newer = file_newer_than( "./perl", ["config.sh", "Policy.sh" ])) {
                return "Rebuild ./perl, @newer is newer"
            };

            my $v = [run("$build_dir/perl", "-I$build_dir/lib", '-wE', 'say $]')]->[0];
            if( $v != $our_version_num) {
                return "Wrong Perl version was built ($v, expected $our_version)";
            };
        },
    },
    {
        name => 'make test was run',
        test => sub {
                if( ! file_exists( 't/rantests', $build_dir )) {
                    return "Run make test";
                };
                if( ! file_newer_than('t/rantests', 'perl')) {
                    return "Run make test after rebuild";
                };
        },
    },
    {
        name => 'Module::CoreList was updated',
        reference => 'update Module::CoreList',
        test => sub {
                if( ! commit_message_exists( "Update Module::CoreList for .*$our_version",
                    since => $previous_tag,
                    author => $git_author,
                )) {
                    return "Update Module::CoreList, commit the changes"
                }
        },
    },
    {
        name => "perldelta was finalized for $our_version",
        files => ["pod/perldelta.pod"],
        test => sub( $self ) {
            # We want/need ./perl as a prerequisite
                my $new = join "\n", run("./perl", "-Ilib", "Porting/acknowledgements.pl", "$previous_tag..HEAD");
                $new =~ s!\s+$!!;
                my $old = pod_section('pod/perldelta.pod', 'Acknowledgements');

                if( $new ne $old ) {
                    return "Update the acknowledgements in pod/perldelta.pod";
                };

                if( ! commit_message_exists( "update perldelta for .*$our_version",
                    since => $previous_tag,
                    author => $git_author,
                )) {
                    return "Commit the changes";
                };
        },
    },
    {
        name => 'perldelta is clean',
        files => ["pod/perldelta.pod"],
        test => sub( $self ) {
                (my $bad) = grep { /\bXXX\b|^\s*\[/ } lines('pod/perldelta.pod');
                if ($bad) {
                    return "Fix '$bad'"
                };
        },
    },
    {
        name => "release was added to perlhist.pod",
        files => ["pod/perlhist.pod"],
        test => sub( $self ) {
                # Perlhist.pod has yet another date format, instead of yyyy-mm-dd
                # We ignore that
                my $version = $our_tag =~ s/^v//r;
                (my $this) = grep { /\Q$version\E/ } lines( 'pod/perlhist.pod' );

                if( ! $this ) {
                    return "version $version not added";
                };

                if( ! commit_message_exists( "add new release to perlhist",
                    since => $previous_tag,
                    author => $git_author,
                )) {
                    return "Commit changes to 'pod/perlhist.pod'";
                };
        },
    },
    {
        action => sub( $self ) {
            run('./perl', "-Ilib", "Porting/makemeta");
        },
        name => "META files are up to date",
        files => ["META.json","META.yml"],
        test => sub( $self ) {
                # Check that the META.* files are up to date
                my $ok = exitcode_zero('./perl', '-Ilib', 'Porting/makemeta', '-n');
                if( ! $ok ) {
                    return "run ./perl -Ilib Porting/makemeta";

                } elsif( my @files = uncommited_changes( @{ $self->{files}})) {
                    return "Commit the changes to @files";

                }
                ()
        },
    },
    {
        name => "tag for $our_tag is created",
        test => sub {
                if( ! git( tag => '-l', $our_tag )) {
                    return "Create the release tag $our_tag"
                };
        },
    },
    {
        name => "release tarball exists",
        files => ["$build_dir/../$our_tarball_xz"],
        test => sub {
            # Well, this should also be newer than all other
            # files here
                if( ! file_exists( "../$our_tarball_xz" )) {
                    return "Build the release tarball $our_tarball_xz"
                };

                if( my @newer = file_newer_than( "../$our_tarball_xz", "./perl" )) {
                    return "Rebuild ../$our_tarball_xz, @newer is newer"
                }
                ()
        },
    },
    {
        name => "local installation of $our_version exists at /tmp/perl-$our_version",
        test => sub {
            # Well, this should also be newer than all other
            # files here
            my $target = "/tmp/perl-$our_version/bin/perl$our_version";
            if( !file_exists( $target )) {
                return "Locallly install $our_version"
            };

            if( my @newer = file_newer_than( $target, "./perl" )) {
                    return "Retest local installation, @newer is newer"
            };

            ()
        },
    },
    {
        name => "release tarball published for testing",
        files => ["$build_dir/../$our_tarball_xz"],
        test => sub {
            # Do we want to make an HTTP call every time?!
            # Or only do that if the release tarball exists, and then
            # check that they are identical!
                if( my @newer = file_newer_than( "../$our_tarball_xz", "./perl" )) {
                    return "Rebuild ../$our_tarball_xz, @newer is newer"
                }
                if(! http_exists("https://datenzoo.de/$our_tarball_xz")) {
                    return "Upload the tarball for testing"
                };
                ()
        },
    },
    {
        name => "release tarball published on CPAN",
        test => sub {
            # Do we want to make an HTTP call every time?!
            # Or only do that if the release tarball exists, and then
            # check that they are identical!
                if(! http_exists("https://www.cpan.org/authors/id/$cpan_author_url/$our_tarball_xz")) {
                    return "Upload the tarball to CPAN"
                };
        },
    },
    {
        name => 'Release schedule ticked and committed',
        test => sub {
            if( ! $planned_release->{released} ) {
                return "Tick the release mark";
            };
            if( ! commit_message_exists( "release_.*$our_tag",
                    since => $previous_tag,
                    author => $git_author,
                )) {
                return "Commit the change";
            };
        },
    },
    {
        name => 'Release branch merged back to blead',
        test => sub {
            my $branch = git_branch();
            if( $branch ne 'blead') {
                return "Switch back to blead";
            }
            my @diff = git( log => $release_branch..'blead' );
            if( @diff ) {
                return "Merge $release_branch into blead";
            };
            ()
        },
    },
    {
        name => 'Release tag pushed upstream',
        test => sub {
            my $branch = git_branch();
            if( $branch ne 'blead' ) {
                return "Switch back to blead";
            };
            if( ! git( tag => '-l', $our_tag )) {
                return "Tag '$our_tag' was not found in git?!"
            };
            if( ! git( 'ls-remote', '--tags', $git_remote )) {
                return "Push the release tag upstream";
            };
            ()
        },
    },
    {
        name => 'Version number bumped for next dev release',
        type => 'BLEAD-POINT',
        test => sub {
            my $branch = git_branch();
            if( $branch ne 'blead' ) {
                return "Switch back to blead";
            };

            (my $version) = map {
                /^api_versionstring='(.*?)'$/
            } lines('config.sh');
            if( $version ne $next_version) {
                return "Found $version, bump versions to $next_version"
            };
        },
    },
);

# Collect the dashboard(s)
my @rendered_boards;
for my $board (@boards) {
    my ($header,$items) = $board->{list}->();

    push @rendered_boards, {
        board => $board,
        header => $header,
        content => $items,
    };
}

# A list of files that need to be newer (or same) than the previous, in sequence
my @up_to_date_files;
my @items;
for my $step (@steps) {
    my $action = $step->{test}->($step);
    my $name = $step->{name};
    my $v_done = ! $action ? "[\N{CHECK MARK}]" : "[ ]";
    #my $status = delete $step->{status};
    push @items, [$v_done,$name,$action];
}

if( $output_format eq 'text' ) {
    # IPC::Run3 thrashes *STDOUT encoding, for some reason ?!
    binmode STDOUT, ':encoding(UTF-8)';

    say for @info;
    say "";

    for my $board (@rendered_boards) {
        say $board->{board}->{name};
        my $header = $board->{header};
        my $items = $board->{content};
        if( @$items ) {
            my $table = Text::Table->new( @$header );
            $table->load( @$items );
            say $table;
        } else {
            say "- none -";
        };
    };
    my $table = Text::Table->new();
    $table->load( @items );
    say $table;
} elsif( $output_format eq 'html' ) {
    # XXX
} elsif( $output_format eq 'json' ) {
    binmode STDOUT, ':encoding(UTF-8)';
    say encode_json {
        boards => \@rendered_boards,
        steps => \@items,
        info => \@info,
    };
}
