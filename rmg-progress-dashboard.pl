#!perl
use 5.040; # we use a built-in class
use experimental 'signatures';
use experimental 'class';

use POSIX 'strftime';
use charnames ':full'; # for CHECK MARK
use Cwd 'getcwd';
use Data::Dumper;
use Getopt::Long;
use IPC::Run3;
use Text::Table;
use JSON::PP;
use HTTP::Tiny;
use YAML::Tiny 'LoadFile';

GetOptions(
    'build-dir|d=s' => \my $build_dir,
    'version=s' => \my $our_version,
    'prev-version=s' => \my $previous_version,
    'date=s' => \my $our_rundate,
    'git-remote=s' => \my $git_remote,
    'cpan-user=s' => \my $cpan_user,
    'git-author=s' => \my $git_author,
    'format=s' => \my $output_format,
    'output-file|o=s' => \my $output_file,
    'console' => \my $console,
);

# We will shell out to the fresh Perl, so be certain not to pollute it
# with our local modules
delete @ENV{qw( PERL5LIB PERL_MB_OPT PERL_LOCAL_LIB_ROOT PERL_MM_OPT )};

=head1 SYNOPSIS

  cd bleadperl
  watch -n 10 /usr/bin/perl ../App-rmg-tools/rmg-progress-dashboard.pl --version 5.35.1

If you prefer an HTML file, you can automatically update it using

  while /bin/true; do ../App-rmg-tools/rmg-progress-dashboard.pl --version 5.35.1 -o /tmp/release-5.35.1.html; sleep; done

If you are interested in using the output of the program otherwise, consider JSON output

  ../App-rmg-tools/rmg-progress-dashboard.pl --version 5.35.1 --format json | ...

=cut

my $today = strftime '%Y-%m-%d', localtime;
$our_rundate //= $today;

$build_dir //= '.';
$git_remote //= 'github';
$cpan_user //= 'CORION';
$git_author //= 'corion@corion.net';
$output_format //= 'text';

# Do a sanity check on the build dir:
if( ! -e "$build_dir/Porting" ) {
    die "Directory '$build_dir/Porting' not found. Did you want to run this with --build-dir='bleadperl' ?";
}

my $cpan_author_url = join "/", substr($cpan_user,0,1), substr($cpan_user,0,2), $cpan_user;

sub file_exists( $fn, $dir = $build_dir ) {
    if( $fn =~ m!^/! ) {
        # absolute filename, sorry Windows users
        return -f $fn
    } else {
        return -f "$build_dir/$fn"
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
    my %mtime = map { $_ => -M $_ } (@$fn, @$reference);
    map {
        my $f = $_;
        #warn $f if ! -f $f;
        grep { ($mtime{ $f } // 0) >= ($mtime{ $_ } // 0) } @$reference
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

sub yamlfile($file) {
    LoadFile($file)
}

our $DRY_RUN;

sub run(@command) {
    if( $DRY_RUN ) {
        return "@command";
    }

    my $dir = getcwd();
    chdir( $build_dir )
        or die "Couldn't chdir() to '$build_dir': $!";
    run3(\@command, \undef, \my @stdout, \my @stderr, {
        return_if_system_error => 1,
        binmode_stdout => ':utf8',
    }) == -1 and warn "Command [@command] failed: $! / $?";
    chdir( $dir )
        or die "Couldn't chdir() back to '$dir': $!";
    return trimmed(@stdout);
}

sub exitcode_zero(@command) {
    if( $DRY_RUN ) {
        return "@command";
    }
    run(@command);
    return $? == 0
}

sub git(@command) {
    if( $DRY_RUN ) {
        return "git @command";
    }
    return run(git => @command)
}

sub manually(@command) {
    if( $DRY_RUN ) {
        return "@command";
    }
    return;
}

sub dry_run( $action ) {
    local $DRY_RUN = 1;
    return $action ? $action->({}) : '(manual)'
}

class RMG::StepStatus {
    field $actions :param :reader = [];
    field $visual  :param :reader;
    field $status  :param :reader = 'open';
    field $prereq  :param :reader = [];

    # Move manually etc. also into here?!

    method is_done {
        return $status eq 'done'
    }

    method next_action {
        return $actions->[0]
    }
};


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

# Check that two commits touch the same files, with fairly identical changes
sub commit_like($this_commit, $other_commit) {
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

sub perl_v( $perl="$build_dir/perl" ) {
    grep { /^This is/ } run($perl, '-v')
}

sub pod_section( $filename, $section ) {
    my @lines = lines($filename);

    my @section =
        grep { /^=head1\s+$section/.../^=/ } @lines;

    # Trim the section
    if( @section ) {
        pop @section if $section[-1] =~ /^=/;
        shift @section; # remove the heading
        pop @section
            while $section[-1] =~ /^\s*$/;
        shift @section
            while $section[0] =~ /^\s*$/;
    };

    @section = map { $_ =~ s!^=\w+\s+!!; $_ } @section;
    return join "\n", @section;
}

my $ua;
sub http_exists( $url ) {
    $ua //= HTTP::Tiny->new();
    my $response = $ua->head($url);
    # We don't handle redirects here, and don't report them as success ...
    #warn Dumper $response;
    return $response->{status} =~ /^2\d\d$/;
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
            my( $self ) = @_;

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

            if( ! @res) {
                $self->{name} = 'No CPAN modules newer than blead';
            } else {
                $self->{name} = 'CPAN modules newer than blead';
            };

            return ['Module','Perl','CPAN'], [map { [$_->{name}, $_->{perl}, $_->{cpan}] } @res]
        },
    },
);

# how can we handle if a later step has happened but a previous step seems to have undone that?!
# a) Create an intricate data structure/workflow graph to model the transitions
#    by having ids and listing ids as prerequisites
# b) Add "milestones" that act as points of no return. "git push" is such a milestone, and a close
#    cousin is creating the appropriate git tag/git commit

my @steps = (
    {
        name => 'Version number bumped for this dev release',
        release_type => 'BLEAD-POINT',
        reference => 'bump version',
        test => sub {
            (my $version) = map {
                /^api_versionstring='(.*?)'$/
            } lines("$build_dir/config.sh");
            if( ! $version ) {
                die "Couldn't find a version via '$build_dir/config.sh' ?!";
            }
            if( $version ne $our_version) {
                return "Found $version, bump versions to $our_version";
            };
        },
    },
    {
        name => 'Release branch created',
        reference => 'create a release branch',
        action => sub( $self ) {
            git( checkout => "-b", $release_branch );
        },
        test => sub( $self ) {
            my $branch = git_branch();
            # timestamp: git show foo^{commit} -s '--format=%ai'
            $branch ne $release_branch
                and return "Create branch $release_branch";
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
                # we should also check that the current Perl has the version number we expect
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

            if( my @newer = file_newer_than( "$build_dir/perl", ["$build_dir/config.sh", "$build_dir/Policy.sh" ])) {
                return "Rebuild $build_dir/perl, @newer is newer"
            };

            my $v = [run("./perl", "-I$build_dir/lib", '-wE', 'say $]')]->[0];
            if( $v != $our_version_num) {
                return "Wrong Perl version was built ($v, expected $our_version)";
            };
        },
    },
    {
        name => 'make test was run',
        action => sub( $self ) {
            run( make => 'test' );
        },
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
        name => 'Module::CoreList was updated for ' . $our_version,
        reference => 'update Module::CoreList',
        action => sub( $self ) {
            run("./perl","-Ilib","Porting/corelist.pl","cpan");
        },
        test => sub {
            # First check, if Module::CoreList knows our version
                if( exitcode_zero("./perl","-Ilib","-MModule::CoreList","-le", 'exit !Module::CoreList->find_version($])')) {
                    # if not, run ./perl -Ilib Porting/corelist.pl cpan
                    return "Update Module::CoreList";
                } elsif( ! commit_message_exists( "Update Module::CoreList for .*$our_version",
                    since => $previous_tag,
                    author => $git_author,
                )) {
                    # git commit -m "Update Module::CoreList for $our_version"
                    return "Commit the changes to Module::CoreList"
                }
                # Check that the commit is like the other commits for that
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
        reference => 'final check of perldelta placeholders',
        test => sub( $self ) {
                (my $bad) = grep { /\bXXX\b|^\s*\[(?!(github|commit))[^L]/ } lines("$build_dir/pod/perldelta.pod");
                if ($bad) {
                    return "Fix '$bad'"
                };
        },
    },
    {
        name => "release was added to perlhist.pod",
        files => ["pod/perlhist.pod"],
        reference => 'update perlhist.pod',
        test => sub( $self ) {
                # Perlhist.pod has yet another date format, instead of yyyy-mm-dd
                # We ignore that
                my $version = $our_tag =~ s/^v//r;
                (my $this) = grep { /\Q$version\E/ } lines( "$build_dir/pod/perlhist.pod" );

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
        name => "Test that the current Perl builds and installs as /tmp/perl-$our_version-pretest",
        action => sub( $self ) {
            run('./Configure -des -Dusedevel && make test && make install');
        },
        reference => 'build, test and check a fresh perl',
        test => sub {
                my $target = "/tmp/perl-$our_version-pretest";
                if( ! -d $target) {
                    return "Build and install using ./Configure -des -Dusedevel -Dprefix=$target"
                };

                # Check that we installed the correct version:
                my $target_perl = "$target/bin/perl$our_version";
                my $v = perl_v( $target_perl );
                if( $v !~ /\Q$our_version\E/ ) {
                    return "!!! $target_perl returns the wrong version ($v)"
                }

                my $git_head = git('describe');
                if( $v !~ /\Q$git_head\E/ ) {
                    return "!!! $target_perl returns wrong git commit ($v)"
                }
        },
    },
    # here the -pretest directory gets deleted, and we won't know where
    # we stand...
    {
        name => "tag for $our_version is created",
        action => sub( $self ) {
            git( tag => "v$our_version", '-m', "Perl $our_version" );
        },
        type => 'milestone',
        test => sub {
                if( ! git( tag => '-l', $our_tag )) {
                    return "Create the release tag $our_tag";
                };
        },
        id => 'tag-created'
    },
    {
        name => "release tarball exists",
        reference => 'build the tarball',
        files => ["$build_dir/../$our_tarball_xz"],
        action => sub( $self ) {
            run( perl => "Porting/makerel", "-x" );
        },
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
        name => "local installation of $previous_version exists at /tmp/perl-$previous_version",
        reference => 'Compare the installed paths to the last release',
        test => sub {
            # Well, this should also be newer than all other
            # files here
            my $target = "/tmp/perl-$previous_version/bin/perl$previous_version";
            if( !file_exists( $target )) {
                return "Locally install $previous_version"
            };

            if( my @newer = file_newer_than( "./perl", $target )) {
                    return "Retest local installation, @newer is newer"
            };

            ()
        },
    },
    {
        name => "local installation of $our_version exists at /tmp/perl-$our_version",
        reference => 'test the tarball',
        test => sub {
            # Well, this should also be newer than all other
            # files here
            my $target = "/tmp/perl-$our_version/bin/perl$our_version";
            if( !file_exists( $target )) {
                return "Locally install $our_version"
            };

            if( my @newer = file_newer_than( $target, "./perl" )) {
                    return "Retest local installation, @newer is newer"
            };

            ()
        },
    },
    {
        name => "Compare the installed paths to the last release",
        reference => 'Compare the installed paths to the last release',
        test => sub {
            my $target = "/tmp/perl-$our_version/bin/perl$our_version";
            if( !file_exists( "/tmp/f1", "/tmp/f2" )) {
                return "Run the file comparison"
            };
        },
    },

    {
        name => "release tarball published for testing",
        reference => 'Copy the tarball to a web server',
        files => ["$build_dir/../$our_tarball_xz"],
        test => sub {
            # Do we want to make an HTTP call every time?!
            # Or only do that if the release tarball exists, and then
            # check that they are identical!
                if( ! file_exists( "../$our_tarball_xz" )) {
                    return "Build the release tarball $our_tarball_xz"
                };

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
                if( ! file_exists( "../$our_tarball_xz" )) {
                    return "Build the release tarball $our_tarball_xz"
                };
                if(! http_exists("https://www.cpan.org/authors/id/$cpan_author_url/$our_tarball_xz")) {
                    return "Upload the tarball to CPAN"
                };
        },
    },
    {
        name => 'Release schedule ticked and committed',
        reference => 'Release schedule',
        test => sub {
            if( ! $planned_release->{released} ) {
                return "Tick the release mark";
            };
            if( ! commit_message_exists( "schedule",
                    since => $previous_tag,
                    author => $git_author,
                )) {
                return "Commit the change";
            };
        },
    },
    {
        name => 'Release branch merged back to blead',
        reference => 'merge release branch back to blead',
        test => sub {
            my $branch = git_branch();
            if( $branch ne 'blead') {
                # XXX here we should return this action as the next step
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
        reference => 'publish the release tag',
        type => 'milestone',
        id => 'release-tag-pushed-upstream',
        needs => ['tag-created'],
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
        name => 'Release branch deleted',
        reference => 'delete release branch',
        needs => ['release-tag-pushed-upstream'],
        test => sub {
            my $branch = git_branch();
            if( $branch ne 'blead') {
                return "Switch back to blead";
            }
            my @branches = grep { $_ eq $release_branch } git( branch => '-l' );
            if( @branches ) {
                return "Delete branch $release_branch";
            };
            ()
        },
    },
    {
        name => "epigraphs.pod was updated",
        files => ["Porting/epigraphs.pod"],
        reference => "Add epigraph for $our_version",
        test => sub( $self ) {
                my $version = $our_tag =~ s/^v//r;
                (my $this) = grep { /\Q$version\E/ } lines( 'Porting/epigraphs.pod' );

                if( ! $this ) {
                    return "version $version not added";
                };

                if( ! commit_message_exists( "Add epigraph for $our_version",
                    since => $previous_tag,
                    author => $git_author,
                )) {
                    return "Commit changes to 'Porting/epigraphs.pod'";
                };
        },
    },
    {
        name => 'Version number bumped for next dev release',
        release_type => 'BLEAD-POINT',
        reference => 'bump version',
        action => sub( $self ) {
            run( "perl" => "-Ilib","Porting/bump-perl-version","-i",$our_version, $next_version );
        },
        test => sub {
            my $branch = git_branch();
            if( $branch ne 'blead' ) {
                return { visual => "Switch back to blead" };
            };

            (my $version) = map {
                /^api_versionstring='(.*?)'$/
            } lines("$build_dir/config.sh");
            if( $version ne $next_version) {
                return "Found $version, bump versions to $next_version"
            } else {
                return 1
            };
        },
    },
);

# Collect the dashboard(s)
my @rendered_boards;
for my $board (@boards) {
    my ($header,$items) = $board->{list}->($board);

    push @rendered_boards, {
        board => $board,
        header => $header,
        content => $items,
        name => $board->{name},
    };
}

my %status_cache;
my %prerequisites;

sub step_status( $step ) {
	if (! exists $status_cache{ $step }) {
		local $|=1;
		my $msg = $step->{name};
		print $msg unless $console;

        my @missing_prereq;
        if( my $p = $step->{needs} ) {
            @missing_prereq = grep { !$prerequisites{ $_ } } $p->@*;
        }

		my $action;
        my $is_done;
        if( @missing_prereq ) {
            $action = "Waiting for " . join( ", ", @missing_prereq),
        } else {
            $action = $step->{test}->($step);
            $is_done = !$action;
        }
		my $name = $step->{name};

		$status_cache{ $step } = {
			done => $is_done,
            done_visual => ( $is_done ? "\N{CHECK MARK}" : " "),
			name => $name,
			action => $action,
			step => $step,
			reference => $step->{reference},
            id => $step->{id},
		};
		print "\r" . (" " x length($msg)). "\r" unless $console;
	}
	return $status_cache{ $step };
}

# Now, find the last milestone whose condition is met
# Also, we set all steps with an id that we found
for my $step (@steps) {
    my $s = step_status( $step );
    if( !$s->{action} and $s->{id} ) {
        $prerequisites{ $s->{id}} = 1;
    }
}

my @milestones = grep { $_->{done} eq "\N{CHECK MARK}" }
                 map  { step_status($_) }
                 grep { $_->{type} and $_->{type} eq 'milestone' } @steps;
my $last_milestone = $milestones[-1] || 0;

# A list of files that need to be newer (or same) than the previous, in sequence
my @up_to_date_files;
my @items;
my $before_milestone = $last_milestone > 0;
for my $step (@steps) {
	if(    $last_milestone
		&& $step == $last_milestone->{step} ) {
		$before_milestone = 0;
	};

	my $s;
	if( $before_milestone ) {
		$s = {
			done      => '-',
			name      => $step->{name},
			action    => "<cannot change anymore>",
			reference => $step->{reference},
		};
	} else {
		$s = step_status( $step );
	}
    push @items, $s;
}

my $output = '';
if( $output_format eq 'text' or $console ) {
    # IPC::Run3 thrashes *STDOUT encoding, for some reason ?!

    $output .= join "\n", @info, "";

    for my $board (@rendered_boards) {
        say $board->{board}->{name};
        my $header = $board->{header};
        my $items = $board->{content};
        if( @$items ) {
            my $table = Text::Table->new( @$header );
            $table->load( @$items );
            $output .= $table . "\n";
        #} else {
        #    $output .= "- none -\n";
        };
    };
    my $table = Text::Table->new();
    my @rendered_items = map {
        my $v_done = "[$_->{done_visual}]";
        [$v_done, $_->{name}, $_->{action}, $_->{done} ? '' : dry_run( $_->{step}->{action} ) ]
    } @items;
    $table->load( @rendered_items );
    $output .= $table . "\n";

    if($console) {
        binmode *STDOUT, ':raw:encoding(UTF-8)';
        print STDOUT $output;
        $output = '';
    }

};
if( $output_format eq 'html' ) {
    require HTML::Template;
    local $/;
    my @html_rendered_boards = map {
        my %b = %$_;
        +{
            name    => $_->{name},
            header  => [ map { +{col => $_ }; } @{$_->{header}} ],
            content => [ map { +{row => [ map {+{col => $_ };} @$_] }} @{$_->{content}} ],
        };

    } @rendered_boards;

    my @html_rendered_items = map {
        my %i = %$_;
        $i{reference} //= '';
        $i{url} = 'https://metacpan.org/pod/distribution/perl/Porting/release_managers_guide.pod#' . ($i{reference} =~ s/\s+/-/gr);
        my $v_done = $_->{done};
        $i{done} = $v_done;
        delete @i{qw[reference list]};
        \%i
    } @items;

    my $tmpl = HTML::Template->new(
        filehandle => *DATA,
        die_on_bad_params => 0,
    );
    $tmpl->param(info   => [map { +{line => $_ }} @info]);
    $tmpl->param(boards => \@html_rendered_boards);
    $tmpl->param(steps  => \@html_rendered_items);
    $tmpl->param(our_version => $our_version);
    $tmpl->param(timestamp  => strftime '%Y-%m-%d %H:%M:%S', gmtime);
    $output = $tmpl->output;

} elsif( $output_format eq 'json' ) {
    binmode STDOUT, ':encoding(UTF-8)';
    $output = encode_json {
        boards => \@rendered_boards,
        steps => \@items,
        info => \@info,
    };
}

my $out;
if ($output_file) {
    open $out, '>:utf8', $output_file
        or die "Couldn't create '$output_file': $!";
} else {
    $out = \*STDOUT;
    binmode $out, ':encoding(UTF-8)';
};
print { $out } $output;

# It would be nice to have links/further information for each action
# be displayable right next to it

__DATA__
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8"/>
<meta http-equiv="refresh" content="60">
<title>Release manager dashboard for <TMPL_VAR NAME="our_version"></title>
<style>
html {
  font-size: medium;
}

body {
  background-color: #fffff6;
  color: #330;
  font-family: georgia, times, serif;
  margin: 2rem auto 8rem;
  max-width: 40em;
  padding: 0 2em;
  width: auto;
  font-size: 1rem;
  line-height: 1.4;
}

a {
  color: #1e6b8c;
  font-size: 1em;
  text-decoration: none;
  transition-delay: 0.1s;
  transition-duration: 0.3s;
  transition-property: color, background-color;
  transition-timing-function: linear;
}

a:visited {
  color: #6f32ad;
  font-size: 1em;
}

a:hover {
  background: #f0f0ff;
  font-size: 1em;
  text-decoration: underline;
}

a:active {
  background-color: #427fed;
  color: #fffff6;
  color: white;
  font-size: 1em;
}

h1,
h2,
h3,
h4,
h5,
h6 {
  color: #703820;
  font-weight: bold;
  line-height: 1.2;
  margin-bottom: 1em;
  margin-top: 2em;
}

h1 {
  font-size: 2.2em;
  text-align: center;
}

h2 {
  font-size: 1.8em;
  border-bottom: solid 0.1rem #703820;
}

h3 {
  font-size: 1.5em;
}

h4 {
  font-size: 1.3em;
  text-decoration: underline;
}

h5 {
  font-size: 1.2em;
  font-style: italic;
}

h6 {
  font-size: 1.1em;
  margin-bottom: 0.5rem;
  color: #330;
}

pre,
code,
xmp {
  font-family: courier;
  font-size: 1.1rem;
  line-height: 1.4;
  white-space: pre-wrap;
}

img {
  margin: 2em auto;
  padding: 1em;
  outline: solid 1px #ccc;
  max-width: 90%;
  }</style>
<body>
<h1>Release manager dashboard</h1>
<small>Last updated: <TMPL_VAR NAME="timestamp"> UTC</small>
<TMPL_LOOP NAME="info"><p><TMPL_VAR NAME="line"></p></TMPL_LOOP>

<TMPL_LOOP NAME="boards">
<h2><TMPL_VAR NAME="name"></h2>
<table>
<thead><tr>
    <TMPL_LOOP NAME="header"><td><TMPL_VAR NAME="col"></td></TMPL_LOOP>
</tr></thead>
    <tbody>
    <TMPL_LOOP NAME="content">
    <tr><TMPL_LOOP NAME="row"><td><TMPL_VAR NAME="col"></td></TMPL_LOOP></tr>
    </TMPL_LOOP>
</tbody>
</table>
</TMPL_LOOP>

<h2>Release progress</h2>
<table>
<tbody>
<TMPL_LOOP NAME="steps">
<tr>
    <td><TMPL_VAR NAME="done"></td>
    <td><a href="<TMPL_VAR NAME='url'>"><TMPL_VAR NAME="name"></a></td>
    <td><TMPL_VAR NAME="action"></td>
</tr>
</TMPL_LOOP>
</tbody>
</table>

<footer>
<small>Created by <a href="https://github.com/Corion/App-rmg-tools">Perl release manager dashboard</a></small>
</footer>
</body>
</html>
