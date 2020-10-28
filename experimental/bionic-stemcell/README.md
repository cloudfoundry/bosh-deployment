# bionic-stemcell

These Ops files replace xenial stemcells with experimental bionic stemcells.

To use them, you'll also need to use the Ops files found in /misc/source-releases since releases are not yet precompiled for bionic:

```
create-env.sh -o experimental/bionic-stemcell/[IAAS_NAME].yml \
              -o misc/source-releases/bosh.yml \
              -o misc/source-releases/credhub.yml \
              -o misc/source-releases/uaa.yml
``
