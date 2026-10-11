#!/bin/sh

#### derived from https://github.com/jokokucing/Origami-Linux/blob/main/modules/custom-kernel/custom-kernel.sh
#### Hardened for EL10.
#### DNF5 is a soft requirement; DNF4 should work with minor tweaks.
#### NOTE: this module is largely untested.  caveat emptor.
####
#### Module options (JSON in $1):
####   kernel:     cachyos-lto (default) | ml | hyperscale | stock
####                 cachyos-lto  kernel-cachyos-lto from COPR (clang/LTO build)
####                 ml           ELRepo kernel-ml (mainline, unsigned for Secure Boot)
####                 hyperscale   CentOS Hyperscale SIG kernel
####                 stock        keep the base image kernel; only build modules for it
####   initramfs:  true|false     regenerate the initramfs
####   nvidia:     true|false     build the NVIDIA driver from the upstream .run
####   sign:       {key, cert, mok-password}   SecureBoot signing

set -eu

log() { printf '[custom-kernel] %s\n' "$*"; }
err() { printf '[custom-kernel] Error: %s\n' "$*" >&2; }

log "Starting custom-kernel module..."

# ---------------------------------------------------------------------------
# Build-time dependency tracking
# ---------------------------------------------------------------------------
# Call track_build_deps BEFORE installing anything that is only needed to
# build. Only packages that were NOT part of the base image (see snapshot
# below) get recorded, so base image packages are never removed.
#
# cleanup_build_deps runs from an EXIT trap (success or failure), removes the
# recorded packages (plus whatever dnf considers newly-unneeded dependencies
# of them), and then cleans the dnf caches.

BUILD_DEPS=""

# Snapshot of what the base image shipped, taken before anything is installed.
# track_build_deps checks this rather than the live rpmdb, so a package that an
# earlier step pulled in as a dependency (e.g. gcc/clang via kernel-devel) is
# still tracked when a later step names it explicitly.
_PRE_PKGS=$(mktemp)
rpm -qa --qf '%{NAME}\n' | sort -u >"${_PRE_PKGS}"

# Remember whether the akmods account pre-existed (the package scriptlets
# create it and removing the package does not delete it).
_AKMODS_USER_PRE=false
getent passwd akmods >/dev/null 2>&1 && _AKMODS_USER_PRE=true
_AKMODS_GROUP_PRE=false
getent group akmods >/dev/null 2>&1 && _AKMODS_GROUP_PRE=true

track_build_deps() {
    for _p in "$@"; do
        grep -qx "${_p}" "${_PRE_PKGS}" && continue
        case " ${BUILD_DEPS} " in
        *" ${_p} "*) ;;
        *) BUILD_DEPS="${BUILD_DEPS} ${_p}" ;;
        esac
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

    # The akmods account is created by package scriptlets and survives removal.
    if [ "${_AKMODS_USER_PRE}" = "false" ] && getent passwd akmods >/dev/null 2>&1; then
        log "Removing stray akmods user."
        userdel akmods 2>/dev/null || true
    fi
    if [ "${_AKMODS_GROUP_PRE}" = "false" ] && getent group akmods >/dev/null 2>&1; then
        log "Removing stray akmods group."
        groupdel akmods 2>/dev/null || true
    fi

    rm -f "${_PRE_PKGS}"

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

# Per-kernel settings.
#   KERNEL_REPLACE      remove the base image kernel and install another
#   KERNEL_SIGN         the kernel image itself needs our SecureBoot signature
#   MODULE_SIGN_SCOPE   all      = sign every module (kernel ships unsigned)
#                       unsigned = sign only modules without a signature
#                                  (leave vendor-signed modules alone)
#   KERNEL_PKG          package whose version defines the kernel version
#   KERNEL_PACKAGES     packages to install (stock: devel tree only)
#   KERNEL_BUILD_PKGS   build-only packages to remove again at the end
#   KERNEL_REPO_OPT     extra dnf option needed to see the kernel packages
#   KERNEL_VERSION_MARK glob the resulting kernel version must match
KERNEL_REPLACE=true
KERNEL_SIGN=true
MODULE_SIGN_SCOPE=all
KERNEL_REPO_OPT=""
KERNEL_VERSION_MARK=""

case "${KERNEL_TYPE}" in
cachyos-lto)
    COPR_REPO="bieszczaders/kernel-cachyos-lto"
    KERNEL_PKG="kernel-cachyos-lto"
    KERNEL_PACKAGES="kernel-cachyos-lto kernel-cachyos-lto-core kernel-cachyos-lto-modules kernel-cachyos-lto-devel-matched"
    KERNEL_BUILD_PKGS="kernel-cachyos-lto-devel-matched kernel-cachyos-lto-devel"
    ;;
ml | kernel-ml)
    KERNEL_TYPE="ml"
    KERNEL_PKG="kernel-ml-core"
    # core/modules/modules-core come in as dependencies
    KERNEL_PACKAGES="kernel-ml kernel-ml-devel kernel-ml-modules-extra"
    KERNEL_BUILD_PKGS="kernel-ml-devel"
    KERNEL_REPO_OPT="--enablerepo=elrepo-kernel"
    KERNEL_VERSION_MARK="*.elrepo.*"
    ;;
hyperscale)
    KERNEL_PKG="kernel-core"
    KERNEL_PACKAGES="kernel kernel-modules-extra kernel-devel kernel-devel-matched"
    KERNEL_BUILD_PKGS="kernel-devel kernel-devel-matched"
    KERNEL_VERSION_MARK="*.hs*"
    ;;
stock)
    KERNEL_REPLACE=false
    KERNEL_SIGN=false
    MODULE_SIGN_SCOPE=unsigned
    KERNEL_PKG="kernel-core"
    # KERNEL_PACKAGES is set below to the devel package for the EXACT installed
    # kernel version (kernel-devel-matched would let dnf downgrade the kernel
    # to whatever version the repos happen to carry).
    KERNEL_PACKAGES=""
    KERNEL_BUILD_PKGS="kernel-devel-matched kernel-devel"
    ;;
*)
    err "Unsupported kernel type: ${KERNEL_TYPE}"
    err "This module supports: cachyos-lto, ml, hyperscale, stock"
    exit 1
    ;;
esac

log "Kernel type: ${KERNEL_TYPE}"

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

# True if the kernel headers declare the two-argument v4l2_fh_add()/v4l2_fh_del()
# (a newer API that some EL kernels backport) while v4l2loopback's compat shim
# still assumes the one-argument form for this kernel version.
v4l2loopback_needs_compat_patch() {
    _hdr="${KERNEL_SOURCE}/include/media/v4l2-fh.h"
    [ -f "${_hdr}" ] || return 1
    grep -Eq 'v4l2_fh_add\(struct v4l2_fh \*fh, struct file \*filp\)' "${_hdr}"
}

# Remove the one-argument compat defines from a v4l2loopback source tree.
# Returns 1 if the source file is missing, 2 if the defines are not present.
_patch_v4l2loopback_src() {
    _f="$1/v4l2loopback.c"
    _re='^#[[:space:]]*define[[:space:]]+v4l2_fh_(add|del)\(fh,[[:space:]]*filp\)[[:space:]]+v4l2_fh_(add|del)\(fh\)[[:space:]]*$'
    [ -f "${_f}" ] || return 1
    grep -Eq "${_re}" "${_f}" || return 2
    sed -i -E "/${_re}/d" "${_f}"
}

# Build v4l2loopback directly from the akmod's source RPM with the compat
# defines removed, and install it for the running (stock) kernel.
build_v4l2loopback_patched() {
    log "Kernel headers use the two-argument v4l2_fh_add/del API; building v4l2loopback with a compat patch."

    _srpm=$(readlink -f /usr/src/akmods/v4l2loopback-kmod.latest 2>/dev/null) || true
    if [ ! -f "${_srpm:-}" ]; then
        _srpm=$(ls /usr/src/akmods/v4l2loopback-kmod-*.src.rpm 2>/dev/null | sort -V | tail -n 1) || true
    fi
    [ -f "${_srpm:-}" ] || { err "v4l2loopback akmod source RPM not found under /usr/src/akmods"; return 1; }

    for _tool in cpio gcc make; do
        if ! command -v "${_tool}" >/dev/null 2>&1; then
            track_build_deps "${_tool}"
            dnf -y install "${_tool}"
        fi
    done

    _wd=$(mktemp -d)
    ( cd "${_wd}" && rpm2cpio "${_srpm}" | cpio -idm --quiet ) \
        || { err "Failed to unpack ${_srpm}"; rm -rf "${_wd}"; return 1; }

    _tb=$(find "${_wd}" -maxdepth 1 -name 'v4l2loopback-*.tar.*' | head -n 1)
    [ -n "${_tb}" ] || { err "v4l2loopback source tarball not found in ${_srpm}"; rm -rf "${_wd}"; return 1; }

    mkdir "${_wd}/src"
    tar -xf "${_tb}" -C "${_wd}/src" \
        || { err "Failed to extract ${_tb}"; rm -rf "${_wd}"; return 1; }
    _csrc=$(find "${_wd}/src" -name v4l2loopback.c | head -n 1)
    [ -n "${_csrc}" ] || { err "v4l2loopback.c not found in the source tarball"; rm -rf "${_wd}"; return 1; }
    _src=$(dirname "${_csrc}")

    _rc=0
    _patch_v4l2loopback_src "${_src}" || _rc=$?
    if [ "${_rc}" -ne 0 ]; then
        err "Could not apply the compat patch (code ${_rc}): the expected one-argument v4l2_fh_add/del defines were not found."
        rm -rf "${_wd}"
        return 1
    fi
    log "Removed the one-argument v4l2_fh_add/del compat defines."

    log "Compiling v4l2loopback against ${KERNEL_SOURCE}"
    make -C "${KERNEL_SOURCE}" M="${_src}" modules \
        || { err "Patched v4l2loopback build failed"; rm -rf "${_wd}"; return 1; }
    _ko="${_src}/v4l2loopback.ko"
    [ -f "${_ko}" ] || { err "v4l2loopback.ko not produced"; rm -rf "${_wd}"; return 1; }

    strip --strip-debug "${_ko}" 2>/dev/null || true
    _dest="/usr/lib/modules/${KERNEL_VERSION}/extra/v4l2loopback"
    install -d -m 0755 "${_dest}"
    install -m 0644 "${_ko}" "${_dest}/v4l2loopback.ko"
    xz --check=crc32 --lzma2=dict=512KiB -f "${_dest}/v4l2loopback.ko"
    depmod -a "${KERNEL_VERSION}"

    # The akmod pulled in the userspace v4l2loopback package as a dependency;
    # keep it (no kmod RPM exists in this path to hold it in place).
    dnf -y mark install v4l2loopback >/dev/null 2>&1 || true

    rm -rf "${_wd}"
    find "${_dest}" -name 'v4l2loopback.ko*' | grep -q . \
        || { err "v4l2loopback module missing after install"; return 1; }
    log "Installed patched v4l2loopback to ${_dest}"
}

# Print every version-release for which EVERY package named in $1
# (space-separated) is available from the enabled repos, newest first.
complete_kernel_versions() {
    _avail=$(dnf -q repoquery --available --showduplicates \
        --queryformat '%{name} %{version}-%{release}\n' $1 2>/dev/null | sort -u)
    [ -n "${_avail}" ] || return 0
    for _v in $(printf '%s\n' "${_avail}" | awk '{print $2}' | sort -uVr); do
        _ok=true
        for _n in $1; do
            printf '%s\n' "${_avail}" | grep -qx "${_n} ${_v}" || { _ok=false; break; }
        done
        [ "${_ok}" = "true" ] && printf '%s\n' "${_v}"
    done
    return 0
}

# Make the repository that carries the selected kernel available.
setup_kernel_repo() {
    case "${KERNEL_TYPE}" in
    cachyos-lto)
        log "Enabling COPR repo: ${COPR_REPO}"
        dnf -y copr enable "${COPR_REPO}"
        ;;
    ml)
        log "Enabling ELRepo (kernel-ml)."
        # The v2 key is the one EL10's crypto policy accepts.
        rpm --import https://www.elrepo.org/RPM-GPG-KEY-v2-elrepo.org
        dnf -y install "https://www.elrepo.org/elrepo-release-${EL_VERSION}.el${EL_VERSION}.elrepo.noarch.rpm"
        ;;
    hyperscale)
        log "Enabling CentOS Hyperscale SIG kernel repo."
        dnf -y install centos-release-hyperscale-kernel
        ;;
    stock)
        ;;
    esac
}

# Drop the repo configuration again once the kernel is installed.
cleanup_kernel_repo() {
    case "${KERNEL_TYPE}" in
    cachyos-lto)
        rm -f /etc/yum.repos.d/*copr*
        ;;
    ml)
        dnf -y remove --setopt=clean_requirements_on_remove=False elrepo-release || true
        rm -f /etc/yum.repos.d/elrepo*.repo
        ;;
    hyperscale)
        dnf -y remove --setopt=clean_requirements_on_remove=False centos-release-hyperscale-kernel || true
        rm -f /etc/yum.repos.d/*hyperscale*.repo
        ;;
    stock)
        ;;
    esac
}

sign_kernel() {
    _vmlinuz="/usr/lib/modules/${KERNEL_VERSION}/vmlinuz"
    [ -f "${_vmlinuz}" ] || { err "Kernel image not found: ${_vmlinuz}"; return 1; }
    # Strip any pre-existing signature so ours is the only one (no-op if unsigned).
    sbattach --remove "${_vmlinuz}" >/dev/null 2>&1 || true
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

# True if this module should be signed with our key.
_needs_signing() {
    [ "${MODULE_SIGN_SCOPE}" = "all" ] && return 0
    # "unsigned": leave modules that already carry a signer alone.
    [ -z "$(modinfo -F signer "$1" 2>/dev/null)" ]
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
        _needs_signing "${_mod}" || continue
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
# epel-release ships in CentOS Stream's extras repo; the upstream "latest" URL
# can be older than what the base image already has and would downgrade it.
rpm -q epel-release >/dev/null 2>&1 || dnf -y install epel-release
dnf -y install dnf-plugins-core
dnf config-manager --set-enabled crb

# ---------------------------------------------------------------------------
# Install kernel
# ---------------------------------------------------------------------------

if [ "${KERNEL_REPLACE}" = "true" ]; then
    # Set up the repo first so a bad/unavailable repo fails before we remove
    # the working kernel.
    setup_kernel_repo

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
else
    log "Keeping the stock kernel; installing only its matching devel tree."
    # No kernel is installed here, but keep the hooks quiet in case a scriptlet fires.
    disable_kernel_install_hooks
    STOCK_VERSION=$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}\n' | sort -V | tail -n 1) || exit 1
    STOCK_ARCH=$(rpm -E %_arch)
    log "Installed stock kernel: ${STOCK_VERSION}"

    # The repos can lag the base image. Everything we need has to exist at ONE
    # version: every kernel package the base ships plus kernel-devel. Use the
    # installed version if the repos carry the full set for it; otherwise fall
    # back to the newest version for which they do.
    STOCK_KPKGS=$(rpm -qa --qf '%{NAME}\n' \
        | grep -E '^kernel(-core|-modules|-modules-core|-modules-extra)?$' | sort -u | tr '\n' ' ')
    STOCK_NEED="${STOCK_KPKGS}kernel-devel"
    log "Packages that must match: ${STOCK_NEED}"

    _complete=$(complete_kernel_versions "${STOCK_NEED}")
    if [ -z "${_complete}" ]; then
        err "No kernel version in the enabled repos provides all of: ${STOCK_NEED}"
        exit 1
    fi
    if printf '%s\n' "${_complete}" | grep -qx "${STOCK_VERSION}"; then
        STOCK_TARGET="${STOCK_VERSION}"
    else
        STOCK_TARGET=$(printf '%s\n' "${_complete}" | head -n 1)
    fi

    if [ "${STOCK_TARGET}" != "${STOCK_VERSION}" ]; then
        log "WARNING: the repos do not carry a complete set for the installed ${STOCK_VERSION}."
        log "Switching the stock kernel to the newest complete set: ${STOCK_TARGET}."
        _pkgs=""
        for _n in ${STOCK_KPKGS}; do _pkgs="${_pkgs} ${_n}-${STOCK_TARGET}"; done
        _newest=$(printf '%s\n%s\n' "${STOCK_VERSION}" "${STOCK_TARGET}" | sort -V | tail -n 1)
        if [ "${_newest}" = "${STOCK_VERSION}" ]; then
            # shellcheck disable=SC2086
            dnf -y downgrade ${_pkgs}
        else
            # shellcheck disable=SC2086
            dnf -y install ${_pkgs}
        fi
        # The old kernel's files are gone with its packages, but its
        # untracked initramfs (and the directory) are not.
        rm -rf "/usr/lib/modules/${STOCK_VERSION}.${STOCK_ARCH}"
        # The new kernel has no initramfs yet; without one the image cannot boot.
        if [ "${INITRAMFS}" != "true" ]; then
            log "Forcing initramfs generation for the switched kernel."
            INITRAMFS=true
        fi
    fi
    KERNEL_PACKAGES="kernel-devel-${STOCK_TARGET}"
fi

log "Installing kernel packages: ${KERNEL_PACKAGES}"
# Devel packages and akmods are build-only; the kernel itself stays.
# shellcheck disable=SC2086
track_build_deps ${KERNEL_BUILD_PKGS} akmods
# shellcheck disable=SC2086
dnf -y ${KERNEL_REPO_OPT} install ${KERNEL_PACKAGES} akmods

KERNEL_VERSION=$(rpm -q "${KERNEL_PKG}" --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -n 1) || exit 1
log "Kernel version: ${KERNEL_VERSION}"

if [ "${KERNEL_TYPE}" = "stock" ] && [ "${KERNEL_VERSION}" != "${STOCK_TARGET}.${STOCK_ARCH}" ]; then
    err "The stock kernel changed unexpectedly during install (expected ${STOCK_TARGET}.${STOCK_ARCH}, got ${KERNEL_VERSION})."
    exit 1
fi
KERNEL_SOURCE="/usr/src/kernels/${KERNEL_VERSION}"

if [ -n "${KERNEL_VERSION_MARK}" ]; then
    # shellcheck disable=SC2254
    case "${KERNEL_VERSION}" in
    ${KERNEL_VERSION_MARK}) ;;
    *)
        err "Expected a ${KERNEL_TYPE} kernel (version matching '${KERNEL_VERSION_MARK}'),"
        err "but the resulting kernel is ${KERNEL_VERSION}."
        err "The repo may not carry a kernel for EL${EL_VERSION}, or the stock kernel won on version."
        exit 1
        ;;
    esac
fi

if [ ! -d "${KERNEL_SOURCE}" ] && [ ! -e "/lib/modules/${KERNEL_VERSION}/build" ]; then
    err "No kernel devel tree for ${KERNEL_VERSION} (looked in ${KERNEL_SOURCE})."
    if [ "${KERNEL_TYPE}" = "stock" ]; then
        err "The repos may no longer carry kernel-devel for the base image's exact kernel."
    fi
    exit 1
fi

log "Restoring kernel install scripts."
restore_kernel_install_hooks

log "Cleaning up kernel source repo configuration."
cleanup_kernel_repo

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

if [ "${KERNEL_TYPE}" = "stock" ] && v4l2loopback_needs_compat_patch; then
    # Stock kernel whose headers are newer than the module expects.
    build_v4l2loopback_patched || exit 1
else
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
fi

log "Cleaning RPM Fusion Free repo."
dnf -y remove rpmfusion-free-release
rm -f /etc/yum.repos.d/rpmfusion-free*.repo

# ---------------------------------------------------------------------------
# Build Nvidia via upstream .run payload
# ---------------------------------------------------------------------------

if [ "${NVIDIA}" = "true" ]; then
    log "Starting upstream NVIDIA payload build for kernel ${KERNEL_VERSION}."

    if [ ! -d "$KERNEL_SOURCE" ]; then
        err "Missing kernel source path: $KERNEL_SOURCE"
        exit 1
    fi

    # Build the module with the same compiler family the kernel was built with.
    # kernel-cachyos-lto is a clang/LTO build; the EL-style kernels (ml,
    # hyperscale, stock) are GCC builds.
    NVIDIA_CLANG=false
    if [ -r "${KERNEL_SOURCE}/.config" ]; then
        if grep -q '^CONFIG_CC_IS_CLANG=y' "${KERNEL_SOURCE}/.config"; then
            NVIDIA_CLANG=true
        fi
    elif [ "${KERNEL_TYPE}" = "cachyos-lto" ]; then
        NVIDIA_CLANG=true
    fi
    log "NVIDIA build toolchain: $([ "${NVIDIA_CLANG}" = "true" ] && echo clang/LLVM || echo gcc)"

    # Explicit Mesa drivers ensure software fallback works in VMs
    NVIDIA_BUILD_TOOLS="perl elfutils-libelf-devel checkpolicy selinux-policy-devel dkms gcc make"
    if [ "${NVIDIA_CLANG}" = "true" ]; then
        NVIDIA_BUILD_TOOLS="${NVIDIA_BUILD_TOOLS} clang llvm lld"
    fi
    NVIDIA_RUNTIME_DEPS="libglvnd libglvnd-egl libglvnd-gles libglvnd-glx libglvnd-opengl egl-x11 egl-wayland2 egl-gbm xorg-x11-server-Xwayland mesa-dri-drivers mesa-vulkan-drivers mesa-libEGL mesa-libGL"

    # Only the compile toolchain is tracked for removal; runtime deps and
    # base utilities (curl, tar, bzip2, policycoreutils) are left alone.
    # shellcheck disable=SC2086
    track_build_deps $NVIDIA_BUILD_TOOLS

    # shellcheck disable=SC2086
    dnf install -y --setopt=install_weak_deps=False --setopt=tsflags=noscripts --setopt=skip_unavailable=1 $NVIDIA_BUILD_TOOLS $NVIDIA_RUNTIME_DEPS curl tar bzip2 policycoreutils

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
    if [ "${NVIDIA_CLANG}" = "true" ]; then
        NVIDIA_ENV="CC=clang LLVM=1 LD=ld.lld IGNORE_CC_MISMATCH=1"
    else
        NVIDIA_ENV="IGNORE_CC_MISMATCH=1"
    fi
    log "Running NVIDIA installer (${NVIDIA_ENV})..."
    # shellcheck disable=SC2086
    env ${NVIDIA_ENV} "$NVIDIA_SRC_DIR/nvidia-installer" \
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
    if [ "${KERNEL_SIGN}" = "true" ]; then
        log "Signing the kernel."
        sign_kernel || exit 1
    else
        log "Keeping the vendor-signed kernel image (${KERNEL_TYPE})."
    fi

    log "Signing kernel modules (scope: ${MODULE_SIGN_SCOPE})."
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

# bootc expects exactly one kernel under /usr/lib/modules. Only directories that
# hold a vmlinuz are kernels; some kernel packages (e.g. Hyperscale) also ship
# kabi-* directories, which are not.
_kernels=$(find /usr/lib/modules -mindepth 2 -maxdepth 2 -name vmlinuz | sed 's|/vmlinuz$||' | sort)
if [ "${_kernels}" != "/usr/lib/modules/${KERNEL_VERSION}" ]; then
    err "Expected exactly one kernel (/usr/lib/modules/${KERNEL_VERSION}) with a vmlinuz, found:"
    printf '%s\n' "${_kernels:-<none>}" >&2
    exit 1
fi

if [ "${SECURE_BOOT}" = "true" ] && [ "${KERNEL_SIGN}" = "true" ]; then
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
