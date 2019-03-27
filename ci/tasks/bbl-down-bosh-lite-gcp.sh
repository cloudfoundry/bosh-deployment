#!/bin/bash -ex

bbl_down() {
  pushd ${BUILD_DIR}/bbl-state
    bbl --debug down --no-confirm
  popd
}

pushd bbl-state
  bbl_down
popd
