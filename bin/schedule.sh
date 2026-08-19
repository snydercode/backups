#!/usr/bin/env bash
# schedule.sh — install backup schedule on one host
# Usage: schedule.sh <host>
# Uses jobs metadata and installs cron or Task Scheduler entry.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$REPO_DIR/jobs.txt"
source "$REPO_DIR/lib/jobs.sh"
source "$REPO_DIR/lib/hosts.sh"
source "$REPO_DIR/lib/remote.sh"

REMOTE_KIT_DIR="/home/toor/backup-kit"
REMOTE_STATE_DIR="/home/toor/.local/state/backup-kit"
SCHEDULE_TIME="01:00"

HOSTS=()
IS_WSL=()
WIN_USERS=()
while IFS='|' read -r host os user win_user; do
    [[ -z "$host" ]] && continue
    if [[ "$os" != "linux" && "$os" != "wsl" ]]; then
        echo "ERROR: host '$host' has invalid or missing os in $CONFIG_FILE" >&2
        exit 1
    fi
    if [[ -z "$user" ]]; then
        echo "ERROR: host '$host' missing user in $CONFIG_FILE" >&2
        exit 1
    fi
    HOSTS+=("$host")
    if [[ "$os" == "wsl" ]]; then
        IS_WSL+=("1")
        WIN_USERS+=("$win_user")
    else
        IS_WSL+=("0")
        WIN_USERS+=("")
    fi
done < <(jobs_list_host_meta "$CONFIG_FILE")

usage() {
    echo "usage: $0 <host>" >&2
    echo "known hosts: ${HOSTS[*]}" >&2
    exit 2
}

schedule_linux() {
    local host="$1"
    local cron_cmd="0 1 * * * $REMOTE_KIT_DIR/backup.sh run >> $REMOTE_STATE_DIR/cron.log 2>&1"

    echo "  Installing cron job..."

    # Remove any existing backup-kit entry, then add new one (idempotent)
    ssh "$host" "(crontab -l 2>/dev/null | grep -v backup-kit; echo '$cron_cmd') | crontab -"

    echo "  Verifying..."
    ssh "$host" "crontab -l | grep backup-kit" || {
        echo "  ERROR: cron entry not found after install"
        return 1
    }
}

# Bring the native state file up to date with the WSL one.
#
# This runs at schedule time, not deploy time, because installing the task is
# what flips bin/status.sh to the native runtime. Seeding any earlier leaves a
# stale timestamp to be read at the moment of cutover, and a host that is backing
# up correctly reports an un-ackable STALE_RUN until its first native run.
#
# Newer wins, so a re-run cannot rewind the history the native runtime has
# written for itself.
seed_native_state() {
    local host="$1"

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local wsl_file="$tmp_dir/wsl" native_file="$tmp_dir/native"
    ssh "$host" "wsl.exe -e bash -lc \"cat $REMOTE_STATE_DIR/last-run.txt\"" \
        > "$wsl_file" 2>/dev/null || true
    if [[ ! -s "$wsl_file" ]]; then
        echo "  no WSL last-run.txt to seed from" >&2
        return 0
    fi
    ssh "$host" "type $WIN_STATE_DIR\\last-run.txt" > "$native_file" 2>/dev/null || true

    local wsl_epoch native_epoch
    wsl_epoch="$(sed -n 's/^last_run_epoch=\([0-9]*\).*/\1/p' "$wsl_file" | head -1)"
    native_epoch="$(sed -n 's/^last_run_epoch=\([0-9]*\).*/\1/p' "$native_file" | head -1)"

    if [[ "${wsl_epoch:-0}" -gt "${native_epoch:-0}" ]]; then
        ssh "$host" "if not exist $WIN_STATE_DIR mkdir $WIN_STATE_DIR"
        scp -q "$wsl_file" "$host:C:/ProgramData/backup-kit/last-run.txt"
        echo "  seeded last-run.txt from the WSL runtime"
    else
        echo "  native last-run.txt is already current"
    fi
}

# os=wsl in jobs.txt means "this host is Windows". It no longer describes how
# the backup runs: the task calls backup.ps1 directly, and WSL is out of the
# path entirely. That is what lets /RU SYSTEM work — see the comment below.
schedule_windows() {
    local host="$1"

    seed_native_state "$host"

    echo "  Installing Task Scheduler job (Run As: SYSTEM)..."

    # /RU SYSTEM with no /IT and no password. The old task ran as the
    # distro-owning user with /IT because WSL2 registers distros per-user in
    # HKCU, so SYSTEM could not find one. Running natively removes that
    # constraint, and with it the requirement that somebody be interactively
    # logged in at 01:00 — which is why ephys7 went 34 days without a backup.
    ssh "$host" \
        "schtasks.exe /Create /TN \"BackupKit\" \
         /TR \"powershell.exe -NoProfile -ExecutionPolicy Bypass -File $WIN_KIT_DIR\\backup.ps1 run\" \
         /SC DAILY /ST $SCHEDULE_TIME /RU SYSTEM /F" || {
        echo "  ERROR: failed to create scheduled task"
        return 1
    }

    echo "  Verifying..."
    # /V /FO LIST so the logon mode is visible: it must NOT say "Interactive
    # only", or the task is back to needing a logged-in user.
    ssh "$host" "schtasks.exe /Query /TN \"BackupKit\" /V /FO LIST" \
        | grep -Ei "Logon Mode|Run As User|Scheduled Task State" || {
        echo "  ERROR: task not found after install"
        return 1
    }
}

main() {
    local host="${1:-}"
    local host_index

    [[ -n "$host" ]] || usage
    host_index="$(hosts_find_index "$host" "${HOSTS[@]}")" || usage

    local is_wsl="${IS_WSL[$host_index]}"
    local win_user="${WIN_USERS[$host_index]}"

    if [[ "$is_wsl" == "1" && -z "$win_user" ]]; then
        echo "ERROR: host '$host' is wsl but missing windows_user in $CONFIG_FILE" >&2
        exit 1
    fi

    echo "=== Scheduling backup on $host ==="

    # Preflight: check that backup-kit is deployed. On Windows the check runs
    # in cmd against the Windows filesystem — there is no shell on that side of
    # the SSH connection that understands `test -x`.
    if [[ "$is_wsl" == "1" ]]; then
        ssh "$host" "if exist $WIN_KIT_DIR\\backup.ps1 (exit 0) else (exit 1)" || {
            echo "ERROR: backup.ps1 not deployed on $host ($WIN_KIT_DIR). Run deploy.sh first." >&2
            exit 1
        }
        schedule_windows "$host"
    else
        remote_exec "$host" "0" "test -x $REMOTE_KIT_DIR/backup.sh" || {
            echo "ERROR: backup-kit not deployed on $host. Run deploy.sh first." >&2
            exit 1
        }
        schedule_linux "$host"
    fi

    echo "  done"
}

main "$@"
