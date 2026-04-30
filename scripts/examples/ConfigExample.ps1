# Example: Using the Azure Local Configuration Module
# This script demonstrates how to load and use configuration values

# Import the configuration module
Import-Module "$PSScriptRoot\..\common\AzureLocalConfig.psm1"

# Load configuration
$config = Get-AzureLocalConfig

# Example: Get Azure subscription IDs
$mgmtSubId = $config.GetValue('azure.mgmt_subscription_id')
$workloadSubId = $config.GetValue('azure.workload_subscription_id')

Write-Host "Management Subscription: $mgmtSubId"
Write-Host "Workload Subscription: $workloadSubId"

# Example: Get all node hostnames
$hostnames = $config.GetNodeHostnames()
Write-Host "Node Hostnames: $($hostnames -join ', ')"

# Example: Get node details by hostname
$node = $config.GetNodeByHostname('{node_hostname_1}')
Write-Host "Node $($node.hostname) - IP: $($node.ip), iDRAC: $($node.idrac_ip)"

# Example: Get deployment credentials
$idracUser = $config.GetValue('deployment.idrac_username')
Write-Host "iDRAC Username: $idracUser"

# Example: Get network configuration
$mgmtNetwork = $config.GetValue('networking.networks.management')
Write-Host "Management Network: $($mgmtNetwork.cidr) (VLAN: $($mgmtNetwork.vlan))"

# Example: Using the convenience function
$clusterName = Get-ConfigValue 'resources.cluster_name'
$localAdmin = Get-ConfigValue 'deployment.local_admin_username'

Write-Host "Cluster Name: $clusterName"
Write-Host "Local Admin: $localAdmin"

# Example: Get all iDRAC IPs for server management
$idracIPs = $config.GetIdracIPs()
Write-Host "iDRAC IPs: $($idracIPs -join ', ')"

# Example: Get ZTP configuration
$sharePath = $config.GetValue('ztp.share_location')
$isoFile = $config.GetValue('ztp.iso_filename')
Write-Host "ZTP Share: $sharePath"
Write-Host "ISO File: $isoFile"