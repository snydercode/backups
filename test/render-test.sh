#!/usr/bin/env bash
# render-test.sh — prove the shared email renderer stays readable.
#
# bin/check.sh (daily, on failure) and bin/report.sh (weekly, always) share
# lib/render.sh so the two mails cannot drift into two formats. The properties
# below are the ones that make an alarm get read: the action comes first, the
# list is capped, the failing host sorts to the top of the table, and no amount
# of model output can push any of that off the screen.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$REPO_DIR/lib/render.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

pass_count=0
fail_count=0

ok() { pass_count=$((pass_count + 1)); printf 'ok    %s\n' "$1"; }
nope() {
    fail_count=$((fail_count + 1))
    printf 'FAIL  %s\n' "$1"
    [[ $# -gt 1 ]] && printf '        %s\n' "$2"
}

# Args: <name> <haystack> <needle>
contains() {
    if [[ "$2" == *"$3"* ]]; then ok "$1"; else nope "$1" "missing: $3"; fi
}
lacks() {
    if [[ "$2" != *"$3"* ]]; then ok "$1"; else nope "$1" "present: $3"; fi
}
equals() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else nope "$1" "got '$2', wanted '$3'"; fi
}

tsv() { printf '%b' "$1"; }

# --- the action list ---

one="ephys3\tDISCONNECTED\t-\tkex_exchange_identification: Connection closed\n"

equals "one finding counts as one action" \
    "$(render_action_count <<< "$(tsv "$one")")" "1"

actions="$(render_actions <<< "$(tsv "$one")")"
contains "the action is numbered" "$actions" "1. ephys3"
contains "DISCONNECTED reads as plain English" "$actions" "unreachable over SSH"
contains "the action carries ssh's reason" "$actions" "kex_exchange_identification"

# A finding with a fix command must print the command, because "knowing the
# answer is not doing the answer" — the reader should not have to compose it.
stale="setup3\tSTALE_RUN\t-\tlast run 49h ago\n"
contains "a fixable finding prints its command" \
    "$(render_actions <<< "$(tsv "$stale")")" "bash bin/schedule.sh setup3"

# --- the cap ---

many=""
for h in a b c d e f g; do
    many+="host$h\tNEVER_RUN\t-\tbackup has never executed\n"
done
capped="$(render_actions <<< "$(tsv "$many")")"

equals "all seven are counted" "$(render_action_count <<< "$(tsv "$many")")" "7"
equals "only five are printed" "$(grep -c '^  [0-9]\. ' <<< "$capped")" "5"
contains "the remainder is announced, not dropped silently" "$capped" \
    "and 2 more"
lacks "the sixth action is folded away" "$capped" "6. hostf"

# --- fleet-level findings must never be handed a per-host command ---

fleet="-\tCONFIG_MISMATCH\t-\thost count 4, expected 5\n"
fleet_actions="$(render_actions <<< "$(tsv "$fleet")")"
contains "a fleet-level finding still renders" "$fleet_actions" "Fleet config drift"
lacks "a fleet-level finding gets no deploy command" "$fleet_actions" "bin/deploy.sh -"
equals "a fleet-level finding names no host" \
    "$(render_failing_hosts <<< "$(tsv "$fleet")")" " "

# --- the host table ---

cat > "$WORK_DIR/fleet.json" <<'JSON'
{"hosts":[
 {"fleet_host":"setup2","last_run":{"age_hours":11},"jobs":[{"pending_files":0}]},
 {"fleet_host":"ephys3","last_run":{"age_hours":"?"},"jobs":[]},
 {"fleet_host":"setup7","last_run":{"age_hours":100},"jobs":[{"pending_files":4}]}
]}
JSON

table="$(render_host_table "$WORK_DIR/fleet.json" " ephys3 ")"
equals "the failing host sorts to the top" \
    "$(head -1 <<< "$table" | awk '{print $2}')" "ephys3"
contains "the failing host is marked" "$table" "! ephys3"
contains "an unknown age reads as unknown, not as a number" "$table" "unknown"
contains "an age over two days reads in days" "$table" "4d ago"
contains "a recent age reads in hours" "$table" "11h ago"

equals "a missing fleet snapshot does not crash the table" \
    "$(render_host_table "$WORK_DIR/nope.json" " ")" "  (no fleet snapshot)"

# --- the subject line ---

equals "the subject names the host, for the phone notification" \
    "$(render_subject 1 " ephys3 ")" "Backups: 1 thing needs you — ephys3"
equals "the subject pluralises" \
    "$(render_subject 2 " ephys3 setup7 ")" "Backups: 2 things need you — ephys3, setup7"
equals "no actions means nothing to do" \
    "$(render_subject 0 " ")" "Backups OK — nothing to do"
equals "a fleet-level failure falls back to a phrase, not an empty dash" \
    "$(render_subject 1 " " "check did not run")" \
    "Backups: 1 thing needs you — check did not run"

# --- model commentary can never bury the action list ---

flood="$(printf 'x%.0s' {1..40000})"
clamped="$(printf '%s\n' "$flood" | render_clamp_note 6 200 2000)"
if [[ "${#clamped}" -le 2000 ]]; then
    ok "a 40KB single line is clamped by bytes, not just by line count"
else
    nope "a 40KB single line is clamped by bytes, not just by line count" \
        "got ${#clamped} chars"
fi

wrapped="$(printf '%s' "$clamped" | render_wrap_note 72)"
if [[ "$(awk '{ if (length($0) > 74) n++ } END { print n + 0 }' <<< "$wrapped")" == "0" ]]; then
    ok "wrapped commentary stays inside the wrap width"
else
    nope "wrapped commentary stays inside the wrap width"
fi

many_lines="$(printf 'line %s\n' {1..50} | render_clamp_note 6 200 2000)"
equals "commentary is clamped to six lines" "$(wc -l <<< "$many_lines")" "6"

blank_stripped="$(printf 'one\n\n\ntwo\n' | render_clamp_note 6 200 2000)"
equals "blank lines do not eat the line budget" "$blank_stripped" "one
two"

echo
echo "passed $pass_count, failed $fail_count"
[[ "$fail_count" -eq 0 ]]
