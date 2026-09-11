#!/bin/bash

set -eu

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
cd "${script_dir}/.."

tmp_file="/tmp/bosh-deployment-test"
touch "${tmp_file}"

# create-env's checks need a deployment directory under $HOME: it warns when the
# deployment directory is somewhere the Docker VM cannot see, and the Rosetta
# drop-ins it renders live there. One mktemp root per invocation, removed whole,
# so cleanup never globs over paths this run does not own.
create_env_dir=$(mktemp -d "${HOME}/.bosh-deployment-create-env-check.XXXXXX")

function clean_tmp() {
  rm -f "${tmp_file}"
  rm -f "${tmp_file}."*
  rm -rf -- "${create_env_dir}"
}

trap clean_tmp EXIT

# Only used for tests below. Ignore it.
function bosh() {
  shift 1
  command bosh int --var-errs --var-errs-unused ${@//--state=*/} > /dev/null
}

echo -e "\nCheck YAML syntax\n"
find . -type "f" -name "*.yml" -print | tee /dev/stderr | xargs -n1 bosh interpolate > /dev/null

echo -e "\nUsed compiled releases\n"
grep -r -i bosh-compiled-release-tarballs.s3.amazonaws.com . | grep -v grep | grep -v ./.git

echo -e "\nUsed stemcells\n"
grep -r -i d/stemcells . | grep -v grep | grep -v ./.git

echo -e "\ndocker/create-env\n"

# The script refuses to run inside this checkout, and it writes generated ops
# files into $PWD, so every check below runs from create_env_dir (created above,
# alongside the cleanup that owns it).
create_env="${PWD}/docker/create-env"

if command -v shellcheck > /dev/null; then
  echo "- shellcheck"
  shellcheck "${create_env}"
else
  echo "- shellcheck (SKIPPED: not installed in this image)"
fi

echo "- --help exits 0"
"${create_env}" --help > /dev/null

# Render the create-env invocation for one flavor/host and print just the ops
# files, relative to the checkout, one per line.
function create_env_ops() {
  local os=$1 arch=$2
  shift 2
  (
    cd "${create_env_dir}"
    CREATE_ENV_OS="${os}" CREATE_ENV_ARCH="${arch}" "${create_env}" --dry-run "$@"
  ) | sed -n "s|^  -o ${PWD}/||p"
}

function create_env_dry_run() {
  local os=$1 arch=$2
  shift 2
  (
    cd "${create_env_dir}"
    CREATE_ENV_OS="${os}" CREATE_ENV_ARCH="${arch}" "${create_env}" --dry-run "$@"
  )
}

# Ops-file *ordering* is otherwise completely silent: whether
# misc/use-compiled-resolute-releases.yml lands after credhub.yml, and whether
# docker/use-resolute-rosetta.yml lands after docker/use-resolute.yml, only
# shows up as the wrong release or stemcell URL in the deployed Director.
function assert_ops() {
  local label=$1 expected=$2 actual=$3
  if [ "${expected}" != "${actual}" ]; then
    echo "ERROR: ${label} ops files are not what we expect" >&2
    diff -u <(echo "${expected}") <(echo "${actual}") >&2 || true
    exit 1
  fi
  echo "- ${label} ops files"
}

default_ops="docker/cpi.yml
uaa.yml
credhub.yml
docker/unix-sock.yml
docker/dns.yml
jumpbox-user.yml"

resolute_ops="docker/cpi.yml
docker/use-resolute.yml
uaa.yml
credhub.yml
misc/use-compiled-resolute-releases.yml
docker/unix-sock.yml
docker/dns.yml
jumpbox-user.yml"

resolute_rosetta_ops="docker/cpi.yml
docker/use-resolute.yml
docker/use-resolute-rosetta.yml
uaa.yml
credhub.yml
misc/use-compiled-resolute-releases.yml
docker/unix-sock.yml
docker/dns.yml
jumpbox-user.yml"

assert_ops "default (Linux/x86_64)"  "${default_ops}"  "$(create_env_ops Linux x86_64)"
assert_ops "default (Darwin/arm64)"  "${default_ops}"  "$(create_env_ops Darwin arm64)"
assert_ops "--resolute (Linux/x86_64)" "${resolute_ops}" "$(create_env_ops Linux x86_64 --resolute)"
assert_ops "--resolute (Darwin/arm64)" "${resolute_rosetta_ops}" "$(create_env_ops Darwin arm64 --resolute)"

# --destroy has to delete with exactly what create built, and it reads the
# flavor back out of .create-env/run rather than being told again.
echo "- --destroy renders the same ops files as create"
# Re-render the create record first: each --dry-run rewrites .create-env/run, so
# without this the assertion below depends on which case ran last.
create_env_ops Darwin arm64 --resolute > /dev/null
destroy_ops=$(
  cd "${create_env_dir}"
  CREATE_ENV_OS=Darwin CREATE_ENV_ARCH=arm64 "${create_env}" --destroy --dry-run
)
assert_ops "--destroy after --resolute (Darwin/arm64)" \
  "${resolute_rosetta_ops}" "$(echo "${destroy_ops}" | sed -n "s|^  -o ${PWD}/||p")"
echo "${destroy_ops}" | grep -q '^bosh delete-env ' \
  || { echo "ERROR: --destroy did not render a delete-env invocation" >&2; exit 1; }

# --dry-run has to render what a real run would apply, including the host-specific
# drop-ins. The generated file lives in the deployment directory, so it does not
# show up in the repo-relative ops lists compared above.
echo "- --dry-run renders the Rosetta drop-ins only on Apple Silicon"
if ! create_env_dry_run Darwin arm64 | grep -q 'rosetta-compat\.yml'; then
  echo "ERROR: Darwin/arm64 --dry-run did not render the Rosetta compatibility ops file" >&2
  exit 1
fi
if create_env_dry_run Linux x86_64 | grep -q 'rosetta-compat\.yml'; then
  echo "ERROR: Linux/x86_64 --dry-run rendered a Rosetta compatibility ops file" >&2
  exit 1
fi

# The run record is sourced from inside a function, so the arrays in it have to
# be plain assignments; `declare -a` would scope them to that function and
# --destroy would delete with a different ops stack than it created.
echo "- --destroy replays the caller's -o and -v arguments"
custom_ops="${tmp_file}.custom-ops.yml"
echo '[]' > "${custom_ops}"
create_env_ops Linux x86_64 -o "${custom_ops}" -v custom_check=1 > /dev/null
destroy_custom=$(
  cd "${create_env_dir}"
  CREATE_ENV_OS=Linux CREATE_ENV_ARCH=x86_64 "${create_env}" --destroy --dry-run
)
for expected in "-o ${custom_ops}" "-v custom_check=1"; do
  if ! echo "${destroy_custom}" | grep -q -- "${expected}"; then
    echo "ERROR: --destroy dropped '${expected}' from the replayed invocation" >&2
    echo "${destroy_custom}" >&2
    exit 1
  fi
done

# The script must never carry its own stemcell table -- CI bumps the ops files,
# and create-env reads the pin back out of the interpolated manifest.
echo "- stemcell pins come from the ops files"
function assert_stemcell_url() {
  local label=$1 expected=$2 actual=$3
  [ "${expected}" = "${actual}" ] \
    || { echo "ERROR: ${label} stemcell is '${actual}', expected '${expected}'" >&2; exit 1; }
  echo "  ${label}: ${actual}"
}

noble_url=$(command bosh int bosh.yml -o docker/cpi.yml --path /resource_pools/name=vms/stemcell/url)
resolute_url=$(command bosh int bosh.yml -o docker/cpi.yml -o docker/use-resolute.yml \
  --path /resource_pools/name=vms/stemcell/url)

function create_env_stemcell() {
  local os=$1 arch=$2
  shift 2
  (
    cd "${create_env_dir}"
    CREATE_ENV_OS="${os}" CREATE_ENV_ARCH="${arch}" "${create_env}" --dry-run "$@"
  ) | sed -n 's|^ *stemcell: ||p'
}

assert_stemcell_url "default"   "${noble_url}"    "$(create_env_stemcell Linux x86_64)"
assert_stemcell_url "--resolute" "${resolute_url}" "$(create_env_stemcell Linux x86_64 --resolute)"

# On Apple Silicon the rosetta ops file has to win, and it may only change the
# stemcell -- the compiled-for-resolute docker CPI from use-resolute.yml stays.
rosetta_url=$(command bosh int bosh.yml -o docker/cpi.yml -o docker/use-resolute.yml \
  -o docker/use-resolute-rosetta.yml --path /resource_pools/name=vms/stemcell/url)
assert_stemcell_url "--resolute on Apple Silicon" \
  "${rosetta_url}" "$(create_env_stemcell Darwin arm64 --resolute)"
[ "${rosetta_url}" != "${resolute_url}" ] \
  || { echo "ERROR: docker/use-resolute-rosetta.yml did not override the stemcell" >&2; exit 1; }
cpi_url=$(command bosh int bosh.yml -o docker/cpi.yml -o docker/use-resolute.yml \
  -o docker/use-resolute-rosetta.yml --path /releases/name=bosh-docker-cpi/url)
case "${cpi_url}" in
  *ubuntu-resolute*) echo "  --resolute on Apple Silicon keeps the resolute docker CPI" ;;
  *) echo "ERROR: rosetta ops file clobbered the resolute docker CPI: ${cpi_url}" >&2; exit 1 ;;
esac

echo "- an explicit --stemcell overrides the pin"
override=$(create_env_stemcell Darwin arm64 --resolute --stemcell https://example.com/my.tgz)
[ "${override}" = "https://example.com/my.tgz" ] \
  || { echo "ERROR: --stemcell did not win, got '${override}'" >&2; exit 1; }

echo -e "\nExamples\n"

echo "- AWS"
bosh create-env bosh.yml \
  -o aws/cpi.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v internal_ip=test \
  -v access_key_id=test \
  -v secret_access_key=test \
  -v az=test \
  -v region=test \
  -v default_key_name=test \
  -v default_security_groups=[test] \
  -v subnet_id=test

echo "- AWS with signed URLs"
bosh create-env bosh.yml \
  -o aws/cpi.yml \
  -o misc/blobstore-signed-urls.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v internal_ip=test \
  -v access_key_id=test \
  -v secret_access_key=test \
  -v az=test \
  -v region=test \
  -v default_key_name=test \
  -v default_security_groups=[test] \
  -v subnet_id=test

echo "- AWS with UAA"
bosh create-env bosh.yml \
  -o aws/cpi.yml \
  -o uaa.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v internal_ip=test \
  -v access_key_id=test \
  -v secret_access_key=test \
  -v az=test \
  -v region=test \
  -v default_key_name=test \
  -v default_security_groups=[test] \
  -v subnet_id=test

echo "- AWS with UAA + config-server"
bosh create-env bosh.yml \
  -o aws/cpi.yml \
  -o uaa.yml \
  -o misc/config-server.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v internal_ip=test \
  -v access_key_id=test \
  -v secret_access_key=test \
  -v az=test \
  -v region=test \
  -v default_key_name=test \
  -v default_security_groups=[test] \
  -v subnet_id=test

echo "- AWS with UAA + CredHub + Turbulence"
bosh create-env bosh.yml \
  -o aws/cpi.yml \
  -o uaa.yml \
  -o credhub.yml \
  -o turbulence.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v internal_ip=test \
  -v access_key_id=test \
  -v secret_access_key=test \
  -v az=test \
  -v region=test \
  -v default_key_name=test \
  -v default_security_groups=[test] \
  -v subnet_id=test \
  -v credhub_encryption_password=test

echo "- AWS with UAA + CredHub + Turbulence + configurable certificate duration"
bosh create-env bosh.yml \
  -o misc/certificate-duration/bosh.yml \
  -o aws/cpi.yml \
  -o uaa.yml \
  -o credhub.yml \
  -o misc/certificate-duration/uaa.yml \
  -o misc/certificate-duration/credhub.yml \
  -o turbulence.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v internal_ip=test \
  -v access_key_id=test \
  -v secret_access_key=test \
  -v az=test \
  -v region=test \
  -v default_key_name=test \
  -v default_security_groups=[test] \
  -v subnet_id=test \
  -v credhub_encryption_password=test \
  -v certificate_duration=3650

echo "- AWS with UAA for BOSH development"
bosh deploy bosh.yml \
  -o aws/cpi.yml \
  -o uaa.yml \
  -o misc/bosh-dev.yml \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_ip=test \
  -v access_key_id=test \
  -v secret_access_key=test \
  -v region=test \
  -v default_key_name=test \
  -v default_security_groups=[test]

echo "- AWS with external db and dns"
bosh create-env bosh.yml \
  -o aws/cpi.yml \
  -o misc/external-db.yml \
  -o misc/dns.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v internal_ip=test \
  -v internal_dns=[8.8.8.8] \
  -v access_key_id=test \
  -v secret_access_key=test \
  -v az=test \
  -v region=test \
  -v default_key_name=test \
  -v default_security_groups=[test] \
  -v subnet_id=test \
  -v external_db_host=test \
  -v external_db_port=test \
  -v external_db_user=test \
  -v external_db_password=test \
  -v external_db_adapter=test \
  -v external_db_name=test

echo "- AWS with UAA + CredHub + External dbs for all"
bosh create-env bosh.yml \
  -o aws/cpi.yml \
  -o uaa.yml \
  -o credhub.yml \
  -o misc/external-db.yml \
  -o misc/external-db-uaa.yml \
  -o misc/external-db-credhub.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v internal_ip=test \
  -v access_key_id=test \
  -v secret_access_key=test \
  -v az=test \
  -v region=test \
  -v default_key_name=test \
  -v default_security_groups=[test] \
  -v subnet_id=test \
  -v credhub_encryption_password=test \
  -v external_db_host=test \
  -v external_db_port=test \
  -v external_db_user=test \
  -v external_db_password=test \
  -v external_db_adapter=test \
  -v external_db_name=test \
  -v external_db_host_credhub=test \
  -v external_db_port_credhub=test \
  -v external_db_name_credhub=test \
  -v external_db_user_credhub=test \
  -v external_db_password_credhub=test \
  -v external_db_require_tls_credhub=test \
  -v external_db_adapter_credhub=test \
  -v external_db_host_uaa=test \
  -v external_db_port_uaa=test \
  -v external_db_user_uaa=test \
  -v external_db_name_uaa=test \
  -v external_db_password_uaa=test \
  -v external_db_scheme_uaa=test

echo "- AWS (cloud-config)"
bosh update-cloud-config aws/cloud-config.yml \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v az=test \
  -v subnet_id=test

echo "- GCP"
bosh create-env bosh.yml \
  -o gcp/cpi.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v internal_ip=test \
  -v gcp_credentials_json=test \
  -v project_id=test \
  -v zone=test \
  -v tags=[internal,no-ip] \
  -v network=test \
  -v subnetwork=test

echo "- GCP with UAA"
bosh create-env bosh.yml \
  -o gcp/cpi.yml \
  -o uaa.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v internal_ip=test \
  -v gcp_credentials_json=test \
  -v project_id=test \
  -v zone=test \
  -v tags=[internal,no-ip] \
  -v network=test \
  -v subnetwork=test

echo "- GCP with UAA on external IP"
bosh create-env bosh.yml \
  -o gcp/cpi.yml \
  -o uaa.yml \
  -o external-ip-not-recommended.yml \
  -o external-ip-not-recommended-uaa.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v internal_ip=test \
  -v gcp_credentials_json=test \
  -v project_id=test \
  -v zone=test \
  -v tags=[internal,no-ip] \
  -v network=test \
  -v subnetwork=test \
  -v external_ip=test

echo "- GCP with BOSH Lite"
bosh create-env bosh.yml \
  -o gcp/cpi.yml \
  -o bosh-lite.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v internal_ip=test \
  -v gcp_credentials_json=test \
  -v project_id=test \
  -v zone=test \
  -v tags=[internal,no-ip] \
  -v network=test \
  -v subnetwork=test

echo "- GCP with BOSH Lite on Docker"
bosh create-env bosh.yml \
  -o gcp/cpi.yml \
  -o bosh-lite-docker.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v internal_ip=test \
  -v gcp_credentials_json=test \
  -v project_id=test \
  -v zone=test \
  -v tags=[internal,no-ip] \
  -v network=test \
  -v subnetwork=test

echo "- GCP with external db"
bosh create-env bosh.yml \
  -o gcp/cpi.yml \
  -o misc/external-db.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v internal_ip=test \
  -v gcp_credentials_json=test \
  -v project_id=test \
  -v zone=test \
  -v tags=[internal,no-ip] \
  -v network=test \
  -v subnetwork=test \
  -v external_db_host=test \
  -v external_db_port=test \
  -v external_db_user=test \
  -v external_db_password=test \
  -v external_db_adapter=test \
  -v external_db_name=test

echo "- GCP (cloud-config)"
bosh update-cloud-config gcp/cloud-config.yml \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v zone=test \
  -v network=test \
  -v subnetwork=test \
  -v tags=[tag]

echo "- Openstack"
bosh create-env bosh.yml \
  -o openstack/cpi.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v internal_ip=test \
  -v auth_url=test \
  -v az=test \
  -v default_key_name=test \
  -v default_security_groups=test \
  -v net_id=test \
  -v openstack_password=test \
  -v openstack_username=test \
  -v openstack_domain=test \
  -v openstack_project=test \
  -v region=test

echo "- Openstack (cloud-config)"
bosh update-cloud-config openstack/cloud-config.yml \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v az=test \
  -v net_id=test

echo "- vSphere"
bosh create-env bosh.yml \
  -o vsphere/cpi.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v internal_ip=test \
  -v network_name=test \
  -v vcenter_dc=test \
  -v vcenter_ds=test \
  -v vcenter_ip=test \
  -v vcenter_user=test \
  -v vcenter_password=test \
  -v vcenter_templates=test \
  -v vcenter_vms=test \
  -v vcenter_disks=test \
  -v vcenter_cluster=test

echo "- vCloud"
bosh create-env bosh.yml \
  -o vcloud/cpi.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v internal_ip=test \
  -v network_name=test \
  -v vcloud_url=test \
  -v vcloud_user=test \
  -v vcloud_password=test \
  -v vcd_org=test \
  -v vcd_name=test

echo "- vSphere (cloud-config)"
bosh update-cloud-config vsphere/cloud-config.yml \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v network_name=test \
  -v vcenter_cluster=test

echo "- Azure"
bosh create-env bosh.yml \
  -o azure/cpi.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=10.0.0.0/24 \
  -v internal_gw=10.0.0.1 \
  -v internal_ip=10.0.0.4 \
  -v vnet_name=boshvnet-crp \
  -v subnet_name=Bosh \
  -v subscription_id=test \
  -v tenant_id=test \
  -v client_id=test \
  -v client_secret=test \
  -v resource_group_name=test \
  -v default_security_group=nsg-bosh

echo "- Azure (custom-environment)"
bosh create-env bosh.yml \
  -o azure/cpi.yml \
  -o azure/custom-environment.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=10.0.0.0/24 \
  -v internal_gw=10.0.0.1 \
  -v internal_ip=10.0.0.4 \
  -v vnet_name=boshvnet-crp \
  -v subnet_name=Bosh \
  -v environment=AzureChinaCloud \
  -v subscription_id=test \
  -v tenant_id=test \
  -v client_id=test \
  -v client_secret=test \
  -v resource_group_name=test \
  -v default_security_group=nsg-bosh

echo "- Azure (managed-identity)"
bosh create-env bosh.yml \
  -o azure/cpi.yml \
  -o azure/use-managed-identity.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=10.0.0.0/24 \
  -v internal_gw=10.0.0.1 \
  -v internal_ip=10.0.0.4 \
  -v vnet_name=boshvnet-crp \
  -v subnet_name=Bosh \
  -v subscription_id=test \
  -v azure-managed-identity=test \
  -v resource_group_name=test \
  -v default_security_group=nsg-bosh

echo "- Azure (managed-identity-for-bosh-managed-vms)"
bosh create-env bosh.yml \
  -o azure/cpi.yml \
  -o azure/use-managed-identity.yml \
  -o azure/use-managed-identity-for-bosh-managed-vms.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=10.0.0.0/24 \
  -v internal_gw=10.0.0.1 \
  -v internal_ip=10.0.0.4 \
  -v vnet_name=boshvnet-crp \
  -v subnet_name=Bosh \
  -v subscription_id=test \
  -v azure-managed-identity=test \
  -v resource_group_name=test \
  -v default_security_group=nsg-bosh

echo "- Azure (cloud-config)"
bosh update-cloud-config azure/cloud-config.yml \
  -v internal_cidr=10.0.16.0/24 \
  -v internal_gw=10.0.16.1 \
  -v vnet_name=boshvnet-crp \
  -v subnet_name=CloudFoundry \
  -v security_group=nsg-cf

echo "- VirtualBox with BOSH Lite"
bosh create-env bosh.yml \
  -o virtualbox/cpi.yml \
  -o bosh-lite.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=vbox \
  -v internal_ip=192.168.56.6 \
  -v internal_gw=192.168.56.1 \
  -v internal_cidr=192.168.56.0/24

echo "- VirtualBox with IPv6 (remote)"
bosh create-env bosh.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -o virtualbox/cpi.yml \
  -o virtualbox/outbound-network.yml \
  -o jumpbox-user.yml \
  -o uaa.yml \
  -o credhub.yml \
  -o misc/ipv6/bosh.yml \
  -o misc/ipv6/uaa.yml \
  -o misc/ipv6/credhub.yml \
  -o virtualbox/remote.yml \
  -o virtualbox/ipv6/cpi.yml \
  -o virtualbox/ipv6/remote.yml \
  -v director_name=vbox \
  -v internal_cidr=fd7a:eeed:e696:969f:0000:0000:0000:0000/64 \
  -v internal_gw=fd7a:eeed:e696:969f:0000:0000:0000:0001 \
  -v internal_ip=fd7a:eeed:e696:969f:0000:0000:0000:0004 \
  -v outbound_network_name=NatNetwork \
  -v vbox_host=fd7a:eeed:e696:969f:0000:0000:0000:0001 \
  -v vbox_username=test

echo "- VirtualBox with BOSH Lite with garden-runc"
bosh create-env bosh.yml \
  -o virtualbox/cpi.yml \
  -o bosh-lite.yml \
  -o bosh-lite-runc.yml \
  -o jumpbox-user.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=vbox \
  -v internal_ip=192.168.56.6 \
  -v internal_gw=192.168.56.1 \
  -v internal_cidr=192.168.56.0/24

echo "- Warden (cloud-config)"
bosh update-cloud-config warden/cloud-config.yml

echo "- Docker"
bosh create-env bosh.yml \
  -o docker/cpi.yml \
  -o jumpbox-user.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=docker \
  -v internal_cidr=10.245.0.0/16 \
  -v internal_gw=10.245.0.1 \
  -v internal_ip=10.245.0.10 \
  -v docker_host=tcp://192.168.56.8:4243 \
  --var-file docker_tls.ca=$tmp_file \
  --var-file docker_tls.certificate=$tmp_file \
  --var-file docker_tls.private_key=$tmp_file \
  -v network=net3

echo "- Docker via UNIX sock"
bosh create-env bosh.yml \
  -o docker/cpi.yml \
  -o docker/unix-sock.yml \
  -o jumpbox-user.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=docker \
  -v internal_cidr=10.245.0.0/16 \
  -v internal_gw=10.245.0.1 \
  -v internal_ip=10.245.0.10 \
  -v docker_host=unix:///var/run/docker.sock \
  -v network=net3

echo "- Docker (cloud-config)"
bosh update-cloud-config docker/cloud-config.yml -v network=net3

echo "- Secondary CPIs"
bosh create-env bosh.yml \
  -o aws/cpi.yml \
  -o docker/cpi-secondary.yml \
  -o azure/cpi-secondary.yml \
  -o vsphere/cpi-secondary.yml \
  -o openstack/cpi-secondary.yml \
  --state=$tmp_file \
  --vars-store $(mktemp ${tmp_file}.XXXXXX) \
  -v director_name=test \
  -v internal_cidr=test \
  -v internal_gw=test \
  -v internal_ip=test \
  -v access_key_id=test \
  -v secret_access_key=test \
  -v az=test \
  -v region=test \
  -v default_key_name=test \
  -v default_security_groups=[test] \
  -v subnet_id=test
