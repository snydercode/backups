# Agent Guidelines — backup-kit

backup-kit is a minimal shell-script backup system for 5 lab machines.
All code is Bash — no Python, no build step, no compilation.

---

## Hosts

| Host   | OS      | User | Source       | Destinations                     |
| ------ | ------- | ---- | ------------ | -------------------------------- |
| setup2 | Linux   | toor | /data        | /phobos/data, /deimos/data       |
| setup3 | Linux   | toor | /data        | /bak/1/data, /bak/2/data         |
| setup7 | Linux   | toor | /data        | /bak/1/data, /bak/2/data         |
| ephys3 | Win+WSL | toor | /mnt/d/data  | /mnt/e/data, /mnt/f/data         |
| ephys7 | Win+WSL | toor | /mnt/d/data  | /mnt/e/data (F disabled for now) |

**Note**: setup7 has stale `/phobos` and `/deimos` mount points — do NOT use them.

---

## Repository Structure

```
backup/
  hub/
    hosts.txt          # Host list (hostname or hostname:wsl)
    deploy.sh          # Push runtime to one host
    deploy-all.sh      # Push runtime to all hosts
    schedule.sh        # Install backup schedule on one host
    schedule-all.sh    # Install backup schedules on all hosts
    status-all.sh      # Check status across all hosts
  runtime/
    backup-sync.sh     # Core rsync logic (--mode plan|run)
    backup-plan.sh     # Thin wrapper: show pending files/bytes
    backup-run.sh      # Thin wrapper: execute backup
    backup-status.sh   # Health summary (human + machine-readable)
    jobs/
      setup2.txt       # Host-specific job definitions
      setup3.txt
      setup7.txt
      ephys3.txt
      ephys7.txt
  _old/                # Archived previous scripts
  AGENTS.md            # This file
```

### hosts.txt format

```
# hostname or hostname:wsl
setup2
setup3
setup7
ephys3:wsl
ephys7:wsl
```

The `:wsl` suffix tells deploy/status scripts to wrap commands with `wsl.exe -e bash -lc "..."`.

**Key rule**: `hub/` scripts run from this repo; `runtime/` scripts are deployed to `~/backup-kit/` on each host.

---

## Safe Commands (READ-ONLY)

These commands are safe for agents to run anytime:

```bash
# Check status across all hosts
bash hub/status-all.sh

# Check status on one host
ssh setup7 '~/backup-kit/backup-status.sh'
ssh ephys3 'wsl.exe -e bash -lc "~/backup-kit/backup-status.sh"'

# Preview pending changes (dry-run)
ssh setup3 '~/backup-kit/backup-plan.sh'
```

---

## Mutating Commands (REQUIRE CONFIRMATION)

These commands make changes — confirm with user before running:

```bash
# Deploy scripts to all hosts
bash hub/deploy-all.sh

# Deploy scripts to one host
bash hub/deploy.sh setup3

# Schedule backups on all hosts
bash hub/schedule-all.sh

# Schedule backup on one host
bash hub/schedule.sh setup3

# Run backup on one host (actually copies files)
ssh setup3 '~/backup-kit/backup-run.sh'
```

---

## Status Output Format

`backup-status.sh` outputs key=value lines for easy parsing:

```
host=setup3
last_run_date=2026-02-22 01:00:15
last_run_age_hours=12
last_run_result=0
last_run_status=OK

job_0_src=/data
job_0_dest=/bak/1/data
job_0_enabled=1
job_0_pending_files=0
job_0_pending_bytes=0
job_0_status=UP_TO_DATE

overall_status=OK
```

**Status values**:
- `UP_TO_DATE`: no pending files
- `PENDING`: files waiting, last run recent
- `STALE`: files waiting, last run >30h ago
- `ERROR`: could not check (mount missing, etc.)
- `NEVER_RUN`: backup has never executed

---

## Health Check Workflow

When asked to verify backup health:

1. Run `bash hub/status-all.sh`
2. Look for `overall_status=` on each host
3. Report issues:
   - `STALE` or `FAILED` on any host → WARN or FAIL
   - `NEVER_RUN` → needs initial backup
   - `ERROR` on job → check mount/drive availability
4. For ephys7 `/mnt/f` (disabled): treat as informational, not failure

---

## Rsync Policy

All backups use these flags (append-only, safe):

```
-a                    # archive mode
--ignore-existing     # never overwrite existing backup files
--partial             # keep partial files on interrupt
--partial-dir=...     # store partials in hidden dir
--stats               # show transfer statistics
```

**NOT used**:
- `--delete` (never remove files from destination)
- `--inplace` (always use temp file + atomic rename)

---

## Scheduling

### Linux (cron)

```bash
# Install cron job (1 AM daily)
ssh setup3 '(crontab -l 2>/dev/null | grep -v backup-kit; \
  echo "0 1 * * * /home/toor/backup-kit/backup-run.sh >> ~/.local/state/backup-kit/cron.log 2>&1") | crontab -'

# Remove cron job
ssh setup3 '(crontab -l 2>/dev/null | grep -v backup-kit) | crontab -'

# Verify
ssh setup3 'crontab -l | grep backup-kit'
```

### Windows (Task Scheduler via WSL)

```bash
# Create task (1 AM daily)
ssh ephys3 'schtasks.exe /Create /TN "BackupKit" \
  /TR "wsl.exe -e bash -lc /home/toor/backup-kit/backup-run.sh" \
  /SC DAILY /ST 01:00 /F'

# Delete task
ssh ephys3 'schtasks.exe /Delete /TN "BackupKit" /F'

# Verify
ssh ephys3 'schtasks.exe /Query /TN "BackupKit"'
```

---

## Cleanup Legacy Schedules

**setup7** has stale cron entries that should be removed:

```bash
ssh setup7 'crontab -l | grep -v backintime | grep -v "/phobos\|/deimos" | crontab -'
```

**ephys3/ephys7** may have old `CinqBackup*` tasks:

```bash
ssh ephys3 'schtasks.exe /Delete /TN "CinqBackupE" /F 2>nul; schtasks.exe /Delete /TN "CinqBackupF" /F 2>nul'
```

---

## File Locations on Hosts

```
~/backup-kit/
  backup-sync.sh
  backup-plan.sh
  backup-run.sh
  backup-status.sh
  jobs.txt

~/.local/state/backup-kit/
  backup.lock          # Lock file (prevents concurrent runs)
  last-run.log         # Rsync output from last run
  last-run.txt         # Machine-readable last run metadata
```

---

## SSH Notes

- All hosts use port 1840 (configured in ~/.ssh/config)
- Use `BatchMode=yes` for automation
- WSL hosts: prefix commands with `wsl.exe -e bash -lc "..."`

---

## Rollback

To revert to previous backup system:

1. Old scripts are preserved in `_old/` directory
2. Old deployed scripts on hosts were at `~/.local/bin/backup`
3. Old cron/Task Scheduler entries may still exist (check per host)

To restore old system:
```bash
# Re-deploy old script
scp _old/backup.sh setup3:~/.local/bin/backup
ssh setup3 'chmod +x ~/.local/bin/backup'
```
