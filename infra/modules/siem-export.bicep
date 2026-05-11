// Optional SIEM export via Event Hub for external SOC tooling integration

@description('Azure region for resources')
param location string

@description('Name prefix for resources')
param namePrefix string

@description('Name of the storage account to export logs from')
param storageAccountName string

@description('Tags to apply to all resources')
param tags object = {}

var eventHubNamespaceName = 'evhns-${namePrefix}'
var eventHubName = 'forensic-audit-logs'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: eventHubNamespaceName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
    capacity: 1
  }
}

resource eventHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: eventHubNamespace
  name: eventHubName
  properties: {
    messageRetentionInDays: 7
    partitionCount: 2
  }
}

resource sendAuthRule 'Microsoft.EventHub/namespaces/eventhubs/authorizationRules@2024-01-01' = {
  parent: eventHub
  name: 'DiagnosticsSend'
  properties: {
    rights: [
      'Send'
    ]
  }
}

resource listenAuthRule 'Microsoft.EventHub/namespaces/eventhubs/authorizationRules@2024-01-01' = {
  parent: eventHub
  name: 'SiemListen'
  properties: {
    rights: [
      'Listen'
    ]
  }
}

// Diagnostic setting to forward storage blob logs to Event Hub
resource siemDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'siem-export-blob-diagnostics'
  scope: blobServices
  properties: {
    eventHubAuthorizationRuleId: sendAuthRule.id
    eventHubName: eventHub.name
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
  }
}

output eventHubNamespaceName string = eventHubNamespace.name
output eventHubName string = eventHub.name
