#!/bin/bash
BASE=$(cd $(dirname $0); pwd)

# This builds and runs bleadperl, highly convenient in the run-up to
# a developer release of Perl

# Maybe this could be ported to Perl instead of being a moderately
# complex shell script ...

# We assume bash, so $PWD is set ...
BLEADPERL=${1-$PWD}
CONFIGURE=${CONFIGURE:-$BASE/cConfigure -- ./Configure}

if [ ! -f "$BLEADPERL/Configure" ]; then
    echo "'$BLEADPERL/Configure' not found - is this the right directory?"
    exit
fi

# Find the current version of Perl we will build. This is maybe a bit
# roundabout... Also, we require a Perl to be available already:
cd "$BLEADPERL"
DEFAULT_VERSION=$(perl -E 'require "./Porting/pod_lib.pl"; my $state=get_pod_metadata(); say sprintf "%d.%d.%d", @{$state->{delta_version}}')
VERSION=${2-$DEFAULT_VERSION}

if [[ -z "$VERSION" ]]; then
    echo "No version found?!"
fi

TEMP=${TMP-/tmp}
INSTALL_TARGET=$TEMP/perl-$VERSION

# Do a sanity check - if a tag for our version already exists, something is wrong:
TAGGED=$(git tag -l "v$VERSION")
if [[ ! -z $TAGGED ]]; then
    echo "Version $VERSION is already tagged at $TAGGED"
    exit 1
fi

# Update the terminal title with the config
echo "Building $VERSION"
echo -en "\e]2;Building $VERSION\a"

# Should we clean and pull?!
git clean -dfX
git pull github

# clean out all the various local Perl modifications you might have.
# We do this so the fresh Perl gets built clean and doesn't pollute your
# local Perl setup:
unset PERL5LIB
unset PERL_MB_OPT
unset PERL_LOCAL_LIB_ROOT
unset PERL_MM_OPT

# Speed up the build
export PERL_TEST_HARNESS_ASAP=1
export HARNESS_OPTIONS=j8
export TEST_JOBS=8
export MAKEFLAGS=-j12

for conf in "" "-Dusethreads" "-Duserrelocatableinc" ; do
    # Update our console title
    echo -en "\e]2;Building $VERSION $conf\a"
    rm config.sh Policy.sh
    if ! ( $CONFIGURE -Dusedevel -des $conf -Dprefix=$INSTALL_TARGET \
          && echo "Test started" \
          && make test_harness \
          && echo "Install started" \
          && make install \
          && $INSTALL_TARGET/bin/perl$VERSION "$BASE/blead-installtest.pl" \
        ) ; then
        echo "Config '$conf' failed: $?"
        echo -en "\e]2;Building $VERSION $conf - failed\a"
        break
    fi
    echo -en "\e]2;Building $VERSION $conf - OK\a"
done
