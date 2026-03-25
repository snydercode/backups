---
description: Run backup health inspection only
model: github-copilot/gpt-4.1
---

Load the `backup-kit` skill first.

Invoke `@backup-inspector`.

If all hosts are healthy, respond with:

`All backups OK.`

Otherwise return the inspector report exactly, with no extra analysis.
