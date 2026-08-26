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

# The scheduled task's name, on every Windows host.
WIN_TASK_NAME="BackupKit"

# Which runtime a Windows host's scheduled task actually runs.
#
# The two runtimes coexist during cutover: bin/deploy.sh installs backup.ps1 on
# every Windows host, while scheduling it is a separate, per-host step. So the
# file's presence does not answer the question status collection asks — which
# runtime wrote the state file it is about to read. The task's /TR string does.
# Matching on the value rather than the "Task To Run" label also survives a
# non-English Windows.
#
# A failed probe is its own answer. Folding it into "not native" would make one
# hiccuped schtasks query send status collection to a state file that has not
# been written since cutover, which reads as a stale host that is in fact fine.
#
# A probe that failed because ssh never connected is a different answer again,
# and it gets its own code. Reporting a powered-off host as "could not determine
# the backup runtime" describes the symptom this function saw instead of the one
# the operator has to act on, and it sends the finding down the STATUS_ERROR
# path rather than DISCONNECTED. ssh exits 255 for its own failures, which is
# how the two are told apart; the diagnostics go to stderr for the caller to
# quote, because "unreachable" without the reason is its own dead end.
#
# Args: <host> [ssh options...]
# Returns: 0 native, 1 WSL, 2 probe failed on a reachable host,
#          REMOTE_RUNTIME_SSH_FAILED (3) ssh never connected
REMOTE_RUNTIME_SSH_FAILED=3
remote_windows_runtime() {
    local host="$1"
    shift

    local out rc
    out="$(ssh "$@" "$host" "schtasks.exe /Query /TN \"$WIN_TASK_NAME\" /V /FO LIST" 2>&1)"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
        printf '%s\n' "$out" >&2
        [[ "$rc" -eq 255 ]] && return "$REMOTE_RUNTIME_SSH_FAILED"
        return 2
    fi

    grep -qi 'backup\.ps1' <<< "$out" && return 0
    return 1
}
