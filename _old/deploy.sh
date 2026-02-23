#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/backup.sh"
INSTALL_PATH="$HOME/.local/bin/backup"

usage() {
  echo "usage: $0 <machine>" >&2
  echo "       machines: ephys2 ephys3 ephys7 setup2 setup3 setup7" >&2
  exit 2
}

die() {
  echo "ERROR: $1" >&2
  exit 1
}

install_script() {
  mkdir -p "$(dirname "$INSTALL_PATH")"
  install -m 0755 "$BACKUP_SCRIPT" "$INSTALL_PATH"
  echo "installed: $INSTALL_PATH"
}

main() {
  local machine="${1:-}"
  [[ -z "$machine" ]] && usage

  install_script

  case "$machine" in
    ephys3)
      schedule_job "/mnt/d/data /mnt/e/data"
      schedule_job "/mnt/d/data /mnt/f/data"
      ;;
    ephys7)
      schedule_job "/mnt/d/data /mnt/e/data"
      ;;
    setup2)
      schedule_jobs "/data /phobos/data"
      schedule_jobs "/data /deimos/data"
      ;;
    setup3|setup7)
      schedule_jobs "/data /bak/1/data"
      schedule_jobs "/data /bak/2/data"
      ;;
    *)
      die "unknown machine: $machine"
      ;;
  esac
}

main "$@"
