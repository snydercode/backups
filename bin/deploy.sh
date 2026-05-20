#!/usr/bin/env bash
# deploy.sh — push runtime to one backup host
# Usage: deploy.sh <host>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_SCRIPT="$REPO_DIR/backup.sh"
CONFIG_FILE="$REPO_DIR/jobs.txt"

REMOTE_KIT_DIR="/home/toor/backup-kit"
REMOTE_STATE_DIR="/home/toor/.local/state/backup-kit"

HOSTS=()

while IFS='|' read -r host_name host_os; do
    HOSTS+=("$host_name")
done < <(
    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        /^[[:space:]]*\[/ {
            section=$0
            sub(/^[[:space:]]*\[/, "", section)
            sub(/\][[:space:]]*$/, "", section)
            os=""
            next
        }
        section != "" {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line ~ /^os=/) {
                os=line
                sub(/^os=/, "", os)
                print section "|" os
                section=""
            }
        }
    ' "$CONFIG_FILE"
)

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
    host_block="$({
        awk -v target="$host" '
            BEGIN { in_target=0 }
            /^[[:space:]]*#/ || /^[[:space:]]*$/ {
                if (in_target) print
                next
            }
            /^[[:space:]]*\[/ {
                if ($0 ~ "^[[:space:]]*\\[" target "\\][[:space:]]*$") {
                    in_target=1
                    next
                }
                if (in_target) exit
                in_target=0
                next
            }
            {
                if (in_target) print
            }
        ' "$CONFIG_FILE"
    } || true)"

    if [[ -z "$host_block" ]]; then
        echo "ERROR: host '$host' not found in $CONFIG_FILE" >&2
        exit 1
    fi

    local host_os=""
    local host_user=""
    local host_windows_user=""
    local host_src=""
    local host_jobs=""
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" != *=* ]]; then
            echo "ERROR: invalid line for host '$host': $line" >&2
            exit 1
        fi
        key="${line%%=*}"
        value="${line#*=}"
        key="${key//[[:space:]]/}"
        value="${value##[[:space:]]}"

        case "$key" in
            os) host_os="$value" ;;
            user) host_user="$value" ;;
            windows_user) host_windows_user="$value" ;;
            src) host_src="$value" ;;
            dest)
                if [[ -z "$host_src" ]]; then
                    echo "ERROR: host '$host' has dest before src in $CONFIG_FILE" >&2
                    exit 1
                fi
                host_jobs+="$host_src:$value"$'\n'
                ;;
        esac
    done <<< "$host_block"

    host_jobs="${host_jobs%$'\n'}"

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
