#!/usr/bin/env bash
# Deploy / update / delete the BOSH director for THIS environment on Proxmox VE,
# using the PUBLISHED bosh-proxmox-cpi release (no source build), with
# state.json + creds.yml persisted to Ceph S3 (or any S3-compatible store).
#
# This is a self-contained environment deployment. It only READS files that ship
# in the repo (upstream bosh.yml + jumpbox-user.yml, and the additive
# proxmox/*.yml ops files) via `-o`/`-l` — it never edits them — so pulling
# upstream cloudfoundry/bosh-deployment stays merge-clean.
#
# Usage:
#   deployments/proxmox/deploy.sh [deploy|delete|cloud-config|env]
#     deploy        (default) create-env — bootstrap or update the director
#     delete        delete-env — tear the director down
#     cloud-config  upload proxmox/cloud-config.yml to the running director
#     env           print the BOSH_* env vars to talk to the director (eval it)
#
# Configuration comes from EITHER:
#   * deployments/proxmox/vars.yml   (local; copied from vars.tmpl.yml), or
#   * environment variables          (CI secrets — see the block below)
# S3 settings and the release pin always come from the environment.
#
# Required env (or provide the proxmox_*/internal_* keys via vars.yml):
#   PROXMOX_API_URL PROXMOX_API_TOKEN PROXMOX_NODE
#   PROXMOX_VM_STORAGE PROXMOX_IMPORT_STORAGE
#   DIRECTOR_INTERNAL_CIDR DIRECTOR_INTERNAL_GW DIRECTOR_INTERNAL_IP
# Always required (for state persistence):
#   STATE_S3_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_S3_ENDPOINT
# Optional env:
#   ACTION=deploy|delete            (default: the CLI arg, else deploy)
#   DIRECTOR_NAME                   (default bosh-proxmox)
#   PROXMOX_BRIDGE                  (default vmbr0)
#   PROXMOX_INSECURE_SKIP_VERIFY    (default true)
#   STATE_S3_PREFIX                 (default director)
#   AWS_DEFAULT_REGION              (default us-east-1)
#   CPI_RELEASE_VERSION             (default 1.0.0)
#   CPI_RELEASE_SHA1                (default the v1.0.0 tarball sha1)
#   CPI_RELEASE_URL                 (default https://cdn.cf-apps.io/...1.0.0.tgz)
#   UPLOAD_CLOUD_CONFIG=true        after deploy, apply proxmox/cloud-config.yml
#   UPLOAD_STEMCELL=true            after deploy, upload STEMCELL_URL
#   STEMCELL_URL                    (default jammy openstack-kvm)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"   # repo root — ops files are referenced from here
cd "$root"

action="${ACTION:-${1:-deploy}}"
state="$here/state.json"
creds="$here/creds.yml"
vars="$here/vars.yml"

# --- published release pin (overridable) --------------------------------------
CPI_RELEASE_VERSION="${CPI_RELEASE_VERSION:-1.0.0}"
CPI_RELEASE_SHA1="${CPI_RELEASE_SHA1:-facc1ef0af0e421508b2db5f86f82b3726f4e030}"
CPI_RELEASE_URL="${CPI_RELEASE_URL:-https://cdn.cf-apps.io/bosh-proxmox-cpi-${CPI_RELEASE_VERSION}.tgz}"

# --- BOSH CLI (Homebrew ships it as "bosh-cli") -------------------------------
if command -v bosh >/dev/null 2>&1; then bosh=bosh
elif command -v bosh-cli >/dev/null 2>&1; then bosh=bosh-cli
else echo "FATAL: the BOSH CLI is not installed (brew install cloudfoundry/tap/bosh-cli)" >&2; exit 2; fi

req() { [ -n "${!1:-}" ] || { echo "FATAL: missing required env var $1" >&2; exit 2; }; }

# --- ops files (read-only; reused, never edited) ------------------------------
ops=(
  bosh.yml
  -o proxmox/cpi.yml
  -o proxmox/use-published-release.yml
  -o proxmox/cpi-release-url.yml
  -o jumpbox-user.yml
  --state="$state" --vars-store="$creds"
  -v proxmox_cpi_version="$CPI_RELEASE_VERSION"
  -v proxmox_cpi_sha1="$CPI_RELEASE_SHA1"
  -v proxmox_cpi_url="$CPI_RELEASE_URL"
)

# --- director + proxmox vars: from vars.yml if present, else from env ---------
if [ -f "$vars" ]; then
  ops+=( -l "$vars" )
  director_ip="$("$bosh" int "$vars" --path /internal_ip)"
else
  for v in PROXMOX_API_URL PROXMOX_API_TOKEN PROXMOX_NODE PROXMOX_VM_STORAGE \
           PROXMOX_IMPORT_STORAGE DIRECTOR_INTERNAL_CIDR DIRECTOR_INTERNAL_GW \
           DIRECTOR_INTERNAL_IP; do req "$v"; done
  director_ip="$DIRECTOR_INTERNAL_IP"
  ops+=(
    -v director_name="${DIRECTOR_NAME:-bosh-proxmox}"
    -v internal_cidr="$DIRECTOR_INTERNAL_CIDR"
    -v internal_gw="$DIRECTOR_INTERNAL_GW"
    -v internal_ip="$DIRECTOR_INTERNAL_IP"
    -v proxmox_api_url="$PROXMOX_API_URL"
    -v proxmox_api_token="$PROXMOX_API_TOKEN"
    -v proxmox_node="$PROXMOX_NODE"
    -v proxmox_vm_storage="$PROXMOX_VM_STORAGE"
    -v proxmox_import_storage="$PROXMOX_IMPORT_STORAGE"
    -v proxmox_bridge="${PROXMOX_BRIDGE:-vmbr0}"
    -v proxmox_insecure_skip_verify="${PROXMOX_INSECURE_SKIP_VERIFY:-true}"
  )
fi

# --- S3 (Ceph RGW) state store ------------------------------------------------
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
STATE_S3_PREFIX="${STATE_S3_PREFIX:-director}"
aws_s3() { aws ${AWS_S3_ENDPOINT:+--endpoint-url "$AWS_S3_ENDPOINT"} s3 "$@"; }
s3_uri="s3://${STATE_S3_BUCKET:-}/$STATE_S3_PREFIX"

# push a file to S3: try SSE-S3, fall back to plain upload, fail LOUD (never
# silently drop creds/state — that is the whole point of this step).
put() {
  local f="$1" name; name="$(basename "$f")"
  [ -f "$f" ] || return 0
  if aws_s3 cp "$f" "$s3_uri/$name" --sse AES256 2>/dev/null; then echo "  pushed $name (SSE-S3)"; return 0; fi
  echo "  note: SSE-S3 rejected for $name; retrying without --sse (bucket/pool must be private + encrypted at rest)" >&2
  if aws_s3 cp "$f" "$s3_uri/$name"; then echo "  pushed $name"; return 0; fi
  echo "  ERROR: failed to upload $name to $s3_uri/ — STATE NOT PERSISTED" >&2
  return 1
}

# --- director BOSH_* env (for verify / cloud-config / env action) -------------
director_env() {
  cat <<EOF
export BOSH_ENVIRONMENT=$director_ip
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET=$("$bosh" int "$creds" --path /admin_password)
export BOSH_CA_CERT="$("$bosh" int "$creds" --path /director_ssl/ca)"
EOF
}

case "$action" in
  deploy|delete)
    req STATE_S3_BUCKET; req AWS_ACCESS_KEY_ID; req AWS_SECRET_ACCESS_KEY; req AWS_S3_ENDPOINT

    echo "== pulling existing state from $s3_uri =="
    aws_s3 cp "$s3_uri/state.json" "$state" 2>/dev/null || echo "  no existing state.json (first run)"
    aws_s3 cp "$s3_uri/creds.yml"  "$creds" 2>/dev/null || echo "  no existing creds.yml (first run)"

    # Always push state back — even on a partial create-env failure, so a
    # half-created director VM recorded in state.json is never orphaned.
    push_state() {
      echo "== pushing state to $s3_uri =="
      put "$state" || true
      put "$creds" || true
      if [ "$action" = delete ] && [ ! -f "$state" ]; then
        aws_s3 rm "$s3_uri/state.json" 2>/dev/null || true
        aws_s3 rm "$s3_uri/creds.yml"  2>/dev/null || true
      fi
    }
    trap push_state EXIT

    if [ "$action" = delete ]; then
      echo "== delete-env: tearing down the director =="
      "$bosh" delete-env "${ops[@]}"
      echo "DIRECTOR DELETED"
      exit 0
    fi

    echo "== create-env: deploying CPI v$CPI_RELEASE_VERSION director at $director_ip =="
    "$bosh" create-env "${ops[@]}"

    echo "== verifying the director responds =="
    eval "$(director_env)"
    "$bosh" -e "$director_ip" env

    if [ "${UPLOAD_CLOUD_CONFIG:-}" = true ]; then
      echo "== applying cloud-config =="
      if [ -f "$vars" ]; then
        "$bosh" -n update-cloud-config proxmox/cloud-config.yml -l "$vars"
      else
        "$bosh" -n update-cloud-config proxmox/cloud-config.yml \
          -v internal_cidr="$DIRECTOR_INTERNAL_CIDR" \
          -v internal_gw="$DIRECTOR_INTERNAL_GW" \
          -v proxmox_bridge="${PROXMOX_BRIDGE:-vmbr0}"
      fi
    fi

    if [ "${UPLOAD_STEMCELL:-}" = true ]; then
      echo "== uploading stemcell =="
      "$bosh" -n upload-stemcell "${STEMCELL_URL:-https://bosh.io/d/stemcells/bosh-openstack-kvm-ubuntu-jammy-go_agent}"
    fi

    echo
    echo "============================================================"
    echo "DIRECTOR DEPLOYED — $director_ip (CPI v$CPI_RELEASE_VERSION)"
    echo "state + creds persisted to $s3_uri/"
    echo "============================================================"
    ;;

  cloud-config)
    [ -f "$creds" ] || { echo "ERROR: $creds missing — deploy first." >&2; exit 1; }
    eval "$(director_env)"
    if [ -f "$vars" ]; then
      "$bosh" -n update-cloud-config proxmox/cloud-config.yml -l "$vars"
    else
      "$bosh" -n update-cloud-config proxmox/cloud-config.yml \
        -v internal_cidr="$DIRECTOR_INTERNAL_CIDR" \
        -v internal_gw="$DIRECTOR_INTERNAL_GW" \
        -v proxmox_bridge="${PROXMOX_BRIDGE:-vmbr0}"
    fi
    ;;

  env)
    [ -f "$creds" ] || { echo "ERROR: $creds missing — deploy first." >&2; exit 1; }
    director_env
    ;;

  *)
    echo "Unknown action: $action (use deploy|delete|cloud-config|env)" >&2
    exit 1
    ;;
esac
