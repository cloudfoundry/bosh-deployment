#!/usr/bin/env bash

set -eu

lpass ls > /dev/null

fly -t bosh-ecosystem set-pipeline -p bosh-deployment \
    -c ci/pipeline.yml
