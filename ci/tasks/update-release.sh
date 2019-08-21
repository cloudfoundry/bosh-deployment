#!/bin/bash -eux

. $(dirname $0)/utils.sh

exit_if_already_compiled() {
  tar -xzf stemcell/*.tgz $( tar -tzf stemcell/*.tgz | grep 'stemcell.MF' )
  STEMCELL_OS=$(bosh int --path /operating_system stemcell.MF)
  STEMCELL_VERSION=$(bosh int --path /version stemcell.MF)
  # Look for the base name of the tarball in the url in the opsfile prior to update
  if grep -q "$RELEASE_NAME-$VERSION-$STEMCELL_OS-$STEMCELL_VERSION" bosh-deployment/$FILE_TO_UPDATE; then
    echo "Already compiled for this OS/VERSION"
    exit 0
  fi
}

tar -xzf stemcell/*.tgz $( tar -tzf stemcell/*.tgz | grep 'stemcell.MF' )
STEMCELL_OS=$(bosh int --path /operating_system stemcell.MF)
STEMCELL_VERSION=$(bosh int --path /version stemcell.MF)

tar -xzf release/*.tgz $(tar -tzf release/*.tgz | grep 'release.MF')
RELEASE_NAME="$(bosh int release.MF --path /name)"
VERSION="$(bosh int release.MF --path /version)"
SHA="$(sha1sum release/*.tgz | cut -d' ' -f1)"

git clone bosh-deployment bosh-deployment-output

if [[ `grep compiled_packages release.MF` ]]; then
  TARBALL_NAME="$(basename release/*.tgz)"
  URL="https://s3.amazonaws.com/bosh-compiled-release-tarballs/${TARBALL_NAME}"
  exit_if_already_compiled
else
  URL="https://bosh.io/d/github.com/${BOSH_IO_RELEASE}?v=${VERSION}"
  test_bosh_io_release_exists $URL
fi

if [[ $UPDATING_BASE_MANIFEST == "true" ]]; then
  UPDATE_RELEASE_OPSFILE=$(make_base_manifest_release_opsfile $RELEASE_NAME $VERSION $URL $SHA)
else
  UPDATE_RELEASE_OPSFILE=$(make_release_opsfile $RELEASE_NAME $VERSION $URL $SHA)
fi

bosh int bosh-deployment/${FILE_TO_UPDATE} -o $UPDATE_RELEASE_OPSFILE > bosh-deployment-output/${FILE_TO_UPDATE}

pushd $PWD/bosh-deployment-output
  git_commit "Bumping $RELEASE_NAME to version $VERSION"
popd
