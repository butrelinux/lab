#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="ghcr.io/butrelinux/lab:latest"
BUILDER="ghcr.io/osbuild/image-builder-cli:latest"

SKIPINSTALL="${SKIPINSTALL:-0}"
BUILDONLY="${BUILDONLY:-0}"
CLEAN="${CLEAN:-0}"

OUTPUT_DIR="./output"
DISK="${OUTPUT_DIR}/test-disk.qcow2"
CONFIG="./config.toml"

if [[ "$SKIPINSTALL" == "1" && "$CLEAN" == "1" ]]; then
  echo "ERROR: SKIPINSTALL and CLEAN cannot both be set to 1."
  exit 1
fi

if [[ "$CLEAN" == "1" ]]; then
  sudo find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
fi

mkdir -p "$OUTPUT_DIR"

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Missing $CONFIG"
  exit 1
fi

if [[ "$SKIPINSTALL" != "1" ]]; then
  sudo podman pull "$IMAGE"
  sudo podman pull "$BUILDER"

  sudo podman --cgroup-manager=cgroupfs run \
    --rm \
    --privileged \
    -v "$PWD/$OUTPUT_DIR:/output" \
    -v "$PWD/$CONFIG:/config.toml:ro" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    "$BUILDER" \
    build \
    --bootc-ref "$IMAGE" \
    --blueprint /config.toml \
    --output-dir /output \
    --output-name test-disk \
    qcow2

  if [[ "$BUILDONLY" == "1" ]]; then
    echo "Build complete: $DISK"
    exit 0
  fi
fi

if [[ ! -f "$DISK" ]]; then
  echo "ERROR: Disk not found: $DISK"
  echo "Run without SKIPINSTALL=1 to build it first."
  exit 1
fi

echo "Starting ButreLinux in QEMU..."
echo "Test username: butrelinux"
echo "Test password: butrelinux"
echo "SSH (if enabled in the image): ssh -p 2222 butrelinux@localhost"
echo "Press Ctrl+C to shut down QEMU."

tput bel 2>/dev/null || true

exec sudo qemu-system-x86_64 \
  -enable-kvm \
  -cpu host \
  -m 2048 \
  -smp 2 \
  -drive "file=$DISK,if=virtio,format=qcow2" \
  -vga virtio \
  -device virtio-net-pci,netdev=n1 \
  -netdev user,id=n1,hostfwd=tcp:127.0.0.1:2222-:22
