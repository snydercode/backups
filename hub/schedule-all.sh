#!/usr/bin/env bash
# schedule-all.sh — install backup schedules on all hosts

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS_FILE="$SCRIPT_DIR/hosts.txt"

# Read host names (strip :wsl suffix)
HOSTS=()
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    HOSTS+=("${line%%:*}")
done < "$HOSTS_FILE"

failed=0

echo "Scheduling backups on ${#HOSTS[@]} hosts..."
echo

for host in "${HOSTS[@]}"; do
    if ! "$SCRIPT_DIR/schedule.sh" "$host"; then
        echo "FAILED: $host"
        failed=1
    fi
    echo
done

if [[ "$failed" -ne 0 ]]; then
    echo "Scheduling finished with failures."
    exit 1
fi

echo "Scheduling complete."
echo
echo "Next steps:"
echo "  1. Run 'bash hub/status-all.sh' to verify backup health"
echo "  2. Wait for scheduled time (01:00) or manually test: ssh <host> '~/backup-kit/backup-run.sh'"
