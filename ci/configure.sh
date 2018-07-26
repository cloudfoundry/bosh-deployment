#!/usr/bin/env bash

set -eu

fly -t production set-pipeline -p bosh-deployment \
    -c ci/pipeline.yml \
    --load-vars-from <(lpass show -G "bosh-deployment concourse secrets" --notes)
