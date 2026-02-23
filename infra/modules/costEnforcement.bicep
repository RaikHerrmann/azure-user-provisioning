// ============================================================================
// costEnforcement.bicep - Azure Automation for cost limit enforcement
// ============================================================================
// Deploys:
//   - Azure Automation Account
//   - Runbook: Set user to read-only when $20 limit is hit
//   - Runbook: Stop all resources in resource group
//   - Runbook: Delete resources after grace period
//   - Webhook for budget action group integration
//   - Managed Identity with necessary permissions
// ============================================================================

// === Parameters ===
@description('Azure region')
param location string

@description('Unique suffix for naming')
param uniqueSuffix string

@description('User Object ID')
param userObjectId string

@description('User email')
param userEmail string

@description('User display name')
param userDisplayName string

@description('Resource group name to manage')
param resourceGroupName string

@description('Subscription ID')
param subscriptionId string

@description('Grace period days before deletion')
param gracePeriodDays int

@description('Hard limit threshold for reference')
param hardLimitThreshold int

@description('Tags')
param tags object

// === Variables ===
var automationAccountName = 'aa-cost-${uniqueSuffix}'
var contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

// === Automation Account ===
resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    publicNetworkAccess: true
    disableLocalAuth: false
    encryption: {
      keySource: 'Microsoft.Automation'
    }
  }
}

// === RBAC: Give Automation Account's Managed Identity Contributor on the RG ===
// This allows the automation to manage resources (stop, delete, change RBAC)
resource automationContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, automationAccount.id, contributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleId)
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Automation Account Contributor for cost enforcement'
  }
}

// === Runbook: Cost Enforcement (Main Orchestrator) ===
resource costEnforcementRunbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: 'Invoke-CostEnforcement'
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell72'
    description: 'Main cost enforcement runbook - sets read-only, stops resources, schedules deletion'
    publishContentLink: {
      // Content will be uploaded by the orchestration script
      // Using inline placeholder
    }
    logProgress: true
    logVerbose: true
  }
}

// === Runbook: Grace Period Cleanup ===
resource cleanupRunbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: 'Invoke-GracePeriodCleanup'
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell72'
    description: 'Deletes all resources after grace period expires'
    publishContentLink: {
      // Content will be uploaded by the orchestration script
    }
    logProgress: true
    logVerbose: true
  }
}

// === Automation Variables (used by runbooks) ===
resource userObjectIdVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'UserObjectId'
  properties: {
    value: '"${userObjectId}"'
    isEncrypted: false
    description: 'Object ID of the user to manage'
  }
}

resource userEmailVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'UserEmail'
  properties: {
    value: '"${userEmail}"'
    isEncrypted: false
    description: 'Email of the user for notifications'
  }
}

resource userDisplayNameVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'UserDisplayName'
  properties: {
    value: '"${userDisplayName}"'
    isEncrypted: false
    description: 'Display name of the user'
  }
}

resource rgNameVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'ResourceGroupName'
  properties: {
    value: '"${resourceGroupName}"'
    isEncrypted: false
    description: 'Resource group to manage'
  }
}

resource subscriptionIdVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'SubscriptionId'
  properties: {
    value: '"${subscriptionId}"'
    isEncrypted: false
    description: 'Subscription ID'
  }
}

resource gracePeriodVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'GracePeriodDays'
  properties: {
    value: '"${gracePeriodDays}"'
    isEncrypted: false
    description: 'Grace period in days before resource deletion'
  }
}

resource hardLimitVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'HardLimitThreshold'
  properties: {
    value: '"${hardLimitThreshold}"'
    isEncrypted: false
    description: 'Hard budget limit in USD'
  }
}

resource contributorRoleIdVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'ContributorRoleId'
  properties: {
    value: '"${contributorRoleId}"'
    isEncrypted: false
    description: 'Contributor role definition ID'
  }
}

resource readerRoleIdVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'ReaderRoleId'
  properties: {
    value: '"${readerRoleId}"'
    isEncrypted: false
    description: 'Reader role definition ID'
  }
}

// === Outputs ===
output automationAccountName string = automationAccount.name
output automationAccountId string = automationAccount.id
output automationPrincipalId string = automationAccount.identity.principalId
output costEnforcementRunbookName string = costEnforcementRunbook.name
output cleanupRunbookName string = cleanupRunbook.name
