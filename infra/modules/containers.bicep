// Forensic evidence and chain-of-custody containers with immutability policies

@description('Name of the storage account')
param storageAccountName string

@description('Retention period in days for time-based immutability policy')
param retentionDays int = 365

resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageAccountName
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' existing = {
  parent: storageAccount
  name: 'default'
}

// Container-level immutability only — no version-level immutable storage (VLWI).
// VLWI is permanently irreversible and prevents storage account deletion even when empty.
// For lab/sandbox environments, container-level WORM (unlocked) provides evidence
// protection while remaining deletable for teardown.
resource forensicEvidence 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobServices
  name: 'forensic-evidence'
  properties: {
    publicAccess: 'None'
  }
}

resource immutabilityPolicy 'Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies@2024-01-01' = {
  parent: forensicEvidence
  name: 'default'
  properties: {
    immutabilityPeriodSinceCreationInDays: retentionDays
    allowProtectedAppendWrites: false
  }
}

// Chain-of-custody container for hash receipts and audit records with immutability policy.
// Hash receipts must be as immutable as the evidence they describe, protecting the
// integrity of the cryptographic chain linking evidence to processing steps.
resource chainOfCustody 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobServices
  name: 'chain-of-custody'
  properties: {
    publicAccess: 'None'
  }
}

resource chainOfCustodyImmutabilityPolicy 'Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies@2024-01-01' = {
  parent: chainOfCustody
  name: 'default'
  properties: {
    immutabilityPeriodSinceCreationInDays: retentionDays
    allowProtectedAppendWrites: false
  }
}

output containerName string = forensicEvidence.name
