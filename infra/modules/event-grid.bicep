// Event Grid subscription for hash Function, created directly on the storage account.
// This avoids conflicts with Defender for Storage, which auto-creates its own system
// topic on each storage account. Resource-scoped subscriptions let Azure manage the
// system topic transparently — no naming conflicts on first deploy.

@description('Storage account name')
param storageAccountName string

@description('Function App resource ID for the event subscription endpoint')
param hashFunctionId string

resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageAccountName
}

resource hashSubscription 'Microsoft.EventGrid/eventSubscriptions@2024-06-01-preview' = {
  name: 'hash-evidence-trigger'
  scope: storageAccount
  properties: {
    destination: {
      endpointType: 'AzureFunction'
      properties: {
        resourceId: '${hashFunctionId}/functions/HashEvidence'
        maxEventsPerBatch: 1
        preferredBatchSizeInKilobytes: 64
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.Storage.BlobCreated'
      ]
      subjectBeginsWith: '/blobServices/default/containers/forensic-evidence'
    }
    eventDeliverySchema: 'EventGridSchema'
    retryPolicy: {
      maxDeliveryAttempts: 5
      eventTimeToLiveInMinutes: 1440
    }
  }
}
