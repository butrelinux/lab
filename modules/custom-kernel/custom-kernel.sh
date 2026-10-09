#!/bin/sh

#### derived from https://github.com/jokokucing/Origami-Linux/blob/main/modules/custom-kernel/custom-kernel.sh
#### Hardened for EL10 + cachyos-lto only.
#### DNF5 is a soft requirement; DNF4 should work with minor tweaks.
#### NOTE: this module is largely untested.  caveat emptor.

set -eu

log() { printf '[custom-kernel] %s\n' "$*"; }
err() { printf '[custom-kernel] Error: %s\n' "$*" >&2; }

log "Starting custom-kernel module..."

# ---------------------------------------------------------------------------
# Build-time dependency tracking
# ---------------------------------------------------------------------------
# Call track_build_deps BEFORE installing anything that is only needed to
# build. Only packages that are NOT already installed get recorded, so
# packages that were part of the base image are never removed.
#
# cleanup_build_deps runs from an EXIT trap (success or failure), removes the
# recorded packages (plus whatever dnf considers newly-unneeded dependencies
# of them), and then cleans the dnf caches.

BUILD_DEPS=""

track_build_deps() {
    for _p in "$@"; do
        if ! rpm -q --quiet "${_p}" 2>/dev/null; then
            case " ${BUILD_DEPS} " in
            *" ${_p} "*) ;;
            *) BUILD_DEPS="${BUILD_DEPS} ${_p}" ;;
            esac
        fi
    done
}

cleanup_build_deps() {
    _rc=$?
    trap - EXIT
    set +e

    # Reduce the tracked list to what is actually installed now.
    _installed=""
    for _p in ${BUILD_DEPS}; do
        rpm -q --quiet "${_p}" 2>/dev/null && _installed="${_installed} ${_p}"
    done

    # Drop anything that a package OUTSIDE the removal set depends on,
    # iterating until stable (dropping one can block another).
    _pass=0
    while [ "${_pass}" -lt 10 ]; do
        _pass=$((_pass + 1))
        _changed=false
        _keep=""
        for _p in ${_installed}; do
            _blocked=false
            for _u in $(rpm -q --whatrequires --qf '%{NAME}\n' "${_p}" 2>/dev/null \
                        | grep -v '^no package requires' | sort -u); do
                [ "${_u}" = "${_p}" ] && continue
                case " ${_installed} " in
                *" ${_u} "*) ;;
                *) _blocked=true; break ;;
                esac
            done
            if [ "${_blocked}" = "true" ]; then
                log "Keeping ${_p} (required by a non-build package)."
                _changed=true
            else
                _keep="${_keep} ${_p}"
            fi
        done
        _installed="${_keep}"
        [ "${_changed}" = "false" ] && break
    done

    if [ -n "${_installed}" ]; then
        log "Removing build-time dependencies:${_installed}"
        # shellcheck disable=SC2086
        dnf -y remove ${_installed} \
            || err "Failed to remove some build-time dependencies (non-fatal)."
    fi

    log "Cleaning DNF caches."
    dnf -y clean all >/dev/null 2>&1
    rm -rf /var/cache/dnf/* /var/tmp/dnf-* /var/cache/libdnf5 2>/dev/null

    exit "${_rc}"
}

trap cleanup_build_deps EXIT

# ---------------------------------------------------------------------------
# Distro detection (EL10 only)
# ---------------------------------------------------------------------------

if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
    rhel | centos | rocky | almalinux | ol | miraclelinux | virtuozzo | butrelinux)
        ;;
    *)
        err "Unsupported distro: ${ID:-<unknown>}. This module only supports EL10."
        exit 1
        ;;
    esac
else
    err "/etc/os-release not found."
    exit 1
fi

EL_VERSION=$(rpm -E %rhel)
if [ "${EL_VERSION}" != "10" ]; then
    err "This module only supports EL10 (detected: EL${EL_VERSION})."
    exit 1
fi

log "Detected base distro: EL ${EL_VERSION}"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

KERNEL_TYPE=$(printf '%s' "$1" | jq -r '.kernel // empty')
INITRAMFS=$(printf '%s' "$1"   | jq -r '.initramfs // false')
NVIDIA=$(printf '%s' "$1"      | jq -r '.nvidia // false')
SIGNING_KEY=$(printf '%s' "$1" | jq -r '.sign.key // ""')
SIGNING_CERT=$(printf '%s' "$1"| jq -r '.sign.cert // ""')
MOK_PASSWORD=$(printf '%s' "$1"| jq -r '.sign["mok-password"] // ""')
SECURE_BOOT=false

if [ -z "${KERNEL_TYPE}" ]; then
    KERNEL_TYPE="cachyos-lto"
fi

if [ "${KERNEL_TYPE}" != "cachyos-lto" ]; then
    err "Unsupported kernel type: ${KERNEL_TYPE}"
    err "This module only supports: cachyos-lto"
    exit 1
fi

if [ -z "${SIGNING_KEY}" ] && [ -z "${SIGNING_CERT}" ] && [ -z "${MOK_PASSWORD}" ]; then
    log "SecureBoot signing disabled."
elif [ -f "${SIGNING_KEY}" ] && [ -f "${SIGNING_CERT}" ] && [ -n "${MOK_PASSWORD}" ]; then
    SECURE_BOOT=true
    log "SecureBoot signing enabled."
else
    err "Invalid signing config:"
    err "  sign.key:          ${SIGNING_KEY:-<empty>}"
    err "  sign.cert:         ${SIGNING_CERT:-<empty>}"
    err "  sign.mok-password: ${MOK_PASSWORD:-<empty>}"
    exit 1
fi

if [ "${SECURE_BOOT}" = "true" ]; then
    openssl pkey -in "${SIGNING_KEY}"  -noout >/dev/null 2>&1 \
        || { err "sign.key is not a valid private key"; exit 1; }
    openssl x509 -in "${SIGNING_CERT}" -noout >/dev/null 2>&1 \
        || { err "sign.cert is not a valid X509 cert"; exit 1; }
    _tmp1=$(mktemp); _tmp2=$(mktemp)
    openssl pkey -in "${SIGNING_KEY}"  -pubout        >"${_tmp1}"
    openssl x509 -in "${SIGNING_CERT}" -pubkey -noout >"${_tmp2}"
    if ! cmp -s "${_tmp1}" "${_tmp2}" >/dev/null 2>&1; then
        rm -f "${_tmp1}" "${_tmp2}"
        err "sign.key and sign.cert do not match"
        exit 1
    fi
    rm -f "${_tmp1}" "${_tmp2}"
fi

# ---------------------------------------------------------------------------
# Kernel package resolution (cachyos-lto only)
# ---------------------------------------------------------------------------

COPR_REPO="bieszczaders/kernel-cachyos-lto"
KERNEL_PKG="kernel-cachyos-lto"
KERNEL_PACKAGES="kernel-cachyos-lto kernel-cachyos-lto-core kernel-cachyos-lto-modules kernel-cachyos-lto-devel-matched"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

disable_kernel_install_hooks() {
    for _f in \
        /usr/lib/kernel/install.d/05-rpmostree.install \
        /usr/lib/kernel/install.d/50-dracut.install
    do
        [ -f "${_f}" ] || continue
        mv "${_f}" "${_f}.bak"
        printf '#!/bin/sh\nexit 0\n' >"${_f}"
        chmod +x "${_f}"
    done
}

restore_kernel_install_hooks() {
    for _f in \
        /usr/lib/kernel/install.d/05-rpmostree.install \
        /usr/lib/kernel/install.d/50-dracut.install
    do
        [ -f "${_f}.bak" ] && mv -f "${_f}.bak" "${_f}"
    done
}

sign_kernel() {
    _vmlinuz="/usr/lib/modules/${KERNEL_VERSION}/vmlinuz"
    [ -f "${_vmlinuz}" ] || { err "Kernel image not found: ${_vmlinuz}"; return 1; }
    _tmp=$(mktemp)
    sbsign --key "${SIGNING_KEY}" --cert "${SIGNING_CERT}" --output "${_tmp}" "${_vmlinuz}"
    if ! sbverify --cert "${SIGNING_CERT}" "${_tmp}"; then
        err "Kernel signature verification failed"
        rm -f "${_tmp}"
        return 1
    fi
    cp "${_tmp}" "${_vmlinuz}"
    chmod 0644 "${_vmlinuz}"
    rm -f "${_tmp}"
    sha256sum "${_vmlinuz}" >/tmp/vmlinuz.sha
}

sign_kernel_modules() {
    _module_root="/usr/lib/modules/${KERNEL_VERSION}"
    _sign_file="${_module_root}/build/scripts/sign-file"
    [ -x "${_sign_file}" ] \
        || { err "sign-file not found or not executable: ${_sign_file}"; return 1; }
    _tmplist=$(mktemp)
    find "${_module_root}" -type f \( \
        -name "*.ko" -o -name "*.ko.xz" -o -name "*.ko.zst" -o -name "*.ko.gz" \
    \) >"${_tmplist}"
    # shellcheck disable=SC2094
    while IFS= read -r _mod; do
        case "${_mod}" in
        *.ko)
            "${_sign_file}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${_mod}" \
                || { rm -f "${_tmplist}"; return 1; }
            ;;
        *.ko.xz)
            _raw="${_mod%.xz}"
            xz -d -q "${_mod}"
            "${_sign_file}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${_raw}" \
                || { rm -f "${_tmplist}"; return 1; }
            xz -z -q "${_raw}"
            ;;
        *.ko.zst)
            _raw="${_mod%.zst}"
            zstd -d -q --rm "${_mod}"
            "${_sign_file}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${_raw}" \
                || { rm -f "${_tmplist}"; return 1; }
            zstd -q "${_raw}"
            ;;
        *.ko.gz)
            _raw="${_mod%.gz}"
            gunzip -q "${_mod}"
            "${_sign_file}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${_raw}" \
                || { rm -f "${_tmplist}"; return 1; }
            gzip -q "${_raw}"
            ;;
        esac
    done <"${_tmplist}"
    rm -f "${_tmplist}"
}

create_mok_enroll_unit() {
    _mok_cert="/usr/share/cert/MOK.der"
    _unit_file="/usr/lib/systemd/system/mok-enroll.service"
    _tmp=$(mktemp)
    openssl x509 -in "${SIGNING_CERT}" -outform DER -out "${_tmp}" \
        || { rm -f "${_tmp}"; return 1; }
    mkdir -p "$(dirname "${_mok_cert}")"
    cp "${_tmp}" "${_mok_cert}"
    chmod 0644 "${_mok_cert}"
    rm -f "${_tmp}"
    mkdir -p "$(dirname "${_unit_file}")"
    cat <<EOF > "${_unit_file}"
[Unit]
Description=Enroll MOK key on first boot
ConditionPathExists=${_mok_cert}
ConditionPathExists=!/var/.mok-enrolled

[Service]
Type=oneshot
ExecStart=/bin/sh -c '(echo "${MOK_PASSWORD}"; echo "${MOK_PASSWORD}") | mokutil --import "${_mok_cert}"'
ExecStartPost=/usr/bin/touch /var/.mok-enrolled
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "${_unit_file}"
    systemctl -f enable mok-enroll.service
    log "Created and enabled mok-enroll.service"
}

# ---------------------------------------------------------------------------
# EL10 prerequisite repos (EPEL + CRB)
# ---------------------------------------------------------------------------

log "Enabling EPEL and CRB repos."
track_build_deps dnf-plugins-core
dnf -y install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${EL_VERSION}.noarch.rpm"
dnf -y install dnf-plugins-core
dnf config-manager --set-enabled crb

# ---------------------------------------------------------------------------
# Install kernel
# ---------------------------------------------------------------------------

log "Temporarily disabling kernel install scripts."
disable_kernel_install_hooks

log "Removing default kernel packages."
dnf -y remove \
    kernel \
    kernel-core \
    kernel-modules \
    kernel-modules-core \
    kernel-modules-extra \
    kernel-devel \
    kernel-devel-matched || true
rm -rf /usr/lib/modules/* || true

log "Resolving kernel source (cachyos-lto via COPR)."
log "Enabling COPR repo: ${COPR_REPO}"
dnf -y copr enable "${COPR_REPO}"
log "Installing kernel packages: ${KERNEL_PACKAGES}"
# Devel packages and akmods are build-only; the kernel itself stays.
track_build_deps kernel-cachyos-lto-devel-matched kernel-cachyos-lto-devel akmods
# shellcheck disable=SC2086
dnf -y install $KERNEL_PACKAGES akmods

KERNEL_VERSION=$(rpm -q "${KERNEL_PKG}" --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -n 1) || exit 1
log "Kernel version: ${KERNEL_VERSION}"
KERNEL_SOURCE="/usr/src/kernels/${KERNEL_VERSION}"

log "Restoring kernel install scripts."
restore_kernel_install_hooks

log "Cleaning up kernel source repo configuration."
rm -f /etc/yum.repos.d/*copr*

# ---------------------------------------------------------------------------
# Build v4l2loopback
# ---------------------------------------------------------------------------

log "Building v4l2loopback module for kernel: ${KERNEL_VERSION}"

log "Enabling RPM Fusion Free repo."
dnf -y install \
    "https://download1.rpmfusion.org/free/el/rpmfusion-free-release-${EL_VERSION}.noarch.rpm"

# The kmod RPM is installed manually below, so akmod-v4l2loopback is build-only.
track_build_deps akmod-v4l2loopback
dnf install -y --setopt=install_weak_deps=False --setopt=tsflags=noscripts \
    akmod-v4l2loopback

# Some kernels intentionally do not provide kernel-uname-r, causing akmods'
# DNF install step to fail even though the build itself succeeds. We ignore
# that error and handle installation manually.
akmods --force --verbose --kernels "${KERNEL_VERSION}" --kmod v4l2loopback || true

_kmod_rpm=$(find /var/cache/akmods/v4l2loopback -maxdepth 1 \
    -name "kmod-v4l2loopback-*.rpm" ! -name "*failed*" 2>/dev/null | head -n1)

if [ -n "$_kmod_rpm" ] && [ -f "$_kmod_rpm" ]; then
    _rpm_name=$(rpm -qp --queryformat '%{NAME}\n' "$_kmod_rpm" 2>/dev/null)
    if [ -n "$_rpm_name" ] && ! rpm -q "$_rpm_name" >/dev/null 2>&1; then
        log "Installing built kmod RPM (bypassing kernel-uname-r dependency): ${_kmod_rpm}"
        rpm -ivh --nodeps "$_kmod_rpm"
    else
        log "kmod RPM already installed, skipping manual install."
    fi
    depmod -a "${KERNEL_VERSION}"
    rm -f /var/cache/akmods/v4l2loopback/*.failed.log
else
    # No cached RPM — determine if it was a real build failure
    _fail_found=false
    for _f in /var/cache/akmods/v4l2loopback/*-for-"${KERNEL_VERSION}".failed.log; do
        [ -f "${_f}" ] && _fail_found=true && break
    done
    if [ "${_fail_found}" = "true" ]; then
        err "v4l2loopback akmod build failed:"
        for _f in /var/cache/akmods/v4l2loopback/*-for-"${KERNEL_VERSION}".failed.log; do
            [ -f "${_f}" ] && cat "${_f}"
        done
        exit 1
    fi
    # akmods may have succeeded and cleaned up the RPM itself. Verify the module exists.
    if ! find "/lib/modules/${KERNEL_VERSION}/extra/v4l2loopback/" -name "v4l2loopback.ko*" | grep -q .; then
        err "v4l2loopback kmod not found after build"
        exit 1
    fi
fi

log "Cleaning RPM Fusion Free repo."
dnf -y remove rpmfusion-free-release
rm -f /etc/yum.repos.d/rpmfusion-free*.repo

# ---------------------------------------------------------------------------
# Build Nvidia via upstream .run payload
# ---------------------------------------------------------------------------

if [ "${NVIDIA}" = "true" ]; then
    log "Starting upstream NVIDIA payload build for kernel ${KERNEL_VERSION}."

    # Explicit Mesa drivers ensure software fallback works in VMs
    NVIDIA_BUILD_TOOLS="perl elfutils-libelf-devel checkpolicy selinux-policy-devel clang llvm lld dkms gcc make"
    NVIDIA_RUNTIME_DEPS="libglvnd libglvnd-egl libglvnd-gles libglvnd-glx libglvnd-opengl egl-x11 egl-wayland2 egl-gbm xorg-x11-server-Xwayland mesa-dri-drivers mesa-vulkan-drivers mesa-libEGL mesa-libGL"

    # Only the compile toolchain is tracked for removal; runtime deps and
    # base utilities (curl, tar, bzip2, policycoreutils) are left alone.
    # shellcheck disable=SC2086
    track_build_deps $NVIDIA_BUILD_TOOLS

    # shellcheck disable=SC2086
    dnf install -y --setopt=install_weak_deps=False --setopt=tsflags=noscripts --setopt=skip_unavailable=1 $NVIDIA_BUILD_TOOLS $NVIDIA_RUNTIME_DEPS curl tar bzip2 policycoreutils

    if [ ! -d "$KERNEL_SOURCE" ]; then
        err "Missing kernel source path after installing devel package: $KERNEL_SOURCE"
        exit 1
    fi

    # Resolve the latest NVIDIA version from the directory listing.
    # latest.txt tracks stable/production; directory scanning picks up
    # the newest feature branch as well. Feature branch drivers may be beta.
    log "Resolving latest NVIDIA version from download.nvidia.com..."
    NVIDIA_VERSION=$(curl -fsSL https://download.nvidia.com/XFree86/Linux-x86_64/ | \
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | \
        sort -V | \
        tail -n 1)

    if [ -z "$NVIDIA_VERSION" ]; then
        err "Failed to resolve latest NVIDIA version from directory listing."
        exit 1
    fi

    NVIDIA_RUN="NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run"
    NVIDIA_URL="https://download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_VERSION}/${NVIDIA_RUN}"

    log "Selected NVIDIA version: ${NVIDIA_VERSION}"
    log "Downloading: ${NVIDIA_URL}"

    _tmpdir="$(mktemp -d)"
    curl -fL "$NVIDIA_URL" -o "$_tmpdir/$NVIDIA_RUN"
    chmod +x "$_tmpdir/$NVIDIA_RUN"

    log "Extracting NVIDIA installer payload..."
    (
        cd "$_tmpdir"
        "./$NVIDIA_RUN" --extract-only
    )

    NVIDIA_SRC_DIR="$_tmpdir/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}"
    if [ ! -d "$NVIDIA_SRC_DIR" ]; then
        err "Extracted NVIDIA source directory not found: $NVIDIA_SRC_DIR"
        exit 1
    fi

    # Compile and Install (omitted --install-libglvnd so distro controls display routing)
    log "Running NVIDIA installer with Clang/LLVM overrides..."
    env CC=clang LLVM=1 LD=ld.lld IGNORE_CC_MISMATCH=1 "$NVIDIA_SRC_DIR/nvidia-installer" \
        --silent \
        --accept-license \
        --no-questions \
        --no-nouveau-check \
        --no-backup \
        --no-check-for-alternate-installs \
        --kernel-name="${KERNEL_VERSION}" \
        --kernel-source-path="${KERNEL_SOURCE}" \
        --utility-prefix=/usr \
        --opengl-prefix=/usr \
        --compat32-prefix=/usr \
        --x-prefix=/usr

    rm -rf "$_tmpdir"

    # Apply standard configuration files
    mkdir -p /etc/modprobe.d /usr/lib/udev/rules.d /usr/lib/dracut/dracut.conf.d

    cat <<'EOF' > /etc/modprobe.d/nvidia.conf
blacklist nouveau
options nouveau modeset=0
options nvidia-drm modeset=1 fbdev=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
EOF
    chmod 0644 /etc/modprobe.d/nvidia.conf

    cat <<'EOF' > /usr/lib/dracut/dracut.conf.d/99-nvidia.conf
force_drivers+=" nvidia nvidia_modeset nvidia_uvm nvidia_peermem nvidia_drm "
omit_drivers+=" nouveau "
EOF
    chmod 0644 /usr/lib/dracut/dracut.conf.d/99-nvidia.conf

    cat <<'EOF' > /usr/lib/udev/rules.d/60-nvidia.rules
KERNEL=="nvidia", RUN+="/usr/bin/nvidia-modprobe -c 0 -u"
KERNEL=="nvidia_uvm", RUN+="/usr/bin/nvidia-modprobe -c 0 -u"
EOF
    chmod 0644 /usr/lib/udev/rules.d/60-nvidia.rules

    mkdir -p /usr/lib/bootc/kargs.d
    cat <<'EOF' > /usr/lib/bootc/kargs.d/90-nvidia.toml
kargs = [
"rd.driver.blacklist=nouveau",
"modprobe.blacklist=nouveau",
"rd.driver.pre=nvidia",
"nvidia-drm.modeset=1",
"nvidia-drm.fbdev=1"
]
EOF
    chmod 0644 /usr/lib/bootc/kargs.d/90-nvidia.toml

    # Enable systemd services
    systemctl enable nvidia-powerd.service >/dev/null 2>&1 || true
    systemctl enable nvidia-persistenced.service >/dev/null 2>&1 || true

    # Install NVIDIA Container Toolkit
    log "Installing NVIDIA Container Toolkit..."
    curl -fsSL --retry 5 --create-dirs \
        https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
        -o /etc/yum.repos.d/nvidia-container-toolkit.repo
    dnf install -y --setopt=skip_unavailable=1 nvidia-container-toolkit
    rm -f /etc/yum.repos.d/nvidia-container-toolkit.repo

    log "Installing Container Toolkit CDI auto-generation unit."
    mkdir -p /usr/lib/systemd/system
    cat <<'EOF' > /usr/lib/systemd/system/nvctk-cdi.service
[Unit]
Description=NVIDIA Container Toolkit CDI auto-generation
ConditionFileIsExecutable=/usr/bin/nvidia-ctk
ConditionPathExists=!/etc/cdi/nvidia.yaml
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 /usr/lib/systemd/system/nvctk-cdi.service

    mkdir -p /usr/lib/systemd/system-preset
    cat <<'EOF' > /usr/lib/systemd/system-preset/70-nvctk-cdi.preset
enable nvctk-cdi.service
EOF
    chmod 0644 /usr/lib/systemd/system-preset/70-nvctk-cdi.preset

    # Generate module dependencies
    depmod "${KERNEL_VERSION}"
fi

# ---------------------------------------------------------------------------
# SecureBoot signing
# ---------------------------------------------------------------------------

if [ "${SECURE_BOOT}" = "true" ]; then
    log "Signing the kernel."
    sign_kernel || exit 1

    log "Signing kernel modules."
    sign_kernel_modules || exit 1

    log "Creating MOK enroll unit."
    create_mok_enroll_unit || exit 1
fi

# ---------------------------------------------------------------------------
# Cleanup (non-package artefacts; packages are removed by the EXIT trap)
# ---------------------------------------------------------------------------

log "Removing kernel build trees."
rm -rf /usr/lib/modules/*/build /usr/lib/modules/*/source /usr/src/nvidia-*

log "Removing akmods build artefacts."
rm -rf /var/cache/akmods /var/lib/dkms

# ---------------------------------------------------------------------------
# Initramfs
# ---------------------------------------------------------------------------

if [ "${INITRAMFS}" = "true" ]; then
    log "Generating initramfs."
    _tmp=$(mktemp)
    DRACUT_NO_XATTR=1 /usr/bin/dracut \
        --no-hostonly \
        --kver "${KERNEL_VERSION}" \
        --reproducible \
        --add ostree \
        -f "${_tmp}" \
        -v || exit 1
    mkdir -p "/usr/lib/modules/${KERNEL_VERSION}"
    cp "${_tmp}" "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img"
    chmod 0600 "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img"
    rm -f "${_tmp}"
fi

# ---------------------------------------------------------------------------
# Final integrity checks
# ---------------------------------------------------------------------------

if [ "${SECURE_BOOT}" = "true" ]; then
    sha256sum -c /tmp/vmlinuz.sha || { err "Kernel modified after signing."; exit 1; }
    rm -f /tmp/vmlinuz.sha
    log "Integrity check passed."
fi

if [ "${NVIDIA}" = "true" ]; then
    for _name in nvidia nvidia-drm nvidia-modeset nvidia-peermem nvidia-uvm; do
        if ! find "/usr/lib/modules/${KERNEL_VERSION}" -name "${_name}.ko*" | grep -q .; then
            err "Missing Nvidia module: ${_name}.ko*"
            exit 1
        fi
    done
    log "All Nvidia modules present."
fi

log "Custom kernel installation complete."
