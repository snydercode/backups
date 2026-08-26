#!/usr/bin/env bash
# status-schema-test.sh — prove a host that never answered ssh is reported as
# unreachable, and that a host which did answer is not.
#
# This is the classification ephys3 got wrong for two days. It was a Windows
# host, so collection probed for its backup runtime before anything else; the
# probe discarded ssh's stderr, so the only evidence left was "the probe did not
# answer". That became STATUS_ERROR — "could not determine the backup runtime" —
# when the machine was simply switched off. The gate has always had DISCONNECTED
# for this and the weekly report has always rendered it as "unreachable over
# SSH"; neither ever fired, because the classification upstream never said so.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$REPO_DIR/lib/status_schema.sh"

pass_count=0
fail_count=0

# What ephys3 actually produced, through the ProxyJump, on 2026-08-26.
PROXY_FAILURE='channel 0: open failed: administratively prohibited: open failed
stdio forwarding failed
kex_exchange_identification: Connection closed by remote host'

# Args: <name> <rc> <output> <want_overall> <want_err_type> [want_message]
check() {
    local name="$1" rc="$2" output="$3" want_overall="$4" want_type="$5"
    local want_message="${6:-}"

    local json overall err_type message problems=""
    json="$(status_error_json "testhost" "$output" "$rc")"

    if ! jq -e . >/dev/null 2>&1 <<< "$json"; then
        printf 'FAIL  %s\n        emitted invalid JSON: %s\n' "$name" "$json"
        fail_count=$((fail_count + 1))
        return
    fi

    overall="$(jq -r '.overall_status' <<< "$json")"
    err_type="$(jq -r '.errors[0].type' <<< "$json")"
    message="$(jq -r '.errors[0].message' <<< "$json")"

    [[ "$overall" == "$want_overall" ]] \
        || problems+="  overall_status $overall, wanted $want_overall"$'\n'
    [[ "$err_type" == "$want_type" ]] \
        || problems+="  errors[0].type $err_type, wanted $want_type"$'\n'
    if [[ -n "$want_message" && "$message" != *"$want_message"* ]]; then
        problems+="  message '$message' does not contain '$want_message'"$'\n'
    fi

    if [[ -z "$problems" ]]; then
        pass_count=$((pass_count + 1))
        printf 'ok    %s\n' "$name"
    else
        fail_count=$((fail_count + 1))
        printf 'FAIL  %s\n%s' "$name" "$problems"
    fi
}

# --- the exit code is authoritative ---

check "status.sh exit 3 means unreachable" \
    3 "ERROR: ssh to ephys3 failed, so the host is unreachable: kex_exchange_identification: Connection closed by remote host
$PROXY_FAILURE" \
    UNREACHABLE ssh_failed "kex_exchange_identification"

# The regression that started this: a Windows host whose runtime probe failed
# because ssh never connected. Exit 3 must win over wording that says nothing
# about ssh at all.
check "exit 3 wins over text that mentions no ssh error" \
    3 "ERROR: ssh to ephys3 failed, so the host is unreachable: no diagnostic output from ssh" \
    UNREACHABLE ssh_failed

# --- and a host that DID answer must not be swept in with it ---

check "a reachable host whose runtime probe failed stays an ERROR" \
    1 "ERROR: could not determine the backup runtime on ephys3
       (ephys3 answered ssh; the schtasks query for BackupKit failed)" \
    ERROR command_failed "could not determine the backup runtime"

check "a non-JSON payload from a reachable host stays an ERROR" \
    1 "NON_JSON_RAW_PAYLOAD: invalid raw payload from host" \
    ERROR raw_payload_not_json "invalid raw payload"

# --- text fallback, for callers with no exit code to offer ---

check "proxy-jump failure is recognized from text alone" \
    "" "$PROXY_FAILURE" UNREACHABLE ssh_failed

check "classic ssh failures are still recognized from text alone" \
    "" "ssh: connect to host setup3 port 1840: Connection timed out" \
    UNREACHABLE ssh_failed

check "an unresolvable name is recognized from text alone" \
    "" "ssh: Could not resolve hostname oephys3.dhcp.wustl.edu: Name or service not known" \
    UNREACHABLE ssh_failed

check "an ordinary remote failure is not mistaken for an ssh failure" \
    "" "bash: /home/toor/backup-kit/backup.sh: No such file or directory" \
    ERROR command_failed

# --- the detail that reaches the email and the weekly report ---
#
# The gate copies errors[0].message straight into the DISCONNECTED finding, so
# this string is what lands in front of a human. It has to be ssh's own last
# line, not bin/status.sh's summary line above it and not the "channel 0: open
# failed" noise below it, and it must not stutter "ERROR:" at a FAIL row.

detail="$(status_error_json "ephys3" \
    "ERROR: ssh to ephys3 failed, so the host is unreachable: kex_exchange_identification: Connection closed by remote host
$PROXY_FAILURE" 3 | jq -r '.errors[0].message')"

if [[ "$detail" == "kex_exchange_identification: Connection closed by remote host" ]]; then
    pass_count=$((pass_count + 1))
    echo "ok    the finding detail is ssh's own reason, verbatim"
else
    fail_count=$((fail_count + 1))
    printf "FAIL  the finding detail is ssh's own reason, verbatim\n        got: %s\n" "$detail"
fi

# A Windows host answers with CRLF, and findings are tab-separated. Neither may
# reach the field: a stray tab ends it early, a stray CR trails through the email.
crlf_detail="$(status_error_json "ephys3" \
    "$(printf 'ERROR: ssh to ephys3 failed\r\nkex_exchange_identification:\tConnection closed by remote host\r\n')" \
    3 | jq -r '.errors[0].message')"

if [[ "$crlf_detail" == "kex_exchange_identification: Connection closed by remote host" ]]; then
    pass_count=$((pass_count + 1))
    echo "ok    CRLF and tabs are stripped out of the finding detail"
else
    fail_count=$((fail_count + 1))
    printf "FAIL  CRLF and tabs are stripped out of the finding detail\n        got: %q\n" "$crlf_detail"
fi

# --- the predicate itself ---

if status_is_unreachable "$STATUS_EXIT_UNREACHABLE" ""; then
    pass_count=$((pass_count + 1))
    echo "ok    status_is_unreachable accepts the exit code with no text"
else
    fail_count=$((fail_count + 1))
    echo "FAIL  status_is_unreachable accepts the exit code with no text"
fi

if status_is_unreachable "" "everything is fine here"; then
    fail_count=$((fail_count + 1))
    echo "FAIL  status_is_unreachable stays quiet on unremarkable text"
else
    pass_count=$((pass_count + 1))
    echo "ok    status_is_unreachable stays quiet on unremarkable text"
fi

echo
echo "passed $pass_count, failed $fail_count"
[[ "$fail_count" -eq 0 ]]
