#!/usr/bin/env bash
set -Eeuo pipefail

SKIP="${SKIP:-0}"

if [[ "$SKIP" != "1" ]]; then
sudo bash <<'ROOT'
set -Eeuo pipefail

podman pull ghcr.io/butrelinux/lab:latest

podman run 
--rm 
--privileged 
--cgroup-manager=cgroupfs 
-v "$PWD/config.toml:/config.toml:ro" 
-v "$PWD/output:/output" 
-v /var/lib/containers/storage:/var/lib/containers/storage 
quay.io/centos-bootc/bootc-image-builder:latest 
--type anaconda-iso 
--config /config.toml 
ghcr.io/butrelinux/lab:latest
ROOT

rm -f ./test-disk.qcow2
qemu-img create -f qcow2 ./test-disk.qcow2 20G

qemu-system-x86_64 
-enable-kvm 
-cpu host 
-m 4096 
-smp 2 
-drive file=./test-disk.qcow2,if=virtio,format=qcow2 
-cdrom ./output/bootiso/install.iso 
-boot d 
-vga virtio 
-device virtio-net-pci,netdev=n1 
-netdev user,id=n1,hostfwd=tcp:127.0.0.1:2222-:22 
-no-reboot
fi

qemu-system-x86_64 
-enable-kvm 
-cpu host 
-m 2048 
-smp 2 
-drive file=./test-disk.qcow2,if=virtio,format=qcow2 
-vga virtio 
-device virtio-net-pci,netdev=n1 
-netdev user,id=n1,hostfwd=tcp:127.0.0.1:2222-:22
