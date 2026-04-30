<#
.SYNOPSIS
    Generate a complete cluster-config.md from a cluster-reference.env file.

.DESCRIPTION
    Reads the minimal cluster-reference.env file (~25 values provided by the
    deployment engineer) and generates a comprehensive cluster-config.md with
    all 250+ variables. Values are derived using naming conventions, networking
    formulas, and sensible defaults for Azure Local deployments.

    This script is the FIRST step in the config generation chain:
      Reference (.env) → cluster-config.md → environment.yaml / .json

    Variables that require hardware discovery (MAC addresses, service tags,
    HBA WWNs) are populated with [DISCOVERED] placeholders until the
    hardware discovery step is run.

.PARAMETER ReferencePath
    Path to the cluster-reference.env file.
    Default: config/cluster-reference.env (relative to repo root)

.PARAMETER OutputPath
    Path for the generated cluster-config.md.
    Default: config/cluster/cluster-config.md

.PARAMETER Force
    Overwrite existing cluster-config.md without prompting.

.EXAMPLE
    .\Generate-ConfigFromReference.ps1

.EXAMPLE
    .\Generate-ConfigFromReference.ps1 -ReferencePath ".\my-cluster.env" -Force

.NOTES
    File: Generate-ConfigFromReference.ps1
    Author: Azure Local ZTP Team
    Version: 1.0.0
    Created: 2026-02-11
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ReferencePath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Repository root detection
$scriptDir = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptDir)))
# scripts/common/utilities/tools → scripts/common/utilities → scripts/common → scripts → repo root

# Default paths
if (-not $ReferencePath) {
    $ReferencePath = Join-Path $repoRoot "config\cluster-reference.env"
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $repoRoot "config\cluster\cluster-config.md"
}

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Generate Cluster Config from Reference                    ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

Write-Host "`nReference: $ReferencePath" -ForegroundColor White
Write-Host "Output:    $OutputPath" -ForegroundColor White

# ─── Validate reference file ─────────────────────────────────────────────
if (-not (Test-Path $ReferencePath)) {
    Write-Host "`n✗ Reference file not found: $ReferencePath" -ForegroundColor Red
    Write-Host "  Copy config/cluster-reference.env.template to config/cluster-reference.env" -ForegroundColor Yellow
    Write-Host "  and fill in your values." -ForegroundColor Yellow
    exit 1
}

# Check output exists
if ((Test-Path $OutputPath) -and -not $Force) {
    Write-Host "`n✗ Output file exists: $OutputPath" -ForegroundColor Red
    Write-Host "  Use -Force to overwrite." -ForegroundColor Yellow
    exit 1
}

# ─── Parse reference .env file ───────────────────────────────────────────
Write-Host "`n[1/4] Reading reference file..." -ForegroundColor Cyan

$ref = @{}
$lines = Get-Content $ReferencePath
foreach ($line in $lines) {
    $line = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
    if ($line -match '^([A-Z_0-9]+)=(.*)$') {
        $key = $matches[1]
        $value = $matches[2].Trim()
        if ($value) {
            $ref[$key] = $value
        }
    }
}

Write-Host "  ✓ Loaded $($ref.Count) values from reference" -ForegroundColor Green

# ─── Validate required fields ────────────────────────────────────────────
Write-Host "`n[2/4] Validating required fields..." -ForegroundColor Cyan

$requiredFields = @(
    'AZURE_TENANT_ID',
    'AZURE_SUBSCRIPTION_ID',
    'CLUSTER_NAME',
    'DOMAIN_FQDN',
    'DC_01_IP',
    'DC_02_IP',
    'IDRAC_IPS',
    'NODE_HOSTNAMES',
    'NODE_MGMT_IPS',
    'KEYVAULT_PLATFORM_NAME',
    'SHARE_SERVER_IP',
    'OOB_CIDR',
    'OOB_GATEWAY',
    'OOB_VLAN',
    'MGMT_CIDR',
    'MGMT_GATEWAY',
    'MGMT_VLAN'
)

$missing = @()
foreach ($field in $requiredFields) {
    if (-not $ref.ContainsKey($field)) {
        $missing += $field
    }
}

if ($missing.Count -gt 0) {
    Write-Host "  ✗ Missing required fields:" -ForegroundColor Red
    foreach ($f in $missing) {
        Write-Host "    - $f" -ForegroundColor Red
    }
    exit 1
}

Write-Host "  ✓ All $($requiredFields.Count) required fields present" -ForegroundColor Green

# ─── Derive all values ───────────────────────────────────────────────────
Write-Host "`n[3/4] Deriving configuration values..." -ForegroundColor Cyan

# Parse comma-separated lists
$idracIPs      = $ref['IDRAC_IPS'] -split ','
$nodeHostnames = $ref['NODE_HOSTNAMES'] -split ','
$nodeMgmtIPs   = $ref['NODE_MGMT_IPS'] -split ','
$nodeCount     = [int]($ref['NODE_COUNT'] ?? '4')

if ($idracIPs.Count -ne $nodeCount -or $nodeHostnames.Count -ne $nodeCount -or $nodeMgmtIPs.Count -ne $nodeCount) {
    Write-Host "  ✗ Mismatch: NODE_COUNT=$nodeCount but got $($idracIPs.Count) iDRAC IPs, $($nodeHostnames.Count) hostnames, $($nodeMgmtIPs.Count) mgmt IPs" -ForegroundColor Red
    exit 1
}

# Basic derived values
$clusterName    = $ref['CLUSTER_NAME']
$domainFQDN     = $ref['DOMAIN_FQDN']
$domainNetBIOS  = $ref['DOMAIN_NETBIOS'] ?? ($domainFQDN -split '\.' | Select-Object -Last 2 | Select-Object -First 1)
$azureRegion    = $ref['AZURE_REGION'] ?? 'eastus'
$regionShort    = switch ($azureRegion) {
    'eastus'       { 'eus' }
    'eastus2'      { 'eus2' }
    'westus'       { 'wus' }
    'westus2'      { 'wus2' }
    'westus3'      { 'wus3' }
    'centralus'    { 'cus' }
    'westeurope'   { 'weu' }
    'northeurope'  { 'neu' }
    default        { $azureRegion.Substring(0, [Math]::Min(4, $azureRegion.Length)) }
}

# Resource group (user-provided or auto)
$clusterRG = if ($ref['CLUSTER_RESOURCE_GROUP']) { $ref['CLUSTER_RESOURCE_GROUP'] } else { "rg-$clusterName-$regionShort-01" }
$kvRG      = if ($ref['KEYVAULT_RESOURCE_GROUP']) { $ref['KEYVAULT_RESOURCE_GROUP'] } else { $clusterRG }

# Networking
$oobCIDR       = $ref['OOB_CIDR']
$oobGateway    = $ref['OOB_GATEWAY']
$oobVLAN       = $ref['OOB_VLAN']
$mgmtCIDR      = $ref['MGMT_CIDR']
$mgmtGateway   = $ref['MGMT_GATEWAY']
$mgmtVLAN      = $ref['MGMT_VLAN']
$computeCIDR   = $ref['COMPUTE_CIDR'] ?? ''
$computeGW     = $ref['COMPUTE_GATEWAY'] ?? ''
$computeVLAN   = $ref['COMPUTE_VLAN'] ?? ''

# Share config
$shareServerIP = $ref['SHARE_SERVER_IP']
$sharePath     = $ref['SHARE_PATH'] ?? 'C:\share\ztp'
$shareName     = $ref['SHARE_NAME'] ?? 'ztp'
$shareNetwork  = "\\$shareServerIP\$shareName"

# ZTP config
$maintVersion  = $ref['MAINTENANCE_VERSION'] ?? '2512'
$downloadDir   = $ref['DOWNLOAD_DIRECTORY'] ?? 'C:\AzureLocal\ZTP'
$extractedDir  = $ref['EXTRACTED_DIRECTORY'] ?? 'C:\AzureLocal\ZTP\extracted'

# Credentials
$idracUsername = $ref['IDRAC_USERNAME'] ?? 'idrac_azl_admin'
$idracSecret   = $ref['IDRAC_SECRET_NAME'] ?? 'idrac-credentials'
$localAdmin    = $ref['LOCAL_ADMIN_USERNAME'] ?? 'administrator'
$lcmAccount    = if ($ref['LCM_DEPLOYMENT_ACCOUNT']) { $ref['LCM_DEPLOYMENT_ACCOUNT'] } else { "lcm-$clusterName" }
$provAccount   = $ref['PROVISIONING_ACCOUNT'] ?? 'azl-admin'
$shareUsername = $ref['SHARE_USERNAME'] ?? 'svc_idrac_share'

# Key Vault
$kvPlatform    = $ref['KEYVAULT_PLATFORM_NAME']
$kvAzureLocal  = "$clusterName-kv"

# Domain
$domainParts   = $domainFQDN -split '\.'
$ouPath        = "OU=$clusterName,OU=AzureLocal,OU=Clusters,OU=Servers,OU=$($domainParts[-1].ToUpper()),DC=$($domainParts -join ',DC=')"

# Azure identity
$tenantID      = $ref['AZURE_TENANT_ID']
$primaryDomain = $ref['AZURE_PRIMARY_DOMAIN'] ?? ''
$tenantDir     = $ref['AZURE_TENANT_DIRECTORY'] ?? ''
$subscriptionID = $ref['AZURE_SUBSCRIPTION_ID']
$workloadSubID = $ref['AZURE_WORKLOAD_SUBSCRIPTION_ID'] ?? $subscriptionID

# Infrastructure IP pool (derive from management CIDR — use .20-.25 range)
$mgmtNetwork   = ($mgmtCIDR -split '/')[0]
$mgmtOctets    = $mgmtNetwork -split '\.'
$ipPoolStart   = "$($mgmtOctets[0]).$($mgmtOctets[1]).$($mgmtOctets[2]).20"
$ipPoolEnd     = "$($mgmtOctets[0]).$($mgmtOctets[1]).$($mgmtOctets[2]).25"
$mgmtSubnetMask = "255.255.255.0"  # Default /24

Write-Host "  ✓ Derived values for $clusterName ($nodeCount nodes)" -ForegroundColor Green

# ─── Generate cluster-config.md ──────────────────────────────────────────
Write-Host "`n[4/4] Generating cluster-config.md..." -ForegroundColor Cyan

# Build node tables
$nodeTableRows = ""
$nodeDetailRows = ""
$nodeMgmtTableRows = ""
$macTableBlocks = ""

for ($i = 0; $i -lt $nodeCount; $i++) {
    $num = $i + 1
    $padNum = "{0:D2}" -f $num
    $hostname = $nodeHostnames[$i].Trim()
    $fqdn = "$hostname.$domainFQDN"
    $mgmtIP = $nodeMgmtIPs[$i].Trim()
    $idracIP = $idracIPs[$i].Trim()

    $nodeTableRows += @"

| NODE_${padNum}_HOSTNAME | $hostname | Node $num hostname |
| NODE_${padNum}_FQDN | $fqdn | Node $num FQDN |
| NODE_${padNum}_IP | $mgmtIP | Node $num management IP |
| NODE_${padNum}_IDRAC_IP | $idracIP | Node $num iDRAC IP |
| NODE_${padNum}_SERVICE_TAG | [DISCOVERED] | Node $num Dell service tag |
| NODE_${padNum}_RACK_POSITION | [CHANGE-ME] | Node $num rack position |
"@

    $nodeMgmtTableRows += "| $hostname | $mgmtIP |`n"

    $macTableBlocks += @"

#### Node $num ($hostname)

| Port | MAC Address |
|------|-------------|
| Slot 3 Port 1 | [DISCOVERED] |
| Slot 3 Port 2 | [DISCOVERED] |
| Slot 6 Port 1 | [DISCOVERED] |
| Slot 6 Port 2 | [DISCOVERED] |
| Embedded NIC 1 | [DISCOVERED] |
| Embedded NIC 2 | [DISCOVERED] |

"@
}

# Build Arc resource ID rows
$arcTableRows = ""
for ($i = 0; $i -lt $nodeCount; $i++) {
    $hostname = $nodeHostnames[$i].Trim()
    $arcTableRows += "| $hostname | /subscriptions/$subscriptionID/resourceGroups/$clusterRG/providers/Microsoft.HybridCompute/machines/$hostname |`n"
}

# Compute network section
$computeSection = ""
if ($computeCIDR) {
    $computeSection = "| Compute | $computeCIDR | $computeGW | $computeVLAN | Compute Network |"
}

$mdContent = @"
# $clusterName - Azure Local Cluster Configuration

[![Azure Local Configuration](https://img.shields.io/badge/Azure%20Local-Converged-blue?logo=microsoft-azure)](https://azure.microsoft.com/en-us/products/azure-stack/)

## Overview

This document provides a comprehensive configuration for deploying the **$clusterName** Azure Local cluster. It was generated from the cluster reference file and contains all variables organized by functional category.

| Detail | Value |
|--------|-------|
| **Cluster Name** | ``$clusterName`` |
| **Configuration Type** | Converged Intent with External Storage |
| **Node Count** | ${nodeCount}x Dell AX-760 |
| **Azure Region** | $($azureRegion -replace 'eastus','East US' -replace 'westus2','West US 2' -replace 'westeurope','West Europe') |
| **Last Updated** | $(Get-Date -Format 'MMMM d, yyyy') |
| **Generated From** | cluster-reference.env |

---

## Table of Contents

1. [Azure Identity](#1-azure-identity)
2. [Azure Resources](#2-azure-resources)
3. [Active Directory & Domain](#3-active-directory--domain)
4. [Infrastructure](#4-infrastructure)
5. [Nodes](#5-nodes)
6. [Networking](#6-networking)
7. [Storage (Fiber Channel / Pure)](#7-storage-fiber-channel--pure)
8. [Deployment Configuration](#8-deployment-configuration)
9. [Authentication & Credentials](#9-authentication--credentials)
10. [ZTP Configuration](#10-ztp-configuration)
11. [Scripts Configuration](#11-scripts-configuration)
12. [GitHub Actions Runner](#12-github-actions-runner)

---

## 1. Azure Identity

### Azure Tenant

| Variable Name | Value | Description |
|---------------|-------|-------------|
| AZURE_TENANT_ID | $tenantID | Azure tenant ID |
| AZURE_PRIMARY_DOMAIN | $primaryDomain | Azure primary domain |
| AZURE_TENANT_DIRECTORY | $tenantDir | Azure tenant directory |

### Azure Subscriptions

| Variable Name | Value | Description |
|---------------|-------|-------------|
| AZURE_MGMT_SUBSCRIPTION_ID | $subscriptionID | Management subscription ID |
| AZURE_WORKLOAD_SUBSCRIPTION_ID | $workloadSubID | Workload subscription ID |

---

## 2. Azure Resources

### Resource Groups

| Variable Name | Value | Description |
|---------------|-------|-------------|
| RG_CLUSTER | $clusterRG | Azure Local cluster resource group |
| RG_ARC | [CHANGE-ME] | Arc resources resource group |
| RG_INFRA | [CHANGE-ME] | Management infrastructure resource group |

### Core Azure Resources

| Variable Name | Value | Description |
|---------------|-------|-------------|
| AZURE_CLUSTER_RESOURCE_NAME | $clusterName | Azure Local cluster resource name |
| AZURE_CUSTOM_LOCATION_NAME | $clusterName-CL | Azure Local custom location name |
| AZURE_CLOUD_WITNESS_STORAGE | [CHANGE-ME] | Cloud witness storage account |
| AZURE_DIAGNOSTIC_STORAGE | [CHANGE-ME] | Diagnostic storage account |

### Key Vault

| Variable Name | Value | Description |
|---------------|-------|-------------|
| KEYVAULT_AZURE_LOCAL_NAME | $kvAzureLocal | Azure Local Key Vault name (created by deployment) |
| KEYVAULT_AZURE_LOCAL_RESOURCE_GROUP | $clusterRG | Azure Local Key Vault resource group |
| KEYVAULT_PLATFORM_NAME | $kvPlatform | Platform Key Vault name |
| KEYVAULT_PLATFORM_RESOURCE_GROUP | $kvRG | Platform Key Vault resource group |
| KEYVAULT_SUBSCRIPTION_ID | $subscriptionID | Key Vault subscription ID |

---

## 3. Active Directory & Domain

### Domain Configuration

| Variable Name | Value | Description |
|---------------|-------|-------------|
| DOMAIN_FQDN | $domainFQDN | Active Directory FQDN |
| DOMAIN_NETBIOS | $domainNetBIOS | Active Directory NetBIOS name |
| DOMAIN_OU_PATH | $ouPath | Organizational Unit path |
| NAMING_PREFIX | hci | Naming prefix |

### Active Directory Groups

| Variable Name | Value | Description |
|---------------|-------|-------------|
| AD_GROUP_AZURE_LOCAL_ADMINS | Azure Local Admins | Azure Local administrators group |

---

## 4. Infrastructure

### Cluster Details

| Variable Name | Value | Description |
|---------------|-------|-------------|
| CLUSTER_NAME | $clusterName | Azure Local cluster name |
| CLUSTER_ENVIRONMENT | [CHANGE-ME] | Environment designation |
| CLUSTER_LOCATION | [CHANGE-ME] | Location code |
| CLUSTER_RACK | [CHANGE-ME] | Physical rack location |
| NODE_COUNT | $nodeCount | Number of cluster nodes |

### Azure VMs

Virtual machines deployed in Azure for domain controllers, management, and runner services.

| Variable Name | Value | Description |
|---------------|-------|-------------|
| AZURE_DC_01_IP | $($ref['DC_01_IP']) | Domain Controller 1 IP address |
| AZURE_DC_01_ROLE | Domain Controller | Domain Controller 1 role |
| AZURE_DC_02_IP | $($ref['DC_02_IP']) | Domain Controller 2 IP address |
| AZURE_DC_02_ROLE | Domain Controller | Domain Controller 2 role |
| AZURE_RUNNER_IP | $shareServerIP | GitHub Actions runner / share server IP |
| AZURE_RUNNER_ROLE | GitHub Actions Runner + Share Server | Runner VM role |

---

## 5. Nodes

### Physical Nodes (Dell AX-760)

| Variable Name | Value | Description |
|---------------|-------|-------------|
$nodeTableRows

### Azure Arc Node Resource IDs

| Node | Resource ID |
|------|-------------|
$arcTableRows

### Physical Node Deployment Settings

| Node | Management IP |
|------|---------------|
$nodeMgmtTableRows

---

## 6. Networking

### 6.1 Network Definitions

| Network | CIDR | Gateway | VLAN | Purpose |
|---------|------|---------|------|---------|
| OOB | $oobCIDR | $oobGateway | $oobVLAN | Out Of Band Network |
| Management | $mgmtCIDR | $mgmtGateway | $mgmtVLAN | Management Network |
| SMB-A | [CHANGE-ME] | — | [CHANGE-ME] | Storage SMB Network A |
| SMB-B | [CHANGE-ME] | — | [CHANGE-ME] | Storage SMB Network B |
$computeSection

### 6.2 Cluster Infrastructure IPs

| Variable Name | Value | Description |
|---------------|-------|-------------|
| CLUSTER_IP_POOL_START | $ipPoolStart | Infrastructure IP pool start |
| CLUSTER_IP_POOL_END | $ipPoolEnd | Infrastructure IP pool end |
| INFRASTRUCTURE_GATEWAY | $mgmtGateway | Infrastructure network gateway |
| INFRASTRUCTURE_SUBNET_MASK | $mgmtSubnetMask | Infrastructure subnet mask |
| DNS_SERVER_1 | $($ref['DC_01_IP']) | Primary DNS server |
| DNS_SERVER_2 | $($ref['DC_02_IP']) | Secondary DNS server |

### 6.3 Network Intents

#### Intent 1: Management

| Setting | Value |
|---------|-------|
| Name | Management |
| Traffic Type | Management |
| Adapters | Embedded Nic 1, Embedded Nic 2 |
| Jumbo Packet | 9014 |
| Network Direct | Disabled |

#### Intent 2: Compute

| Setting | Value |
|---------|-------|
| Name | Compute |
| Traffic Type | Compute |
| Adapters | Slot 3 Port 1, Slot 6 Port 1 |
| Jumbo Packet | 9014 |
| Network Direct | Enabled |
| Network Direct Technology | RoCEv2 |

#### Intent 3: Storage

| Setting | Value |
|---------|-------|
| Name | Storage |
| Traffic Type | Storage |
| Adapters | Slot 3 Port 2, Slot 6 Port 2 |
| Jumbo Packet | 9014 |
| Network Direct | Enabled |
| Network Direct Technology | RoCEv2 |

### 6.4 Network Hardware

| Variable Name | Value | Description |
|---------------|-------|-------------|
| NETWORK_ADAPTER_TYPE | [CHANGE-ME] | Network adapter models per node |
| PRIMARY_SWITCH_HOSTNAME | [CHANGE-ME] | Primary ToR switch hostname |
| PRIMARY_SWITCH_IP | [CHANGE-ME] | Primary ToR switch management IP |
| SECONDARY_SWITCH_HOSTNAME | [CHANGE-ME] | Secondary ToR switch hostname |
| SECONDARY_SWITCH_IP | [CHANGE-ME] | Secondary ToR switch management IP |
| FIREWALL_MODEL | [CHANGE-ME] | Firewall model |

### 6.5 Physical Port MAC Addresses

$macTableBlocks

---

## 7. Storage (Fiber Channel / Pure)

### Fiber Channel Configuration

| Variable Name | Value | Description |
|---------------|-------|-------------|
| FC_HBA_MODEL | [CHANGE-ME] | Fiber channel HBA model |
| FC_SPEED | [CHANGE-ME] | Fiber channel speed |
| FC_MULTIPATHING | MPIO | Multipathing configuration |
| FC_ZONING_TYPE | Single Initiator | Zoning configuration type |

### Node HBA WWNs

| Node | HBA 1 WWN | HBA 2 WWN |
|------|-----------|-----------|
$(for ($i = 0; $i -lt $nodeCount; $i++) { "| $($nodeHostnames[$i].Trim()) | [DISCOVERED] | [DISCOVERED] |`n" })

---

## 8. Deployment Configuration

### 8.1 General Settings

| Variable Name | Value | Description |
|---------------|-------|-------------|
| DEPLOYMENT_MODE | Validate | Deployment mode |
| CONFIGURATION_MODE | InfraOnly | Configuration mode |
| AZURE_CLOUD_TYPE | Public | Azure cloud type |
| AZURE_REGION | $azureRegion | Target Azure region |
| CREATE_NEW_KEY_VAULT | true | Whether to create a new Key Vault |
| SOFT_DELETE_RETENTION_DAYS | 30 | Soft delete retention days |
| WITNESS_TYPE | Cloud | Witness type |

### 8.2 Security Settings

| Variable Name | Value | Description |
|---------------|-------|-------------|
| SECURITY_LEVEL | Customized | Security level |
| DRIFT_CONTROL_ENFORCED | true | Drift control enforced |
| CREDENTIAL_GUARD_ENFORCED | true | Credential guard enforced |
| SMB_SIGNING_ENFORCED | true | SMB signing enforced |
| SMB_CLUSTER_ENCRYPTION | true | SMB cluster encryption |
| BITLOCKER_BOOT_VOLUME | true | BitLocker boot volume |
| BITLOCKER_DATA_VOLUMES | true | BitLocker data volumes |
| WDAC_ENFORCED | false | WDAC enforced |

### 8.3 Networking Deployment Settings

| Variable Name | Value | Description |
|---------------|-------|-------------|
| NETWORKING_TYPE | switchedMultiServerDeployment | Networking type |
| NETWORKING_PATTERN | custom | Networking pattern |
| USE_DHCP | false | Use DHCP for management IPs |
| STORAGE_CONNECTIVITY_SWITCHLESS | false | Storage connectivity switchless |

---

## 9. Authentication & Credentials

### 9.1 Local Admin

| Variable Name | Value | Description |
|---------------|-------|-------------|
| LOCAL_ADMIN_USERNAME | $localAdmin | Local administrator username |
| LOCAL_ADMIN_PASSWORD | [SECURED] | Local administrator password |

### 9.2 Service Accounts

| Variable Name | Value | Description |
|---------------|-------|-------------|
| LCM_DEPLOYMENT_ACCOUNT | $lcmAccount | LCM deployment account |
| LCM_DEPLOYMENT_ACCOUNT_PASSWORD | [SECURED] | LCM deployment account password |
| PROVISIONING_ACCOUNT | $provAccount | Provisioning account |
| PROVISIONING_ACCOUNT_PASSWORD | [SECURED] | Provisioning account password |

### 9.3 Service Principal

| Variable Name | Value | Description |
|---------------|-------|-------------|
| SERVICE_PRINCIPAL_APP_ID | [CHANGE-ME] | Service principal application ID |
| SERVICE_PRINCIPAL_PURPOSE | Azure Local Deployment SPN | Service principal purpose |
| SERVICE_PRINCIPAL_SECRET | [SECURED] | Service principal secret |

### 9.4 Infrastructure Credentials

| Variable Name | Value | Description |
|---------------|-------|-------------|
| IDRAC_USERNAME | $idracUsername | iDRAC management username for all nodes |
| IDRAC_PASSWORD | [SECURED] | iDRAC management password (retrieve from Key Vault) |

---

## 10. ZTP Configuration

### 10.1 File Share

| Variable Name | Value | Description |
|---------------|-------|-------------|
| ZTP_SHARE_LOCATION | $sharePath | Local share path on runner/share server |
| ZTP_SHARE_NETWORK_PATH | $shareNetwork | UNC network path to ZTP share |
| ZTP_SHARE_NAME | $shareName | Share name |
| ZTP_SHARE_USERNAME | $shareUsername | Service account for iDRAC share access |
| ZTP_SHARE_PASSWORD | [SECURED] | Share access password |

### 10.2 ZTP Media

| Variable Name | Value | Description |
|---------------|-------|-------------|
| ZTP_MAINTENANCE_VERSION | $maintVersion | Azure Local maintenance version |
| ZTP_DOWNLOAD_URL | https://aka.ms/aep/installeros/$maintVersion | Azure Local OS download URL |
| ZTP_DOWNLOAD_DIRECTORY | $downloadDir | Local download directory |
| ZTP_EXTRACTED_DIRECTORY | $extractedDir | Extracted tools directory |

### 10.3 ZTP Credentials

| Variable Name | Value | Description |
|---------------|-------|-------------|
| IDRAC_SECRET_NAME | $idracSecret | Key Vault secret name for iDRAC credentials |

---

## 11. Scripts Configuration

| Variable Name | Value | Description |
|---------------|-------|-------------|
| SCRIPTS_WORKING_DIRECTORY | [AUTO-DETECTED] | Scripts working directory (repo root on runner) |
| SCRIPTS_LOGS_DIRECTORY | .\logs | Logs output directory |
| SCRIPTS_OUTPUT_DIRECTORY | .\output | Script output directory |
| SCRIPTS_TEMP_DIRECTORY | .\temp | Temporary files directory |

---

## 12. GitHub Actions Runner

### Runner Configuration

| Variable Name | Value | Description |
|---------------|-------|-------------|
| RUNNER_IP | $shareServerIP | Runner/share server IP address |
| RUNNER_OS | Windows Server 2025 | Runner operating system |
| RUNNER_LABELS | self-hosted, Windows, ztp-runner | GitHub Actions runner labels |
| RUNNER_IS_SHARE_SERVER | true | Runner doubles as the ZTP file share server |

### Runner Prerequisites

| Requirement | Description |
|-------------|-------------|
| PowerShell 7.0+ | Core scripting runtime |
| Git for Windows | Repository access |
| Azure CLI | Azure authentication |
| Az.Accounts module | Azure PowerShell identity |
| Az.KeyVault module | Key Vault secret retrieval |
| powershell-yaml module | YAML config parsing |

### Network Requirements

| Access | Target | Purpose |
|--------|--------|---------|
| HTTPS | github.com | Runner registration and job polling |
| HTTPS | Azure (login.microsoftonline.com, vault.azure.net) | Azure auth + Key Vault |
| HTTPS | aka.ms / download.microsoft.com | ZTP ISO download |
| Redfish (443) | iDRAC IPs ($($idracIPs -join ', ')) | Server management |
| SMB (445) | Local ($shareServerIP) | Share hosting |

---

---
**Version Control**
- Created: $(Get-Date -Format 'yyyy-MM-dd') by Generate-ConfigFromReference.ps1
- Last Edited: $(Get-Date -Format 'yyyy-MM-dd') by Generate-ConfigFromReference.ps1
- Version: 1.0.0
- Generated From: cluster-reference.env
- Tags: azure-local, configuration, generated, ztp
- Keywords: cluster, deployment, parameters, networking, storage, security, ztp

"@

# Ensure output directory exists
$outputDir = Split-Path -Parent $OutputPath
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

# Write output
Set-Content -Path $OutputPath -Value $mdContent -Force -Encoding UTF8

Write-Host "  ✓ Generated: $OutputPath" -ForegroundColor Green

# Summary
$changeMeCount = ([regex]::Matches($mdContent, '\[CHANGE-ME\]')).Count
$discoveredCount = ([regex]::Matches($mdContent, '\[DISCOVERED\]')).Count
$securedCount = ([regex]::Matches($mdContent, '\[SECURED\]')).Count

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Cluster Config Generated Successfully                     ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green

Write-Host "`n  Cluster:           $clusterName" -ForegroundColor White
Write-Host "  Nodes:             $nodeCount" -ForegroundColor White
Write-Host "  Region:            $azureRegion" -ForegroundColor White
Write-Host "  Output:            $OutputPath" -ForegroundColor White
Write-Host ""
Write-Host "  Values populated:  $(($mdContent | Select-String -Pattern '\|.*\|.*\|' -AllMatches).Matches.Count) table rows" -ForegroundColor White
Write-Host "  [CHANGE-ME]:       $changeMeCount fields need manual review" -ForegroundColor Yellow
Write-Host "  [DISCOVERED]:      $discoveredCount fields populated by hardware discovery" -ForegroundColor Yellow
Write-Host "  [SECURED]:         $securedCount fields stored in Key Vault" -ForegroundColor Cyan
Write-Host ""

if ($changeMeCount -gt 0) {
    Write-Host "  Next steps:" -ForegroundColor White
    Write-Host "    1. Review cluster-config.md and fill [CHANGE-ME] values" -ForegroundColor White
    Write-Host "    2. Run hardware discovery to populate [DISCOVERED] values" -ForegroundColor White
    Write-Host "    3. Run Generate-ConfigFromMD.ps1 to create yaml/json" -ForegroundColor White
    Write-Host "    4. Run Validate-ClusterConfig.ps1 to verify completeness" -ForegroundColor White
}

Write-Host ""
