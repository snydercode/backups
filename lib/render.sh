#!/usr/bin/env bash

# Shared email rendering for bin/check.sh (daily, on failure) and bin/report.sh
# (weekly, always). Both mails answer the same question — what do I have to do
# about the backups — so they are one format in one place, not two that drift.
#
# The shape is deliberate and it is the whole point: the action comes first, it
# is numbered, it is capped, and the tables under it are there to check the
# action against rather than to be read through. A report that takes effort to
# read stops being read, and an alarm that stops being read is not an alarm.
#
# Everything here is computed from the gate's findings in bash. No model output
# reaches these functions. A model may annotate the result underneath; it may
# never write the verdict or the action list.

# Actions shown before the fold, before "+N more". Five is the readable cap.
RENDER_MAX_ACTIONS=5

# Fleet-level findings arrive with host "-" (lib/gate.sh CONFIG_MISMATCH,
# bin/check.sh RUNNER_FAILURE, and INCOMPLETE_RUN). Those must never reach a
# per-host command: "bash bin/deploy.sh -" is a mutating invocation handed to
# the reader as if it were the fix.
#
# Prints two tab-separated fields: the description, and the command that fixes
# this finding (empty when there is not one worth printing). Returning the
# command rather than setting a global is not a style choice — every caller
# wants the description inside "$(...)", and a global assigned in that subshell
# is discarded on the way out. That is how the fix commands went missing from
# the weekly report from the day it was written until 2026-08-26.
action_desc() {
    local ACTION_CMD=""
    _action_desc_body "$@"
    printf '%s%s' "	" "$ACTION_CMD"
}

_action_desc_body() {
    local host="$1" code="$2" key="$3" detail="$4"
    # Legacy 4-field findings carry no key column; recover the destination
    # from the detail prefix ("/phobos/data: 23GB free ...").
    local dest="$key"
    [[ "$dest" == "-" || -z "$dest" ]] && dest="${detail%%:*}"
    ACTION_CMD=""
    case "$code" in
        DISK_LOW)
            # FIXME: strips lib/gate.sh's exact DISK_LOW and STALE_IDLE wording, and no test
            # pins it. Add a render test fed real gate_evaluate output.
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
            # Lead with ssh's own reason rather than a guess at the cause.
            # "Powered off", "the name stopped resolving" and "the key was
            # rejected" all land here and need different things done about
            # them, so naming one of them here would be wrong most times it
            # mattered. The command re-tests once the reader has acted.
            ACTION_CMD="bash bin/status.sh $host"
            printf '%s — unreachable over SSH: %s' "$host" "$detail"
            ;;
        JOB_ERROR)
            printf '%s — %s is not readable (mount gone?)' "$host" "$dest"
            ;;
        MISSING_HOST|MISSING_JOB|CONFIG_MISMATCH)
            if [[ "$host" == "-" ]]; then
                printf 'Fleet config drift — %s' "$detail"
            else
                ACTION_CMD="bash bin/deploy.sh $host"
                printf '%s — config drift' "$host"
            fi
            ;;
        RUNNER_FAILURE|INCOMPLETE_RUN)
            printf 'The check itself broke — %s' "$detail"
            ;;
        NO_CHECK)
            # Not a gate finding. bin/report.sh synthesises it when a day in the
            # window has no run at all, which outranks anything a run found.
            ACTION_CMD="ssh quintana 'crontab -l | grep backup-kit'"
            printf 'No check ran on %s' "$detail"
            ;;
        # FIXME: STATUS_ERROR, UNRECOGNIZED_STATUS, UNRECOGNIZED_JOB_STATUS, DISK_UNKNOWN
        # and MALFORMED_FIELD land here as raw codes; give each an arm.
        *)
            if [[ "$host" == "-" ]]; then
                printf '%s: %s' "$code" "$detail"
            else
                printf '%s — %s: %s' "$host" "$code" "$detail"
            fi
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

# Model-written commentary is allowed under the action list, never above it and
# never instead of it. These two fit it into something that cannot bury what it
# annotates. Bounded by BYTES as well as lines: head -n alone lets a single 40KB
# line through, and the wrap then expands it to hundreds of display lines.
#
# Args: <max lines> <max cols> <max bytes>. Text on stdin. Clamp first, so the
# caller can test the result for empty before deciding to print a heading.
render_clamp_note() {
    grep -v '^[[:space:]]*$' | cut -c1-"$2" | head -n "$1" | head -c "$3"
}

# Args: <wrap width>. Text on stdin. Wraps and indents to sit under a heading.
render_wrap_note() {
    # fold -s breaks on spaces and leaves them dangling at end of line.
    fold -s -w "$1" | sed -e 's/[[:space:]]*$//' -e 's/^/  /'
}

# The next three read FAIL findings as TSV on stdin: host, code, key, detail.
# Three passes over at most a handful of lines, rather than one pass setting
# globals: every caller wants the result inside "$(...)", and a subshell throws
# globals away. The cost is nothing and the trap is real.

# Count of actions, before the MAX_ACTIONS fold.
render_action_count() {
    local host rest n=0
    while IFS=$'\t' read -r host rest; do
        [[ -z "$host" ]] && continue
        n=$((n + 1))
    done
    printf '%s' "$n"
}

# Space-padded list of the hosts with a failing finding, for table marking.
# Fleet-level findings (host "-") name no host and are skipped.
render_failing_hosts() {
    local host rest out=" "
    while IFS=$'\t' read -r host rest; do
        [[ -z "$host" || "$host" == "-" ]] && continue
        [[ "$out" == *" $host "* ]] && continue
        out+="$host "
    done
    printf '%s' "$out"
}

# The numbered action list, folded at RENDER_MAX_ACTIONS.
render_actions() {
    local host code key detail rendered desc cmd idx
    local -a items=()
    while IFS=$'\t' read -r host code key detail; do
        [[ -z "$host" ]] && continue
        rendered="$(action_desc "$host" "$code" "$key" "$detail")"
        desc="${rendered%%$'\t'*}"
        cmd="${rendered#*$'\t'}"
        # The command goes on its own line under the description, indented past
        # the number, so it can be copied without picking up the prose.
        items+=("$desc${cmd:+$'\n'"       $cmd"}")
    done
    for idx in "${!items[@]}"; do
        [[ "$idx" -ge "$RENDER_MAX_ACTIONS" ]] && break
        printf '  %d. %s\n' "$((idx + 1))" "${items[idx]}"
    done
    if [[ "${#items[@]}" -gt "$RENDER_MAX_ACTIONS" ]]; then
        printf '  ... and %d more (see artifacts below)\n' \
            "$((${#items[@]} - RENDER_MAX_ACTIONS))"
    fi
}

# Column header for the host table.
render_host_header() {
    printf '  %-8s %13s %9s' "HOST" "last backup" "waiting"
}

# Args: <fleet.json path> <failing hosts, from render_failing_hosts>
# Worst first: anything with a failing finding sorts to the top, so the eye
# lands on it without reading the whole block.
render_host_table() {
    local fleet="$1" failing="$2"
    local rows="" name age pending mark sort_key

    if [[ -z "$fleet" || ! -s "$fleet" ]]; then
        printf '  (no fleet snapshot)'
        return
    fi

    while IFS=$'\t' read -r name age pending; do
        [[ -z "$name" ]] && continue
        mark=" "
        sort_key=1
        if [[ "$failing" == *" $name "* ]]; then
            mark="!"
            sort_key=0
        fi
        rows+="$(printf '%d\t%s %-8s %13s %9s' "$sort_key" "$mark" "$name" \
            "$(humanize_age "$age")" "$pending")"$'\n'
    done < <(jq -r '.hosts[]
        | [ (.fleet_host // .host // "?"),
            (.last_run.age_hours // "?" | tostring),
            ([.jobs[]?.pending_files] | add // 0 | tostring) ]
        | @tsv' "$fleet" 2>/dev/null)

    if [[ -z "$rows" ]]; then
        printf '  (could not parse %s)' "$fleet"
        return
    fi
    # grep -v '^$' drops the empty trailing field the here-string adds;
    # without it an empty line sorts to the top of the table.
    grep -v '^$' <<< "$rows" | sort -k1,1n | cut -f2-
}

# Args: <action count> <failing hosts> [fleet-level fallback phrase]
# Names the hosts in the subject line, so the phone notification alone says
# which machine to walk to.
render_subject() {
    local count="$1" failing="$2" fallback="${3:-fleet-level}"
    local short noun

    if [[ "$count" -eq 0 ]]; then
        printf 'Backups OK — nothing to do'
        return
    fi

    short="$(tr ' ' '\n' <<< "$failing" | grep -v '^$' | sort -u \
        | head -3 | paste -sd, - | sed 's/,/, /g')"
    noun="things need"
    [[ "$count" -eq 1 ]] && noun="thing needs"
    [[ -z "$short" ]] && short="$fallback"
    printf 'Backups: %s %s you — %s' "$count" "$noun" "$short"
}
