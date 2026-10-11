// The portal's nested "Key vault template" (one per edge machine), deployed into the vault's resource group.
// Grants the edge machine's system identity Role Based Access Control Administrator on the vault, constrained (ABAC
// condition, verbatim from the portal template) so it can only assign or remove Key Vault Secrets User.
// The provisioning service uses it to let the target Arc machine read the administrator secret during the OS install.
targetScope = 'resourceGroup'

@description('Key Vault NAME (in this resource group) that holds the provisioning administrator secret.')
param key_vault_name string
@description('Edge machine name; part of the role assignment name (portal formula).')
param edge_machine_name string
@description('Principal ID of the edge machine system-assigned identity.')
param principal_id string
@description('Per-deployment salt of the portal formula (newGuid in main.bicep).')
param guid_value string

var rbacAdministratorRoleId = 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: key_vault_name
}

resource delegation 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(vault.id, edge_machine_name, 'roleDefinitions/${rbacAdministratorRoleId}', guid_value, 'Key vault Secrets User role')
  properties: {
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', rbacAdministratorRoleId)
    principalId: principal_id
    principalType: 'ServicePrincipal'
    condition: '((!(ActionMatches{\'Microsoft.Authorization/roleAssignments/write\'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${keyVaultSecretsUserRoleId}})) AND ((!(ActionMatches{\'Microsoft.Authorization/roleAssignments/delete\'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${keyVaultSecretsUserRoleId}}))'
    conditionVersion: '2.0'
  }
}

output role_assignment_id string = delegation.id
