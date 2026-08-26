#!/usr/bin/env bash
# prompt-test.sh — prove the FAIL-path triage prompt survives the shell parser.
#
# The prompt is a long literal that quotes shell and PowerShell commands at the
# triage agent. On 2026-08-25 one unescaped double quote inside it ended the
# assignment early: bash ran the remainder as a command, the agent was invoked
# with an empty prompt, and the email carried raw findings instead of a
# diagnosis. Only a real fleet failure runs that path, so six days of green
# checks said nothing about it.
#
# This test lifts the assignment out of bin/check.sh, evaluates it with stub
# inputs, and asserts the prompt arrived whole — head, tail, embedded quotes,
# and every interpolated value.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CHECK="$REPO_DIR/bin/check.sh"

pass_count=0
fail_count=0

ok() {
    pass_count=$((pass_count + 1))
    printf 'ok    %s\n' "$1"
}

nope() {
    fail_count=$((fail_count + 1))
    printf 'FAIL  %s\n' "$1"
    [[ $# -gt 1 ]] && printf '        %s\n' "$2"
}

# Args: <name> <haystack> <needle>
contains() {
    if [[ "$2" == *"$3"* ]]; then
        ok "$1"
    else
        nope "$1" "missing: $3"
    fi
}

# Args: <name> <haystack> <needle>
lacks() {
    if [[ "$2" != *"$3"* ]]; then
        ok "$1"
    else
        nope "$1" "unexpectedly present: $3"
    fi
}

# --- the script still parses at all ---

if bash -n "$CHECK" 2>/dev/null; then
    ok "bin/check.sh parses"
else
    nope "bin/check.sh parses" "$(bash -n "$CHECK" 2>&1 | head -1)"
fi

# --- lift the assignment out of the real source ---
#
# Bounded by the two surrounding statements rather than by the heredoc markers,
# so the test does not care how the prompt is written — only that whatever is
# written produces the whole prompt. Rewrite it as a quoted string tomorrow and
# these assertions still hold you to it.

block="$(awk '
    index($0, "report=") == 1 { exit }
    index($0, "triage_prompt=") == 1 { inblock = 1 }
    inblock { print }
' "$CHECK")"

if [[ -z "$block" ]]; then
    nope "found the triage_prompt assignment" "no triage_prompt= line in bin/check.sh"
    echo
    echo "passed $pass_count, failed $fail_count"
    exit 1
fi
ok "found the triage_prompt assignment"

# Args: <info_lines value>. Echoes the built prompt; empty if the build broke.
build() {
    (
        set -u
        REPO_DIR="/stub/repo"
        run_dir="/stub/run"
        fail_lines=$'FAIL\tephys3\tSTATUS_ERROR\t-\tstub failure detail'
        info_lines="$1"
        eval "$block"
        printf '%s' "$triage_prompt"
    ) 2>/dev/null
}

prompt="$(build $'INFO\tephys7\tJOB_DISABLED\t/mnt/f/data\tstub informational detail')"

if [[ -n "$prompt" ]]; then
    ok "the prompt builds"
else
    nope "the prompt builds" "built empty — the assignment broke before it finished"
fi

# The head and tail together are the real assertion: a literal that terminates
# early keeps its opening and loses everything after the stray quote.
contains "keeps its opening line" "$prompt" \
    "You are the automated FAIL path of the daily backup health check"
contains "keeps its closing line" "$prompt" \
    "Fix. No preamble, no code fences."

# The two lines that carry embedded quotes. They must reach the agent as real
# quotes: bare in the PowerShell example, and bare inside the single-quoted
# ssh-ro example too.
contains "PowerShell example keeps its quotes" "$prompt" \
    '-Command "Get-Content ..." or "Get-ScheduledTaskInfo ..."'
contains "WSL example keeps its quotes" "$prompt" \
    $'bash bin/ssh-ro.sh <host> \'wsl.exe -e bash -lc "<command>"\''
lacks "no backslash-escaped quotes leak through" "$prompt" '\"'

# Every value the prompt interpolates.
contains "interpolates REPO_DIR" "$prompt" "/stub/repo (the backup-kit repo)"
contains "interpolates run_dir" "$prompt" "/stub/run/fleet.json"
contains "interpolates fail_lines" "$prompt" "stub failure detail"
contains "interpolates info_lines" "$prompt" "stub informational detail"
contains "labels the informational block" "$prompt" \
    "Also present, informational only"

# With nothing informational the block must vanish, not render an empty header.
bare="$(build "")"
contains "still builds with no informational findings" "$bare" \
    "Fix. No preamble, no code fences."
lacks "omits the informational block when empty" "$bare" \
    "Also present, informational only"

echo
echo "passed $pass_count, failed $fail_count"
[[ "$fail_count" -eq 0 ]]
