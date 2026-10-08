#!/usr/bin/env bash
# BlueBuild module: nix
# Multi-user (daemon) Nix for CentOS Stream 10 bootc images, for runtime
# package management. Self-contained: all unit files are generated below.
#
# Options (recipe.yml):
#   flavor:                  upstream (default) | determinate
#   nix-version:             upstream only; "latest" (default) or a pinned version
#   nix-upgrade:             image (default) | never
#                            image: on boot, upgrade the live Nix if the image's
#                            Nix is newer (never downgrades). never: ship
#                            /etc/nix/no-image-upgrade so machines keep their Nix.
#   build-users:             number of nixbld users (default 32)
#   experimental-features:   list (default [nix-command, flakes])
#   extra-conf:              extra nix.conf lines
#   selinux:                 add SELinux file contexts (default true)
#
# Design:
#   * Nix is installed into /nix at build time (no systemd needed), then
#     moved to /usr/lib/nix-seed/tree, with metadata files beside it.
#   * /nix is an empty mountpoint in the image; nix.mount bind-mounts the
#     persistent /var/lib/nix onto it.
#   * nix-seed.service copies the seed into /var/lib/nix on first boot.
#   * nix-upgrade.service (every boot, before the daemon) brings an existing
#     /var/lib/nix up to the image's Nix when the image's is newer.
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
NIX_UPGRADE=$(cfg '.["nix-upgrade"] // "image"')
BUILD_USERS=$(cfg '.["build-users"] // 32')
FEATURES=$(cfg '(.["experimental-features"] // ["nix-command","flakes"]) | join(" ")')
EXTRA_CONF=$(cfg '.["extra-conf"] // ""')
# NB: jq's `//` treats false as unset, so booleans need the explicit null check.
SELINUX=$(cfg '.selinux | if . == null then true else . end')

case "$FLAVOR" in
  upstream|determinate) ;;
  *) die "flavor must be 'upstream' or 'determinate' (got '$FLAVOR')" ;;
esac
case "$NIX_UPGRADE" in
  image|never) ;;
  *) die "nix-upgrade must be 'image' or 'never' (got '$NIX_UPGRADE')" ;;
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
  # `cp -a store/. dest/` also copies the source dir's own attributes
  # (root:root 0755) onto /nix/store; restore the multi-user layout.
  chown "root:${NIXBLD_GID}" /nix/store
  chmod 1775 /nix/store

  # Nix defaults build-users-group to "nixbld" when run as root, even with an
  # empty config, and the group doesn't exist yet at build time (sysusers
  # creates it at boot). Explicitly disable it for these registration steps;
  # we aren't building anything, only registering paths and creating the profile.
  export NIX_CONF_DIR="$TMP/empty-conf"; mkdir -p "$NIX_CONF_DIR"
  export NIX_CONFIG='build-users-group ='
  export NIX_REMOTE=
  "$nix_storepath/bin/nix-store" --load-db < "$self/.reginfo"
  "$nix_storepath/bin/nix-env" -p /nix/var/nix/profiles/default -i "$nix_storepath"
  unset NIX_CONF_DIR NIX_CONFIG NIX_REMOTE

  install -d -m 0755 /etc/nix
  {
    echo "build-users-group = nixbld"
    echo "experimental-features = ${FEATURES}"
    [ -z "$EXTRA_CONF" ] || printf '%s\n' "$EXTRA_CONF"
  } > /etc/nix/nix.conf
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

if [ "$NIX_UPGRADE" = "never" ]; then
  install -d -m 0755 /etc/nix
  cat > /etc/nix/no-image-upgrade << 'EOF'
# Present: this machine keeps its current Nix; image updates will not upgrade it.
# Delete this file to let the image upgrade Nix on boot (never downgrades).
EOF
fi

# --- seed: the installed tree plus the metadata the upgrader needs -----------
SEED=/usr/lib/nix-seed
PROFILE_BIN=/nix/var/nix/profiles/default/bin
[ -x "$PROFILE_BIN/nix" ] || die "no nix in the default profile after install"

real_nix=$(readlink -f "$PROFILE_BIN/nix")
seed_store=$(dirname "$(dirname "$real_nix")")
case "$seed_store" in /nix/store/*) ;; *) die "unexpected nix location: $real_nix" ;; esac

# Same extraction as the boot-time upgrader uses, so versions compare like-for-like.
seed_ver=$("$PROFILE_BIN/nix" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1 || true)
[ -n "$seed_ver" ] || die "could not determine installed Nix version"
log "seeding Nix ${seed_ver} (${FLAVOR}) from ${seed_store}"

install -d -m 0755 "$SEED/tree"
mkdir -p "$TMP/empty-conf"
# Registration dump of everything in the store, used to register new paths on upgrade.
NIX_CONF_DIR="$TMP/empty-conf" NIX_CONFIG='build-users-group =' NIX_REMOTE= \
  "$PROFILE_BIN/nix-store" --dump-db > "$SEED/reginfo"

cp -a /nix/. "$SEED/tree/"
find /nix -mindepth 1 -delete
echo "$FLAVOR"     > "$SEED/flavor"
echo "$seed_ver"   > "$SEED/version"
echo "$seed_store" > "$SEED/storepath"

# --- first-boot seed ---------------------------------------------------------
cat > /usr/libexec/nix-seed << 'EOF'
#!/usr/bin/bash
set -euo pipefail
SEED=/usr/lib/nix-seed
dest=/var/lib/nix
mkdir -p "$dest"
cp -a "$SEED"/tree/. "$dest"/
cp "$SEED/flavor" "$dest/.flavor"
if command -v restorecon >/dev/null 2>&1; then
  restorecon -RF "$dest" || true
fi
touch "$dest/.seeded"
EOF
chmod 0755 /usr/libexec/nix-seed

# --- boot-time upgrade (never fails the boot) --------------------------------
cat > /usr/libexec/nix-upgrade << 'EOF'
#!/usr/bin/bash
# Upgrade the live Nix from the image's seed when the seed is newer.
# Rules: never downgrade; skip on flavor mismatch; every error path exits 0
# so a failed upgrade can never block boot (the old Nix keeps running).
# Paths are overridable only so the logic can be tested off-box.
set -uo pipefail

SEED=${NIX_SEED_DIR:-/usr/lib/nix-seed}
DEST=${NIX_DEST_DIR:-/var/lib/nix}
PROFILE=${NIX_PROFILE_DIR:-/nix/var/nix/profiles/default}
RUN_DIR=${NIX_RUN_DIR:-/run}

log() { echo "[nix-upgrade] $*"; }
ver_of() { "$1" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1; }

do_upgrade() {
  local seed_store=$1 conf p name
  local -a copied=()
  # This runs before basic.target, when /tmp is still on the read-only root
  # (it only becomes a tmpfs once tmp.mount has run). Keep all scratch space in
  # /run, and point TMPDIR there too, since Nix creates temp dirs of its own
  # (for example when nix-env builds the new profile generation).
  conf=$(mktemp -d "$RUN_DIR/nix-upgrade.XXXXXX") || return 1
  export TMPDIR="$conf" NIX_CONF_DIR="$conf" NIX_CONFIG='build-users-group =' NIX_REMOTE=

  # Leftovers from an interrupted run (copies are renamed into place atomically).
  rm -rf "$DEST"/store/.upgrade-* 2>/dev/null

  for p in "$SEED"/tree/store/*; do
    name=${p##*/}
    [ -e "$DEST/store/$name" ] && continue
    cp -a "$p" "$DEST/store/.upgrade-$name" || { rm -rf "$conf"; return 1; }
    mv "$DEST/store/.upgrade-$name" "$DEST/store/$name" || { rm -rf "$conf"; return 1; }
    copied+=("$name")
  done
  log "copied ${#copied[@]} new store path(s)"

  if command -v restorecon >/dev/null 2>&1; then
    for name in "${copied[@]}"; do restorecon -RF "$DEST/store/$name" || true; done
  fi

  # Register with the NEW Nix (the daemon isn't running yet, so nothing else
  # is using the database), then switch the default profile to it.
  "$seed_store/bin/nix-store" --load-db < "$SEED/reginfo" || { rm -rf "$conf"; return 1; }
  "$seed_store/bin/nix-env" -p "$PROFILE" -i "$seed_store" || { rm -rf "$conf"; return 1; }

  if ! "$PROFILE/bin/nix" --version >/dev/null 2>&1 || [ ! -x "$PROFILE/bin/nix-daemon" ]; then
    log "new profile failed its health check; rolling back"
    "$seed_store/bin/nix-env" -p "$PROFILE" --rollback || true
    rm -rf "$conf"
    return 1
  fi
  rm -rf "$conf"
  return 0
}

seed_ver=$(cat "$SEED/version" 2>/dev/null)     || { log "no seed metadata; skipping"; exit 0; }
seed_flavor=$(cat "$SEED/flavor" 2>/dev/null)   || { log "no seed metadata; skipping"; exit 0; }
seed_store=$(cat "$SEED/storepath" 2>/dev/null) || { log "no seed metadata; skipping"; exit 0; }

inst_flavor=$(cat "$DEST/.flavor" 2>/dev/null || true)
if [ -z "$inst_flavor" ]; then log "no recorded flavor for the live store; skipping"; exit 0; fi
if [ "$inst_flavor" != "$seed_flavor" ]; then
  log "flavor mismatch (live: $inst_flavor, image: $seed_flavor); skipping"
  exit 0
fi

# Only nix-env style profiles are handled; a nix-profile manifest.json default
# profile would need different steps and is deliberately left alone.
if [ ! -e "$PROFILE/manifest.nix" ]; then
  log "default profile is not nix-env style; skipping (unsupported)"
  exit 0
fi

inst_ver=$(ver_of "$PROFILE/bin/nix")
if [ -z "$inst_ver" ]; then log "cannot determine live Nix version; skipping"; exit 0; fi

newest=$(printf '%s\n%s\n' "$seed_ver" "$inst_ver" | sort -V | tail -n1)
if [ "$newest" = "$inst_ver" ]; then
  log "live Nix $inst_ver is not older than the image's $seed_ver; nothing to do"
  exit 0
fi

log "upgrading Nix $inst_ver -> $seed_ver"
if do_upgrade "$seed_store"; then
  log "upgrade complete"
else
  log "upgrade FAILED; continuing with Nix $inst_ver"
fi
exit 0
EOF
chmod 0755 /usr/libexec/nix-upgrade

# --- units -------------------------------------------------------------------
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

# DefaultDependencies=no is required: default service deps put this after
# basic.target (which is after sockets.target), which would make
# "Before=nix-daemon.socket" a dependency cycle.
cat > /usr/lib/systemd/system/nix-upgrade.service << 'EOF'
[Unit]
Description=Upgrade Nix from the booted image's seed when the image's Nix is newer
DefaultDependencies=no
Requires=nix.mount
After=nix.mount
Before=nix-daemon.socket nix-daemon.service
Conflicts=shutdown.target
Before=shutdown.target
ConditionPathExists=!/etc/nix/no-image-upgrade
ConditionPathExists=/var/lib/nix/.seeded

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/nix-upgrade
TimeoutStartSec=10min

[Install]
WantedBy=multi-user.target
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

systemctl enable nix-seed.service nix.mount nix-upgrade.service nix-daemon.socket

# --- SELinux ----------------------------------------------------------------
if [ "$SELINUX" = "true" ]; then
  log "adding SELinux file contexts"
  dnf install -y policycoreutils-python-utils
  semanage fcontext -a -t usr_t  '/var/lib/nix(/.*)?'
  semanage fcontext -a -t bin_t  '/var/lib/nix/store/[^/]+/s?bin(/.*)?'
  semanage fcontext -a -t lib_t  '/var/lib/nix/store/[^/]+/lib(64)?(/.*)?'
  # systemd (init_t) must be able to create the listening socket here; it
  # can't in a usr_t directory.
  semanage fcontext -a -t var_run_t '/var/lib/nix/var/nix/daemon-socket(/.*)?'
  semanage fcontext -a -e /var/lib/nix /nix
fi

dnf clean all
log "done (${FLAVOR}, nix-upgrade=${NIX_UPGRADE})"