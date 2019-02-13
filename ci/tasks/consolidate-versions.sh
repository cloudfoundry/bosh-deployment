#!/bin/bash

git clone bosh-deployment bosh-deployment-output

DIRECTORY=bosh-deployment/ci/intermediate-vars/

echo "---" > bosh-deployment-output/version-vars.yml
for file in "${DIRECTORY}"/*.yml; do
  tail -n 4 "${file}" >> bosh-deployment-output/version-vars.yml
done

pushd $PWD/bosh-deployment-output
  git diff
  git add -A
  git config --global user.email "ci@localhost"
  git config --global user.name "CI Bot"
  git commit -m "Bumping BOSH to version $VERSION"
popd
