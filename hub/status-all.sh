#!/usr/bin/env bash
# status-all.sh — check backup status across all hosts
# Calls ~/backup-kit/backup-status.sh on each host via SSH

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

    local cmd="$REMOTE_KIT_DIR/backup-status.sh"
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

print_pretty_host_status() {
    local host="$1"
    local output="$2"

    local last_run_age_hours="-1"
    local overall_status="UNKNOWN"
    local -A job
    local -A seen
    local -a job_order=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^([a-zA-Z0-9_]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            case "$key" in
                last_run_age_hours) last_run_age_hours="$value" ;;
                overall_status)     overall_status="$value" ;;
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

    # Host header line
    printf "%-8s  %-10s  last run %s\n" "$host" "$overall_status" "$age_str"

    if [[ ${#job_order[@]} -eq 0 ]]; then
        printf "          (no jobs)\n"
        return
    fi

    local idx
    for idx in "${job_order[@]}"; do
        local dest="${job["${idx}_dest"]:-?}"
        local status="${job["${idx}_status"]:-UNKNOWN}"
        local pending_files="${job["${idx}_pending_files"]:-?}"
        local dest_avail="${job["${idx}_dest_avail_human"]:-?}"
        local dest_total_kb="${job["${idx}_dest_total_kb"]:-}"
        local err="${job["${idx}_error"]:-}"

        # Convert total KB to human-readable
        local dest_total_human
        if [[ -n "$dest_total_kb" && "$dest_total_kb" =~ ^[0-9]+$ ]]; then
            dest_total_human=$(numfmt --to=iec --suffix=B --from-unit=1024 "$dest_total_kb" 2>/dev/null || echo "${dest_total_kb}K")
        else
            dest_total_human="?"
        fi

        local space_str="${dest_avail} of ${dest_total_human} free"

        if [[ -n "$err" ]]; then
            printf "          %-22s  ERROR: %s\n" "$dest" "$err"
        elif [[ "$status" == "OK" || "$status" == "UP_TO_DATE" ]]; then
            printf "          %-22s  OK            %s\n" "$dest" "$space_str"
        else
            printf "          %-22s  %-12s  %s files pending   %s\n" \
                "$dest" "$status" "$pending_files" "$space_str"
        fi
    done
}

print_raw_host_status() {
    local host="$1"
    local output="$2"
    echo "host=$host"
    echo "$output"
    echo ""
}

render_host_output() {
    local host="$1"
    local success="$2"
    local output="$3"

    if [[ "$RAW" == "1" ]]; then
        if [[ "$success" != "1" ]]; then
            echo "host=$host"
            echo "overall_status=UNREACHABLE"
            echo ""
        else
            print_raw_host_status "$host" "$output"
        fi
        return
    fi

    if [[ "$success" != "1" ]]; then
        printf "%-8s  UNREACHABLE\n" "$host"
        return
    fi

    print_pretty_host_status "$host" "$output"
}

# --- main ---

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
        if fetch_host_status "${HOSTS[$i]}" "${IS_WSL[$i]}" "$before_date" >"$out_file" 2>&1; then
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
    if fetch_host_status "${HOSTS[$i]}" "${IS_WSL[$i]}" "$before_date" >"$out_file" 2>&1; then
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

