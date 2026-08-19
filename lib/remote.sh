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

# True when a Windows host's scheduled task runs the native runtime.
#
# The two runtimes coexist during cutover: bin/deploy.sh installs backup.ps1 on
# every Windows host, while scheduling it is a separate, per-host step. So the
# file's presence does not answer the question status collection actually asks —
# which runtime wrote the state file it is about to read. The task's /TR string
# does, and it is what changes at the moment of cutover. Matching on the value
# rather than the "Task To Run" label also survives a non-English Windows.
#
# Rolling a host back is therefore two operations: reinstall the WSL task, and
# remove C:\backup-kit\backup.ps1.
# Args: <host> [ssh options...]
remote_has_native_windows() {
    local host="$1"
    shift

    ssh "$@" "$host" "schtasks.exe /Query /TN \"BackupKit\" /V /FO LIST" 2>/dev/null \
        | grep -qi 'backup\.ps1'
}
