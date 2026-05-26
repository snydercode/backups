#!/usr/bin/env bash

# Shared helpers for host list operations.

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
