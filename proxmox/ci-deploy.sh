#!/usr/bin/env bash
# CI entrypoint: deploy / update / delete a BOSH director on Proxmox VE, with
# state.json + creds.yml persisted in S3-compatible object storage (S3/MinIO)
# so the director survives across CI runs.
#
# Unlike proxmox/deploy.sh (local, reads proxmox/vars.yml), this reads all
# configuration from environment variables (CI secrets) and syncs state to a
# bucket. The state upload runs on EXIT even when create-env fails partway, so a
# half-created director VM recorded in state.json is never orphaned.
#
# Required env:
#   PROXMOX_API_URL PROXMOX_API_TOKEN PROXMOX_NODE
#   PROXMOX_VM_STORAGE PROXMOX_IMPORT_STORAGE
#   DIRECTOR_INTERNAL_CIDR DIRECTOR_INTERNAL_GW DIRECTOR_INTERNAL_IP
#   STATE_S3_BUCKET            e.g. bosh-director-state
#   AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
# Optional env:
#   ACTION=deploy|delete       (default deploy)
#   DIRECTOR_NAME              (default bosh-proxmox)
#   PROXMOX_BRIDGE            (default vmbr0)
#   PROXMOX_INSECURE_SKIP_VERIFY (default true)
#   STEMCELL_URL              (default jammy openstack-kvm)
#   STATE_S3_PREFIX           key prefix in the bucket (default director)
#   AWS_DEFAULT_REGION        (default us-east-1)
#   AWS_S3_ENDPOINT           set for MinIO / non-AWS, e.g. https://minio.lan:9000
#   PROXMOX_CPI_DIR           CPI checkout to build (default ./bosh-proxmox-cpi)
#   UPLOAD_CLOUD_CONFIG=true  after deploy, apply proxmox/cloud-config.yml
#   UPLOAD_STEMCELL=true      after deploy, upload STEMCELL_URL to the director
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# --- required config ----------------------------------------------------------
req() { [ -n "${!1:-}" ] || { echo "FATAL: missing required env var $1" >&2; exit 2; }; }
for v in PROXMOX_API_URL PROXMOX_API_TOKEN PROXMOX_NODE PROXMOX_VM_STORAGE \
         PROXMOX_IMPORT_STORAGE DIRECTOR_INTERNAL_CIDR DIRECTOR_INTERNAL_GW \
         DIRECTOR_INTERNAL_IP STATE_S3_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  req "$v"
done

ACTION="${ACTION:-deploy}"
DIRECTOR_NAME="${DIRECTOR_NAME:-bosh-proxmox}"
BRIDGE="${PROXMOX_BRIDGE:-vmbr0}"
INSECURE="${PROXMOX_INSECURE_SKIP_VERIFY:-true}"
STEMCELL_URL="${STEMCELL_URL:-https://bosh.io/d/stemcells/bosh-openstack-kvm-ubuntu-jammy-go_agent}"
STATE_S3_PREFIX="${STATE_S3_PREFIX:-director}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
cpi_dir="$(cd "${PROXMOX_CPI_DIR:-$root/bosh-proxmox-cpi}" && pwd)"

# aws CLI with optional custom endpoint (MinIO). SSE-S3 on upload; rely on a
# private, encrypted bucket for creds.yml at-rest protection.
aws_s3() { aws ${AWS_S3_ENDPOINT:+--endpoint-url "$AWS_S3_ENDPOINT"} s3 "$@"; }
s3_uri="s3://$STATE_S3_BUCKET/$STATE_S3_PREFIX"

state="$root/state.json"
creds="$root/creds.yml"

# --- BOSH CLI (installed by the workflow; Homebrew names it bosh-cli) ---------
if command -v bosh >/dev/null 2>&1; then bosh=bosh
elif command -v bosh-cli >/dev/null 2>&1; then bosh=bosh-cli
else echo "FATAL: bosh CLI not found on runner" >&2; exit 2; fi

# --- pull existing state from the bucket (first deploy has none) ---------------
echo "== pulling state from $s3_uri =="
aws_s3 cp "$s3_uri/state.json" "$state" 2>/dev/null || echo "  no existing state.json (first deploy)"
aws_s3 cp "$s3_uri/creds.yml"  "$creds" 2>/dev/null || echo "  no existing creds.yml (first deploy)"

# --- always push state back, even on partial failure --------------------------
push_state() {
  echo "== pushing state back to $s3_uri =="
  [ -f "$state" ] && aws_s3 cp "$state" "$s3_uri/state.json" --sse AES256 || true
  # creds.yml is deleted by a successful delete-env; only push when present
  [ -f "$creds" ] && aws_s3 cp "$creds" "$s3_uri/creds.yml" --sse AES256 || true
  # after a successful delete, clear the remote objects so the next deploy is clean
  if [ "$ACTION" = delete ] && [ ! -f "$state" ]; then
    aws_s3 rm "$s3_uri/state.json" 2>/dev/null || true
    aws_s3 rm "$s3_uri/creds.yml"  2>/dev/null || true
  fi
}
trap push_state EXIT

# --- vendor the golang package into the CPI checkout (one-time per checkout) ---
if [ ! -d "$cpi_dir/packages/golang-1-linux" ]; then
  echo "== vendoring golang package into CPI at $cpi_dir =="
  ( cd "$cpi_dir" && ./scripts/create-release.sh >/dev/null )
fi

common_args=(
  bosh.yml
  -o proxmox/cpi.yml
  -o jumpbox-user.yml
  --state="$state" --vars-store="$creds"
  -v director_name="$DIRECTOR_NAME"
  -v internal_cidr="$DIRECTOR_INTERNAL_CIDR"
  -v internal_gw="$DIRECTOR_INTERNAL_GW"
  -v internal_ip="$DIRECTOR_INTERNAL_IP"
  -v proxmox_cpi_release="file://$cpi_dir"
  -v proxmox_api_url="$PROXMOX_API_URL"
  -v proxmox_api_token="$PROXMOX_API_TOKEN"
  -v proxmox_node="$PROXMOX_NODE"
  -v proxmox_vm_storage="$PROXMOX_VM_STORAGE"
  -v proxmox_import_storage="$PROXMOX_IMPORT_STORAGE"
  -v proxmox_bridge="$BRIDGE"
  -v proxmox_insecure_skip_verify="$INSECURE"
)

if [ "$ACTION" = delete ]; then
  echo "== delete-env: tearing down the director =="
  "$bosh" delete-env "${common_args[@]}"
  echo "DIRECTOR DELETED"
  exit 0
fi

echo "== create-env: bootstrapping/updating the director =="
"$bosh" create-env "${common_args[@]}"

# --- verify + optional post-deploy wiring -------------------------------------
export BOSH_ENVIRONMENT="$DIRECTOR_INTERNAL_IP"
export BOSH_CLIENT=admin
BOSH_CLIENT_SECRET="$("$bosh" int "$creds" --path /admin_password)"; export BOSH_CLIENT_SECRET
BOSH_CA_CERT="$("$bosh" int "$creds" --path /director_ssl/ca)"; export BOSH_CA_CERT

echo "== verifying the director responds =="
"$bosh" -e "$DIRECTOR_INTERNAL_IP" env

if [ "${UPLOAD_CLOUD_CONFIG:-}" = true ]; then
  echo "== applying cloud-config =="
  "$bosh" -n update-cloud-config proxmox/cloud-config.yml \
    -v internal_cidr="$DIRECTOR_INTERNAL_CIDR" \
    -v internal_gw="$DIRECTOR_INTERNAL_GW" \
    -v proxmox_bridge="$BRIDGE"
fi

if [ "${UPLOAD_STEMCELL:-}" = true ]; then
  echo "== uploading stemcell =="
  "$bosh" -n upload-stemcell "$STEMCELL_URL"
fi

echo
echo "============================================================"
echo "DIRECTOR DEPLOYED — $DIRECTOR_INTERNAL_IP ($DIRECTOR_NAME)"
echo "============================================================"
