# ephys3 offline — 2026-08-25

Task-scoped. Delete this file once ephys3 is back and the daily check is green.

## What happened

The 08:00 check on 2026-08-25 failed with
`STATUS_ERROR: could not determine the backup runtime on ephys3`.
It never reached the host, so this is a reachability failure, not a backup failure.

## Already ruled out — don't redo this

- No DNS record for the host under any spelling (`oephys3.dhcp.wustl.edu`,
  `ephys3.dhcp.wustl.edu`, `ephys3`, `oephys3`), from this machine or from eye-hand.
- No ARP entry on eye-hand.
- A port-1840 sweep of eye-hand's subnet neighbours answers for setup2, setup3,
  setup7, ephys7, quintana and conception. Nothing answers as ephys3.

A lapsed dynamic-DNS name plus a vanished ARP entry means the host has been off
the wire long enough for its DHCP lease to expire. Remote diagnosis is exhausted;
what's left needs someone at the machine.

## Why it isn't urgent

- Last successful backup: 2026-08-24 01:00, exit 0, both `/mnt/e/data` and
  `/mnt/f/data` OK, 0 pending files, 1.2 TB free each.
- Newest file on the source is 2026-07-31 17:30, unchanged across every check for
  the past week. ephys3 hasn't recorded since July, so nothing is accumulating
  unbacked-up even if the machine is running with a dead network link.

## Next step

Read the 2026-08-26 08:00 check. Green means it was transient — delete this file.
Still dark means a physical visit: confirm power, then the network link.
