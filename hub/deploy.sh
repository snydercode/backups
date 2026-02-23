#!/usr/bin/env bash
# deploy.sh — push runtime to one backup host
# Usage: deploy.sh <host>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
RUNTIME_DIR="$REPO_DIR/runtime"
JOBS_DIR="$RUNTIME_DIR/jobs"
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

main() {
    local host="${1:-}"

    [[ -n "$host" ]] || usage
    host_index "$host" || usage

    local is_wsl="${IS_WSL[$HOST_INDEX]}"

    [ -f "$JOBS_DIR/${host}.txt" ] || {
        echo "ERROR: missing jobs file: $JOBS_DIR/${host}.txt" >&2
        exit 1
    }

    echo "=== Deploying to $host ==="

    if [[ "$is_wsl" == "1" ]]; then
        echo "  [WSL host]"

        # Ensure C:\Temp exists for file staging
        ssh "$host" "if not exist C:\\Temp mkdir C:\\Temp" 2>/dev/null || true
        ssh "$host" "wsl.exe -e bash -lc \"mkdir -p $REMOTE_KIT_DIR $REMOTE_STATE_DIR\""

        for f in "$RUNTIME_DIR"/*.sh; do
            local fname
            fname="$(basename "$f")"
            echo "  copying $fname"
            # Copy to Windows temp, then move into WSL filesystem
            scp -q "$f" "$host:C:/Temp/$fname"
            ssh "$host" "wsl.exe -e bash -lc \"cp /mnt/c/Temp/$fname $REMOTE_KIT_DIR/\""
        done

        echo "  copying jobs.txt ($host)"
        scp -q "$JOBS_DIR/${host}.txt" "$host:C:/Temp/jobs.txt"
        ssh "$host" "wsl.exe -e bash -lc \"cp /mnt/c/Temp/jobs.txt $REMOTE_KIT_DIR/jobs.txt\""

        ssh "$host" "wsl.exe -e bash -lc \"chmod +x $REMOTE_KIT_DIR/*.sh\""
    else
        echo "  [Linux host]"

        ssh "$host" "mkdir -p $REMOTE_KIT_DIR $REMOTE_STATE_DIR"

        for f in "$RUNTIME_DIR"/*.sh; do
            local fname
            fname="$(basename "$f")"
            echo "  copying $fname"
            scp -q "$f" "$host:$REMOTE_KIT_DIR/"
        done

        echo "  copying jobs.txt ($host)"
        scp -q "$JOBS_DIR/${host}.txt" "$host:$REMOTE_KIT_DIR/jobs.txt"

        ssh "$host" "chmod +x $REMOTE_KIT_DIR/*.sh"
    fi

    echo "  done"
}

main "$@"
