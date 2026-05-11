using './main.bicep'

param location = 'eastus2'
param resourceGroupName = 'rg-forensic-storage-lab-v3'
param namePrefix = 'forensiclab'
param vnetAddressPrefix = '10.1.0.0/16'
param subnetAddressPrefix = '10.1.0.0/24'
param blobSoftDeleteRetentionDays = 90
param containerSoftDeleteRetentionDays = 90
param retentionDays = 1
param hotToCoolDays = 60
param coolToArchiveDays = 730
param enableSiemExport = false

// Investigator principal IDs — replace with your own Entra ID object IDs.
// Each value is the object ID of an Entra user, group, or service principal that
// should receive Storage Blob Data Contributor on the forensic-evidence container.
param investigatorPrincipalIds = [
  '00000000-0000-0000-0000-000000000000'
]
param principalType = 'User'

param tags = {
  project: 'forensic-storage-lab'
  environment: 'demo'
}
