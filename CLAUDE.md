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
| ephys3 | Windows | toor | /mnt/d/data  | /mnt/e/data, /mnt/f/data         |
| ephys7 | Windows | toor | /mnt/d/data  | /mnt/e/data (F disabled for now) |

**Two runtimes.** The Linux hosts run `backup.sh` (bash, rsync). The Windows hosts
run `backup.ps1` (PowerShell, robocopy) natively against `D:`/`E:`/`F:` — WSL is not
in the path. `jobs.txt` still says `os=wsl` for them, which now means "this host is
Windows" and no longer describes how the backup runs; paths stay in WSL form
(`/mnt/d/data`) because the fleet renderer emits them that way, and `backup.ps1`
translates them.

Cutover status: **ephys7 native since 2026-08-19; ephys3 still on the WSL runtime.**
Every script picks the runtime per host by asking the host, so a mixed fleet is a
supported state — see `remote_has_native_windows` in `lib/remote.sh`.

**Note**: setup7's old `/ganymede` and `/callisto` mount points have been renamed to `/phobos` and `/deimos`.

---

## Repository Structure

```
backup/
  bin/
    deploy.sh          # Push runtime to one host
    deploy-all.sh      # Push runtime to all hosts
    schedule.sh        # Install backup schedule on one host
    schedule-all.sh    # Install backup schedules on all hosts
    status-all.sh      # Check status across all hosts
    render-jobs-from-fleet.py  # Regenerate jobs.txt from the fleet config
  lib/
    jobs.sh            # jobs.txt parsing helpers
    hosts.sh           # Host lookup helpers
    fleet.sh           # Shared host-loop execution helper
    remote.sh          # Linux/WSL remote dispatch helper
  backup.sh            # Unified runtime command (Linux/WSL): plan|run|status
  backup.ps1           # Same three commands, native Windows (robocopy)
  jobs.txt             # GENERATED host + job config (do not edit)
  _old/                # Archived previous scripts
  CLAUDE.md            # This file
```

### jobs.txt host config format

`jobs.txt` is a **generated artifact**. The canonical source of truth is the
snyderverse fleet config (`src/snyderverse/fleet/config/fleet.yaml` in the snyderverse repo), consumed via the
public `snyderverse.fleet` Python API. Never hand-edit `jobs.txt`; edit the
fleet config and regenerate:

```
# regenerate jobs.txt from the fleet config
python3 bin/render-jobs-from-fleet.py
# (or) make jobs

# verify jobs.txt is not stale (CI / pre-deploy guard)
python3 bin/render-jobs-from-fleet.py --check
```

The renderer requires the `snyderverse` package importable in the environment
(set `PYTHONPATH` to its repo root, or install it). Hosts are emitted in
alphabetical order; only hosts with a `backup` route in the fleet config appear.

```
[setup2]
os=linux
user=toor
src=/data
dest=/phobos/data
dest=/deimos/data

[ephys3]
os=wsl
user=toor
windows_user=admin
src=/mnt/d/data
dest=/mnt/e/data
dest=/mnt/f/data
```

`os=wsl` marks a Windows host. On one still running the WSL runtime, bin scripts wrap
commands with `wsl.exe -e bash -lc "..."`; on a cut-over host they call
`powershell.exe` directly.

**Key rule**: `bin/` scripts run from this repo. `backup.sh` is deployed to
`~/backup-kit/` on every host; on Windows hosts `backup.ps1` also goes to
`C:\backup-kit\`, and that is the copy the scheduled task runs.

### Code Map

- `backup.sh`: deployed runtime on Linux hosts; performs `plan`, `run`, and `status`
- `backup.ps1`: the same three commands on Windows hosts, native (no WSL); state
  lives in `C:\ProgramData\backup-kit`
- `bin/deploy.sh`: deploy runtime and host-scoped jobs to one host
- `bin/schedule.sh`: install schedule on one host (cron or Task Scheduler)
- `bin/status-all.sh`: collect and render status from all hosts
- `bin/deploy-all.sh`, `bin/schedule-all.sh`: fleet wrappers for one-host commands
- `lib/jobs.sh`: parse `jobs.txt` into host lists, host metadata, and `src:dest` job lines
- `bin/render-jobs-from-fleet.py`: regenerate `jobs.txt` from the snyderverse fleet config (`--check` for drift)
- `lib/hosts.sh`: shared host index lookup
- `lib/fleet.sh`: shared host iteration + failure aggregation
- `lib/remote.sh`: shared remote command dispatch, plus `remote_has_native_windows`,
  which decides a Windows host's runtime by reading its scheduled task

---

## Safe Commands (READ-ONLY)

These commands are safe for agents to run anytime:

```bash
# Check status across all hosts
bash bin/status-all.sh

# Check status on one host (picks the right runtime for you)
bash bin/status.sh setup7
bash bin/status.sh ephys7

# Same, by hand
ssh setup7 '~/backup-kit/backup.sh status'
ssh ephys7 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\backup-kit\backup.ps1 status'
ssh ephys3 'wsl.exe -e bash -lc "~/backup-kit/backup.sh status"'   # still WSL

# Preview pending changes (dry-run)
ssh setup3 '~/backup-kit/backup.sh plan'
ssh ephys7 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\backup-kit\backup.ps1 plan'
```

Use `bash bin/ssh-ro.sh <host> <command>` when you want the allowlist enforced; it
permits `type` and `dir` and a few `Get-*` cmdlets on Windows hosts.

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
ssh setup3 '~/backup-kit/backup.sh run'
ssh ephys7 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\backup-kit\backup.ps1 run'

# Fire a Windows host's scheduled task as SYSTEM, which is what 01:00 does
ssh ephys7 'schtasks.exe /Run /TN "BackupKit"'
```

On a cut-over host, do **not** run `~/backup-kit/backup.sh run` through WSL: it still
works, but it writes the WSL state file, which nothing reads any more. The run will
look like it had no effect.

---

## Status Output Format

`backup.sh status` outputs JSON for easy parsing:

```json
{
  "schema_version": 1,
  "generated_at": "2026-05-27T14:45:00Z",
  "host": "setup3",
  "last_run": {
    "date": "2026-05-27 01:00:01",
    "age_hours": 8,
    "result": 0,
    "status": "OK"
  },
  "overall_status": "OK",
  "jobs": [
    {
      "src": "/data",
      "dest": "/phobos/data",
      "enabled": 1,
      "pending_files": 0,
      "pending_bytes": 0,
      "status": "OK"
    }
  ],
  "errors": []
}
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

1. Run `bash bin/status-all.sh` for a quick overview of all hosts
2. Look for `overall_status=` on each host — anything not `OK` needs investigation
3. For ephys7 `/mnt/f` (disabled): treat as informational, not failure

### Diagnostic triage (for any host not OK)

Work through these checks **in order** — stop once you find the root cause.

**First, know which runtime the host is on.** A Windows host whose scheduled task
names `backup.ps1` is native; anything else is still WSL. State is in a different
place for each:

```bash
bash bin/ssh-ro.sh <host> 'schtasks.exe /Query /TN "BackupKit" /V /FO LIST'
```

Read `Task To Run`: `powershell.exe ... backup.ps1` is native, `wsl.exe ...` is not.

| | Linux | Windows, native | Windows, WSL |
|---|---|---|---|
| log | `~/.local/state/backup-kit/last-run.log` | `C:\ProgramData\backup-kit\last-run.log` | `~/.local/state/backup-kit/last-run.log` |
| state | `~/.local/state/backup-kit/last-run.txt` | `C:\ProgramData\backup-kit\last-run.txt` | same as Linux |
| scheduler | cron | Task Scheduler, `BackupKit`, as SYSTEM | Task Scheduler, `BackupKit`, `/IT` |

1. **Is a backup currently running?**
   - Linux: `ssh <host> 'pgrep -af "backup.sh run"'`
   - Windows, native: `ssh <host> 'schtasks.exe /Query /TN "BackupKit"'` — Status
     reads `Running` rather than `Ready`
   - Windows, WSL: `ssh <host> 'wsl.exe -e bash -lc "pgrep -af \"backup.sh run\""'`
   - If yes → normal, just report ETA based on pending bytes

2. **Did the last run fail?** (`last_run_result` non-zero / `last_run_status=FAILED`)
   - Linux and WSL: `bash bin/ssh-ro.sh <host> 'cat ~/.local/state/backup-kit/last-run.log'`
   - Windows, native: `bash bin/ssh-ro.sh <host> 'type C:\ProgramData\backup-kit\last-run.log'`
   - Common causes: mount disappeared mid-run, network timeout, permission denied.
     On Windows also check `Last Result` on the task itself — a non-zero there with
     no log at all means the task could not start the script.

3. **Are destinations missing?** (`job_N_status=ERROR`)
   - Linux: `ssh <host> 'mountpoint -q /phobos && echo mounted || echo NOT mounted'`
   - Windows, native: `ssh <host> 'dir E:\data'` — the runtime requires the
     destination *directory*, not just the drive letter, so a reformatted disk that
     comes back as an empty `E:` reports ERROR rather than copying into it
   - Windows, WSL: `ssh <host> 'wsl.exe -e bash -lc "ls /mnt/e/data"'`
   - If missing → drive/NFS issue, report which one

4. **Is a destination disk full?** (`job_N_dest_used_pct` near 100%)
   - Check `job_N_dest_avail_human` from status output
   - If < 50GB remaining → flag as critical

5. **Is the last run stale?** (`last_run_age_hours` > 30)
   - Linux: `ssh <host> 'crontab -l | grep backup-kit'`, then
     `ssh <host> 'tail -50 ~/.local/state/backup-kit/cron.log'`
   - Windows: `ssh <host> 'schtasks.exe /Query /TN "BackupKit" /V /FO LIST'` and read
     three fields — `Last Run Time`, `Last Result`, and `Logon Mode`. **`Logon Mode:
     Interactive only` means the task fires only when that account is logged in at
     01:00**; that is the pre-2026-08-19 configuration and it is why ephys7 once went
     36 missed runs without anyone noticing. A native task reads
     `Interactive/Background` and `Run As User: SYSTEM`.
   - `bash bin/ssh-ro.sh <host> 'powershell.exe -NoProfile -Command "Get-ScheduledTaskInfo -TaskName BackupKit"'`
     counts the skipped firings directly (`NumberOfMissedRuns`). No pipe — the
     read-only wrapper rejects one.
   - Common causes: cron entry removed, task disabled, task still on `/IT`, host
     rebooted

6. **Pending files but run was recent and successful?**
   - Likely new files created after the last 1 AM run — normal, will sync tonight.
     Both runtimes exclude files written today from `pending_files`, so a non-zero
     count here means files from *yesterday or earlier* are still unbacked-up.

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
After each successful rsync job, `backup.sh run` runs `make_readonly()` which sets all regular files in the destination to `444` (read-only). This prevents accidental overwrites or deletions of backed-up data.
- Only runs on clean rsync exit (exit code 0)
- Skips files already at 444 for speed on repeat runs
- Excludes `.rsync-partial/` temp dirs
- Directories are left writable so future rsync runs can still create new files
- **WSL note**: `chmod 444` on NTFS volumes from inside WSL only persists if the volume is mounted with the `metadata` option; without it permissions can appear correct in the WSL session and not be enforced by Windows. Measured on 2026-08-19, though, every destination file on both hosts *does* carry the Windows read-only attribute — ephys7 `E:` 10,192 of 10,192, ephys3 `E:` 14,536 of 14,536 and `F:` 14,454 of 14,454.

### Windows hosts: robocopy

`backup.ps1 run` uses the same policy with different tools:

```
/E /XN /XO           # recurse; skip files newer or older at the destination
/Z                   # restartable copies
/COPY:DAT /DCOPY:T   # data, attributes, timestamps
/R:1 /W:5            # one retry, 5s apart
```

**NOT used**: `/MIR`, `/PURGE` (nothing is ever deleted from a destination).

`/XC` is deliberately absent. robocopy has no equivalent of rsync's `--partial-dir`,
so an interrupted run leaves a truncated file under its final name; that file is
robocopy's "changed" class, which `/XC` would exclude and freeze permanently.
Without `/XC` the next run repairs it.

**Post-backup read-only pass**: `Set-DestReadOnly` sets `attrib +R` instead of
`chmod 444`, which Windows does enforce. It skips files already read-only, and it
leaves a file *writable* when its size disagrees with the source — that file is a
truncated copy, and marking it read-only would prevent the repair above.

---

## Scheduling

### Linux (cron)

```bash
# Install cron job (1 AM daily)
ssh setup3 '(crontab -l 2>/dev/null | grep -v backup-kit; \
  echo "0 1 * * * /home/toor/backup-kit/backup.sh run >> ~/.local/state/backup-kit/cron.log 2>&1") | crontab -'

# Remove cron job
ssh setup3 '(crontab -l 2>/dev/null | grep -v backup-kit) | crontab -'

# Verify
ssh setup3 'crontab -l | grep backup-kit'
```

### Windows (Task Scheduler, as SYSTEM)

The task runs `backup.ps1` natively, so it runs as `SYSTEM`: no stored password, no
logged-in user, and it fires whether or not anyone is at the machine.

```bash
bash bin/schedule.sh ephys7        # install (idempotent)

# what it runs
ssh ephys7 'schtasks.exe /Create /TN "BackupKit" \
  /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\backup-kit\backup.ps1 run" \
  /SC DAILY /ST 01:00 /RU SYSTEM /F'

# delete
ssh ephys7 'schtasks.exe /Delete /TN "BackupKit" /F'

# verify — Logon Mode must read "Interactive/Background", NOT "Interactive only"
ssh ephys7 'schtasks.exe /Query /TN "BackupKit" /V /FO LIST'
```

**Why not WSL, and why this matters.** WSL2 registers distros per-user in `HKCU`, so
a task running as `SYSTEM` finds no distro and exits `-1`. The old task worked around
that by running as the distro-owning account with `/IT` (interactive token), which
avoids storing a credential — blocked here by the WUSTL.EDU domain GPO — but only
fires when that account is interactively logged in at 01:00. It silently did not
fire for 36 scheduled runs on ephys7. Taking WSL out of the path removes the
constraint that forced `/IT`.

`windows_user` in `jobs.txt` is a leftover of that arrangement. The native task does
not use it.

### Windows (legacy, WSL) — ephys3 until it is cut over

The `/RU` account differs per host — it is `windows_user` in `jobs.txt`, and using
the wrong one silently installs a task that can never run:

```bash
# ephys3
ssh ephys3 'schtasks.exe /Create /TN "BackupKit" \
  /TR "wsl.exe -u toor -e bash -lc /home/toor/backup-kit/backup.sh run" \
  /SC DAILY /ST 01:00 /RU admin /IT /F'

# ephys7
ssh ephys7 'schtasks.exe /Create /TN "BackupKit" \
  /TR "wsl.exe -u toor -e bash -lc /home/toor/backup-kit/backup.sh run" \
  /SC DAILY /ST 01:00 /RU Toor /IT /F'
```

Cutting a host over is two commands, and the order matters — status follows the
scheduled task, so the host keeps reporting from WSL until the task changes:

```bash
bash bin/deploy.sh ephys3      # puts backup.ps1 on C:\, seeds the native state file
bash bin/schedule.sh ephys3    # replaces the task; this is the cutover
```

Rolling back is the same two steps in reverse: reinstall the WSL task with the
matching command above — `/RU admin` on ephys3, `/RU Toor` on ephys7 — then delete
`C:\backup-kit\backup.ps1`. Reinstalling the WSL task flips reporting back to a
state file frozen at cutover, so expect one stale-looking day until the first WSL
run writes it again.

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

Linux hosts, and Windows hosts still on the WSL runtime:

```
~/backup-kit/
  backup.sh
  jobs.txt

~/.local/state/backup-kit/
  last-run.log         # rsync output from the last run
  last-run.txt         # machine-readable last-run metadata
  cron.log             # scheduler output (Linux)
```

Windows hosts on the native runtime:

```
C:\backup-kit\
  backup.ps1
  jobs.txt             # host-scoped, still in WSL path form

C:\ProgramData\backup-kit\
  last-run.log         # robocopy output from the last run
  last-run.txt         # same key=value format as the Linux runtime
```

A cut-over host keeps its WSL copies. They are the rollback path, and nothing reads
them while the native task is installed.

---

## SSH Notes

- All hosts use port 1840 (configured in ~/.ssh/config)
- Use `BatchMode=yes` for automation
- WSL hosts: prefix commands with `wsl.exe -e bash -lc "..."`

---

## Rollback

To revert one Windows host from the native runtime, see the two commands at the end
of § Scheduling — reinstall the WSL task first, then delete `C:\backup-kit\backup.ps1`.
Deleting the script alone leaves the task pointing at a file that is not there.

To revert to the pre-backup-kit system:

1. Old scripts are preserved in `_old/` directory
2. Old deployed scripts on hosts were at `~/.local/bin/backup`
3. Old cron/Task Scheduler entries may still exist (check per host)

To restore old system:
```bash
# Re-deploy old script
scp _old/backup.sh setup3:~/.local/bin/backup
ssh setup3 'chmod +x ~/.local/bin/backup'
```
