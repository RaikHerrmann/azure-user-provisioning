// ============================================================================
// rbac.bicep - Role assignments for user within their resource group
// ============================================================================
// Assigns:
//   - Contributor role to the user (scoped to resource group only)
//   - Owner role to tenant admin for management operations
//
// Security notes:
//   - Contributor at RG scope does NOT allow creating resource groups
//   - Azure Policy at subscription scope provides an additional guardrail
//   - The tenant admin keeps Owner for administrative overrides
// ============================================================================

// === Parameters ===
@description('Object ID of the user in Entra ID')
param userObjectId string

@description('Object ID of the tenant admin')
param tenantAdminObjectId string

// === Variables ===
// Built-in role definition IDs
var contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
var ownerRoleId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'

// === Role Assignments ===

// User gets Contributor ONLY on the resource group (not subscription)
// This means the user can:
//   - Create, manage, delete resources WITHIN this RG
//   - Read resource configurations
// The user CANNOT:
//   - Create new resource groups
//   - Access other resource groups
//   - Modify subscription-level settings
//   - Manage RBAC assignments (that requires Owner or User Access Administrator)
resource userContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, userObjectId, contributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleId)
    principalId: userObjectId
    principalType: 'User'
    description: 'Contributor access for user sandbox environment - scoped to this RG only'
  }
}

// Tenant admin gets Owner on the resource group for full management
resource adminOwnerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, tenantAdminObjectId, ownerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', ownerRoleId)
    principalId: tenantAdminObjectId
    principalType: 'User'
    description: 'Owner access for tenant admin management'
  }
}

// === Outputs ===
output contributorAssignmentId string = userContributorAssignment.id
output adminOwnerAssignmentId string = adminOwnerAssignment.id
