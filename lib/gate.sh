#!/usr/bin/env bash

# Deterministic health gate over the fleet status JSON (status-all.sh --raw).
# Depends on lib/jobs.sh (jobs_list_hosts, jobs_emit_host_block, jobs_emit_host_jobs);
# callers must source it first.
#
# The verdict is computed here, by code, on purpose: the weekly check's fail-safe
# guarantee rests on never letting an LLM (or a human skim) decide "all's well".
# Every rule maps to a numbered gate rule in the weekly-check design spec.

# Destinations under this are critical per AGENTS.md ("< 50GB remaining").
# Units: GNU df -P 1024-byte blocks (assumes no POSIXLY_CORRECT on remote hosts).
GATE_MIN_AVAIL_KB=50000000

# Hours since last successful run before a host counts as stale.
# Backups run daily at 1 AM; 30h allows one night of slack (AGENTS.md).
GATE_MAX_RUN_AGE_HOURS=30

# Evaluate fleet status JSON against the local jobs config.
# Args: <jobs_file> <expected_host_count> [ack_file]
# Stdin: fleet JSON from status-all.sh --raw (host entries carry .fleet_host)
# Stdout: one finding per line: FAIL|ACK <TAB> host <TAB> code <TAB> detail
#         (ACK = finding matched an ack_file entry; informational, not failing)
# Returns: 0 no failing findings, 1 failing findings, 2 input invalid
gate_evaluate() {
    local jobs_file="$1"
    local expected_host_count="$2"
    local ack_file="${3:-}"

    local input
    input="$(cat)"

    if ! jq -e '.hosts | type == "array"' >/dev/null 2>&1 <<< "$input"; then
        printf 'FAIL\t-\tRUNNER_FAILURE\tstatus output is not valid fleet JSON\n'
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

    findings+="$(jq -r \
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
                    if (($h.last_run.age_hours // -1) < 0
                        or ($h.last_run.age_hours // -1) > $max_age_hours) then
                        [{code: "STALE_RUN", key: "-",
                          detail: ("last successful run "
                                   + (($h.last_run.age_hours // -1) | tostring)
                                   + "h ago (limit " + ($max_age_hours | tostring) + "h)")}]
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
                  # G11 DISK_LOW: destination under the critical threshold.
                  $h.jobs[]? | select(.status != "ERROR")
                  | select(.dest_avail_kb != null and .dest_avail_kb < $min_avail_kb)
                  | {code: "DISK_LOW", key: .dest,
                     detail: (.dest + ": " + (.dest_avail_human // "?")
                              + " free (critical threshold ~50GB)")}
              ] + [
                  # G12 DISK_UNKNOWN: df silently failed on a non-ERROR job.
                  $h.jobs[]? | select(.status != "ERROR")
                  | select(.dest_avail_kb == null)
                  | {code: "DISK_UNKNOWN", key: .dest,
                     detail: (.dest + ": destination free space unknown (df failed)")}
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

    local rc=0
    local status line code key detail
    while IFS=$'\t' read -r host code key detail; do
        [[ -z "$code" ]] && continue
        status="FAIL"
        if [[ -n "$ack_file" && -r "$ack_file" ]] \
            && grep -Eq "^[[:space:]]*${host}[[:space:]]+${code}[[:space:]]+${key}([[:space:]]|$)" "$ack_file"; then
            status="ACK"
        else
            rc=1
        fi
        printf '%s\t%s\t%s\t%s\n' "$status" "$host" "$code" "$detail"
    done <<< "$findings"

    return "$rc"
}
