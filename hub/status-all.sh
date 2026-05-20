#!/usr/bin/env bash
# status-all.sh — check backup status across all hosts
# Calls remote status scripts and prints host output sequentially

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS_FILE="$SCRIPT_DIR/hosts.txt"

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

fetch_host_status() {
    local host="$1"
    local is_wsl="$2"
    local before_date="$3"

    local cmd
    if [[ "$RAW" == "1" ]]; then
        cmd="$REMOTE_KIT_DIR/backup-status.sh"
    else
        cmd="if [[ -f $REMOTE_KIT_DIR/backup-status-human.sh ]]; then bash $REMOTE_KIT_DIR/backup-status-human.sh; else bash $REMOTE_KIT_DIR/backup-status.sh; fi"
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
            echo "host=$host"
            echo "overall_status=UNREACHABLE"
            echo "error=ssh_failed"
            echo ""
        else
            echo "$output"
            echo ""
        fi
        return
    fi

    if [[ "$success" != "1" ]]; then
        printf "%-8s  [UNREACHABLE] ssh failed\n" "$host"
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
