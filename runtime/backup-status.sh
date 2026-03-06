#!/usr/bin/env bash
# backup-status.sh — show health summary for AI agents and humans
# Outputs both human-readable text and key=value lines

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${HOME}/.local/state/backup-kit"
RESULT_FILE="${STATE_DIR}/last-run.txt"
JOBS_FILE="$SCRIPT_DIR/jobs.txt"

[ -f "$JOBS_FILE" ] || {
    echo "ERROR: jobs file not found: $JOBS_FILE" >&2
    exit 1
}

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
    plan_output=$("$SCRIPT_DIR/backup-sync.sh" --mode plan --src "$src" --dest "$dest" 2>&1) || {
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
        echo "job_${job_index}_status=UP_TO_DATE"
    elif [[ "$age_hours" -gt 30 && "$pending_files" -gt 0 ]]; then
        echo "job_${job_index}_status=STALE"
    else
        echo "job_${job_index}_status=PENDING"
    fi
    
    echo ""
    job_index=$((job_index + 1))
done < "$JOBS_FILE"

# Overall health verdict
if [[ "$last_run_result" != "0" && "$last_run_epoch" -gt 0 ]]; then
    echo "overall_status=FAILED"
elif [[ "$age_hours" -gt 30 ]]; then
    echo "overall_status=STALE"
elif [[ "$last_run_epoch" -eq 0 ]]; then
    echo "overall_status=NEVER_RUN"
else
    echo "overall_status=OK"
fi
