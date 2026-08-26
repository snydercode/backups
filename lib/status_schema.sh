#!/usr/bin/env bash

# Shared status-payload vocabulary for bin/status.sh and bin/status-all.sh.

# bin/status.sh exits with this when ssh never connected, as distinct from 1
# (the host answered and something after that went wrong). Collection classifies
# a host UNREACHABLE from this code, which the gate turns into DISCONNECTED and
# the weekly report renders as "unreachable over SSH". Keeping the number here
# rather than in each script is the point: the producer and both consumers have
# to agree on it, and a silent disagreement would look like a healthy fleet.
STATUS_EXIT_UNREACHABLE=3

# Text fallback for callers that have output but no exit code, and for a
# status.sh invoked by hand. The exit code is authoritative where there is one:
# these strings are incomplete by nature, and were the whole story until a
# ProxyJump failure — which names the jump host and not the target, and says
# none of the below — spent two days being reported as a runtime-detection bug.
status_ssh_error_patterns() {
    cat <<'EOF'
Connection timed out
Could not resolve hostname
Connection refused
No route to host
Permission denied
Network is unreachable
Connection closed by remote host
Connection reset by peer
kex_exchange_identification
ssh_exchange_identification
administratively prohibited
stdio forwarding failed
Host key verification failed
not responding
Operation timed out
EOF
}

# ssh spreads one failure over several lines and saves the useful one for last:
#   channel 0: open failed: administratively prohibited: open failed
#   stdio forwarding failed
#   kex_exchange_identification: Connection closed by remote host
# A finding and a report row each get one line, so give them the one that says
# why. bin/status.sh reprints ssh's stderr verbatim under its own summary line,
# so the last line is ssh's own words whether or not it went through that.
status_ssh_reason() {
    local line
    line="$(printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -1)"
    line="$(status_clean_line "$line")"
    printf '%s' "${line:-no diagnostic output from ssh}"
}

# Findings are tab-separated and a Windows host answers with CRLF, so a raw
# remote line can end a field early or trail a stray carriage return through the
# email. Fit one line to sit in a field.
status_clean_line() {
    printf '%s' "$1" | tr -d '\r' | tr '\t' ' ' | sed -e 's/^ *//' -e 's/ *$//'
}

# Args: <exit code, or "" if unknown> <combined output>
# True when the host never answered ssh.
status_is_unreachable() {
    local rc="$1" text="$2" pattern

    if [[ -n "$rc" && "$rc" == "$STATUS_EXIT_UNREACHABLE" ]]; then
        return 0
    fi

    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        [[ "$text" == *"$pattern"* ]] && return 0
    done < <(status_ssh_error_patterns)

    return 1
}

# Args: <host> <combined output> [exit code from bin/status.sh]
status_error_json() {
    local host="$1"
    local output="$2"
    local rc="${3:-}"
    local err_type="command_failed"
    local overall="ERROR"
    # Everything else is identified by its first line. An unreachable host is the
    # exception: its first line is bin/status.sh saying so, and the line worth
    # carrying into the finding is ssh's own, further down.
    local message="${output%%$'\n'*}"

    if status_is_unreachable "$rc" "$output"; then
        err_type="ssh_failed"
        overall="UNREACHABLE"
        message="$(status_ssh_reason "$output")"
    elif [[ "$output" == "NON_JSON_RAW_PAYLOAD:"* ]]; then
        err_type="raw_payload_not_json"
        message="${message#NON_JSON_RAW_PAYLOAD: }"
    fi

    message="$(status_clean_line "$message")"
    # "FAIL ephys3 DISCONNECTED - ERROR: ..." stutters; the status field already
    # says this is a failure.
    message="${message#ERROR: }"

    jq -cn --arg host "$host" --arg overall "$overall" --arg err_type "$err_type" --arg message "$message" '{schema_version:1,host:$host,reachable:false,overall_status:$overall,last_run:{date:"unknown",age_hours:-1,result:null,status:"UNKNOWN"},jobs:[],errors:[{type:$err_type,message:$message}]}'
}
