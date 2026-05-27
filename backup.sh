#!/usr/bin/env bash
# backup.sh — unified backup-kit command entrypoint
# Usage: backup.sh <plan|run|status> [options]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${HOME}/.local/state/backup-kit"
LOG_FILE="${STATE_DIR}/last-run.log"
RESULT_FILE="${STATE_DIR}/last-run.txt"
DEFAULT_JOBS_FILE="$SCRIPT_DIR/jobs.txt"

RSYNC_FLAGS=(
    -a
    --ignore-existing
    --partial
    --partial-dir=.rsync-partial
    --stats
    --human-readable
)

die() {
    echo "ERROR: $1" >&2
    exit 1
}

usage() {
    cat <<'EOF'
usage: backup.sh <command> [options]

Commands:
  plan                    Show pending files/bytes for all enabled jobs
  run                     Execute backup for all enabled jobs
  status [--before DATE] [--human|--raw]
                          Show status (machine-readable by default)

Options:
  --jobs <path>           Override jobs file (default: script-dir/jobs.txt)
  --before YYYY-MM-DD     Status cutoff date (only with status)
  --human                 Human-readable status (only with status)
  --raw                   Machine-readable status (only with status)
  -h, --help              Show this help
EOF
}

ensure_state_dir() {
    mkdir -p "$STATE_DIR"
}

check_mount() {
    local path="$1"
    local mount_root

    if [[ "$path" =~ ^(/mnt/[a-z]) ]]; then
        mount_root="${BASH_REMATCH[1]}"
    elif [[ "$path" =~ ^(/bak/[^/]+) ]]; then
        mount_root="${BASH_REMATCH[1]}"
    elif [[ "$path" =~ ^(/[^/]+) ]]; then
        mount_root="${BASH_REMATCH[1]}"
    else
        mount_root="$path"
    fi

    if [[ "$mount_root" =~ ^/mnt/ ]]; then
        [ -d "$path" ] || die "destination not accessible: $path"
        return 0
    fi

    mountpoint -q "$mount_root" 2>/dev/null || die "not mounted: $mount_root"
    [ -d "$path" ] || mkdir -p "$path"
}

make_readonly() {
    local dest="$1"
    local log_file="$2"

    echo "--- chmod pass: setting files read-only in $dest ---" | tee -a "$log_file"
    local chmod_start
    chmod_start=$(date +%s)

    local count=0
    count=$(find "$dest" -type f \
        ! -name '.rsync-partial' \
        ! -path '*/.rsync-partial/*' \
        ! -perm 444 \
        -exec chmod 444 {} + \
        -print 2>>"$log_file" | wc -l) || true

    local chmod_end
    chmod_end=$(date +%s)
    local chmod_duration=$(( chmod_end - chmod_start ))
    echo "chmod pass done: ${count} files updated in ${chmod_duration}s" | tee -a "$log_file"
}

run_plan_one() {
    local src="$1"
    local dest="$2"
    local max_age="${3:-}"

    check_mount "$dest"

    local rsync_cmd=("${RSYNC_FLAGS[@]}" --dry-run)
    if [[ -n "$max_age" ]]; then
        if rsync --help | grep -q -- "--max-age"; then
            rsync_cmd+=(--max-age="$max_age")
        else
            local cutoff_epoch
            cutoff_epoch=$(($(date +%s) - max_age))
            local cutoff_date
            cutoff_date=$(date -d "@$cutoff_epoch" '+%Y-%m-%d %H:%M:%S')

            local exclude_file
            exclude_file=$(mktemp)
            trap 'rm -f "$exclude_file"' RETURN

            find "$src" -type f -newermt "$cutoff_date" 2>/dev/null | while read -r file; do
                rel_path="${file#$src/}"
                echo "$rel_path"
            done > "$exclude_file"

            if [[ -s "$exclude_file" ]]; then
                rsync_cmd+=(--exclude-from="$exclude_file")
            fi
        fi
    fi

    local output
    output=$(rsync "${rsync_cmd[@]}" "$src/" "$dest/" 2>&1)

    local files bytes
    files=$(echo "$output" | awk '/Number of regular files transferred:/ { gsub(/,/, "", $NF); print $NF+0 }')
    bytes=$(echo "$output" | awk -F': ' '
        /Total transferred file size:/ {
            gsub(/,/, "", $2)
            gsub(/ bytes/, "", $2)
            print $2+0
        }
    ')
    files="${files:-0}"
    bytes="${bytes:-0}"

    local bytes_human
    if command -v numfmt >/dev/null 2>&1; then
        bytes_human=$(numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes} bytes")
    else
        bytes_human="${bytes} bytes"
    fi

    echo "pending_files=$files"
    echo "pending_bytes=$bytes"
    echo "pending_human=$bytes_human"
}

run_backup_one() {
    local src="$1"
    local dest="$2"

    ensure_state_dir
    check_mount "$dest"

    local start_time
    start_time=$(date +%s)

    echo "=== Backup: $src -> $dest ===" | tee "$LOG_FILE"
    echo "Started: $(date)" | tee -a "$LOG_FILE"

    local exit_code=0
    rsync "${RSYNC_FLAGS[@]}" --log-file="$LOG_FILE" "$src/" "$dest/" || exit_code=$?

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo "Finished: $(date)" | tee -a "$LOG_FILE"
    echo "Duration: ${duration}s" | tee -a "$LOG_FILE"
    echo "Exit code: $exit_code" | tee -a "$LOG_FILE"

    cat > "$RESULT_FILE" <<EOF
last_run_epoch=$end_time
last_run_date="$(date '+%Y-%m-%d %H:%M:%S')"
last_run_result=$exit_code
EOF

    if [[ $exit_code -eq 0 ]]; then
        make_readonly "$dest" "$LOG_FILE"
    fi

    return $exit_code
}

run_for_all_jobs() {
    local mode="$1"
    local jobs_file="$2"
    local max_age="${3:-}"
    local exit_code=0

    [ -f "$jobs_file" ] || die "jobs file not found: $jobs_file"

    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        IFS=':' read -r src dest <<< "$line"
        [ -n "$src" ] && [ -n "$dest" ] || continue

        echo "=== $src -> $dest ==="
        if [[ "$mode" == "plan" ]]; then
            run_plan_one "$src" "$dest" "$max_age" || true
        else
            run_backup_one "$src" "$dest" || {
                echo "FAILED: $src -> $dest"
                exit_code=1
            }
        fi
        echo
    done < "$jobs_file"

    return $exit_code
}

latest_file_mtime() {
    local path="$1"

    [ -d "$path" ] || {
        echo "last_file_epoch=-1"
        echo "last_file_time=ERROR:not_a_directory"
        return 1
    }

    local latest_epoch
    latest_epoch=$(
        find "$path" -type f -printf '%T@\n' 2>/dev/null |
            awk '
                BEGIN { m=-1 }
                { if ($1 > m) m=$1 }
                END { if (m >= 0) printf "%.0f", m; else print "-1" }
            '
    )

    if [[ "$latest_epoch" == "-1" ]]; then
        echo "last_file_epoch=-1"
        echo "last_file_time=never"
        return 0
    fi

    local latest_time
    latest_time=$(date -d "@$latest_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
    echo "last_file_epoch=$latest_epoch"
    echo "last_file_time=$latest_time"
}

status_machine() {
    local jobs_file="$1"
    local before_date="$2"

    [ -f "$jobs_file" ] || die "jobs file not found: $jobs_file"

    local cutoff_date="${before_date:-$(date +%Y-%m-%d)}"
    if [[ -n "$before_date" && ! "$before_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        die "--before must be YYYY-MM-DD"
    fi

    local cutoff_datetime="$cutoff_date 00:00:00"
    local cutoff_epoch
    cutoff_epoch=$(date -d "$cutoff_datetime" +%s 2>/dev/null) || die "invalid date/time: $cutoff_datetime"

    local now_epoch
    now_epoch=$(date +%s)
    local max_age=$((now_epoch - cutoff_epoch))
    if [[ $max_age -lt 0 ]]; then
        max_age=""
    fi

    local last_run_epoch=0
    local last_run_result=""
    local last_run_date=""
    if [[ -f "$RESULT_FILE" ]]; then
        source "$RESULT_FILE"
    fi

    local now
    now=$(date +%s)
    local age_hours=-1
    if [[ "$last_run_epoch" -gt 0 ]]; then
        local age_seconds=$((now - last_run_epoch))
        age_hours=$((age_seconds / 3600))
    fi

    echo "host=$(hostname)"
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

    local job_index=0
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        IFS=':' read -r src dest <<< "$line"
        [ -n "$src" ] && [ -n "$dest" ] || continue

        echo "job_${job_index}_src=$src"
        echo "job_${job_index}_dest=$dest"
        echo "job_${job_index}_enabled=1"

        src_mtime_output=$(latest_file_mtime "$src" 2>&1) || true
        src_last_file_epoch=$(echo "$src_mtime_output" | grep '^last_file_epoch=' | cut -d= -f2)
        src_last_file_time=$(echo "$src_mtime_output" | grep '^last_file_time=' | cut -d= -f2-)
        src_last_file_epoch="${src_last_file_epoch:--1}"
        src_last_file_time="${src_last_file_time:-unknown}"
        echo "job_${job_index}_src_last_file_epoch=$src_last_file_epoch"
        echo "job_${job_index}_src_last_file_time=$src_last_file_time"

        sync_output=$(run_plan_one "$src" "$dest" "$max_age" 2>&1) || {
            echo "job_${job_index}_status=ERROR"
            echo "job_${job_index}_error=$sync_output"
            job_index=$((job_index + 1))
            continue
        }

        pending_files=$(echo "$sync_output" | grep "^pending_files=" | cut -d= -f2)
        pending_bytes=$(echo "$sync_output" | grep "^pending_bytes=" | cut -d= -f2)
        pending_human=$(echo "$sync_output" | grep "^pending_human=" | cut -d= -f2)

        echo "job_${job_index}_pending_files=$pending_files"
        echo "job_${job_index}_pending_bytes=$pending_bytes"
        echo "job_${job_index}_pending_human=$pending_human"

        if df_line=$(df -P "$dest" 2>/dev/null | tail -1); then
            dest_total_kb=$(echo "$df_line" | awk '{print $2}')
            dest_used_kb=$(echo "$df_line" | awk '{print $3}')
            dest_avail_kb=$(echo "$df_line" | awk '{print $4}')
            dest_used_pct=$(echo "$df_line" | awk '{print $5}')
            if command -v numfmt &>/dev/null; then
                dest_avail_human=$(
                    numfmt --to=iec --suffix=B -- "${dest_avail_kb}000" 2>/dev/null \
                        || echo "${dest_avail_kb}K"
                )
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

        if [[ "$pending_files" == "0" ]]; then
            echo "job_${job_index}_status=OK"
        else
            echo "job_${job_index}_status=PENDING"
        fi

        job_index=$((job_index + 1))
    done < "$jobs_file"

    if [[ "$last_run_result" != "0" && "$last_run_epoch" -gt 0 ]]; then
        echo "overall_status=FAILED"
    elif [[ "$last_run_epoch" -eq 0 ]]; then
        echo "overall_status=NEVER_RUN"
    else
        echo "overall_status=OK"
    fi
}

status_human() {
    local jobs_file="$1"
    local before_date="$2"

    local output
    output=$(status_machine "$jobs_file" "$before_date")

    local host="unknown"
    local last_run_age_hours="-1"
    local overall_status="UNKNOWN"
    declare -A job
    declare -A seen
    local job_order=()

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

    overall_label="[$overall_status]"
    case "$overall_status" in
        OK) overall_label="[OK]" ;;
        FAILED) overall_label="[FAILED]" ;;
        NEVER_RUN) overall_label="[NEVER_RUN]" ;;
    esac

    printf "%-8s  %-12s last run %s\n" "$host" "$overall_label" "$age_str"

    if [[ ${#job_order[@]} -eq 0 ]]; then
        printf "          (no jobs)\n"
        return 0
    fi

    for idx in "${job_order[@]}"; do
        dest="${job["${idx}_dest"]:-?}"
        status="${job["${idx}_status"]:-UNKNOWN}"
        src_last_file_time="${job["${idx}_src_last_file_time"]:-unknown}"
        pending_files="${job["${idx}_pending_files"]:-?}"
        pending_human="${job["${idx}_pending_human"]:-?}"
        dest_avail="${job["${idx}_dest_avail_human"]:-?}"
        dest_total_kb="${job["${idx}_dest_total_kb"]:-}"
        err="${job["${idx}_error"]:-}"

        if [[ -n "$dest_total_kb" && "$dest_total_kb" =~ ^[0-9]+$ ]]; then
            dest_total_human=$(
                numfmt --to=iec --suffix=B --from-unit=1024 "$dest_total_kb" 2>/dev/null \
                    || echo "${dest_total_kb}K"
            )
        else
            dest_total_human="?"
        fi

        space_str="${dest_avail} of ${dest_total_human} free"

        if [[ -n "$err" ]]; then
            printf "          %-22s  [ERROR] %s   src last data %s\n" "$dest" "$err" "$src_last_file_time"
        elif [[ "$status" == "OK" || "$status" == "UP_TO_DATE" ]]; then
            printf "          %-22s  [OK]         %s   src last data %s\n" "$dest" "$space_str" "$src_last_file_time"
        elif [[ "$status" == "PENDING" ]]; then
            printf "          %-22s  [PENDING]    %s files (%s)   %s   src last data %s\n" \
                "$dest" "$pending_files" "$pending_human" "$space_str" "$src_last_file_time"
        elif [[ "$status" == "STALE" ]]; then
            printf "          %-22s  [STALE]      %s files (%s)   %s   src last data %s\n" \
                "$dest" "$pending_files" "$pending_human" "$space_str" "$src_last_file_time"
        else
            printf "          %-22s  [%s]  %s files (%s)   %s   src last data %s\n" \
                "$dest" "$status" "$pending_files" "$pending_human" "$space_str" "$src_last_file_time"
        fi
    done
}

COMMAND=""
JOBS_FILE="$DEFAULT_JOBS_FILE"
BEFORE_DATE=""
STATUS_MODE="raw"

if [[ $# -eq 0 ]]; then
    usage
    exit 2
fi

COMMAND="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --jobs)
            JOBS_FILE="$2"
            shift 2
            ;;
        --before)
            BEFORE_DATE="$2"
            shift 2
            ;;
        --human)
            [[ "$STATUS_MODE" == "raw" ]] || die "--human and --raw are mutually exclusive"
            STATUS_MODE="human"
            shift
            ;;
        --raw)
            [[ "$STATUS_MODE" == "raw" || "$STATUS_MODE" == "human" ]] || true
            if [[ "$STATUS_MODE" == "human" ]]; then
                die "--human and --raw are mutually exclusive"
            fi
            STATUS_MODE="raw"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

case "$COMMAND" in
    plan)
        [[ -z "$BEFORE_DATE" ]] || die "--before is only valid with status"
        run_for_all_jobs "plan" "$JOBS_FILE"
        ;;
    run)
        [[ -z "$BEFORE_DATE" ]] || die "--before is only valid with status"
        run_for_all_jobs "run" "$JOBS_FILE"
        ;;
    status)
        if [[ "$STATUS_MODE" == "human" ]]; then
            status_human "$JOBS_FILE" "$BEFORE_DATE"
        else
            status_machine "$JOBS_FILE" "$BEFORE_DATE"
        fi
        ;;
    *)
        die "unknown command: $COMMAND"
        ;;
esac
