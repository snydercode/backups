#!/usr/bin/env bash
# report.sh — weekly backup report email (cron entry point, Mondays 08:30).
#
# Aggregates the daily check runs (bin/check.sh) from the last 7 calendar days
# into one always-sent email: per-run verdicts, days with no run, and the
# fleet snapshot from the newest run. Sent on all-PASS weeks too — positive
# confirmation that the checks themselves are alive. The Todoist dead-man's
# task remains the primary alarm; a failed send here is logged, nothing more.
#
# usage: report.sh [--days N] [--dry-run]
#   --days N     window size in calendar days, default 7
#   --dry-run    print subject and body to stdout instead of emailing

set -u
PATH=/usr/local/bin:/usr/bin:/bin
shopt -s nullglob

readonly EMAIL_TO="charles.d.holmes@gmail.com"
readonly EMAIL_BIN="$HOME/scripts/email"
readonly STATE_DIR="$HOME/.local/state/backup-kit-check"

log() {
    printf '%s report: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

days=7
dry_run=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --days)
            days="${2:?ERROR: --days needs a value}"
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        -h|--help)
            sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

total=0
failed=0
missed=0
checks=""
latest_fleet=""
latest_run_name=""

for ((i = days - 1; i >= 0; i--)); do
    day="$(date -d "-$i days" +%Y%m%d)"
    day_h="$(date -d "-$i days" +%Y-%m-%d)"
    run_dirs=("$STATE_DIR"/run-"$day"-*/)
    if [[ ${#run_dirs[@]} -eq 0 ]]; then
        checks+="$day_h        — no check ran
"
        missed=$((missed + 1))
        continue
    fi
    for run in "${run_dirs[@]}"; do
        name="$(basename "$run")"
        hhmm="${name:13:2}:${name:15:2}"
        total=$((total + 1))
        if [[ ! -e "$run/findings.tsv" ]]; then
            verdict="INCOMPLETE (no findings recorded — check crashed?)"
            failed=$((failed + 1))
        elif grep -q '^FAIL' "$run/findings.tsv" 2>/dev/null; then
            verdict="FAIL"
            failed=$((failed + 1))
        else
            verdict="PASS"
        fi
        checks+="$day_h $hhmm  $verdict
"
        # ACK/INFO lines ride along on PASS runs so chronic and informational
        # findings stay visible week to week.
        while IFS= read -r line; do
            [[ -n "$line" ]] && checks+="    $line
"
        done < <(sed 's/\t/  /g' "$run/findings.tsv" 2>/dev/null)
        if [[ -s "$run/fleet.json" ]]; then
            latest_fleet="$run/fleet.json"
            latest_run_name="$name"
        fi
    done
done

snapshot="(no fleet.json found in the window)"
if [[ -n "$latest_fleet" ]]; then
    snapshot="$(jq -r '
        .hosts[] | "\(.fleet_host): \(.overall_status), last run \(.last_run.age_hours)h ago, \([.jobs[].pending_files] | add // 0) files pending"
    ' "$latest_fleet" 2>/dev/null)" || snapshot="(could not parse $latest_fleet)"
fi

if [[ "$failed" -eq 0 && "$missed" -eq 0 ]]; then
    subject="BACKUP WEEKLY REPORT: all $total checks passed"
else
    subject="BACKUP WEEKLY REPORT: $failed of $total checks failed, $missed day(s) unchecked"
fi

body="Weekly backup report — $(date '+%Y-%m-%d %H:%M') on quintana
Window: last $days days

Daily checks:
$checks
Current fleet (from $latest_run_name):
$snapshot

Artifacts: $STATE_DIR on quintana (run-*/fleet.json, findings.tsv)."

if [[ "$dry_run" -eq 1 ]]; then
    printf 'SUBJECT: %s\n\n%s\n' "$subject" "$body"
    exit 0
fi

if ! "$EMAIL_BIN" --to "$EMAIL_TO" -s "$subject" <<< "$body"; then
    log "email send failed (subject: $subject)"
    exit 1
fi
log "sent: $subject"
