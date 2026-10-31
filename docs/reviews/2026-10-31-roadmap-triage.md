# backups ROADMAP.md triage (2026-10-31)

Base: `origin/main:ROADMAP.md` (731 lines, 43 open items) plus the 2 items `fix/check-triage-quoting` adds (cited as `br:5`, `br:20`, branch line numbers). 45 items in all.

| Verdict | Rows | Items covered |
|---|---|---|
| DONE | 3 | 3 |
| DROP | 15 | 15 |
| FIXME | 13 | 14 (284 and 295 merged) |
| TASK | 6 | 13 (merged) |

Outcome: the FIXMEs were placed on chore/roadmap-to-todoist (branched from fix/check-triage-quoting, so at branch lines) in 428da4f, and the six tasks were filed in Todoist's Lab 🔬 › backups project.

Notes that apply across rows:

- The branch moves most of `bin/report.sh` into a new `lib/render.sh`. For report-side FIXMEs I give the origin/main site and the branch site. Place them after the branch merges, or they will conflict.
- `~/backup` on quintana is checked out on `fix/check-triage-quoting`, and cron runs from that working tree, so the branch code is what runs in production today.
- Two existing comments point into ROADMAP and need rewording when it goes: `backup.sh:127-129` (row 48 below) and `backup.ps1:133` ("see the FIXME at backup.sh:127", which still resolves).
- Out of scope but same cleanup: the repo root also has `FIXME.md` (fleet-cutover follow-ups) and `TODO` (one line: "have status ignore files from today"). That line looks done: `backup.sh:260` and `backup.ps1:283` both default the cutoff to today.

## DONE

| Line(s) | Item | Evidence |
|---|---|---|
| br:20 | ephys3 destinations at 94-95% | Capacity changed. `~/.local/state/backup-kit-check/run-20261031-080001/fleet.json` on quintana: ephys3 `/mnt/e/data` and `/mnt/f/data` are both at 19% used with 14.8TB free. |
| 306 | Malformed `fleet.json` reads as "no fleet snapshot" | Restored: `bin/report.sh:372-373` prints `(could not parse $latest_fleet)` when jq yields no rows. On the branch it is `lib/render.sh:229-230`. |
| 543 | `deploy_seed_native_state` writes a fixed `/tmp` path | Gone from `bin/deploy.sh`. Its successor `seed_native_state` (`bin/schedule.sh:76-78`) uses `mktemp -d` with a RETURN trap. |

## DROP

| Line(s) | Item | Why |
|---|---|---|
| 5 | Keep or revert generated jobs.txt (Chuck, 2026-10-31: keep) | The trigger was "revisit if it causes friction". It hasn't in 12 weeks, and leaving it alone keeps the pipeline. Dropping this item settles the decision as "keep". |
| 129 | `cron.log` grows unbounded | 229 lines and 22 KB after 12 weeks (`~/.local/state/backup-kit-check/cron.log`), so roughly 90 KB a year. |
| 138 | Polish batch (check.sh/gate-test minors) | The one robustness item is fixed: the tab strip is at `bin/check.sh:124`. What's left is readability nits plus the `--check-only` rc 2→1 collapse (`:144-145`), which only changes `make check`'s exit code. |
| 188 | jobs.txt separator vs Windows paths | jobs.txt is generated, and the renderer emits WSL-form paths. A hand-written `C:\` line never happens. |
| 300 | `--days 0` emits all-clear | Only reachable by hand. The cron line uses the default of 7. |
| 326 | `make report` makes a network call | It still prints rather than emails. The claude call is the only side effect, and it runs only when there are actions. |
| 330 | Non-ASCII subject, no RFC 2047 | Em-dash subjects have gone out every Monday since August (`cron.log:149-219`, all "sent"). The mailer declares `charset=UTF-8` (`~/scripts/email:99`). The branch's daily FAIL mail now uses the same `render_subject`, so the two conventions no longer diverge. |
| 337 | `dest_total_kb` absent → "0GB total" in prompt | Affects only the model's prompt (`report.sh:407`). The gate already raises DISK_UNKNOWN on the action list. |
| 344 | `age_hours=-1` renders "unknown" | The gate emits NEVER_RUN for that host, so the action list already says "never backed up". Only the table cell is vague. |
| 350 | `NONE` suppression is an exact match | Cosmetic: the worst case is a SUMMARY/WHY heading over the word "NONE." |
| 367 | Two claude calls overlap on a failing Monday | Two independent `claude -p` processes do not interfere with each other. The overlap costs only load. |
| 549 | Source tree walked per job/status call (unsure) | Measured at 1.4 s and about 15 s against the 600 s collect cap. The trees would have to grow about 40x. |
| 558 | Windows `.host` differs from WSL hostname | Cosmetic: only `make status` prints `.host`. Every consumer keys on `.fleet_host`. |
| 579 | Three copies of `if exist`; `$script:RunExitCode` | The idiom half is moot: `remote_has_native_windows` is gone (`lib/remote.sh:44-54` probes the task's `/TR` now) and deploy.sh's copy is gone, which leaves one at `bin/schedule.sh:156`. The `RunExitCode` half is a style choice its comment explains (`backup.ps1:51-55`). |
| 698 | `-Before` shape-only validation, culture-dependent cutoff | Only a manual `--before` reaches it. A non-Gregorian current culture on the lab hosts is not plausible. |

## FIXME

All target files are bash or PowerShell, so the comment syntax is `#` throughout. "Line" is the origin/main line the comment goes above.

| Roadmap | Item | File:line (origin/main) | Comment text |
|---|---|---|---|
| 48 | `run_plan_one` swallows rsync dry-run failures | `backup.sh:127` (exists; reword lines 127-129) | `# FIXME: rsync rc unchecked; a failed dry-run parses as pending 0, status OK. Make non-zero rc job_status=ERROR with rsync's first stderr line.` |
| 114 | `dest_total_kb: 0` disables the disk check (unsure) | `lib/gate.sh:163` (inside the jq program; `#` is a jq comment too) | `# FIXME: dest_total_kb == 0 makes the threshold 0, so a dead mount reporting zeros passes; treat total or avail == 0 as DISK_UNKNOWN.` |
| 133 | `jobs_emit_host_jobs` failure swallowed | `lib/gate.sh:68` | `# FIXME: helper rc is discarded; a malformed jobs.txt silently shrinks the expected-job set and weakens MISSING_JOB. Emit CONFIG_MISMATCH on failure.` |
| 170 | backup.sh records only the last job's result | `backup.sh:180` | `# FIXME: written per job, so a later clean dest overwrites an earlier failure; the gate reads this field. Write once in run_for_all_jobs with the worst rc.` |
| 179 | Timestamp-skewed truncation invisible (unsure) | `backup.ps1:455` | `# FIXME: left-writable (size-mismatched) files never reach status JSON, and /XO keeps one with a newer mtime from ever being repaired; emit a count and gate on it.` |
| 284, 295 | report.sh claude call lacks guardrails; `timeout` without `-k` | `bin/report.sh:194` (branch: `bin/report.sh:122`) | `# FIXME: unlike check.sh's triage call: no --allowedTools "", stderr discarded, no log on rc, no injection-defense line, and no timeout -k.` |
| 313 | Five gate codes fall through to raw jargon | `bin/report.sh:136` (branch: `lib/render.sh:93`) | `# FIXME: STATUS_ERROR, UNRECOGNIZED_STATUS, UNRECOGNIZED_JOB_STATUS, DISK_UNKNOWN, MALFORMED_FIELD land here as raw codes; give each an arm.` |
| 319 | gate prose is a parsed contract with no test | `bin/report.sh:103` (branch: `lib/render.sh:48`) | `# FIXME: strips lib/gate.sh's exact DISK_LOW and STALE_IDLE wording; no test pins it. Add a render test fed real gate_evaluate output.` |
| 526 | Schedule verification matches the label, not the value | `bin/schedule.sh:128` | `# FIXME: grep passes on "Interactive only" too, and fails on non-English labels; assert the Logon Mode value and fire the task once to check Last Result.` |
| 535 | Robocopy summary parse fails open | `backup.ps1:173` | `# FIXME: a count wide enough to merge columns leaves 0 pending with rc 1; treat (rc -band 1) with a parsed zero as an error.` Partly fixed already: a missing summary block, including a non-English one, now errors at `:155`. |
| 707 | ssh-ro allowlist admits unbounded/off-host reads | `bin/ssh-ro.sh:34` | `# FIXME: type/dir/Get-Content accept UNC paths (outbound SMB auth) and -Wait or recursive forms block to the 1800 s triage timeout; reject a leading \\ and -Wait.` |
| 718 | One throw abandons the remaining destinations | `backup.ps1:509` | `# FIXME: try wraps the whole loop, so a throw on E: skips F:; move it inside the loop and name the job in the catch.` |
| br:5 | Failed summary comment blocks the task completion (unsure: reorders the dead-man contract) | `bin/check.sh:183` (branch: `bin/check.sh:191`) | `# FIXME: comment failure exits before the completion, so a flaky API (502, 2026-08-24) turns a PASS into an overdue task; complete first, then comment.` |

## TASK

| Roadmap | Title | Description |
|---|---|---|
| 120, 371, 726 | Bring CLAUDE.md and the project memory note up to date | The triage checklist in CLAUDE.md (main `:251-270`) still keys on flat names no producer emits (`last_run_result`, `job_N_status`, `job_N_dest_used_pct`, `last_run_age_hours`). The real fields are `jobs[].status` and `last_run.age_hours`. The Status Output Format section still lists `UP_TO_DATE` and `STALE` (`:208-210`). The branch's triage prompt still sends the FAIL-path agent to that checklist. Separately, `~/.claude/projects/-home-chuck-backup/memory/weekly-backup-check.md` still describes report sections that are gone ("per-run verdicts, days with no run, latest fleet snapshot") and the pre-SYSTEM ephys7 stall. |
| 162, 502, 508 | Retire the WSL runtime path now that both Windows hosts are native? | Both Windows hosts went native on 2026-08-20. Even so, `bin/deploy.sh:121-135` still pushes `backup.sh` and a WSL jobs.txt to them, and `bin/status.sh:162` pays a schtasks probe per Windows host. The remnants are dead: `windows_user` hard-exits scheduling (`bin/schedule.sh:145-148`, `bin/deploy.sh:102-105`) but nothing reads it, and `bin/schedule-all.sh:36` tells the operator to run `~/backup-kit/backup.sh run`, which writes a state file nobody reads. The decision is whether cheap per-host rollback is still worth carrying the dual path. Dropping it removes the probe, the dual deploy, `seed_native_state`, and the `os=wsl` ambiguity, which also touches the snyderverse fleet schema. |
| 56, 375 (unsure) | Decide stale-host policy: cap STALE_IDLE, stop asserting "scheduler dead" | STALE_IDLE is informational forever (`lib/gate.sh:29`), so a host stale for six months reads like one stale for 49 h. Any cap must exceed ephys7's idle gaps between recording blocks, which can last months. Separately, the gate and render strings assert "scheduler dead" (`lib/gate.sh:134`, `bin/report.sh:109,151`; branch `lib/render.sh:54,108`), but nothing queries the scheduler. The 2026-08 cases were interactive-only tasks with a healthy scheduler. The SYSTEM cutover removed that cause, which makes both changes lower-stakes than when they were filed. |
| 354, 572 (unsure) | Delete the legacy 4-field findings code from the report path | The 4-field findings format has not been written since 2026-08-06. The oldest kept run dir is `run-20260916-*`, so it can never re-enter the window. It is still parsed in `dedup_findings` (branch `bin/report.sh:141,145`) and `_action_desc_body` (branch `lib/render.sh:38-49`, the legacy paren strip at `:49`). The branch already cleared most of the rest of the spartan batch: `ACTION_CMD` is no longer a global (`render.sh:30-34`), and `MAX_ACTIONS` and the header widths live in one place each. Left over: `known_desc`, the two jq reads of the same fleet.json, and the unused `.overall_status`. Do it after the branch merges. |
| 520 | Add a backup.ps1 status capture as a second gate fixture | `test/fixtures/healthy.json` is the only fixture, and it is a backup.sh capture. That is still true on the branch, whose new tests (prompt, render, status-schema) take no native payload. Two of five hosts now emit backup.ps1 JSON, so `make test` proves nothing about it. Capture a real `backup.ps1 status` from ephys7 and run the gate cases over it. |
| 565, 513 (unsure) | Move the Windows runtime from C:\backup-kit to ProgramData? | The deploy account creates and fills `C:\backup-kit` over SSH (`bin/deploy.sh:142-144`), and a SYSTEM task runs it with `-ExecutionPolicy Bypass` (`bin/schedule.sh:119`). If that account is not a local admin, this is a privilege-escalation path. First check whether `toor`/`Toor` are local admins on ephys3 and ephys7, because if they are, the item is moot. If it does move, change the scp targets with it: they are hardcoded as `C:/backup-kit/...` (`deploy.sh:143-144`, plus `C:/ProgramData/...` at `schedule.sh:95`), while the probes use `$WIN_KIT_DIR`/`$WIN_STATE_DIR` (`lib/remote.sh:7-8`). |
