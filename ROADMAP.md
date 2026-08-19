# Roadmap

## Open decisions

- [ ] **Keep or revert the generated-jobs.txt pipeline** (2026-08-06)
      jobs.txt is generated from the snyderverse fleet config
      (`bin/render-jobs-from-fleet.py`, commits around e15cf9c). Spartan
      review recommended reverting to a hand-edited jobs.txt: one consumer,
      cross-repo dependency, and the renderer is more machinery than five
      host blocks warrant. Counter-position (Claude): the fleet config is
      already the single source of truth for host facts across repos, and
      the `--check` drift guard plus CONFIG_MISMATCH make the pipeline
      cheap to trust. Undecided — revisit if the renderer or the snyderverse
      dependency causes friction; reverting is easy (commit the current
      jobs.txt, delete the renderer and Makefile hook).

## Review findings — STALE_IDLE downgrade, feat/stale-idle-gate (2026-08-06)

**Context:** Pre-merge adversarial review of the stale-but-idle gate change
(d98b951) via @skeptic, @spartan, @side-effect-tracer, and @code-reviewer.
Every finding below was verified by reproduction against the branch gate
before filing; 0 raw findings dropped. The skeptic's rsync-version concern
was resolved by checking all 5 hosts live (all ≥ 3.1.1, modern stats line).

### Before merge

- [x] **Idle proof accepted defaulted evidence (3 fail-open holes)** — `lib/gate.sh`
      **Why it's an issue:** ERROR jobs, missing `pending_bytes`, and
      stringified `age_hours` all passed the "provably idle" proof, so a stale
      host with a dead mount plus an acked JOB_ERROR returned rc 0 forever —
      an ack un-monitoring a host, which the ack design explicitly forbids.
      **Fix applied (1d592b2):** idle requires numeric age ≥ 0, jobs listed,
      every job `status == "OK"` with both pending counters strictly numeric
      zero; 6 regression tests including the acked-JOB_ERROR trap.
- [x] **Broken source reads as idle** — `lib/gate.sh` / `backup.sh:127-138`
      **Why it's an issue:** `run_plan_one` never checks the rsync dry-run's
      exit code and defaults `pending_files` to 0 with `status=OK`, so a host
      whose source disk vanished (the ephys7 reboot scenario: same reboot
      kills scheduler and D: mount) would report "provably idle, no data at
      risk". Reproduced by the skeptic end-to-end.
      **Fix applied:** idle proof additionally requires per-job
      `src_last_file_epoch` numeric and > 0 — positive evidence the source
      was readable and non-empty (backup.sh emits -1 when it can't stat any
      source file). 2 regression tests.

### Deferred

- [ ] **`run_plan_one` swallows rsync dry-run failures** — `backup.sh:127-138`
      **Why it's an issue:** rsync rc is unchecked; on failure the stats parse
      yields `pending_files=0, status=OK` — a measurement that is really a
      default. The gate now defends itself via `src_last_file_epoch`, but the
      producer is still lying to every other consumer of status output.
      **Proposed fix:** capture rsync's rc in `run_plan_one`; non-zero →
      `job_status=ERROR` with the first stderr line. Producer change deployed
      to all 5 hosts — land with the next deploy batch, with fixture updates.
- [ ] **STALE_IDLE never escalates** — `lib/gate.sh`
      **Why it's an issue:** a host stale 6 months renders identically to one
      stale 49h; if any future proof bug appears, "quiet forever" is reachable.
      A cap (idle beyond N days FAILs regardless) bounds the blast radius.
      Deliberately deferred as a policy decision: ephys7 legitimately idles
      for months between recording blocks, so any cap must exceed that.
      **Proposed fix:** decide a ceiling (e.g. 90d) or explicitly accept none.

## Review findings — weekly backup check, feat/weekly-check (2026-08-06)

**Context:** Pre-merge adversarial review of the automated weekly backup health
check (commits 7bab1a9, 671bdbe) via @skeptic, @spartan, @side-effect-tracer,
and @code-reviewer, findings verified against the code before filing (the
critical one reproduced live). 0 raw findings dropped as unverified; two were
downgraded with evidence (deployed status vocabulary confirmed current via live
fleet capture; jq null-concatenation triggers ruled out — null is identity for
`+` — narrowing the fail-open to type/arithmetic errors, which reproduce).

### Before merge

- [x] **Gate fails open on jq runtime error** — `lib/gate.sh:61`
      **Why it's an issue:** the jq program's exit status is unchecked; a
      runtime error (reproduced: string-typed `dest_avail_kb` from one host)
      aborts it with zero findings → rc 0 → PASS → the dead-man task is
      completed on data the gate never evaluated. Inverts the core invariant.
      **Proposed fix:** capture jq's rc; on non-zero emit
      `FAIL - RUNNER_FAILURE <msg>` and return 2. Add a fixture test.
- [x] **Triage agent's `Bash(ssh:*)` grant is not read-only** — `bin/weekly-check.sh:199`
      **Why it's an issue:** permits `ssh host '<anything>'` (writes, crontab
      edits) on all fleet hosts while the prompt embeds remote-originated
      strings (gate details, remote logs) — prompt-injection surface with
      write-capable tools; "read-only" exists only as prose.
      **Proposed fix:** route remote access through a `bin/ssh-ro.sh` wrapper
      that allowlists read-only command prefixes and rejects shell
      metacharacters; grant `Bash(bash bin/ssh-ro.sh:*)` instead of `Bash(ssh:*)`.
- [x] **PASS re-run double-advances the recurrence** — `bin/weekly-check.sh:159`
      **Why it's an issue:** completing a recurring Todoist task always consumes
      one occurrence (verified semantics), so a manual re-run on a PASS day
      pushes the due date out an extra week — the overdue alarm then lags a
      week, exactly the silence-looks-OK window the design forbids.
      **Proposed fix:** before completing, read the task's due date and skip
      completion (log it) when due is already in the future.
- [x] **Ack machinery: dropped key column, wrong documented key, regex
      over-match, host-level codes ackable** — `lib/gate.sh:149-171`, `check-ack.txt`
      **Why it's an issue:** (a) the `key` needed to write an ack is consumed
      internally and never shown, and check-ack.txt documents the wrong key for
      MISSING_JOB (`dest` vs actual `src:dest`) — docs-conformant acks never
      match, refailing weekly; (b) unescaped fields interpolated into an ERE
      can over-match and wrongly suppress a *real* finding (fail-unsafe); (c)
      acking a host-level code like DISCONNECTED un-monitors an entire host
      indefinitely while the task keeps completing.
      **Proposed fix:** emit one 5-field TSV (`status host code key detail`)
      end-to-end so acks are copy-paste of fields 2-4; match acks with awk
      exact-field equality, no regex; restrict ackable codes to job-level
      (DISK_LOW, JOB_ERROR, MISSING_JOB, DISK_UNKNOWN); fix check-ack.txt docs.

### Deferred

- [ ] **`dest_total_kb: 0` disables the disk check** — `lib/gate.sh:124-128`
      **Why it's an issue:** a dead-but-mounted filesystem reporting zeros gets
      threshold 0 and `0 < 0` never fires; DISK_UNKNOWN doesn't fire either
      (avail is non-null). Exotic df output, but silently green.
      **Proposed fix:** treat `dest_total_kb == 0 or dest_avail_kb == 0` as
      DISK_UNKNOWN.
- [ ] **CLAUDE.md is stale where it is now load-bearing** — `CLAUDE.md:171-215`
      **Why it's an issue:** the FAIL-path triage prompt tells an automated
      agent to follow the CLAUDE.md triage checklist, which references obsolete
      flat field names (`last_run_result`, `job_N_status`, …) and status values
      (`UP_TO_DATE`, `STALE`) that the runtime no longer emits; `fleet_host`
      and the "match on fleet_host, never host" rule are undocumented.
      **Proposed fix:** update the Status Output Format + triage sections; fold
      in the health-check surface (script, gate, ack file, tests, Makefile
      targets). Entangled with uncommitted fleet-cutover edits — land with them.
- [ ] **`cron.log` grows unbounded in STATE_DIR** — `bin/check.sh:134`
      **Why it's an issue:** the `run-*/` prune glob never touches it; daily
      check + weekly report append forever (worse now that the check is daily).
      **Proposed fix:** truncate to the last ~500 lines during the prune step.
- [ ] **`jobs_emit_host_jobs` failure swallowed in expected-jobs pipeline** — `lib/gate.sh:52-57`
      **Why it's an issue:** a malformed jobs.txt shrinks the expected-job set
      without tripping CONFIG_MISMATCH (which only counts hosts), silently
      weakening MISSING_JOB.
      **Proposed fix:** propagate the helper's rc into a CONFIG_MISMATCH finding.
- [ ] **Polish batch (spartan/code-reviewer minors)** — `bin/check.sh`
      (formerly `bin/weekly-check.sh`), `test/gate-test.sh`
      **Why it's an issue:** readability/robustness drift, no behavior bugs:
      check-only's bare `exit` rides the preceding `[[ ]]` and collapses gate
      rc 2 into 1; synthesized RUNNER_FAILURE line doesn't strip tabs from
      stderr text; `NO_FAILURES` test-DSL case is redundant with rc 0;
      3-process-per-host jq pipeline; help text inlined instead of the house
      `usage()` idiom; `send_email`'s unused return scaffolding.
      **Proposed fix:** apply as one cleanup pass alongside the ack-schema change.
- [ ] **backup.ps1 is not wired into deploy or scheduling** — `backup.ps1`, `bin/deploy.sh`, `bin/schedule.sh`
      **Why it's an issue:** plan, run and status all work. Verified 2026-08-19:
      status output on ephys3 is byte-identical to the WSL runtime's whole
      `jobs` array and drives `gate_evaluate` to identical findings; run copies,
      sets read-only, and writes `last-run.txt` in backup.sh's format; a
      truncated destination file is repaired on the next run. All of it against
      temp fixtures. No host deploys it, nothing schedules it, and it has never
      run against real data.
      **Proposed fix:** add a Windows route to `bin/deploy.sh` (copy to
      `C:\backup-kit\`, no WSL), have `bin/schedule.sh` create the task with
      `/RU SYSTEM` and no `/IT`, and at cutover seed
      `C:\ProgramData\backup-kit\last-run.txt` from the host's WSL
      `~/.local/state/backup-kit/last-run.txt` — without it the first status
      reports NEVER_RUN and the gate fails a healthy host. Run `plan` before the
      first `run`: it must report 0 pending, which proves no existing
      destination file is about to be rewritten.
- [ ] **backup.sh records only the last job's result in last-run.txt** — `backup.sh:180`
      **Why it's an issue:** `run_backup_one` writes the result file at the end
      of every job, so on a two-destination host the second job's exit code
      overwrites the first's. A failed `/phobos` followed by a clean `/deimos`
      leaves `last_run_result=0`, and lib/gate.sh reads exactly that field, so
      the host reports OK. `run_for_all_jobs` does return the aggregate, but
      only cron.log ever sees it. backup.ps1 writes once with the worst result.
      **Proposed fix:** move the `last-run.txt` write out of `run_backup_one`
      into `run_for_all_jobs`, recording the worst exit code across jobs.
- [ ] **A timestamp-skewed truncation is invisible to plan and status** — `backup.ps1`
      **Why it's an issue:** a destination file that is short AND carries a
      timestamp newer than its source is excluded by `/XO`, so robocopy never
      repairs it and `pending_files` stays 0. `Set-DestReadOnly` does detect it,
      leaves it writable, and logs "left writable, size differs from source",
      but nothing surfaces that in the status JSON, so the gate cannot see it.
      Verified as a real behaviour on ephys7, 2026-08-19.
      **Proposed fix:** count the left-writable files during the read-only pass
      and emit the total as a job field, then add a gate rule for non-zero.
- [ ] **jobs.txt has no separator that survives Windows paths** — `backup.ps1`, `lib/jobs.sh`
      **Why it's an issue:** job lines are `src:dest`, and `C:\data` contains
      the separator. Harmless today because the fleet renderer emits WSL-form
      paths (`/mnt/d/data`) and backup.ps1 translates them, but a hand-written
      Windows path splits into `C` and `\data` and surfaces as a JOB_ERROR
      with a confusing message rather than a config error.
      **Proposed fix:** reject a job line whose first field is a single letter,
      with an explicit "use WSL-form paths in jobs.txt" error.
