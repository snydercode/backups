#Requires -Version 5.1
<#
backup.ps1 — Windows-native backup-kit runtime.

SPIKE: implements `status` only. `plan` and `run` are stubs so the JSON
contract can be reviewed before the copy path is written.

Why this exists: on ephys3/ephys7 the backup work is D: -> E:/F:, all local
NTFS volumes. Routing it through WSL forces the scheduled task to run as the
distro-owning user, which needs either a stored password (blocked by the
domain GPO) or /IT (fires only when that account is interactively logged in).
Doing the same work natively lets the task run as SYSTEM, which needs neither.

The output must be byte-compatible with `backup.sh status --raw`: bin/status-all.sh
merges it into the fleet JSON and lib/gate.sh evaluates it field by field.
Two consequences worth knowing before editing:

  * src/dest are reported as the WSL-style paths from jobs.txt (/mnt/d/data),
    not the Windows paths used to touch the disk. lib/gate.sh G13 MISSING_JOB
    compares "src:dest" against the repo's jobs.txt, which the fleet renderer
    emits in WSL form. Translate for I/O, report what jobs.txt said.
  * Every numeric field must be a JSON number. lib/gate.sh G14 MALFORMED_FIELD
    fails a host whose counters arrive as strings.

Usage: backup.ps1 status [-Raw] [-Before YYYY-MM-DD] [-JobsFile <path>]
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
# Streamed rather than collected: D:\data holds millions of files.
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

# robocopy in list-only mode is the analog of `rsync --dry-run`.
#   /E              recurse, including empty dirs        (rsync -a)
#   /XC /XN /XO     skip changed, newer, older files, so only files absent
#                   from the destination count           (rsync --ignore-existing)
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

    $roboArgs = @($Src, $Dest, '/E', '/XC', '/XN', '/XO', '/L',
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
        UsedPct    = ('{0}%' -f [int][math]::Round(($usedKb / $totalKb) * 100))
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
    if (-not (Test-Path -LiteralPath $JobsFile)) {
        throw "jobs file not found: $JobsFile"
    }

    $minAgeDate = ''
    if ($Before) {
        if ($Before -notmatch '^\d{4}-\d{2}-\d{2}$') { throw '--Before must be YYYY-MM-DD' }
        $minAgeDate = $Before -replace '-', ''
    }

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
    foreach ($line in Get-Content -LiteralPath $JobsFile) {
        if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }

        $parts = $line.Trim() -split ':', 2
        if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) { continue }
        $src = $parts[0]
        $dest = $parts[1]

        $srcWin  = ConvertTo-WindowsPath $src
        $destWin = ConvertTo-WindowsPath $dest

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
        if (-not (Test-Path -LiteralPath ([System.IO.Path]::GetPathRoot($destWin)))) {
            $jobStatus = 'ERROR'
            $jobError = "destination volume not available: $destWin"
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

switch ($Command) {
    'status' { Get-StatusJson }
    default  { throw "$Command is not implemented in this spike; status only" }
}
