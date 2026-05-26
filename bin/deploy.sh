#!/usr/bin/env bash
# deploy.sh — push runtime to one backup host
# Usage: deploy.sh <host>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_SCRIPT="$REPO_DIR/backup.sh"
CONFIG_FILE="$REPO_DIR/jobs.txt"
source "$REPO_DIR/lib/jobs.sh"
source "$REPO_DIR/lib/hosts.sh"

REMOTE_KIT_DIR="/home/toor/backup-kit"
REMOTE_STATE_DIR="/home/toor/.local/state/backup-kit"

HOSTS=()
while IFS= read -r host_name; do
    [[ -z "$host_name" ]] && continue
    HOSTS+=("$host_name")
done < <(jobs_list_hosts "$CONFIG_FILE")

usage() {
    echo "usage: $0 <host>" >&2
    echo "known hosts: ${HOSTS[*]}" >&2
    exit 2
}

main() {
    local host="${1:-}"

    [[ -n "$host" ]] || usage
    hosts_find_index "$host" "${HOSTS[@]}" >/dev/null || usage

    local tmp_jobs_file

    [ -f "$CONFIG_FILE" ] || {
        echo "ERROR: missing config file: $CONFIG_FILE" >&2
        exit 1
    }
    [ -f "$BACKUP_SCRIPT" ] || {
        echo "ERROR: missing backup script: $BACKUP_SCRIPT" >&2
        exit 1
    }

    local host_block
    host_block="$(jobs_emit_host_block "$CONFIG_FILE" "$host")"

    if [[ -z "$host_block" ]]; then
        echo "ERROR: host '$host' not found in $CONFIG_FILE" >&2
        exit 1
    fi

    local host_os=""
    local host_user=""
    local host_windows_user=""
    local host_jobs=""
    local host_src=""

    while IFS='|' read -r row_host row_os row_user row_windows_user; do
        if [[ "$row_host" == "$host" ]]; then
            host_os="$row_os"
            host_user="$row_user"
            host_windows_user="$row_windows_user"
            break
        fi
    done < <(jobs_list_host_meta "$CONFIG_FILE")

    if ! host_jobs="$(jobs_emit_host_jobs "$host_block")"; then
        echo "ERROR: invalid host '$host' config structure in $CONFIG_FILE" >&2
        exit 1
    fi

    if [[ -n "$host_jobs" ]]; then
        host_src="${host_jobs%%:*}"
        host_src="${host_src%%$'\n'*}"
    fi

    if [[ "$host_os" != "linux" && "$host_os" != "wsl" ]]; then
        echo "ERROR: host '$host' missing or invalid os=linux|wsl in $CONFIG_FILE" >&2
        exit 1
    fi
    if [[ -z "$host_src" ]]; then
        echo "ERROR: host '$host' missing src in $CONFIG_FILE" >&2
        exit 1
    fi
    if [[ -z "$host_user" ]]; then
        echo "ERROR: host '$host' missing user in $CONFIG_FILE" >&2
        exit 1
    fi
    if [[ -z "$host_jobs" ]]; then
        echo "ERROR: host '$host' has no active dest entries in $CONFIG_FILE" >&2
        exit 1
    fi
    if [[ "$host_os" == "wsl" && -z "$host_windows_user" ]]; then
        echo "ERROR: host '$host' missing windows_user for os=wsl in $CONFIG_FILE" >&2
        exit 1
    fi

    local is_wsl=0
    if [[ "$host_os" == "wsl" ]]; then
        is_wsl=1
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
