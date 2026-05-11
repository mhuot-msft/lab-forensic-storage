// Log Analytics workspace, diagnostic settings, Defender for Storage, and alerting

@description('Azure region for all resources')
param location string

@description('Name of the Log Analytics workspace')
param workspaceName string

@description('Name of the storage account to monitor')
param storageAccountName string

@description('Tags to apply to all resources')
param tags object = {}

// Reference existing storage account and blob services for scoping
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: storageAccount
  name: 'default'
}

// Log Analytics workspace as SIEM pipeline stub
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 90
  }
}

// Diagnostic settings: log all blob read, write, delete operations
resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'forensic-blob-diagnostics'
  scope: blobServices
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'StorageRead'
        enabled: true
      }
      {
        category: 'StorageWrite'
        enabled: true
      }
      {
        category: 'StorageDelete'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

// Defender for Storage (per-transaction plan)
resource defenderForStorage 'Microsoft.Security/defenderForStorageSettings@2022-12-01-preview' = {
  name: 'current'
  scope: storageAccount
  properties: {
    isEnabled: true
    overrideSubscriptionLevelSettings: true
    malwareScanning: {
      onUpload: {
        isEnabled: true
        capGBPerMonth: 5000
      }
    }
    sensitiveDataDiscovery: {
      isEnabled: true
    }
  }
}

// Alert rule: delete attempts on forensic evidence container
resource deleteAlertRule 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-evidence-delete-attempt'
  location: location
  tags: tags
  properties: {
    displayName: 'Delete Attempt on Forensic Evidence'
    description: 'Fires when a delete operation is attempted against the forensic-evidence container'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [
      logAnalytics.id
    ]
    criteria: {
      allOf: [
        {
          query: '''
StorageBlobLogs
| where OperationName startswith "Delete"
| where ObjectKey has "forensic-evidence"
| project TimeGenerated, CallerIpAddress, UserAgentHeader, OperationName, ObjectKey, StatusCode, StatusText
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
        }
      ]
    }
    actions: {
      actionGroups: []
    }
  }
}

output logAnalyticsWorkspaceId string = logAnalytics.id
output logAnalyticsWorkspaceName string = logAnalytics.name
