# ephys3 offline — since 2026-08-25

Task-scoped. Delete this file once ephys3 is back and the daily check is green.

**Status: needs someone at the machine.** Remote diagnosis is exhausted.

## What happened

The 08:00 check on 2026-08-25 failed with
`STATUS_ERROR: could not determine the backup runtime on ephys3`.
It never reached the host, so this is a reachability failure, not a backup failure.

The 08:00 check on 2026-08-26 failed the same way, and a manual ssh at 11:45 the
same day still got nowhere: `oephys3.dhcp.wustl.edu` does not resolve, and the
proxy jump closes the connection. Two days dark is no longer transient.

## Already ruled out — don't redo this

- No DNS record for the host under any spelling (`oephys3.dhcp.wustl.edu`,
  `ephys3.dhcp.wustl.edu`, `ephys3`, `oephys3`), from this machine or from eye-hand.
  Rechecked 2026-08-26; still nothing.
- No ARP entry on eye-hand.
- A port-1840 sweep of eye-hand's subnet neighbours answers for setup2, setup3,
  setup7, ephys7, quintana and conception. Nothing answers as ephys3.

A lapsed dynamic-DNS name plus a vanished ARP entry means the host has been off
the wire long enough for its DHCP lease to expire.

The rest of the fleet is fine. setup2, setup3, setup7 and ephys7 all ran at
01:00 on 2026-08-26 and report OK.

## Why it isn't urgent

- Last successful backup: 2026-08-24 01:00, exit 0, both `/mnt/e/data` and
  `/mnt/f/data` OK, 0 pending files, 1.2 TB free each.
- Newest file on the source is 2026-07-31 17:30, unchanged across every check
  since. ephys3 hasn't recorded since July, so nothing is accumulating
  unbacked-up even if the machine is running with a dead network link.

Two days of missed 01:00 runs cost nothing while the source is static. What the
outage does cost is visibility: while ephys3 is unreachable the daily check FAILs
every morning, and once the Monday due date passes the Todoist task goes overdue.
That is the alarm working, not a second problem.

## Next step

Go to the machine. In order:

1. Confirm it has power and is booted.
2. Confirm the network link — cable seated, switch port live.
3. Once it is on the wire, `getent hosts oephys3.dhcp.wustl.edu` from quintana
   should resolve again on its own after the DHCP lease renews.
4. Then `bash bin/status.sh ephys3` to confirm the native runtime still answers.
   ephys3 cut over on 2026-08-20, so the scheduled task should name `backup.ps1`
   and state should be in `C:\ProgramData\backup-kit`.
5. When the next 08:00 check is green, delete this file.

While you are there: both destinations were at 94-95% used with 1.2 TB free on
2026-08-24. That is not failing yet, and it is tracked in ROADMAP.md, but it is
worth a look before ephys3 starts recording again.
