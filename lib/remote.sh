#!/usr/bin/env bash

# Shared remote command dispatch for Linux and WSL hosts.

# Execute one remote command on Linux or WSL hosts.
# Args: <host> <is_wsl:0|1> <cmd> [ssh options...]
# Notes: for WSL hosts, command is wrapped with wsl.exe bash -lc.
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
