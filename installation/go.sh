#!/usr/bin/env bash
set -Eeuo pipefail

SKIPINSTALL="${SKIPINSTALL:-0}"
BUILDONLY="${BUILDONLY:-0}"
CLEAN="${CLEAN:-0}"

if [[ "$SKIPINSTALL" == "1" && "$CLEAN" == "1" ]]; then
  echo "ERROR: SKIPINSTALL and CLEAN cannot both be set to 1."
  exit 1
fi

if [[ "$CLEAN" == "1" ]]; then
  sudo find ./output -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  rm -f ./test-disk.qcow2
fi

if [[ "$SKIPINSTALL" != "1" ]]; then
  # Build the installation ISO.
  sudo bash <<'ROOT'
set -Eeuo pipefail

podman pull ghcr.io/butrelinux/lab:latest

podman run \
  --rm \
  --privileged \
  --cgroup-manager=cgroupfs \
  -v "$PWD/config.toml:/config.toml:ro" \
  -v "$PWD/output:/output" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type anaconda-iso \
  --config /config.toml \
  ghcr.io/butrelinux/lab:latest
ROOT

  if [[ "$BUILDONLY" == "1" ]]; then
    exit 0
  fi

  # Create a fresh test disk.
  rm -f ./test-disk.qcow2
  qemu-img create -f qcow2 ./test-disk.qcow2 20G

  # Run the installer.
  qemu-system-x86_64 \
  -enable-kvm \
  -cpu host \
  -m 4096 \
  -smp 2 \
  -drive file=./test-disk.qcow2,if=virtio,format=qcow2 \
  -cdrom ./output/bootiso/install.iso \
  -boot d \
  -vga virtio \
  -device virtio-net-pci,netdev=n1 \
  -netdev user,id=n1,hostfwd=tcp:127.0.0.1:2222-:22 \
  -no-reboot

echo "Installation complete."
echo "Default username: butrelinux"
echo "Default password: butrelinux"
echo "You can SSH into the installed system using:"
echo "  ssh -p 2222 butrelinux@localhost"

tput bel

read -n 1 -s -p "Press any key to boot up the installed system (or Ctrl+C to exit)..."
echo ""
fi

qemu-system-x86_64 \
  -enable-kvm \
  -cpu host \
  -m 2048 \
  -smp 2 \
  -drive file=./test-disk.qcow2,if=virtio,format=qcow2 \
  -vga virtio \
  -device virtio-net-pci,netdev=n1 \
  -netdev user,id=n1,hostfwd=tcp:127.0.0.1:2222-:22
