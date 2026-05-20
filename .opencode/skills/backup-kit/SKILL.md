---
name: backup-kit
description: Backup-kit operational reference for host status, triage, and safe command boundaries in /home/chuck/backup.
---

# Backup-Kit Skill

Use this skill when working in `/home/chuck/backup`.

## Hosts

- `setup2` (Linux): `/data` -> `/phobos/data`, `/deimos/data`
- `setup3` (Linux): `/data` -> `/phobos/data`, `/deimos/data`
- `setup7` (Linux): `/data` -> `/phobos/data`, `/deimos/data`
- `ephys3` (Windows+WSL): `/mnt/d/data` -> `/mnt/e/data`, `/mnt/f/data`
- `ephys7` (Windows+WSL): `/mnt/d/data` -> `/mnt/e/data` only (`/mnt/f` is not present)

## Ground truth command

- Primary status command: `bash bin/status-all.sh`

## Status semantics

- `OK`: healthy and current
- `PENDING`: files waiting, last run recent
- `STALE`: files waiting, last run too old
- `ERROR`: check failed (mount/scheduler/runtime)
- `NEVER_RUN`: backup has never executed

Treat missing ephys7 `/mnt/f` as informational, not failure.
If a future host adds an `/mnt/f` destination, handle it explicitly per host config.

## Read-only diagnostic triage order

For any host not OK, check in this order and stop when root cause is clear:

1. Is a backup currently running?
2. Did the last run fail? (inspect last-run log)
3. Are destination mounts missing/unavailable?
4. Is destination disk near/full?
5. Is scheduler missing/disabled/stale?
6. If run was recent+successful, are pending files simply new data since last run?

## Command boundaries

Allowed read-only actions:

- `bash bin/status-all.sh`
- `ssh <host> ...` read-only checks/log reads

Never run without explicit user approval:

- `backup-run.sh`
- `bin/deploy*.sh`
- `bin/schedule*.sh`
- any command that edits crontab or Task Scheduler
- any command that modifies files on hosts

For fix procedures and scheduling command details, read `AGENTS.md` in this repo root.

## Reporting shape

When diagnosing, report per host:

- Symptom
- Checks run
- Most likely cause
- Evidence snippets

Do not invent fixes if evidence is incomplete.
