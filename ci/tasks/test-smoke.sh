#!/bin/bash -eux

pushd bosh-deployment/tests
  ./run-checks.sh
popd
