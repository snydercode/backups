---
description: Run backup status check and escalate to troubleshooting when needed
model: github-copilot/gpt-4.1
---

Load the `backup-kit` skill first.

Invoke `@backup-inspector` first.

## Fast path

If `@backup-inspector` reports all hosts healthy, respond with one line:

`All backups OK.`

Nothing else.

## Non-OK path

If any host is not OK:

1. Use the full `@backup-inspector` report as the source of truth for status.
2. For each host marked `NEEDS_TROUBLESHOOTING`, invoke `@backup-troubleshooter` and pass:
   - the full inspector report
   - the specific host being diagnosed
3. Synthesize a concise operator plan:
   - What is wrong (host-by-host)
   - Most likely root cause (with evidence)
   - Exact copy-pasteable fix commands (from CLAUDE.md-safe procedures)
   - Verification commands to confirm the fix

## Rules

- Treat missing ephys7 `/mnt/f` as informational, not failure.
- Never execute mutating fix commands automatically.
- If a fix command might impact active data collection, call that out explicitly.
