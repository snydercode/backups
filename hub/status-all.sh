#!/usr/bin/env bash
# status-all.sh — check backup status across all hosts
# Calls ~/backup-kit/backup-status.sh on each host via SSH

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS_FILE="$SCRIPT_DIR/hosts.txt"

REMOTE_KIT_DIR="/home/toor/backup-kit"

usage() {
    cat <<'EOF'
usage: status-all.sh [--before-date YYYY-MM-DD] [--before-time HH]

Prints a human-readable backup status table for all hosts.

Options:
  --before-date YYYY-MM-DD    Only count files modified before this date (default: today)
  --before-time HH            Hour in 24-hour format (default: 1)
EOF
}

before_date=""
before_time=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --before-date)
            before_date="$2"
            shift 2
            ;;
        --before-time)
            before_time="$2"
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
    local before_time="$4"

    local cmd="$REMOTE_KIT_DIR/backup-status.sh"
    if [[ -n "$before_date" ]]; then
        cmd="$cmd --before-date $before_date"
    fi
    if [[ -n "$before_time" ]]; then
        cmd="$cmd --before-time $before_time"
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

print_pretty_host_status() {
    local host="$1"
    local output="$2"

    local last_run_age_hours="-1"
    local -A job
    local -A seen
    local -a job_order=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^([a-zA-Z0-9_]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            case "$key" in
                last_run_age_hours) last_run_age_hours="$value" ;;
                job_*)
                    if [[ "$key" =~ ^job_([0-9]+)_([a-z_]+)$ ]]; then
                        local idx="${BASH_REMATCH[1]}"
                        local field="${BASH_REMATCH[2]}"
                        job["${idx}_${field}"]="$value"
                        if [[ -z "${seen[$idx]:-}" ]]; then
                            seen["$idx"]=1
                            job_order+=("$idx")
                        fi
                    fi
                    ;;
            esac
        fi
    done <<< "$output"

    # Age string
    local age_str
    if [[ "$last_run_age_hours" -ge 0 ]]; then
        age_str="${last_run_age_hours}h ago"
    else
        age_str="never"
    fi

    local idx
    for idx in "${job_order[@]}"; do
        local dest="${job["${idx}_dest"]:-?}"
        local status="${job["${idx}_status"]:-UNKNOWN}"
        local pending_files="${job["${idx}_pending_files"]:-0}"
        local pending_human="${job["${idx}_pending_human"]:-}"
        local err="${job["${idx}_error"]:-}"

        local status_str
        if [[ -n "$err" ]]; then
            status_str="ERROR"
        elif [[ "$status" == "OK" ]]; then
            status_str="OK"
        elif [[ "$status" == "DISABLED" ]]; then
            status_str="DISABLED"
        else
            status_str="$status"
        fi

        local detail=""
        if [[ "$status_str" == "PENDING" ]]; then
            detail="  ${pending_files} files, ${pending_human}"
        elif [[ "$status_str" == "ERROR" ]]; then
            detail="  $err"
        fi

        printf "%-10s  %-24s  %-10s  %s%s\n" \
            "$host" "$dest" "$status_str" "$age_str" "$detail"
    done

    if [[ ${#job_order[@]} -eq 0 ]]; then
        printf "%-10s  %-24s  %-10s  %s\n" "$host" "(no jobs)" "UNKNOWN" "$age_str"
    fi
}

render_host_output() {
    local host="$1"
    local success="$2"
    local output="$3"

    if [[ "$success" != "1" ]]; then
        printf "%-10s  %-24s  %-10s\n" "$host" "(all jobs)" "UNREACHABLE"
        return
    fi

    print_pretty_host_status "$host" "$output"
}

# --- main ---

printf "%-10s  %-24s  %-10s  %s\n" "HOST" "DESTINATION" "STATUS" "LAST RUN"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

OUT_FILES=()
RC_FILES=()
PIDS=()

# Pass 1: Linux hosts in parallel
for i in "${!HOSTS[@]}"; do
    [[ "${IS_WSL[$i]}" == "1" ]] && continue
    out_file="$tmp_dir/out_$i.txt"
    rc_file="$tmp_dir/rc_$i.txt"
    OUT_FILES[$i]="$out_file"
    RC_FILES[$i]="$rc_file"
    {
        if fetch_host_status "${HOSTS[$i]}" "${IS_WSL[$i]}" "$before_date" "$before_time" >"$out_file" 2>&1; then
            echo "1" >"$rc_file"
        else
            echo "0" >"$rc_file"
        fi
    } &
    PIDS+=("$!")
done

for pid in "${PIDS[@]}"; do
    wait "$pid" || true
done

# Pass 2: WSL hosts sequentially
for i in "${!HOSTS[@]}"; do
    [[ "${IS_WSL[$i]}" == "0" ]] && continue
    out_file="$tmp_dir/out_$i.txt"
    rc_file="$tmp_dir/rc_$i.txt"
    OUT_FILES[$i]="$out_file"
    RC_FILES[$i]="$rc_file"
    if fetch_host_status "${HOSTS[$i]}" "${IS_WSL[$i]}" "$before_date" "$before_time" >"$out_file" 2>&1; then
        echo "1" >"$rc_file"
    else
        echo "0" >"$rc_file"
    fi
done


for i in "${!HOSTS[@]}"; do
    success="0"
    output=""

    if [[ -f "${RC_FILES[$i]}" ]]; then
        success="$(<"${RC_FILES[$i]}")"
    fi
    if [[ -f "${OUT_FILES[$i]}" ]]; then
        output="$(<"${OUT_FILES[$i]}")"
    fi

    render_host_output "${HOSTS[$i]}" "$success" "$output"
done


