#!/usr/bin/env bash
# deploy-all.sh — deploy runtime to every host

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$REPO_DIR/jobs.txt"

# Read host names from jobs.txt sections
HOSTS=()
while IFS= read -r host || [[ -n "$host" ]]; do
    [[ -z "$host" ]] && continue
    HOSTS+=("$host")
done < <(awk '/^[[:space:]]*\[/{h=$0; sub(/^[[:space:]]*\[/,"",h); sub(/\][[:space:]]*$/,"",h); print h}' "$CONFIG_FILE")

if [[ ${#HOSTS[@]} -eq 0 ]]; then
    echo "ERROR: no hosts found in $CONFIG_FILE" >&2
    exit 1
fi

failed=0

echo "Deploying backup-kit to ${#HOSTS[@]} hosts..."
echo

for host in "${HOSTS[@]}"; do
    if ! "$SCRIPT_DIR/deploy.sh" "$host"; then
        echo "FAILED: $host"
        failed=1
    fi
    echo
done

if [[ "$failed" -ne 0 ]]; then
    echo "Deployment finished with failures."
    exit 1
fi

echo "Deployment complete."
echo
echo "Next steps:"
echo "  1. Run 'bash bin/status-all.sh' to verify deployment"
echo "  2. Test on one host: ssh <host> '~/backup-kit/backup.sh plan'"
echo "  3. Schedule backups (see AGENTS.md for cron/Task Scheduler setup)"
