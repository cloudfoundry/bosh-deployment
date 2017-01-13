## BOSH Lite on VirtualBox

1. Make sure your machine has at least 8GB RAM, and 100GB free disk space. Smaller configurations may work.

1. Install [VirtualBox](https://www.virtualbox.org/wiki/Downloads)

    Known working version:

    ```
    $ VBoxManage --version
    5.1...
    ```

    Note: If you encounter problems with VirtualBox networking try installing [Oracle VM VirtualBox Extension Pack](https://www.virtualbox.org/wiki/Downloads) as suggested by [Issue 202](https://github.com/cloudfoundry/bosh-lite/issues/202). Alternatively make sure you are on VirtualBox 5.1+ since previous versions had a [network connectivity bug](https://github.com/concourse/concourse-lite/issues/9).

1. Install Director

    ```
    $ git clone https://github.com/cloudfoundry/bosh-deployment ~/workspace/bosh-deployment

    $ mkdir -p ~/deployments/vbox

    $ cd ~/deployments/vbox

    $ bosh create-env ~/workspace/bosh-deployment/bosh.yml \
      --state ./state.json \
      -o ~/workspace/bosh-deployment/virtualbox/cpi.yml \
      -o ~/workspace/bosh-deployment/virtualbox/outbound-network.yml \
      -o ~/workspace/bosh-deployment/bosh-lite.yml \
      -o ~/workspace/bosh-deployment/bosh-lite-runc.yml \
      -o ~/workspace/bosh-deployment/jumpbox-user.yml \
      --vars-store ./creds.yml \
      -v director_name="Bosh Lite Director" \
      -v internal_ip=192.168.50.6 \
      -v internal_gw=192.168.50.1 \
      -v internal_cidr=192.168.50.0/24 \
      -v network_name=vboxnet0 \
      -v outbound_network_name=NatNetwork
    ```

    Note: Above assumes that you have configured Host-only network 'vboxnet0' with 192.168.50.0/24 and NAT network 'NatNetwork' with DHCP enabled.

    To create the 'NatNetwork', run the command below. This is assuming 'NatNetwork' will be on the 10.0.2.0/24 subnet.

    ```
    VBoxManage natnetwork add --netname NatNetwork --network 10.0.2.0/24 --dhcp on
    ```

1. Alias and log into the Director

    ```
    $ bosh alias-env vbox -e 192.168.50.6 --ca-cert <(bosh int ./creds.yml --path /director_ssl/ca)
    $ export BOSH_CLIENT=admin
    $ export BOSH_CLIENT_SECRET=`bosh int ./creds.yml --path /admin_password`
    ```

1. Continue using Director to install other software.
