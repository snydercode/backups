#!/usr/bin/env bash
# schedule.sh — install backup schedule on one host
# Usage: schedule.sh <host>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS_FILE="$SCRIPT_DIR/hosts.txt"

REMOTE_KIT_DIR="/home/toor/backup-kit"
REMOTE_STATE_DIR="/home/toor/.local/state/backup-kit"
SCHEDULE_TIME="01:00"

# Parse hosts.txt into parallel arrays: HOSTS and IS_WSL
HOSTS=()
IS_WSL=()
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    host="${line%%:*}"
    if [[ "$line" == *":wsl" ]]; then
        IS_WSL+=("1")
    else
        IS_WSL+=("0")
    fi
    HOSTS+=("$host")
done < "$HOSTS_FILE"

usage() {
    echo "usage: $0 <host>" >&2
    echo "known hosts: ${HOSTS[*]}" >&2
    exit 2
}

# Returns 0 if host exists, sets HOST_INDEX
host_index() {
    local needle="$1"
    local i
    for i in "${!HOSTS[@]}"; do
        if [[ "${HOSTS[$i]}" == "$needle" ]]; then
            HOST_INDEX=$i
            return 0
        fi
    done
    return 1
}

schedule_linux() {
    local host="$1"
    local cron_cmd="0 1 * * * $REMOTE_KIT_DIR/backup-run.sh >> $REMOTE_STATE_DIR/cron.log 2>&1"

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

    echo "  Installing Task Scheduler job..."

    # Create/replace task (idempotent via /F flag)
    ssh "$host" "schtasks.exe /Create /TN \"BackupKit\" /TR \"wsl.exe -e bash -lc $REMOTE_KIT_DIR/backup-run.sh\" /SC DAILY /ST $SCHEDULE_TIME /F" || {
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

    [[ -n "$host" ]] || usage
    host_index "$host" || usage

    local is_wsl="${IS_WSL[$HOST_INDEX]}"

    echo "=== Scheduling backup on $host ==="

    # Preflight: check that backup-kit is deployed
    if [[ "$is_wsl" == "1" ]]; then
        ssh "$host" "wsl.exe -e bash -lc \"test -x $REMOTE_KIT_DIR/backup-run.sh\"" || {
            echo "ERROR: backup-kit not deployed on $host. Run deploy.sh first." >&2
            exit 1
        }
        schedule_wsl "$host"
    else
        ssh "$host" "test -x $REMOTE_KIT_DIR/backup-run.sh" || {
            echo "ERROR: backup-kit not deployed on $host. Run deploy.sh first." >&2
            exit 1
        }
        schedule_linux "$host"
    fi

    echo "  done"
}

main "$@"
