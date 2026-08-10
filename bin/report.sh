#!/usr/bin/env bash
# report.sh — weekly backup report email (cron entry point, Mondays 08:30).
#
# Aggregates the daily check runs (bin/check.sh) from the last 7 calendar days
# into one always-sent email. Sent on all-PASS weeks too — positive confirmation
# that the checks themselves are alive. The Todoist dead-man's task remains the
# primary alarm; a failed send here is logged, nothing more.
#
# Shape is deliberate: the subject line carries the verdict, the first body line
# is either "NOTHING TO DO" or a numbered action list, and repeated findings are
# collapsed to one line with an occurrence count. A report that takes effort to
# read is a report that stops being read.
#
# usage: report.sh [--days N] [--dry-run] [--no-context]
#   --days N       window size in calendar days, default 7
#   --dry-run      print subject and body to stdout instead of emailing
#   --no-context   skip the Claude-written CONTEXT section (it is skipped
#                  automatically when there is nothing to act on)
# env: CLAUDE_BIN   path to the claude CLI, default ~/.local/bin/claude

set -u
PATH=/usr/local/bin:/usr/bin:/bin
shopt -s nullglob

readonly EMAIL_TO="charles.d.holmes@gmail.com"
readonly EMAIL_BIN="$HOME/scripts/email"
readonly STATE_DIR="$HOME/.local/state/backup-kit-check"

# Actions shown before the fold, before "+N more". Five is the readable cap.
readonly MAX_ACTIONS=5

# Optional CONTEXT section. Runs only when there is at least one action, so
# an all-clear week costs nothing and adds no failure mode. Every outcome
# other than usable text (missing binary, timeout, non-zero exit, empty or
# NONE reply) omits the section and leaves the rest of the report untouched:
# the verdict, the action list and the counts are computed in bash above and
# are never shown to the model as something it may revise. See lib/gate.sh —
# the fail-safe guarantee rests on no LLM deciding "all's well".
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
readonly CONTEXT_TIMEOUT=120
readonly CONTEXT_MAX_LINES=3
readonly CONTEXT_WRAP=72

log() {
    printf '%s report: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

days=7
dry_run=0
want_context=1
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
        --no-context)
            want_context=0
            shift
            ;;
        -h|--help)
            sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
ACTION_CMD=""
action_desc() {
    local host="$1" code="$2" key="$3" detail="$4"
    # Legacy 4-field findings carry no key column; recover the destination
    # from the detail prefix ("/phobos/data: 23GB free ...").
    local dest="$key"
    [[ "$dest" == "-" || -z "$dest" ]] && dest="${detail%%:*}"
    ACTION_CMD=""
    case "$code" in
        DISK_LOW)
            # Keep the size, drop the threshold rationale the gate appends
            # after an em-dash (current format) or in parens (legacy).
            local amount="${detail#*: }"
            amount="${amount%% —*}"
            amount="${amount%% (*}"
            printf '%s — free up space on %s (%s)' "$host" "$dest" "$amount"
            ;;
        STALE_RUN)
            ACTION_CMD="bash bin/schedule.sh $host"
            printf '%s — scheduler dead AND data is waiting' "$host"
            ;;
        NEVER_RUN)
            ACTION_CMD="bash bin/schedule.sh $host"
            printf '%s — never backed up' "$host"
            ;;
        FAILED_RUN)
            ACTION_CMD="ssh $host 'cat ~/.local/state/backup-kit/last-run.log'"
            printf '%s — last backup exited non-zero' "$host"
            ;;
        DISCONNECTED)
            printf '%s — unreachable over SSH. Check it is powered on.' "$host"
            ;;
        JOB_ERROR)
            printf '%s — %s is not readable (mount gone?)' "$host" "$dest"
            ;;
        MISSING_HOST|MISSING_JOB|CONFIG_MISMATCH)
            ACTION_CMD="bash bin/deploy.sh $host"
            printf '%s — config drift' "$host"
            ;;
        RUNNER_FAILURE)
            printf 'The check itself broke — %s' "$detail"
            ;;
        *)
            printf '%s — %s: %s' "$host" "$code" "$detail"
            ;;
    esac
}

# Informational findings get the same de-jargoning, one line each.
known_desc() {
    local host="$1" code="$2" detail="$3"
    case "$code" in
        STALE_IDLE)
            printf '%s — scheduler dead (%s), nothing waiting. No data at risk.' \
                "$host" "${detail%% (limit*}"
            ;;
        *)
            printf '%s — %s' "$host" "$detail"
            ;;
    esac
}

# Ask Claude what the failing findings mean taken together. Prints the section
# on success and nothing at all otherwise — every failure path here is a
# no-op, never an error, because a missing paragraph must not cost the reader
# the report. Args: <failing findings tsv> <fleet summary lines>
claude_context() {
    local findings="$1" fleet="$2" out=""
    [[ -x "$CLAUDE_BIN" ]] || return 0

    local prompt="You are annotating an automated backup health report. Do NOT
give a verdict, do NOT say whether things are fine, and do NOT repeat the
findings verbatim. The report already states what is wrong and what to do.

Add at most $CONTEXT_MAX_LINES lines of plain text explaining what these
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

FINDINGS (deduped across the window):
$findings

FLEET:
$fleet"

    # </dev/null: the CLI waits on stdin otherwise, and cron has none.
    out="$(timeout "$CONTEXT_TIMEOUT" "$CLAUDE_BIN" -p "$prompt" \
        </dev/null 2>/dev/null)" || return 0

    out="$(printf '%s' "$out" | grep -v '^[[:space:]]*$' \
        | head -n "$CONTEXT_MAX_LINES")"
    [[ -z "$out" || "$out" == "NONE" ]] && return 0

    printf 'SUMMARY (written by Claude, not part of the verdict)\n'
    # fold -s breaks on spaces and leaves them dangling at end of line.
    printf '%s' "$out" | fold -s -w "$CONTEXT_WRAP" \
        | sed -e 's/[[:space:]]*$//' -e 's/^/  /'
}

# Render an hour count as the coarsest unit that still reads at a glance.
humanize_age() {
    local h="$1"
    if [[ ! "$h" =~ ^[0-9]+$ ]]; then
        printf 'unknown'
    elif [[ "$h" -lt 48 ]]; then
        printf '%sh ago' "$h"
    else
        printf '%sd ago' "$((h / 24))"
    fi
}

total=0
failed_runs=0
missed=0
ran_days=0
missed_days=""
latest_fleet=""
raw_findings=""

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
        if [[ ! -e "$run/findings.tsv" ]]; then
            failed_runs=$((failed_runs + 1))
            raw_findings+="$day_h	FAIL	-	INCOMPLETE_RUN	-	no findings recorded (check crashed?)"$'\n'
        elif grep -q '^FAIL' "$run/findings.tsv" 2>/dev/null; then
            failed_runs=$((failed_runs + 1))
        fi
        # Stamp each finding with its day so repeats collapse to a date range.
        while IFS= read -r line; do
            [[ -n "$line" ]] && raw_findings+="$day_h	$line"$'\n'
        done < "$run/findings.tsv" 2>/dev/null
        [[ -s "$run/fleet.json" ]] && latest_fleet="$run/fleet.json"
    done
done

# Collapse identical findings across runs to one row: same host+code+key seen
# nine times is one fact, not nine lines. Legacy runs wrote 4-field findings
# (no key column); treat their missing key as "-" rather than dropping them.
dedup="$(awk -F'\t' '
    {
        day = $1; st = $2; host = $3; code = $4
        if (NF >= 6) { key = $5; det = $6 } else { key = "-"; det = $5 }
        # Legacy runs wrote no key column. Recover the destination from the
        # detail prefix ("/phobos/data: 23GB free ...") before building the
        # dedup key, or two destinations on one host collapse into one row.
        if (key == "-" && det ~ /^\//) { split(det, p, ":"); key = p[1] }
        k = st SUBSEP host SUBSEP code SUBSEP key
        if (!(k in cnt)) { first[k] = day; order[++n] = k }
        cnt[k]++
        last[k] = day; detail[k] = det
        stt[k] = st; hh[k] = host; cc[k] = code; kk[k] = key
    }
    END {
        for (i = 1; i <= n; i++) {
            k = order[i]
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
                stt[k], hh[k], cc[k], kk[k], cnt[k], first[k], last[k], detail[k]
        }
    }' <<< "$raw_findings")"

actions=""
action_count=0
known=""
failing_hosts=" "
fail_tsv=""
while IFS=$'\t' read -r st host code key cnt first last detail; do
    [[ -z "$st" ]] && continue
    case "$st" in
        FAIL)
            action_count=$((action_count + 1))
            failing_hosts+="$host "
            fail_tsv+="$host	$code	$key	$detail"$'\n'
            if [[ "$action_count" -le "$MAX_ACTIONS" ]]; then
                seen=""
                if [[ "$cnt" -gt 1 && "$first" == "$last" ]]; then
                    seen="  [$cnt checks on $first]"
                elif [[ "$cnt" -gt 1 ]]; then
                    seen="  [$cnt checks, $first to $last]"
                fi
                desc="$(action_desc "$host" "$code" "$key" "$detail")"
                actions+="$(printf '  %d. %s%s' "$action_count" "$desc" "$seen")"$'\n'
                [[ -n "$ACTION_CMD" ]] && actions+="       $ACTION_CMD"$'\n'
            fi
            ;;
        INFO|ACK)
            known+="  $(known_desc "$host" "$code" "$detail")"$'\n'
            ;;
    esac
done <<< "$dedup"

if [[ "$missed" -gt 0 ]]; then
    action_count=$((action_count + 1))
    if [[ "$action_count" -le "$MAX_ACTIONS" ]]; then
        actions+="$(printf '  %d. No check ran on %s' "$action_count" "$missed_days")"$'\n'
        actions+="       ssh quintana 'crontab -l | grep backup-kit'"$'\n'
    fi
fi
if [[ "$action_count" -gt "$MAX_ACTIONS" ]]; then
    actions+="  ... and $((action_count - MAX_ACTIONS)) more (see artifacts below)"$'\n'
fi

# Host table, worst first: anything with a failing finding sorts to the top so
# the eye lands on it without reading the whole block.
hosts_table="  (no fleet snapshot in the window)"
if [[ -n "$latest_fleet" ]]; then
    rows=""
    while IFS=$'\t' read -r name age pending status; do
        [[ -z "$name" ]] && continue
        mark=" "
        [[ "$failing_hosts" == *" $name "* ]] && mark="!"
        sort_key=1
        [[ "$mark" == "!" ]] && sort_key=0
        rows+="$(printf '%d\t%s %-8s %13s %9s' "$sort_key" "$mark" "$name" \
            "$(humanize_age "$age")" "$pending")"$'\n'
    done < <(jq -r '.hosts[]
        | [ (.fleet_host // .host // "?"),
            (.last_run.age_hours // "?" | tostring),
            ([.jobs[]?.pending_files] | add // 0 | tostring),
            (.overall_status // "?") ]
        | @tsv' "$latest_fleet" 2>/dev/null)
    if [[ -n "$rows" ]]; then
        # grep -v '^$' drops the empty trailing field the here-string adds;
        # without it an empty line sorts to the top of the table.
        hosts_table="$(grep -v '^$' <<< "$rows" | sort -k1,1n | cut -f2-)"
    fi
fi

if [[ "$action_count" -eq 0 ]]; then
    subject="Backups OK — nothing to do"
    headline="NOTHING TO DO."
else
    short="$(tr ' ' '\n' <<< "$failing_hosts" | grep -v '^$' | sort -u \
        | head -3 | paste -sd, - | sed 's/,/, /g')"
    noun="things need"
    [[ "$action_count" -eq 1 ]] && noun="thing needs"
    subject="Backups: $action_count $noun you — ${short:-no check ran}"
    headline="DO THIS ($action_count):
$actions"
fi

checks_line="$ran_days of $days days ran, $total checks, $failed_runs failed."
[[ "$missed" -gt 0 ]] && checks_line+=" No check on: $missed_days."

context=""
if [[ "$want_context" -eq 1 && "$action_count" -gt 0 && -n "$latest_fleet" ]]; then
    # Per-destination sizes matter: hosts share mount NAMES (/phobos, /deimos)
    # while pointing at different volumes, and without the totals the model
    # infers a shared pool that does not exist.
    fleet_lines="$(jq -r '.hosts[]
        | (.fleet_host // .host // "?") as $h
        | "\($h): \(.overall_status // "?"), last run \(.last_run.age_hours // "?")h ago, \([.jobs[]?.pending_files] | add // 0) files pending",
          (.jobs[]? | "    \($h) \(.dest): \(.dest_avail_human // "?") free of \(((.dest_total_kb // 0) / 1048576 | floor))GB total, \(.dest_used_pct // "?") used")
        ' "$latest_fleet" 2>/dev/null)"
    context="$(claude_context "$fail_tsv" "$fleet_lines")"
fi

# The failure headline ends with the action list's trailing newline; the
# all-clear headline is a single line, so add one to keep the same gap.
[[ "$action_count" -eq 0 ]] && headline+=$'\n'

# Prose first, tables second. The summary is what gets read; the host table
# and counts are there to check it against, not to be waded through.
body=""
[[ -n "$context" ]] && body+="$context"$'\n\n'

body+="$headline
$(printf '  %-8s %13s %9s' "HOST" "last backup" "waiting")
$hosts_table
"
[[ -n "$known" ]] && body+="
KNOWN, NOT ACTIONABLE
$known"
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
