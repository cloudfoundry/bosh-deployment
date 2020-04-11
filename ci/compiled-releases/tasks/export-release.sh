#!/usr/bin/env bash

set -eu

. $(dirname $0)/../../tasks/utils.sh

. start-bosh

. /tmp/local-bosh/director/env

tar -xzf stemcell/*.tgz $( tar -tzf stemcell/*.tgz | grep 'stemcell.MF' )
tar -xzf release/*.tgz $( tar -tzf release/*.tgz | grep 'release.MF' )

RELEASE_NAME=$(bosh int --path /name release.MF)
RELEASE_VERSION=$(bosh int --path /version release.MF)
STEMCELL_OS=$(bosh int --path /operating_system stemcell.MF)
STEMCELL_VERSION=$(bosh int --path /version stemcell.MF)

bosh -n upload-stemcell stemcell/*.tgz
bosh -n upload-release release/*.tgz

cat > manifest.yml <<EOF
---
name: compilation
releases:
- name: "$RELEASE_NAME"
  version: "$RELEASE_VERSION"
stemcells:
- alias: default
  os: "$STEMCELL_OS"
  version: "$STEMCELL_VERSION"
update:
  canaries: 1
  max_in_flight: 1
  canary_watch_time: 1000 - 90000
  update_watch_time: 1000 - 90000
instance_groups: []
EOF

bosh -n -d compilation deploy manifest.yml
bosh -d compilation export-release $RELEASE_NAME/$RELEASE_VERSION $STEMCELL_OS/$STEMCELL_VERSION

mv *.tgz compiled-release/$( echo *.tgz | sed "s/\.tgz$/-$( date -u +%Y%m%d%H%M%S ).tgz/" )
sha1sum compiled-release/*.tgz
