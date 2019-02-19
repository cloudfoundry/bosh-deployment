#!/bin/bash -eux

tar -xzf compiled-release/*.tgz $( tar -tzf compiled-release/*.tgz | grep 'release.MF' )
RELEASE_NAME="$( bosh int release.MF --path /name )"
VERSION="$( bosh int release.MF --path /version )"
TARBALL_NAME="$(cd compiled-release/; echo *.tgz)"
SHA1="$(sha1sum compiled-release/*.tgz | cut -d' ' -f1)"

URL="https://s3.amazonaws.com/bosh-compiled-release-tarballs/${TARBALL_NAME}"

INTERPOLATE_SCRIPT=interpolate_script.rb
git clone bosh-deployment bosh-deployment-output

cat << EOF > $INTERPOLATE_SCRIPT
changes=0
manifests=%x|find bosh-deployment-output -name '*.yml'|.split("\n")
manifests.each do |manifest|
  lines = File.readlines(manifest)
  found_releases = false
  found_ops_releases = false
  lines.each_with_index do |line, i|
    found_releases = true if line.start_with?('releases:')
    if found_releases
      found_releases = false if line.chomp == ''
      if line.chomp == '- name: $RELEASE_NAME' && lines[i+2].include?('compile')
        lines[i+1] = "  version: \"$VERSION\"\n"
        lines[i+2] = "  url: $URL\n"
        lines[i+3] = "  sha1: ${SHA1}\n"
        puts "Updated release in #{manifest}"
        changes += 1
        break
      end
    end
    found_ops_releases = true if line.start_with?('  path: /releases/-')
    if found_ops_releases
      found_ops_releases = false if line.chomp == ''
      if line.chomp == '    name: $RELEASE_NAME' && lines[i+2].include?('compile')
        lines[i+1] = "    version: \"$VERSION\"\n"
        lines[i+2] = "    url: $URL\n"
        lines[i+3] = "    sha1: ${SHA1}\n"
        puts "Updated release in #{manifest}"
        changes += 1
        break
      end
    end
  end
  File.open(manifest, 'w') { |f| f.write(lines.join) }
end
puts "Made #{changes} change for $RELEASE_NAME"
EOF

ruby $INTERPOLATE_SCRIPT

pushd $PWD/bosh-deployment-output
  git diff
  git add -A
  git config --global user.email "ci@localhost"
  git config --global user.name "CI Bot"
  git commit -m "Bumping $RELEASE_NAME to version $VERSION"
popd
