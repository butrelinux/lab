#!/usr/bin/env bash
set -Eeuo pipefail

: "${SSH_HOST:?SSH_HOST must be set}"
: "${SSH_PORT:?SSH_PORT must be set}"
: "${SSH_USER:?SSH_USER must be set}"
: "${RESULTS_DIR:?RESULTS_DIR must be set}"
: "${SSHPASS:?SSHPASS must be set}"

mkdir -p "$RESULTS_DIR"

SSH_OPTS=(
  -p "$SSH_PORT"
  -o PreferredAuthentications=password
  -o PubkeyAuthentication=no
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -o NumberOfPasswordPrompts=1
)

guest() {
  sshpass -e ssh "${SSH_OPTS[@]}" \
    "$SSH_USER@$SSH_HOST" "$@"
}

guest_sudo() {
  {
    printf '%s\n' "$SSHPASS"
    printf '%s\n' "$1"
  } | guest 'sudo -S -p "" bash -s'
}

REPORT="$RESULTS_DIR/report.md"
IMAGE_INFO="$RESULTS_DIR/image-info.json"

sleep 360

echo "Testing $SSH_USER@$SSH_HOST:$SSH_PORT"

guest 'cat /etc/os-release' \
  > "$RESULTS_DIR/os-release.txt"

# -sr already produces .x86_64, -m turned out to be unnecessary for el10 packaging conventions
guest 'uname -sr' \
  > "$RESULTS_DIR/uname.txt"


# disables and resets nvidia-related units 
# because github runners don't have a gpu, this is the likely fix for the degraded status on nvidia images
guest_sudo 'units=$(systemctl list-unit-files --no-legend --no-pager |
  grep -oE '^nvidia-[^[:space:]]+')
if [[ -n "$units" ]]; then
  systemctl stop $units || true
  systemctl disable $units || true
  systemctl reset-failed $units || true
fi'

guest 'systemctl is-system-running || true' \
  > "$RESULTS_DIR/system-state.txt"

guest 'cat /usr/share/butrelinux/image-info.json' \
  > "$IMAGE_INFO"

OS_NAME="$(
  sed -n 's/^PRETTY_NAME=//p' "$RESULTS_DIR/os-release.txt" |
    head -n 1 |
    tr -d '"'
)"

KERNEL="$(cat "$RESULTS_DIR/uname.txt")"
SYSTEM_STATE="$(cat "$RESULTS_DIR/system-state.txt")"

PLASMA_VERSION="$(
  guest 'plasmashell --version 2>/dev/null || rpm -q --qf "%{VERSION}-%{RELEASE}\n" plasma-workspace 2>/dev/null || true' \
    2>/dev/null || true
)"
PLASMA_VERSION="${PLASMA_VERSION:-Not detected}"

printf '%s\n' "$PLASMA_VERSION" \
  > "$RESULTS_DIR/plasma-version.txt"

NVIDIA_VERSION="Not applicable"

if grep -qi nvidia "$IMAGE_INFO"; then
  NVIDIA_VERSION="$(
    guest 'modinfo -F version nvidia 2>/dev/null || true' \
      2>/dev/null || true
  )"

  if [[ -z "$NVIDIA_VERSION" ]]; then
    NVIDIA_VERSION="$(
      guest 'cat /proc/driver/nvidia/version 2>/dev/null || true' \
        2>/dev/null || true
    )"
    NVIDIA_VERSION="$(
      printf '%s\n' "$NVIDIA_VERSION" |
        sed -n 's/.*Kernel Module[[:space:]]*\([0-9][^ ]*\).*/\1/p' |
        head -n 1
    )"
  fi

  NVIDIA_VERSION="${NVIDIA_VERSION:-Not detected}"
fi

printf '%s\n' "$NVIDIA_VERSION" \
  > "$RESULTS_DIR/nvidia-version.txt"

MESA_VERSION="$(
  guest 'rpm -q --qf "%{VERSION}-%{RELEASE}\n" mesa-dri-drivers 2>/dev/null || rpm -q --qf "%{VERSION}-%{RELEASE}\n" mesa-libGL 2>/dev/null || true' \
    2>/dev/null |
    sort -u |
    paste -sd ', ' - || true
)"

MESA_VERSION="${MESA_VERSION:-Not detected}"

printf '%s\n' "$MESA_VERSION" \
  > "$RESULTS_DIR/mesa-version.txt"

{
  echo "# Image test report"
  echo
  echo "| Property | Value |"
  echo "|---|---|"
  printf '| OS | %s |\n' "${OS_NAME:-Unknown}"
  printf '| Kernel | `%s` |\n' "$KERNEL"
  printf '| systemd | %s |\n' "$SYSTEM_STATE"
  printf '| KDE Plasma | %s |\n' "$PLASMA_VERSION"
  printf '| Mesa | %s |\n' "$MESA_VERSION"

  if grep -qi nvidia "$IMAGE_INFO"; then
    printf '| NVIDIA driver | %s |\n' "$NVIDIA_VERSION"
  fi
} > "$REPORT"

echo
echo "Report written to $REPORT"
cat "$REPORT"
