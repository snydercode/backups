#!/usr/bin/env bash
# schedule-all.sh — install backup schedules on all hosts

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$REPO_DIR/jobs.txt"
source "$REPO_DIR/lib/jobs.sh"

HOSTS=()
while IFS= read -r host || [[ -n "$host" ]]; do
    [[ -z "$host" ]] && continue
    HOSTS+=("$host")
done < <(jobs_list_hosts "$CONFIG_FILE")

if [[ ${#HOSTS[@]} -eq 0 ]]; then
    echo "ERROR: no hosts found in $CONFIG_FILE" >&2
    exit 1
fi

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
echo "  1. Run 'bash bin/status-all.sh' to verify backup health"
echo "  2. Wait for scheduled time (01:00) or manually test: ssh <host> '~/backup-kit/backup.sh run'"
