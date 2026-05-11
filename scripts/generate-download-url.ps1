<#
.SYNOPSIS
    Generates a time-limited, read-only download URL for a blob using User Delegation SAS.

.DESCRIPTION
    Creates a shareable download URL for a specific blob in the forensic storage account.
    Uses User Delegation SAS, which is signed with the caller's Entra ID credentials --
    not storage account keys. This works even with shared key access disabled.

    The generated URL:
    - Is read-only (download only)
    - Expires after the specified duration (default: 1 hour)
    - Is traceable to the Entra ID principal who generated it
    - Requires approved private endpoint access (public access is disabled on the storage account)

    The recipient must use the approved private endpoint path to use the URL. The SAS token
    grants authorization to download; it does not bypass network restrictions.

.PARAMETER StorageAccountName
    Name of the Azure Storage account.

.PARAMETER BlobName
    Full blob path including case folder (e.g., case-2026-002/image.e01).

.PARAMETER ContainerName
    Container name (default: forensic-evidence).

.PARAMETER ExpiryHours
    Number of hours until the URL expires (default: 1, maximum: 24).

.EXAMPLE
    .\generate-download-url.ps1 -StorageAccountName "forensiclab..." -BlobName "case-2026-002/image.e01"

.EXAMPLE
    .\generate-download-url.ps1 -StorageAccountName "forensiclab..." -BlobName "case-2026-002/image.e01" -ExpiryHours 4

.NOTES
    Requires:
    - Azure CLI v2.50+ with active 'az login' session
    - Storage Blob Data Contributor or Storage Blob Data Reader role on the storage account
    - Approved private endpoint access to the storage account
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$StorageAccountName,

    [Parameter(Mandatory)]
    [string]$BlobName,

    [string]$ContainerName = 'forensic-evidence',

    [ValidateRange(1, 24)]
    [int]$ExpiryHours = 1
)

$ErrorActionPreference = 'Stop'

# Validate Azure CLI session
$accountJson = az account show 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accountJson)) {
    Write-Error "Not logged in to Azure CLI. Run 'az login' first."
    exit 1
}
$account = $accountJson | ConvertFrom-Json
Write-Host "Signed in as: $($account.user.name)" -ForegroundColor DarkGray

# Verify the blob exists before generating a URL
Write-Host "Verifying blob exists..." -ForegroundColor Cyan
$blobCheckJson = az storage blob show `
    --account-name $StorageAccountName `
    --container-name $ContainerName `
    --name $BlobName `
    --auth-mode login 2>$null

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($blobCheckJson)) {
    Write-Error "Blob '$ContainerName/$BlobName' not found or not accessible."
    exit 1
}

$blobCheck = $blobCheckJson | ConvertFrom-Json
$blobSize = $blobCheck.properties.contentLength
Write-Host "  Blob found: $BlobName ($blobSize bytes)" -ForegroundColor DarkGray

# Calculate expiry time (UTC)
$expiry = (Get-Date).ToUniversalTime().AddHours($ExpiryHours).ToString('yyyy-MM-ddTHH:mm:ssZ')
Write-Host "  URL expires: $expiry UTC" -ForegroundColor DarkGray

# Generate User Delegation SAS URL
Write-Host "Generating User Delegation SAS URL..." -ForegroundColor Cyan
$sasErrorFile = [System.IO.Path]::GetTempFileName()
try {
    $sasUrl = az storage blob generate-sas `
        --account-name $StorageAccountName `
        --container-name $ContainerName `
        --name $BlobName `
        --permissions r `
        --expiry $expiry `
        --auth-mode login `
        --as-user `
        --full-uri `
        --only-show-errors `
        --output tsv 2>$sasErrorFile

    if ($LASTEXITCODE -ne 0) {
        $sasError = Get-Content -Path $sasErrorFile -Raw
        Write-Error "Failed to generate SAS URL. Ensure you have Storage Blob Data Contributor or Reader role.`n$sasError"
        exit 1
    }
}
finally {
    if (Test-Path $sasErrorFile) { Remove-Item $sasErrorFile -Force }
}

Write-Host ""
Write-Host "Download URL (expires in $ExpiryHours hour(s)):" -ForegroundColor Green
Write-Host $sasUrl
Write-Host ""
Write-Host "Share this URL with anyone who has private network access." -ForegroundColor Yellow
Write-Host "The recipient can download using a browser, curl, azcopy, or Storage Explorer." -ForegroundColor DarkGray
Write-Host ""
Write-Host "Security notes:" -ForegroundColor Yellow
Write-Host "  - This URL is read-only and time-limited" -ForegroundColor DarkGray
Write-Host "  - Generation is logged under your Entra ID identity" -ForegroundColor DarkGray
Write-Host "  - Private network access is still required to use the URL" -ForegroundColor DarkGray
