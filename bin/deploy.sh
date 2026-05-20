#!/usr/bin/env bash
# deploy.sh — push runtime to one backup host
# Usage: deploy.sh <host>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_SCRIPT="$REPO_DIR/backup.sh"
ALL_JOBS_FILE="$REPO_DIR/jobs.txt"
HOSTS_FILE="$SCRIPT_DIR/hosts.txt"

REMOTE_KIT_DIR="/home/toor/backup-kit"
REMOTE_STATE_DIR="/home/toor/.local/state/backup-kit"

# Parse hosts.txt into parallel arrays: HOSTS and IS_WSL
HOSTS=()
IS_WSL=()
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    host="${line%%:*}"
    if [[ "$line" == *":wsl"* ]]; then
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

main() {
    local host="${1:-}"

    [[ -n "$host" ]] || usage
    host_index "$host" || usage

    local is_wsl="${IS_WSL[$HOST_INDEX]}"
    local tmp_jobs_file

    [ -f "$ALL_JOBS_FILE" ] || {
        echo "ERROR: missing jobs file: $ALL_JOBS_FILE" >&2
        exit 1
    }
    [ -f "$BACKUP_SCRIPT" ] || {
        echo "ERROR: missing backup script: $BACKUP_SCRIPT" >&2
        exit 1
    }

    local host_jobs
    host_jobs="$({
        awk -v target="$host" '
            BEGIN {
                in_target=0
            }
            /^[[:space:]]*\[/ {
                if ($0 ~ "^[[:space:]]*\\[" target "\\][[:space:]]*$") {
                    in_target=1
                } else {
                    in_target=0
                }
                next
            }
            {
                if (in_target) print
            }
        ' "$ALL_JOBS_FILE" \
        | sed '/^[[:space:]]*$/d' \
        | sed '/^[[:space:]]*#/d'
    } || true)"

    if [[ -z "$host_jobs" ]]; then
        echo "ERROR: no active jobs found for host '$host' in $ALL_JOBS_FILE" >&2
        exit 1
    fi

    tmp_jobs_file="$(mktemp)"
    trap 'rm -f "$tmp_jobs_file"' EXIT
    printf '%s\n' "$host_jobs" > "$tmp_jobs_file"

    echo "=== Deploying to $host ==="

    if [[ "$is_wsl" == "1" ]]; then
        echo "  [WSL host]"

        # Ensure C:\Temp exists for file staging
        ssh "$host" "if not exist C:\\Temp mkdir C:\\Temp" 2>/dev/null || true
        ssh "$host" "wsl.exe -e bash -lc \"mkdir -p $REMOTE_KIT_DIR $REMOTE_STATE_DIR\""

        echo "  copying backup.sh"
        scp -q "$BACKUP_SCRIPT" "$host:C:/Temp/backup.sh"
        ssh "$host" "wsl.exe -e bash -lc \"cp /mnt/c/Temp/backup.sh $REMOTE_KIT_DIR/backup.sh\""

        echo "  copying jobs.txt ($host)"
        scp -q "$tmp_jobs_file" "$host:C:/Temp/jobs.txt"
        ssh "$host" "wsl.exe -e bash -lc \"rm -f $REMOTE_KIT_DIR/jobs.txt && cp /mnt/c/Temp/jobs.txt $REMOTE_KIT_DIR/jobs.txt\""

        ssh "$host" "wsl.exe -e bash -lc \"chmod +x $REMOTE_KIT_DIR/*.sh\""
    else
        echo "  [Linux host]"

        ssh "$host" "mkdir -p $REMOTE_KIT_DIR $REMOTE_STATE_DIR"

        echo "  copying backup.sh"
        scp -q "$BACKUP_SCRIPT" "$host:$REMOTE_KIT_DIR/backup.sh"

        echo "  copying jobs.txt ($host)"
        scp -q "$tmp_jobs_file" "$host:$REMOTE_KIT_DIR/jobs.txt.new"
        ssh "$host" "rm -f $REMOTE_KIT_DIR/jobs.txt && mv $REMOTE_KIT_DIR/jobs.txt.new $REMOTE_KIT_DIR/jobs.txt"

        ssh "$host" "chmod +x $REMOTE_KIT_DIR/*.sh"
    fi

    echo "  done"

    rm -f "$tmp_jobs_file"
    trap - EXIT
}

main "$@"
