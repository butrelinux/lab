# butrelinux QEMU test environment

build and run a butrelinux bootc image in QEMU using `image-builder`.

This script builds a bootable QCOW2 disk directly from the butrelinux container image.

## Requirements

The host system needs:

- Bash
- Podman
- QEMU (`qemu-system-x86_64`)
- QEMU KVM support (`/dev/kvm`)
- `qemu-img` if you need to inspect or manage QCOW2 images
- Sudo privileges
- An internet connection to pull container images

The script uses these container images:

- butrelinux: `ghcr.io/butrelinux/lab:latest`
- Image Builder: `ghcr.io/osbuild/image-builder-cli:latest`

## Files

Expected directory layout:

    installation/
    ├── go.sh
    ├── config.toml
    └── output/
        └── test-disk.qcow2

The script creates `output/` automatically. The QCOW2 disk is stored there.

## Configuration

Create a `config.toml` file in the same directory as the script.

For example, the following blueprint configures a default test user:

    [[customizations.user]]
    name = "butrelinux"
    password = "butrelinux"
    groups = ["wheel"]

Keep any additional image-builder customizations you need in this file.

**Security:** These credentials are intended only for disposable local test VMs. Do not use them for production images or expose the VM to untrusted networks.

## Usage

Make the script executable:

    chmod +x go.sh

### Build and boot

Run the script without arguments:

    ./go.sh

The script will:

1. Pull the butrelinux and image-builder container images.
2. Build a QCOW2 disk using image-builder.
3. Start QEMU with the generated disk.
4. Forward host TCP port `2222` to guest TCP port `22`.

### Build only

Build the disk without starting QEMU:

    BUILDONLY=1 ./go.sh

The generated disk will be:

    output/test-disk.qcow2

### Boot an existing disk

Skip the build and boot the existing QCOW2 disk:

    SKIPINSTALL=1 ./go.sh

The disk must already exist.

### Clean and rebuild

Remove generated files in `output/`, rebuild the disk, and start QEMU:

    CLEAN=1 ./go.sh

**Warning:** `CLEAN=1` deletes the contents of the script's `output/` directory. Store anything important elsewhere.

`CLEAN=1` cannot be combined with `SKIPINSTALL=1`.

## Default Test Credentials

The example blueprint configures:

| Setting | Value |
|---|---|
| Username | `butrelinux` |
| Password | `butrelinux` |
| Group | `wheel` |

## SSH Access

The script forwards host port `2222` to guest port `22`.

    ssh -p 2222 butrelinux@localhost


## QEMU Settings

The default VM configuration is:

| Setting | Value |
|---|---|
| Architecture | x86_64 |
| Memory | 2048 MiB |
| CPUs | 2 |
| Disk | `output/test-disk.qcow2` |
| Disk interface | Virtio |
| Graphics | Virtio VGA |
| Networking | User-mode networking |
| SSH forwarding | `127.0.0.1:2222` → guest port `22` |

KVM acceleration is enabled with `-enable-kvm` and `-cpu host`. The host must support KVM for this configuration.

## Notes

- The build runs in a privileged container and uses the host's rootful Podman storage.
- The script requires sudo access for pulling and building container images.
- The output directory is mounted into the image-builder container.
- The script uses the `latest` tags for both container images. For reproducible testing, consider pinning image versions or digests.
- This is a local development and testing workflow, not a production image deployment process.