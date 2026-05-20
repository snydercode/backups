#!/usr/bin/env bash
# status-all.sh — check backup status across all hosts
# Calls remote status scripts and prints host output sequentially

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$REPO_DIR/jobs.txt"

REMOTE_KIT_DIR="/home/toor/backup-kit"

usage() {
    cat <<'EOF'
usage: status-all.sh [--raw] [--before YYYY-MM-DD]

Prints backup status for all hosts.

Options:
  --raw                       Print machine-parseable key=value output
  --before YYYY-MM-DD         Only count files modified before this date (default: today)
EOF
}

before_date=""
RAW=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --raw)
            RAW=1
            shift
            ;;
        --before)
            before_date="$2"
            shift 2
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# Parse jobs.txt into parallel arrays: HOSTS and IS_WSL
HOSTS=()
IS_WSL=()
while IFS='|' read -r host os; do
    [[ -z "$host" ]] && continue
    if [[ "$os" != "linux" && "$os" != "wsl" ]]; then
        echo "ERROR: host '$host' has invalid or missing os in $CONFIG_FILE" >&2
        exit 1
    fi
    HOSTS+=("$host")
    if [[ "$os" == "wsl" ]]; then
        IS_WSL+=("1")
    else
        IS_WSL+=("0")
    fi
done < <(
    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        /^[[:space:]]*\[/ {
            section=$0
            sub(/^[[:space:]]*\[/, "", section)
            sub(/\][[:space:]]*$/, "", section)
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

if [[ ${#HOSTS[@]} -eq 0 ]]; then
    echo "ERROR: no hosts found in $CONFIG_FILE" >&2
    exit 1
fi

fetch_host_status() {
    local host="$1"
    local is_wsl="$2"
    local before_date="$3"

    local cmd
    if [[ "$RAW" == "1" ]]; then
        cmd="$REMOTE_KIT_DIR/backup.sh status"
    else
        cmd="$REMOTE_KIT_DIR/backup.sh status --human"
    fi

    if [[ -n "$before_date" ]]; then
        cmd="$cmd --before $before_date"
    fi

    if [[ "$is_wsl" == "1" ]]; then
        # Windows host — run via WSL
        ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
            "wsl.exe -e bash -lc \"$cmd\"" 2>&1
    else
        # Linux host — direct
        ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "$cmd" 2>&1
    fi
}

render_host_output() {
    local host="$1"
    local success="$2"
    local output="$3"

    if [[ "$RAW" == "1" ]]; then
        if [[ "$success" != "1" ]]; then
            local err_type="command_failed"
            if [[ "$output" == *"Connection timed out"* || "$output" == *"Could not resolve hostname"* || "$output" == *"Connection refused"* || "$output" == *"No route to host"* || "$output" == *"Permission denied"* ]]; then
                err_type="ssh_failed"
            fi
            echo "host=$host"
            if [[ "$err_type" == "ssh_failed" ]]; then
                echo "overall_status=UNREACHABLE"
            else
                echo "overall_status=ERROR"
            fi
            echo "error=$err_type"
            echo ""
        else
            echo "$output"
            echo ""
        fi
        return
    fi

    if [[ "$success" != "1" ]]; then
        if [[ "$output" == *"Connection timed out"* || "$output" == *"Could not resolve hostname"* || "$output" == *"Connection refused"* || "$output" == *"No route to host"* || "$output" == *"Permission denied"* ]]; then
            printf "%-8s  [UNREACHABLE] ssh failed\n" "$host"
        else
            local first_line="${output%%$'\n'*}"
            printf "%-8s  [ERROR] remote status command failed: %s\n" "$host" "$first_line"
        fi
        return
    fi

    echo "$output"
}

# --- main ---

for i in "${!HOSTS[@]}"; do
    host="${HOSTS[$i]}"
    is_wsl="${IS_WSL[$i]}"

    if output="$(fetch_host_status "$host" "$is_wsl" "$before_date" 2>&1)"; then
        render_host_output "$host" "1" "$output"
    else
        render_host_output "$host" "0" "$output"
    fi
    if [[ "$RAW" != "1" ]]; then
        echo ""
    fi
done
