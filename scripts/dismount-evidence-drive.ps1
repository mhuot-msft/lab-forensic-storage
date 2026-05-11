<#
.SYNOPSIS
    Dismounts the forensic storage drives previously mounted by mount-evidence-drive.ps1.

.DESCRIPTION
    Reads the per-mount state files written under
    %LOCALAPPDATA%\forensic-lab\mounts\, validates that the running process
    still matches the stored signature (PID + start time + executable path +
    command-line markers), then terminates rclone and cleans up the state.

    The signature check prevents the dismount script from killing an unrelated
    rclone process if a PID is reused.

.PARAMETER EvidenceDriveLetter
    Drive letter of the evidence mount. Default: Z.

.PARAMETER ReceiptDriveLetter
    Drive letter of the chain-of-custody mount. Default: Y.

.PARAMETER All
    Dismount every drive that has a state file under the lab state directory.

.EXAMPLE
    .\dismount-evidence-drive.ps1
    # Dismounts Z: and Y: by default.

.EXAMPLE
    .\dismount-evidence-drive.ps1 -All
    # Dismounts every drive with state in %LOCALAPPDATA%\forensic-lab\mounts\.

.EXAMPLE
    .\dismount-evidence-drive.ps1 -EvidenceDriveLetter F -ReceiptDriveLetter G
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[D-Zd-z]$')]
    [string]$EvidenceDriveLetter = 'Z',
    [ValidatePattern('^[D-Zd-z]$')]
    [string]$ReceiptDriveLetter = 'Y',
    [switch]$All
)

$ErrorActionPreference = 'Stop'
$LabRoot = Join-Path $env:LOCALAPPDATA 'forensic-lab'
$StateDir = Join-Path $LabRoot 'mounts'
$MountTag = 'forensic-storage-lab'

function Write-Banner {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor Cyan
}

function Write-Step { param([string]$Msg) Write-Host "  >> $Msg" -ForegroundColor Yellow }
function Write-Ok   { param([string]$Msg) Write-Host "     [PASS] $Msg" -ForegroundColor Green }
function Write-Skip { param([string]$Msg) Write-Host "     [SKIP] $Msg" -ForegroundColor DarkGray }
function Write-Fail { param([string]$Msg) Write-Host "     [FAIL] $Msg" -ForegroundColor Red }

function Get-StateFiles {
    param([string[]]$Letters, [bool]$AllMounts)
    if ($AllMounts) {
        if (-not (Test-Path $StateDir)) { return @() }
        return Get-ChildItem -Path $StateDir -Filter '*.json' -File
    }
    $files = @()
    foreach ($l in $Letters) {
        $path = Join-Path $StateDir "$($l.ToUpper()).json"
        if (Test-Path $path) { $files += Get-Item $path }
    }
    return $files
}

function Test-ProcessMatches {
    param(
        [psobject]$State,
        [System.Diagnostics.Process]$Proc,
        [string]$CommandLine
    )
    if (-not $Proc -or $Proc.HasExited) { return $false }

    if ($State.executable -and $Proc.Path -and ($Proc.Path -ne $State.executable)) {
        return $false
    }

    try {
        $stored = [datetime]::Parse($State.start_time)
        $delta = [Math]::Abs(($Proc.StartTime - $stored).TotalSeconds)
        if ($delta -gt 2) { return $false }
    } catch {
        return $false
    }

    if ($State.drive_letter -and $CommandLine -notlike "*$($State.drive_letter):*") {
        return $false
    }
    if ($State.account -and $CommandLine -notlike "*$($State.account)*") {
        return $false
    }
    if ($CommandLine -notlike "*$MountTag*" -and $State.config_path -and $CommandLine -notlike "*$($State.config_path)*") {
        return $false
    }
    return $true
}

function Stop-MountFromState {
    param([System.IO.FileInfo]$StateFile)

    $state = Get-Content $StateFile.FullName -Raw | ConvertFrom-Json
    $letter = $state.drive_letter
    Write-Step "Dismounting ${letter}: (rclone pid $($state.pid))"

    if ($state.tag -and $state.tag -ne $MountTag) {
        Write-Fail "State tag mismatch. Refusing to act on this state file."
        return
    }

    $proc = Get-Process -Id $state.pid -ErrorAction SilentlyContinue
    if (-not $proc) {
        Write-Skip "Process $($state.pid) is no longer running. Cleaning up state file."
        Remove-Item $StateFile.FullName -Force
        if (Test-Path "${letter}:\") {
            Write-Fail "Drive ${letter}: is still mapped but no rclone process is running. Reboot may be needed."
        }
        return
    }

    $cmdline = $null
    try {
        $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$($state.pid)" -ErrorAction Stop
        $cmdline = $cim.CommandLine
    } catch {
        Write-Fail "Cannot read command line for pid $($state.pid): $($_.Exception.Message)"
        Write-Fail "Refusing to terminate without full signature match."
        return
    }

    if (-not (Test-ProcessMatches -State $state -Proc $proc -CommandLine $cmdline)) {
        Write-Fail "Process $($state.pid) does not match the stored mount signature."
        Write-Host "         executable: expected '$($state.executable)', got '$($proc.Path)'" -ForegroundColor DarkGray
        Write-Host "         start_time: expected '$($state.start_time)', got '$($proc.StartTime.ToString('o'))'" -ForegroundColor DarkGray
        Write-Host "         command_line markers: drive=$($state.drive_letter), account=$($state.account)" -ForegroundColor DarkGray
        Write-Fail "Refusing to terminate. Remove the state file manually if you are sure: $($StateFile.FullName)"
        return
    }

    try {
        $proc | Stop-Process -Force -ErrorAction Stop
    } catch {
        Write-Fail "Failed to stop pid $($state.pid): $($_.Exception.Message)"
        return
    }

    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path "${letter}:\")) { break }
        Start-Sleep -Milliseconds 500
    }
    if (Test-Path "${letter}:\") {
        Write-Fail "Drive ${letter}: still appears mapped after stopping rclone. May need manual cleanup."
    } else {
        Write-Ok "${letter}: unmounted."
    }
    Remove-Item $StateFile.FullName -Force
}

# ============================================================
# MAIN
# ============================================================

Write-Banner 'Forensic Storage Lab — Dismount'

if (-not (Test-Path $StateDir)) {
    Write-Skip "No mount state directory at $StateDir. Nothing to dismount."
    exit 0
}

$files = Get-StateFiles -Letters @($EvidenceDriveLetter, $ReceiptDriveLetter) -AllMounts:$All
if (-not $files -or $files.Count -eq 0) {
    Write-Skip 'No matching mount state files found.'
    exit 0
}

foreach ($f in $files) {
    Stop-MountFromState -StateFile $f
}

Write-Host ''
