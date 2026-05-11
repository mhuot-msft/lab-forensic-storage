// Lifecycle management rules for forensic-evidence container

@description('Name of the storage account')
param storageAccountName string

@description('Days after last modification to move blobs to Cool tier')
param hotToCoolDays int = 60

@description('Days after last modification to move blobs to Archive tier')
param coolToArchiveDays int = 730

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource lifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'tier-evidence-to-cool'
          enabled: true
          type: 'Lifecycle'
          definition: {
            actions: {
              baseBlob: {
                tierToCool: {
                  daysAfterModificationGreaterThan: hotToCoolDays
                }
              }
            }
            filters: {
              blobTypes: [
                'blockBlob'
              ]
              prefixMatch: [
                'forensic-evidence/'
              ]
            }
          }
        }
        {
          name: 'tier-evidence-to-archive'
          enabled: true
          type: 'Lifecycle'
          definition: {
            actions: {
              baseBlob: {
                tierToArchive: {
                  daysAfterModificationGreaterThan: coolToArchiveDays
                }
              }
            }
            filters: {
              blobTypes: [
                'blockBlob'
              ]
              prefixMatch: [
                'forensic-evidence/'
              ]
            }
          }
        }
      ]
    }
  }
}
