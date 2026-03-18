#!/usr/bin/env bash
# backup-status.sh — show health summary for AI agents and humans
# Outputs both human-readable text and key=value lines
# Usage: backup-status.sh [--before-date YYYY-MM-DD] [--before-time HH]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${HOME}/.local/state/backup-kit"
RESULT_FILE="${STATE_DIR}/last-run.txt"
JOBS_FILE="$SCRIPT_DIR/jobs.txt"

[ -f "$JOBS_FILE" ] || {
    echo "ERROR: jobs file not found: $JOBS_FILE" >&2
    exit 1
}

# Parse arguments
before_date=""
before_time=""
while [[ $# -gt 0 ]]; do
    case "$1" in
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
            exit 2
            ;;
    esac
done

# Compute max_age (always apply, with defaults)
max_age=""
# Default to today at 1AM if not specified
cutoff_date="${before_date:-$(date +%Y-%m-%d)}"
cutoff_time="${before_time:-1}"

# Construct datetime string (pad hour if needed)
cutoff_time=$(printf "%02d" "$cutoff_time")
cutoff_datetime="$cutoff_date $cutoff_time:00:00"

# Convert to epoch
cutoff_epoch=$(date -d "$cutoff_datetime" +%s 2>/dev/null) || {
    echo "ERROR: invalid date/time: $cutoff_datetime" >&2
    exit 2
}

# Current epoch
now_epoch=$(date +%s)

# max_age in seconds (how old files must be to be included)
max_age=$((now_epoch - cutoff_epoch))

# Clamp to non-negative (if cutoff is in future, don't pass flag)
if [[ $max_age -lt 0 ]]; then
    max_age=""
fi

# Read last run metadata
last_run_epoch=0
last_run_result=""
if [[ -f "$RESULT_FILE" ]]; then
    source "$RESULT_FILE"
fi

# Calculate age
now=$(date +%s)
if [[ "$last_run_epoch" -gt 0 ]]; then
    age_seconds=$((now - last_run_epoch))
    age_hours=$((age_seconds / 3600))
else
    age_seconds=-1
    age_hours=-1
fi

echo "=== Backup Status ==="
echo "host=$(hostname)"
echo ""

# Last run info
if [[ "$last_run_epoch" -gt 0 ]]; then
    echo "last_run_date=$last_run_date"
    echo "last_run_age_hours=$age_hours"
    echo "last_run_result=$last_run_result"
    
    if [[ "$last_run_result" == "0" ]]; then
        echo "last_run_status=OK"
    else
        echo "last_run_status=FAILED"
    fi
else
    echo "last_run_date=never"
    echo "last_run_age_hours=-1"
    echo "last_run_status=NEVER_RUN"
fi

echo ""

# Check each job
job_index=0
while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    IFS=':' read -r src dest <<< "$line"
    [ -n "$src" ] && [ -n "$dest" ] || continue
    
    echo "--- Job $job_index: $src -> $dest ---"
    echo "job_${job_index}_src=$src"
    echo "job_${job_index}_dest=$dest"
    echo "job_${job_index}_enabled=1"
    
    # Get pending counts
    sync_cmd=("$SCRIPT_DIR/backup-sync.sh" --mode plan --src "$src" --dest "$dest")
    if [[ -n "$max_age" ]]; then
        sync_cmd+=(--max-age "$max_age")
    fi
    plan_output=$("${sync_cmd[@]}" 2>&1) || {
        echo "job_${job_index}_status=ERROR"
        echo "job_${job_index}_error=$plan_output"
        echo ""
        job_index=$((job_index + 1))
        continue
    }
    
    # Parse plan output
    pending_files=$(echo "$plan_output" | grep "^pending_files=" | cut -d= -f2)
    pending_bytes=$(echo "$plan_output" | grep "^pending_bytes=" | cut -d= -f2)
    pending_human=$(echo "$plan_output" | grep "^pending_human=" | cut -d= -f2)
    
    echo "job_${job_index}_pending_files=$pending_files"
    echo "job_${job_index}_pending_bytes=$pending_bytes"
    echo "job_${job_index}_pending_human=$pending_human"
    
    # Disk space on destination
    if df_line=$(df -P "$dest" 2>/dev/null | tail -1); then
        dest_total_kb=$(echo "$df_line" | awk '{print $2}')
        dest_used_kb=$(echo "$df_line" | awk '{print $3}')
        dest_avail_kb=$(echo "$df_line" | awk '{print $4}')
        dest_used_pct=$(echo "$df_line" | awk '{print $5}')
        # Human-readable available space
        if command -v numfmt &>/dev/null; then
            dest_avail_human=$(numfmt --to=iec --suffix=B -- "${dest_avail_kb}000" 2>/dev/null || echo "${dest_avail_kb}K")
        else
            dest_avail_human="${dest_avail_kb}K"
        fi
        echo "job_${job_index}_dest_total_kb=$dest_total_kb"
        echo "job_${job_index}_dest_used_kb=$dest_used_kb"
        echo "job_${job_index}_dest_avail_kb=$dest_avail_kb"
        echo "job_${job_index}_dest_avail_human=$dest_avail_human"
        echo "job_${job_index}_dest_used_pct=$dest_used_pct"
    else
        echo "job_${job_index}_dest_avail_human=UNKNOWN"
        echo "job_${job_index}_dest_used_pct=UNKNOWN"
    fi
    
    # Determine status
    if [[ "$pending_files" == "0" ]]; then
        echo "job_${job_index}_status=OK"
    else
        echo "job_${job_index}_status=PENDING"
    fi
    
    echo ""
    job_index=$((job_index + 1))
done < "$JOBS_FILE"

# Overall health verdict
if [[ "$last_run_result" != "0" && "$last_run_epoch" -gt 0 ]]; then
    echo "overall_status=FAILED"
elif [[ "$last_run_epoch" -eq 0 ]]; then
    echo "overall_status=NEVER_RUN"
else
    echo "overall_status=OK"
fi
