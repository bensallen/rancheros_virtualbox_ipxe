#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

trap 'kill -9 $(jobs -p) 2>/dev/null' EXIT

RANCHEROS_VERSION=${1:-v1.5.2}
NODE_COUNT=${2:-3}

VBOXNET=vboxnet98
VBOXNET_IP=192.168.98.1
VBOXNET_NETMASK=255.255.255.0

HTTP_PORT=12345

NODE_CPUS=1
NODE_MEM=4096

CACHE_DIR=$(pwd)/cache

if ! type jq > /dev/null 2>&1; then
    echo "Requires jq to be installed"
    exit 1
fi

if ! type VBoxManage > /dev/null 2>&1; then
    echo "Requires VBoxManage and VirtualBox to be installed"
    exit 1
fi

if ! type rke > /dev/null 2>&1; then
    echo "Requires rke to be installed"
    exit 1
fi

echo "RancherOS Version: $RANCHEROS_VERSION"

mkdir -p "${CACHE_DIR}/${RANCHEROS_VERSION}" "${CACHE_DIR}/cfg" 

if [ ! -f "${CACHE_DIR}/${RANCHEROS_VERSION}"/vmlinuz ]; then
    printf "\n* Downloading RancherOS vmlinuz %s ..." "$RANCHEROS_VERSION"
    wget -q "https://github.com/rancher/os/releases/download/$RANCHEROS_VERSION/vmlinuz" -O "${CACHE_DIR}/${RANCHEROS_VERSION}/vmlinuz"
fi

if [ ! -f "${CACHE_DIR}/${RANCHEROS_VERSION}"/initrd ]; then
    printf "\n* Downloading RancherOS initrd %s ..." "$RANCHEROS_VERSION"
    wget -q "https://github.com/rancher/os/releases/download/$RANCHEROS_VERSION/initrd" -O "${CACHE_DIR}/${RANCHEROS_VERSION}/initrd"
fi

if [ ! -f "ipxe/bin/virtio-net.isarom" ]; then
  echo "iPXE ROM missing, build via ipxe/build-virtio.sh"
  exit 1
fi

if ! ifconfig "${VBOXNET}" >/dev/null 2>&1; then
  /Applications/VirtualBox.app/Contents/MacOS/VBoxNetAdpCtl "${VBOXNET}" add
  VBoxManage hostonlyif ipconfig "${VBOXNET}" -ip="${VBOXNET_IP}" --netmask="${VBOXNET_NETMASK}"
  VBoxManage dhcpserver remove --ifname "${VBOXNET}" >/dev/null 2>&1 || true
fi

if [ ! -f .ssh/vbox.pub ]; then
  mkdir -p .ssh
  ssh-keygen -N "" -C "" -f .ssh/vbox >/dev/null
fi

python3 -m http.server ${HTTP_PORT} --bind 127.0.0.1 --directory "${CACHE_DIR}" &

cat <<EOF > "${CACHE_DIR}/${RANCHEROS_VERSION}/rancher.ipxe"
#!ipxe

set base http://10.0.2.2:${HTTP_PORT}
set version ${RANCHEROS_VERSION}

echo "Booting RancherOS \${version}"
initrd \${base}/\${version}/initrd
kernel \${base}/\${version}/vmlinuz initrd=initrd console=tty1 rancher.autologin=tty1 rancher.state.dev=LABEL=RANCHER_STATE rancher.state.autoformat=[/dev/sda] rancher.state.formatzero rancher.cloud_init.datasources=[url:\${base}/cfg/\${mac}]

boot
EOF

for i in $(seq 1 "$NODE_COUNT"); do 
    if VBoxManage list vms | grep -q "ros-vm${i}"; then
        echo "ros-vm${i} already exists, skipping"
    else
        VBoxManage createvm --name "ros-vm${i}" --ostype "RedHat_64" --register

        VBoxManage modifyvm "ros-vm${i}" \
            --nic1 nat \
            --nictype1 virtio \
            --macaddress1 "AABBCC00110${i}" \
            --nic2 hostonly \
            --nictype2 virtio \
            --hostonlyadapter2 "${VBOXNET}" \
            --nattftpfile1 "http://10.0.2.2:${HTTP_PORT}/${RANCHEROS_VERSION}/rancher.ipxe" \
            --boot1 net \
            --boot2 none \
            --boot3 none \
            --boot4 none \
            --cpus "${NODE_CPUS}" \
            --memory "${NODE_MEM}" \
            --vram 16
        VBoxManage setextradata "ros-vm${i}" VBoxInternal/Devices/pcbios/0/Config/LanBootRom "$(pwd)/ipxe/bin/virtio-net.isarom"

        VBoxManage createmedium disk --filename "${CACHE_DIR}/ros-vm${i}.vdi" --size 32768 --format VDI
        VBoxManage storagectl "ros-vm${i}" --name "SATA Controller" --add sata --controller IntelAhci
        VBoxManage storageattach "ros-vm${i}" --storagectl "SATA Controller" --port 0 --device 0 --type hdd --medium "${CACHE_DIR}/ros-vm${i}.vdi"

        cat <<EOF > "${CACHE_DIR}/cfg/AA:BB:CC:00:11:0${i}"
#cloud-config
hostname: ros-vm${i}
rancher:
  docker:
    engine: docker-18.09.2
  network:
    interfaces:
      "eth0":
        dhcp: true
      "eth1":
        address: 192.168.98.1${i}/24
        dhcp: false
ssh_authorized_keys:
  - $(cat .ssh/vbox.pub)
EOF

        VBoxManage startvm "ros-vm${i}" --type headless
    fi
done



cat <<EOF > "${CACHE_DIR}/cluster.yml"
---
nodes:
EOF

for i in $(seq 1 "$NODE_COUNT"); do
cat <<EOF >> "${CACHE_DIR}/cluster.yml"
  - address: 192.168.98.1${i}
    hostname_override: ros-vm${i}
    ssh_key_path: $(pwd)/.ssh/vbox
    user: rancher
    role: [controlplane,worker,etcd]
EOF
done

cat <<EOF >> "${CACHE_DIR}/cluster.yml"
services:
    kube-controller:
      cluster_cidr: 10.42.0.0/16
      service_cluster_ip_range: 10.43.0.0/16

network:
  plugin: none

ingress:
  provider: none
EOF

# Be better if we actually polled for SSH access here
sleep 60

(cd "${CACHE_DIR}" && rke up)

for i in $(seq 1 "$NODE_COUNT"); do
    kubectl --kubeconfig=kube_config_cluster.yml annotate node "ros-vm$i" "kube-router.io/bgp-local-addresses=192.168.98.1${i}"
done

kubectl --kubeconfig=kube_config_cluster.yml apply -f kube-router.yml

wait