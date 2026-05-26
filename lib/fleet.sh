#!/usr/bin/env bash

# Shared helper for host-by-host worker execution.

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
