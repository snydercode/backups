#!/usr/bin/env bash

# Shared remote command dispatch for Linux and Windows hosts.

# Where the native Windows runtime lives. Not inside the distro: a task running
# as SYSTEM cannot reach the WSL filesystem, and not needing to is the point.
WIN_KIT_DIR="C:\\backup-kit"
WIN_STATE_DIR="C:\\ProgramData\\backup-kit"

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

# True when a Windows host has the native runtime deployed.
#
# The two runtimes coexist during cutover: deploy.sh adds backup.ps1 on the
# Windows side without removing the WSL copy, and callers ask the host which
# one is there rather than being told by config. jobs.txt is generated from the
# snyderverse fleet config and cannot carry a per-host runtime flag, and this
# way a rollback is deleting one file on one host, not editing code.
# TODO(review 2026-08-19): that last sentence is wrong — deleting backup.ps1 leaves
# the SYSTEM task pointing at it, and no code path restores the WSL task.
# Args: <host> [ssh options...]
remote_has_native_windows() {
    local host="$1"
    shift

    ssh "$@" "$host" "if exist $WIN_KIT_DIR\\backup.ps1 (exit 0) else (exit 1)" \
        >/dev/null 2>&1
}
