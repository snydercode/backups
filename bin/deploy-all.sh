#!/usr/bin/env bash
# deploy-all.sh — deploy runtime to every host
# Fleet wrapper over deploy.sh.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$REPO_DIR/jobs.txt"
source "$REPO_DIR/lib/jobs.sh"
source "$REPO_DIR/lib/fleet.sh"

HOSTS=()
while IFS= read -r host || [[ -n "$host" ]]; do
    [[ -z "$host" ]] && continue
    HOSTS+=("$host")
done < <(jobs_list_hosts "$CONFIG_FILE")

if [[ ${#HOSTS[@]} -eq 0 ]]; then
    echo "ERROR: no hosts found in $CONFIG_FILE" >&2
    exit 1
fi

echo "Deploying backup-kit to ${#HOSTS[@]} hosts..."
echo

if ! fleet_run_all "$SCRIPT_DIR/deploy.sh" "${HOSTS[@]}"; then
    echo "Deployment finished with failures."
    exit 1
fi

echo "Deployment complete."
echo
echo "Next steps:"
echo "  1. Run 'bash bin/status-all.sh' to verify deployment"
echo "  2. Test on one host: ssh <host> '~/backup-kit/backup.sh plan'"
echo "  3. Schedule backups (see CLAUDE.md for cron/Task Scheduler setup)"
