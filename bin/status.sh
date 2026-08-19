#!/usr/bin/env bash
# status.sh — check backup status on one host
# Usage: status.sh <host> [--raw] [--before YYYY-MM-DD]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$REPO_DIR/jobs.txt"
source "$REPO_DIR/lib/jobs.sh"
source "$REPO_DIR/lib/hosts.sh"
source "$REPO_DIR/lib/remote.sh"
source "$REPO_DIR/lib/cli.sh"

REMOTE_KIT_DIR="/home/toor/backup-kit"

usage() {
    cat <<'EOF'
usage: status.sh <host> [--raw] [--before YYYY-MM-DD]

Prints backup status for one host.

Options:
  --raw                       Print machine-parseable JSON output
  --before YYYY-MM-DD         Only count files modified before this date (default: today)
EOF
}

render_human_json() {
    local output="$1"

    local host
    host=$(printf '%s\n' "$output" | jq -r '.host // "unknown"')
    local last_run_age_hours
    last_run_age_hours=$(printf '%s\n' "$output" | jq -r '.last_run.age_hours // -1')
    local overall_status
    overall_status=$(printf '%s\n' "$output" | jq -r '.overall_status // "UNKNOWN"')

    local age_str
    if [[ "$last_run_age_hours" =~ ^-?[0-9]+$ ]] && [[ "$last_run_age_hours" -ge 0 ]]; then
        age_str="${last_run_age_hours}h ago"
    else
        age_str="never"
    fi

    local overall_label="[$overall_status]"
    case "$overall_status" in
        OK) overall_label="[OK]" ;;
        FAILED) overall_label="[FAILED]" ;;
        NEVER_RUN) overall_label="[NEVER_RUN]" ;;
    esac

    printf "%-8s  %-12s last run %s\n" "$host" "$overall_label" "$age_str"

    local job_count
    job_count=$(printf '%s\n' "$output" | jq -r '.jobs | length')
    if [[ "$job_count" == "0" ]]; then
        printf "          (no jobs)\n"
        return 0
    fi

    while IFS=$'\t' read -r dest status src_last_file_time pending_files pending_human dest_avail dest_total_kb err; do
        local dest_total_human
        if [[ -n "$dest_total_kb" && "$dest_total_kb" =~ ^[0-9]+$ ]]; then
            dest_total_human=$(numfmt --to=iec --suffix=B --from-unit=1024 "$dest_total_kb" 2>/dev/null || echo "${dest_total_kb}K")
        else
            dest_total_human="?"
        fi

        local space_str="${dest_avail} of ${dest_total_human} free"

        if [[ -n "$err" ]]; then
            printf "          %-22s  [ERROR] %s   src last data %s\n" "$dest" "$err" "$src_last_file_time"
        elif [[ "$status" == "OK" || "$status" == "UP_TO_DATE" ]]; then
            printf "          %-22s  [OK]         %s   src last data %s\n" "$dest" "$space_str" "$src_last_file_time"
        elif [[ "$status" == "PENDING" ]]; then
            printf "          %-22s  [PENDING]    %s files (%s)   %s   src last data %s\n" "$dest" "$pending_files" "$pending_human" "$space_str" "$src_last_file_time"
        elif [[ "$status" == "STALE" ]]; then
            printf "          %-22s  [STALE]      %s files (%s)   %s   src last data %s\n" "$dest" "$pending_files" "$pending_human" "$space_str" "$src_last_file_time"
        else
            printf "          %-22s  [%s]  %s files (%s)   %s   src last data %s\n" "$dest" "$status" "$pending_files" "$pending_human" "$space_str" "$src_last_file_time"
        fi
    done < <(printf '%s\n' "$output" | jq -r '.jobs[] | [
            (.dest // "?"),
            (.status // "UNKNOWN"),
            (.src_last_file_time // "unknown"),
            ((.pending_files // "?")|tostring),
            (.pending_human // "?"),
            (.dest_avail_human // "?"),
            ((.dest_total_kb // "")|tostring),
            (.error // "")
        ] | @tsv')
}

die_arg() {
    echo "ERROR: $*" >&2
    usage >&2
    exit 2
}

HOSTS=()
IS_WSL=()
while IFS='|' read -r host os _user _windows_user; do
    [[ -z "$host" ]] && continue
    if [[ "$os" != "linux" && "$os" != "wsl" ]]; then
        echo "ERROR: host '$host' has invalid or missing os in $CONFIG_FILE" >&2
        exit 1
    fi
    HOSTS+=("$host")
    if [[ "$os" == "wsl" ]]; then
        IS_WSL+=("1")
    else
        IS_WSL+=("0")
    fi
done < <(jobs_list_host_meta "$CONFIG_FILE")

main() {
    local host="${1:-}"
    local before_date=""
    local raw=0

    [[ -n "$host" ]] || die_arg "missing host"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --raw)
                raw=1
                shift
                ;;
            --before)
                [[ $# -ge 2 ]] || die_arg "--before requires YYYY-MM-DD"
                before_date="$2"
                is_valid_before_date "$before_date" || die_arg "invalid --before date '$before_date' (expected YYYY-MM-DD)"
                shift 2
                ;;
            *)
                die_arg "unknown argument: $1"
                ;;
        esac
    done

    local host_index
    host_index="$(hosts_find_index "$host" "${HOSTS[@]}")" || {
        echo "ERROR: unknown host '$host'" >&2
        usage >&2
        exit 2
    }

    local is_wsl="${IS_WSL[$host_index]}"
    local output

    # A Windows host answers from whichever runtime its scheduled task runs. The
    # probe costs one extra ssh round trip per Windows host per check and keeps a
    # half-migrated fleet reporting correctly in both directions.
    local runtime=0
    if [[ "$is_wsl" == "1" ]]; then
        remote_windows_runtime "$host" -o BatchMode=yes -o ConnectTimeout=10 \
            || runtime=$?
        # A probe that could not answer must not be treated as "still on WSL":
        # on a cut-over host that reads a state file nothing has written since
        # cutover, and a healthy host reports as stale. Fail loudly instead.
        if [[ "$runtime" -ge 2 ]]; then
            echo "ERROR: could not determine the backup runtime on $host" >&2
            echo "       (schtasks query for $WIN_TASK_NAME failed)" >&2
            exit 1
        fi
    fi

    if [[ "$runtime" -eq 0 && "$is_wsl" == "1" ]]; then
        local win_cmd="powershell.exe -NoProfile -ExecutionPolicy Bypass"
        win_cmd="$win_cmd -File $WIN_KIT_DIR\\backup.ps1 status"
        # Unquoted on purpose: cmd.exe would pass the quotes through to
        # PowerShell as part of the value. backup.ps1 validates the format.
        if [[ -n "$before_date" ]]; then
            win_cmd="$win_cmd -Before $before_date"
        fi
        output="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "$win_cmd")"
    else
        local cmd="$REMOTE_KIT_DIR/backup.sh status --raw"

        if [[ -n "$before_date" ]]; then
            cmd="$cmd --before '$before_date'"
        fi

        output="$(remote_exec "$host" "$is_wsl" "$cmd" -o BatchMode=yes -o ConnectTimeout=10)"
    fi

    if [[ "$raw" == "1" ]]; then
        printf '%s\n' "$output"
    else
        render_human_json "$output"
    fi
}

main "$@"
