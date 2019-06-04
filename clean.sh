#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset
shopt -s nullglob

if ! type VBoxManage > /dev/null 2>&1; then
    echo "Requires VBoxManage and VirtualBox to be installed"
    exit 1
fi

for i in cache/*.vdi; do
  VBoxManage closemedium --delete $i
done

rm -rf .ssh/vbox* cache/cfg/* cache/v*/rancher.ipxe cache/*.vdi cache/cluster.rkestate cache/cluster.yml cache/kube_config_cluster.yml
