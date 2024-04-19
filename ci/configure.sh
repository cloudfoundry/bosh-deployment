#!/usr/bin/env bash

set -eu

fly -t bosh-ecosystem set-pipeline -p bosh-deployment \
    -c ci/pipeline.yml
