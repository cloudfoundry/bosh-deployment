#!/usr/bin/env bash
# Seed the GitHub Actions config the proxmox-deploy workflow needs, with safe
# DEFAULTS, so the repo is wired up before you have real values.
#
#   - Non-sensitive config  -> repository VARIABLES (visible, edit in the UI later)
#   - Sensitive credentials -> repository SECRETS   (seeded as CHANGE-ME placeholders)
#
# Idempotent: an existing variable/secret is left ALONE (never clobbered), so
# re-running after you've set real values is safe. Pass FORCE=1 to overwrite.
#
# Usage:
#   deployments/proxmox/seed-github-config.sh                 # seed hjaffan/bosh-deployment
#   REPO=owner/repo deployments/proxmox/seed-github-config.sh # a different repo
#   FORCE=1 deployments/proxmox/seed-github-config.sh         # overwrite existing
#
# Requires the gh CLI, authenticated with repo admin on REPO.
set -euo pipefail

REPO="${REPO:-hjaffan/bosh-deployment}"
FORCE="${FORCE:-0}"

command -v gh >/dev/null 2>&1 || { echo "FATAL: gh CLI not found" >&2; exit 2; }

# name = default  (non-sensitive -> Actions Variables)
variables=(
  "PROXMOX_API_URL=https://pve.example.com:8006"
  "PROXMOX_NODE=pve1"
  "PROXMOX_VM_STORAGE=local-lvm"
  "PROXMOX_IMPORT_STORAGE=local"
  "PROXMOX_BRIDGE=vmbr0"
  "PROXMOX_INSECURE_SKIP_VERIFY=true"     # self-signed PVE cert -> do not validate
  "DIRECTOR_NAME=bosh-proxmox"
  "DIRECTOR_INTERNAL_CIDR=10.0.0.0/24"
  "DIRECTOR_INTERNAL_GW=10.0.0.1"
  "DIRECTOR_INTERNAL_IP=10.0.0.6"
  "STATE_S3_BUCKET=bosh-director-state"
  "STATE_S3_PREFIX=director"
  "AWS_S3_ENDPOINT=https://ceph-rgw.example.com"   # your Ceph RGW endpoint
  "AWS_DEFAULT_REGION=us-east-1"
)

# name = placeholder  (sensitive -> Actions Secrets; REPLACE these with real values)
secrets=(
  "PROXMOX_API_TOKEN=bosh@pve!cpi=CHANGE-ME"
  "AWS_ACCESS_KEY_ID=CHANGE-ME"
  "AWS_SECRET_ACCESS_KEY=CHANGE-ME"
)

existing_vars="$(gh variable list -R "$REPO" 2>/dev/null | awk 'NF{print $1}' || true)"
existing_secrets="$(gh secret list  -R "$REPO" 2>/dev/null | awk 'NF{print $1}' || true)"
has() { printf '%s\n' "$2" | grep -qx "$1"; }

echo "== seeding repository VARIABLES on $REPO =="
for kv in "${variables[@]}"; do
  name="${kv%%=*}"; value="${kv#*=}"
  if [ "$FORCE" != 1 ] && has "$name" "$existing_vars"; then
    echo "  = $name (exists — kept)"; continue
  fi
  gh variable set "$name" -R "$REPO" --body "$value" && echo "  + $name = $value"
done

echo "== seeding repository SECRETS on $REPO (placeholders — replace before deploying) =="
for kv in "${secrets[@]}"; do
  name="${kv%%=*}"; value="${kv#*=}"
  if [ "$FORCE" != 1 ] && has "$name" "$existing_secrets"; then
    echo "  = $name (exists — kept)"; continue
  fi
  gh secret set "$name" -R "$REPO" --body "$value" && echo "  + $name = <placeholder>"
done

cat <<EOF

Done. Next:
  1. Edit the VARIABLES with your real values (Settings -> Secrets and variables
     -> Actions -> Variables), or re-run any single one, e.g.:
       gh variable set DIRECTOR_INTERNAL_IP -R $REPO --body 10.20.0.6
  2. Replace the three SECRETS with real credentials:
       gh secret set PROXMOX_API_TOKEN     -R $REPO
       gh secret set AWS_ACCESS_KEY_ID     -R $REPO
       gh secret set AWS_SECRET_ACCESS_KEY -R $REPO
  The workflow will fail fast against the CHANGE-ME placeholders until you do.
EOF
