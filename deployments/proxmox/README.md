# Proxmox director — my environment

A self-contained BOSH director deployment for this environment on
[Proxmox VE](https://www.proxmox.com/), using the **published**
[`bosh-proxmox-cpi`](https://github.com/hjaffan/bosh-proxmox-cpi) **release**
(no source build). State (`state.json` + `creds.yml`) is persisted to **Ceph S3**.

## Why this is a separate directory

This fork mirrors upstream `cloudfoundry/bosh-deployment`. To keep pulling
upstream **merge-clean**, everything here is **new files only** — it never edits
`bosh.yml` or any upstream file. It layers the shared, additive ops files
(`proxmox/cpi.yml`, `proxmox/use-published-release.yml`,
`proxmox/cpi-release-url.yml`, `jumpbox-user.yml`) on top via `-o`, read-only.

| File | Purpose |
|---|---|
| `deploy.sh` | Driver: `create-env` / `delete-env` / `cloud-config` / `env`, published release, Ceph S3 state |
| `vars.tmpl.yml` | Copy to `vars.yml` and fill in (Proxmox + networking). Git-ignored. |
| `.gitignore` | Keeps `vars.yml`, `creds.yml`, `state.json` out of git |

The CPI release is pinned to **v1.0.0** (`https://cdn.cf-apps.io/bosh-proxmox-cpi-1.0.0.tgz`,
sha1 `facc1ef0…f4e030`) by default — override with `CPI_RELEASE_VERSION` /
`CPI_RELEASE_SHA1` / `CPI_RELEASE_URL`.

## Deploy locally

```bash
cp deployments/proxmox/vars.tmpl.yml deployments/proxmox/vars.yml
$EDITOR deployments/proxmox/vars.yml          # Proxmox + networking

# Ceph S3 (state store) — keys stay out of git; endpoint is your RGW:
export AWS_S3_ENDPOINT=https://<ceph-rgw>:<port>
export STATE_S3_BUCKET=<bucket> STATE_S3_PREFIX=director
export AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=…

deployments/proxmox/deploy.sh deploy
eval "$(deployments/proxmox/deploy.sh env)"   # talk to the director
```

Tear down with `deployments/proxmox/deploy.sh delete`.

## Deploy via CI (self-hosted runner)

`.github/workflows/proxmox-deploy.yml` runs `deploy.sh` on the self-hosted
**`proxmox-cpi`** runner, `workflow_dispatch` only (no auto-deploy on push — infra
changes are deliberate). Config is split so it's easy to reason about:

- **Repository Variables** (non-sensitive, visible/editable): `PROXMOX_API_URL`,
  `PROXMOX_NODE`, `PROXMOX_VM_STORAGE`, `PROXMOX_IMPORT_STORAGE`, `PROXMOX_BRIDGE`,
  `PROXMOX_INSECURE_SKIP_VERIFY`, `DIRECTOR_NAME`, `DIRECTOR_INTERNAL_CIDR`,
  `DIRECTOR_INTERNAL_GW`, `DIRECTOR_INTERNAL_IP`, `STATE_S3_BUCKET`,
  `STATE_S3_PREFIX`, `AWS_S3_ENDPOINT` (your Ceph RGW), `AWS_DEFAULT_REGION`.
- **Repository Secrets** (sensitive): `PROXMOX_API_TOKEN`, `AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY` (RGW keys).

**Seed them all with defaults** (variables get real defaults; secrets get
`CHANGE-ME` placeholders you must replace):

```bash
deployments/proxmox/seed-github-config.sh                 # -> hjaffan/bosh-deployment
# then set the real values:
gh variable set DIRECTOR_INTERNAL_IP -R hjaffan/bosh-deployment --body 10.20.0.6
gh secret   set PROXMOX_API_TOKEN    -R hjaffan/bosh-deployment
gh secret   set AWS_ACCESS_KEY_ID    -R hjaffan/bosh-deployment
gh secret   set AWS_SECRET_ACCESS_KEY -R hjaffan/bosh-deployment
```

The script is idempotent — it never clobbers an existing value (pass `FORCE=1` to
overwrite). Also **register the `proxmox-cpi` self-hosted runner** on this repo
(online, able to reach the Proxmox API and director IP).

Then: Actions → **proxmox-deploy** → Run workflow (or
`gh workflow run proxmox-deploy.yml -f action=deploy`).

> **`creds.yml` holds the director admin password, the CA private key, and every
> internal cert/password.** Use a **private** bucket. Uploads try SSE-S3 and fall
> back to a plain upload if the RGW doesn't offer it — so ensure the bucket/pool
> is private and encrypted at rest, and the RGW endpoint is TLS.
