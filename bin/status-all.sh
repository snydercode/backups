#!/usr/bin/env bash
# status-all.sh — check backup status across all hosts
# Calls remote status scripts and prints host output sequentially
# Uses jobs metadata for host inventory and OS dispatch.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$REPO_DIR/jobs.txt"
source "$REPO_DIR/lib/jobs.sh"
source "$REPO_DIR/lib/remote.sh"

REMOTE_KIT_DIR="/home/toor/backup-kit"

usage() {
    cat <<'EOF'
usage: status-all.sh [--raw] [--before YYYY-MM-DD]

Prints backup status for all hosts.

Options:
  --raw                       Print machine-parseable JSON output
  --before YYYY-MM-DD         Only count files modified before this date (default: today)
EOF
}

is_ssh_error() {
    local text="$1"
    [[ "$text" == *"Connection timed out"* \
    || "$text" == *"Could not resolve hostname"* \
    || "$text" == *"Connection refused"* \
    || "$text" == *"No route to host"* \
    || "$text" == *"Permission denied"* ]]
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

HOSTS=()
IS_WSL=()
while IFS='|' read -r host os _user _windows_user; do
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
done < <(jobs_list_host_meta "$CONFIG_FILE")

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
        cmd="$REMOTE_KIT_DIR/backup.sh status --raw"
    else
        cmd="$REMOTE_KIT_DIR/backup.sh status --human"
    fi

    if [[ -n "$before_date" ]]; then
        cmd="$cmd --before $before_date"
    fi

    remote_exec "$host" "$is_wsl" "$cmd" -o BatchMode=yes -o ConnectTimeout=10 2>&1
}

render_host_output() {
    local host="$1"
    local success="$2"
    local output="$3"

    if [[ "$RAW" == "1" ]]; then
        return
    fi

    if [[ "$success" != "1" ]]; then
        if is_ssh_error "$output"; then
            printf "%-8s  [UNREACHABLE] ssh failed\n" "$host"
        else
            local first_line="${output%%$'\n'*}"
            printf "%-8s  [ERROR] remote status command failed: %s\n" "$host" "$first_line"
        fi
        return
    fi

    echo "$output"
}

json_error_host() {
    local host="$1"
    local output="$2"
    local err_type="command_failed"
    local overall="ERROR"

    if is_ssh_error "$output"; then
        err_type="ssh_failed"
        overall="UNREACHABLE"
    fi

    jq -cn \
        --arg host "$host" \
        --arg overall "$overall" \
        --arg err_type "$err_type" \
        --arg message "${output%%$'\n'*}" '
        {
            schema_version: 1,
            host: $host,
            reachable: false,
            overall_status: $overall,
            last_run: {
                date: "unknown",
                age_hours: -1,
                result: null,
                status: "UNKNOWN"
            },
            jobs: [],
            errors: [
                {
                    type: $err_type,
                    message: $message
                }
            ]
        }
    '
}

json_hosts=()

# --- main ---

for i in "${!HOSTS[@]}"; do
    host="${HOSTS[$i]}"
    is_wsl="${IS_WSL[$i]}"

    if output="$(fetch_host_status "$host" "$is_wsl" "$before_date" 2>&1)"; then
        if [[ "$RAW" == "1" ]]; then
            if jq -e . >/dev/null 2>&1 <<< "$output"; then
                json_hosts+=("$output")
            else
                json_hosts+=("$(json_error_host "$host" "$output")")
            fi
        fi
        render_host_output "$host" "1" "$output"
    else
        if [[ "$RAW" == "1" ]]; then
            json_hosts+=("$(json_error_host "$host" "$output")")
        fi
        render_host_output "$host" "0" "$output"
    fi
    if [[ "$RAW" != "1" ]]; then
        echo ""
    fi
done

if [[ "$RAW" == "1" ]]; then
    {
        for host_json in "${json_hosts[@]}"; do
            printf '%s\n' "$host_json"
        done
    } | jq -sc --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg before_date "$before_date" '
        {
            schema_version: 1,
            generated_at: $generated_at,
            before_date: (if $before_date == "" then null else $before_date end),
            hosts: .,
            summary: {
                total_hosts: length,
                ok: map(select(.overall_status == "OK")) | length,
                pending: map(select(.overall_status == "PENDING")) | length,
                stale: map(select(.overall_status == "STALE")) | length,
                failed: map(select(.overall_status == "FAILED")) | length,
                never_run: map(select(.overall_status == "NEVER_RUN")) | length,
                error: map(select(.overall_status == "ERROR")) | length,
                unreachable: map(select(.overall_status == "UNREACHABLE")) | length
            }
        }
    '
fi
