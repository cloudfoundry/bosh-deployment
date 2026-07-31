#!/usr/bin/env bash
# Deploy / update / delete a BOSH director on Proxmox VE from this fork.
#
# Usage:
#   proxmox/deploy.sh [deploy|delete|cloud-config|env]
#     deploy        (default) bosh create-env — bootstrap or update the director
#     delete        bosh delete-env — tear the director down
#     cloud-config  upload proxmox/cloud-config.yml to the running director
#     env           print the BOSH_* env vars to talk to the director (eval it)
#
# Config:
#   proxmox/vars.yml         your filled-in variables (copied from vars.tmpl.yml)
#   PROXMOX_CPI_DIR=<path>   the bosh-proxmox-cpi checkout (default ../bosh-proxmox-cpi)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

cpi_dir="${PROXMOX_CPI_DIR:-$repo_root/../bosh-proxmox-cpi}"
vars_file="proxmox/vars.yml"
state_file="proxmox/state.json"
creds_file="proxmox/creds.yml"
action="${1:-deploy}"

# --- Locate the BOSH CLI (Homebrew ships it as "bosh-cli") ---------------------
if command -v bosh >/dev/null 2>&1; then
  bosh=bosh
elif command -v bosh-cli >/dev/null 2>&1; then
  bosh=bosh-cli
else
  cat >&2 <<'EOF'
ERROR: the BOSH CLI is not installed.
  macOS:  brew install cloudfoundry/tap/bosh-cli
  other:  https://github.com/cloudfoundry/bosh-cli/releases
EOF
  exit 1
fi

# --- Ensure the vars file exists ----------------------------------------------
if [[ ! -f "$vars_file" ]]; then
  cp proxmox/vars.tmpl.yml "$vars_file"
  echo "Created $vars_file from the template — fill in your Proxmox details, then re-run." >&2
  exit 1
fi

# --- Locate the CPI checkout ---------------------------------------------------
if [[ ! -d "$cpi_dir" ]]; then
  echo "ERROR: bosh-proxmox-cpi checkout not found at: $cpi_dir" >&2
  echo "       git clone git@github.com:hjaffan/bosh-proxmox-cpi.git, or set PROXMOX_CPI_DIR." >&2
  exit 1
fi
cpi_dir="$(cd "$cpi_dir" && pwd)"

# --- One-time vendoring of the golang package into the CPI checkout ------------
# `version: create` in cpi.yml builds the release from the checkout, which needs
# the golang-1-linux package vendored first. Idempotent: skip if already present.
ensure_vendored() {
  if [[ ! -d "$cpi_dir/packages/golang-1-linux" ]]; then
    echo ">> Vendoring the golang package into the CPI (one-time)..."
    ( cd "$cpi_dir" && ./scripts/create-release.sh >/dev/null )
  fi
}

# --- BOSH_* env for talking to the running director ----------------------------
director_env() {
  cat <<EOF
export BOSH_ENVIRONMENT=$($bosh int "$vars_file" --path /internal_ip)
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET=$($bosh int "$creds_file" --path /admin_password)
export BOSH_CA_CERT="$($bosh int "$creds_file" --path /director_ssl/ca)"
EOF
}

case "$action" in
  deploy)
    ensure_vendored
    echo ">> create-env: bootstrapping/updating the director (this can take a while)..."
    "$bosh" create-env bosh.yml \
      -o proxmox/cpi.yml \
      -o jumpbox-user.yml \
      --state="$state_file" \
      --vars-store="$creds_file" \
      -l "$vars_file" \
      -v proxmox_cpi_release="file://$cpi_dir"
    echo
    echo "Done. Talk to the director with:  eval \"\$(proxmox/deploy.sh env)\""
    ;;
  delete)
    ensure_vendored
    "$bosh" delete-env bosh.yml \
      -o proxmox/cpi.yml \
      -o jumpbox-user.yml \
      --state="$state_file" \
      --vars-store="$creds_file" \
      -l "$vars_file" \
      -v proxmox_cpi_release="file://$cpi_dir"
    ;;
  cloud-config)
    [[ -f "$creds_file" ]] || { echo "ERROR: $creds_file missing — deploy first." >&2; exit 1; }
    eval "$(director_env)"
    "$bosh" -n update-cloud-config proxmox/cloud-config.yml -l "$vars_file"
    ;;
  env)
    [[ -f "$creds_file" ]] || { echo "ERROR: $creds_file missing — deploy first." >&2; exit 1; }
    director_env
    ;;
  *)
    echo "Unknown action: $action (use deploy|delete|cloud-config|env)" >&2
    exit 1
    ;;
esac
