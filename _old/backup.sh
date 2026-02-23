#!/usr/bin/env bash
set -e

usage() {
  echo "usage: $0 <source> <dest>" >&2
  echo "       $0 status <source> <dest>" >&2
  echo "       $0 schedule <source> <dest> [cron]" >&2
  echo "       $0 unschedule <dest>" >&2
  exit 2
}

die() {
  echo "ERROR: $1" >&2
  exit 1
}

running_in_wsl() {
  grep -qsi microsoft /proc/version 2>/dev/null
}

assert_mounted() {
  mountpoint -q "$1" || die "$1 not mounted"
}

show_pending_changes() {
  local src="$1" dest="$2"
  rsync -avzn --stats "$src/" "$dest/" 2>&1 | \
    sed -n 's/^Number of regular files transferred:/files pending:/p
            s/^Total transferred file size:/bytes pending:/p'
}

run_backup() {
  local src="$1" dest="$2"
  rsync -avz --log-file="$dest/backup.log" "$src/" "$dest/"
}

# --- scheduling: linux ---

add_cron_job() {
  local src="$1" dest="$2" cron_time="${3:-0 1 * * *}"
  local script_path marker cron_line current tmp
  script_path=$(readlink -f "$0")
  marker="# BACKUP: $src -> $dest"
  cron_line="$cron_time $script_path $src $dest >> $dest/backup.log 2>&1"
  current=$(crontab -l 2>/dev/null || true)
  tmp=$(mktemp)

  {
    echo "$current" | awk -v m="$marker" \
      '/^#/ { if ($0==m) { skip=1; next } } skip && /^[0-9]/ { skip=0; next } { print }'
    echo "$marker"
    echo "$cron_line"
  } > "$tmp"

  crontab "$tmp"
  rm -f "$tmp"
  echo "scheduled: $cron_time"
}

remove_cron_job() {
  local dest="$1" marker current tmp
  marker="# BACKUP: .* -> $dest"
  current=$(crontab -l 2>/dev/null || true)
  echo "$current" | grep -qE "^$marker" || die "no backup scheduled for $dest"
  tmp=$(mktemp)

  echo "$current" | awk -v m="$marker" \
    '/^#/ { if ($0 ~ m) { skip=1; next } } skip && /^[0-9]/ { skip=0; next } { print }' > "$tmp"

  crontab "$tmp"
  rm -f "$tmp"
  echo "unscheduled: $dest"
}

# --- scheduling: wsl ---

add_windows_task() {
  local src="$1" dest="$2" time="${3:-01:00}"
  local script_path task_name
  script_path=$(wslpath -w "$0")
  task_name="Backup-$(basename "$dest")"

  schtasks.exe /Create /TN "$task_name" \
    /TR "wsl.exe bash \"$script_path\" \"$src\" \"$dest\"" \
    /SC DAILY /ST "$time" /F > /dev/null

  echo "scheduled: $time daily (Windows Task Scheduler)"
}

remove_windows_task() {
  local dest="$1"
  local task_name="Backup-$(basename "$dest")"
  schtasks.exe /Query /TN "$task_name" > /dev/null 2>&1 || die "no task found: $task_name"
  schtasks.exe /Delete /TN "$task_name" /F > /dev/null
  echo "unscheduled: $task_name"
}

# --- dispatch ---

schedule() {
  if running_in_wsl; then
    add_windows_task "$@"
  else
    add_cron_job "$@"
  fi
}

unschedule() {
  if running_in_wsl; then
    remove_windows_task "$@"
  else
    remove_cron_job "$@"
  fi
}

# --- main ---

main() {
  local cmd="${1:-}"
  case "$cmd" in
    status)
      [[ -z "${2:-}" || -z "${3:-}" ]] && usage
      assert_mounted "$3"
      show_pending_changes "$2" "$3"
      ;;
    schedule)
      [[ -z "${2:-}" || -z "${3:-}" ]] && usage
      schedule "$2" "$3" "${4:-}"
      ;;
    unschedule)
      [[ -z "${2:-}" ]] && usage
      unschedule "$2"
      ;;
    *)
      [[ -z "${1:-}" || -z "${2:-}" ]] && usage
      assert_mounted "$2"
      run_backup "$1" "$2"
      ;;
  esac
}

main "$@"
