#!/bin/bash -eux

. $(dirname $0)/utils.sh

tar -xzf release/release.tgz "release.MF"

RELEASE_NAME="$( bosh int release.MF --path /name )"
VERSION="$( bosh int release.MF --path /version )"
SHA1="$(sha1sum release/*.tgz | cut -d' ' -f1)"
URL="https://bosh.io/d/github.com/${BOSH_IO_RELEASE}?v=${VERSION}"

test_bosh_io_release_exists $URL

UPDATE_RELEASE_OPSFILE=$(make_release_opsfile $RELEASE_NAME $VERSION $URL $SHA1)

git clone bosh-deployment bosh-deployment-output

bosh int bosh-deployment/${FILE_TO_UPDATE} -o $UPDATE_RELEASE_OPSFILE > bosh-deployment-output/${FILE_TO_UPDATE}

pushd $PWD/bosh-deployment-output
  git_commit "Bumping $RELEASE_NAME to version $VERSION"
popd
