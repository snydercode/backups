# FIXME: Fleet Cutover Follow-Ups (Backup Repo)

This repo now treats `jobs.txt` as a generated artifact from Snyderverse fleet config.

What is already in place:
- `bin/render-jobs-from-fleet.py` renders `jobs.txt` from `snyderverse.fleet`.
- `Makefile` has `jobs` and `check-jobs` targets.
- `AGENTS.md` documents `fleet.yaml` as source of truth.

Remaining prescribed work (pilot-safe, non-blocking):

1. CI drift guard
- Add a CI check that runs `python3 bin/render-jobs-from-fleet.py --check`.
- Fail if committed `jobs.txt` is stale relative to fleet config.

2. Environment reproducibility
- Standardize how `snyderverse` is made importable when rendering:
  - preferred: install snyderverse in the rendering environment, or
  - fallback: document/encode required `PYTHONPATH`.

3. Ownership boundary enforcement
- Keep deploy/schedule/status paths reading committed `jobs.txt` only.
- Do not add runtime dependency on `snyderverse` for host operations.

4. Operational runbook snippet
- Add a short “when fleet changes” checklist:
  1) edit `snyderverse/config/fleet.yaml`
  2) regenerate `backup/jobs.txt`
  3) run drift check
  4) commit both repos appropriately

5. Optional hardening
- Add a small parser-compatibility smoke test that validates rendered output with `lib/jobs.sh` helpers.
- Pin expected header text/order in one test to catch accidental renderer format drift.
