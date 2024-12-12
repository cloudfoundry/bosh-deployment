#!/bin/bash

set -eu -o pipefail

STEP() { echo ; echo ; echo "==\\" ; echo "===>" "$@" ; echo "==/" ; echo ; }

bosh_deployment="$(cd "$(dirname "${BASH_SOURCE[0]}")"; cd ..; pwd)"
bosh_deployment_sha="$(cd "${bosh_deployment}"; git rev-parse --short HEAD)"
bosh_stemcell_version="1.651"
cf_deployment="$(cd "${bosh_deployment}"; cd ../cf-deployment; pwd)"

if [ "${PWD##${bosh_deployment}}" != "${PWD}" ] || [ -e docker/create-env.sh ] || [ -e ../docker/create-env.sh ]; then
  echo "It looks like you are running this within the ${bosh_deployment} repository."
  echo "To avoid secrets ending up in this repo, run this from another directory."
  echo

  exit 1
fi

####
STEP "Creating Docker Network"
####

docker_network=random
docker_network_ip=10.244.0.2
docker_network_gw=10.244.0.1
docker_network_cidr=10.244.0.0/20

if [ "$(docker network ls | grep -c "${docker_network}")" -eq 0 ]; then
    echo "Creating docker network: ${docker_network} with range: ${docker_network_cidr}"
    docker network create -d bridge --subnet=${docker_network_cidr} ${docker_network} --attachable 1>/dev/null
else
    echo "Using existing docker network: ${docker_network}"
fi


####
STEP "Creating BOSH Director"
####

docker_host="unix:///var/run/docker.sock"
docker_tls=$(docker context inspect | jq -r '.[0].Endpoints.docker.SkipTLSVerify')

bosh create-env "${bosh_deployment}/bosh.yml" \
  --state "${PWD}/state.json" \
  --ops-file "${bosh_deployment}/docker/cpi.yml" \
  --ops-file "${bosh_deployment}/bosh-lite-docker.yml" \
  --ops-file "${bosh_deployment}/docker/localhost.yml" \
  --ops-file "${bosh_deployment}/docker/unix-sock.yml" \
  --ops-file "${bosh_deployment}/docker/bosh-lite.yml" \
  --ops-file "${bosh_deployment}/uaa.yml" \
  --ops-file "${bosh_deployment}/credhub.yml" \
  --ops-file "${bosh_deployment}/jumpbox-user.yml" \
  --vars-store "${PWD}/creds.yml" \
  --var director_name=bosh-lite \
  --var docker_host="${docker_host}" \
  --var docker_tls="${docker_tls}" \
  --var network="${docker_network}" \
  --var static_ip="${docker_network_ip}" \
  --var internal_ip="localhost" \
  --var internal_gw="${docker_network_gw}" \
  --var internal_cidr="${docker_network_cidr}" "$@"


# Find BOSH director's docker container by the exposed port 6868
director_container_id=$(docker ps --filter "expose=6868" --format "{{.ID}}")
if [ -n "${director_container_id}" ]; then
  echo "Found director container with ID: ${director_container_id} and will modify docker socket permissions"
  docker container exec -it ${director_container_id} bash -c "chmod 777 /var/run/docker.sock"
else
  echo "No director container ID found"
fi


####
STEP "Adding Network Routes (sudo is required)"
####

if [ "$(uname)" = "Darwin" ]; then
  if [ "netstat -rn | grep 10.244" -eq 0 ]; then
    echo "Adding new route "
    sudo route add -net 10.244.0.0/16 192.168.56.6
  else
      echo "Using existing route"
  fi
elif [ "$(uname)" = "Linux" ]; then
  if type ip > /dev/null 2>&1; then
    sudo ip route add 10.244.0.0/16 via 192.168.56.6
  elif type route > /dev/null 2>&1; then
    sudo route add -net 10.244.0.0/16 gw 192.168.56.6
  else
    echo "ERROR adding route"
    exit 1
  fi
fi

####
STEP "Generating .envrc"
####

cat > .envrc <<EOF
export BOSH_ENVIRONMENT=docker
export BOSH_CA_CERT=\$( bosh interpolate ${PWD}/creds.yml --path /director_ssl/ca )
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET=\$( bosh interpolate ${PWD}/creds.yml --path /admin_password )

export CREDHUB_SERVER=https://localhost:8844
export CREDHUB_CA_CERT="\$( bosh interpolate ${PWD}/creds.yml --path=/credhub_tls/ca )
\$( bosh interpolate ${PWD}/creds.yml --path=/uaa_ssl/ca )"
export CREDHUB_CLIENT=credhub-admin
export CREDHUB_SECRET=\$( bosh interpolate ${PWD}/creds.yml --path=/credhub_admin_client_secret )

EOF
echo "export BOSH_DEPLOYMENT_SHA=${bosh_deployment_sha}" >> .envrc


source .envrc

echo Succeeded


####
STEP "Configuring Environment Alias"
####

bosh \
  --environment localhost \
  --ca-cert <( bosh interpolate "${PWD}/creds.yml" --path /director_ssl/ca ) \
  alias-env docker


####
STEP "Updating Cloud Config"
####

bosh -n update-cloud-config "../cf-deployment/iaas-support/bosh-lite/cloud-config.yml" \
  > /dev/null

echo Succeeded

####
STEP "Updating Runtime Config"
####

bosh -n update-runtime-config "${bosh_deployment}/runtime-configs/dns.yml" \
  > /dev/null

echo Succeeded

####
STEP "Completed"
####

echo "Credentials for your environment have been generated and stored in creds.yml."
echo "Details about the state of your VM have been stored in state.json."
echo "You should keep these files for future updates and to destroy your environment."
echo
echo "BOSH Director is now running. You may need to run the following before using bosh commands:"
echo
echo "    source .envrc"
echo

####
STEP "Upload Stemcell"
####

bosh upload-stemcell "https://storage.googleapis.com/bosh-core-stemcells/${bosh_stemcell_version}/bosh-stemcell-${bosh_stemcell_version}-warden-boshlite-ubuntu-jammy-go_agent.tgz"


####
STEP "Deploy CF"
####
 bosh -n -d cf deploy ${cf_deployment}/cf-deployment.yml -o ${cf_deployment}/operations/bosh-lite.yml \
 -o ${cf_deployment}/operations/use-postgres.yml -o ${cf_deployment}/operations/use-compiled-releases.yml \
 -o ${cf_deployment}/operations/enable-cpu-throttling.yml -o ${cf_deployment}/operations/experimental/use-native-garden-runc-runner.yml \
 -o ${cf_deployment}/operations/experimental/disable-interpolate-service-bindings.yml -o ${cf_deployment}/operations/experimental/disable-cf-credhub.yml \
 -v system_domain=bosh-lite.com