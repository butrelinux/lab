#!/usr/bin/env bash

# adapted from https://github.com/secureblue/secureblue/blob/live/files/scripts/installselinuxpolicies.sh

set -euo pipefail

selinux_policy_version="$(rpm -q --qf '%{version}-%{release}' selinux-policy)"

dnf install -y --setopt=install_weak_deps=False \
    "selinux-policy-devel-${selinux_policy_version}"

cd ./files/selinux/tuned-ppd-logging
make -f /usr/share/selinux/devel/Makefile tuned-ppd-logging.pp
cd ../../..

semodule -v -X 300 -i \
    ./selinux/tuned-ppd-logging/tuned-ppd-logging.pp
    