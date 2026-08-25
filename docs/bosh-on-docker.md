# BOSH on Docker

These steps bring up a local BOSH Director on the Docker CPI and deploy the
`nats` test deployment against it. They are the interactive equivalent of what
[`ci/tasks/test-docker.sh`](../ci/tasks/test-docker.sh) runs in CI.

## Prerequisites

- A running Docker daemon reachable at `unix:///var/run/docker.sock`
- The `bosh` CLI (7.x)
- A user-defined bridge network for the Director and its VMs:

  ```bash
  docker network create --subnet=10.245.0.0/16 --gateway=10.245.0.1 bosh-net
  ```

  The gateway must match the `internal_gw` you pass to `create-env` and the
  `gateway` in `docker/cloud-config.yml`. Size the subnet to cover that file's
  `range` (`10.245.0.0/16`) — the Director allocates from the bottom of the
  range, so a `/24` works for small deployments, but once you have enough VMs
  the Director will hand out an address that Docker's subnet does not contain.

- **On macOS**, [`docker-mac-net-connect`](https://github.com/chipmk/docker-mac-net-connect)
  running in the background:

  ```bash
  brew install chipmk/tap/docker-mac-net-connect
  sudo brew services start chipmk/tap/docker-mac-net-connect
  ```

  Docker runs inside a Linux VM on macOS, and that VM's bridge networks are not
  routable from the host — so without it there is no IP-level access from the Mac
  to any container. Every step from step 2 onward talks to the Director at
  `10.245.0.10` directly, so all of them fail. `docker-mac-net-connect` opens a
  WireGuard tunnel into the VM and adds host routes for the Docker subnets.
  Verify before continuing:

  ```bash
  docker run --rm -d --name nettest --network bosh-net busybox sleep 60
  ping -c1 "$(docker inspect -f '{{(index .NetworkSettings.Networks "bosh-net").IPAddress}}' nettest)"
  docker rm -f nettest
  ```

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

Use `docker/dns.yml` and the `dns` value already set in
`docker/cloud-config.yml`, which both point at `127.0.0.11` — Docker's embedded
DNS server. It exists in every container's own network namespace and forwards to
whatever resolvers the Docker host is using, so it works regardless of the
network the host is on.

## 1. Deploy the Director

```bash
export DEPLOYMENT_DIR=~/bosh-docker      # holds state.json and creds.yml
export BOSH_DEPLOYMENT=/path/to/bosh-deployment
mkdir -p "${DEPLOYMENT_DIR}" && cd "${DEPLOYMENT_DIR}"

bosh create-env "${BOSH_DEPLOYMENT}/bosh.yml" \
  --state=state.json \
  --vars-store=creds.yml \
  -o "${BOSH_DEPLOYMENT}/docker/cpi.yml" \
  -o "${BOSH_DEPLOYMENT}/uaa.yml" \
  -o "${BOSH_DEPLOYMENT}/credhub.yml" \
  -o "${BOSH_DEPLOYMENT}/docker/unix-sock.yml" \
  -o "${BOSH_DEPLOYMENT}/docker/dns.yml" \
  -o "${BOSH_DEPLOYMENT}/jumpbox-user.yml" \
  -v director_name=bosh-docker \
  -v internal_cidr=10.245.0.0/24 \
  -v internal_gw=10.245.0.1 \
  -v internal_ip=10.245.0.10 \
  -v docker_host="unix:///var/run/docker.sock" \
  -v network=bosh-net
```

`uaa.yml` and `credhub.yml` are not optional here: both `ci/assets/nats.yml` and
`runtime-configs/dns.yml` declare a `variables:` block, and the Director can only
generate those credentials with a config server. Without them the Director comes
up reporting `config_server: disabled` and the deploy in step 6 fails to resolve
`((nats_password))`.

`docker/unix-sock.yml` bind-mounts the host's Docker socket into the Director so
the CPI can create sibling containers. Drop it and pass `-v docker_tls=...`
instead if you are talking to a remote, TLS-protected daemon.

Ops-file order matters if you also use one of the `misc/use-compiled-*-releases.yml`
files: those replace `/releases/name=uaa` and `/releases/name=credhub`, so they
must come *after* `uaa.yml` and `credhub.yml`, which append their own
uncompiled entries.

`create-env` writes its progress to `/dev/tty`, so it emits **nothing** when you
redirect it to a file or a pipe. Pass `--tty` (or set `BOSH_TTY=true`) whenever
you capture the output — otherwise a long run looks identical to a hung one.

## 2. Target the Director

```bash
bosh int creds.yml --path /director_ssl/ca > ca.crt

export BOSH_ENVIRONMENT=10.245.0.10
export BOSH_CA_CERT="${PWD}/ca.crt"
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET="$(bosh int creds.yml --path /admin_password)"

bosh env
```

`bosh env` should report `config_server: enabled`. If it says `disabled`, go back
to step 1 and add `uaa.yml` and `credhub.yml`.

## 3. Upload the cloud config

```bash
bosh -n update-cloud-config "${BOSH_DEPLOYMENT}/docker/cloud-config.yml" \
  -v network=bosh-net

bosh cloud-config     # verify
```

`-v network=bosh-net` is required. `docker/cloud-config.yml` uses `((network))`
for the subnet's `cloud_properties.name`, and the Director stores cloud configs
verbatim — omit the var and it uploads the literal string `((network))`, after
which every `create_vm` fails looking for a Docker network by that name. The
verification step above is worth doing: the broken config is only visible as the
unresolved `((network))` in the output.

## 4. Upload a stemcell

```bash
bosh upload-stemcell \
  https://storage.googleapis.com/bosh-core-stemcells/1.484/bosh-stemcell-1.484-warden-boshlite-ubuntu-noble.tgz

bosh stemcells
```

Use the same version referenced by `docker/cpi.yml`, or your own locally built
warden stemcell. Note the `OS` column — step 6 needs it.

## 5. Upload the bosh-dns runtime config

```bash
bosh -n update-runtime-config "${BOSH_DEPLOYMENT}/runtime-configs/dns.yml"
```

On Noble and Resolute stemcells this addon sets `configure_systemd_resolved: true`
and `disable_recursors: true`, so bosh-dns answers only for BOSH domains and
leaves everything else to systemd-resolved — which is exactly why the `127.0.0.11`
value from step 3 has to be right for deployed VMs too.

## 6. Deploy nats

```bash
bosh -n -d nats deploy "${BOSH_DEPLOYMENT}/ci/assets/nats.yml" \
  -v stemcell_os=ubuntu-noble

bosh -d nats instances --ps
bosh -n -d nats run-errand smoke-tests
```

`stemcell_os` must match the `OS` of the stemcell uploaded in step 4.

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
