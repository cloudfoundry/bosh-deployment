#!/usr/bin/env bash

set -eu

fly -t production set-pipeline -n \
 -p compiled-releases-xenial-97 \
 -c ./pipeline-xenial-97.yml \
 -l <(lpass show --note "concourse:production pipeline:compiled-releases")

fly -t production check-resource -r compiled-releases-xenial-97/bosh-release -f version:267.3.0
fly -t production check-resource -r compiled-releases-xenial-97/ubuntu-xenial-stemcell -f version:97.3

fly -t production set-pipeline -n \
 -p compiled-releases-3586 \
 -c ./pipeline-3586.yml \
 -l <(lpass show --note "concourse:production pipeline:compiled-releases")

fly -t production check-resource -r compiled-releases-3586/bosh-release -f version:266.7.0
fly -t production check-resource -r compiled-releases-3586/uaa-release -f version:52.2
fly -t production check-resource -r compiled-releases-3586/credhub-release -f version:1.6.0
fly -t production check-resource -r compiled-releases-3586/bpm-release -f version:0.6.0
fly -t production check-resource -r compiled-releases-3586/backup-and-restore-sdk-release -f version:1.2.1
fly -t production check-resource -r compiled-releases-3586/ubuntu-trusty-stemcell -f version:3541
fly -t production check-resource -r compiled-releases-3586/warden-cpi -f version:37
fly -t production check-resource -r compiled-releases-3586/garden-linux -f version:0.342.0
fly -t production check-resource -r compiled-releases-3586/garden-runc -f version:1.9.4
fly -t production check-resource -r compiled-releases-3586/grootfs -f version:0.24.0
