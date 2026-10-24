#!/usr/bin/env bash
alias fastfetch='bfetch'
alias ll='ls -laF --color=auto'

alias update='run0 /usr/bin/env bash -c "bootc upgrade"'
alias upgrade='run0 /usr/bin/env bash -c "bootc upgrade"'

alias reboot='systemctl reboot'
alias shutdown='systemctl poweroff'
alias poweroff='systemctl poweroff'



pkg-add() {
    if [ "$#" -eq 0 ]; then
        echo "Usage: pkg-add <package> [packages...]" >&2
        return 1
    fi
    local pkgs=()
    local pkg
    for pkg in "$@"; do
        pkgs+=("nixpkgs#$pkg")
    done
    nix profile add "${pkgs[@]}"
}   
pkg-rm() {
    if [ "$#" -eq 0 ]; then
        echo "Usage: pkg-rm <profile-element-id-or-pattern> [...]" >&2
        return 1
    fi
    nix profile remove "$@"
}
pkg-run() {
    if [ "$#" -eq 0 ]; then
        echo "Usage: pkg-run <package> [arguments...]" >&2
        return 1
    fi
    local pkg="nixpkgs#$1"
    shift
    nix run "$pkg" -- "$@"
}
pkg-list() {
    nix profile list
}
pkg-info() {
    if [ "$#" -eq 0 ]; then
        echo "Usage: pkg-info <package>" >&2
        return 1
    fi
    local pkg="nixpkgs#$1"
    nix search "$pkg" --json | jq -r '.[].description'
}
pkg-search() {
    if [ "$#" -eq 0 ]; then
        echo "Usage: pkg-search <pattern>" >&2
        return 1
    fi
    nix run nixpkgs#nix-search-cli -- "$@"
}
