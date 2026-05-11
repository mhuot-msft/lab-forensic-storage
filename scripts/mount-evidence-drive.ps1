<#
.SYNOPSIS
    Mounts forensic storage containers as Windows drive letters via rclone + WinFsp.

.DESCRIPTION
    Provides an OPTIONAL convenience filesystem-style access path for investigators
    who prefer drag-and-drop in File Explorer. Authentication uses Entra ID through
    the Azure CLI cached token (rclone option use_az = true). The mount path does
    NOT use shared keys, account SAS, or service-principal credentials.

    This is NOT the recommended path for bulk ingestion of multi-GB evidence
    images — the VFS write cache can mask upload failures. Use Azure Storage
    Explorer, AzCopy, or 'rclone copy' for durable bulk transfer.

    Run as the SAME Windows user that ran 'az login'. Do not mount from an
    elevated shell if 'az login' was non-elevated; the drive will not appear in
    your Explorer session due to UAC token splitting.

    Two drives are mounted by default:
      - Evidence drive (read-write):    forensic-evidence    -> Z:
      - Chain-of-custody drive (RO):    chain-of-custody     -> Y:

    The chain-of-custody mount is presented read-only as a UX guardrail. It is
    NOT a security boundary for investigators who hold Storage Blob Data
    Contributor at the storage account scope — they can still write to that
    container through other tools. Container-scoped Reader is the production
    answer; this lab uses account-scoped Contributor for demo simplicity.

.PARAMETER StorageAccountName
    Storage account to mount. If omitted, discovered from the resource group by
    name prefix.

.PARAMETER ResourceGroup
    Resource group containing the storage account. If omitted, read from
    infra/main.bicepparam.

.PARAMETER NamePrefix
    Storage account name prefix used for discovery. If omitted, read from
    infra/main.bicepparam (default: forensiclab).

.PARAMETER EvidenceContainer
    Evidence container name. Default: forensic-evidence.

.PARAMETER ReceiptContainer
    Chain-of-custody container name. Default: chain-of-custody.

.PARAMETER EvidenceDriveLetter
    Drive letter for the evidence mount (single letter D-Z). Default: Z.

.PARAMETER ReceiptDriveLetter
    Drive letter for the chain-of-custody mount (single letter D-Z). Default: Y.

.PARAMETER InstallPrerequisites
    Install WinFsp and rclone via winget. Requires elevation. Run once on a
    fresh workstation, then re-run this script (without -InstallPrerequisites,
    not elevated) to mount.

.PARAMETER Preflight
    Run preflight checks only; do not mount.

.PARAMETER AcceptCurrentContext
    Skip interactive confirmation of the signed-in Azure account.

.PARAMETER SkipDnsCheck
    Skip the private-DNS validation. Use only when your VNet uses non-RFC1918
    address space.

.EXAMPLE
    .\mount-evidence-drive.ps1 -InstallPrerequisites
    # Run once as Administrator to install WinFsp + rclone.

.EXAMPLE
    .\mount-evidence-drive.ps1 -Preflight
    # Validate prerequisites and DNS without mounting.

.EXAMPLE
    .\mount-evidence-drive.ps1
    # Mount with discovered defaults: Z: (evidence, RW), Y: (custody, RO).

.EXAMPLE
    .\mount-evidence-drive.ps1 -EvidenceDriveLetter F -ReceiptDriveLetter G
    # Mount on alternate drive letters.
#>
[CmdletBinding()]
param(
    [string]$StorageAccountName,
    [string]$ResourceGroup,
    [string]$NamePrefix,
    [string]$EvidenceContainer = 'forensic-evidence',
    [string]$ReceiptContainer = 'chain-of-custody',
    [ValidatePattern('^[D-Zd-z]$')]
    [string]$EvidenceDriveLetter = 'Z',
    [ValidatePattern('^[D-Zd-z]$')]
    [string]$ReceiptDriveLetter = 'Y',
    [switch]$InstallPrerequisites,
    [switch]$Preflight,
    [switch]$AcceptCurrentContext,
    [switch]$SkipDnsCheck
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$BicepParam = Join-Path $RepoRoot 'infra\main.bicepparam'
$LabRoot = Join-Path $env:LOCALAPPDATA 'forensic-lab'
$StateDir = Join-Path $LabRoot 'mounts'
$LogDir = Join-Path $LabRoot 'logs'
$RcloneConfigDir = Join-Path $LabRoot 'rclone'
$RcloneConfig = Join-Path $RcloneConfigDir 'rclone.conf'
$CacheDir = Join-Path $LabRoot 'cache'
$MountTag = 'forensic-storage-lab'
$MinRcloneVersion = [version]'1.66.0'

$EvidenceDriveLetter = $EvidenceDriveLetter.ToUpper()
$ReceiptDriveLetter = $ReceiptDriveLetter.ToUpper()

function Write-Banner {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Step)
    Write-Host "  >> $Step" -ForegroundColor Yellow
}

function Write-Ok {
    param([string]$Msg)
    Write-Host "     [PASS] $Msg" -ForegroundColor Green
}

function Write-Warn2 {
    param([string]$Msg)
    Write-Host "     [WARN] $Msg" -ForegroundColor DarkYellow
}

function Write-Fail {
    param([string]$Msg)
    Write-Host "     [FAIL] $Msg" -ForegroundColor Red
}

function Read-BicepParam {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-Path $BicepParam)) { return $null }
    $pattern = "param\s+$([regex]::Escape($Name))\s*=\s*'([^']+)'"
    $match = Select-String -Path $BicepParam -Pattern $pattern
    if ($match) { return $match.Matches[0].Groups[1].Value }
    return $null
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RcloneInfo {
    $cmd = Get-Command rclone -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    $verLine = (& $cmd.Path version 2>$null | Select-Object -First 1)
    $ver = $null
    if ($verLine -match 'rclone\s+v(\d+\.\d+\.\d+)') { $ver = [version]$matches[1] }
    return [PSCustomObject]@{ Path = $cmd.Path; Version = $ver }
}

function Test-WinFspInstalled {
    $regKey = 'HKLM:\SOFTWARE\WOW6432Node\WinFsp'
    if (Test-Path $regKey) { return $true }
    $regKey64 = 'HKLM:\SOFTWARE\WinFsp'
    if (Test-Path $regKey64) { return $true }
    $svc = Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue
    if ($svc) { return $true }
    return $false
}

function Install-Prerequisites {
    Write-Banner 'Installing prerequisites (WinFsp + rclone)'
    if (-not (Test-IsAdmin)) {
        Write-Fail 'Installation requires an elevated PowerShell. Re-run as Administrator.'
        exit 1
    }
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Fail 'winget not found. Install App Installer from the Microsoft Store, or install WinFsp/rclone manually:'
        Write-Host '       WinFsp: https://winfsp.dev/rel/' -ForegroundColor DarkGray
        Write-Host '       rclone: https://rclone.org/downloads/' -ForegroundColor DarkGray
        exit 1
    }
    Write-Step 'Installing WinFsp'
    & winget install --id WinFsp.WinFsp --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
    Write-Step 'Installing rclone'
    & winget install --id Rclone.Rclone --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
    Write-Host ''
    Write-Ok 'Prerequisites installed. Open a NEW non-elevated PowerShell as the investigator user and run:'
    Write-Host '       .\scripts\mount-evidence-drive.ps1' -ForegroundColor DarkGray
}

function Test-AzContext {
    Write-Step 'Azure CLI is signed in'
    $account = az account show -o json 2>$null | ConvertFrom-Json
    if (-not $account) {
        Write-Fail "Not signed in. Run 'az login' as this Windows user, then re-run this script."
        return $null
    }
    Write-Ok "User: $($account.user.name)"
    Write-Ok "Tenant: $($account.tenantId)"
    Write-Ok "Subscription: $($account.name) ($($account.id))"
    if (-not $AcceptCurrentContext) {
        $resp = Read-Host '     Use this Azure context? [Y/n]'
        if ($resp -and $resp.Trim().ToLower() -eq 'n') {
            Write-Host "     Run 'az account set --subscription <id>' or 'az login --tenant <id>' and re-run." -ForegroundColor DarkGray
            return $null
        }
    }
    Write-Step 'Acquire storage data-plane token'
    $token = az account get-access-token --resource 'https://storage.azure.com/' -o json 2>$null | ConvertFrom-Json
    if (-not $token -or -not $token.accessToken) {
        Write-Fail "Could not get a storage access token. Try 'az login --scope https://storage.azure.com/.default'."
        return $null
    }
    Write-Ok 'Storage access token acquired (Entra ID).'
    return $account
}

function Resolve-StorageAccountName {
    param([string]$Rg, [string]$Prefix)
    Write-Step "Discovering storage account in '$Rg' with prefix '$Prefix'"
    $list = az storage account list -g $Rg --query "[?starts_with(name, '$Prefix')].name" -o tsv 2>$null
    if (-not $list) {
        Write-Fail "No storage account starting with '$Prefix' found in resource group '$Rg'."
        return $null
    }
    $names = @($list -split "`r?`n" | Where-Object { $_ })
    if ($names.Count -gt 1) {
        Write-Fail "Multiple matches: $($names -join ', '). Re-run with -StorageAccountName."
        return $null
    }
    Write-Ok "Storage account: $($names[0])"
    return $names[0]
}

function Test-PrivateDns {
    param([string]$Account)
    if ($SkipDnsCheck) {
        Write-Warn2 'DNS check skipped (-SkipDnsCheck).'
        return $true
    }
    $rfc1918 = '^(10\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.)'
    $allOk = $true
    foreach ($sub in @('blob', 'dfs')) {
        $fqdn = "$Account.$sub.core.windows.net"
        Write-Step "Resolving $fqdn"
        $dns = $null
        try {
            $dns = Resolve-DnsName $fqdn -ErrorAction Stop
        } catch {
            Write-Fail "$fqdn did not resolve: $($_.Exception.Message)"
            $allOk = $false
            continue
        }
        $a = $dns | Where-Object { $_.Type -eq 'A' -and $_.IP4Address } | Select-Object -First 1
        if (-not $a) {
            Write-Fail "$fqdn returned no A record."
            $allOk = $false
            continue
        }
        if ($a.IP4Address -match $rfc1918) {
            Write-Ok "$fqdn -> $($a.IP4Address) (consistent with private endpoint)"
        } else {
            Write-Fail "$fqdn -> $($a.IP4Address) is not RFC1918. This does not prove private endpoint access."
            Write-Host '            Storage may be reachable, but the security posture is not validated.' -ForegroundColor DarkGray
            Write-Host '            Override with -SkipDnsCheck if your VNet uses non-RFC1918 address space.' -ForegroundColor DarkGray
            $allOk = $false
        }
    }
    return $allOk
}

function Test-DriveLetterAvailable {
    param([string]$Letter)
    $path = "${Letter}:\"
    if (Test-Path $path) {
        Write-Fail "Drive ${Letter}: is already in use."
        return $false
    }
    Write-Ok "Drive ${Letter}: is free."
    return $true
}

function Write-RcloneConfig {
    param([string]$Account)
    if (-not (Test-Path $RcloneConfigDir)) { New-Item -ItemType Directory -Path $RcloneConfigDir -Force | Out-Null }
    $remoteName = 'forensic'
    $config = @"
[$remoteName]
type = azureblob
account = $Account
use_az = true
"@
    Set-Content -Path $RcloneConfig -Value $config -Encoding ascii
    Write-Ok "rclone config written: $RcloneConfig"
    return $remoteName
}

function Get-MountStateFile {
    param([string]$Letter)
    return Join-Path $StateDir "$($Letter.ToUpper()).json"
}

function Save-MountState {
    param(
        [string]$Letter,
        [System.Diagnostics.Process]$Proc,
        [string]$Container,
        [string]$Account,
        [string]$Cmdline,
        [bool]$ReadOnly
    )
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    $state = [ordered]@{
        tag           = $MountTag
        drive_letter  = $Letter.ToUpper()
        pid           = $Proc.Id
        start_time    = $Proc.StartTime.ToString('o')
        executable    = $Proc.Path
        command_line  = $Cmdline
        container     = $Container
        account       = $Account
        read_only     = $ReadOnly
        config_path   = $RcloneConfig
        log_path      = (Join-Path $LogDir "$($Letter.ToUpper())-rclone.log")
    }
    $state | ConvertTo-Json -Depth 4 | Set-Content -Path (Get-MountStateFile $Letter) -Encoding ascii
}

function Start-RcloneMount {
    param(
        [string]$Remote,
        [string]$Container,
        [string]$Letter,
        [string]$VolumeLabel,
        [bool]$ReadOnly
    )
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
    $logPath = Join-Path $LogDir "$($Letter.ToUpper())-rclone.log"
    $rcloneArgs = @(
        'mount', "${Remote}:${Container}", "${Letter}:",
        '--config', $RcloneConfig,
        '--cache-dir', $CacheDir,
        '--vfs-cache-mode', 'writes',
        '--dir-cache-time', '1m',
        '--poll-interval', '30s',
        '--network-mode',
        '--volname', $VolumeLabel,
        '--exclude', 'desktop.ini',
        '--exclude', 'Thumbs.db',
        '--exclude', '$RECYCLE.BIN/**',
        '--exclude', 'System Volume Information/**',
        '--log-file', $logPath,
        '--log-level', 'NOTICE'
    )
    if ($ReadOnly) { $rcloneArgs += '--read-only' }

    $rclone = (Get-RcloneInfo).Path
    $proc = Start-Process -FilePath $rclone -ArgumentList $rcloneArgs -WindowStyle Hidden -PassThru
    $cmdline = "$rclone $($rcloneArgs -join ' ')"

    Write-Step "Waiting for ${Letter}: to appear"
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path "${Letter}:\") { break }
        if ($proc.HasExited) {
            Write-Fail "rclone exited (code $($proc.ExitCode)) before mount appeared. Check $logPath"
            return $null
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not (Test-Path "${Letter}:\")) {
        Write-Fail "${Letter}: did not appear within 30 s. Check $logPath"
        try { $proc | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
        return $null
    }
    Write-Ok "${Letter}: mounted (rclone pid $($proc.Id))"
    return [PSCustomObject]@{ Process = $proc; CommandLine = $cmdline; LogPath = $logPath }
}

# ============================================================
# MAIN
# ============================================================

if ($InstallPrerequisites) {
    Install-Prerequisites
    exit 0
}

Write-Banner 'Forensic Storage Lab — Drive Mapping (rclone + WinFsp)'
Write-Host '  Optional convenience access path. Use Storage Explorer or AzCopy for' -ForegroundColor DarkGray
Write-Host '  durable bulk ingestion of large evidence images.' -ForegroundColor DarkGray

# 1. Resolve parameters from bicepparam if needed
if (-not $ResourceGroup) {
    $ResourceGroup = Read-BicepParam 'resourceGroupName'
    if (-not $ResourceGroup) {
        Write-Fail "Could not read resourceGroupName from $BicepParam. Pass -ResourceGroup."
        exit 1
    }
}
if (-not $NamePrefix) {
    $NamePrefix = Read-BicepParam 'namePrefix'
    if (-not $NamePrefix) { $NamePrefix = 'forensiclab' }
}

# 2. Preflight
Write-Banner 'Preflight'

Write-Step 'rclone present'
$rinfo = Get-RcloneInfo
if (-not $rinfo) {
    Write-Fail "rclone not found. Run elevated: .\scripts\mount-evidence-drive.ps1 -InstallPrerequisites"
    exit 1
}
if ($rinfo.Version -and $rinfo.Version -lt $MinRcloneVersion) {
    Write-Fail "rclone $($rinfo.Version) is older than required $MinRcloneVersion. Upgrade via 'winget upgrade Rclone.Rclone'."
    exit 1
}
Write-Ok "rclone $($rinfo.Version) at $($rinfo.Path)"

Write-Step 'WinFsp installed'
if (-not (Test-WinFspInstalled)) {
    Write-Fail "WinFsp not detected. Run elevated: .\scripts\mount-evidence-drive.ps1 -InstallPrerequisites"
    exit 1
}
Write-Ok 'WinFsp present.'

Write-Step 'Azure CLI present'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Fail "Azure CLI not found. Install: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
}
Write-Ok 'az on PATH.'

if (Test-IsAdmin) {
    Write-Warn2 'Running as Administrator. The mounted drive may not appear in your normal Explorer session.'
    Write-Host '            Recommended: close this window and run as the investigator user (non-elevated).' -ForegroundColor DarkGray
}

$account = Test-AzContext
if (-not $account) { exit 1 }

if (-not $StorageAccountName) {
    $StorageAccountName = Resolve-StorageAccountName -Rg $ResourceGroup -Prefix $NamePrefix
    if (-not $StorageAccountName) { exit 1 }
}

if (-not (Test-PrivateDns -Account $StorageAccountName)) {
    Write-Fail 'Private DNS validation failed. Aborting.'
    exit 1
}

Write-Step 'Drive letters available'
$evOk = Test-DriveLetterAvailable -Letter $EvidenceDriveLetter
$rcOk = Test-DriveLetterAvailable -Letter $ReceiptDriveLetter
if (-not ($evOk -and $rcOk)) {
    Write-Host '     Override with -EvidenceDriveLetter / -ReceiptDriveLetter.' -ForegroundColor DarkGray
    exit 1
}

if ($Preflight) {
    Write-Banner 'Preflight complete'
    Write-Host '  All checks passed. Re-run without -Preflight to mount.' -ForegroundColor Green
    exit 0
}

# 3. rclone config
Write-Banner 'Mounting'
$remote = Write-RcloneConfig -Account $StorageAccountName

# 4. Mount evidence (read-write) and chain-of-custody (read-only)
$evMount = Start-RcloneMount -Remote $remote -Container $EvidenceContainer `
    -Letter $EvidenceDriveLetter -VolumeLabel 'Forensic Evidence' -ReadOnly:$false
if (-not $evMount) { exit 1 }
Save-MountState -Letter $EvidenceDriveLetter -Proc $evMount.Process `
    -Container $EvidenceContainer -Account $StorageAccountName `
    -Cmdline $evMount.CommandLine -ReadOnly $false

$rcMount = Start-RcloneMount -Remote $remote -Container $ReceiptContainer `
    -Letter $ReceiptDriveLetter -VolumeLabel 'Chain of Custody' -ReadOnly:$true
if (-not $rcMount) {
    Write-Warn2 'Chain-of-custody mount failed. Evidence drive remains mounted.'
    exit 1
}
Save-MountState -Letter $ReceiptDriveLetter -Proc $rcMount.Process `
    -Container $ReceiptContainer -Account $StorageAccountName `
    -Cmdline $rcMount.CommandLine -ReadOnly $true

# 5. Summary
Write-Banner 'Mounted'
Write-Host ''
Write-Host "  EVIDENCE DRIVE   ${EvidenceDriveLetter}:\   read-write   ($EvidenceContainer)" -ForegroundColor Green
Write-Host "  CUSTODY DRIVE    ${ReceiptDriveLetter}:\   read-only    ($ReceiptContainer)" -ForegroundColor Green
Write-Host ''
Write-Host "  Storage account: $StorageAccountName"
Write-Host "  Auth:            Entra ID via Azure CLI cached token (use_az)"
Write-Host "  Logs:            $LogDir"
Write-Host ''
Write-Host '  Notes:' -ForegroundColor DarkGray
Write-Host '   - Folders appear in HNS as you copy files into them. Avoid pre-creating empty folders.' -ForegroundColor DarkGray
Write-Host '   - Wait for File Explorer to finish copy before closing this PowerShell window.' -ForegroundColor DarkGray
Write-Host '   - Delete attempts on retained evidence will surface as Windows errors; the canonical' -ForegroundColor DarkGray
Write-Host '     evidence of the WORM block is in StorageBlobLogs (see lab-walkthrough.md Act 5).' -ForegroundColor DarkGray
Write-Host '   - If `az` token expires, re-run `az login` (the mount picks up the new token).' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Dismount: .\scripts\dismount-evidence-drive.ps1' -ForegroundColor Cyan
Write-Host ''
