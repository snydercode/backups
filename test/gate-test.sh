#!/usr/bin/env bash
# gate-test.sh — prove every named error condition trips the health-check gate.
#
# Each case takes the healthy fixture (captured from the real fleet), breaks it
# the way the real failure would, and asserts the gate emits the expected
# finding code with the expected exit code. The healthy and pending cases prove
# the gate stays quiet when it should.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$REPO_DIR/lib/jobs.sh"
source "$REPO_DIR/lib/gate.sh"

JOBS_FILE="$REPO_DIR/jobs.txt"
HEALTHY="$SCRIPT_DIR/fixtures/healthy.json"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

pass_count=0
fail_count=0

mutate() {
    jq -c "$1" "$HEALTHY"
}

# Args: <output> <status FAIL|ACK|INFO> <code>
has_finding() {
    awk -F'\t' -v s="$2" -v c="$3" '$1 == s && $3 == c { found = 1 } END { exit !found }' <<< "$1"
}

# Args: <name> <input> <want_rc> [want_code ...] — want_code as STATUS:CODE.
# Prefix a want_code with ! to assert its absence.
check() {
    local name="$1" input="$2" want_rc="$3"
    shift 3

    local out rc
    out="$(gate_evaluate "$JOBS_FILE" "${GATE_TEST_HOST_COUNT:-5}" "${GATE_TEST_ACK_FILE:-}" <<< "$input")"
    rc=$?

    local problems=""
    [[ "$rc" -eq "$want_rc" ]] || problems+="  exit $rc, wanted $want_rc"$'\n'

    local spec status code
    for spec in "$@"; do
        if [[ "$spec" == "NO_FAILURES" ]]; then
            if grep -q '^FAIL' <<< "$out"; then
                problems+="  unexpected FAIL findings present"$'\n'
            fi
            continue
        fi
        local negate=0
        [[ "$spec" == !* ]] && { negate=1; spec="${spec#!}"; }
        status="${spec%%:*}"
        code="${spec#*:}"
        if has_finding "$out" "$status" "$code"; then
            [[ "$negate" -eq 1 ]] && problems+="  unwanted $status $code present"$'\n'
        else
            [[ "$negate" -eq 0 ]] && problems+="  missing $status $code"$'\n'
        fi
    done

    if [[ -z "$problems" ]]; then
        echo "ok       $name"
        pass_count=$((pass_count + 1))
    else
        echo "NOT OK   $name"
        printf '%s' "$problems"
        sed 's/^/    | /' <<< "$out"
        fail_count=$((fail_count + 1))
    fi
}

unreachable_entry='{schema_version:1,host:"HOST",fleet_host:"HOST",reachable:false,
    overall_status:"UNREACHABLE",
    last_run:{date:"unknown",age_hours:-1,result:null,status:"UNKNOWN"},
    jobs:[],errors:[{type:"ssh_failed",message:"ssh: connect to host HOST port 1840: Connection timed out"}]}'
remote_error_entry='{schema_version:1,host:"HOST",fleet_host:"HOST",reachable:false,
    overall_status:"ERROR",
    last_run:{date:"unknown",age_hours:-1,result:null,status:"UNKNOWN"},
    jobs:[],errors:[{type:"command_failed",message:"bash: /home/toor/backup-kit/backup.sh: No such file or directory"}]}'

check "healthy fleet passes" \
    "$(cat "$HEALTHY")" 0 NO_FAILURES

check "pending files with recent run pass" \
    "$(mutate '.hosts[2].jobs[0].status = "PENDING" | .hosts[2].jobs[0].pending_files = 12')" \
    0 NO_FAILURES

check "unreachable host (disconnection)" \
    "$(mutate ".hosts[3] = ${unreachable_entry//HOST/setup3}")" \
    1 FAIL:DISCONNECTED "!FAIL:MISSING_JOB" "!FAIL:STALE_RUN"

check "host missing from output" \
    "$(mutate 'del(.hosts[4])')" 1 FAIL:MISSING_HOST

check "last run failed" \
    "$(mutate '.hosts[0].overall_status = "FAILED" | .hosts[0].last_run.result = 23 | .hosts[0].last_run.status = "FAILED"')" \
    1 FAIL:FAILED_RUN

check "stale run with pending files fails" \
    "$(mutate '.hosts[2].last_run.age_hours = 49
               | .hosts[2].jobs[0] |= (.status = "PENDING" | .pending_files = 3 | .pending_bytes = 9000000)')" \
    1 FAIL:STALE_RUN "!INFO:STALE_IDLE"

check "stale but provably idle downgrades to informational" \
    "$(mutate '.hosts[2].last_run.age_hours = 49')" \
    0 INFO:STALE_IDLE "!FAIL:STALE_RUN" NO_FAILURES

check "stale with pending unprovable fails closed (field missing)" \
    "$(mutate '.hosts[2].last_run.age_hours = 49 | del(.hosts[2].jobs[0].pending_files)')" \
    1 FAIL:STALE_RUN "!INFO:STALE_IDLE"

check "stale with unknown age fails closed" \
    "$(mutate '.hosts[2].last_run.age_hours = -1')" \
    1 FAIL:STALE_RUN "!INFO:STALE_IDLE"

check "stale with missing pending_bytes fails closed" \
    "$(mutate '.hosts[2].last_run.age_hours = 49 | del(.hosts[2].jobs[].pending_bytes)')" \
    1 FAIL:STALE_RUN "!INFO:STALE_IDLE"

check "stale with stringified age fails closed" \
    "$(mutate '.hosts[2].last_run.age_hours = "49"')" \
    1 FAIL:STALE_RUN "!INFO:STALE_IDLE"

# A broken or empty source reports src_last_file_epoch=-1 while the rsync
# dry-run parse defaults pending to 0 — that must not count as proof of idleness.
check "stale with unreadable source is not idle" \
    "$(mutate '.hosts[2].last_run.age_hours = 49 | .hosts[2].jobs[].src_last_file_epoch = -1')" \
    1 FAIL:STALE_RUN "!INFO:STALE_IDLE"

check "stale with missing src evidence fails closed" \
    "$(mutate '.hosts[2].last_run.age_hours = 49 | del(.hosts[2].jobs[].src_last_file_epoch)')" \
    1 FAIL:STALE_RUN "!INFO:STALE_IDLE"

# An ERROR job reports default-zero pending counters ("dry-run never ran"),
# which must not count as proof of idleness.
check "stale with ERROR job is not idle" \
    "$(mutate '.hosts[2].last_run.age_hours = 49
               | .hosts[2].jobs[0] |= (.status = "ERROR" | .error = "df failed" | del(.dest_avail_kb))')" \
    1 FAIL:STALE_RUN FAIL:JOB_ERROR "!INFO:STALE_IDLE"

# The compounding trap: acking the JOB_ERROR must not let the stale host pass.
printf 'setup2\tJOB_ERROR\t/phobos/data\n' > "$WORK_DIR/ack-joberr.txt"
GATE_TEST_ACK_FILE="$WORK_DIR/ack-joberr.txt" \
check "acked JOB_ERROR does not unlock idle downgrade" \
    "$(mutate '.hosts[2].last_run.age_hours = 49
               | .hosts[2].jobs[0] |= (.status = "ERROR" | .error = "df failed" | del(.dest_avail_kb))')" \
    1 FAIL:STALE_RUN ACK:JOB_ERROR "!INFO:STALE_IDLE"

check "job error (missing mount) behind OK status" \
    "$(mutate '.hosts[3].jobs[0] |= (.status = "ERROR" | .error = "df: /phobos: No such file or directory" | del(.dest_avail_kb))')" \
    1 FAIL:JOB_ERROR "!FAIL:DISK_UNKNOWN"

check "destination disk low (large disk under absolute threshold)" \
    "$(mutate '.hosts[4].jobs[0].dest_avail_kb = 30000000 | .hosts[4].jobs[0].dest_avail_human = "29GB"')" \
    1 FAIL:DISK_LOW

check "small disk with proportional headroom passes" \
    "$(mutate '.hosts[4].jobs[0] |= (.dest_total_kb = 30000000 | .dest_used_kb = 10000000 | .dest_avail_kb = 20000000 | .dest_avail_human = "19GB")')" \
    0 NO_FAILURES

check "pending backlog exceeds free space" \
    "$(mutate '.hosts[4].jobs[0] |= (.dest_total_kb = 30000000 | .dest_avail_kb = 10000000 | .dest_avail_human = "9.5GB" | .status = "PENDING" | .pending_files = 40 | .pending_bytes = 12000000000 | .pending_human = "12GB")')" \
    1 FAIL:DISK_LOW

check "backup never ran" \
    "$(mutate '.hosts[2].overall_status = "NEVER_RUN" | .hosts[2].last_run = {date:"never",age_hours:-1,result:null,status:"NEVER_RUN"}')" \
    1 FAIL:NEVER_RUN

check "remote status command failed" \
    "$(mutate ".hosts[1] = ${remote_error_entry//HOST/ephys7}")" \
    1 FAIL:STATUS_ERROR

check "garbage input" \
    "this is not json" 2 FAIL:RUNNER_FAILURE

check "unrecognized overall status" \
    "$(mutate '.hosts[1].overall_status = "WEIRD"')" 1 FAIL:UNRECOGNIZED_STATUS

check "unrecognized job status" \
    "$(mutate '.hosts[0].jobs[0].status = "MYSTERY"')" 1 FAIL:UNRECOGNIZED_JOB_STATUS

check "disk space unknown (df failed)" \
    "$(mutate '.hosts[1].jobs[0] |= (del(.dest_avail_kb) | .dest_avail_human = "UNKNOWN")')" \
    1 FAIL:DISK_UNKNOWN

check "job dropped from deployed config" \
    "$(mutate 'del(.hosts[0].jobs[1])')" 1 FAIL:MISSING_JOB

printf 'setup7\tDISK_LOW\t/phobos/data\n' > "$WORK_DIR/ack.txt"
GATE_TEST_ACK_FILE="$WORK_DIR/ack.txt" \
check "acknowledged finding passes but stays visible" \
    "$(mutate '.hosts[4].jobs[0].dest_avail_kb = 30000000')" \
    0 ACK:DISK_LOW NO_FAILURES

printf 'setup7 DISK_LOW /phobos/dat.\n' > "$WORK_DIR/ack-regex.txt"
GATE_TEST_ACK_FILE="$WORK_DIR/ack-regex.txt" \
check "ack matching is exact, not regex" \
    "$(mutate '.hosts[4].jobs[0].dest_avail_kb = 30000000')" \
    1 FAIL:DISK_LOW "!ACK:DISK_LOW"

printf 'ephys7 STALE_RUN -\n' > "$WORK_DIR/ack-host.txt"
GATE_TEST_ACK_FILE="$WORK_DIR/ack-host.txt" \
check "host-level codes cannot be acked" \
    "$(mutate '.hosts[1].last_run.age_hours = 49
               | .hosts[1].jobs[0] |= (.status = "PENDING" | .pending_files = 5 | .pending_bytes = 1000000)')" \
    1 FAIL:STALE_RUN "!ACK:STALE_RUN"

check "stringified numeric field fails closed (jq coerces silently)" \
    "$(mutate '.hosts[0].jobs[0].dest_avail_kb = "1294097432"')" \
    1 FAIL:MALFORMED_FIELD

check "gate fails closed on jq runtime error" \
    "$(mutate '.hosts[2].last_run = "garbage"')" \
    2 FAIL:RUNNER_FAILURE

GATE_TEST_HOST_COUNT=6 \
check "fleet config shrank vs expected count" \
    "$(cat "$HEALTHY")" 1 FAIL:CONFIG_MISMATCH

echo
echo "passed $pass_count, failed $fail_count"
[[ "$fail_count" -eq 0 ]]
