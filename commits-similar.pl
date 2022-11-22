#!perl
use 5.020;
use feature 'signatures';
no warnings 'experimental::signatures';

use IPC::Run3;
use Text::Table;
use List::Util 'max';

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
    return run(git => @command)
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

sub commit_unlike( $this, $that, $unifier_cb ) {
	my @left  = raw_commit( $this );
	my @right = raw_commit( $that );
	my @cmp_left  = map { $unifier_cb->($_) } @left;
	#my @cmp_right = map { $unifier_cb->($_) } @right;
	my @cmp_right = @right;

	my @diff;

    my $lines = max( scalar @left, scalar @right );	
	for( 0..$lines-1 ) {
		my $l = $cmp_left[ $_ ];
		my $r = $cmp_right[ $_ ];
		if( $l ne $r ) {
			push @diff, [$left[$_], $right[$_]];
		}
	}
	
	return @diff;
}

my $d;
$d = commit_files_unlike('4ab96809c99e944e70c21779641e4b1c9a00df41','4ab96809c99e944e70c21779641e4b1c9a00df41');
say commit_file_diff_vis( 'old', 'new', $d );
$d = commit_files_unlike('1ef54df4bdf39e1d2ef626673002bbc7886b7bb3','4ab96809c99e944e70c21779641e4b1c9a00df41');
say commit_file_diff_vis( 'old', 'new', $d );
$d = commit_files_unlike('1ef54df4bdf39e1d2ef626673002bbc7886b7bb3','f2582f5b18658f945a763f2edc110cdc7c5220e7');
say commit_file_diff_vis( 'old', 'new', $d );

my $old_v = '5.37.4';
my $new_v = '5.37.5';
my $next_v = '5.37.6';

my %old_repl = (
    '5.37.4'    => '5.37.5',
    '5.037004'    => '5.037005',
    '005037004' => '005037005',
);

my %new_repl = (
    '5.37.5'    => '5.37.6',
    '5.037005'    => '5.037006',
    '005037005' => '005037006',
);

sub fudge_version_number($line) {
	if( $line =~ /^-/ ) {
		my $search = "(" . join( "|", keys %old_repl ) . ")";
		$line =~ s!$search!$old_repl{$1}!ge;
	} elsif( $line =~ /^\+/ ) {
		my $search = "(" . join( "|", keys %new_repl ) . ")";
		$line =~ s!$search!$new_repl{$1}!ge;
	}
	$line
};

my @diff = commit_unlike( '1ef54df4bdf39e1d2ef626673002bbc7886b7bb3','4ab96809c99e944e70c21779641e4b1c9a00df41', \&fudge_version_number );
if( @diff ) {
	use Data::Dumper;
	warn Dumper \@diff;
}
