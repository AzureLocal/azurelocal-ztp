// Azure Local simplified machine provisioning (preview): site, site configuration and edge machines claimed from
// ownership vouchers.
// Every resource shape is the one the Azure portal deploys (Machine provisioning (preview) > Provision): a Microsoft.Edge
// site, a Microsoft.Edge/configurations resource with its network, time, connectivity and security settings, the site
// configurationReference, the Azure Local resource-provider role, one Microsoft.AzureStackHCI/edgeMachines per node, and
// the edge machine's constrained role delegations on the resource group and on the Key Vault. Arc gateway (not supported in
// the preview) and the AKS scenario of the portal template are left out.
// RULES: no literal tenant, subscription, address or name; the ownership vouchers arrive only as a secure run-time object
// (never in a file); the administrator password never enters the template - only the ARM ID of the Key Vault secret that
// holds it (the service rejects the https secret URI).
// Deployed at resource-group scope by scripts/simplified-provisioning/Invoke-ZtpAzureProvisioning.ps1. Parameter example:
// main.example.parameters.json.
targetScope = 'resourceGroup'

// ------------------------------------------------------------------ inputs (main.example.parameters.json)
@description('Provisioning region of the site configuration and the edge machines (preview: eastus only).')
param location string
@description('Tags for the site configuration and the edge machines (Microsoft.Edge sites take none).')
param tags object = {}
@description('Object ID of the Azure Local resource provider first-party app in your tenant (portal: hciRPServiceprincipalID).')
param azl_rp_app_object_id string
@description('Key Vault NAME that holds the provisioning administrator secret (portal: keyVaultArmId).')
param key_vault_name string
@description('Resource group of that Key Vault.')
param key_vault_resource_group string
@description('Name of the Microsoft.Edge site (a site groups the machines of one location).')
param site_name string
@description('Display name of the site; empty = site_name.')
param site_display_name string = ''
@description('Name of the Microsoft.Edge/configurations resource.')
param configuration_name string = 'default'
@description('Local administrator user name of the provisioned machines.')
param admin_username string
@description('Name of the Key Vault secret that holds that administrator password.')
// A Key Vault secret NAME, never a value: the linter keys on the word "secret".
#disable-next-line secure-secrets-in-params
param admin_secret_name string
@description('Time zone of the site settings, for example UTC.')
param time_zone string
@description('nodes[]: name (edge machine name = host name); service_tag is read by the script to map vouchers.')
param nodes array

@description('Apply the network, time, connectivity and security site settings.')
param apply_site_settings bool = true
@description('Reference the Key Vault in the security settings (needed for the administrator secret).')
param use_key_vault_configuration bool = true
@description('Create the edge machines\' constrained role delegations on the resource group and the Key Vault.')
param assign_provisioning_roles bool = true
@description('Assign the Azure Local resource provider its role on the resource group. Separate switch: a landing zone that already holds this assignment under another name would fail with RoleAssignmentExists.')
param assign_hci_rp_role bool = true
@description('Override of the managed resource group name; empty = service default.')
param managed_resource_group_name string = ''
@description('Network settings: LAN or WLAN kind.')
param network_kind string = 'LAN'
@description('Network settings: Automatic (DHCP) or Manual.')
param ip_assignment_type string = 'Automatic'
@description('Network settings for Manual assignment: addressRange { startIp, endIp }, defaultGateway, dnsServers, subnetMask, vLanId.')
param ipv4 object = {}
@description('Time settings: Automatic or Manual NTP.')
param ntp_configuration_choice string = 'Automatic'
@description('Time settings: primary NTP server (Manual).')
param ntp_server string = ''
@description('Time settings: alternate NTP server (Manual).')
param alternate_ntp_server string = ''
@description('Connectivity settings: Public or Proxy.')
param connectivity_type string = 'Public'

// ------------------------------------------------------------------ run-time inputs (the script; never in a file)
@secure()
@description('Node name -> ownership voucher: base64 of the voucher .pem file bytes (portal format; API: "Ownership voucher in base64 encoded format").')
param ownership_vouchers object = {}
@description('Validated solution recipe version (osImages?solution-type=HCI validatedSolutionRecipeVersion) resolved by Get-ZtpOsImage.ps1, for example 12.2609.1003.7.')
param os_version string
@description('Create the Microsoft.Edge site. false = reuse the existing site (the script decides from a GET).')
param create_site bool = true
@description('Create the Microsoft.Edge/configurations resource. false = reuse the existing one and its managed resource group.')
param create_configuration bool = true
@description('Node names to claim in this run; empty = every node. The script leaves out nodes whose edge machine already exists.')
param node_filter array = []
@description('false = site and site configuration only, no edge machine (what-if before the vouchers exist).')
param claim_machines bool = true
@description('Per-deployment salt of the portal role-assignment names (portal: guidValue = newGuid()).')
param guid_value string = newGuid()

// ------------------------------------------------------------------ derived values
var siteName = site_name
var configurationName = configuration_name
var vsrVersion = os_version
var applySiteSettings = apply_site_settings
var useKeyVaultConfiguration = use_key_vault_configuration
var assignProvisioningRoles = assign_provisioning_roles
var assignHciRpRole = assign_hci_rp_role
var managedResourceGroupName = managed_resource_group_name
var keyVaultResourceGroup = key_vault_resource_group
var keyVaultId = resourceId(subscription().subscriptionId, keyVaultResourceGroup, 'Microsoft.KeyVault/vaults', key_vault_name)
// Secret ARM ID (not the https URI): proven by the portal run and by the API refusing the URI.
var adminSecretId = resourceId(subscription().subscriptionId, keyVaultResourceGroup, 'Microsoft.KeyVault/vaults/secrets', key_vault_name, admin_secret_name)
var selectedNodes = claim_machines ? filter(nodes, n => empty(node_filter) || contains(node_filter, n.name)) : []
var emptyIpv4 = {
  addressRange: { startIp: '', endIp: '' }
  defaultGateway: ''
  dnsServers: []
  subnetMask: ''
  vLanId: 0
}

// Built-in role definitions used by the portal template.
var connectedMachineResourceManagerRoleId = 'f5819b54-e033-4d82-ac66-4fec3cbf3f4c' // Azure Connected Machine Resource Manager
var rbacAdministratorRoleId = 'f58310d9-a9f6-439a-9e8d-f62e7b41a168' // Role Based Access Control Administrator
var connectedMachineResourceAdministratorRoleId = 'cd570a14-e51a-42ad-bac8-bafd67325302' // Azure Connected Machine Resource Administrator

// ------------------------------------------------------------------ site and site configuration
resource siteNew 'Microsoft.Edge/sites@2025-03-01-preview' = if (create_site) {
  name: siteName
  properties: {
    displayName: empty(site_display_name) ? siteName : site_display_name
  }
}

resource site 'Microsoft.Edge/sites@2025-03-01-preview' existing = {
  name: siteName
}

#disable-next-line BCP081 // no published Bicep types for this preview API; shapes are the portal template's
resource configurationNew 'Microsoft.Edge/configurations@2025-12-01-preview' = if (create_configuration) {
  name: configurationName
  location: location
  tags: tags
  properties: {
    managedResourcesConfiguration: {
      enabled: true
      managedResourceGroupNameOverride: empty(managedResourceGroupName) ? null : managedResourceGroupName
      additionalIdentitiesMetadata: [
        {
          servicePrincipalObjectId: azl_rp_app_object_id
          name: 'AzureLocal'
        }
      ]
    }
  }
  dependsOn: [
    siteNew
  ]
}

#disable-next-line BCP081 // no published Bicep types for this preview API; shapes are the portal template's
resource configuration 'Microsoft.Edge/configurations@2025-12-01-preview' existing = {
  name: configurationName
}

#disable-next-line BCP081 // no published Bicep types for this preview API; shapes are the portal template's
resource networkSettings 'Microsoft.Edge/configurations/networkConfigurations@2025-12-01-preview' = if (applySiteSettings) {
  parent: configuration
  name: 'default'
  kind: network_kind
  properties: {
    ipAssignments: {
      ipAssignmentType: ip_assignment_type
      ipv4: union(emptyIpv4, ipv4)
    }
    scenario: 'Provisioning'
  }
  dependsOn: [
    configurationNew
  ]
}

#disable-next-line BCP081 // no published Bicep types for this preview API; shapes are the portal template's
resource timeSettings 'Microsoft.Edge/configurations/timeServerConfigurations@2025-12-01-preview' = if (applySiteSettings) {
  parent: configuration
  name: 'default'
  properties: {
    ntpConfigurationChoice: ntp_configuration_choice
    ntpServerConfiguration: {
      alternateNtpServer: alternate_ntp_server
      ntpServer: ntp_server
    }
    scenario: 'Provisioning'
    timezone: time_zone
  }
  dependsOn: [
    configurationNew
  ]
}

#disable-next-line BCP081 // no published Bicep types for this preview API; shapes are the portal template's
resource connectivitySettings 'Microsoft.Edge/configurations/connectivityConfigurations@2025-12-01-preview' = if (applySiteSettings) {
  parent: configuration
  name: 'default'
  properties: {
    connectivityType: connectivity_type
    scenario: 'Provisioning'
  }
  dependsOn: [
    configurationNew
  ]
}

#disable-next-line BCP081 // no published Bicep types for this preview API; shapes are the portal template's
resource securitySettings 'Microsoft.Edge/configurations/securityConfigurations@2025-12-01-preview' = if (applySiteSettings && useKeyVaultConfiguration) {
  parent: configuration
  name: 'default'
  properties: {
    scenario: 'Provisioning'
    secretReferences: [
      {
        keyvaultResourceId: keyVaultId
        purpose: 'LocalAdminCredentials'
        secretUri: ''
        vaultUri: 'https://${key_vault_name}${environment().suffixes.keyvaultDns}/'
      }
    ]
  }
  dependsOn: [
    configurationNew
  ]
}

#disable-next-line BCP081 // no published Bicep types for this preview API; shapes are the portal template's
resource configurationLink 'Microsoft.Edge/configurationReferences@2025-12-01-preview' = if (create_site || create_configuration) {
  scope: site
  name: 'default'
  properties: {
    configurationResourceId: configuration.id
  }
  dependsOn: [
    siteNew
    configurationNew
  ]
}

// ------------------------------------------------------------------ Azure Local resource provider on the resource group
// Same deterministic name as the portal, so a re-run (or the portal's own assignment) is an idempotent re-PUT.
resource hciRpRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignHciRpRole) {
  name: guid(azl_rp_app_object_id, 'Management', resourceGroup().name, subscription().id)
  properties: {
    principalId: azl_rp_app_object_id
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', connectedMachineResourceManagerRoleId)
    principalType: 'ServicePrincipal'
  }
}

// ------------------------------------------------------------------ edge machines (claim with the ownership voucher)
resource edgeMachines 'Microsoft.AzureStackHCI/edgeMachines@2025-12-01-preview' = [
  for node in selectedNodes: {
    name: node.name
    location: location
    tags: tags
    identity: {
      type: 'SystemAssigned'
    }
    properties: {
      arcMachineResourceGroupId: configuration.properties.managedResourcesConfiguration.managedResourceGroupId
      siteDetails: {
        siteResourceId: site.id
        deviceConfiguration: {
          hostName: node.name
        }
      }
      ownershipVoucherDetails: {
        ownerKeyType: 'MicrosoftManaged'
        #disable-next-line use-secure-value-for-secure-inputs // indexed from the @secure() object parameter
        ownershipVoucher: ownership_vouchers[node.name]
      }
      provisioningDetails: {
        osProfile: {
          osType: 'HCI'
          vsrVersion: vsrVersion
        }
        userDetails: [
          {
            secretLocation: adminSecretId
            secretType: 'KeyVault'
            userName: admin_username
          }
        ]
      }
    }
    dependsOn: [
      configurationNew
      configurationLink
      networkSettings
      timeSettings
      connectivitySettings
      securitySettings
      hciRpRole
    ]
  }
]

// The edge machine may assign only Azure Connected Machine Resource Administrator in this resource group (ABAC
// condition verbatim from the portal template). The service uses it for the target Arc machine ("SetupPermissions").
resource machineRoleDelegation 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (node, i) in selectedNodes: if (assignProvisioningRoles) {
    #disable-next-line use-stable-resource-identifiers // portal formula: a new name per run so an orphaned assignment of a deleted edge machine never collides
    name: guid(resourceGroup().id, node.name, 'roleDefinitions/${connectedMachineResourceAdministratorRoleId}', guid_value, 'Azure connected machine role')
    properties: {
      roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', rbacAdministratorRoleId)
      principalId: edgeMachines[i].identity.principalId
      principalType: 'ServicePrincipal'
      condition: '((!(ActionMatches{\'Microsoft.Authorization/roleAssignments/write\'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${connectedMachineResourceAdministratorRoleId}})) AND ((!(ActionMatches{\'Microsoft.Authorization/roleAssignments/delete\'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${connectedMachineResourceAdministratorRoleId}}))'
      conditionVersion: '2.0'
    }
  }
]

// Same delegation on the Key Vault, limited to Key Vault Secrets User (portal: nested "Key vault template").
module keyVaultDelegation 'modules/key-vault-delegation.bicep' = [
  for (node, i) in selectedNodes: if (assignProvisioningRoles) {
    name: guid(keyVaultId, node.name, 'Key vault template', guid_value)
    scope: resourceGroup(keyVaultResourceGroup)
    params: {
      key_vault_name: key_vault_name
      edge_machine_name: node.name
      principal_id: edgeMachines[i].identity.principalId
      guid_value: guid_value
    }
  }
]

// ------------------------------------------------------------------ outputs
output site_id string = site.id
output configuration_id string = configuration.id
output os_version string = vsrVersion
output edge_machine_names array = [for node in selectedNodes: node.name]
output edge_machine_ids array = [for (node, i) in selectedNodes: edgeMachines[i].id]
#disable-next-line outputs-should-not-contain-secrets
output admin_secret_resource_id string = adminSecretId

