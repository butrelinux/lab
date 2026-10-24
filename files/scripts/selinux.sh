#!/usr/bin/env bash

# adapted from https://github.com/secureblue/secureblue/blob/live/files/scripts/installselinuxpolicies.sh

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
policy_dir="${script_dir}/selinux"
module="tuned-ppd-logging"

selinux_policy_version="$(rpm -q --qf '%{version}-%{release}' selinux-policy)"

dnf install -y --setopt=install_weak_deps=False \
    "selinux-policy-devel-${selinux_policy_version}"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

make -f /usr/share/selinux/devel/Makefile \
    -C "$policy_dir" \
    "${module}.pp"

semodule -v -X 300 -i "${policy_dir}/${module}.pp"
