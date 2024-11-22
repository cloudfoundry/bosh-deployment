#!/usr/bin/env bash

set -eu

fly -t bosh set-pipeline -p bosh-deployment \
    -c ci/pipeline.yml
