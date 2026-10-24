#!/usr/bin/env bash
dnf config-manager --set-enabled crb
dnf install -y epel-release
