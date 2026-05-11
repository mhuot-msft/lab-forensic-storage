<#
.SYNOPSIS
    End-to-end deployment script for the forensic storage lab.

.DESCRIPTION
    Deploys all infrastructure and application code in three phases:
    1. Main infrastructure WITHOUT Event Grid (storage, networking, PE, DNS, RBAC, Function App)
    2. Function code (hash-evidence Azure Function via remote build)
    3. Event Grid subscription (requires the HashEvidence function to exist)

    The deployment secures the storage account behind private endpoints.
    Your organization's approved access path to those endpoints is managed
    outside this lab.

.PARAMETER Location
    Azure region. Default: eastus2

.PARAMETER ResourceGroupName
    Resource group name. Read from infra/main.bicepparam if not provided.

.PARAMETER SkipInfra
    Skip step 1 (infrastructure). Use when re-running after a step 2/3 failure.

.PARAMETER SkipFunctionDeploy
    Skip step 2 (function code). Use when re-running after a step 3 failure.

.EXAMPLE
    .\deploy.ps1

.EXAMPLE
    .\deploy.ps1 -SkipFunctionDeploy
#>
[CmdletBinding()]
param(
    [string]$Location = 'eastus2',
    [string]$ResourceGroupName,
    [switch]$SkipInfra,
    [switch]$SkipFunctionDeploy
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$mainParams = Join-Path $RepoRoot "infra\main.bicepparam"

# Single source of truth: read resource group name from bicepparam if not provided
if (-not $ResourceGroupName) {
    $match = Select-String -Path $mainParams -Pattern "param resourceGroupName\s*=\s*'([^']+)'"
    if ($match) {
        $ResourceGroupName = $match.Matches[0].Groups[1].Value
    } else {
        Write-Error "Could not read resourceGroupName from $mainParams. Pass -ResourceGroupName explicitly."
        exit 1
    }
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Forensic Storage Lab — Full Deployment" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# -------------------------------------------------------------------
# Step 1: Main infrastructure (Event Grid deferred — function code must exist first)
# -------------------------------------------------------------------
if ($SkipInfra) {
    Write-Host "[1/3] Skipping infrastructure deployment (-SkipInfra)." -ForegroundColor DarkGray
} else {
    Write-Host "[1/3] Deploying main infrastructure (Event Grid deferred)..." -ForegroundColor Yellow

    $deployName = "forensiclab-main-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    az deployment sub create `
        --location $Location `
        --template-file (Join-Path $RepoRoot "infra\main.bicep") `
        --parameters $mainParams `
        --parameters deployEventGrid=false `
        --name $deployName `
        --output json | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Main infrastructure deployment failed."
        exit 1
    }
    Write-Host "  Main infrastructure deployed." -ForegroundColor Green
}

# -------------------------------------------------------------------
# Step 2: Function code (remote build via Oryx)
# -------------------------------------------------------------------
if ($SkipFunctionDeploy) {
    Write-Host "[2/3] Skipping function code deployment (-SkipFunctionDeploy)." -ForegroundColor DarkGray
} else {
    Write-Host "[2/3] Publishing function code to func-forensiclab-hash..." -ForegroundColor Yellow

    $funcDir = Join-Path $RepoRoot "functions\hash-evidence"
    $zipPath = Join-Path $env:TEMP "hash-evidence.zip"

    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path (Join-Path $funcDir "*") -DestinationPath $zipPath -Force

    # Deploy via ARM management plane with remote build.
    # config-zip works in SFI environments (no shared keys needed).
    # --build-remote triggers Oryx to install Python deps on the server.
    az functionapp deployment source config-zip `
        -n func-forensiclab-hash `
        -g $ResourceGroupName `
        --src $zipPath `
        --build-remote true `
        -o none 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "ZIP deploy failed. Check that the function app exists and is running."
        exit 1
    }
    Write-Host "  Function code deployed. Waiting for remote build + registration..." -ForegroundColor Green

    Remove-Item $zipPath -ErrorAction SilentlyContinue

    # Wait for function to register (Event Grid needs the endpoint to exist).
    # Remote build takes 2-5 min, then the host indexes — allow up to 10 min.
    $maxAttempts = 60
    $registered = $false
    for ($i = 1; $i -le $maxAttempts; $i++) {
        $funcs = az functionapp function list -n func-forensiclab-hash -g $ResourceGroupName --query "[].name" -o tsv 2>$null
        if ($funcs -match 'HashEvidence') {
            $registered = $true
            Write-Host "  HashEvidence function registered (after $($i * 10)s)." -ForegroundColor Green
            break
        }
        if ($i % 6 -eq 0) { Write-Host "    Still waiting... ($($i * 10)s elapsed)" -ForegroundColor DarkGray }
        Start-Sleep -Seconds 10
    }
    if (-not $registered) {
        Write-Host "`n  HashEvidence not registered after 10 minutes." -ForegroundColor Yellow
        Write-Host "  Infrastructure is deployed. Once the function appears, run:" -ForegroundColor Yellow
        Write-Host "    .\deploy.ps1 -SkipInfra -SkipFunctionDeploy" -ForegroundColor White
        Write-Host "`n  Check with: az functionapp function list -n func-forensiclab-hash -g $ResourceGroupName`n" -ForegroundColor White
        exit 0
    }
}

# -------------------------------------------------------------------
# Step 3: VNet integration + Event Grid
# -------------------------------------------------------------------
# VNet integration is applied via CLI (not Bicep) to avoid the EP1 VNETFailure
# race condition that occurs when VNet is deployed simultaneously with the app.
Write-Host "[3/3] Enabling VNet integration and Event Grid subscription..." -ForegroundColor Yellow

Write-Host "  Adding VNet integration..." -ForegroundColor DarkGray
az functionapp vnet-integration add `
    -n func-forensiclab-hash `
    -g $ResourceGroupName `
    --vnet vnet-forensiclab `
    --subnet snet-functions `
    -o none 2>&1
az functionapp config set -n func-forensiclab-hash -g $ResourceGroupName --vnet-route-all-enabled true -o none 2>&1

Write-Host "  Deploying Event Grid subscription..." -ForegroundColor DarkGray
$egDeployName = "forensiclab-final-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
az deployment sub create `
    --location $Location `
    --template-file (Join-Path $RepoRoot "infra\main.bicep") `
    --parameters $mainParams `
    --parameters deployEventGrid=true `
    --name $egDeployName `
    --output json | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Error "Event Grid deployment failed."
    Write-Host "  Check: az functionapp function list -n func-forensiclab-hash -g $ResourceGroupName" -ForegroundColor Yellow
    Write-Host "  Then: .\deploy.ps1 -SkipInfra -SkipFunctionDeploy" -ForegroundColor Yellow
    exit 1
}
Write-Host "  Event Grid subscription deployed." -ForegroundColor Green

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Deployment Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$acctName = az storage account list -g $ResourceGroupName --query "[?tags.storageMode=='hns'].name" -o tsv 2>$null
if (-not $acctName) { $acctName = az storage account list -g $ResourceGroupName --query "[0].name" -o tsv 2>$null }
Write-Host "  Storage account:  $acctName" -ForegroundColor White
Write-Host "  Resource group:   $ResourceGroupName" -ForegroundColor White

Write-Host "`n  Next steps:" -ForegroundColor Yellow
Write-Host "  1. Use your organization's approved access path to the storage private endpoint" -ForegroundColor White
Write-Host "  2. Verify DNS resolves $acctName.blob.core.windows.net to a private IP" -ForegroundColor White
Write-Host "  3. See docs/storage-explorer-setup.md for investigator access" -ForegroundColor White
