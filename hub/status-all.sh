#!/usr/bin/env bash
# status-all.sh — check backup status across all hosts
# Calls ~/backup-kit/backup-status.sh on each host via SSH

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS_FILE="$SCRIPT_DIR/hosts.txt"

REMOTE_KIT_DIR="/home/toor/backup-kit"
MODE="verbose"

usage() {
    cat <<'EOF'
usage: status-all.sh [--short]

Options:
  --short   Print compact human-readable status lines
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --short)
            MODE="short"
            shift
            ;;
        -h|--help)
            usage
            exit 0
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
    if [[ "$line" == *":wsl" ]]; then
        IS_WSL+=("1")
    else
        IS_WSL+=("0")
    fi
    HOSTS+=("$host")
done < "$HOSTS_FILE"

fetch_host_status() {
    local host="$1"
    local is_wsl="$2"

    if [[ "$is_wsl" == "1" ]]; then
        # Windows host — run via WSL
        ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
            "wsl.exe -e bash -lc '$REMOTE_KIT_DIR/backup-status.sh'" 2>&1
    else
        # Linux host — direct
        ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
            "$REMOTE_KIT_DIR/backup-status.sh" 2>&1
    fi
}

print_short_host_status() {
    local host="$1"
    local output="$2"

    local last_run_date="unknown"
    local last_run_age_hours="-1"
    local last_run_status="UNKNOWN"
    local overall_status="UNKNOWN"

    local -A job
    local -A seen
    local -a job_order=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^([a-zA-Z0-9_]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            case "$key" in
                last_run_date) last_run_date="$value" ;;
                last_run_age_hours) last_run_age_hours="$value" ;;
                last_run_status) last_run_status="$value" ;;
                overall_status) overall_status="$value" ;;
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

    printf "%s overall=%s run=%s age=%sh last=%s\n" \
        "$host" "$overall_status" "$last_run_status" "$last_run_age_hours" "$last_run_date"

    if [[ ${#job_order[@]} -eq 0 ]]; then
        echo "  no_jobs=found"
        return
    fi

    local idx
    for idx in "${job_order[@]}"; do
        local src="${job["${idx}_src"]:-?}"
        local dest="${job["${idx}_dest"]:-?}"
        local status="${job["${idx}_status"]:-UNKNOWN}"
        local enabled="${job["${idx}_enabled"]:-1}"
        local pending_files="${job["${idx}_pending_files"]:-?}"
        local pending_human="${job["${idx}_pending_human"]:-?}"
        local err="${job["${idx}_error"]:-}"

        if [[ "$enabled" == "0" ]]; then
            status="DISABLED"
        fi

        if [[ -n "$err" ]]; then
            printf "  %s -> %s status=%s error=%s\n" "$src" "$dest" "$status" "$err"
        else
            printf "  %s -> %s status=%s pending=%s (%s)\n" \
                "$src" "$dest" "$status" "$pending_files" "$pending_human"
        fi
    done
}

render_host_output() {
    local host="$1"
    local success="$2"
    local output="$3"

    if [[ "$success" != "1" ]]; then
        if [[ "$MODE" == "short" ]]; then
            echo "$host overall=ERROR run=UNKNOWN age=-1h last=unknown"
            echo "  error=unreachable_or_status_failed"
        else
            echo "========================================"
            echo "[$host]"
            echo "========================================"
            echo "ERROR: could not reach $host or backup-status.sh failed"
            echo ""
        fi
        return
    fi

    if [[ "$MODE" == "short" ]]; then
        print_short_host_status "$host" "$output"
        echo ""
    else
        echo "========================================"
        echo "[$host]"
        echo "========================================"
        echo "$output"
        echo ""
    fi
}

# --- main ---

if [[ "$MODE" == "short" ]]; then
    echo "Backup Status (short)"
else
    echo "Backup Status Report"
fi
echo "Generated: $(date)"
echo ""

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

OUT_FILES=()
RC_FILES=()
PIDS=()

for i in "${!HOSTS[@]}"; do
    out_file="$tmp_dir/out_$i.txt"
    rc_file="$tmp_dir/rc_$i.txt"

    OUT_FILES+=("$out_file")
    RC_FILES+=("$rc_file")

    {
        if fetch_host_status "${HOSTS[$i]}" "${IS_WSL[$i]}" >"$out_file" 2>&1; then
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

if [[ "$MODE" != "short" ]]; then
    echo "========================================"
    echo "Report complete."
fi
