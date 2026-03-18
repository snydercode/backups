#!/usr/bin/env bash
# backup-sync.sh — core rsync logic for backup operations
# Usage: backup-sync.sh --mode plan|run --src <path> --dest <path>
#
# Rsync policy (append-only, safe):
#   -a                 archive mode
#   --ignore-existing  never overwrite files already in dest
#   --partial          keep partial files on interrupt
#   --partial-dir      store partials in hidden dir (atomic finalization)
#   NO --delete        never remove files from dest
#   NO --inplace       use temp file + rename (atomic writes)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${HOME}/.local/state/backup-kit"
LOG_FILE="${STATE_DIR}/last-run.log"
RESULT_FILE="${STATE_DIR}/last-run.txt"

# Rsync flags for append-only, atomic, resumable backups
RSYNC_FLAGS=(
    -a
    --ignore-existing
    --partial
    --partial-dir=.rsync-partial
    --stats
    --human-readable
)

usage() {
    echo "usage: $0 --mode plan|run --src <path> --dest <path> [--max-age SECONDS]" >&2
    exit 2
}

die() {
    echo "ERROR: $1" >&2
    exit 1
}

ensure_state_dir() {
    mkdir -p "$STATE_DIR"
}

check_mount() {
    local path="$1"
    local mount_root
    
    # Extract mount point (first or second path component depending on pattern)
    # For /mnt/e/data, check /mnt/e (WSL drive mount)
    # For /bak/1/data, check /bak/1 (multi-level mount)
    # For /phobos/data, check /phobos (single-level mount)
    if [[ "$path" =~ ^(/mnt/[a-z]) ]]; then
        # WSL: /mnt/e/... → /mnt/e
        mount_root="${BASH_REMATCH[1]}"
    elif [[ "$path" =~ ^(/bak/[^/]+) ]]; then
        # Multi-disk: /bak/1/... → /bak/1
        mount_root="${BASH_REMATCH[1]}"
    elif [[ "$path" =~ ^(/[^/]+) ]]; then
        # Single mount: /phobos/... → /phobos
        mount_root="${BASH_REMATCH[1]}"
    else
        mount_root="$path"
    fi
    
    # On WSL, /mnt/* are always "mounted" via 9p — just check existence
    if [[ "$mount_root" =~ ^/mnt/ ]]; then
        [ -d "$path" ] || die "destination not accessible: $path"
        return 0
    fi
    
    # On Linux, verify it's a real mount point
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

run_plan() {
    local src="$1"
    local dest="$2"
    local max_age="${3:-}"
    
    check_mount "$dest"
    
    local rsync_cmd=("${RSYNC_FLAGS[@]}" --dry-run)
    
    # For rsync 3.2.0+, use --max-age. For older versions, filter via find.
    if [[ -n "$max_age" ]]; then
        # Try --max-age first (3.2.0+)
        if rsync --help | grep -q -- "--max-age"; then
            rsync_cmd+=(--max-age="$max_age")
        else
            # Fallback: use find to exclude files newer than max_age seconds ago
            # Convert max_age (seconds) to a cutoff timestamp, then use -newermt
            local cutoff_epoch=$(($(date +%s) - max_age))
            local cutoff_date
            cutoff_date=$(date -d "@$cutoff_epoch" '+%Y-%m-%d %H:%M:%S')
            
            # Generate list of files to exclude
            local exclude_file
            exclude_file=$(mktemp)
            trap "rm -f '$exclude_file'" RETURN
            
            find "$src" -type f -newermt "$cutoff_date" 2>/dev/null | while read -r file; do
                # Compute relative path for exclude pattern
                rel_path="${file#$src/}"
                echo "$rel_path"
            done > "$exclude_file"
            
            # Add exclude list to rsync command
            if [[ -s "$exclude_file" ]]; then
                rsync_cmd+=(--exclude-from="$exclude_file")
            fi
        fi
    fi
    
    local output
    output=$(rsync "${rsync_cmd[@]}" "$src/" "$dest/" 2>&1)
    
    # Extract stats
    local files bytes
    files=$(echo "$output" | awk '/Number of regular files transferred:/ { gsub(/,/, "", $NF); print $NF+0 }')
    bytes=$(echo "$output" | awk -F': ' '/Total transferred file size:/ { gsub(/,/, "", $2); gsub(/ bytes/, "", $2); print $2+0 }')
    
    files="${files:-0}"
    bytes="${bytes:-0}"
    
    # Human-readable bytes
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

run_backup() {
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
    
    # Write result file for status checks
    {
        echo "last_run_epoch=$end_time"
        echo "last_run_date=\"$(date -d "@$end_time" '+%Y-%m-%d %H:%M:%S')\""
        echo "last_run_duration=$duration"
        echo "last_run_result=$exit_code"
        echo "last_run_src=$src"
        echo "last_run_dest=$dest"
    } > "$RESULT_FILE"
    
    if [[ $exit_code -eq 0 ]]; then
        make_readonly "$dest" "$LOG_FILE"
    else
        echo "rsync exited with $exit_code — skipping chmod pass" | tee -a "$LOG_FILE"
    fi

    echo "Finished: $(date) (${duration}s, exit=$exit_code)" | tee -a "$LOG_FILE"
    return $exit_code
}

# --- main ---

main() {
    local mode="" src="" dest="" max_age=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)     mode="$2"; shift 2 ;;
            --src)      src="$2"; shift 2 ;;
            --dest)     dest="$2"; shift 2 ;;
            --max-age)  max_age="$2"; shift 2 ;;
            *)          usage ;;
        esac
    done
    
    [[ -z "$mode" || -z "$src" || -z "$dest" ]] && usage
    
    case "$mode" in
        plan) run_plan "$src" "$dest" "$max_age" ;;
        run)  run_backup "$src" "$dest" ;;
        *)    usage ;;
    esac
}

main "$@"
