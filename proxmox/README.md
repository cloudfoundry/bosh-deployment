# Proxmox VE

Deploy a BOSH director onto [Proxmox VE](https://www.proxmox.com/) using the
[bosh-proxmox-cpi](https://github.com/hjaffan/bosh-proxmox-cpi). Proxmox is not
an official BOSH CPI, so these ops files are vendored into this fork from that
repo's `manifests/`.

## Files

| File | Purpose |
|---|---|
| `cpi.yml` | Ops file that wires the Proxmox CPI into the repo's `bosh.yml` |
| `cloud-config.yml` | Example cloud config (AZs, vm_types, networks, disks) |
| `use-published-release.yml` | Use a published CPI tarball instead of a local checkout |
| `vars.tmpl.yml` | Template for your deployment variables — copy to `vars.yml` and fill in |
| `deploy.sh` | Local wrapper around `bosh create-env` / `delete-env` / cloud-config |
| `ci-deploy.sh` | CI entrypoint — same, but reads secrets from env and persists state to S3 |

`vars.yml`, `creds.yml`, and `state.json` are git-ignored (they hold secrets and
deploy state).

## Prerequisites

1. **Proxmox VE 8.4+** with an API token (`bosh@pve!cpi=...`) and storages with
   `import`+`iso` content (e.g. `local`) and VM disks (e.g. `local-lvm`). See
   the CPI's `docs/proxmox-setup.md`.
2. **BOSH CLI** — `brew install cloudfoundry/tap/bosh-cli`
   (or https://github.com/cloudfoundry/bosh-cli/releases).
3. **A checkout of `bosh-proxmox-cpi`** next to this repo (`../bosh-proxmox-cpi`),
   or point `PROXMOX_CPI_DIR` at it. No published release exists yet, so the CPI
   is built from the checkout (`deploy.sh` vendors the Go package automatically
   on first run).

## Deploy

```bash
# 1. Fill in your environment (first run creates vars.yml from the template)
proxmox/deploy.sh            # -> writes proxmox/vars.yml, then edit it
$EDITOR proxmox/vars.yml

# 2. Bootstrap the director (create-env)
proxmox/deploy.sh deploy

# 3. Point the CLI at it, upload cloud config + a stemcell
eval "$(proxmox/deploy.sh env)"
proxmox/deploy.sh cloud-config
bosh upload-stemcell https://bosh.io/d/stemcells/bosh-openstack-kvm-ubuntu-jammy-go_agent

# 4. Deploy something
bosh -d zookeeper deploy <(curl -sL https://raw.githubusercontent.com/cppforlife/zookeeper-release/master/manifests/zookeeper.yml)
```

Tear down with `proxmox/deploy.sh delete`.

## Deploy via CI (GitHub Actions)

`.github/workflows/proxmox-director.yml` deploys/updates/deletes the director on
the self-hosted **`proxmox-cpi`** runner (the same one the CPI repo uses — it must
be able to reach the Proxmox API and the director IP, and be visible to this
repo). `state.json` + `creds.yml` are persisted to **S3-compatible object storage**
(`proxmox/ci-deploy.sh`), so the director survives across runs. The state upload
runs even if `create-env` fails partway, so a half-created VM is never orphaned.

**Triggers:** manual (`workflow_dispatch`, with a `deploy`/`delete` choice) and
automatically on push to `master` touching `proxmox/**` or `bosh.yml`.

**Required repository secrets** (Settings → Secrets and variables → Actions):

| Secret | Example |
|---|---|
| `PROXMOX_API_URL` | `https://pve.lan:8006` |
| `PROXMOX_API_TOKEN` | `bosh@pve!cpi=xxxx...` |
| `PROXMOX_NODE` | `pve1` |
| `PROXMOX_VM_STORAGE` | `local-lvm` |
| `PROXMOX_IMPORT_STORAGE` | `local` |
| `PROXMOX_BRIDGE` | `vmbr0` |
| `DIRECTOR_INTERNAL_CIDR` | `10.0.0.0/24` |
| `DIRECTOR_INTERNAL_GW` | `10.0.0.1` |
| `DIRECTOR_INTERNAL_IP` | `10.0.0.6` |
| `STATE_S3_BUCKET` | `bosh-director-state` (private, SSE-enabled) |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | bucket credentials |

Optional: `PROXMOX_INSECURE_SKIP_VERIFY` (default `true`), `DIRECTOR_NAME`,
`STATE_S3_PREFIX`, `AWS_DEFAULT_REGION`, and `AWS_S3_ENDPOINT` (set for MinIO /
non-AWS S3).

> **creds.yml holds the director admin password + CA + all internal passwords.**
> Use a **private** bucket; uploads request SSE-S3. For MinIO, enable bucket
> encryption and TLS on `AWS_S3_ENDPOINT`.

## Using a published CPI release

Once you cut a GitHub release of the CPI, skip the source build:

```bash
bosh create-env bosh.yml \
  -o proxmox/cpi.yml \
  -o proxmox/use-published-release.yml \
  -o jumpbox-user.yml \
  --state=proxmox/state.json --vars-store=proxmox/creds.yml \
  -l proxmox/vars.yml \
  -v proxmox_cpi_version=<X.Y.Z> \
  -v proxmox_cpi_sha1=<sha1>
```

## cloud_properties reference

See the [CPI README](https://github.com/hjaffan/bosh-proxmox-cpi#cloud_properties-reference)
for all `vm_types`, `disk_types`, and `networks` cloud properties.
