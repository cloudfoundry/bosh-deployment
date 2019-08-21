#!/bin/bash -eux

test_bosh_io_release_exists() {
  BOSH_IO_URL=$1
  echo "Testing source release url: ${BOSH_IO_URL}"
  if ! curl --output /dev/null --silent --head --fail "$BOSH_IO_URL"; then exit 1; fi
}

git_commit() {
  MESSAGE=$1

  git diff | cat
  git add -A
  git config --global user.email "ci@localhost"
  git config --global user.name "CI Bot"
  git diff-index --quiet HEAD || git commit -m "$MESSAGE"
}

make_update_patch() {
  NAME=$1
  VERSION=$2
  URL=$3
  SHA=$4
  PATCH_PATH=$5

  cat << EOF
---
- type: replace
  path: ${PATCH_PATH}
  value:
    name: ${NAME}
    sha1: ${SHA}
    url: ${URL}
    version: ${VERSION}
EOF
}

make_cpi_opsfile() {
  make_update_patch "$@" "/name=cpi/value" > update-cpi-ops.yml
  echo update-cpi-ops.yml
}

make_release_opsfile() {
  NAME=$1
  make_update_patch "$@" "/release=${NAME}/value" > update-release-ops.yml
  echo update-release-ops.yml
}

make_base_manifest_release_opsfile() {
  NAME=$1
  make_update_patch "$@" "/releases/name=${NAME}" > update-base-release-ops.yml
  echo update-base-release-ops.yml
}

make_stemcell_opsfile() {
  URL=$1
  SHA=$2

  cat << EOF > update_stemcell_ops.yml
---
- type: replace
  path: /name=stemcell/value
  value:
    sha1: ${SHA}
    url: ${URL}
EOF

  echo update_stemcell_ops.yml
}
