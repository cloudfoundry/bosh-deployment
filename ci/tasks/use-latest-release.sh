#!/bin/bash -eux


tar -xzf compiled-bosh-release/*.tgz $( tar -tzf *.tgz | grep 'release.MF' )
VERSION=$( grep -E '^version: ' release.MF | awk '{print $2}' | tr -d "\"'" )
URL=$(cat compiled-bosh-release/url)
SHA1=$(sha1sum compiled-bosh-release/*.tgz | awk '{print $1}')

INTERPOLATE_SCRIPT=interpolate_script.rb
MANIFEST=bosh-deployment-output/bosh.yml

git clone bosh-deployment bosh-deployment-output

cat << EOF > $INTERPOLATE_SCRIPT
lines = File.readlines("$MANIFEST")
found_releases = false
lines.each_with_index do |line, i|
  found_releases = true if line.start_with?('releases:')
  next if !found_releases
  if line.start_with?("- name: #{ENV['RELEASE_NAME']}")
    lines[i+1] = "  version: \"$VERSION\"\n"
    lines[i+2] = "  url: $URL\n"
    lines[i+3] = "  sha1: $SHA1\n"
    break
  end
end
File.open("$MANIFEST", 'w') { |f| f.write(lines.join) }
EOF

ruby $INTERPOLATE_SCRIPT

pushd $PWD/bosh-deployment-output
  git diff
  git add -A
  git config --global user.email "ci@localhost"
  git config --global user.name "CI Bot"
  git commit -m "Bumping BOSH to version $VERSION"
popd
