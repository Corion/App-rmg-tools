#!perl
use 5.020;
use experimental 'signatures';
use stable 'postderef';

use Data::Dumper;
use YAML 'Load';
use Carp 'croak';
use List::Util 'reduce';

sub extract_prefix( $l, $r ) {
    my $map = $l ^ $r;
    $map =~ /^(\0*)/;
    return substr( $l, 0, length( $1 ));
}

# We assume a single change per line, which makes sense given our data
sub line_template( $line1, $line2, $name='XXX' ) {

    if( $line1 eq $line2 ) {
        return {
            template => $line1,
            values => {}
        };
    }

    my $prefix = extract_prefix( $line1, $line2 );
    my $suffix = reverse extract_prefix( scalar reverse($line1), scalar reverse($line2));

    my $template = $prefix . "{$name}" . $suffix;

    my ($pre, $suf) = (length($prefix),length($suffix));

    my $values = [
        substr( $line1, $pre, length($line1)-$pre-$suf),
        substr( $line2, $pre, length($line2)-$pre-$suf),
    ];

    return {
        template => $template,
        values => { $name => $values },
    };
}

sub gen_template( $diff1, $diff2 ) {
    # Rearrange sequences of + / - side-by-side
    my $hunk_length = 1;
    while( substr( $diff1->[$hunk_length],0,1 ) eq '-' ) {
        $hunk_length++;
    }
    my $i  = 0;
    return [
        line_template( substr($diff1->[$i],1), substr($diff2->[$i],1),'xxx'),
        line_template( substr($diff1->[$i],1), substr($diff1->[$i+$hunk_length],1),'yyy' ),
    ]
}

my @diff = (
[
    [
          '-api_subversion=\'4\'',
          '+api_subversion=\'5\'',
          '-api_versionstring=\'5.37.4\'',
          '+api_versionstring=\'5.37.5\'',
          '-archlib=\'/usr/lib/perl5/5.37.4/armv4l-linux\'',
          '-archlibexp=\'/usr/lib/perl5/5.37.4/armv4l-linux\'',
          '+archlib=\'/usr/lib/perl5/5.37.5/armv4l-linux\'',
          '+archlibexp=\'/usr/lib/perl5/5.37.5/armv4l-linux\'',
     ],
    [
          '-api_subversion=\'4\'',
          '+api_subversion=\'5\'',
          '-api_versionstring=\'5.41.4\'',
          '+api_versionstring=\'5.41.5\'',
          '-archlib=\'/usr/lib/perl5/5.41.4/armv4l-linux\'',
          '-archlibexp=\'/usr/lib/perl5/5.41.4/armv4l-linux\'',
          '+archlib=\'/usr/lib/perl5/5.41.5/armv4l-linux\'',
          '+archlibexp=\'/usr/lib/perl5/5.41.5/armv4l-linux\'',
    ]
],
[
    [
          '-1.a',
          '+2.a',
     ],
    [
          '-1.b',
          '+2.b',
    ]
],
[
    [
          '-api_versionstring=\'5.37.4\'',
          '+api_versionstring=\'5.37.5\'',
          '-archlib=\'/usr/lib/perl5/5.37.4/armv4l-linux\'',
          '-archlibexp=\'/usr/lib/perl5/5.37.4/armv4l-linux\'',
          '+archlib=\'/usr/lib/perl5/5.37.5/armv4l-linux\'',
          '+archlibexp=\'/usr/lib/perl5/5.37.5/armv4l-linux\'',
     ],
    [
          '-api_versionstring=\'5.41.4\'',
          '+api_versionstring=\'5.41.5\'',
          '-archlib=\'/usr/lib/perl5/5.41.4/armv4l-linux\'',
          '-archlibexp=\'/usr/lib/perl5/5.41.4/armv4l-linux\'',
          '+archlib=\'/usr/lib/perl5/5.41.5/armv4l-linux\'',
          '+archlibexp=\'/usr/lib/perl5/5.41.5/armv4l-linux\'',
    ]
],
[
    [
          '-archlib=\'/usr/lib/perl5/5.37.4/armv4l-linux\'',
          '-archlibexp=\'/usr/lib/perl5/5.37.4/armv4l-linux\'',
          '+archlib=\'/usr/lib/perl5/5.37.7/armv4l-linux\'',
          '+archlibexp=\'/usr/lib/perl5/5.37.7/armv4l-linux\'',
     ],
    [
          '-archlib=\'/usr/lib/perl5/5.41.4/armv4l-linux\'',
          '-archlibexp=\'/usr/lib/perl5/5.41.4/armv4l-linux\'',
          '+archlib=\'/usr/lib/perl5/5.41.5/armv4l-linux\'',
          '+archlibexp=\'/usr/lib/perl5/5.41.5/armv4l-linux\'',
    ]
],
);

sub merge_templates_2( $t1, $t2 ) {
    my $magic_key = "\0magic\0";
    my $merged = line_template( $t1->{template}, $t2->{template}, $magic_key );
    my $values = $merged->{values}->{$magic_key};

    # This means we have only a single variable. So, just return the template,
    # instead of trying to further merge it
    croak "Logic error, didn't expect " . Dumper $merged
        if $merged->{template} !~ "{$magic_key}";

    # Now, find the middle ground between the two templates
    $values->[0] =~ /\{\w+\}/;
    my ($start1, $end1) = ($-[0],$+[0]);
    $values->[1] =~ /\{\w+\}/;
    my ($start2, $end2) = ($-[0],$+[0]);

    # Now, magically align the two strings...
    if( $start1 > $start2 ) {
        # Swap and start over
        #warn "Swapping";
        return merge_templates( $t2, $t1 );
    } else {
        #use Data::Dumper; warn Dumper $merged;
        #warn "[$start1,$end1] | [$start2,$end2]";
        my $middle1 = substr( $values->[0], $end1 );
        my $middle2 = substr( $values->[1], 0, $start2 );

        #warn "$middle1 | $middle2";

        my $common_len = 0;
        while( substr( $middle2, -$common_len-1 ) eq substr($middle1,0,$common_len+1)) {
            $common_len++
        }
        #warn "Common: $common_len";
        my $common = substr( $middle2, -$common_len );

        my $first_template  = substr($values->[0], $start1, $end1-$start1);
        my $second_template = substr($values->[1], $start2, $end2-$start2);

        (my $k1) = keys $t1->{values}->%*;
        (my $k2) = keys $t2->{values}->%*;

        my $t = "$first_template$common$second_template";
        my $m = $merged->{template} =~ s/\Q{$magic_key}/$t/r;

        return {
            template => $m,

            # The construction of the values is not entirely correct, but
            # close enough for "common" values.
            values => {
                $k1 => $t1->{values}->{$k1},
                $k2 => $t2->{values}->{$k2},
            },
        }
    }
}

sub merge_templates( $t, @templates ) {
    my $t2 = $t;
    return reduce { merge_templates_2($a,$b) } ($t, @templates)
}

for my $test (@diff) {
    my $template = gen_template($test->[0], $test->[1]);
    #use Data::Dumper; warn Dumper $template;

    my $needs_merge = [
        grep { 0+keys $_->{values}->%* } $template->@*
    ];

    warn Dumper merge_templates( $needs_merge->@* );
}

