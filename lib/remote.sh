#!/usr/bin/env bash

# Shared remote command dispatch for Linux and WSL hosts.

remote_exec() {
    local host="$1"
    local is_wsl="$2"
    local cmd="$3"
    shift 3

    if [[ "$is_wsl" == "1" ]]; then
        ssh "$@" "$host" "wsl.exe -e bash -lc \"$cmd\""
    else
        ssh "$@" "$host" "$cmd"
    fi
}
