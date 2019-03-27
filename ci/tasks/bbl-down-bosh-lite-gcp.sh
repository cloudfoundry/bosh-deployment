#!/bin/bash -ex

bbl_down() {
  bbl --debug down --no-confirm
}

pushd "${PWD}/bbl-state"
  bbl_down
popd
