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
use HTTP::Tiny;

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
);

# We will shell out to the fresh Perl, so be certain not to pollute it
# with our local modules
delete @ENV{qw( PERL5LIB PERL_MB_OPT PERL_LOCAL_LIB_ROOT PERL_MM_OPT )};

=head1 SYNOPSIS

  cd bleadperl
  watch -n 10 /usr/bin/perl ../App-rmg-tools/rmg-progress-dashboard.pl --version 5.35.1

If you prefer an HTML file, you can automatically update it using

  while /bin/true; do ../App-rmg-tools/rmg-progress-dashboard.pl --version 5.35.1 -o /tmp/release-5.35.1.html; sleep; done

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
        warn $f if ! -f $f;
        grep { warn $_ if ! -f $_; $mtime{ $f } >= $mtime{ $_ }} @$reference
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

            my @items = run("$build_dir/perl", "-Ilib", "Porting/core-cpan-diff", "-x", "-a");
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

my @steps = (
    {
        name => 'Release branch created',
        reference => 'create a release branch',
        test => sub( $self ) {
            my $branch = git_branch();
            # timestamp: git show foo^{commit} -s '--format=%ai'
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
        reference => 'final check of perldelta placeholders',
        test => sub( $self ) {
                (my $bad) = grep { /\bXXX\b|^\s*\[(?!(github|commit))[^L]/ } lines('pod/perldelta.pod');
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
        name => "Test that the current Perl builds and installs as /tmp/perl-$our_version-pretest",
        reference => 'build, test and check a fresh perl',
        test => sub {
                my $target = "/tmp/perl-$our_version-pretest";
                if( ! -d $target) {
                    return "Build and install using ./Configure -des -Dusedevel -Dprefix=/tmp/perl-5.x.y-pretest"
                };
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
        reference => 'build the tarball',
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
        reference => 'merge release branch back to blead',
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
        reference => 'publish the release tag',
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
        type => 'BLEAD-POINT',
        reference => 'bump version',
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
    my ($header,$items) = $board->{list}->($board);

    push @rendered_boards, {
        board => $board,
        header => $header,
        content => $items,
        name => $board->{name},
    };
}

# A list of files that need to be newer (or same) than the previous, in sequence
my @up_to_date_files;
my @items;
for my $step (@steps) {
    my $action = $step->{test}->($step);
    my $name = $step->{name};
    push @items, {
        done => !$action,
        name => $name,
        action => $action,
        reference => $step->{reference},
    };
}

my $output = '';
if( $output_format eq 'text' ) {
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
        my $v_done = $_->{done} ? "[\N{CHECK MARK}]" : "[ ]";
        [$v_done, $_->{name}, $_->{action}]
    } @items;
    $table->load( @rendered_items );
    $output .= $table . "\n";

} elsif( $output_format eq 'html' ) {
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
        my $v_done = $_->{done} ? "\N{CHECK MARK}" : "";
        $i{done} = $v_done;
        delete @i{qw[reference list]};
        \%i
    } @items;

    my $tmpl = HTML::Template->new(
        filehandle => *DATA,
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
