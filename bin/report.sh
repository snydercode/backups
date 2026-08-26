#!/usr/bin/env bash
# report.sh — weekly backup report email (cron entry point, Mondays 08:30).
#
# Aggregates the daily check runs (bin/check.sh) from the last 7 calendar days
# into one always-sent email. Sent on all-PASS weeks too — positive confirmation
# that the checks themselves are alive. The Todoist dead-man's task remains the
# primary alarm; a failed send here is logged, nothing more.
#
# Shape is deliberate: the subject line carries the verdict; the body opens with
# the model-written SUMMARY when there is one, then either "NOTHING TO DO" or a
# numbered action list. A report that takes effort to read stops being read.
#
# Actions and the subject come from the NEWEST run only. A finding the latest
# check no longer reports has been superseded — by a fixed fault or by a changed
# gate rule — and must not drive the subject line. Older findings still in the
# window are listed, unnumbered, under ALSO SEEN THIS WEEK.
#
# usage: report.sh [--days N] [--dry-run] [--no-summary]
#   --days N       window size in calendar days, default 7
#   --dry-run      print subject and body to stdout instead of emailing
#   --no-summary   skip the Claude-written SUMMARY section (it is skipped
#                  automatically when there is nothing to act on)
# env: CLAUDE_BIN   path to the claude CLI, default ~/.local/bin/claude

set -u
PATH=/usr/local/bin:/usr/bin:/bin
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$REPO_DIR/lib/render.sh"

readonly EMAIL_TO="charles.d.holmes@gmail.com"
readonly EMAIL_BIN="$HOME/scripts/email"
readonly STATE_DIR="$HOME/.local/state/backup-kit-check"

# Optional SUMMARY section. Runs only when there is at least one action, so
# an all-clear week costs nothing and adds no failure mode. Every outcome
# other than usable text (missing binary, timeout, non-zero exit, empty or
# NONE reply) omits the section and leaves the rest of the report untouched:
# the verdict, the action list and the counts are computed in bash above and
# are never shown to the model as something it may revise. See lib/gate.sh —
# the fail-safe guarantee rests on no LLM deciding "all's well".
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
readonly SUMMARY_TIMEOUT=120
readonly SUMMARY_MAX_LINES=3
readonly SUMMARY_MAX_COLS=200
readonly SUMMARY_MAX_BYTES=2000
readonly SUMMARY_WRAP=72

log() {
    printf '%s report: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

days=7
dry_run=0
want_summary=1
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
        --no-summary)
            want_summary=0
            shift
            ;;
        -h|--help)
            sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

# Turn a gate finding into an imperative. The gate's `detail` is diagnostic
# prose; what the reader needs at 08:30 on a Monday is the command to run.
# Sets ACTION_CMD to the command to run, or empty when there isn't one.
#

# Ask Claude what the failing findings mean taken together. Prints the section
# on success and nothing at all otherwise — every failure path here is a
# no-op, never an error, because a missing paragraph must not cost the reader
# the report. Args: <failing findings tsv> <fleet summary lines>
claude_summary() {
    local findings="$1" fleet="$2" out=""
    [[ -x "$CLAUDE_BIN" ]] || return 0

    local prompt="You are annotating an automated backup health report. Do NOT
give a verdict, do NOT say whether things are fine, and do NOT repeat the
findings verbatim. The report already states what is wrong and what to do.

Add at most $SUMMARY_MAX_LINES lines of plain text explaining what these
findings mean TAKEN TOGETHER: correlations between hosts, a likely shared root
cause, or which item is most urgent and why. If you see no meaningful pattern,
reply with exactly: NONE

Hard limit: each line must be a single sentence under 120 characters. The
reader has ADHD and will not read a paragraph. Lead with the most useful
observation; drop the rest rather than running long.

State only what the data below shows. Hosts reuse mount names (/phobos,
/deimos) for different physical volumes, so never infer that two hosts share
storage — compare the totals, which are listed per destination.

No markdown, no bullets, no preamble.

FINDINGS (from the most recent check):
$findings

FLEET:
$fleet"

    # </dev/null: the CLI waits on stdin otherwise, and cron has none.
    out="$(timeout "$SUMMARY_TIMEOUT" "$CLAUDE_BIN" -p "$prompt" \
        </dev/null 2>/dev/null)" || return 0

    out="$(printf '%s' "$out" | render_clamp_note \
        "$SUMMARY_MAX_LINES" "$SUMMARY_MAX_COLS" "$SUMMARY_MAX_BYTES")"
    [[ -z "$out" || "$out" == "NONE" ]] && return 0

    printf 'SUMMARY (written by Claude, not part of the verdict)\n'
    printf '%s' "$out" | render_wrap_note "$SUMMARY_WRAP"
}


# Collapse identical findings to one row: same status+host+code+key seen nine
# times is one fact, not nine lines. Emits
# status, host, code, key, count, first_day, last_day, detail.
dedup_findings() {
    awk -F'\t' '
        {
            day = $1; st = $2; host = $3; code = $4
            if (NF >= 6) { key = $5; det = $6 } else { key = "-"; det = $5 }
            # Legacy runs wrote no key column. Recover the destination from the
            # detail prefix ("/phobos/data: 23GB free ...") before building the
            # dedup key, or two destinations on one host collapse into one row.
            if (key == "-" && det ~ /^\//) { split(det, p, ":"); key = p[1] }
            k = st "\t" host "\t" code "\t" key
            if (!(k in cnt)) { first[k] = day; order[++n] = k }
            cnt[k]++
            last[k] = day; detail[k] = det
        }
        END {
            for (i = 1; i <= n; i++) {
                k = order[i]
                printf "%s\t%s\t%s\t%s\t%s\n", k, cnt[k], first[k], last[k], detail[k]
            }
        }'
}

total=0
failed_runs=0
missed=0
ran_days=0
missed_days=""
latest_fleet=""
raw_findings=""
current_findings=""

for ((i = days - 1; i >= 0; i--)); do
    day="$(date -d "-$i days" +%Y%m%d)"
    day_h="$(date -d "-$i days" +%Y-%m-%d)"
    run_dirs=("$STATE_DIR"/run-"$day"-*/)
    if [[ ${#run_dirs[@]} -eq 0 ]]; then
        missed=$((missed + 1))
        missed_days+="${missed_days:+, }$day_h"
        continue
    fi
    ran_days=$((ran_days + 1))
    for run in "${run_dirs[@]}"; do
        total=$((total + 1))
        run_findings=""
        # Unreadable, absent or zero-byte all mean the check's verdict is gone.
        # Reading that as "no findings" is a fail-open: bin/check.sh always
        # writes at least a newline, so an empty file means the check died
        # mid-write, not that the fleet was clean.
        if [[ ! -r "$run/findings.tsv" || ! -s "$run/findings.tsv" ]]; then
            failed_runs=$((failed_runs + 1))
            run_findings="$day_h	FAIL	-	INCOMPLETE_RUN	-	findings.tsv missing, unreadable or truncated (check crashed?)"$'\n'
        else
            grep -q '^FAIL' "$run/findings.tsv" && failed_runs=$((failed_runs + 1))
            # Stamp each finding with its day so repeats collapse to a range.
            while IFS= read -r line; do
                [[ -n "$line" ]] && run_findings+="$day_h	$line"$'\n'
            done < "$run/findings.tsv"
        fi
        raw_findings+="$run_findings"
        # Loop runs oldest-first, so the last assignment is the newest run.
        current_findings="$run_findings"
        [[ -s "$run/fleet.json" ]] && latest_fleet="$run/fleet.json"
    done
done

current_dedup="$(dedup_findings <<< "$current_findings")"
window_dedup="$(dedup_findings <<< "$raw_findings")"

# Keys the newest check still reports. Anything else in the window is history.
current_keys="$(cut -f1-4 <<< "$current_dedup" | grep -v '^[[:space:]]*$')"

known=""
fail_tsv=""

# A dead check pipeline outranks any single-host finding, and it is the item
# the fold would otherwise drop. It goes first, always. It is not a gate
# finding, so it is synthesised into one — the renderer knows NO_CHECK.
action_tsv=""
if [[ "$missed" -gt 0 ]]; then
    action_tsv+="-	NO_CHECK	-	$missed_days"$'\n'
fi

while IFS=$'\t' read -r st host code key cnt first last detail; do
    [[ -z "$st" ]] && continue
    case "$st" in
        FAIL)
            fail_tsv+="$host	$code	$key	$detail"$'\n'
            ;;
        INFO|ACK)
            known+="  $(known_desc "$host" "$code" "$detail")"$'\n'
            ;;
    esac
done <<< "$current_dedup"

action_tsv+="$fail_tsv"
action_count="$(render_action_count <<< "$action_tsv")"
failing_hosts="$(render_failing_hosts <<< "$action_tsv")"
actions="$(render_actions <<< "$action_tsv")"$'\n'

# Findings from earlier in the window that the newest check no longer reports.
# Listed, not numbered: they are context, not work.
also_seen=""
while IFS=$'\t' read -r st host code key cnt first last detail; do
    [[ -z "$st" || "$st" != "FAIL" ]] && continue
    grep -qxF "$st	$host	$code	$key" <<< "$current_keys" && continue
    when="last seen $last"
    [[ "$cnt" -gt 1 && "$first" == "$last" ]] && when="$cnt checks on $last"
    [[ "$cnt" -gt 1 && "$first" != "$last" ]] && when="$cnt checks, $first to $last"
    # Without the key, a host's two destinations render as identical lines.
    what="$host $code"
    [[ "$key" != "-" && -n "$key" ]] && what="$host $code $key"
    also_seen+="$(printf '  %s (%s)' "$what" "$when")"$'\n'
done <<< "$window_dedup"

# Host table, worst first, so the eye lands on the failing host.
hosts_table="$(render_host_table "$latest_fleet" "$failing_hosts")"

# No host names means every action is fleet-level. Which fallback reads right
# depends on which: a missed check is not the same as config drift.
fleet_fallback="fleet-level"
[[ "$missed" -gt 0 ]] && fleet_fallback="check did not run"
subject="$(render_subject "$action_count" "$failing_hosts" "$fleet_fallback")"

if [[ "$action_count" -eq 0 ]]; then
    headline="NOTHING TO DO."$'\n'
else
    headline="DO THIS ($action_count):
$actions"
fi

checks_line="$ran_days of $days days ran, $total checks, $failed_runs failed."
[[ "$missed" -gt 0 ]] && checks_line+=" No check on: $missed_days."

summary=""
if [[ "$want_summary" -eq 1 && "$action_count" -gt 0 && -n "$latest_fleet" ]]; then
    # Per-destination sizes matter: hosts share mount NAMES (/phobos, /deimos)
    # while pointing at different volumes, and without the totals the model
    # infers a shared pool that does not exist.
    fleet_lines="$(jq -r '.hosts[]
        | (.fleet_host // .host // "?") as $h
        | "\($h): \(.overall_status // "?"), last run \(.last_run.age_hours // "?")h ago, \([.jobs[]?.pending_files] | add // 0) files pending",
          (.jobs[]? | "    \($h) \(.dest): \(.dest_avail_human // "?") free of \(((.dest_total_kb // 0) / 1048576 | floor))GB total, \(.dest_used_pct // "?") used")
        ' "$latest_fleet" 2>/dev/null)"
    summary="$(claude_summary "$fail_tsv" "$fleet_lines")"
fi

# Prose first, tables second. The summary is what gets read; the host table
# and counts are there to check it against, not to be waded through.
body=""
[[ -n "$summary" ]] && body+="$summary"$'\n\n'

body+="$headline
$(printf '  %-8s %13s %9s' "HOST" "last backup" "waiting")
$hosts_table
"
[[ -n "$known" ]] && body+="
KNOWN, NOT ACTIONABLE
$known"
[[ -n "$also_seen" ]] && body+="
ALSO SEEN THIS WEEK (not reported by the latest check)
$also_seen"
body+="
CHECKS  $checks_line

Details: $STATE_DIR on quintana (run-*/fleet.json, findings.tsv)
Report:  $(date '+%Y-%m-%d %H:%M') on quintana, window $days days"

if [[ "$dry_run" -eq 1 ]]; then
    printf 'SUBJECT: %s\n\n%s\n' "$subject" "$body"
    exit 0
fi

if ! "$EMAIL_BIN" --to "$EMAIL_TO" -s "$subject" <<< "$body"; then
    log "email send failed (subject: $subject)"
    exit 1
fi
log "sent: $subject"
