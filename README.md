# bosh-deployment

This repository is intended to serve as a reference and starting point for developer-friendly configuration of the Bosh Director. Consume the `master` branch. Any changes should be made against the `develop` branch (it will be automatically promoted once it passes tests).

## Important notice for users of bosh-deployment and Bosh DNS versions older than 1.28

As of Bosh DNS version 1.28, Bosh DNS is now built with Go 1.15. This version of Go demands that TLS certificates be created with a SAN field, in addition to the usual CN field.

The following certificates are affected by this change and will need to be regenerated:

* `/dns_healthcheck_server_tls`
* `/dns_healthcheck_client_tls`
* `/dns_api_server_tls`
* `/dns_api_client_tls`

If you're using Credhub or another external variable store, then you will need to use `update_mode: converge` as documented here: <https://bosh.io/docs/manifest-v2/#variables>.<br>
If you are not using Credhub or another external variable store, then you will need to follow the usual procedure for regenerating your certificates.

## Jammy stemcells

We deploy using Jammy stemcells; however, if you would prefer to use the Bionic stemcells, append the ops files `[IAAS]/use-bionic.yml` and `misc/source-releases/bosh.yml` after the ops file `[IAAS]/cpi.yml`.

## How is bosh-deployment updated?
An automatic process updates Bosh, and other releases within bosh-deployment

1. A new release of [bosh](https://github.com/cloudfoundry/bosh) is created.
1. A CI pipeline updates bosh-deployment on `develop` with a compiled bosh release.
1. Smoke tests are performed to ensure `create-env` works with this potential collection of resources and the new release.
1. A commit to `master` is made.

Other releases such as [UAA](https://github.com/cloudfoundry/uaa-release), [CredHub](https://github.com/pivotal-cf/credhub-release), and various CPIs are also updated automatically.

## Using bosh-deployment

* [Create an environment](https://bosh.io/docs/init.html)
    * [On Local machine (BOSH Lite)](https://bosh.io/docs/bosh-lite.html)
    * [On Alibaba Cloud](https://bosh.io/docs/init-alicloud.html)
    * [On AWS](https://bosh.io/docs/init-aws.html)
    * [On Azure](https://bosh.io/docs/init-azure.html)
    * [On OpenStack](https://bosh.io/docs/init-openstack.html)
    * [On vSphere](https://bosh.io/docs/init-vsphere.html)
    * [On vCloud](https://bosh.io/docs/init-vcloud.html)
    * [On SoftLayer](https://bosh.io/docs/init-softlayer.html)
    * [On Google Compute Platform](https://bosh.io/docs/init-google.html)

* Access your BOSH director
    * Through a VPN
        * [`bosh create-env`, OpenVPN option](https://github.com/dpb587/openvpn-bosh-release)
    * Through a jumpbox
        * [`bosh create-env` option](https://github.com/cppforlife/jumpbox-deployment)
    * [Expose Director on a Public IP](https://bosh.io/docs/init-external-ip.html) (not recommended)

* [CLI v2](https://bosh.io/docs/cli-v2.html)
    * [`create-env` Dependencies](https://bosh.io/docs/cli-v2-install/#additional-dependencies)
    * [Differences between CLI v2 vs v1](https://bosh.io/docs/cli-v2-diff.html)
    * [Global Flags](https://bosh.io/docs/cli-global-flags.html)
    * [Environments](https://bosh.io/docs/cli-envs.html)
    * [Operations files](https://bosh.io/docs/cli-ops-files.html)
    * [Variable Interpolation](https://bosh.io/docs/cli-int.html)
    * [Tunneling](https://bosh.io/docs/cli-tunnel.html)

### Ops files

- `bosh.yml`: Base manifest that is meant to be used with different CPI configurations
- `[alicloud|aws|azure|docker|gcp|openstack|softlayer|vcloud|vsphere|virtualbox]/cpi.yml`: CPI configuration
- `[alicloud|aws|azure|docker|gcp|openstack|softlayer|vcloud|vsphere|virtualbox]/cloud-config.yml`: Simple cloud configs
- `[alicloud|aws|azure|docker|gcp|openstack|vcloud|virtualbox|vsphere|warden]/use-bionic.yml`: use Bionic stemcell instead of Jammy stemcell
- `jumpbox-user.yml`: Adds user `jumpbox` for SSH-ing into the Director (see [Jumpbox User](docs/jumpbox-user.md))
- `uaa.yml`: Deploys UAA and enables UAA user management in the Director
- `credhub.yml`: Deploys CredHub and enables CredHub integration in the Director
- `bosh-lite.yml`: Configures Director to use Garden CPI within the Director VM (see [BOSH Lite](docs/bosh-lite-on-vbox.md))
- `syslog.yml`: Configures syslog to forward logs to some destination
- `local-dns.yml`: Enables Director DNS beta functionality
- `misc/config-server.yml`: Deploys config-server (see `credhub.yml`)
- `misc/proxy.yml`: Configure HTTP proxy for Director and CPI
- `misc/dns.yml`: Configure your upstream DNS (NOTE: by default bosh-deployment uses Google DNS: 8.8.8.8)
- `misc/ntp.yml`: Configure your NTP Servers (NOTE: by default bosh-deployment uses Google NTP servers: time{1-4}.google.com
- `runtime-configs/syslog.yml`: Runtime config to enable syslog forwarding

See [tests/run-checks.sh](tests/run-checks.sh) for example usage of different ops files.

### Runtime Config Files

The director can optionally add configuration to all VMs in all deployments. The YAML defines an IaaS agnostic configuration that applies to all deployments. (see [Director Runtime Config](https://bosh.io/docs/runtime-config/).

- `dns.yml`: Install bosh defined dns release in every deployed VM. This allows bosh VMs to use the VM name as a FQDN. *It is extremely common for deployments require this addon*. (eg concourse-ci with UAA). For more information see [Native DNS Support](https://bosh.io/docs/dns/).
- `bpm.yml`: Install bosh process manager on every VM (see [BPM-Release](https://github.com/cloudfoundry/bpm-release)
- `syslog.yml`: Install a syslog forwarder agent in every VM.

See [runtime-configs/](runtime-configs/) for examples of different runtime configs.
Other uses include installation of prometheus exporters, os-conf (to modify os level configurations), virus scanning, compliance agents.

### Security Groups

Please ensure you have security groups setup correctly. i.e:

```
Type                 Protocol Port Range  Source                     Purpose
SSH                  TCP      22          <IP you run bosh CLI from> SSH (if Registry is used)
Custom TCP Rule      TCP      6868        <IP you run bosh CLI from> Agent for bootstrapping
Custom TCP Rule      TCP      25555       <IP you run bosh CLI from> Director API
Custom TCP Rule      TCP      8443        <IP you run bosh CLI from> UAA API (if UAA is used)
Custom TCP Rule      TCP      8844        <IP you run bosh CLI from> CredHub API (if CredHub is used)
SSH                  TCP      22          <((internal_cidr))>        BOSH SSH (optional)
Custom TCP Rule      TCP      4222        <((internal_cidr))>        NATS
Custom TCP Rule      TCP      25250       <((internal_cidr))>        Blobstore
Custom TCP Rule      TCP      25777       <((internal_cidr))>        Registry if enabled
```
