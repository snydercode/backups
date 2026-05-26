#!/usr/bin/env bash
# schedule.sh — install backup schedule on one host
# Usage: schedule.sh <host>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$REPO_DIR/jobs.txt"
source "$REPO_DIR/lib/jobs.sh"
source "$REPO_DIR/lib/hosts.sh"

REMOTE_KIT_DIR="/home/toor/backup-kit"
REMOTE_STATE_DIR="/home/toor/.local/state/backup-kit"
SCHEDULE_TIME="01:00"

HOSTS=()
IS_WSL=()
WIN_USERS=()
USERS=()
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
    USERS+=("$user")
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

schedule_wsl() {
    local host="$1"
    local win_user="$2"

    echo "  Installing Task Scheduler job (Run As: $win_user)..."

    # Create/replace task (idempotent via /F flag)
    # /IT: interactive token — runs only when win_user is logged in interactively.
    # This is required because WSL2 distros are registered per-user in HKCU;
    # SYSTEM has no distro registration and always fails with exit -1.
    ssh "$host" "schtasks.exe /Create /TN \"BackupKit\" /TR \"wsl.exe -u toor -e bash -lc $REMOTE_KIT_DIR/backup.sh run\" /SC DAILY /ST $SCHEDULE_TIME /RU \"$win_user\" /IT /F" || {
        echo "  ERROR: failed to create scheduled task"
        return 1
    }

    echo "  Verifying..."
    ssh "$host" "schtasks.exe /Query /TN \"BackupKit\"" || {
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

    # Preflight: check that backup-kit is deployed
    if [[ "$is_wsl" == "1" ]]; then
        ssh "$host" "wsl.exe -e bash -lc \"test -x $REMOTE_KIT_DIR/backup.sh\"" || {
            echo "ERROR: backup-kit not deployed on $host. Run deploy.sh first." >&2
            exit 1
        }
        schedule_wsl "$host" "$win_user"
    else
        ssh "$host" "test -x $REMOTE_KIT_DIR/backup.sh" || {
            echo "ERROR: backup-kit not deployed on $host. Run deploy.sh first." >&2
            exit 1
        }
        schedule_linux "$host"
    fi

    echo "  done"
}

main "$@"
