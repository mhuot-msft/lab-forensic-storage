<#
.SYNOPSIS
    Verifies evidence integrity by comparing local SHA-256 against the chain-of-custody receipt.

.DESCRIPTION
    Downloads the hash receipt from the chain-of-custody container and the evidence blob,
    computes local SHA-256, and compares against the receipt's hashValue.
    Reports PASS or FAIL with hash details.

.PARAMETER StorageAccountName
    Name of the Azure Storage account.

.PARAMETER BlobName
    Full blob path including case folder (e.g., case-2026-002/coc-test.txt).

.PARAMETER ContainerName
    Evidence container name (default: forensic-evidence).

.EXAMPLE
    .\verify-integrity.ps1 -StorageAccountName "forensiclab..." -BlobName "case-2026-002/coc-test.txt"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$StorageAccountName,

    [Parameter(Mandatory)]
    [string]$BlobName,

    [string]$ContainerName = 'forensic-evidence'
)

$ErrorActionPreference = 'Stop'

$receiptContainer = 'chain-of-custody'
$receiptName = "$BlobName.sha256.json"

# Step 1: Download the hash receipt
Write-Host "Retrieving chain-of-custody receipt for '$BlobName'..." -ForegroundColor Cyan
$receiptFile = Join-Path $env:TEMP "verify-receipt-$([System.IO.Path]::GetRandomFileName()).json"
az storage blob download `
    --account-name $StorageAccountName `
    --container-name $receiptContainer `
    --name $receiptName `
    --file $receiptFile `
    --auth-mode login `
    --no-progress 2>$null | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to download receipt. Has the hash function processed this blob?"
    exit 1
}

$receipt = Get-Content $receiptFile | ConvertFrom-Json
Write-Host "  Receipt hash:     $($receipt.hashValue)" -ForegroundColor Yellow
Write-Host "  Hashed at:        $($receipt.hashedAt)" -ForegroundColor DarkGray
Write-Host "  Hashed by:        $($receipt.hashedBy)" -ForegroundColor DarkGray
Write-Host "  Evidence size:    $($receipt.evidenceSizeBytes) bytes" -ForegroundColor DarkGray

# Step 2: Download the evidence blob
$tempFile = Join-Path $env:TEMP "verify-evidence-$([System.IO.Path]::GetRandomFileName())"
try {
    Write-Host "Downloading evidence blob for hash computation..." -ForegroundColor Cyan
    az storage blob download `
        --account-name $StorageAccountName `
        --container-name $ContainerName `
        --name $BlobName `
        --file $tempFile `
        --auth-mode login `
        --no-progress 2>$null | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to download evidence blob."
        exit 1
    }

    # Step 3: Compute and compare
    Write-Host "Computing SHA-256 hash of downloaded evidence..." -ForegroundColor Cyan
    $actualHash = (Get-FileHash -Path $tempFile -Algorithm SHA256).Hash.ToLower()
    Write-Host "  Local SHA-256:    $actualHash" -ForegroundColor Yellow

    if ($actualHash -eq $receipt.hashValue) {
        Write-Host ""
        Write-Host "RESULT: PASS - Hashes match. Evidence integrity verified." -ForegroundColor Green
        Write-Host "  Chain-of-custody receipt confirms this evidence is unmodified since ingestion." -ForegroundColor Green
    }
    else {
        Write-Host ""
        Write-Host "RESULT: FAIL - Hash mismatch detected!" -ForegroundColor Red
        Write-Host "  Receipt:  $($receipt.hashValue)" -ForegroundColor Red
        Write-Host "  Local:    $actualHash" -ForegroundColor Red
        exit 1
    }
}
finally {
    if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
    if (Test-Path $receiptFile) { Remove-Item $receiptFile -Force }
}
