#Requires -Version 5.1
<#
backup.ps1 — Windows-native backup-kit runtime.

Implements the same three commands as backup.sh: plan, run, status.

Why this exists: on ephys3/ephys7 the backup work is D: -> E:/F:, all local
NTFS volumes. Routing it through WSL forces the scheduled task to run as the
distro-owning user, which needs either a stored password (blocked by the
domain GPO) or /IT (fires only when that account is interactively logged in).
Doing the same work natively lets the task run as SYSTEM, which needs neither.

The output must carry the same field names and types as `backup.sh status --raw`:
bin/status-all.sh merges it into the fleet JSON and lib/gate.sh evaluates it field
by field. The human-readable strings (`pending_human`, `dest_avail_human`) are
rendered differently by the two runtimes and no consumer compares them.
Two consequences worth knowing before editing:

  * src/dest are reported as the WSL-style paths from jobs.txt (/mnt/d/data),
    not the Windows paths used to touch the disk. lib/gate.sh G13 MISSING_JOB
    compares "src:dest" against the repo's jobs.txt, which the fleet renderer
    emits in WSL form. Translate for I/O, report what jobs.txt said.
  * Every numeric field must be a JSON number. lib/gate.sh G14 MALFORMED_FIELD
    fails a host whose counters arrive as strings.

Usage: backup.ps1 <plan|run|status> [-Raw] [-Before YYYY-MM-DD] [-JobsFile <path>]
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'plan', 'run')]
    [string]$Command = 'status',

    [string]$JobsFile,
    [string]$Before,
    [switch]$Raw
)

$ErrorActionPreference = 'Stop'

# SYSTEM's $HOME is C:\Windows\system32\config\systemprofile, so the Linux
# ~/.local/state path has no useful analog. ProgramData is the Windows home for
# machine-scoped state and stays readable when the task runs unattended.
$StateDir   = Join-Path $env:ProgramData 'backup-kit'
$ResultFile = Join-Path $StateDir 'last-run.txt'
if (-not $JobsFile) { $JobsFile = Join-Path $PSScriptRoot 'jobs.txt' }

$EpochStart = [datetime]::SpecifyKind([datetime]'1970-01-01', [DateTimeKind]::Utc)

# Invoke-Run reports its result here rather than returning it. A `return` would
# be indistinguishable from the progress lines the function writes: calling it
# as `exit (Invoke-Run)` captures the whole output stream as the exit
# expression, and every line of the run log vanishes into it.
$script:RunExitCode = 0

# /mnt/d/data -> D:\data. Anything else passes through unchanged.
function ConvertTo-WindowsPath {
    param([string]$Path)

    if ($Path -match '^/mnt/([a-zA-Z])(/.*)?$') {
        $drive = $Matches[1].ToUpper()
        $rest  = if ($Matches[2]) { $Matches[2] -replace '/', '\' } else { '\' }
        return "${drive}:$rest"
    }
    return $Path
}

function ConvertTo-Epoch {
    param([datetime]$Time)
    return [long][math]::Round(($Time.ToUniversalTime() - $EpochStart).TotalSeconds, [MidpointRounding]::AwayFromZero)
}

function Format-Iec {
    param([long]$Bytes)

    $units = @('B', 'K', 'M', 'G', 'T', 'P')
    $value = [double]$Bytes
    $i = 0
    while ($value -ge 1024 -and $i -lt ($units.Length - 1)) {
        $value = $value / 1024
        $i++
    }
    if ($i -eq 0) { return "$Bytes" + 'B' }
    return ('{0:0.#}{1}B' -f $value, $units[$i])
}

# Newest mtime under $Path, or -1 when the tree is unreadable or empty.
# lib/gate.sh treats -1 as "source not proven readable" and refuses to
# downgrade a stale host to informational, so this must never guess.
# Streamed rather than collected, so the source tree does not have to fit in memory.
function Get-LastFileEpoch {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return -1 }

    $newest = $null
    Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($null -eq $newest -or $_.LastWriteTimeUtc -gt $newest) {
                $newest = $_.LastWriteTimeUtc
            }
        }

    if ($null -eq $newest) { return -1 }
    return (ConvertTo-Epoch $newest)
}

# File selection, shared by plan, run, and status so all three agree on what
# "pending" means.
#   /E              recurse, including empty dirs        (rsync -a)
#   /XN /XO         skip files newer or older at the destination, so a file
#                   already backed up is never rewritten (rsync --ignore-existing)
#
# /XC is deliberately absent, and this is the one place the two runtimes differ
# on purpose. robocopy has no equivalent of rsync's --partial-dir: it writes
# straight to the final path, so an interrupted run leaves a truncated file
# under the real name. robocopy classes that file as "changed" (same timestamp,
# different size), which is exactly what /XC would exclude — so excluding it
# would freeze the truncation forever. Without /XC the next run repairs it.
# A source file genuinely edited after backup gets a new timestamp and is
# excluded by /XN, so append-only still holds for the case it protects.
$RoboSelect = @('/E', '/XN', '/XO')

# robocopy in list-only mode is the analog of `rsync --dry-run`.
#   /L              list only, copy nothing              (rsync --dry-run)
#   /BYTES          report the summary in plain integers, not "1.2 g"
#   /NFL /NDL /NP   suppress file, dir, and progress lines; keep the summary
#   /R:0 /W:0       never retry: a status check must not block for minutes
#   /MINAGE:date    exclude files newer than date        (rsync --max-age)
# Exit codes below 8 are success (0 nothing to copy, 1 files would copy,
# 2 extras present, 3 both). 8 and above is a real failure, and unlike the
# rsync path in backup.sh this checks it — see the FIXME at backup.sh:127.
function Get-PendingWork {
    param([string]$Src, [string]$Dest, [string]$MinAgeDate)

    # Function-scoped, so it reverts on return. The global 'Stop' turns a native
    # command's stderr into a terminating error, which would unwind past the rc
    # check below and cost the caller the per-destination JOB_ERROR it needs.
    $ErrorActionPreference = 'Continue'

    $roboArgs = @($Src, $Dest) + $RoboSelect + @('/L',
                  '/BYTES', '/NFL', '/NDL', '/NP', '/R:0', '/W:0')
    if ($MinAgeDate) { $roboArgs += "/MINAGE:$MinAgeDate" }

    $output = & robocopy.exe @roboArgs 2>&1 | Out-String
    $rc = $LASTEXITCODE

    if ($rc -ge 8) {
        return [pscustomobject]@{
            Ok = $false
            Error = ("robocopy exited $rc" + [Environment]::NewLine +
                     ($output.Trim() -split "`r?`n" | Select-Object -Last 1))
        }
    }

    # Summary block, second column is "Copied" — what a real run would move.
    $files = 0
    $bytes = [long]0
    if ($output -match '(?m)^\s*Files\s*:\s+\d+\s+(\d+)') { $files = [int]$Matches[1] }
    if ($output -match '(?m)^\s*Bytes\s*:\s+\d+\s+(\d+)') { $bytes = [long]$Matches[1] }

    return [pscustomobject]@{
        Ok = $true
        PendingFiles = $files
        PendingBytes = $bytes
    }
}

# jobs.txt is host-scoped and deployed alongside this script: one "src:dest"
# per line, blanks and # comments ignored. Paths are WSL-form because the
# fleet renderer emits them that way; see ConvertTo-WindowsPath.
function Read-JobLines {
    if (-not (Test-Path -LiteralPath $JobsFile)) {
        throw "jobs file not found: $JobsFile"
    }

    $lines = @()
    foreach ($line in Get-Content -LiteralPath $JobsFile) {
        if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }

        $parts = $line.Trim() -split ':', 2
        if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) { continue }

        $lines += [pscustomobject]@{
            Src     = $parts[0]
            Dest    = $parts[1]
            SrcWin  = (ConvertTo-WindowsPath $parts[0])
            DestWin = (ConvertTo-WindowsPath $parts[1])
        }
    }
    return $lines
}

# True when the destination is present and usable. Checked before robocopy, which
# takes its own sweet time to fail against a missing volume and gives a worse
# message when it does.
#
# The directory itself must exist, not merely its volume — this mirrors
# backup.sh's check_mount, which requires `[ -d "$path" ]`. A disk that was
# replaced or reformatted comes back as a valid empty E:, and without this check
# robocopy would create E:\data and start a fresh full copy into it, reporting
# PENDING and then OK while the real backup is gone.
function Test-DestVolume {
    param([string]$PathWin)
    $root = [System.IO.Path]::GetPathRoot($PathWin)
    if (-not $root) { return $false }
    if (-not (Test-Path -LiteralPath $root)) { return $false }
    return (Test-Path -LiteralPath $PathWin -PathType Container)
}

function Get-DestDisk {
    param([string]$DestWin)

    $root = [System.IO.Path]::GetPathRoot($DestWin)
    if (-not $root) { return $null }
    $deviceId = $root.TrimEnd('\')

    $disk = Get-CimInstance -ClassName Win32_LogicalDisk `
        -Filter "DeviceID='$deviceId'" -ErrorAction SilentlyContinue
    if ($null -eq $disk -or $null -eq $disk.Size -or $disk.Size -eq 0) { return $null }

    # KiB throughout, matching `df -P` on the Linux hosts.
    $totalKb = [long]($disk.Size / 1024)
    $availKb = [long]($disk.FreeSpace / 1024)
    $usedKb  = $totalKb - $availKb

    return [pscustomobject]@{
        TotalKb    = $totalKb
        UsedKb     = $usedKb
        AvailKb    = $availKb
        AvailHuman = (Format-Iec $disk.FreeSpace)
        # df -P rounds the use% UP, and computes it over used+avail rather than
        # the raw size. Match both, or a destination reads one point cleaner
        # here than it does on the Linux hosts.
        UsedPct    = ('{0}%' -f [int][math]::Ceiling(($usedKb / ($usedKb + $availKb)) * 100))
    }
}

# last-run.txt is written by whichever runtime performed the run and is shared
# with backup.sh verbatim: shell-style key=value, values optionally quoted.
function Read-LastRun {
    $result = @{ epoch = [long]0; date = ''; result = $null }
    if (-not (Test-Path -LiteralPath $ResultFile)) { return $result }

    foreach ($line in Get-Content -LiteralPath $ResultFile) {
        if ($line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { continue }
        $key = $Matches[1]
        $value = $Matches[2].Trim().Trim('"')
        switch ($key) {
            'last_run_epoch'  { if ($value -match '^\d+$') { $result.epoch = [long]$value } }
            'last_run_date'   { $result.date = $value }
            'last_run_result' { if ($value -match '^-?\d+$') { $result.result = [int]$value } }
        }
    }
    return $result
}

function Get-StatusJson {
    # backup.sh applies this cutoff whether or not --before is passed
    # (`${before_date:-$(date +%Y-%m-%d)}`), so files written today are excluded
    # from pending on both runtimes. Without it a Windows host reports PENDING on
    # a recording day where a Linux host reports OK, and a job with pending files
    # can never reach the informational STALE_IDLE downgrade.
    #
    # The cutoff means "count files modified before this date", and robocopy's
    # /MINAGE:<date> excludes files newer than that date's midnight — the same
    # boundary. Verified on ephys7, 2026-08-19: with the default cutoff a file
    # written that afternoon is excluded and one written the day before is not.
    $cutoff = (Get-Date).Date
    if ($Before) {
        if ($Before -notmatch '^\d{4}-\d{2}-\d{2}$') { throw '-Before must be YYYY-MM-DD' }
        $cutoff = [datetime]::ParseExact($Before, 'yyyy-MM-dd', $null)
    }
    $minAgeDate = $cutoff.ToString('yyyyMMdd')

    $lastRun = Read-LastRun
    $ageHours = -1
    $lastRunStatus = 'NEVER_RUN'
    $overallStatus = 'NEVER_RUN'
    $lastRunDate = 'never'

    if ($lastRun.epoch -gt 0) {
        $lastRunDate = $lastRun.date
        $ageHours = [int][math]::Floor(((ConvertTo-Epoch (Get-Date)) - $lastRun.epoch) / 3600)
        if ($lastRun.result -eq 0) {
            $lastRunStatus = 'OK'
            $overallStatus = 'OK'
        } else {
            $lastRunStatus = 'FAILED'
            $overallStatus = 'FAILED'
        }
    }

    $jobs = @()
    foreach ($jobLine in (Read-JobLines)) {
        $src     = $jobLine.Src
        $dest    = $jobLine.Dest
        $srcWin  = $jobLine.SrcWin
        $destWin = $jobLine.DestWin

        $job = [ordered]@{
            src                 = $src
            dest                = $dest
            enabled             = 1
            src_last_file_epoch = [long](Get-LastFileEpoch $srcWin)
            src_last_file_time  = 'unknown'
            pending_files       = 0
            pending_bytes       = [long]0
            pending_human       = '0B'
        }
        if ($job.src_last_file_epoch -gt 0) {
            $job.src_last_file_time =
                $EpochStart.AddSeconds($job.src_last_file_epoch).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
        } elseif (-not (Test-Path -LiteralPath $srcWin -PathType Container)) {
            $job.src_last_file_time = 'ERROR:not_a_directory'
        } else {
            $job.src_last_file_time = 'never'
        }

        $jobStatus = 'OK'
        $jobError = $null

        # Mount check first: robocopy against a missing volume is slow to fail.
        if (-not (Test-DestVolume $destWin)) {
            $jobStatus = 'ERROR'
            $jobError = "destination not available: $destWin"
        } else {
            $pending = Get-PendingWork -Src $srcWin -Dest $destWin -MinAgeDate $minAgeDate
            if (-not $pending.Ok) {
                $jobStatus = 'ERROR'
                $jobError = $pending.Error
            } else {
                $job.pending_files = [int]$pending.PendingFiles
                $job.pending_bytes = [long]$pending.PendingBytes
                $job.pending_human = Format-Iec $pending.PendingBytes
                if ($pending.PendingFiles -ne 0) { $jobStatus = 'PENDING' }
            }
        }

        if ($jobStatus -ne 'ERROR') {
            $disk = Get-DestDisk $destWin
            if ($null -ne $disk) {
                $job.dest_total_kb = $disk.TotalKb
                $job.dest_used_kb  = $disk.UsedKb
                $job.dest_avail_kb = $disk.AvailKb
                $job.dest_avail_human = $disk.AvailHuman
                $job.dest_used_pct = $disk.UsedPct
            } else {
                # Omit dest_*_kb entirely. lib/gate.sh G12 DISK_UNKNOWN keys off
                # a null dest_avail_kb; a zero here would read as a full disk.
                $job.dest_avail_human = 'UNKNOWN'
                $job.dest_used_pct = 'UNKNOWN'
            }
        } else {
            $job.dest_avail_human = 'UNKNOWN'
            $job.dest_used_pct = 'UNKNOWN'
        }

        $job.status = $jobStatus
        if ($jobError) { $job.error = $jobError }

        $jobs += [pscustomobject]$job
    }

    $status = [ordered]@{
        schema_version = 1
        generated_at   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        host           = $env:COMPUTERNAME.ToLower()
        last_run       = [ordered]@{
            date      = $lastRunDate
            age_hours = $ageHours
            result    = $lastRun.result
            status    = $lastRunStatus
        }
        overall_status = $overallStatus
        jobs           = @($jobs)
        errors         = @()
    }

    return ($status | ConvertTo-Json -Depth 6 -Compress)
}

function Write-Tee {
    param([string]$Message, [string]$LogFile)

    Write-Output $Message
    if ($LogFile) { Add-Content -LiteralPath $LogFile -Value $Message }
}

function Invoke-Plan {
    foreach ($jobLine in (Read-JobLines)) {
        Write-Output "=== $($jobLine.Src) -> $($jobLine.Dest) ==="

        if (-not (Test-DestVolume $jobLine.DestWin)) {
            Write-Output "ERROR: destination not available: $($jobLine.DestWin)"
            Write-Output ''
            continue
        }

        $pending = Get-PendingWork -Src $jobLine.SrcWin -Dest $jobLine.DestWin -MinAgeDate ''
        if (-not $pending.Ok) {
            Write-Output "ERROR: $($pending.Error)"
        } else {
            Write-Output "pending_files=$($pending.PendingFiles)"
            Write-Output "pending_bytes=$($pending.PendingBytes)"
            Write-Output "pending_human=$(Format-Iec $pending.PendingBytes)"
        }
        Write-Output ''
    }
}

# The analog of backup.sh's make_readonly(). Two deliberate differences:
#   * attrib +R is enforced by Windows on NTFS. chmod 444 from inside WSL is
#     not: it resets on remount unless the volume carries the `metadata` mount
#     option, which CLAUDE.md documents as a known hole on these two hosts.
#   * a destination file whose size disagrees with its source is left WRITABLE.
#     Such a file is a truncated copy from an interrupted run, and marking it
#     read-only freezes the truncation for good — nothing would ever repair it.
#     Left writable, the next run overwrites it. backup.sh needs no equivalent:
#     rsync's --partial-dir keeps partials out of the final path in the first
#     place, which robocopy has no way to do.
# Directories stay writable so later runs can still create files in them.
function Set-DestReadOnly {
    param([string]$SrcWin, [string]$DestWin, [string]$LogFile)

    $start = Get-Date
    $marked = 0
    $left = 0
    $destRoot = $DestWin.TrimEnd('\')

    Get-ChildItem -LiteralPath $DestWin -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            # Already read-only: the fast path for repeat runs, same reason
            # backup.sh filters on ! -perm 444.
            if ($_.IsReadOnly) { return }

            $rel = $_.FullName.Substring($destRoot.Length).TrimStart('\')
            $srcInfo = Get-Item -LiteralPath (Join-Path $SrcWin $rel) -Force -ErrorAction SilentlyContinue

            if ($null -ne $srcInfo -and $srcInfo.Length -ne $_.Length) {
                $left++
                Add-Content -LiteralPath $LogFile `
                    -Value "left writable, size differs from source: $($_.FullName)"
                return
            }

            $_.IsReadOnly = $true
            $marked++
        }

    $secs = [int]((Get-Date) - $start).TotalSeconds
    Write-Tee "read-only pass: $marked marked, $left left writable, ${secs}s" $LogFile
}

# Shared with backup.sh verbatim, so either runtime can read the other's state.
# One deliberate difference: backup.sh writes this file inside each job, so on a
# two-destination host it records only the LAST job's result and a failure in
# the first destination is invisible to lib/gate.sh. This writes once, and the
# worst result wins.
function Write-LastRun {
    param([int]$Result)

    $now = Get-Date
    $quoted = '"' + $now.ToString('yyyy-MM-dd HH:mm:ss') + '"'
    $lines = @(
        "last_run_epoch=$(ConvertTo-Epoch $now)",
        "last_run_date=$quoted",
        "last_run_result=$Result"
    )
    Set-Content -LiteralPath $ResultFile -Value $lines -Encoding ASCII
}

# Copy flags, on top of $RoboSelect:
#   /Z              restartable mode, so a dropped link mid-file resumes
#                   instead of restarting                (rsync --partial)
#   /COPY:DAT       data, attributes, timestamps         (rsync -a)
#   /DCOPY:T        carry directory timestamps too
#   /R:1 /W:5       one retry, 5s apart. robocopy's default is a million
#                   retries 30s apart, which would hang the 1 AM job for weeks.
#   /LOG+ /TEE      append to last-run.log and echo to stdout for cron.log
# No /MIR and no /PURGE: nothing may ever be deleted from a destination.
# The result is recorded from `finally` on purpose. $ErrorActionPreference is
# 'Stop', so an unhandled throw anywhere in the loop — a file held open by an
# acquisition process, an ACL SYSTEM cannot rewrite — would otherwise unwind past
# the write and leave the PREVIOUS run's success in last-run.txt. lib/gate.sh
# reads that field, so the failed run would be invisible for a full day.
# backup.sh writes its result unconditionally (backup.sh:180); this matches it.
function Invoke-Run {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $logFile = Join-Path $StateDir 'last-run.log'
    Set-Content -LiteralPath $logFile `
        -Value "backup-kit run $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"

    $worst = 0
    try {
        foreach ($jobLine in (Read-JobLines)) {
            Write-Tee "=== Backup: $($jobLine.Src) -> $($jobLine.Dest) ===" $logFile
            $started = Get-Date
            Write-Tee "Started: $($started.ToString('yyyy-MM-dd HH:mm:ss'))" $logFile

            if (-not (Test-DestVolume $jobLine.DestWin)) {
                Write-Tee "FAILED: destination not available: $($jobLine.DestWin)" $logFile
                if ($worst -lt 1) { $worst = 1 }
                continue
            }

            $roboArgs = @($jobLine.SrcWin, $jobLine.DestWin) + $RoboSelect +
                        @('/Z', '/COPY:DAT', '/DCOPY:T', '/R:1', '/W:5',
                          '/BYTES', '/NP', "/LOG+:$logFile", '/TEE')
            & robocopy.exe @roboArgs
            $rc = $LASTEXITCODE

            # 0-7 is success (bits: 1 copied, 2 extras present, 4 mismatched).
            # 8 and above is a real failure. Passing robocopy's code through
            # unmapped would report every successful copy as a failed run to
            # lib/gate.sh, which reads last_run_result.
            if ($rc -ge 8) {
                Write-Tee "FAILED: robocopy exited $rc" $logFile
                if ($worst -lt $rc) { $worst = $rc }
            } else {
                Set-DestReadOnly -SrcWin $jobLine.SrcWin -DestWin $jobLine.DestWin -LogFile $logFile
            }

            $secs = [int]((Get-Date) - $started).TotalSeconds
            Write-Tee "Finished: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) (${secs}s, robocopy exit $rc)" $logFile
            Write-Tee '' $logFile
        }
    } catch {
        Write-Tee "FAILED: $($_.Exception.Message)" $logFile
        if ($worst -lt 1) { $worst = 1 }
    } finally {
        Write-LastRun $worst
        $script:RunExitCode = $worst
    }
}

switch ($Command) {
    'status' { Get-StatusJson }
    'plan'   {
        if ($Before) { throw '-Before is only valid with status' }
        Invoke-Plan
    }
    'run'    {
        if ($Before) { throw '-Before is only valid with status' }
        Invoke-Run
        exit $script:RunExitCode
    }
}
