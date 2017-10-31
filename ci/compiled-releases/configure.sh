#!/usr/bin/env bash

set -eu

fly -t production set-pipeline \
 -p compiled-releases \
 -c ./pipeline.yml \
 -l <(lpass show --note "concourse:production pipeline:compiled-releases")

fly -t production set-pipeline \
 -p compiled-releases-3468 \
 -c ./pipeline-3468.yml \
 -l <(lpass show --note "concourse:production pipeline:compiled-releases")

fly -t production check-resource -r compiled-releases-3468/bosh-release -f version:263.4.0
fly -t production check-resource -r compiled-releases-3468/uaa-release -f version:52.2
fly -t production check-resource -r compiled-releases-3468/credhub-release -f version:1.6.0
fly -t production check-resource -r compiled-releases-3468/warden-cpi -f version:37
fly -t production check-resource -r compiled-releases-3468/garden-linux -f version:0.342.0
fly -t production check-resource -r compiled-releases-3468/garden-runc -f version:1.9.4
fly -t production check-resource -r compiled-releases-3468/grootfs -f version:0.24.0
fly -t production check-resource -r compiled-releases-3468/ubuntu-trusty-stemcell -f version:3468
