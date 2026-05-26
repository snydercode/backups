#!/usr/bin/env bash

# Shared helpers for host list operations.

# Find index of a host name in a provided host list.
# Args: <needle> <host_0> [host_1 ...]
# Stdout: zero-based index when found.
# Returns: 0 if found, 1 otherwise.
hosts_find_index() {
    local needle="$1"
    shift

    local i=0
    local host
    for host in "$@"; do
        if [[ "$host" == "$needle" ]]; then
            printf '%s\n' "$i"
            return 0
        fi
        i=$((i + 1))
    done

    return 1
}
