#!/usr/bin/env bash
# backup-run.sh — execute backup for all enabled jobs
# Thin wrapper around backup-sync.sh --mode run

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS_FILE="$SCRIPT_DIR/jobs.txt"

[ -f "$JOBS_FILE" ] || {
    echo "ERROR: jobs file not found: $JOBS_FILE" >&2
    exit 1
}

exit_code=0

while IFS= read -r line || [ -n "$line" ]; do
    # Skip blank/comment lines
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    IFS=':' read -r src dest <<< "$line"
    [ -n "$src" ] && [ -n "$dest" ] || continue
    
    echo "=== $src -> $dest ==="
    "$SCRIPT_DIR/backup-sync.sh" --mode run --src "$src" --dest "$dest" || {
        echo "FAILED: $src -> $dest"
        exit_code=1
    }
    echo
done < "$JOBS_FILE"

exit $exit_code
