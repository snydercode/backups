#!/usr/bin/env bash
# ssh-ro.sh — run an allowlisted read-only diagnostic on one fleet host.
# Usage: ssh-ro.sh <host> <command...>
#
# This is the only remote access granted to the backup-check FAIL-path triage
# agent. That agent's prompt embeds remote-originated text (error strings, log
# contents), so its remote reach is capped here, in code, not in prompt prose:
# only known read-only commands, no shell metacharacters, only fleet hosts.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$REPO_DIR/lib/jobs.sh"

die() {
    echo "ssh-ro: $*" >&2
    exit 2
}

# Args: <command string>; recurses once to vet the inner command of a WSL wrap.
allowed_command() {
    local cmd="$1"
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"

    case "$cmd" in
        pgrep\ *|cat\ *|tail\ *|head\ *|ls|ls\ *|stat\ *|file\ *) return 0 ;;
        df|df\ *|du\ *|findmnt*|mountpoint\ *|free*|uptime*|quser*|hostname*|date*) return 0 ;;
        crontab\ -l*) return 0 ;;
        schtasks.exe\ /[Qq]uery*) return 0 ;;
        # cmd.exe is the shell on the Windows side of the SSH connection, so a
        # cut-over host's state under C:\ProgramData\backup-kit is unreachable by
        # cat/tail/ls. These are the cmd equivalents.
        type\ *|dir|dir\ *) return 0 ;;
        # Windows reads that cmd has no verb for. The payload is vetted the same
        # way the WSL wrap below is, and the metacharacter guard already rejects
        # the ; that PowerShell would need to chain a second statement.
        powershell.exe\ -NoProfile\ -Command\ *)
            local ps="${cmd#powershell.exe -NoProfile -Command }"
            ps="${ps#[\"\']}"
            ps="${ps%[\"\']}"
            case "$ps" in
                Get-Content\ *|Get-ScheduledTaskInfo*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        wsl.exe\ -e\ bash\ -lc\ *)
            local inner="${cmd#wsl.exe -e bash -lc }"
            inner="${inner#[\"\']}"
            inner="${inner%[\"\']}"
            allowed_command "$inner"
            return
            ;;
        *) return 1 ;;
    esac
}

host="${1:-}"
[[ -n "$host" ]] || die "usage: ssh-ro.sh <host> <command...>"
shift
cmd="$*"
[[ -n "$cmd" ]] || die "usage: ssh-ro.sh <host> <command...>"

hosts="$(jobs_list_hosts "$REPO_DIR/jobs.txt")"
grep -qx "$host" <<< "$hosts" || die "unknown host '$host' (not in jobs.txt)"

# One command per invocation: no chaining, substitution, or redirection.
[[ "$cmd" == *$'\n'* ]] && die "rejected: newline in command"
[[ "$cmd" =~ [\;\|\&\<\>\`\$\(\)] ]] && die "rejected: shell metacharacter in command"

allowed_command "$cmd" || die "rejected: not an allowlisted read-only command: $cmd"

exec ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "$cmd"
