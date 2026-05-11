<#
.SYNOPSIS
    End-to-end CLI validation of the Forensic Storage Lab — all 7 acts.

.DESCRIPTION
    Runs the complete demo workflow using only Azure CLI and PowerShell,
    producing a PASS/FAIL report for each act. This serves as both a
    validation tool and an alternative CLI-based demo (no Storage Explorer).

    Each run uses a unique prefix to avoid collisions with prior runs.
    Evidence blobs are immutable and cannot be cleaned up — this is by design.

.PARAMETER StorageAccountName
    Storage account name (ADLS Gen2 with HNS enabled).

.PARAMETER ResourceGroup
    Resource group containing the lab resources.

.PARAMETER WorkspaceId
    Log Analytics workspace ID for KQL queries.

.PARAMETER SkipKql
    Skip Act 5 (KQL) if logs haven't had time to ingest.

.EXAMPLE
    .\validate-demo.ps1 `
      -StorageAccountName "<storage-account-name>" `
      -ResourceGroup "rg-forensic-storage-lab" `
      -WorkspaceId "<log-analytics-workspace-guid>"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$StorageAccountName,

    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$WorkspaceId,

    [switch]$SkipKql
)

$ErrorActionPreference = 'Continue'
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$testPrefix = "validation/$runId"
$results = @()

$acctName = $StorageAccountName

function Write-Act {
    param([string]$Act, [string]$Title)
    Write-Host "`n$('=' * 60)" -ForegroundColor Cyan
    Write-Host "  $Act — $Title" -ForegroundColor Cyan
    Write-Host "$('=' * 60)" -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Step)
    Write-Host "`n  >> $Step" -ForegroundColor Yellow
}

function Add-Result {
    param([string]$Act, [string]$Test, [string]$Status, [string]$Detail)
    $icon = if ($Status -eq 'PASS') { '[PASS]' } elseif ($Status -eq 'FAIL') { '[FAIL]' } else { '[SKIP]' }
    $color = if ($Status -eq 'PASS') { 'Green' } elseif ($Status -eq 'FAIL') { 'Red' } else { 'DarkGray' }
    Write-Host "     $icon $Test" -ForegroundColor $color
    if ($Detail) { Write-Host "           $Detail" -ForegroundColor DarkGray }
    $script:results += [PSCustomObject]@{ Act = $Act; Test = $Test; Status = $Status; Detail = $Detail }
}

# ============================================================
# PREFLIGHT — Verify prerequisites
# ============================================================
Write-Act "Preflight" "Environment Checks"

Write-Step "Azure CLI authenticated"
$account = az account show --query "{name:name, id:id, user:user.name}" -o json 2>$null | ConvertFrom-Json
if ($account) {
    Add-Result "Preflight" "Azure CLI login" "PASS" "$($account.user) / $($account.name)"
} else {
    Add-Result "Preflight" "Azure CLI login" "FAIL" "Not logged in. Run 'az login' first."
    Write-Host "`nPreflight failed. Exiting." -ForegroundColor Red
    exit 1
}

Write-Step "DNS resolves to private IP"
$dns = Resolve-DnsName "$acctName.blob.core.windows.net" -ErrorAction SilentlyContinue
$privateIp = $dns | Where-Object { $_.IP4Address -match '^10\.' } | Select-Object -First 1
if ($privateIp) {
    Add-Result "Preflight" "Private DNS resolution" "PASS" "$acctName.blob → $($privateIp.IP4Address)"
} else {
    Add-Result "Preflight" "Private DNS resolution" "FAIL" "Not resolving to private IP. Ensure approved private endpoint access is active."
    Write-Host "`nPreflight failed. Exiting." -ForegroundColor Red
    exit 1
}

Write-Step "Resource group exists"
$rg = az group show --name $ResourceGroup -o json 2>$null | ConvertFrom-Json
if ($rg) {
    Add-Result "Preflight" "Resource group" "PASS" "$ResourceGroup ($($rg.location))"
} else {
    Add-Result "Preflight" "Resource group" "FAIL" "$ResourceGroup not found."
    exit 1
}

# ============================================================
# ACT 1 — The Vault (Infrastructure Verification)
# ============================================================
Write-Act "Act 1" "The Vault — Infrastructure Verification"

Write-Step "Verifying storage account: $acctName"
$acct = az storage account show --name $acctName --resource-group $ResourceGroup -o json 2>$null | ConvertFrom-Json

# Public access disabled
$pubAccess = $acct.publicNetworkAccess
Add-Result "Act 1" "Public network access" `
    $(if ($pubAccess -eq 'Disabled') { 'PASS' } else { 'FAIL' }) `
    "publicNetworkAccess: $pubAccess"

# Shared keys disabled
$sharedKey = $acct.allowSharedKeyAccess
Add-Result "Act 1" "Shared key access disabled" `
    $(if ($sharedKey -eq $false) { 'PASS' } else { 'FAIL' }) `
    "allowSharedKeyAccess: $sharedKey"

# HNS check
$hns = $acct.isHnsEnabled
Add-Result "Act 1" "Hierarchical namespace" `
    $(if ($hns -eq $true) { 'PASS' } else { 'FAIL' }) `
    "isHnsEnabled: $hns"

# Network rules
$defaultAction = $acct.networkRuleSet.defaultAction
Add-Result "Act 1" "Default network action" `
    $(if ($defaultAction -eq 'Deny') { 'PASS' } else { 'FAIL' }) `
    "defaultAction: $defaultAction"

# Immutability - check forensic-evidence container
$immutabilityJson = az storage container immutability-policy show `
    --account-name $acctName `
    --container-name "forensic-evidence" `
    -o json 2>$null
$immutability = $null
if ($immutabilityJson) { $immutability = $immutabilityJson | ConvertFrom-Json }
$retDays = if ($immutability) { $immutability.immutabilityPeriodSinceCreationInDays } else { 0 }
Add-Result "Act 1" "Immutability policy" `
    $(if ([int]$retDays -gt 0) { 'PASS' } else { 'FAIL' }) `
    "Retention: $retDays days"

# Containers exist
$containers = az storage container list --account-name $acctName --auth-mode login --query "[].name" -o json 2>$null | ConvertFrom-Json
$hasEvidence = $containers -contains 'forensic-evidence'
$hasCoc = $containers -contains 'chain-of-custody'
Add-Result "Act 1" "forensic-evidence container" `
    $(if ($hasEvidence) { 'PASS' } else { 'FAIL' }) ""
Add-Result "Act 1" "chain-of-custody container" `
    $(if ($hasCoc) { 'PASS' } else { 'FAIL' }) ""

# Private endpoints
Write-Step "Checking private endpoints"
$peList = az network private-endpoint list --resource-group $ResourceGroup -o json 2>$null | ConvertFrom-Json
$peCount = if ($peList) { $peList.Count } else { 0 }
Add-Result "Act 1" "Private endpoints deployed" `
    $(if ($peCount -ge 2) { 'PASS' } else { 'FAIL' }) `
    "$peCount private endpoints found"

# Function app
Write-Step "Checking function app"
$funcApps = az functionapp list --resource-group $ResourceGroup --query "[].{name:name, state:state}" -o json 2>$null | ConvertFrom-Json
$hashFunc = $funcApps | Where-Object { $_.name -match 'hash' }
Add-Result "Act 1" "Hash function app" `
    $(if ($hashFunc -and $hashFunc.state -eq 'Running') { 'PASS' } else { 'FAIL' }) `
    "$($hashFunc.name): $($hashFunc.state)"

# Defender for Storage
Write-Step "Checking Defender for Storage"
$defender = az security pricing show --name StorageAccounts --query "pricingTier" -o tsv 2>$null
Add-Result "Act 1" "Defender for Storage" `
    $(if ($defender -eq 'Standard') { 'PASS' } else { 'FAIL' }) `
    "Tier: $defender"

# ============================================================
# ACT 2 — The Upload
# ============================================================
Write-Act "Act 2" "The Upload — Evidence Ingestion via CLI"

$testContent = "Validation run $runId — forensic evidence test file for integrity verification."
$testFileName = "validation-evidence-$runId.txt"
$localTestFile = Join-Path $env:TEMP $testFileName
Set-Content -Path $localTestFile -Value $testContent -NoNewline

$blobPath = "$testPrefix/$testFileName"

Write-Step "Uploading to $acctName - $blobPath"
$uploadResult = az storage blob upload `
    --account-name $acctName `
    --container-name "forensic-evidence" `
    --name $blobPath `
    --file $localTestFile `
    --auth-mode login `
    --overwrite false 2>&1

$uploadSuccess = $LASTEXITCODE -eq 0
Add-Result "Act 2" "Evidence upload" `
    $(if ($uploadSuccess) { 'PASS' } else { 'FAIL' }) `
    $(if ($uploadSuccess) { "Uploaded $blobPath" } else { "$uploadResult" })

# ============================================================
# ACT 3 — The Hash (Chain-of-Custody Receipts)
# ============================================================
Write-Act "Act 3" "The Hash — Automated Chain-of-Custody Receipts"

Write-Host "  Waiting 45 seconds for Event Grid + Function pipeline..." -ForegroundColor DarkGray
Start-Sleep -Seconds 45

$receiptPath = "$testPrefix/$testFileName.sha256.json"

Write-Step "Checking receipt: $receiptPath"

# Poll for receipt (up to 90 seconds additional)
$receiptFound = $false
$receiptFile = Join-Path $env:TEMP "receipt-$runId.json"
for ($i = 0; $i -lt 6; $i++) {
    $dlResult = az storage blob download `
        --account-name $acctName `
        --container-name "chain-of-custody" `
        --name $receiptPath `
        --file $receiptFile `
        --auth-mode login 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $receiptFile)) {
        $receiptFound = $true
        break
    }
    Write-Host "    Waiting 15s for receipt... (attempt $($i+1)/6)" -ForegroundColor DarkGray
    Start-Sleep -Seconds 15
}

if ($receiptFound) {
    $receipt = Get-Content $receiptFile | ConvertFrom-Json
    Add-Result "Act 3" "Hash receipt exists" "PASS" "hashValue: $($receipt.hashValue.Substring(0,16))..."
    Add-Result "Act 3" "Receipt has required fields" `
        $(if ($receipt.hashValue -and $receipt.hashedAt -and $receipt.hashedBy -and $receipt.evidenceSizeBytes) { 'PASS' } else { 'FAIL' }) `
        "algorithm: $($receipt.hashAlgorithm), size: $($receipt.evidenceSizeBytes)B"
} else {
    Add-Result "Act 3" "Hash receipt exists" "FAIL" "Receipt not found after 135 seconds"
    Add-Result "Act 3" "Receipt has required fields" "SKIP" "No receipt to validate"
}

# ============================================================
# ACT 4 — The Lock (Immutability Enforcement)
# ============================================================
Write-Act "Act 4" "The Lock — Immutability Enforcement"

$blobPath = "$testPrefix/$testFileName"

# Attempt delete
Write-Step "Attempting delete (expect failure)"
$deleteResult = az storage blob delete `
    --account-name $acctName `
    --container-name "forensic-evidence" `
    --name $blobPath `
    --auth-mode login 2>&1

Add-Result "Act 4" "Delete blocked" `
    $(if ($LASTEXITCODE -ne 0 -and ($deleteResult -match 'Immutable|immutable')) { 'PASS' } else { 'FAIL' }) `
    $(if ($deleteResult -match 'Immutable|immutable') { "BlobImmutableDueToPolicy" } else { "Unexpected: $deleteResult" })

# Attempt overwrite
Write-Step "Attempting overwrite (expect failure)"
$overwriteFile = Join-Path $env:TEMP "overwrite-$runId.txt"
Set-Content -Path $overwriteFile -Value "TAMPERED CONTENT" -NoNewline
$overwriteResult = az storage blob upload `
    --account-name $acctName `
    --container-name "forensic-evidence" `
    --name $blobPath `
    --file $overwriteFile `
    --auth-mode login `
    --overwrite true 2>&1

if ($LASTEXITCODE -ne 0 -and ($overwriteResult -match 'Immutable|immutable')) {
    Add-Result "Act 4" "Overwrite blocked" "PASS" "BlobImmutableDueToPolicy"
} else {
    Add-Result "Act 4" "Overwrite blocked" "FAIL" "Unexpected: $overwriteResult"
}

# ============================================================
# ACT 5 — The Audit (KQL Queries)
# ============================================================
Write-Act "Act 5" "The Audit — Log Analytics Queries"

if ($SkipKql) {
    Add-Result "Act 5" "KQL queries" "SKIP" "Skipped via -SkipKql flag (logs may need time to ingest)"
} else {
    Write-Host "  Note: Queries cover all activity in the last 4 hours." -ForegroundColor DarkGray

    # Query: Operation summary
    Write-Step "Operation summary"
    $opSummary = az monitor log-analytics query `
        --workspace $WorkspaceId `
        --analytics-query "StorageBlobLogs | summarize count() by OperationName | order by count_ desc | take 10" `
        --timespan PT4H -o json 2>$null | ConvertFrom-Json
    Add-Result "Act 5" "Operation summary query" `
        $(if ($opSummary -and $opSummary.Count -gt 0) { 'PASS' } else { 'FAIL' }) `
        "$($opSummary.Count) operation types found"

    # Query: Failed deletes (immutability)
    Write-Step "Failed delete attempts"
    $failedDeletes = az monitor log-analytics query `
        --workspace $WorkspaceId `
        --analytics-query "StorageBlobLogs | where OperationName == 'DeleteBlob' and toint(StatusCode) >= 400 | summarize count()" `
        --timespan PT4H -o json 2>$null | ConvertFrom-Json
    $deleteCount = if ($failedDeletes) { $failedDeletes[0].count_ } else { 0 }
    Add-Result "Act 5" "Failed deletes logged" `
        $(if ([int]$deleteCount -gt 0) { 'PASS' } else { 'FAIL' }) `
        "$deleteCount failed delete attempts in logs"

    # Query: Hash receipts (chain-of-custody PutBlob)
    Write-Step "Hash receipt operations"
    $hashOps = az monitor log-analytics query `
        --workspace $WorkspaceId `
        --analytics-query "StorageBlobLogs | where ObjectKey has 'chain-of-custody' and OperationName == 'PutBlob' | summarize count()" `
        --timespan PT4H -o json 2>$null | ConvertFrom-Json
    $hashCount = if ($hashOps) { $hashOps[0].count_ } else { 0 }
    Add-Result "Act 5" "Hash receipts in audit log" `
        $(if ([int]$hashCount -gt 0) { 'PASS' } else { 'FAIL' }) `
        "$hashCount receipt writes logged"

    # Query: Caller identity present
    Write-Step "Caller identity in logs"
    $identityOps = az monitor log-analytics query `
        --workspace $WorkspaceId `
        --analytics-query "StorageBlobLogs | where isnotempty(RequesterUpn) | summarize dcount(RequesterUpn)" `
        --timespan PT4H -o json 2>$null | ConvertFrom-Json
    $identityCount = if ($identityOps) { $identityOps[0].dcount_RequesterUpn } else { 0 }
    Add-Result "Act 5" "Investigator identity tracking" `
        $(if ([int]$identityCount -gt 0) { 'PASS' } else { 'FAIL' }) `
        "$identityCount distinct identities in logs"
}

# ============================================================
# ACT 6 — The Retrieve (Download + Verify Integrity)
# ============================================================
Write-Act "Act 6" "The Retrieve — Download and Integrity Verification"

$blobPath = "$testPrefix/$testFileName"
$receiptFile = Join-Path $env:TEMP "receipt-$runId.json"

if (-not (Test-Path $receiptFile)) {
    Add-Result "Act 6" "Integrity verification" "SKIP" "No receipt from Act 3"
} else {
    Write-Step "Downloading evidence for verification"
    $downloadFile = Join-Path $env:TEMP "verify-$runId.txt"

    $receipt = Get-Content $receiptFile | ConvertFrom-Json
    az storage blob download `
        --account-name $acctName `
        --container-name 'forensic-evidence' `
        --name $blobPath `
        --file $downloadFile `
        --auth-mode login 2>$null | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Add-Result "Act 6" "Evidence download" "FAIL" "Download failed"
    } else {
        Add-Result "Act 6" "Evidence download" "PASS" ""

        $localHash = (Get-FileHash -Path $downloadFile -Algorithm SHA256).Hash.ToLower()

        Add-Result "Act 6" "Hash match" `
            $(if ($localHash -eq $receipt.hashValue) { 'PASS' } else { 'FAIL' }) `
            "Local=$($localHash.Substring(0,16))... Receipt=$($receipt.hashValue.Substring(0,16))..."
    }

    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
}

# ============================================================
# ACT 7 — The Lifecycle (Policy Verification)
# ============================================================
Write-Act "Act 7" "The Lifecycle — Cost Optimization Policies"

Write-Step "Checking lifecycle policy"
$policy = az storage account management-policy show `
    --account-name $acctName `
    --resource-group $ResourceGroup -o json 2>$null | ConvertFrom-Json

$rules = $policy.policy.rules
$coolRule = $rules | Where-Object { $_.name -eq 'tier-evidence-to-cool' }
$archiveRule = $rules | Where-Object { $_.name -eq 'tier-evidence-to-archive' }

Add-Result "Act 7" "Cool tiering rule" `
    $(if ($coolRule -and $coolRule.enabled) { 'PASS' } else { 'FAIL' }) `
    $(if ($coolRule) { "After $($coolRule.definition.actions.baseBlob.tierToCool.daysAfterModificationGreaterThan) days" } else { "Not found" })

Add-Result "Act 7" "Archive tiering rule" `
    $(if ($archiveRule -and $archiveRule.enabled) { 'PASS' } else { 'FAIL' }) `
    $(if ($archiveRule) { "After $($archiveRule.definition.actions.baseBlob.tierToArchive.daysAfterModificationGreaterThan) days" } else { "Not found" })

# ============================================================
# REPORT
# ============================================================
Write-Host "`n$('=' * 60)" -ForegroundColor Magenta
Write-Host "  VALIDATION REPORT — Run $runId" -ForegroundColor Magenta
Write-Host "$('=' * 60)" -ForegroundColor Magenta

$passed = ($results | Where-Object { $_.Status -eq 'PASS' }).Count
$failed = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$skipped = ($results | Where-Object { $_.Status -eq 'SKIP' }).Count
$total = $results.Count

Write-Host "`n  Total: $total | PASS: $passed | FAIL: $failed | SKIP: $skipped" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })

if ($failed -gt 0) {
    Write-Host "`n  Failed tests:" -ForegroundColor Red
    $results | Where-Object { $_.Status -eq 'FAIL' } | ForEach-Object {
        Write-Host "    [$($_.Act)] $($_.Test): $($_.Detail)" -ForegroundColor Red
    }
}

# Summary by act
Write-Host "`n  Per-act summary:" -ForegroundColor White
$results | Group-Object Act | ForEach-Object {
    $actPassed = ($_.Group | Where-Object { $_.Status -eq 'PASS' }).Count
    $actTotal = $_.Group.Count
    $actIcon = if (($_.Group | Where-Object { $_.Status -eq 'FAIL' }).Count -eq 0) { "PASS" } else { "FAIL" }
    $color = if ($actIcon -eq 'PASS') { 'Green' } else { 'Red' }
    Write-Host "    [$actIcon] $($_.Name) ($actPassed/$actTotal)" -ForegroundColor $color
}

# Clean up local temp files
Remove-Item (Join-Path $env:TEMP "validation-evidence-$runId.txt") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:TEMP "overwrite-$runId.txt") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:TEMP "receipt-$runId.json") -Force -ErrorAction SilentlyContinue

Write-Host "`n  Test data prefix: $testPrefix (immutable — will not be cleaned up)" -ForegroundColor DarkGray
Write-Host "  Completed at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC' -AsUTC)" -ForegroundColor DarkGray
