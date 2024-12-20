#!/bin/bash

VERSION=${1-5.41.7}

cd ~/Projekte/bleadperl

perl ~/Projekte/App-rmg-tools/rmg-progress-dashboard.pl -o /tmp/livestream/index.html --format html --version "$VERSION" --console
scp /tmp/livestream/index.html corion@datenzoo.de:corion.net/live/release-$VERSION.html
