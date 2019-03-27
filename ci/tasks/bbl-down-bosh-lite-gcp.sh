#!/bin/bash -ex

bbl_down() {
  pushd ${BUILD_DIR}/bbl-state
    bbl --debug down --no-confirm
  popd
}

pushd "${PWD}/bbl-state"
  bbl_down
popd
