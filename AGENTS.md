# Agent Guidelines — backup-kit

backup-kit is a minimal shell-script backup system for 5 lab machines.
All code is Bash — no Python, no build step, no compilation.

---

## Hosts

| Host   | OS      | User | Source       | Destinations                     |
| ------ | ------- | ---- | ------------ | -------------------------------- |
| setup2 | Linux   | toor | /data        | /phobos/data, /deimos/data       |
| setup3 | Linux   | toor | /data        | /phobos/data, /deimos/data       |
| setup7 | Linux   | toor | /data        | /phobos/data, /deimos/data       |
| ephys3 | Win+WSL | toor | /mnt/d/data  | /mnt/e/data, /mnt/f/data         |
| ephys7 | Win+WSL | toor | /mnt/d/data  | /mnt/e/data (F disabled for now) |

**Note**: setup7's old `/ganymede` and `/callisto` mount points have been renamed to `/phobos` and `/deimos`.

---

## Repository Structure

```
backup/
  bin/
    hosts.txt          # Host list (hostname or hostname:wsl:windowsuser)
    deploy.sh          # Push runtime to one host
    deploy-all.sh      # Push runtime to all hosts
    schedule.sh        # Install backup schedule on one host
    schedule-all.sh    # Install backup schedules on all hosts
    status-all.sh      # Check status across all hosts
    check-and-email.sh # Collect status and email daily digest
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
# hostname (Linux) or hostname:wsl:windowsuser (Windows/WSL)
setup2
setup3
setup7
ephys3:wsl:admin
ephys7:wsl:Toor
```

The `:wsl` suffix tells deploy/status scripts to wrap commands with `wsl.exe -e bash -lc "..."`.

**Key rule**: `bin/` scripts run from this repo; `backup.sh` is deployed to `~/backup-kit/` on each host.

---

## Daily Email Digest

`bin/check-and-email.sh` collects status from all hosts and emails a daily digest to `chuck@eye-hand.wustl.edu` (aliased to `charles.d.holmes@gmail.com`).

- Runs daily at **8:30 AM** via cron on `eye-hand`
- Sends via local `sendmail -t` when running on `eye-hand` (otherwise relays via `ssh eye "sendmail -t"`)
- Subject encodes overall health: `[backup] OK`, `WARNING`, `RUNNING`, or `FAILED`
- Reports per-host: overall status, last run age, per-job pending files/bytes, disk avail/used
- Detects still-running backups via `pgrep -f backup-run.sh` on each host
- Log: `~/.local/state/backup-kit/email.log`
- Install/update cron on eye-hand: `make install-email`
- Dry run: `bash bin/check-and-email.sh --dry-run`

---

## Safe Commands (READ-ONLY)

These commands are safe for agents to run anytime:

```bash
# Check status across all hosts
bash bin/status-all.sh

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
bash bin/deploy-all.sh

# Deploy scripts to one host
bash bin/deploy.sh setup3

# Schedule backups on all hosts
bash bin/schedule-all.sh

# Schedule backup on one host
bash bin/schedule.sh setup3

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
job_0_dest=/phobos/data
job_0_enabled=1
job_0_pending_files=0
job_0_pending_bytes=0
job_0_dest_total_kb=3906886656
job_0_dest_used_kb=2344131793
job_0_dest_avail_kb=1562754863
job_0_dest_avail_human=1.5TB
job_0_dest_used_pct=60%
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

1. Run `bash bin/status-all.sh --short` for a quick overview of all hosts
2. Look for `overall_status=` on each host — anything not `OK` needs investigation
3. For ephys7 `/mnt/f` (disabled): treat as informational, not failure

### Diagnostic triage (for any host not OK)

Work through these checks **in order** — stop once you find the root cause:

1. **Is a backup currently running?**
   - Linux: `ssh <host> 'pgrep -af backup-run.sh'`
   - WSL: `ssh <host> 'wsl.exe -e bash -lc "pgrep -af backup-run.sh"'`
   - If yes → normal, just report ETA based on pending bytes

2. **Did the last run fail?** (`last_run_result` non-zero / `last_run_status=FAILED`)
   - Read the rsync log: `ssh <host> 'cat ~/.local/state/backup-kit/last-run.log'`
   - Common causes: mount disappeared mid-run, network timeout, permission denied

3. **Are destination mounts missing?** (`job_N_status=ERROR`)
   - Linux: `ssh <host> 'mountpoint -q /phobos && echo mounted || echo NOT mounted'`
   - WSL: `ssh <host> 'wsl.exe -e bash -lc "ls /mnt/e/data 2>&1"'`
   - If missing → drive/NFS issue, report which mount

4. **Is a destination disk full?** (`job_N_dest_used_pct` near 100%)
   - Check `job_N_dest_avail_human` from status output
   - If < 50GB remaining → flag as critical

5. **Is the last run stale?** (`last_run_age_hours` > 30)
   - Check whether the scheduler is still installed:
     - Linux: `ssh <host> 'crontab -l | grep backup-kit'`
     - WSL: `ssh <host> 'schtasks.exe /Query /TN "BackupKit"'`
   - Check cron log for errors: `ssh <host> 'tail -50 ~/.local/state/backup-kit/cron.log'`
   - Common causes: cron entry removed, Task Scheduler task disabled, host was rebooted and WSL didn't restart

6. **Pending files but run was recent and successful?**
   - Likely new files created after the last 1 AM run — normal, will sync tonight

### Reporting format

For each problem host, report:
- **Host**: name
- **Symptom**: what `status-all.sh` showed (e.g., `overall=STALE age=48h`)
- **Cause**: what the triage found (e.g., "cron entry missing")
- **Fix**: what the user should do (e.g., "run `bash bin/schedule.sh setup3`")

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

**Post-backup chmod pass**:
After each successful rsync job, `backup-sync.sh` runs `make_readonly()` which sets all regular files in the destination to `444` (read-only). This prevents accidental overwrites or deletions of backed-up data.
- Only runs on clean rsync exit (exit code 0)
- Skips files already at 444 for speed on repeat runs
- Excludes `.rsync-partial/` temp dirs
- Directories are left writable so future rsync runs can still create new files
- **WSL note**: on ephys3/ephys7, `chmod 444` on NTFS volumes (`/mnt/e`, `/mnt/f`) only persists if the volume is mounted with the `metadata` option. Without it, permissions appear correct within the WSL session but reset on remount and are not enforced by Windows. This is a known NTFS/DrvFs limitation, not a script bug.

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

**Important**: Tasks must run as the local Windows account that owns the WSL2 distro,
with the `/IT` (interactive token) flag. WSL2 distros are registered per-user in `HKCU`,
not system-wide — if the task runs as `SYSTEM`, `wsl.exe` finds no distro and exits with
code -1 immediately. The `/IT` flag avoids the need to store credentials (which is blocked
by the WUSTL.EDU domain GPO that sets `LimitBlankPasswordUse = 1`). The task only fires
if the account is interactively logged in at 1 AM, which is expected on recording machines.

- **ephys3**: Windows account is `admin`
- **ephys7**: Windows account is `Toor`

```bash
# Create task (1 AM daily) — ephys3
ssh ephys3 'schtasks.exe /Create /TN "BackupKit" \
  /TR "wsl.exe -e bash -lc /home/toor/backup-kit/backup-run.sh" \
  /SC DAILY /ST 01:00 /RU admin /IT /F'

# Create task (1 AM daily) — ephys7
ssh ephys7 'schtasks.exe /Create /TN "BackupKit" \
  /TR "wsl.exe -e bash -lc /home/toor/backup-kit/backup-run.sh" \
  /SC DAILY /ST 01:00 /RU Toor /IT /F'

# Delete task
ssh ephys3 'schtasks.exe /Delete /TN "BackupKit" /F'

# Verify (check "Run As User" and "Logon Mode: Interactive only")
ssh ephys3 'schtasks.exe /Query /TN "BackupKit" /V /FO LIST'
```

---

## Cleanup Legacy Schedules

**setup7** has stale cron entries that should be removed:

```bash
ssh setup7 'crontab -l | grep -v backintime | grep -v "/ganymede\|/callisto" | crontab -'
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
