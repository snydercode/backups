#!/usr/bin/env bash
# status-all.sh — check backup status across all hosts
# Calls ~/backup-kit/backup-status.sh on each host via SSH

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS_FILE="$SCRIPT_DIR/hosts.txt"

REMOTE_KIT_DIR="/home/toor/backup-kit"

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

check_host() {
    local host="$1"
    local is_wsl="$2"

    echo "========================================"
    echo "[$host]"
    echo "========================================"

    if [[ "$is_wsl" == "1" ]]; then
        # Windows host — run via WSL
        ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
            "wsl.exe -e bash -lc '$REMOTE_KIT_DIR/backup-status.sh'" 2>&1 || {
            echo "ERROR: could not reach $host or backup-status.sh failed"
        }
    else
        # Linux host — direct
        ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
            "$REMOTE_KIT_DIR/backup-status.sh" 2>&1 || {
            echo "ERROR: could not reach $host or backup-status.sh failed"
        }
    fi

    echo ""
}

# --- main ---

echo "Backup Status Report"
echo "Generated: $(date)"
echo ""

for i in "${!HOSTS[@]}"; do
    check_host "${HOSTS[$i]}" "${IS_WSL[$i]}"
done

echo "========================================"
echo "Report complete."
