#!/usr/bin/env bash
# deploy-all.sh — deploy runtime to every host

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
echo "  1. Run 'bash hub/status-all.sh' to verify deployment"
echo "  2. Test on one host: ssh <host> '~/backup-kit/backup-plan.sh'"
echo "  3. Schedule backups (see AGENTS.md for cron/Task Scheduler setup)"
