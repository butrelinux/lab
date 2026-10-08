#!/usr/bin/env bash
# BlueBuild module: nix
# Multi-user (daemon) Nix for CentOS Stream 10 bootc images, for runtime
# package management. Self-contained: all unit files are generated below.
#
# Options (recipe.yml):
#   flavor:                  upstream (default) | determinate
#   nix-version:             upstream only; "latest" (default) or a pinned version
#   build-users:             number of nixbld users (default 32)
#   experimental-features:   list (default [nix-command, flakes])
#   extra-conf:              extra nix.conf lines
#   selinux:                 add SELinux file contexts (default true)
#
# Design:
#   * Nix is installed into /nix at build time (no systemd needed), then
#     moved to /usr/lib/nix-seed.
#   * /nix is an empty mountpoint in the image; nix.mount bind-mounts the
#     persistent /var/lib/nix onto it.
#   * nix-seed.service copies the seed into /var/lib/nix on first boot.
set -euo pipefail

log() { echo "[nix] $*"; }
die() { echo "[nix] ERROR: $*" >&2; exit 1; }

# --- tooling (needed before we can parse the JSON config) -------------------
need=()
for t in jq curl tar xz; do command -v "$t" >/dev/null 2>&1 || need+=("$t"); done
if [ "${#need[@]}" -gt 0 ]; then
  log "installing build tools: ${need[*]}"
  dnf install -y "${need[@]}"
fi

# --- options ----------------------------------------------------------------
CONFIG="${1:-}"
[ -n "$CONFIG" ] || CONFIG='{}'
cfg() { jq -r "$1" <<<"$CONFIG"; }

FLAVOR=$(cfg '.flavor // "upstream"')
NIX_VERSION=$(cfg '.["nix-version"] // "latest"')
BUILD_USERS=$(cfg '.["build-users"] // 32')
FEATURES=$(cfg '(.["experimental-features"] // ["nix-command","flakes"]) | join(" ")')
EXTRA_CONF=$(cfg '.["extra-conf"] // ""')
# NB: jq's `//` treats false as unset, so booleans need the explicit null check.
SELINUX=$(cfg '.selinux | if . == null then true else . end')

case "$FLAVOR" in
  upstream|determinate) ;;
  *) die "flavor must be 'upstream' or 'determinate' (got '$FLAVOR')" ;;
esac

NIXBLD_GID=30000

# shellcheck disable=SC1091
. /etc/os-release
if [ "${ID:-}" != "centos" ] || [ "${VERSION_ID:-}" != "10" ]; then
  log "WARNING: written for CentOS Stream 10, found ${PRETTY_NAME:-unknown}"
fi

case "$(uname -m)" in
  x86_64)  SYSTEM=x86_64-linux ;;
  aarch64) SYSTEM=aarch64-linux ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ============================================================================
# Flavor: upstream (official tarball, installed by hand; the official
# multi-user installer refuses to run without systemd)
# ============================================================================
install_upstream() {
  if [ "$NIX_VERSION" = "latest" ]; then
    local final_url
    final_url=$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://nixos.org/nix/install)
    NIX_VERSION=$(sed -nE 's|.*/nix-([0-9][^/]*)/install$|\1|p' <<<"$final_url")
    [ -n "$NIX_VERSION" ] || die "could not resolve latest Nix version from: $final_url"
  fi
  log "installing upstream Nix ${NIX_VERSION} (${SYSTEM})"

  local tarball="nix-${NIX_VERSION}-${SYSTEM}.tar.xz"
  local base_url="https://releases.nixos.org/nix/nix-${NIX_VERSION}"
  curl -fsSL -o "$TMP/$tarball"        "$base_url/$tarball"
  curl -fsSL -o "$TMP/$tarball.sha256" "$base_url/$tarball.sha256"
  local expected
  expected=$(awk '{print $1}' "$TMP/$tarball.sha256")
  echo "$expected  $TMP/$tarball" | sha256sum -c - || die "checksum mismatch"

  tar -xf "$TMP/$tarball" -C "$TMP"
  local self="$TMP/nix-${NIX_VERSION}-${SYSTEM}"
  [ -d "$self/store" ] && [ -f "$self/.reginfo" ] || die "unexpected tarball layout"

  local nix_src
  nix_src=$(compgen -G "$self/store/*-nix-${NIX_VERSION}" | head -n1)
  [ -n "$nix_src" ] || die "nix store path not found in tarball"
  local nix_storepath
  nix_storepath="/nix/store/$(basename "$nix_src")"

  # Build users via sysusers (applied at boot). Numeric gid is used for
  # ownership below so nothing depends on the group existing during the build.
  {
    echo "g nixbld ${NIXBLD_GID} -"
    local i
    for i in $(seq 1 "$BUILD_USERS"); do
      echo "u nixbld${i} $((NIXBLD_GID + i)):${NIXBLD_GID} \"Nix build user ${i}\" /var/empty /usr/sbin/nologin"
      # Nix reads group membership via gr_mem, so primary-group-only isn't enough.
      echo "m nixbld${i} nixbld"
    done
  } > /usr/lib/sysusers.d/nix.conf

  # Mirrors the official installer's closure steps.
  install -d -m 0755 /nix
  install -d -m 1775 -o 0 -g "$NIXBLD_GID" /nix/store
  install -d -m 0755 /nix/var/nix/{db,gcroots,profiles,daemon-socket}
  install -d -m 1777 /nix/var/nix/{temproots,profiles/per-user,gcroots/per-user}
  cp -a "$self"/store/. /nix/store/

  # Empty conf during the build so build-users-group isn't consulted.
  export NIX_CONF_DIR="$TMP/empty-conf"; mkdir -p "$NIX_CONF_DIR"
  export NIX_REMOTE=
  "$nix_storepath/bin/nix-store" --load-db < "$self/.reginfo"
  "$nix_storepath/bin/nix-env" -p /nix/var/nix/profiles/default -i "$nix_storepath"
  unset NIX_CONF_DIR NIX_REMOTE

  install -d -m 0755 /etc/nix
  {
    echo "build-users-group = nixbld"
    echo "experimental-features = ${FEATURES}"
    [ -z "$EXTRA_CONF" ] || printf '%s\n' "$EXTRA_CONF"
  } > /etc/nix/nix.conf

  echo "$NIX_VERSION" > "$TMP/installed-version"
}

# ============================================================================
# Flavor: determinate (Determinate Nix Installer, no init system)
# Notes:
#   * The installer chooses the Determinate Nix version; nix-version is ignored.
#   * It creates the nixbld users/group itself (useradd), so no sysusers file.
#   * We provide our own nix-daemon units (below) for both flavors;
#     determinate-nixd's own units are NOT set up with --init none.
# ============================================================================
install_determinate() {
  log "installing Determinate Nix via the Determinate Nix Installer (${SYSTEM})"
  [ "$NIX_VERSION" = "latest" ] || log "note: nix-version is ignored for flavor=determinate"

  local installer="$TMP/nix-installer"
  curl -fsSL -o "$installer" "https://install.determinate.systems/nix/nix-installer-${SYSTEM}"
  chmod +x "$installer"

  local args=(install linux --no-confirm --init none
              --nix-build-user-count "$BUILD_USERS"
              --nix-build-group-id "$NIXBLD_GID")
  # Older installers need --determinate to get Determinate Nix; newer ones
  # default to it and may not know the flag, so only pass it if supported.
  if "$installer" install linux --help 2>&1 | grep -q -- '--determinate'; then
    args+=(--determinate)
  fi

  # Opt out of installer telemetry (ignored if the variable is unknown).
  NIX_INSTALLER_DIAGNOSTIC_ENDPOINT="" "$installer" "${args[@]}"

  [ -x /nix/var/nix/profiles/default/bin/nix ] || die "Determinate Nix install did not produce a default profile"

  # Determinate Nix manages /etc/nix/nix.conf and expects local settings in
  # nix.custom.conf when nix.conf includes it; otherwise append to nix.conf.
  install -d -m 0755 /etc/nix
  local target=/etc/nix/nix.conf
  if grep -qs 'nix.custom.conf' /etc/nix/nix.conf; then
    target=/etc/nix/nix.custom.conf
  fi
  {
    echo "extra-experimental-features = ${FEATURES}"
    [ -z "$EXTRA_CONF" ] || printf '%s\n' "$EXTRA_CONF"
  } >> "$target"

  echo "determinate" > "$TMP/installed-version"
}

case "$FLAVOR" in
  upstream)    install_upstream ;;
  determinate) install_determinate ;;
esac

cat > /etc/profile.d/nix.sh << 'EOF'
# Nix (multi-user)
if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
elif [ -d /nix/var/nix/profiles/default/bin ]; then
  export PATH="/nix/var/nix/profiles/default/bin:$PATH"
fi
EOF

# --- persistence: seed + bind mount ----------------------------------------
# Move the installed tree out of /nix; /nix stays as an empty mountpoint.
install -d -m 0755 /usr/lib/nix-seed
cp -a /nix/. /usr/lib/nix-seed/
find /nix -mindepth 1 -delete
echo "${FLAVOR}: $(cat "$TMP/installed-version")" > /usr/lib/nix-seed/.nix-flavor

cat > /usr/libexec/nix-seed << 'EOF'
#!/usr/bin/bash
set -euo pipefail
dest=/var/lib/nix
mkdir -p "$dest"
cp -a /usr/lib/nix-seed/. "$dest"/
if command -v restorecon >/dev/null 2>&1; then
  restorecon -RF "$dest" || true
fi
touch "$dest/.seeded"
EOF
chmod 0755 /usr/libexec/nix-seed

cat > /usr/lib/systemd/system/nix-seed.service << 'EOF'
[Unit]
Description=Seed the Nix store into /var/lib/nix on first boot
DefaultDependencies=no
RequiresMountsFor=/var/lib
Before=nix.mount
ConditionPathExists=!/var/lib/nix/.seeded

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/nix-seed

[Install]
WantedBy=local-fs.target
EOF

cat > /usr/lib/systemd/system/nix.mount << 'EOF'
[Unit]
Description=Persistent Nix store (bind mount of /var/lib/nix)
Requires=nix-seed.service
After=nix-seed.service
RequiresMountsFor=/var/lib

[Mount]
What=/var/lib/nix
Where=/nix
Type=none
Options=bind

[Install]
WantedBy=local-fs.target
EOF

cat > /usr/lib/systemd/system/nix-daemon.socket << 'EOF'
[Unit]
Description=Nix Daemon Socket
Before=multi-user.target
RequiresMountsFor=/nix/store
ConditionPathIsReadWrite=/nix/var/nix/daemon-socket

[Socket]
ListenStream=/nix/var/nix/daemon-socket/socket

[Install]
WantedBy=sockets.target
EOF

cat > /usr/lib/systemd/system/nix-daemon.service << 'EOF'
[Unit]
Description=Nix Daemon
RequiresMountsFor=/nix/store
RequiresMountsFor=/nix/var/nix/db
ConditionPathIsReadWrite=/nix/var/nix/daemon-socket

[Service]
Environment=NIX_SSL_CERT_FILE=/etc/pki/tls/certs/ca-bundle.crt
ExecStart=@/nix/var/nix/profiles/default/bin/nix-daemon nix-daemon --daemon
KillMode=process
LimitNOFILE=1048576
TasksMax=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl enable nix-seed.service nix.mount nix-daemon.socket

# --- SELinux ----------------------------------------------------------------
if [ "$SELINUX" = "true" ]; then
  log "adding SELinux file contexts"
  dnf install -y policycoreutils-python-utils
  semanage fcontext -a -t usr_t  '/var/lib/nix(/.*)?'
  semanage fcontext -a -t bin_t  '/var/lib/nix/store/[^/]+/s?bin(/.*)?'
  semanage fcontext -a -t lib_t  '/var/lib/nix/store/[^/]+/lib(64)?(/.*)?'
  semanage fcontext -a -e /var/lib/nix /nix
fi

dnf clean all
log "done (${FLAVOR})"