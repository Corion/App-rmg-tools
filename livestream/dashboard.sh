#!/bin/bash

VERSION=${1-5.41.7}

cd $(dirname $0)

watch -n 60 ./generate-dashboard.sh "$VERSION"

