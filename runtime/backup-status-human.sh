#!/usr/bin/env bash
# backup-status-human.sh — human-readable backup health status
# Usage: backup-status-human.sh [--before YYYY-MM-DD]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

before_date=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --before)
            before_date="$2"
            shift 2
            ;;
        -h|--help)
            echo "usage: backup-status-human.sh [--before YYYY-MM-DD]"
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

cmd=("$SCRIPT_DIR/backup-status.sh")
if [[ -n "$before_date" ]]; then
    cmd+=(--before "$before_date")
fi

output="$("${cmd[@]}")"

host="unknown"
last_run_age_hours="-1"
overall_status="UNKNOWN"

declare -A job
declare -A seen
job_order=()

while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^([a-zA-Z0-9_]+)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"

    case "$key" in
        host) host="$value" ;;
        last_run_age_hours) last_run_age_hours="$value" ;;
        overall_status) overall_status="$value" ;;
        job_*)
            if [[ "$key" =~ ^job_([0-9]+)_([a-z_]+)$ ]]; then
                idx="${BASH_REMATCH[1]}"
                field="${BASH_REMATCH[2]}"
                job["${idx}_${field}"]="$value"
                if [[ -z "${seen[$idx]:-}" ]]; then
                    seen["$idx"]=1
                    job_order+=("$idx")
                fi
            fi
            ;;
    esac
done <<< "$output"

if [[ "$last_run_age_hours" =~ ^-?[0-9]+$ ]] && [[ "$last_run_age_hours" -ge 0 ]]; then
    age_str="${last_run_age_hours}h ago"
else
    age_str="never"
fi

overall_label="$overall_status"
case "$overall_status" in
    OK) overall_label="[OK]" ;;
    FAILED) overall_label="[FAILED]" ;;
    NEVER_RUN) overall_label="[NEVER_RUN]" ;;
    *) overall_label="[${overall_status}]" ;;
esac

printf "%-8s  %-12s last run %s\n" "$host" "$overall_label" "$age_str"

if [[ ${#job_order[@]} -eq 0 ]]; then
    printf "          (no jobs)\n"
    exit 0
fi

for idx in "${job_order[@]}"; do
    dest="${job["${idx}_dest"]:-?}"
    status="${job["${idx}_status"]:-UNKNOWN}"
    pending_files="${job["${idx}_pending_files"]:-?}"
    pending_human="${job["${idx}_pending_human"]:-?}"
    dest_avail="${job["${idx}_dest_avail_human"]:-?}"
    dest_total_kb="${job["${idx}_dest_total_kb"]:-}"
    err="${job["${idx}_error"]:-}"

    if [[ -n "$dest_total_kb" && "$dest_total_kb" =~ ^[0-9]+$ ]]; then
        dest_total_human=$(numfmt --to=iec --suffix=B --from-unit=1024 "$dest_total_kb" 2>/dev/null || echo "${dest_total_kb}K")
    else
        dest_total_human="?"
    fi

    space_str="${dest_avail} of ${dest_total_human} free"

    if [[ -n "$err" ]]; then
        printf "          %-22s  [ERROR] %s\n" "$dest" "$err"
    elif [[ "$status" == "OK" || "$status" == "UP_TO_DATE" ]]; then
        printf "          %-22s  [OK]         %s\n" "$dest" "$space_str"
    elif [[ "$status" == "PENDING" ]]; then
        printf "          %-22s  [PENDING]    %s files (%s)   %s\n" \
            "$dest" "$pending_files" "$pending_human" "$space_str"
    elif [[ "$status" == "STALE" ]]; then
        printf "          %-22s  [STALE]      %s files (%s)   %s\n" \
            "$dest" "$pending_files" "$pending_human" "$space_str"
    else
        printf "          %-22s  [%s]  %s files (%s)   %s\n" \
            "$dest" "$status" "$pending_files" "$pending_human" "$space_str"
    fi
done
