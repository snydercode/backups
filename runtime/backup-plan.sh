#!/usr/bin/env bash
# backup-plan.sh — show pending files/bytes for all enabled jobs
# Thin wrapper around backup-sync.sh --mode plan

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS_FILE="$SCRIPT_DIR/jobs.txt"

[ -f "$JOBS_FILE" ] || {
    echo "ERROR: jobs file not found: $JOBS_FILE" >&2
    exit 1
}

while IFS= read -r line || [ -n "$line" ]; do
    # Skip blank/comment lines
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    IFS=':' read -r src dest <<< "$line"
    [ -n "$src" ] && [ -n "$dest" ] || continue
    
    echo "=== $src -> $dest ==="
    "$SCRIPT_DIR/backup-sync.sh" --mode plan --src "$src" --dest "$dest" || true
    echo
done < "$JOBS_FILE"
