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
  status [--before DATE] [--raw]
                          Show status (JSON only)

Options:
  --jobs <path>           Override jobs file (default: script-dir/jobs.txt)
  --before YYYY-MM-DD     Status cutoff date (only with status)
  --raw                   Machine-readable JSON status (only with status)
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
    # FIXME: rsync rc unchecked; a failed dry-run parses as pending 0, status OK.
    # Make a non-zero rc job_status=ERROR with rsync's first stderr line.
    # lib/gate.sh defends meanwhile via src_last_file_epoch.
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

    # FIXME: written per job, so a later clean dest overwrites an earlier failure,
    # and the gate reads this field. Write once in run_for_all_jobs with the worst rc.
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

status_machine_json() {
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

    local age_hours=-1
    local last_run_status="NEVER_RUN"
    local overall_status="UNKNOWN"
    local now
    now=$(date +%s)
    if [[ "$last_run_epoch" -gt 0 ]]; then
        local age_seconds=$((now - last_run_epoch))
        age_hours=$((age_seconds / 3600))
        if [[ "$last_run_result" == "0" ]]; then
            last_run_status="OK"
            overall_status="OK"
        else
            last_run_status="FAILED"
            overall_status="FAILED"
        fi
    else
        last_run_date="never"
        overall_status="NEVER_RUN"
    fi

    json_escape() {
        local s="$1"
        s=${s//\\/\\\\}
        s=${s//\"/\\\"}
        s=${s//$'\n'/\\n}
        s=${s//$'\r'/\\r}
        s=${s//$'\t'/\\t}
        printf '%s' "$s"
    }

    local host
    host="$(hostname)"

    local generated_at
    generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    printf '{"schema_version":1,"generated_at":"%s","host":"%s","last_run":{' \
        "$(json_escape "$generated_at")" "$(json_escape "$host")"
    printf '"date":"%s","age_hours":%s,' "$(json_escape "$last_run_date")" "$age_hours"
    if [[ "$last_run_epoch" -gt 0 ]]; then
        printf '"result":%s,' "$last_run_result"
    else
        printf '"result":null,'
    fi
    printf '"status":"%s"},"overall_status":"%s","jobs":[' \
        "$(json_escape "$last_run_status")" "$(json_escape "$overall_status")"

    local first_job=1
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        IFS=':' read -r src dest <<< "$line"
        [ -n "$src" ] && [ -n "$dest" ] || continue

        src_mtime_output=$(latest_file_mtime "$src" 2>&1) || true
        src_last_file_epoch=$(echo "$src_mtime_output" | grep '^last_file_epoch=' | cut -d= -f2)
        src_last_file_time=$(echo "$src_mtime_output" | grep '^last_file_time=' | cut -d= -f2-)
        src_last_file_epoch="${src_last_file_epoch:--1}"
        src_last_file_time="${src_last_file_time:-unknown}"

        job_status="OK"
        job_error=""
        pending_files=0
        pending_bytes=0
        pending_human="0B"
        dest_total_kb=""
        dest_used_kb=""
        dest_avail_kb=""
        dest_avail_human="UNKNOWN"
        dest_used_pct="UNKNOWN"

        sync_output=$(run_plan_one "$src" "$dest" "$max_age" 2>&1) || {
            job_status="ERROR"
            job_error="$sync_output"
            sync_output=""
        }

        if [[ "$job_status" != "ERROR" ]]; then
            pending_files=$(echo "$sync_output" | grep '^pending_files=' | cut -d= -f2)
            pending_bytes=$(echo "$sync_output" | grep '^pending_bytes=' | cut -d= -f2)
            pending_human=$(echo "$sync_output" | grep '^pending_human=' | cut -d= -f2)

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
            fi

            if [[ "$pending_files" != "0" ]]; then
                job_status="PENDING"
            fi
        fi

        if [[ $first_job -eq 0 ]]; then
            printf ','
        fi
        first_job=0

        printf '{"src":"%s","dest":"%s","enabled":1,' \
            "$(json_escape "$src")" "$(json_escape "$dest")"
        printf '"src_last_file_epoch":%s,"src_last_file_time":"%s",' \
            "$src_last_file_epoch" "$(json_escape "$src_last_file_time")"
        printf '"pending_files":%s,"pending_bytes":%s,"pending_human":"%s",' \
            "$pending_files" "$pending_bytes" "$(json_escape "$pending_human")"
        if [[ -n "$dest_total_kb" ]]; then
            printf '"dest_total_kb":%s,"dest_used_kb":%s,"dest_avail_kb":%s,' \
                "$dest_total_kb" "$dest_used_kb" "$dest_avail_kb"
        fi
        printf '"dest_avail_human":"%s","dest_used_pct":"%s","status":"%s"' \
            "$(json_escape "$dest_avail_human")" "$(json_escape "$dest_used_pct")" "$(json_escape "$job_status")"
        if [[ -n "$job_error" ]]; then
            printf ',"error":"%s"' "$(json_escape "$job_error")"
        fi
        printf '}'
    done < "$jobs_file"

    printf '],"errors":[]}\n'
}

COMMAND=""
JOBS_FILE="$DEFAULT_JOBS_FILE"
BEFORE_DATE=""

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
        --raw)
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
        status_machine_json "$JOBS_FILE" "$BEFORE_DATE"
        ;;
    *)
        die "unknown command: $COMMAND"
        ;;
esac
