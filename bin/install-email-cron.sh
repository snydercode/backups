#!/usr/bin/env bash
set -euo pipefail

EXPECTED_HOST_SHORT="eye-hand"
CRON_MARKER="# backup-kit-email-cron"
LOG_DIR="${HOME}/.local/state/backup-kit"
LOG_FILE="${LOG_DIR}/email.log"
SCRIPT_PATH="/home/chuck/backup/bin/check-and-email.sh"
CRON_LINE="30 8 * * * /usr/bin/env bash ${SCRIPT_PATH} >> ${LOG_FILE} 2>&1 ${CRON_MARKER}"

host_short="$(hostname -s 2>/dev/null || true)"
host_full="$(hostname -f 2>/dev/null || true)"

if [[ "${host_short}" != "${EXPECTED_HOST_SHORT}" && "${host_full}" != "${EXPECTED_HOST_SHORT}" && "${host_full}" != "${EXPECTED_HOST_SHORT}."* ]]; then
    echo "ERROR: must run on ${EXPECTED_HOST_SHORT}. Detected host_short='${host_short}', host_full='${host_full}'" >&2
    exit 1
fi

if [[ ! -x "${SCRIPT_PATH}" ]]; then
    echo "ERROR: missing executable script: ${SCRIPT_PATH}" >&2
    exit 1
fi

mkdir -p "${LOG_DIR}"

# Lightweight preflight for delivery path.
command -v sendmail >/dev/null 2>&1 || {
    echo "ERROR: sendmail is not available on this host" >&2
    exit 1
}

# Idempotent install using a managed marker.
(
    crontab -l 2>/dev/null | grep -Fv "${CRON_MARKER}" || true
    echo "${CRON_LINE}"
) | crontab -

count="$(crontab -l | grep -Fc "${CRON_MARKER}" || true)"
if [[ "${count}" != "1" ]]; then
    echo "ERROR: expected exactly 1 managed cron entry, found ${count}" >&2
    exit 1
fi

/usr/bin/env bash "${SCRIPT_PATH}" --dry-run

echo "Installed backup email cron on ${EXPECTED_HOST_SHORT}."
echo "Cron entry:"
crontab -l | grep -F "${CRON_MARKER}"

next_run_epoch="$(date -d 'today 08:30' +%s)"
now_epoch="$(date +%s)"
if (( now_epoch >= next_run_epoch )); then
    next_run="$(date -d 'tomorrow 08:30' '+%a %b %d %Y %H:%M %Z')"
else
    next_run="$(date -d 'today 08:30' '+%a %b %d %Y %H:%M %Z')"
fi
echo "Next scheduled run: ${next_run}"
