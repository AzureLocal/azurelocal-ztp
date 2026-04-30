<#
.SYNOPSIS
    Generate environment.yaml and environment.json from cluster-config.md.

.DESCRIPTION
    Parses the cluster-config.md markdown file, extracts all variable/value
    pairs from markdown tables, and generates the environment.yaml and
    environment.json configuration files consumed by AzureLocalConfig.psm1.

    This script is the SECOND step in the config generation chain:
      Reference (.env) → cluster-config.md → environment.yaml / .json

    The generated files are NOT committed to the repo — they exist only
    on the runner for pipeline execution.

.PARAMETER ClusterConfigPath
    Path to the cluster-config.md file.
    Default: config/cluster/cluster-config.md (relative to repo root)

.PARAMETER OutputDirectory
    Directory for generated yaml and json files.
    Default: config/ (relative to repo root)

.PARAMETER Force
    Overwrite existing files without prompting.

.EXAMPLE
    .\Generate-ConfigFromMD.ps1

.EXAMPLE
    .\Generate-ConfigFromMD.ps1 -ClusterConfigPath ".\cluster-config.md" -Force

.NOTES
    File: Generate-ConfigFromMD.ps1
    Author: Azure Local ZTP Team
    Version: 1.0.0
    Created: 2026-02-11
    Requires: powershell-yaml module
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ClusterConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputDirectory,

    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Repository root detection
$scriptDir = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptDir)))

# Default paths
if (-not $ClusterConfigPath) {
    $ClusterConfigPath = Join-Path $repoRoot "config\cluster\cluster-config.md"
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repoRoot "config"
}

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Generate Config Files from Cluster Config MD              ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

Write-Host "`nSource: $ClusterConfigPath" -ForegroundColor White
Write-Host "Output: $OutputDirectory" -ForegroundColor White

# ─── Validate ────────────────────────────────────────────────────────────
if (-not (Test-Path $ClusterConfigPath)) {
    Write-Host "`n✗ Cluster config not found: $ClusterConfigPath" -ForegroundColor Red
    Write-Host "  Run Generate-ConfigFromReference.ps1 first." -ForegroundColor Yellow
    exit 1
}

# Check powershell-yaml
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host "Installing powershell-yaml module..." -ForegroundColor Yellow
    Install-Module -Name powershell-yaml -Scope CurrentUser -Force -ErrorAction Stop
}
Import-Module powershell-yaml -ErrorAction Stop

$yamlPath = Join-Path $OutputDirectory "environment.yaml"
$jsonPath = Join-Path $OutputDirectory "environment.json"

if ((Test-Path $yamlPath) -and -not $Force) {
    Write-Host "`n✗ $yamlPath already exists. Use -Force to overwrite." -ForegroundColor Red
    exit 1
}

# ─── Parse markdown tables ──────────────────────────────────────────────
Write-Host "`n[1/4] Parsing cluster-config.md..." -ForegroundColor Cyan

$mdContent = Get-Content $ClusterConfigPath -Raw
$lines = Get-Content $ClusterConfigPath

# Extract variable-value pairs from markdown tables with 3+ columns
# Format: | VARIABLE_NAME | value | description |
$variables = @{}

foreach ($line in $lines) {
    $line = $line.Trim()

    # Match table rows with at least Variable | Value pattern
    # Skip header rows (containing "Variable Name" or dashes)
    if ($line -match '^\|([^|]+)\|([^|]+)\|') {
        $col1 = $matches[1].Trim()
        $col2 = $matches[2].Trim()

        # Skip header/separator rows
        if ($col1 -match '^-+$' -or $col1 -match 'Variable' -or $col1 -match '\*\*' -or $col1 -eq 'Detail' -or $col1 -eq 'Setting' -or $col1 -match 'Network|Node|Requirement|Access|Port') {
            continue
        }

        # Only process rows where col1 looks like a variable name (UPPER_CASE or mixed)
        if ($col1 -match '^[A-Z][A-Z0-9_]+$') {
            # Strip markdown formatting from value
            $value = $col2 -replace '`', '' -replace '\*\*', ''
            $value = $value.Trim()

            # Skip placeholder values
            if ($value -notin @('[CHANGE-ME]', '[DISCOVERED]', '[SECURED]', '[AUTO-DETECTED]', '(not set)', '')) {
                $variables[$col1] = $value
            }
        }
    }
}

Write-Host "  ✓ Extracted $($variables.Count) variables from markdown tables" -ForegroundColor Green

# ─── Map variables to nested YAML structure ──────────────────────────────
Write-Host "`n[2/4] Building configuration structure..." -ForegroundColor Cyan

# Helper: safely get variable or return default
function GetVar {
    param([string]$Name, [string]$Default = '')
    if ($variables.ContainsKey($Name)) { return $variables[$Name] }
    return $Default
}

# Build the nested structure that matches what AzureLocalConfig.psm1 expects
$config = [ordered]@{
    # Azure Identity
    azure = [ordered]@{
        tenant_id              = GetVar 'AZURE_TENANT_ID'
        primary_domain         = GetVar 'AZURE_PRIMARY_DOMAIN'
        tenant_directory       = GetVar 'AZURE_TENANT_DIRECTORY'
        mgmt_subscription_id   = GetVar 'AZURE_MGMT_SUBSCRIPTION_ID'
        workload_subscription_id = GetVar 'AZURE_WORKLOAD_SUBSCRIPTION_ID'
        tenant_root_group_id   = GetVar 'TENANT_ROOT_GROUP_ID' (GetVar 'AZURE_TENANT_ID')
        management_group_id    = GetVar 'MANAGEMENT_GROUP_ID'
    }

    # Azure Resources
    resources = [ordered]@{
        cluster_resource_group  = GetVar 'RG_CLUSTER'
        arc_resource_group      = GetVar 'RG_ARC'
        infra_resource_group    = GetVar 'RG_INFRA'
        network_resource_group  = GetVar 'RG_NETWORKING' (GetVar 'RG_INFRA')
        cluster_name            = GetVar 'AZURE_CLUSTER_RESOURCE_NAME' (GetVar 'CLUSTER_NAME')
        custom_location_name    = GetVar 'AZURE_CUSTOM_LOCATION_NAME'
        cloud_witness_storage   = GetVar 'AZURE_CLOUD_WITNESS_STORAGE'
        diagnostic_storage      = GetVar 'AZURE_DIAGNOSTIC_STORAGE'
        arc_gateway_name        = GetVar 'AZURE_ARC_GATEWAY_NAME'
        arc_gateway_resource_group = GetVar 'AZURE_ARC_GATEWAY_RESOURCE_GROUP'
        arc_gateway_resource_id = GetVar 'AZURE_ARC_GATEWAY_RESOURCE_ID'
        hci_resource_provider_object_id = GetVar 'HCI_RESOURCE_PROVIDER_OBJECT_ID'
    }

    # Key Vault
    keyvault = [ordered]@{
        azure_local_name          = GetVar 'KEYVAULT_AZURE_LOCAL_NAME'
        azure_local_resource_group = GetVar 'KEYVAULT_AZURE_LOCAL_RESOURCE_GROUP'
        platform_name             = GetVar 'KEYVAULT_PLATFORM_NAME'
        platform_resource_group   = GetVar 'KEYVAULT_PLATFORM_RESOURCE_GROUP'
        subscription_id           = GetVar 'KEYVAULT_SUBSCRIPTION_ID'
        subscription_name         = GetVar 'KEYVAULT_SUBSCRIPTION_NAME'
    }

    # Active Directory
    active_directory = [ordered]@{
        domain_fqdn     = GetVar 'DOMAIN_FQDN'
        domain_netbios  = GetVar 'DOMAIN_NETBIOS'
        ou_path         = GetVar 'DOMAIN_OU_PATH'
        naming_prefix   = GetVar 'NAMING_PREFIX' 'hci'
        dc_01_ip        = GetVar 'AZURE_DC_01_IP'
        dc_01_role      = GetVar 'AZURE_DC_01_ROLE' 'Domain Controller'
        dc_02_ip        = GetVar 'AZURE_DC_02_IP'
        dc_02_role      = GetVar 'AZURE_DC_02_ROLE' 'Domain Controller'
        ad_group_azure_local_admins = GetVar 'AD_GROUP_AZURE_LOCAL_ADMINS' 'Azure Local Admins'
    }
}

# ─── Nodes section ────────────────────────────────────────────────────────
$nodes = [ordered]@{}
$nodeCount = [int](GetVar 'NODE_COUNT' '4')

for ($i = 1; $i -le $nodeCount; $i++) {
    $padNum = "{0:D2}" -f $i
    $nodeKey = "node_$padNum"

    $hostname = GetVar "NODE_${padNum}_HOSTNAME"
    if (-not $hostname) { continue }

    $nodeData = [ordered]@{
        hostname = $hostname
        fqdn     = GetVar "NODE_${padNum}_FQDN"
        ip       = GetVar "NODE_${padNum}_IP"
        idrac_ip = GetVar "NODE_${padNum}_IDRAC_IP"
    }

    $serviceTag = GetVar "NODE_${padNum}_SERVICE_TAG"
    if ($serviceTag) { $nodeData['service_tag'] = $serviceTag }

    $rackPos = GetVar "NODE_${padNum}_RACK_POSITION"
    if ($rackPos -and $rackPos -match '^\d+$') { $nodeData['rack_position'] = [int]$rackPos }

    # MAC addresses (from cluster-config.md node tables — may not be present if [DISCOVERED])
    # These are populated after hardware discovery

    $nodes[$nodeKey] = $nodeData
}

$config['nodes'] = $nodes

# ─── Networking ───────────────────────────────────────────────────────────
$networking = [ordered]@{
    networks = [ordered]@{}
    cluster_infrastructure = [ordered]@{
        ip_pool_start           = GetVar 'CLUSTER_IP_POOL_START'
        ip_pool_end             = GetVar 'CLUSTER_IP_POOL_END'
        infrastructure_gateway  = GetVar 'INFRASTRUCTURE_GATEWAY'
        infrastructure_subnet_mask = GetVar 'INFRASTRUCTURE_SUBNET_MASK' '255.255.255.0'
        dns_primary             = GetVar 'DNS_SERVER_1'
        dns_secondary           = GetVar 'DNS_SERVER_2'
    }
    intents = [ordered]@{
        management = [ordered]@{
            name          = 'Management'
            traffic_type  = 'Management'
            adapters      = @('Embedded Nic 1', 'Embedded Nic 2')
            jumbo_packet  = 9014
            network_direct = $false
        }
        compute = [ordered]@{
            name          = 'Compute'
            traffic_type  = 'Compute'
            adapters      = @('Slot 3 Port 1', 'Slot 6 Port 1')
            jumbo_packet  = 9014
            network_direct = $true
            network_direct_technology = 'RoCEv2'
        }
        storage = [ordered]@{
            name          = 'Storage'
            traffic_type  = 'Storage'
            adapters      = @('Slot 3 Port 2', 'Slot 6 Port 2')
            jumbo_packet  = 9014
            network_direct = $true
            network_direct_technology = 'RoCEv2'
        }
    }
}

$config['networking'] = $networking

# ─── Deployment ───────────────────────────────────────────────────────────
$config['deployment'] = [ordered]@{
    local_admin_username = GetVar 'LOCAL_ADMIN_USERNAME' 'administrator'
    lcm_deployment_account = GetVar 'LCM_DEPLOYMENT_ACCOUNT'
    provisioning_account = GetVar 'PROVISIONING_ACCOUNT'
    idrac_username       = GetVar 'IDRAC_USERNAME'
}

# ─── ZTP ──────────────────────────────────────────────────────────────────
$config['ztp'] = [ordered]@{
    share_location   = GetVar 'ZTP_SHARE_LOCATION'
    share_network_path = GetVar 'ZTP_SHARE_NETWORK_PATH'
    share_name       = GetVar 'ZTP_SHARE_NAME' 'ztp'
    maintenance_version = GetVar 'ZTP_MAINTENANCE_VERSION'
    download_url     = GetVar 'ZTP_DOWNLOAD_URL'
    download_directory = GetVar 'ZTP_DOWNLOAD_DIRECTORY'
    extracted_directory = GetVar 'ZTP_EXTRACTED_DIRECTORY'
    share_username   = GetVar 'ZTP_SHARE_USERNAME' 'svc_idrac_share'
    idrac_secret_name = GetVar 'IDRAC_SECRET_NAME'
}

# ─── Scripts ──────────────────────────────────────────────────────────────
$config['scripts'] = [ordered]@{
    working_directory = GetVar 'SCRIPTS_WORKING_DIRECTORY' $repoRoot
    logs_directory    = GetVar 'SCRIPTS_LOGS_DIRECTORY' '.\logs'
    output_directory  = GetVar 'SCRIPTS_OUTPUT_DIRECTORY' '.\output'
    temp_directory    = GetVar 'SCRIPTS_TEMP_DIRECTORY' '.\temp'
}

Write-Host "  ✓ Built config structure with $($config.Keys.Count) sections" -ForegroundColor Green

# ─── Remove empty values from config ─────────────────────────────────────
function Remove-EmptyValues {
    param([hashtable]$Hash)
    $keysToRemove = @()
    foreach ($key in $Hash.Keys) {
        $val = $Hash[$key]
        if ($val -is [hashtable] -or $val -is [System.Collections.Specialized.OrderedDictionary]) {
            Remove-EmptyValues -Hash $val
        }
        elseif ($val -is [string] -and [string]::IsNullOrWhiteSpace($val)) {
            $keysToRemove += $key
        }
    }
    foreach ($key in $keysToRemove) {
        $Hash.Remove($key)
    }
}

# Don't remove empty values — keep structure intact for AzureLocalConfig.psm1

# ─── Generate YAML ──────────────────────────────────────────────────────
Write-Host "`n[3/4] Generating environment.yaml..." -ForegroundColor Cyan

# Build YAML manually for better formatting with comments
$clusterName = GetVar 'CLUSTER_NAME' (GetVar 'AZURE_CLUSTER_RESOURCE_NAME')
$yamlHeader = @"
# $clusterName Azure Local Environment Configuration
# Generated from cluster-config.md on $(Get-Date -Format 'yyyy-MM-dd')
# This file is auto-generated — do NOT edit directly.
# Edit cluster-config.md and re-run Generate-ConfigFromMD.ps1 instead.


"@

$yamlBody = ConvertTo-Yaml -Data $config
$yamlContent = $yamlHeader + $yamlBody

# Ensure output directory exists
if (-not (Test-Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

Set-Content -Path $yamlPath -Value $yamlContent -Force -Encoding UTF8
Write-Host "  ✓ Generated: $yamlPath" -ForegroundColor Green

# ─── Generate JSON ───────────────────────────────────────────────────────
Write-Host "`n[4/4] Generating environment.json..." -ForegroundColor Cyan

$jsonContent = $config | ConvertTo-Json -Depth 10
Set-Content -Path $jsonPath -Value $jsonContent -Force -Encoding UTF8
Write-Host "  ✓ Generated: $jsonPath" -ForegroundColor Green

# ─── Summary ─────────────────────────────────────────────────────────────
Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Config Files Generated Successfully                       ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green

Write-Host "`n  YAML: $yamlPath" -ForegroundColor Cyan
Write-Host "  JSON: $jsonPath" -ForegroundColor Cyan
Write-Host ""
Write-Host "  These files are consumed by AzureLocalConfig.psm1" -ForegroundColor White
Write-Host "  They should NOT be committed to the repository." -ForegroundColor Yellow
Write-Host ""
