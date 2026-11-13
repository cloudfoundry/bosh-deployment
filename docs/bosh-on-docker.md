# BOSH on Docker

`docker/create-env` stands up a local BOSH Director on the Docker CPI, on macOS
or Linux, and leaves you with a file you can `source`. It is the interactive
equivalent of what [`ci/tasks/test-docker.sh`](../ci/tasks/test-docker.sh) runs
in CI.

## Prerequisites

- A running Docker daemon
- The `bosh` CLI (7.x)
- **On macOS**, [`docker-mac-net-connect`](https://github.com/chipmk/docker-mac-net-connect)
  running in the background:

  ```bash
  brew install chipmk/tap/docker-mac-net-connect
  sudo brew services start chipmk/tap/docker-mac-net-connect
  ```

  Docker runs inside a Linux VM on macOS, and that VM's bridge networks are not
  routable from the host — so without it there is no IP-level access from the Mac
  to any container, and everything after `create-env` times out against
  `10.245.0.10`. `docker-mac-net-connect` opens a WireGuard tunnel into the VM
  and adds host routes for the Docker subnets. `create-env` checks this by
  pinging the bridge's gateway and warns if it does not answer. 

The Docker bridge network the Director and its VMs live on (`bosh-net`,
`10.245.0.0/16`, gateway `10.245.0.1`) is created for you if it does not exist.

## Deploy the Director

Run it from the directory you want your deployment files in — `state.json`,
`creds.yml`, `bosh.env` and the stemcell tarball are written to `$PWD`, and the
script refuses to run inside this checkout so credentials cannot land in the
repo.

```bash
mkdir -p ~/bosh-docker && cd ~/bosh-docker
/path/to/bosh-deployment/docker/create-env
```

That does the whole thing: preflight, `bosh create-env`, write and source
`bosh.env`, `bosh env`, upload the cloud config, upload the stemcell the
manifest pinned, upload the bosh-dns runtime config. When it finishes:

```bash
source bosh.env
```

`bosh.env` holds no secrets — it interpolates out of `creds.yml` at source time.
A `.envrc` symlink to it is created so direnv users get the same behaviour.

It also exports `BOSH_AGENT_ENDPOINT` and `BOSH_AGENT_CERTIFICATE`, so you can get
a shell on the Director itself:

```bash
bosh ssh --director
```

To tear it down, from the same directory:

```bash
/path/to/bosh-deployment/docker/create-env --destroy
```

`--destroy` reads the flavor and ops files back out of `.create-env/run`, so it
deletes with exactly what the create built — no flags to remember, and no list
to keep in sync. It removes `creds.yml` and `bosh.env` afterwards, because both
now describe a Director that no longer exists. `bosh delete-env` removes
`state.json` itself once the deployment is gone. The stemcell tarball stays, so
recreating in the same directory does not re-download ~1GB.

### Flags

```
docker/create-env [--resolute] [--silent] [--recreate] [--dry-run]
                  [--bosh-release PATH] [--stemcell URL_OR_PATH]
                  [-o FILE] [--var k=v]
docker/create-env --destroy
docker/create-env --help
```

- `--resolute` uses the Resolute stemcell and the compiled Resolute releases —
  `docker/use-resolute.yml` plus `misc/use-compiled-resolute-releases.yml`,
  which is the combination the `test-resolute` job in `ci/pipeline.yml` already
  uses. On Apple Silicon it also applies `docker/use-resolute-rosetta.yml`,
  whose stemcell keeps an x86_64 userland but ships native arm64 systemd
  daemons — Resolute's systemd 259 stops services with pidfd syscalls that
  Rosetta 2 does not translate.
- `--bosh-release PATH` points the bosh release at a local build. A directory
  uses `local-bosh-release.yml` (`version: create`); a `.tgz` uses
  `local-bosh-release-tarball.yml` (`version: latest`).
- `--stemcell URL_OR_PATH` overrides the stemcell the ops files pin, including
  the Apple Silicon auto-detection. Use it for "I just built a stemcell, use
  it", rather than editing a tracked ops file.
- `-o FILE` and `--var k=v` are applied after everything the script adds, so
  they override any of it. This is the escape hatch for anything there is no
  flag for — a different `docker_host` for a remote TLS daemon, say.
- `--recreate` passes `--recreate` through to `bosh create-env`. See
  [Recovering from an interrupted create-env](#recovering-from-an-interrupted-create-env).
- `--silent` puts everything but errors into `create-env.log` and prints the
  failing command plus the tail of that log if the run fails. It passes `--tty`
  to `create-env`, which otherwise writes its progress to `/dev/tty` and so
  logs nothing at all when redirected.
- `--dry-run` prints the `create-env` invocation and the stemcell it resolved,
  and touches neither Docker nor the network.

### Ops-file ordering

The script owns this, and that is most of the reason for it to exist:

- `docker/use-resolute.yml` replaces the `bosh-docker-cpi` release that
  `docker/cpi.yml` appends, so it must come after it.
- `misc/use-compiled-resolute-releases.yml` replaces `/releases/name=uaa` and
  `/releases/name=credhub`, so it must come after `uaa.yml` and `credhub.yml`,
  which append their own uncompiled entries.
- `docker/use-resolute-rosetta.yml` overrides only the stemcell, on top of
  `docker/use-resolute.yml`.

Get any of those wrong and nothing complains — you just get the wrong release or
stemcell in the deployed Director. `tests/run-checks.sh` asserts the resulting
ops list and stemcell URL for every flavor for exactly that reason.

`docker/unix-sock.yml` bind-mounts the host's Docker socket into the Director so
the CPI can create sibling containers. Pass `--var docker_tls=...` and
`-o` your own file instead if you are talking to a remote, TLS-protected daemon.

## A note on DNS

The Docker CPI runs every BOSH VM as a container, and the BOSH agent writes the
network's `dns` setting into `/etc/systemd/resolved.conf.d/10-bosh.conf` inside
that container. `bosh.yml` defaults that to Google's `8.8.8.8`, which fails
closed on any network that blocks public resolvers. The Director comes up fine
but cannot download remote releases or stemcells:

```
Task 47 | Downloading remote release: Downloading remote release (00:00:20)
                   L Error: Downloading remote release failed.
```

The failure is easy to misread, because ICMP to `8.8.8.8` is often answered by
the local Docker VM's NAT even when TCP and UDP port 53 are dropped. Confirm it
from inside the Director with `resolvectl status` and `getent hosts bosh.io`
rather than with `ping`.

`create-env` applies `docker/dns.yml`, and `docker/cloud-config.yml` carries the
matching value for deployed VMs. Both point at `127.0.0.11` — Docker's embedded
DNS server, which exists in every container's own network namespace and forwards
to whatever resolvers the Docker host is using, so it works regardless of the
network the host is on.

## Verify it: deploy nats

`create-env` stops once the Director is configured. Deploying something is the
step that proves it works, and it is the same thing CI does:

```bash
source bosh.env
bosh stemcells      # note the OS column

bosh -n -d nats deploy /path/to/bosh-deployment/ci/assets/nats.yml \
  -v stemcell_os=ubuntu-noble

bosh -d nats instances --ps
bosh -n -d nats run-errand smoke-tests
```

`stemcell_os` must match the `OS` of the uploaded stemcell — `ubuntu-resolute`
if you used `--resolute`.

A healthy result looks like this — two `nats` instances, each running `bosh-dns`,
`bosh-dns-healthcheck`, `nats-tls-healthcheck` and `nats-tls-wrapper`:

```
Instance                                   Process               Process State  AZ  IPs
nats/50084029-f03c-4784-a0e0-84eaeb5ba815  -                     running        z2  10.245.0.12
~                                          bosh-dns              running
~                                          bosh-dns-healthcheck  running
~                                          nats-tls-healthcheck  running
~                                          nats-tls-wrapper      running
```

and the errand exits `0` with `Detected no non-TLS hosts` on stderr, which is
expected — this deployment only runs the TLS leg of the smoke tests.

## What CI covers, and what it does not

`tests/run-checks.sh` runs on every commit in a plain container with no Docker
daemon, so it covers `create-env` statically: shellcheck, `--help`, the
`--dry-run` ops list for each flavor on both `uname` branches, and the stemcell
URL each flavor resolves to.

The end-to-end coverage is the `test-docker` job, which is privileged and does
stand up a real Director — but it sources `start-bosh` from the
`bosh-docker-cpi` image rather than running this script, because that image
handles nested-container specifics `create-env` does not. So **CI exercises the
ops files and the manifest, not `docker/create-env` itself.** That gap is
deliberate for now: `create-env` in a privileged Concourse container is a
materially different environment from a laptop, and making it work there is its
own piece of work.

## Troubleshooting

### Package compilation hangs forever on an emulated stemcell

On Apple Silicon, an `amd64` warden stemcell runs under Rosetta (every process in
the container is prefixed `/mnt/lima-rosetta/rosetta`). The parallel Go compiler
can deadlock there. The symptom is misleading: `create-env` appears stuck on an
unrelated step, such as

```
Running the pre-stop scripts 'unknown/0'...
```

because bosh-agent serialises tasks — a wedged compile blocks every task queued
behind it, including the one `create-env` is waiting on. Check inside the
container:

```bash
docker exec <container> ps -eo pid,stat,etime,args | grep -E 'packaging|go build|compile'
```

A deadlocked build shows a long-running `go build` with unreaped
`[compile] <defunct>` children, at zero CPU, with `wchan=rt_mutex_schedule`.
Kill the `go build` and its parent `bash -x packaging`, then re-run `create-env`;
the compile normally succeeds on a second attempt.

To confirm where the CLI itself is blocked, send it `SIGQUIT` — the Go stack dump
names the exact agent call it is polling.

### Recovering from an interrupted create-env

If `create-env` is interrupted after it has created the VM but before it applies
a spec, the container is left with no jobs and the agent reports the instance as
`unknown/0`. Re-running plain `create-env` then tries to update that VM in place.
Pass `--recreate` to replace the VM instead, which skips the in-place update path.