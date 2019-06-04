#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

trap 'kill -9 $(jobs -p) 2>/dev/null' EXIT

NODE_COUNT=${2:-3}

for i in $(seq 1 "$NODE_COUNT"); do 
    if VBoxManage list vms | grep -q ros-vm${i}; then
        VBoxManage controlvm "ros-vm${i}" poweroff || true
        VBoxManage unregistervm "ros-vm${i}" --delete || true
    fi
done