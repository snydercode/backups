#!/usr/bin/env bash

# Deterministic health gate over the fleet status JSON (status-all.sh --raw).
# Depends on lib/jobs.sh (jobs_list_hosts, jobs_emit_host_block, jobs_emit_host_jobs);
# callers must source it first.
#
# The verdict is computed here, by code, on purpose: the weekly check's fail-safe
# guarantee rests on never letting an LLM (or a human skim) decide "all's well".
# Every rule maps to a numbered gate rule in the weekly-check design spec.

# Destinations under this are critical per CLAUDE.md ("< 50GB remaining").
# Units: GNU df -P 1024-byte blocks (assumes no POSIXLY_CORRECT on remote hosts).
GATE_MIN_AVAIL_KB=50000000

# Hours since last successful run before a host counts as stale.
# Backups run daily at 1 AM; 30h allows one night of slack (CLAUDE.md).
GATE_MAX_RUN_AGE_HOURS=30

# Only per-destination findings may be acknowledged. Host-level codes
# (DISCONNECTED, STALE_RUN, ...) stay un-ackable on purpose: acking one would
# un-monitor an entire host while the dead-man task keeps completing.
GATE_ACKABLE_CODES=" DISK_LOW JOB_ERROR MISSING_JOB DISK_UNKNOWN UNRECOGNIZED_JOB_STATUS "

# Informational codes: reported for visibility but never failing. STALE_IDLE is
# a stale host whose every job proved pending_files == 0 — the scheduler is
# dead but nothing on the source is unbacked-up, so alarming weekly would just
# breed alarm fatigue. Accepted trade-off: when new data does land, the alarm
# waits for the next weekly check (up to ~7 days of single-copy exposure).
GATE_INFO_CODES=" STALE_IDLE "

# Evaluate fleet status JSON against the local jobs config.
# Args: <jobs_file> <expected_host_count> [ack_file]
# Stdin: fleet JSON from status-all.sh --raw (host entries carry .fleet_host)
# Stdout: one finding per line: FAIL|ACK|INFO <TAB> host <TAB> code <TAB> key <TAB> detail
#         (ACK = finding matched an ack_file entry; informational, not failing.
#          An ack_file line is fields 2-4 of a FAIL line, whitespace-separated.
#          INFO = code in GATE_INFO_CODES; never failing, no ack needed.)
# Returns: 0 no failing findings, 1 failing findings, 2 input invalid
gate_evaluate() {
    local jobs_file="$1"
    local expected_host_count="$2"
    local ack_file="${3:-}"

    local input
    input="$(cat)"

    if ! jq -e '.hosts | type == "array"' >/dev/null 2>&1 <<< "$input"; then
        printf 'FAIL\t-\tRUNNER_FAILURE\t-\tstatus output is not valid fleet JSON\n'
        return 2
    fi

    local -a expected_hosts=()
    local host
    while IFS= read -r host; do
        [[ -n "$host" ]] && expected_hosts+=("$host")
    done < <(jobs_list_hosts "$jobs_file")

    local findings=""
    if [[ "${#expected_hosts[@]}" -ne "$expected_host_count" ]]; then
        findings+="$(printf '%s\t%s\t%s\t%s' "-" "CONFIG_MISMATCH" "-" \
            "jobs.txt lists ${#expected_hosts[@]} hosts, expected $expected_host_count (fleet config changed or renderer broke?)")"$'\n'
    fi

    # Expected src:dest pairs per host, as JSON for the jq gate below.
    local expected_jobs_json
    expected_jobs_json="$(
        for host in "${expected_hosts[@]}"; do
            jobs_emit_host_jobs "$(jobs_emit_host_block "$jobs_file" "$host")" \
                | jq -R . | jq -sc --arg host "$host" '{($host): .}'
        done | jq -sc 'add // {}'
    )"
    local expected_hosts_json
    expected_hosts_json="$(printf '%s\n' "${expected_hosts[@]}" | jq -R . | jq -sc .)"

    local jq_findings
    jq_findings="$(jq -r \
        --argjson expected_hosts "$expected_hosts_json" \
        --argjson expected_jobs "$expected_jobs_json" \
        --argjson min_avail_kb "$GATE_MIN_AVAIL_KB" \
        --argjson max_age_hours "$GATE_MAX_RUN_AGE_HOURS" '
        (.hosts // []) as $hosts |
        ([
            # G2 MISSING_HOST: expected host absent from the output entirely.
            ($expected_hosts - [$hosts[].fleet_host // empty])[]
                | {host: ., code: "MISSING_HOST", key: "-",
                   detail: "host absent from status output"}
        ] + [
            $hosts[]
            | (.fleet_host // .host // "?") as $name
            | . as $h
            | (
                # G3-G8: one finding per host from overall/last-run state.
                if $h.overall_status == "UNREACHABLE" then
                    [{code: "DISCONNECTED", key: "-",
                      detail: ($h.errors[0].message // "ssh failed")}]
                elif $h.overall_status == "FAILED" then
                    [{code: "FAILED_RUN", key: "-",
                      detail: ("last run " + ($h.last_run.date // "?")
                               + " exited " + (($h.last_run.result // "?") | tostring))}]
                elif $h.overall_status == "NEVER_RUN" then
                    [{code: "NEVER_RUN", key: "-", detail: "backup has never executed"}]
                elif $h.overall_status == "ERROR" then
                    [{code: "STATUS_ERROR", key: "-",
                      detail: ($h.errors[0].message // "remote status command failed")}]
                elif $h.overall_status == "OK" then
                    ($h.last_run.age_hours // -1) as $age
                    | if ($age | type) != "number" or $age < 0
                         or $age > $max_age_hours then
                        # G8 STALE_RUN vs G15 STALE_IDLE: a stale host downgrades
                        # to informational only when it PROVES idle. Anything
                        # unprovable stays a failure: non-numeric or unknown age,
                        # no jobs, a job whose check did not succeed (an ERROR
                        # job reports default-zero pending counters that mean
                        # "dry-run never ran", not "nothing pending"), or a
                        # pending counter that is missing or non-numeric.
                        # src_last_file_epoch > 0 demands positive evidence the
                        # source is readable and non-empty: backup.sh emits -1
                        # when it cannot stat any source file, and its rsync
                        # dry-run parse defaults pending to 0 on failure — a
                        # host whose source disk vanished must not read as idle.
                        [$h.jobs[]?] as $jobs
                        | (($age | type) == "number" and $age >= 0
                           and ($jobs | length > 0)
                           and ($jobs | all(.status == "OK"
                                            and ([.pending_files, .pending_bytes]
                                                 | all(type == "number" and . == 0))
                                            and ((.src_last_file_epoch | type) == "number"
                                                 and .src_last_file_epoch > 0)))) as $idle
                        | [{code: (if $idle then "STALE_IDLE" else "STALE_RUN" end),
                            key: "-",
                            detail: ("last successful run " + ($age | tostring)
                                     + "h ago (limit " + ($max_age_hours | tostring) + "h)"
                                     + (if $idle
                                        then " — no files pending, scheduler likely dead but no data at risk"
                                        else "" end))}]
                    else [] end
                else
                    [{code: "UNRECOGNIZED_STATUS", key: "-",
                      detail: ("overall_status=" + ($h.overall_status | tostring))}]
                end
              )
              + [
                  # G9 JOB_ERROR: per-destination check failure (missing mount etc).
                  $h.jobs[]? | select(.status == "ERROR")
                  | {code: "JOB_ERROR", key: .dest,
                     detail: (.dest + ": " + ((.error // "unknown error")
                              | split("\n")[0]))}
              ] + [
                  # G10: unknown job status must alarm, not pass.
                  $h.jobs[]? | select(.status as $s | ["OK", "PENDING", "ERROR"]
                                      | index($s) | not)
                  | {code: "UNRECOGNIZED_JOB_STATUS", key: .dest,
                     detail: (.dest + ": status=" + (.status | tostring))}
              ] + [
                  # G11 DISK_LOW: destination lacks headroom. Threshold is the
                  # smaller of the absolute critical limit and 20% of the disk —
                  # some hosts back up small datasets to ~29GB disks that could
                  # never hold 50GB free. Independently, a pending backlog
                  # bigger than the free space fails tonight regardless of
                  # thresholds.
                  $h.jobs[]? | select(.status != "ERROR")
                  | select(.dest_avail_kb != null)
                  | (if .dest_total_kb != null
                     then ([$min_avail_kb, (.dest_total_kb / 5)] | min)
                     else $min_avail_kb end) as $threshold
                  | select(.dest_avail_kb < $threshold
                           or ((.pending_bytes // 0) > .dest_avail_kb * 1024))
                  | {code: "DISK_LOW", key: .dest,
                     detail: (.dest + ": " + (.dest_avail_human // "?")
                              + " free — "
                              + (if (.pending_bytes // 0) > .dest_avail_kb * 1024
                                 then "pending backlog (" + (.pending_human // "?")
                                      + ") exceeds free space"
                                 else "below critical headroom threshold" end))}
              ] + [
                  # G12 DISK_UNKNOWN: df silently failed on a non-ERROR job.
                  $h.jobs[]? | select(.status != "ERROR")
                  | select(.dest_avail_kb == null)
                  | {code: "DISK_UNKNOWN", key: .dest,
                     detail: (.dest + ": destination free space unknown (df failed)")}
              ] + [
                  # G14 MALFORMED_FIELD: numeric job fields with a non-numeric
                  # type. jq coerces silently ("x" < n is false, "x" * n is
                  # string-repeat), so without this rule a stringified number
                  # bypasses every disk check with no error to catch.
                  $h.jobs[]?
                  | . as $j
                  | (["dest_avail_kb", "dest_total_kb", "pending_bytes", "pending_files"]
                     | map(select((($j[.]) | type) as $t
                                  | $t != "number" and $t != "null"))) as $bad
                  | select($bad | length > 0)
                  | {code: "MALFORMED_FIELD", key: ($j.dest // "-"),
                     detail: (($j.dest // "?") + ": non-numeric field(s): "
                              + ($bad | join(",")))}
              ] + (
                  # G13 MISSING_JOB: deployed jobs file dropped an expected pair.
                  # Only when the host produced a real job listing (not synthesized).
                  if ["OK", "FAILED", "NEVER_RUN"] | index($h.overall_status) then
                      ($expected_jobs[$name] // []) as $expected
                      | [$h.jobs[]? | (.src + ":" + .dest)] as $reported
                      | [($expected - $reported)[]
                         | {code: "MISSING_JOB", key: .,
                            detail: ("expected job " + . + " not reported by host")}]
                  else [] end
              )
              | .[]
              | . + {host: $name}
        ])
        | .[] | [.host, .code, .key, .detail] | @tsv
    ' <<< "$input")"
    # A jq runtime error (schema drift, wrongly-typed field) must fail CLOSED:
    # unchecked, it would abort with zero findings and read as a healthy fleet.
    if [[ $? -ne 0 ]]; then
        printf 'FAIL\t-\tRUNNER_FAILURE\t-\tgate jq program failed on the fleet JSON (schema drift?)\n'
        return 2
    fi
    findings+="$jq_findings"

    local rc=0
    local status code key detail
    while IFS=$'\t' read -r host code key detail; do
        [[ -z "$code" ]] && continue
        status="FAIL"
        if [[ "$GATE_INFO_CODES" == *" $code "* ]]; then
            status="INFO"
        elif [[ "$GATE_ACKABLE_CODES" == *" $code "* ]] \
            && [[ -n "$ack_file" && -r "$ack_file" ]] \
            && awk -v h="$host" -v c="$code" -v k="$key" '
                   /^[[:space:]]*#/ { next }
                   $1 == h && $2 == c && $3 == k { found = 1; exit }
                   END { exit !found }' "$ack_file"; then
            status="ACK"
        else
            rc=1
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$status" "$host" "$code" "$key" "$detail"
    done <<< "$findings"

    return "$rc"
}
