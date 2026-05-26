#!/usr/bin/env bash

# Shared helper for host-by-host worker execution.

# Run a worker script for each host and aggregate failures.
# Args: <worker_script> <host_0> [host_1 ...]
# Output: forwards worker output; prints FAILED lines per host.
# Returns: 0 if all hosts succeed, 1 if any host fails.
fleet_run_all() {
    local worker_script="$1"
    shift

    local failed=0
    local host
    for host in "$@"; do
        if ! "$worker_script" "$host"; then
            echo "FAILED: $host"
            failed=1
        fi
        echo
    done

    return "$failed"
}
