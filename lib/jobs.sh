#!/usr/bin/env bash

# Shared helpers for parsing jobs.txt.

jobs_list_hosts() {
    local config_file="$1"

    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        /^[[:space:]]*\[/ {
            host=$0
            sub(/^[[:space:]]*\[/, "", host)
            sub(/\][[:space:]]*$/, "", host)
            print host
        }
    ' "$config_file"
}

jobs_list_host_meta() {
    local config_file="$1"

    awk '
        function flush() {
            if (host != "") {
                print host "|" os "|" user "|" windows_user
            }
        }

        BEGIN {
            host = ""
            os = ""
            user = ""
            windows_user = ""
        }

        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }

        /^[[:space:]]*\[/ {
            flush()
            host=$0
            sub(/^[[:space:]]*\[/, "", host)
            sub(/\][[:space:]]*$/, "", host)
            os = ""
            user = ""
            windows_user = ""
            next
        }

        host != "" {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)

            if (line ~ /^os=/) {
                os = line
                sub(/^os=/, "", os)
            } else if (line ~ /^user=/) {
                user = line
                sub(/^user=/, "", user)
            } else if (line ~ /^windows_user=/) {
                windows_user = line
                sub(/^windows_user=/, "", windows_user)
            }
        }

        END {
            flush()
        }
    ' "$config_file"
}

jobs_emit_host_block() {
    local config_file="$1"
    local target_host="$2"

    awk -v target="$target_host" '
        BEGIN { in_target=0 }

        /^[[:space:]]*#/ || /^[[:space:]]*$/ {
            if (in_target) print
            next
        }

        /^[[:space:]]*\[/ {
            if ($0 ~ "^[[:space:]]*\\[" target "\\][[:space:]]*$") {
                in_target=1
                next
            }
            if (in_target) exit
            in_target=0
            next
        }

        {
            if (in_target) print
        }
    ' "$config_file"
}

jobs_emit_host_jobs() {
    local host_block="$1"

    local host_src=""
    local line key value

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" != *=* ]]; then
            return 1
        fi

        key="${line%%=*}"
        value="${line#*=}"
        key="${key//[[:space:]]/}"
        value="${value##[[:space:]]}"

        case "$key" in
            src) host_src="$value" ;;
            dest)
                [[ -n "$host_src" ]] || return 1
                printf '%s:%s\n' "$host_src" "$value"
                ;;
        esac
    done <<< "$host_block"
}
