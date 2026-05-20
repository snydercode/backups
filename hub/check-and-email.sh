#!/usr/bin/env bash
# check-and-email.sh — collect backup status and email a daily digest
# Runs from the hub (chuck's workstation); no changes needed on remote hosts.
#
# Usage: check-and-email.sh [--dry-run]
#   --dry-run   Print the email to stdout instead of sending it

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS_FILE="$SCRIPT_DIR/hosts.txt"
REMOTE_KIT_DIR="/home/toor/backup-kit"

EMAIL_TO="chuck@eye-hand.wustl.edu"
EMAIL_FROM="backup-kit@eye-hand.wustl.edu"
SEND_HOST="eye"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
fi

LOCAL_HOST="$(hostname -s 2>/dev/null || hostname)"

BEFORE_DATE="$(date +%Y-%m-%d)"

# --- Parse hosts.txt ---

HOSTS=()
IS_WSL=()
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    host="${line%%:*}"
    [[ "$line" == *":wsl"* ]] && IS_WSL+=("1") || IS_WSL+=("0")
    HOSTS+=("$host")
done < "$HOSTS_FILE"

# --- Fetch status and running-check in parallel ---

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# Pass 1: Linux hosts in parallel
for i in "${!HOSTS[@]}"; do
    host="${HOSTS[$i]}"
    is_wsl="${IS_WSL[$i]}"
    [[ "$is_wsl" == "1" ]] && continue
    out="$tmp_dir/status_$i.txt"
    rc="$tmp_dir/rc_$i.txt"
    run="$tmp_dir/running_$i.txt"
    {
        cmd="$REMOTE_KIT_DIR/backup.sh status --before $BEFORE_DATE"
        if ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "$cmd" >"$out" 2>&1; then
            echo "1" >"$rc"
        else
            echo "0" >"$rc"
        fi

        # Check if backup process is still running
        run_check="pgrep -f 'backup.sh run' >/dev/null && echo running || echo idle"
        ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "$run_check" >"$run" 2>/dev/null || echo "unknown" >"$run"
    } &
done
wait

# Pass 2: WSL hosts sequentially
for i in "${!HOSTS[@]}"; do
    host="${HOSTS[$i]}"
    is_wsl="${IS_WSL[$i]}"
    [[ "$is_wsl" == "0" ]] && continue
    out="$tmp_dir/status_$i.txt"
    rc="$tmp_dir/rc_$i.txt"
    run="$tmp_dir/running_$i.txt"
    if [[ "$is_wsl" == "1" ]]; then
        cmd="wsl.exe -e bash -lc '$REMOTE_KIT_DIR/backup.sh status --before $BEFORE_DATE'"
    else
        cmd="$REMOTE_KIT_DIR/backup.sh status --before $BEFORE_DATE"
    fi
    if ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "$cmd" >"$out" 2>&1; then
        echo "1" >"$rc"
    else
        echo "0" >"$rc"
    fi
    # Check if backup process is still running
    if [[ "$is_wsl" == "1" ]]; then
        run_check="wsl.exe -e bash -lc 'pgrep -f \"backup.sh run\" >/dev/null && echo running || echo idle'"
    else
        run_check="pgrep -f 'backup.sh run' >/dev/null && echo running || echo idle"
    fi
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "$run_check" >"$run" 2>/dev/null || echo "unknown" >"$run"
done


# --- Build email body ---

overall_flag="OK"   # OK | WARNING | RUNNING | FAILED
body_lines=()

for i in "${!HOSTS[@]}"; do
    host="${HOSTS[$i]}"
    success="$(<"$tmp_dir/rc_$i.txt")"
    is_running="$(<"$tmp_dir/running_$i.txt")"
    is_running="${is_running%%$'\n'*}"   # first line only

    if [[ "$success" != "1" ]]; then
        body_lines+=("$(printf "%-8s  UNREACHABLE" "$host")")
        [[ "$overall_flag" == "OK" ]] && overall_flag="WARNING"
        continue
    fi

    output="$(<"$tmp_dir/status_$i.txt")"

    # Parse key=value from status output
    last_run_age_hours="-1"
    last_run_status="UNKNOWN"
    overall_status="UNKNOWN"
    declare -A job
    declare -a job_order=()
    declare -A seen_jobs

    while IFS= read -r line; do
        [[ "$line" =~ ^([a-zA-Z0-9_]+)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        value="${value%\"}"
        value="${value#\"}"
        case "$key" in
            last_run_age_hours) last_run_age_hours="$value" ;;
            last_run_status)    last_run_status="$value" ;;
            overall_status)     overall_status="$value" ;;
            job_*)
                if [[ "$key" =~ ^job_([0-9]+)_([a-z_]+)$ ]]; then
                    idx="${BASH_REMATCH[1]}"
                    field="${BASH_REMATCH[2]}"
                    job["${idx}_${field}"]="$value"
                    if [[ -z "${seen_jobs[$idx]:-}" ]]; then
                        seen_jobs["$idx"]=1
                        job_order+=("$idx")
                    fi
                fi
                ;;
        esac
    done <<< "$output"
    unset job seen_jobs
    declare -A job
    declare -A seen_jobs

    # Re-parse cleanly (bash associative arrays don't reset well in loops)
    while IFS= read -r line; do
        [[ "$line" =~ ^(job_[a-zA-Z0-9_]+)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        value="${value%\"}"
        value="${value#\"}"
        job["$key"]="$value"
    done <<< "$output"

    # Determine host-level flag
    host_flag="$overall_status"
    if [[ "$is_running" == "running" ]]; then
        host_flag="RUNNING"
    fi

    # Escalate overall
    case "$host_flag" in
        RUNNING) [[ "$overall_flag" == "OK" ]] && overall_flag="RUNNING" ;;
        FAILED)  overall_flag="FAILED" ;;
        STALE)   [[ "$overall_flag" != "FAILED" ]] && overall_flag="WARNING" ;;
        WARNING) [[ "$overall_flag" != "FAILED" ]] && overall_flag="WARNING" ;;
        ERROR)   [[ "$overall_flag" != "FAILED" ]] && overall_flag="WARNING" ;;
    esac

    # Age string
    if [[ "$last_run_age_hours" -ge 0 ]]; then
        age_str="${last_run_age_hours}h ago"
    else
        age_str="never"
    fi

    body_lines+=("$(printf "%-8s  %-9s  last run %s" "$host" "$host_flag" "$age_str")")

    # Per-job lines
    for idx in "${!job_order[@]}"; do
        idx="${job_order[$idx]}"
        src="${job["job_${idx}_src"]:-?}"
        dest="${job["job_${idx}_dest"]:-?}"
        status="${job["job_${idx}_status"]:-UNKNOWN}"
        pending_files="${job["job_${idx}_pending_files"]:-?}"
        pending_human="${job["job_${idx}_pending_human"]:-?}"
        dest_avail="${job["job_${idx}_dest_avail_human"]:-?}"
        dest_used_pct="${job["job_${idx}_dest_used_pct"]:-?}"
        dest_total_kb="${job["job_${idx}_dest_total_kb"]:-}"
        err="${job["job_${idx}_error"]:-}"

        # Convert total KB to human-readable
        if [[ -n "$dest_total_kb" && "$dest_total_kb" =~ ^[0-9]+$ ]]; then
            dest_total_human=$(numfmt --to=iec --suffix=B --from-unit=1024 "$dest_total_kb" 2>/dev/null || echo "${dest_total_kb}K")
        else
            dest_total_human="?"
        fi

        space_str="${dest_avail} of ${dest_total_human} free"

        if [[ -n "$err" ]]; then
            body_lines+=("$(printf "          %-22s  ERROR: %s" "$dest" "$err")")
        elif [[ "$status" == "OK" || "$status" == "UP_TO_DATE" ]]; then
            body_lines+=("$(printf "          %-22s  OK            %s" "$dest" "$space_str")")
        else
            body_lines+=("$(printf "          %-22s  %-12s  %s files pending   %s" \
                "$dest" "$status" "$pending_files" "$space_str")")
        fi
    done

    unset job seen_jobs job_order
    declare -A job
    declare -A seen_jobs
    declare -a job_order=()
done

# --- Compose email ---

subject="[backup] ${overall_flag} — $(date '+%a %b %d %Y')"

body="Backup Status — $(date '+%a %b %d %Y %H:%M %Z')
========================================"
for line in "${body_lines[@]}"; do
    body+=$'\n'"$line"
done
body+=$'\n'"========================================"

# --- Send or dry-run ---

email_msg="To: ${EMAIL_TO}
From: ${EMAIL_FROM}
Subject: ${subject}

${body}"

if [[ "$DRY_RUN" == "1" ]]; then
    echo "=== DRY RUN — would send: ==="
    echo "$email_msg"
else
    if [[ "$LOCAL_HOST" == "eye-hand" ]]; then
        printf '%s\n' "$email_msg" | sendmail -t
    else
        printf '%s\n' "$email_msg" | ssh -o BatchMode=yes "$SEND_HOST" "sendmail -t"
    fi
    echo "Email sent: $subject"
fi
