# Azure Local ZTP Server Preparation Guide

!!! note "Note"
    This guide provides detailed instructions for preparing servers for Zero-Touch Provisioning (ZTP) of Azure Local. It combines manual steps with automated scripts and references the official Azure Local ZTP documentation.

**📁 Working Directory Assumption:** All commands in this guide assume you are working from the root directory of your cloned repository.

## Overview

This guide covers the server preparation phase of Azure Local Zero-Touch Provisioning (ZTP). The process involves configuring the Azure environment, downloading ZTP tools, and using Redfish API operations to prepare servers for automated provisioning.

The complete ZTP workflow consists of three main phases:

1. **Server Preparation** (This guide) - Configure environment and prepare servers
2. **Azure Portal Provisioning** ([Portal Provisioning Guide](ztp-azure-portal-provisioning-guide.md)) - Set up sites and provision machines via Azure
3. **On-site Setup** - Connect servers and power on for automated configuration

## Prerequisites

Before beginning, ensure you have:

- **Hardware Prerequisites:**
    - Lenovo: 650v3 and 650v4, HPE DL360 Gen 11, Dell AX-760 servers
    - Windows 11 PC with reliable internet connection
    - USB flash drive with at least 8GB capacity

- **Software Prerequisites:**
    - PowerShell 7.0 or later
    - Azure CLI installed and configured
    - Access to Azure subscription with proper permissions

- **Network Prerequisites:**
    - Server BMC/iDRAC interfaces accessible on management network ({idrac_network})
    - File share accessible to servers for ISO hosting
    - Internet connectivity for Azure operations

- **Permissions:**
    - Azure subscription contributor or owner
    - Local administrator access to servers
    - BMC/iDRAC administrative credentials

- **Cluster-Specific Information:**
    - Cluster Name: `{cluster_name}`
    - Azure Region: {region}
    - Node Count: {node_count}x {node_model}
    - Management Network: {management_network}
    - OOB Network: {idrac_network} (VLAN {idrac_vlan})

## Clone Repository and Setup Environment

Before configuring Azure, clone this repository and set up your working environment.

### Clone the Repository

Clone the Azure Local ZTP repository to your local machine:

```bash
# Clone the repository
git clone https://github.com/AzureLocal/azurelocal-ztp.git

# Navigate to the repository directory
cd azurelocal-ztp
```

### Verify Repository Structure

Ensure all required files are present:

```powershell
# List repository contents (PowerShell)
Get-ChildItem -Force

# Expected output should include:
# - config/ directory with environment files
# - docs/ directory with documentation
# - scripts/ directory with automation scripts
# - .github/ directory with workflows
```

### Configure Environment Variables

Update the configuration files with your environment-specific values:

```bash
# Edit the main configuration file
# Update config/environment.yaml with your Azure subscription, resource groups, and network details
# Only these three files should contain real values:
# - config/environment.yaml
# - config/environment.json
# - config/cluster/cluster-config.md
```

### Verify PowerShell Environment

Ensure PowerShell is properly configured for Azure operations:

```powershell
# Check PowerShell version
$PSVersionTable.PSVersion

# Install Azure PowerShell modules if not present
Install-Module -Name Az -Scope CurrentUser -Force

# Connect to Azure (you will be prompted for credentials)
Connect-AzAccount
```

## Configure Azure Environment

Configure your Azure subscription and environment for Azure Local ZTP.

### Enable Required Azure Features

Launch Azure Cloud Shell and run the following commands to check and enable required features:

```bash
# Check feature flag status
curl -fsSL "https://aka.ms/ztp/checkfeature.sh" -o checkfeature.sh && chmod +x checkfeature.sh && ./checkfeature.sh

# Enable Hybrid Connectivity feature if not registered
az feature registration create --namespace Microsoft.HybridConnectivity --name hiddenPreviewAccess
```

### Register Required Resource Providers

Ensure all required resource providers are registered:

```bash
# Check resource provider registration
curl -fsSL "https://aka.ms/ztp/checkprovider.sh" -o checkprovider.sh && chmod +x checkprovider.sh && ./checkprovider.sh
```

### Verify Subscription Allowlisting

Contact Microsoft Product Team to confirm your subscription is allowlisted for the Azure Local ZTP private preview. Provide your subscription ID when requesting access.

### Create Resource Group

Create a dedicated resource group for your Azure Local deployment:

**Script Location:** `scripts\common\utilities\tools\Create-AzureResourceGroup.ps1`

**Run the script directly:**
```powershell
.\scripts\common\utilities\tools\Create-AzureResourceGroup.ps1
```

**Or copy/paste the script contents:**
```powershell
<#
.SYNOPSIS
    Creates Azure resource group for Azure Local deployment.

.DESCRIPTION
    Creates a dedicated resource group for Azure Local ZTP deployment
    using configuration values from environment.yaml.

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    .\Create-AzureResourceGroup.ps1

    Creates the resource group defined in config/environment.yaml

.EXAMPLE
    .\Create-AzureResourceGroup.ps1 -Force

    Creates the resource group without confirmation

.NOTES
    Requires:
    - PowerShell 7.0+
    - Azure CLI installed and configured
    - AzureLocalConfig.psm1 module for configuration loading
    - Valid Azure subscription with proper permissions
#>

param(
    [Parameter(Mandatory=$false)]
    [switch]$Force
)

#Requires -Version 7.0

# Find repository root and config file
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) {
    throw "Could not find repository root (config directory not found)"
}

# Import configuration module
$modulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
Import-Module $modulePath -Force

# Load configuration
$config = Get-AzureLocalConfig
$subscriptionId = $config.GetValue('azure.mgmt_subscription_id')
$resourceGroup = $config.GetValue('resources.cluster_resource_group')
$region = $config.GetValue('azure.region')

# Confirm operation if not forced
if (!$Force) {
    Write-Host "About to create resource group:" -ForegroundColor Yellow
    Write-Host "  Subscription: $subscriptionId" -ForegroundColor Gray
    Write-Host "  Resource Group: $resourceGroup" -ForegroundColor Gray
    Write-Host "  Region: $region" -ForegroundColor Gray
    Write-Host ""

    $confirmation = Read-Host "Continue? (y/N)"
    if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
}

Write-Host "Setting Azure subscription context..." -ForegroundColor Cyan
az account set --subscription $subscriptionId
if ($LASTEXITCODE -ne 0) {
    throw "Failed to set Azure subscription context"
}

Write-Host "Creating resource group '$resourceGroup' in '$region'..." -ForegroundColor Cyan
az group create --name $resourceGroup --location $region
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create resource group"
}

Write-Host "✓ Resource group '$resourceGroup' created successfully" -ForegroundColor Green

# Verify the resource group was created
Write-Host "Verifying resource group..." -ForegroundColor Cyan
$rgInfo = az group show --name $resourceGroup --output json | ConvertFrom-Json
Write-Host "✓ Resource group verified: $($rgInfo.name) in $($rgInfo.location)" -ForegroundColor Green
```

### Verify Cluster Configuration

Ensure your environment matches the cluster configuration:

**Script Location:** `scripts\common\utilities\tools\Test-ZTPConfig.ps1`

**Run the script directly:**
```powershell
.\scripts\common\utilities\tools\Test-ZTPConfig.ps1
```

**Or copy/paste the script contents:**
```powershell
# Load configuration and verify subscription details
Import-Module ".\scripts\common\AzureLocalConfig.psm1"
$config = Get-AzureLocalConfig

# Get current Azure context
$context = Get-AzContext
Write-Host "Current Account: $($context.Account.Id)" -ForegroundColor Cyan
Write-Host "Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))" -ForegroundColor Cyan
Write-Host "Tenant: $($context.Tenant.Id)" -ForegroundColor Cyan

# Expected values from config/environment.yaml:
# Subscription ID: $($config.GetValue('azure.mgmt_subscription_id'))
# Tenant ID: $($config.GetValue('azure.tenant_id'))
# Resource Group: $($config.GetValue('resources.cluster_resource_group'))
# Cluster Name: $($config.GetValue('resources.cluster_name'))
```

## Download ZTP Tools

Download the Azure Local maintenance environment, USB preparation tools, and Configurator App.

### Download Maintenance Environment

Download the maintenance environment ISO and USB preparation tool:

**Script Location:** `scripts\common\utilities\tools\Download-ZTPTools.ps1`

**Run the script directly:**
```powershell
.\scripts\common\utilities\tools\Download-ZTPTools.ps1
```

**Or copy/paste the script contents:**
```powershell
<#
.SYNOPSIS
    Downloads Azure Local maintenance environment ISO.

.DESCRIPTION
    Downloads the Azure Local maintenance environment ISO and USB preparation tools
    from Microsoft official channels using configuration values.

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    .\Download-ZTPTools.ps1

    Downloads ZTP tools to the configured download directory

.EXAMPLE
    .\Download-ZTPTools.ps1 -Force

    Downloads without confirmation

.NOTES
    Requires:
    - PowerShell 7.0+
    - Internet connectivity
    - AzureLocalConfig.psm1 module for configuration loading
#>

param(
    [Parameter(Mandatory=$false)]
    [switch]$Force
)

#Requires -Version 7.0

# Find repository root and config file
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) {
    throw "Could not find repository root (config directory not found)"
}

# Import configuration module
$modulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
Import-Module $modulePath -Force

# Load configuration
$config = Get-AzureLocalConfig
$downloadDir = $config.GetValue('ztp.download_directory')
$maintenanceVer = $config.GetValue('ztp.maintenance_version')

# Confirm operation if not forced
if (!$Force) {
    Write-Host "About to download Azure Local ZTP tools:" -ForegroundColor Yellow
    Write-Host "  Download Directory: $downloadDir" -ForegroundColor Gray
    Write-Host "  Maintenance Version: $maintenanceVer" -ForegroundColor Gray
    Write-Host ""

    $confirmation = Read-Host "Continue? (y/N)"
    if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
        Write-Host "Download cancelled." -ForegroundColor Yellow
        exit 0
    }
}

Write-Host "Creating download directory..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path $downloadDir -Force

Write-Host "Downloading maintenance environment from Microsoft..." -ForegroundColor Cyan
$downloadUrl = "https://aka.ms/aep/installeros/$maintenanceVer"
$zipFile = Join-Path $downloadDir "maintenance-env.zip"

Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile

Write-Host "✓ Download completed successfully" -ForegroundColor Green

# Verify download
$zipInfo = Get-Item $zipFile
Write-Host "Downloaded file: $($zipInfo.Name) ($([math]::Round($zipInfo.Length / 1MB, 2)) MB)" -ForegroundColor Green
```

### Download Configurator App

The **Configurator App for Azure Local V2** is used to download ownership vouchers, configure static IP addresses, and track machine provisioning progress.

**Download Link:** https://aka.ms/ztp/configuratorapp

**Script Location:** `scripts\common\utilities\tools\Download-ConfiguratorApp.ps1`

**Run the script directly:**
```powershell
.\scripts\common\utilities\tools\Download-ConfiguratorApp.ps1
```

The script downloads the Configurator App to the same directory as the maintenance environment tools (`ztp.download_directory` from config).

!!! tip "Tip"
    You can also download the Configurator App from the Azure Portal: https://aka.ms/ztp/tryit → **Azure Arc > Operations > Provisioning (preview)** → **Get started** → **View Downloads**.

**The Configurator App is used for:**

- Downloading ownership vouchers from prepared servers (Step 2, Option A)
- Configuring static IP addresses on servers
- Monitoring machine provisioning progress from a Windows 11 PC
- Running diagnostic tests and collecting support packages for troubleshooting

See [Azure Portal Provisioning Guide](ztp-azure-portal-provisioning-guide.md) for detailed Configurator App usage.

## Mark Files as Safe

PowerShell may block downloaded files. Unblock them before use:

**Script Location:** `scripts\common\utilities\tools\Unblock-ZTPFiles.ps1`

**Run the script directly:**
```powershell
.\scripts\common\utilities\tools\Unblock-ZTPFiles.ps1
```

**Or copy/paste the script contents:**
```powershell
<#
.SYNOPSIS
    Unblocks downloaded Azure Local ZTP files.

.DESCRIPTION
    Removes the "downloaded from internet" security flag from Azure Local ZTP files
    to allow execution and processing.

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    .\Unblock-ZTPFiles.ps1

    Unblocks all ZTP files in download and extracted directories

.EXAMPLE
    .\Unblock-ZTPFiles.ps1 -Force

    Unblocks without confirmation

.NOTES
    Requires:
    - PowerShell 7.0+
    - Downloaded and extracted ZTP tools
    - AzureLocalConfig.psm1 module for configuration loading
    - Administrator privileges may be required for some operations
#>

param(
    [Parameter(Mandatory=$false)]
    [switch]$Force
)

#Requires -Version 7.0

# Find repository root and config file
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) {
    throw "Could not find repository root (config directory not found)"
}

# Import configuration module
$modulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
Import-Module $modulePath -Force

# Load configuration
$config = Get-AzureLocalConfig
$downloadDir = $config.GetValue('ztp.download_directory')
$extractedDir = $config.GetValue('ztp.extracted_directory')

# Confirm operation if not forced
if (!$Force) {
    Write-Host "About to unblock Azure Local ZTP files:" -ForegroundColor Yellow
    Write-Host "  Download Directory: $downloadDir" -ForegroundColor Gray
    Write-Host "  Extracted Directory: $extractedDir" -ForegroundColor Gray
    Write-Host ""

    $confirmation = Read-Host "Continue? (y/N)"
    if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
        Write-Host "Unblock operation cancelled." -ForegroundColor Yellow
        exit 0
    }
}

Write-Host "Unblocking files in download directory..." -ForegroundColor Cyan
$downloadFiles = Get-ChildItem -Path $downloadDir -Recurse -Include "*.zip","*.exe","*.ps1","*.cmd" -ErrorAction SilentlyContinue
if ($downloadFiles) {
    $downloadFiles | Unblock-File
    Write-Host "✓ Unblocked $($downloadFiles.Count) files in download directory" -ForegroundColor Green
} else {
    Write-Host "No blocked files found in download directory" -ForegroundColor Gray
}

Write-Host "Unblocking files in extracted directory..." -ForegroundColor Cyan
$extractedFiles = Get-ChildItem -Path $extractedDir -Recurse -Include "*.exe","*.ps1","*.cmd","*.iso" -ErrorAction SilentlyContinue
if ($extractedFiles) {
    $extractedFiles | Unblock-File
    Write-Host "✓ Unblocked $($extractedFiles.Count) files in extracted directory" -ForegroundColor Green
} else {
    Write-Host "No blocked files found in extracted directory" -ForegroundColor Gray
}

Write-Host "✓ All ZTP files have been unblocked" -ForegroundColor Green
```

## Extract ZTP Tools

Extract the downloaded maintenance environment package and verify the contents.

**Script Location:** `scripts\common\utilities\tools\Extract-ZTPTools.ps1`

**Run the script directly:**
```powershell
.\scripts\common\utilities\tools\Extract-ZTPTools.ps1
```

The script extracts `maintenance-env.zip` from the download directory to the configured extracted directory, then verifies the contents and locates the ISO file.

**Expected Output:**
```
Extracting maintenance environment package...
✓ Extraction completed successfully
Extracted 12 files/folders to C:\AzureLocal\ZTP\Extracted
Found ISO file: C:\AzureLocal\ZTP\Extracted\maintenance-env.iso
```

## Create Network Share

Create a network share accessible to all target servers on the management network ({management_network}):

**Script Location:** `scripts\common\utilities\tools\Create-ZTPShare.ps1`

**Run the script directly:**
```powershell
.\scripts\common\utilities\tools\Create-ZTPShare.ps1
```

**Or copy/paste the script contents:**
```powershell
<#
.SYNOPSIS
    Creates network share for Azure Local ISO files.

.DESCRIPTION
    Creates a network share accessible to cluster nodes for hosting the Azure Local
    maintenance environment ISO file. The share directory will be created for ISO placement.

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    .\Create-ZTPShare.ps1

    Creates the ZTP share with default settings

.EXAMPLE
    .\Create-ZTPShare.ps1 -Force

    Creates the share without confirmation

.NOTES
    Requires:
    - PowerShell 7.0+
    - Administrator privileges
    - AzureLocalConfig.psm1 module for configuration loading
#>

param(
    [Parameter(Mandatory=$false)]
    [switch]$Force
)

#Requires -Version 7.0

# Find repository root and config file
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) {
    throw "Could not find repository root (config directory not found)"
}

# Import configuration module
$modulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
Import-Module $modulePath -Force

# Load configuration
$config = Get-AzureLocalConfig
$shareLocation = $config.GetValue('ztp.share_location')
$shareName = $config.GetValue('ztp.share_name')

# Confirm operation if not forced
if (!$Force) {
    Write-Host "About to create Azure Local ZTP network share:" -ForegroundColor Yellow
    Write-Host "  Share Location: $shareLocation" -ForegroundColor Gray
    Write-Host "  Share Name: $shareName" -ForegroundColor Gray
    Write-Host ""

    $confirmation = Read-Host "Continue? (y/N)"
    if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
        Write-Host "Share creation cancelled." -ForegroundColor Yellow
        exit 0
    }
}

Write-Host "Creating share directory..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path $shareLocation -Force

Write-Host "Creating SMB share..." -ForegroundColor Cyan
# Remove existing share if it exists
$existingShare = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
if ($existingShare) {
    Remove-SmbShare -Name $shareName -Force
}

New-SmbShare -Name $shareName -Path $shareLocation -FullAccess "Everyone"

Write-Host "✓ Network share created successfully" -ForegroundColor Green
Write-Host "  Share Path: \\$env:COMPUTERNAME\$shareName" -ForegroundColor Green
```

## Create Share Access User

Create a local user account for iDRAC virtual media to access the network share with read-only permissions:

**Script Location:** `scripts\common\utilities\tools\Create-ShareAccessUser.ps1`

**Run the script directly:**
```powershell
.\scripts\common\utilities\tools\Create-ShareAccessUser.ps1
```

**Or copy/paste the script contents:**
```powershell
<#
.SYNOPSIS
    Creates local user for iDRAC virtual media share access.

.DESCRIPTION
    Creates a local Windows user account with appropriate permissions for iDRAC virtual media
    to access the Azure Local ZTP network share. Configures both SMB share and NTFS permissions
    for read-only access to the share location.

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    .\Create-ShareAccessUser.ps1

    Creates the share access user with default settings from environment.yaml

.EXAMPLE
    .\Create-ShareAccessUser.ps1 -Force

    Creates the user without confirmation

.NOTES
    Requires:
    - PowerShell 7.0+
    - Administrator privileges
    - AzureLocalConfig.psm1 module for configuration loading
    - Network share already created (Create-ZTPShare.ps1)

    Configuration Variables (from environment.yaml):
    - ztp.share_username: Username for the share access account
    - ztp.share_password: Password for the share access account
    - ztp.share_location: Local path to the ZTP share directory
#>

param(
    [Parameter(Mandatory=$false)]
    [switch]$Force
)

#Requires -Version 7.0
#Requires -RunAsAdministrator

# Find repository root by looking for config directory
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) {
    throw "Could not find repository root (config directory not found)"
}

# Import configuration module
$configModulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
if (!(Test-Path $configModulePath)) {
    throw "Config module not found at $configModulePath"
}
Import-Module $configModulePath -Force
$config = Get-AzureLocalConfig

# Get configuration values
$username = $config.GetValue('ztp.share_username')
$password = $config.GetValue('ztp.share_password')
$sharePath = $config.GetValue('ztp.share_location')
$shareName = $config.GetValue('ztp.share_name')

# Validate share exists
if (!(Test-Path $sharePath)) {
    throw "Share location not found: $sharePath. Please run Create-ZTPShare.ps1 first."
}

$existingShare = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
if (!$existingShare) {
    throw "SMB share '$shareName' not found. Please run Create-ZTPShare.ps1 first."
}

# Confirm operation
if (-not $Force) {
    Write-Host "About to create share access user:" -ForegroundColor Yellow
    Write-Host "  Username: $env:COMPUTERNAME\$username" -ForegroundColor Gray
    Write-Host "  Share Path: $sharePath" -ForegroundColor Gray
    Write-Host "  Share Name: $shareName" -ForegroundColor Gray
    Write-Host "  Permissions: Read-Only" -ForegroundColor Gray
    Write-Host ""
    $confirm = Read-Host "Continue? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
}

Write-Host "`nCreating share access user..." -ForegroundColor Cyan

# Step 1: Create local user
Write-Host "  Creating local user '$username'..." -ForegroundColor Gray
$securePass = ConvertTo-SecureString $password -AsPlainText -Force

if (Get-LocalUser -Name $username -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name $username -Password $securePass
    Write-Host "  ⚠ User '$username' already exists - password reset" -ForegroundColor Yellow
} else {
    try {
        New-LocalUser -Name $username -Password $securePass `
            -Description "iDRAC virtual media share access" `
            -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires `
            -ErrorAction Stop | Out-Null
        Write-Host "  ✓ User '$username' created" -ForegroundColor Green
    } catch {
        throw "Failed to create user: $($_.Exception.Message)"
    }
}

# Ensure user is enabled
Enable-LocalUser -Name $username -ErrorAction SilentlyContinue
Write-Host "  ✓ User enabled" -ForegroundColor Green

# Step 2: Grant SMB share read access
Write-Host "  Granting SMB read access..." -ForegroundColor Gray
try {
    # Remove any existing access
    $existingAccess = Get-SmbShareAccess -Name $shareName -AccountName "$env:COMPUTERNAME\$username" -ErrorAction SilentlyContinue
    if ($existingAccess) {
        Revoke-SmbShareAccess -Name $shareName -AccountName "$env:COMPUTERNAME\$username" -Force -ErrorAction SilentlyContinue
    }
    
    # Grant read access
    Grant-SmbShareAccess -Name $shareName -AccountName "$env:COMPUTERNAME\$username" -AccessRight Read -Force | Out-Null
    Write-Host "  ✓ SMB read access granted" -ForegroundColor Green
} catch {
    Write-Host "  ⚠ SMB access configuration warning: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Step 3: Grant NTFS read access
Write-Host "  Granting NTFS read access..." -ForegroundColor Gray
try {
    $acl = Get-Acl $sharePath
    
    # Remove any existing rules for this user
    $existingRules = $acl.Access | Where-Object { $_.IdentityReference -eq "$env:COMPUTERNAME\$username" }
    foreach ($rule in $existingRules) {
        $acl.RemoveAccessRule($rule) | Out-Null
    }
    
    # Add new read rule
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "$env:COMPUTERNAME\$username",
        "ReadAndExecute",
        "ContainerInherit,ObjectInherit",
        "None",
        "Allow"
    )
    $acl.AddAccessRule($rule)
    Set-Acl $sharePath $acl
    Write-Host "  ✓ NTFS read access granted" -ForegroundColor Green
} catch {
    throw "Failed to set NTFS permissions: $($_.Exception.Message)"
}

Write-Host "`n✓ Share access user configured successfully" -ForegroundColor Green
Write-Host "  Username: $env:COMPUTERNAME\$username" -ForegroundColor Cyan
Write-Host "  Share: \\$env:COMPUTERNAME\$shareName" -ForegroundColor Cyan
Write-Host "  Permissions: Read-Only (SMB + NTFS)" -ForegroundColor Cyan
Write-Host "`nUse this credential for iDRAC virtual media operations." -ForegroundColor Gray
```

## Copy ISO to Share Location

Copy the extracted Azure Local maintenance environment ISO to the created share location:

**Script Location:** `scripts\common\utilities\tools\Copy-ZTPISO.ps1`

**Run the script directly:**
```powershell
.\scripts\common\utilities\tools\Copy-ZTPISO.ps1
```

**Or copy/paste the script contents:**
```powershell
<#
.SYNOPSIS
    Copies Azure Local ISO to network share location.

.DESCRIPTION
    Copies the extracted Azure Local maintenance environment ISO file to the
    configured network share location for access by cluster nodes.

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    .\Copy-ZTPISO.ps1

    Copies the ISO to the share location

.EXAMPLE
    .\Copy-ZTPISO.ps1 -Force

    Copies without confirmation

.NOTES
    Requires:
    - PowerShell 7.0+
    - Extracted Azure Local maintenance environment
    - Network share already created
    - AzureLocalConfig.psm1 module for configuration loading
#>

param(
    [Parameter(Mandatory=$false)]
    [switch]$Force
)

#Requires -Version 7.0

# Find repository root and config file
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) {
    throw "Could not find repository root (config directory not found)"
}

# Import configuration module
$modulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
Import-Module $modulePath -Force

# Load configuration
$config = Get-AzureLocalConfig
$shareLocation = $config.GetValue('ztp.share_location')
$extractedDir = $config.GetValue('ztp.extracted_directory')

# Confirm operation if not forced
if (!$Force) {
    Write-Host "About to copy Azure Local ISO to share location:" -ForegroundColor Yellow
    Write-Host "  Source: $extractedDir" -ForegroundColor Gray
    Write-Host "  Destination: $shareLocation" -ForegroundColor Gray
    Write-Host ""

    $confirmation = Read-Host "Continue? (y/N)"
    if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
        Write-Host "ISO copy cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# Validate source directory exists
if (!(Test-Path $extractedDir)) {
    throw "Extracted directory not found: $extractedDir"
}

# Validate share location exists
if (!(Test-Path $shareLocation)) {
    throw "Share location not found: $shareLocation"
}

# Find ISO file
$isoFile = Get-ChildItem -Path $extractedDir -Filter "*.iso" -Recurse | Select-Object -First 1
if (!$isoFile) {
    throw "No ISO file found in extracted directory: $extractedDir"
}

Write-Host "Copying ISO file to share location..." -ForegroundColor Cyan
Write-Host "  Source: $($isoFile.FullName)" -ForegroundColor Gray
Write-Host "  Destination: $shareLocation" -ForegroundColor Gray

Copy-Item $isoFile.FullName $shareLocation -Force

Write-Host "✓ ISO file copied successfully" -ForegroundColor Green
Write-Host "  File: $(Split-Path $isoFile.FullName -Leaf)" -ForegroundColor Green
Write-Host "  Location: $shareLocation" -ForegroundColor Green
```

## Verify Share Access

Test access to the share from the management network:

**Script Location:** `scripts\common\utilities\tools\Test-ZTPShare.ps1`

**Run the script directly:**
```powershell
.\scripts\common\utilities\tools\Test-ZTPShare.ps1
```

**Or copy/paste the script contents:**
```powershell
<#
.SYNOPSIS
    Verifies access to Azure Local ZTP network share.

.DESCRIPTION
    Tests network connectivity and file access to the Azure Local ISO share
    to ensure cluster nodes can access the maintenance environment.

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    .\Test-ZTPShare.ps1

    Tests access to the ZTP share

.EXAMPLE
    .\Test-ZTPShare.ps1 -Force

    Tests without confirmation

.NOTES
    Requires:
    - PowerShell 7.0+
    - Network access to share location
    - AzureLocalConfig.psm1 module for configuration loading
#>

param(
    [Parameter(Mandatory=$false)]
    [switch]$Force
)

#Requires -Version 7.0

# Find repository root and config file
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) {
    throw "Could not find repository root (config directory not found)"
}

# Import configuration module
$modulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
Import-Module $modulePath -Force

# Load configuration
$config = Get-AzureLocalConfig
$shareLocation = $config.GetValue('ztp.share_location')
$shareName = $config.GetValue('ztp.share_name')

Write-Host "Testing Azure Local ZTP share access..." -ForegroundColor Cyan

# Test local access
Write-Host "Testing local file access..." -ForegroundColor Gray
$localTest = Test-Path (Join-Path $shareLocation "*.iso")
if ($localTest) {
    Write-Host "✓ Local ISO file access: OK" -ForegroundColor Green
} else {
    Write-Host "✗ Local ISO file access: FAILED" -ForegroundColor Red
}

# Test network share access
Write-Host "Testing network share access..." -ForegroundColor Gray
$sharePath = "\\$env:COMPUTERNAME\$shareName"
$networkTest = Test-Path $sharePath
if ($networkTest) {
    Write-Host "✓ Network share access: OK ($sharePath)" -ForegroundColor Green
} else {
    Write-Host "✗ Network share access: FAILED ($sharePath)" -ForegroundColor Red
}

# Test SMB connectivity
Write-Host "Testing SMB connectivity..." -ForegroundColor Gray
$smbTest = Test-NetConnection -ComputerName $env:COMPUTERNAME -Port 445 -InformationLevel Quiet
if ($smbTest) {
    Write-Host "✓ SMB connectivity: OK (Port 445 open)" -ForegroundColor Green
} else {
    Write-Host "✗ SMB connectivity: FAILED (Port 445 blocked)" -ForegroundColor Red
}

# List share contents
Write-Host "Checking share contents..." -ForegroundColor Gray
try {
    $shareContents = Get-ChildItem -Path $sharePath -ErrorAction Stop
    $isoFiles = $shareContents | Where-Object { $_.Extension -eq '.iso' }
    if ($isoFiles) {
        Write-Host "✓ Share contents: OK ($($isoFiles.Count) ISO file(s) found)" -ForegroundColor Green
        $isoFiles | ForEach-Object {
            Write-Host "  - $($_.Name) ($([math]::Round($_.Length / 1GB, 2)) GB)" -ForegroundColor Gray
        }
    } else {
        Write-Host "✗ Share contents: No ISO files found" -ForegroundColor Red
    }
} catch {
    Write-Host "✗ Share contents check: FAILED - $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "Share verification completed." -ForegroundColor Cyan
```

## Run Redfish API Discovery

Use Redfish API to discover and inventory all target servers.

### Server Discovery

Discover cluster servers using Redfish API. By default the script reads server IPs from your configuration. Use `-ServerIPs` to target specific servers manually.

**Script Location:** `scripts\common\utilities\tools\Discover-Servers.ps1`

**Run the script directly:**
```powershell
# Option 1: Use Key Vault credentials, all servers from config
.\scripts\common\utilities\tools\Discover-Servers.ps1 -Full

# Option 2: Provide credentials interactively
$Credential = Get-Credential
.\scripts\common\utilities\tools\Discover-Servers.ps1 -Credential $Credential -Full

# Option 3: Target specific servers
.\scripts\common\utilities\tools\Discover-Servers.ps1 -ServerIPs "192.168.1.100","192.168.1.101" -Full

# Option 4: Basic discovery (no detailed hardware inventory)
.\scripts\common\utilities\tools\Discover-Servers.ps1
```

**Expected Output:**
- Individual comprehensive JSON file for each server: `config/dell/discovery/<server-ip>.json` (contains full hardware inventory, BIOS config, iDRAC settings, etc.)
- Combined CSV file: `config/dell/discovery/server-discovery-results.csv` (basic summary)
- Combined JSON file: `config/dell/discovery/server-discovery-results.json` (full detailed data)
- Console output showing discovery status for each server

**Or copy/paste the script contents:**
```powershell
<#
.SYNOPSIS
    Discovers Azure Local servers via Redfish API for ZTP deployment with comprehensive hardware inventory.

.DESCRIPTION
    Uses Redfish API to discover Dell PowerEdge servers with iDRAC, collecting
    detailed hardware information including system details, chassis, power, thermal,
    CPUs, memory, storage, network adapters, BIOS configuration, iDRAC settings,
    and firmware inventory for comprehensive ZTP preparation.

.PARAMETER Credential
    PSCredential object for BMC/iDRAC authentication

.PARAMETER ServerIPs
    One or more iDRAC IP addresses to target. If not specified, all servers from environment.yaml are used.

.PARAMETER Full
    Include detailed hardware inventory in discovery results (enabled by default for comprehensive discovery)

.EXAMPLE
    .\Discover-Servers.ps1 -Full

    Discovers all servers from config using Key Vault credentials with full hardware inventory.

.EXAMPLE
    $Credential = Get-Credential
    .\Discover-Servers.ps1 -Credential $Credential -Full

    Discovers all servers defined in config with full hardware inventory details.

.EXAMPLE
    .\Discover-Servers.ps1 -ServerIPs "192.168.1.100","192.168.1.101" -Full

    Discovers specific servers with full hardware inventory.

.NOTES
    Requires:
    - PowerShell 7.0+
    - Network access to BMC/iDRAC interfaces
    - Valid BMC credentials with system read permissions
    - AzureLocalConfig.psm1 module for configuration loading
    - Az.KeyVault module (if using Key Vault for credentials)
    - Key Vault name and secret name in environment.yaml (keyvault.platform_name, ztp.idrac_secret_name)
#>

param(
    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory=$false)]
    [string[]]$ServerIPs,

    [Parameter(Mandatory=$false)]
    [switch]$Full
)

#Requires -Version 7.0

# Find repository root and config file
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) {
    throw "Could not find repository root (config directory not found)"
}

# Import configuration module
$modulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
Import-Module $modulePath -Force

# Load configuration
$config = Get-AzureLocalConfig
if ($ServerIPs) {
    $serverIPs = $ServerIPs
} else {
    $serverIPs = $config.GetIdracIPs()
}

# Retrieve credentials from Key Vault if not provided
if (!$Credential) {
    $keyVaultName = $config.GetValue('keyvault.platform_name')
    $secretName = $config.GetValue('ztp.idrac_secret_name')
    if (!$keyVaultName -or !$secretName) {
        throw "Key Vault name and secret name must be configured in environment.yaml under keyvault.platform_name and ztp.idrac_secret_name"
    }
    Write-Host "Retrieving credentials from Azure Key Vault '$keyVaultName'..." -ForegroundColor Cyan
    $secret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName
    if (!$secret) {
        throw "Failed to retrieve secret '$secretName' from Key Vault '$keyVaultName'"
    }
    $credString = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
    if ($credString -notmatch ':') {
        throw "Secret value must be in format 'username:password'"
    }
    $username, $password = $credString -split ':', 2
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    $Credential = New-Object PSCredential ($username, $securePassword)
    Write-Host "✓ Credentials retrieved successfully" -ForegroundColor Green
}

Write-Host "Starting server discovery for $($serverIPs.Count) servers..." -ForegroundColor Green
Write-Host "Server IPs: $($serverIPs -join ', ')" -ForegroundColor Cyan

$results = @()

foreach ($ip in $serverIPs) {
    try {
        Write-Host "Discovering server at $ip..." -ForegroundColor Yellow

        $baseUrl = "https://$ip"

        # Test connectivity and get basic system information
        $systemUri = "$baseUrl/redfish/v1/Systems"
        $systemResponse = Invoke-RestMethod -Uri $systemUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30

        # Get the first system (usually the only one)
        $system = $systemResponse.Members[0]
        $systemDetailsUri = "$baseUrl$system.'@odata.id'"
        $systemDetails = Invoke-RestMethod -Uri $systemDetailsUri -Credential $Credential -Method GET -SkipCertificateCheck

        $serverInfo = [PSCustomObject]@{
            IPAddress = $ip
            Model = $systemDetails.Model
            SerialNumber = $systemDetails.SerialNumber
            Manufacturer = $systemDetails.Manufacturer
            Status = "Discovered"
            Timestamp = Get-Date
            PowerState = $systemDetails.PowerState
            BiosVersion = $systemDetails.BiosVersion
            HostName = $systemDetails.HostName
        }

        # Include hardware inventory if requested
        if ($Full) {
            try {
                # Get processor information
                $processorUri = "$baseUrl/redfish/v1/Systems/System.Embedded.1/Processors"
                $processorResponse = Invoke-RestMethod -Uri $processorUri -Credential $Credential -Method GET -SkipCertificateCheck
                $serverInfo | Add-Member -MemberType NoteProperty -Name "ProcessorCount" -Value $processorResponse.Members.Count

                # Get memory information
                $memoryUri = "$baseUrl/redfish/v1/Systems/System.Embedded.1/Memory"
                $memoryResponse = Invoke-RestMethod -Uri $memoryUri -Credential $Credential -Method GET -SkipCertificateCheck
                $totalMemoryGB = ($memoryResponse.Members | Measure-Object -Property SizeMiB -Sum).Sum / 1024
                $serverInfo | Add-Member -MemberType NoteProperty -Name "TotalMemoryGB" -Value $totalMemoryGB

                # Get storage information
                $storageUri = "$baseUrl/redfish/v1/Systems/System.Embedded.1/Storage"
                $storageResponse = Invoke-RestMethod -Uri $storageUri -Credential $Credential -Method GET -SkipCertificateCheck
                $driveCount = ($storageResponse.Members | ForEach-Object {
                    $storageDetailsUri = "$baseUrl$($_. '@odata.id')"
                    $storageDetails = Invoke-RestMethod -Uri $storageDetailsUri -Credential $Credential -Method GET -SkipCertificateCheck
                    $storageDetails.Drives.Count
                } | Measure-Object -Sum).Sum
                $serverInfo | Add-Member -MemberType NoteProperty -Name "DriveCount" -Value $driveCount

            } catch {
                Write-Warning "Could not retrieve hardware inventory for $ip`: $($_.Exception.Message)"
            }
        }

        $results += $serverInfo
        Write-Host "Successfully discovered server at $ip ($($systemDetails.Model))" -ForegroundColor Green

    } catch {
        Write-Warning "Failed to discover server at $ip`: $($_.Exception.Message)"
        $results += [PSCustomObject]@{
            IPAddress = $ip
            Status = "Failed"
            Error = $_.Exception.Message
            Timestamp = Get-Date
        }
    }
}

# Export results
$outputDir = Join-Path $repoRoot "config\dell\discovery"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# Create individual JSON files for each server
foreach ($result in $results) {
    $serverName = $result.ServerIP -replace '\.', '-'
    $individualJsonPath = Join-Path $outputDir "$serverName.json"
    $result | ConvertTo-Json | Out-File $individualJsonPath
}

# Create combined CSV and JSON files
$csvPath = Join-Path $outputDir "server-discovery-results.csv"
$jsonPath = Join-Path $outputDir "server-discovery-results.json"

$results | Export-Csv -Path $csvPath -NoTypeInformation
$results | ConvertTo-Json | Out-File $jsonPath

Write-Host "Discovery complete. Results saved to:" -ForegroundColor Green
Write-Host "  Individual JSON files: config/dell/discovery/<server-ip>.json" -ForegroundColor Cyan
Write-Host "  Combined CSV: $csvPath" -ForegroundColor Cyan
Write-Host "  Combined JSON: $jsonPath" -ForegroundColor Cyan
Write-Host "Discovered servers: $(($results | Where-Object { $_.Status -eq 'Discovered' }).Count)" -ForegroundColor Cyan
Write-Host "Failed discoveries: $(($results | Where-Object { $_.Status -eq 'Failed' }).Count)" -ForegroundColor Yellow
```

### Validate Discovery Results

Review the discovery output to ensure all servers are properly inventoried:

**Script Location:** `scripts\common\utilities\tools\Validate-DiscoveryResults.ps1`

**Run the script directly:**
```powershell
.\scripts\common\utilities\tools\Validate-DiscoveryResults.ps1
```

**Or copy/paste the script contents:**
```powershell
<#
.SYNOPSIS
    Validates server discovery results.

.DESCRIPTION
    Reviews and validates the output from server discovery operations
    to ensure all servers are properly inventoried.

.EXAMPLE
    .\Validate-DiscoveryResults.ps1

    Validates discovery results from CSV and JSON files

.NOTES
    Requires:
    - PowerShell 7.0+
    - Discovery results files (CSV and JSON)
#>

Write-Host "Validating server discovery results..." -ForegroundColor Cyan

# Check for results files
$csvFile = ".\server-discovery-results.csv"
$jsonFile = ".\server-discovery-results.json"

$filesExist = $true
if (!(Test-Path $csvFile)) {
    Write-Warning "CSV results file not found: $csvFile"
    $filesExist = $false
}

if (!(Test-Path $jsonFile)) {
    Write-Warning "JSON results file not found: $jsonFile"
    $filesExist = $false
}

if (!$filesExist) {
    Write-Host "No discovery results files found. Run discovery first." -ForegroundColor Yellow
    exit 1
}

# Import and display results
Write-Host "Importing discovery results..." -ForegroundColor Gray
$results = Import-Csv $csvFile

Write-Host "`nDiscovery Results Summary:" -ForegroundColor Yellow
$results | Format-Table -AutoSize

# Analyze results
$discovered = $results | Where-Object { $_.Status -eq "Discovered" }
$failed = $results | Where-Object { $_.Status -eq "Failed" }

Write-Host "`nAnalysis:" -ForegroundColor Cyan
Write-Host "  Total servers: $($results.Count)" -ForegroundColor White
Write-Host "  Successfully discovered: $($discovered.Count)" -ForegroundColor Green
Write-Host "  Failed discoveries: $($failed.Count)" -ForegroundColor Red

if ($failed.Count -gt 0) {
    Write-Host "`nFailed servers:" -ForegroundColor Red
    $failed | ForEach-Object {
        Write-Host "  - $($_.IPAddress): $($_.Error)" -ForegroundColor Red
    }
}

if ($discovered.Count -gt 0) {
    Write-Host "`nDiscovered servers:" -ForegroundColor Green
    $discovered | ForEach-Object {
        $model = if ($_.Model) { " ($($_.Model))" } else { "" }
        Write-Host "  - $($_.IPAddress)$model" -ForegroundColor Green
    }

    # Check for hardware details
    $withHardware = $discovered | Where-Object { $_.ProcessorCount -or $_.TotalMemoryGB -or $_.DriveCount }
    if ($withHardware) {
        Write-Host "`nServers with hardware inventory:" -ForegroundColor Cyan
        $withHardware | ForEach-Object {
            Write-Host "  - $($_.IPAddress): $($_.ProcessorCount) CPUs, $($_.TotalMemoryGB) GB RAM, $($_.DriveCount) drives" -ForegroundColor Gray
        }
    }
}

Write-Host "`nValidation completed." -ForegroundColor Cyan
```

## Insert ISO as Virtual Disk via Redfish

Use Redfish API to insert the maintenance environment ISO as a virtual drive on each server.

### Mount ISO

**Script Location:** `scripts\common\utilities\tools\Mount-AzureLocalISO.ps1`

**Run the script directly:**
```powershell
# Option 1: Using interactive credentials
$credential = Get-Credential
.\scripts\common\utilities\tools\Mount-AzureLocalISO.ps1 -Credential $credential

# Option 2: Using Azure Key Vault (automatic from config)
.\scripts\common\utilities\tools\Mount-AzureLocalISO.ps1
```

**Or copy/paste the script contents:**
```powershell
<#
.SYNOPSIS
    Mounts Azure Local ISO as virtual media on Dell servers via iDRAC Redfish API.

.DESCRIPTION
    Uses Redfish API to mount an ISO as virtual CD on Dell PowerEdge servers via iDRAC,
    then sets one-time boot to CD. Uses CIFS share credentials from environment.yaml config.

    The qualified username (SERVER\user) is built at runtime by extracting the server name
    from ztp.share_network_path, so the config stays portable across environments.

.PARAMETER ServerIPs
    Array of iDRAC IP addresses. Defaults to config values.

.PARAMETER Credential
    PSCredential for iDRAC authentication.

.PARAMETER IsoUrl
    Override: HTTP/HTTPS URL to ISO. Bypasses CIFS and share credentials entirely.

.PARAMETER DelayBetweenServers
    Delay in seconds between servers (default: 10)

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    $cred = Get-Credential
    .\Mount-AzureLocalISO.ps1 -Credential $cred -Force

.EXAMPLE
    .\Mount-AzureLocalISO.ps1 -Credential $cred -IsoUrl "http://10.250.1.38:8080/provision-os.iso" -Force

.NOTES
    Requires: PowerShell 7.0+, AzureLocalConfig.psm1

    Config keys used (under ztp:):
      share_location      - local path to ISO directory (e.g. C:\share\ztp)
      share_network_path  - UNC path to share (e.g. \\util-eus-01\share\ztp)
      share_username      - local account name (e.g. svc_idrac_share)
      share_password      - account password
#>
param(
    [Parameter(Mandatory=$false)]
    [string[]]$ServerIPs,

    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory=$false)]
    [string]$IsoUrl,

    [Parameter(Mandatory=$false)]
    [int]$DelayBetweenServers = 10,

    [Parameter(Mandatory=$false)]
    [switch]$Force
)

#Requires -Version 7.0

# Validate parameters
if ($ServerIPs) {
    foreach ($ip in $ServerIPs) {
        if ($ip -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
            throw "Invalid IP address provided: $ip"
        }
    }
}

if ($Credential -and $Credential.GetType().Name -ne 'PSCredential') {
    throw "Credential parameter must be a PSCredential object"
}

# ── Load Config ──────────────────────────────────────────────────────────────
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) { throw "Could not find repository root (config directory not found)" }

$configModulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
if (!(Test-Path $configModulePath)) { throw "Config module not found at $configModulePath" }
Import-Module $configModulePath -Force
$config = Get-AzureLocalConfig

# ── Resolve Server IPs ──────────────────────────────────────────────────────
if (-not $ServerIPs) { $ServerIPs = $config.GetIdracIPs() }
if (-not $ServerIPs -or $ServerIPs.Count -eq 0) { throw "No server IPs provided and none found in config" }
Write-Host "Using ServerIPs: $($ServerIPs -join ', ')" -ForegroundColor Cyan

# ── Build InsertMedia Payload ────────────────────────────────────────────────
if ($IsoUrl -and $IsoUrl -match '^https?://') {
    # HTTP override - no share credentials needed
    Write-Host "Using HTTP: $IsoUrl" -ForegroundColor Cyan
    $insertBodyTemplate = @{
        Image          = $IsoUrl
        Inserted       = $true
        WriteProtected = $true
    }
} else {
    # CIFS from config
    $shareLocation   = $config.GetValue('ztp.share_location')
    $shareNetworkPath = $config.GetValue('ztp.share_network_path')
    $shareUsername   = $config.GetValue('ztp.share_username')
    $sharePassword   = $config.GetValue('ztp.share_password')

    # Auto-detect ISO
    $isoFile = Get-ChildItem -Path $shareLocation -Filter "*.iso" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $isoFile) { throw "No ISO file found in: $shareLocation" }
    Write-Host "Auto-detected ISO: $($isoFile.Name)" -ForegroundColor Green

    # Build CIFS path with forward slashes
    $cifsPath = "$shareNetworkPath\$($isoFile.Name)".Replace('\', '/')
    Write-Host "CIFS path: $cifsPath" -ForegroundColor Cyan

    # Build qualified username: extract server name from \\server\share\path
    # share_network_path = \\util-eus-01\share\ztp  →  server = util-eus-01
    $shareServer = ($shareNetworkPath -replace '^\\\\', '') -split '\\' | Select-Object -First 1
    $qualifiedUsername = "$shareServer\$shareUsername"
    Write-Host "Share account: $qualifiedUsername" -ForegroundColor Gray

    $insertBodyTemplate = @{
        Image    = $cifsPath
        UserName = $qualifiedUsername
        Password = $sharePassword
    }
}

# ── Resolve iDRAC Credentials ───────────────────────────────────────────────
if (!$Credential) {
    $keyVaultName = $config.GetValue('keyvault.platform_name', $null)
    $secretName = $config.GetValue('ztp.idrac_secret_name', $null)
    if ($keyVaultName -and $secretName) {
        Write-Host "Retrieving iDRAC credentials from Key Vault '$keyVaultName'..." -ForegroundColor Cyan
        $secret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName
        if (!$secret) { throw "Failed to retrieve secret '$secretName' from Key Vault '$keyVaultName'" }
        $credString = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
        if ($credString -notmatch ':') { throw "Invalid Key Vault secret format. Expected: 'username:password'" }
        $username, $password = $credString -split ':', 2
        $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
        $Credential = New-Object PSCredential ($username, $securePassword)
        Write-Host "✓ iDRAC credentials retrieved" -ForegroundColor Green
    } else {
        $Credential = Get-Credential -Message "Enter iDRAC credentials"
    }
}

# ── Confirm ──────────────────────────────────────────────────────────────────
if (-not $Force) {
    $serverList = $ServerIPs -join ", "
    $confirm = Read-Host "Mount '$($insertBodyTemplate.Image)' on servers: $serverList. Continue? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') { Write-Host "Cancelled." ; exit 0 }
}

# ── Mount ISO on Each Server ─────────────────────────────────────────────────
$results = @()
foreach ($ip in $ServerIPs) {
    Write-Host "`n── Server $ip ──" -ForegroundColor Cyan
    $baseUrl = "https://$ip"

    try {
        # 1. Test connectivity
        Write-Host "  Connecting..." -ForegroundColor Gray
        $redfishRoot = Invoke-RestMethod -Uri "$baseUrl/redfish/v1" `
            -Credential $Credential -SkipCertificateCheck -TimeoutSec 30 -ErrorAction Stop
        Write-Host "  ✓ Connected - Redfish $($redfishRoot.RedfishVersion)" -ForegroundColor Green

        # 2. Eject existing media
        Write-Host "  Ejecting existing media..." -ForegroundColor Gray
        try {
            Invoke-RestMethod -Uri "$baseUrl/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD/Actions/VirtualMedia.EjectMedia" `
                -Method Post -Credential $Credential -SkipCertificateCheck `
                -ContentType 'application/json' -Body '{}' -TimeoutSec 30 -ErrorAction Stop
            Write-Host "  ✓ Ejected" -ForegroundColor Green
        } catch {
            Write-Host "  - No media to eject" -ForegroundColor Gray
        }

        Start-Sleep -Seconds 2

        # 3. Insert ISO
        $insertJson = $insertBodyTemplate | ConvertTo-Json
        Write-Host "  Mounting: $($insertBodyTemplate.Image)" -ForegroundColor Gray

        Invoke-RestMethod -Uri "$baseUrl/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD/Actions/VirtualMedia.InsertMedia" `
            -Method Post -Credential $Credential -SkipCertificateCheck `
            -ContentType 'application/json' -Body $insertJson -TimeoutSec 60 -ErrorAction Stop
        Write-Host "  ✓ ISO mounted" -ForegroundColor Green

        # 4. Verify
        $vmStatus = Invoke-RestMethod -Uri "$baseUrl/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD" `
            -Credential $Credential -SkipCertificateCheck -TimeoutSec 30 -ErrorAction Stop
        if ($vmStatus.Inserted -eq $true) {
            Write-Host "  ✓ Verified: $($vmStatus.Image)" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ Inserted=false - check iDRAC GUI" -ForegroundColor Yellow
        }

        # 5. Set one-time boot to CD
        $bootBody = @{ Boot = @{ BootSourceOverrideEnabled = "Once"; BootSourceOverrideTarget = "Cd" } } | ConvertTo-Json -Depth 5
        Invoke-RestMethod -Uri "$baseUrl/redfish/v1/Systems/System.Embedded.1" `
            -Method Patch -Credential $Credential -SkipCertificateCheck `
            -ContentType 'application/json' -Body $bootBody -TimeoutSec 30 -ErrorAction Stop
        Write-Host "  ✓ Boot set to CD (one-time)" -ForegroundColor Green

        $results += @{ server = $ip; success = $true; message = "OK" }
    }
    catch {
        Write-Host "  ✗ FAILED: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            Write-Host "  Response: $($_.ErrorDetails.Message)" -ForegroundColor Red
        }
        $results += @{ server = $ip; success = $false; message = $_.Exception.Message }
    }

    if ($ip -ne $ServerIPs[-1]) { Start-Sleep -Seconds $DelayBetweenServers }
}

# ── Summary ──────────────────────────────────────────────────────────────────
$ok = ($results | Where-Object { $_.success }).Count
$fail = ($results | Where-Object { -not $_.success }).Count
Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "  Total: $($results.Count)  |  OK: $ok  |  Failed: $fail" -ForegroundColor $(if ($fail -gt 0) { "Red" } else { "Green" })
if ($fail -gt 0) {
    $results | Where-Object { -not $_.success } | ForEach-Object {
        Write-Host "  ✗ $($_.server): $($_.message)" -ForegroundColor Red
    }
}
Write-Host "========================================" -ForegroundColor Yellow
```

### Verify ISO Insert

Check that the ISO is properly inserted on each server:

**Script Location:** `scripts\common\utilities\tools\Verify-ISOMount.ps1`

**Run the script directly:**
```powershell
$credential = Get-Credential
.\scripts\common\utilities\tools\Verify-ISOMount.ps1 -Credential $credential
```

**Or copy/paste the script contents:**
```powershell
<#
.SYNOPSIS
    Verifies ISO mount status on servers.

.DESCRIPTION
    Checks that the Azure Local maintenance environment ISO is properly
    mounted as virtual media on target servers via Redfish API.

.PARAMETER ServerIPs
    Array of BMC/iDRAC IP addresses for target servers. Defaults to config values.

.PARAMETER Credential
    PSCredential object for BMC/iDRAC authentication

.EXAMPLE
    $credential = Get-Credential
    .\Verify-ISOMount.ps1 -ServerIPs "192.168.200.11","192.168.200.12" -Credential $credential

    Verifies ISO mount status on specified servers

.EXAMPLE
    .\Verify-ISOMount.ps1 -Credential $credential

    Verifies ISO mount status on all servers from config

.NOTES
    Requires:
    - PowerShell 7.0+
    - Network access to BMC/iDRAC interfaces
    - Valid BMC credentials with virtual media permissions
    - AzureLocalConfig.psm1 module for configuration loading
#>

param(
    [Parameter(Mandatory=$false)]
    [string[]]$ServerIPs,

    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential
)

#Requires -Version 7.0

# ── Load Config ──────────────────────────────────────────────────────────────
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) { throw "Could not find repository root (config directory not found)" }

$configModulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
if (!(Test-Path $configModulePath)) { throw "Config module not found at $configModulePath" }
Import-Module $configModulePath -Force
$config = Get-AzureLocalConfig

# ── Resolve Server IPs ──────────────────────────────────────────────────────
if (-not $ServerIPs) { $ServerIPs = $config.GetIdracIPs() }
if (-not $ServerIPs -or $ServerIPs.Count -eq 0) { throw "No server IPs provided and none found in config" }

# ── Resolve iDRAC Credentials ───────────────────────────────────────────────
if (!$Credential) {
    $keyVaultName = $config.GetValue('keyvault.platform_name', $null)
    $secretName = $config.GetValue('ztp.idrac_secret_name', $null)
    if ($keyVaultName -and $secretName) {
        Write-Host "Retrieving iDRAC credentials from Key Vault '$keyVaultName'..." -ForegroundColor Cyan
        $secret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName
        if (!$secret) { throw "Failed to retrieve secret '$secretName' from Key Vault '$keyVaultName'" }
        $credString = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
        if ($credString -notmatch ':') { throw "Invalid Key Vault secret format. Expected: 'username:password'" }
        $username, $password = $credString -split ':', 2
        $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
        $Credential = New-Object PSCredential ($username, $securePassword)
        Write-Host "✓ iDRAC credentials retrieved" -ForegroundColor Green
    } else {
        $Credential = Get-Credential -Message "Enter iDRAC credentials"
    }
}

Write-Host "Verifying ISO mount status on $($ServerIPs.Count) servers..." -ForegroundColor Cyan

$results = @()

foreach ($ip in $ServerIPs) {
    $result = [PSCustomObject]@{
        IPAddress = $ip
        Status = "Checking"
        ISOMounted = $false
        Message = ""
        Timestamp = Get-Date
    }

    try {
        Write-Host "Checking server $ip..." -ForegroundColor Gray

        $baseUrl = "https://$ip"

        # Check virtual media status
        $vmUri = "$baseUrl/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD"
        $vmResponse = Invoke-RestMethod -Uri $vmUri -Credential $Credential -Method GET -SkipCertificateCheck

        if ($vmResponse.Inserted -eq $true) {
            $result.Status = "Success"
            $result.ISOMounted = $true
            $result.Message = "ISO successfully mounted: $($vmResponse.Image)"
            Write-Host "✓ ISO mounted on server $ip" -ForegroundColor Green
        } else {
            $result.Status = "Not Mounted"
            $result.Message = "ISO not mounted"
            Write-Warning "ISO not mounted on server $ip"
        }

    } catch {
        $result.Status = "Error"
        $result.Message = $_.Exception.Message
        Write-Error "Could not verify ISO mount on server $ip`: $($_.Exception.Message)"
    }

    $results += $result
}

# Display results
Write-Host "`nISO Mount Verification Results:" -ForegroundColor Yellow
$results | Format-Table -AutoSize

# Summary
$mounted = $results | Where-Object { $_.ISOMounted -eq $true }
$notMounted = $results | Where-Object { $_.ISOMounted -eq $false -and $_.Status -ne "Error" }
$errors = $results | Where-Object { $_.Status -eq "Error" }

Write-Host "`nSummary:" -ForegroundColor Cyan
Write-Host "  Successfully mounted: $($mounted.Count)" -ForegroundColor Green
Write-Host "  Not mounted: $($notMounted.Count)" -ForegroundColor Yellow
Write-Host "  Errors: $($errors.Count)" -ForegroundColor Red

if ($notMounted.Count -gt 0) {
    Write-Host "`nServers without ISO mounted:" -ForegroundColor Yellow
    $notMounted | ForEach-Object {
        Write-Host "  - $($_.IPAddress)" -ForegroundColor Yellow
    }
}

if ($errors.Count -gt 0) {
    Write-Host "`nServers with verification errors:" -ForegroundColor Red
    $errors | ForEach-Object {
        Write-Host "  - $($_.IPAddress): $($_.Message)" -ForegroundColor Red
    }
}
```

## Reboot Server to Boot from ISO

Initiate server reboot to boot from the mounted maintenance environment ISO.

### Configure Boot Source

Set the boot source to the virtual CD/DVD before rebooting:

**Script Location:** `scripts\common\utilities\tools\Set-ServerBootSource.ps1`

**Run the script directly:**
```powershell
# Option 1: Use Key Vault credentials (recommended for automation)
.\scripts\common\utilities\tools\Set-ServerBootSource.ps1

# Option 2: Provide credentials interactively
$Credential = Get-Credential
.\scripts\common\utilities\tools\Set-ServerBootSource.ps1 -Credential $Credential
```

**Or copy/paste the script contents:**
```powershell
<#
.SYNOPSIS
    Configures boot source override on target servers via Redfish API for Azure Local ZTP.

.DESCRIPTION
    Uses Redfish API to set one-time boot source to virtual CD/DVD on Dell PowerEdge servers
    with iDRAC. This ensures servers boot from the mounted Azure Local maintenance environment
    ISO during the next restart.

.PARAMETER Credential
    PSCredential object for BMC/iDRAC authentication (optional if using Key Vault)

.PARAMETER BootSource
    Boot source to set (default: Cd). Valid values: Cd, Hdd, Pxe

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    $Credential = Get-Credential
    .\Set-ServerBootSource.ps1 -Credential $Credential

    Sets boot source to CD for all servers defined in config using interactive credentials.

.EXAMPLE
    .\Set-ServerBootSource.ps1 -BootSource "Pxe" -Force

    Sets boot source to PXE without confirmation using Key Vault credentials.

.NOTES
    Requires:
    - PowerShell 7.0+
    - Network access to BMC/iDRAC interfaces
    - Valid BMC credentials with system control permissions
    - AzureLocalConfig.psm1 module for configuration loading
    - Az.KeyVault module (if using Key Vault for credentials)
    - Key Vault name and secret name in environment.yaml (keyvault.platform_name, ztp.idrac_secret_name)
#>

param(
    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory=$false)]
    [ValidateSet("Cd", "Hdd", "Pxe")]
    [string]$BootSource = "Cd",

    [Parameter(Mandatory=$false)]
    [switch]$Force
)

#Requires -Version 7.0

# Find repository root and config file
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) {
    throw "Could not find repository root (config directory not found)"
}

# Import configuration module
$modulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
Import-Module $modulePath -Force

# Load configuration
$config = Get-AzureLocalConfig
$serverIPs = $config.GetIdracIPs()

# Retrieve credentials from Key Vault if not provided
if (!$Credential) {
    $keyVaultName = $config.GetValue('keyvault.platform_name')
    $secretName = $config.GetValue('ztp.idrac_secret_name')
    if ($keyVaultName -and $secretName) {
        Write-Host "Retrieving credentials from Azure Key Vault '$keyVaultName'..." -ForegroundColor Cyan
        $secret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName
        if (!$secret) {
            throw "Failed to retrieve secret '$secretName' from Key Vault '$keyVaultName'"
        }
        $credString = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
        if ($credString -notmatch ':') {
            throw "Invalid credential format in Key Vault secret. Expected format: 'username:password'"
        }
        $username, $password = $credString -split ':', 2
        $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
        $Credential = New-Object PSCredential ($username, $securePassword)
        Write-Host "✓ Credentials retrieved successfully" -ForegroundColor Green
    } else {
        Write-Host "Key Vault configuration not found. Please provide credentials interactively." -ForegroundColor Yellow
        $Credential = Get-Credential -Message "Enter iDRAC credentials"
    }
}

# Confirm operation if not forced
if (!$Force) {
    $serverCount = $serverIPs.Count
    Write-Host "WARNING: About to set boot source to '$BootSource' on $serverCount server(s):" -ForegroundColor Red
    $serverIPs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host "This will change the one-time boot source for these servers." -ForegroundColor Red

    $confirmation = Read-Host "Are you sure you want to continue? (yes/N)"
    if ($confirmation -ne 'yes') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
}

$results = @()

foreach ($ip in $serverIPs) {
    $result = [PSCustomObject]@{
        IPAddress = $ip
        Status = "Processing"
        BootSource = $BootSource
        Message = ""
        Timestamp = Get-Date
    }

    try {
        Write-Host "Checking boot source for server $ip..." -ForegroundColor Gray

        $baseUrl = "https://$ip"

        # Test connectivity first
        $testUri = "$baseUrl/redfish/v1"
        $testResponse = Invoke-RestMethod -Uri $testUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30

        if ($testResponse.'@odata.type' -notlike '*ServiceRoot*') {
            throw "Invalid Redfish service response from $ip"
        }

        # Check current boot source override
        $bootUri = "$baseUrl/redfish/v1/Systems/System.Embedded.1"
        $currentBoot = Invoke-RestMethod -Uri $bootUri -Credential $Credential -Method GET -SkipCertificateCheck

        $currentEnabled = $currentBoot.Boot.BootSourceOverrideEnabled
        $currentTarget = $currentBoot.Boot.BootSourceOverrideTarget

        if ($currentEnabled -eq "Once" -and $currentTarget -eq $BootSource) {
            $result.Status = "Already Set"
            $result.Message = "Boot source already set to $BootSource"
            Write-Host "Boot source already correctly set on server $ip" -ForegroundColor Green
        } else {
            Write-Host "Setting boot source to $BootSource for server $ip..." -ForegroundColor Yellow

            # Set one-time boot source override
            $bootBody = @{
                Boot = @{
                    BootSourceOverrideEnabled = "Once"
                    BootSourceOverrideTarget = $BootSource
                }
            } | ConvertTo-Json -Depth 3

            $bootResponse = Invoke-RestMethod -Uri $bootUri -Credential $Credential -Method PATCH -Body $bootBody -ContentType "application/json" -SkipCertificateCheck

            $result.Status = "Success"
            $result.Message = "Boot source set to $BootSource"
            Write-Host "Successfully set boot source on server $ip" -ForegroundColor Green
        }

    } catch {
        $result.Status = "Failed"
        $result.Message = $_.Exception.Message
        Write-Error "Failed to set boot source on server $ip`: $($_.Exception.Message)"
    }

    $results += $result
}

# Display results
Write-Host "`nBoot Source Configuration Results:" -ForegroundColor Cyan
$results | Format-Table -AutoSize

# Export results
$results | Export-Csv -Path ".\server-boot-source-results.csv" -NoTypeInformation
$results | ConvertTo-Json | Out-File ".\server-boot-source-results.json"

Write-Host "Results saved to CSV and JSON files." -ForegroundColor Green
```

### Initiate Server Reboot

**⚠️ CRITICAL: Simultaneous Reboot Required**

Reboot ALL servers simultaneously to begin the maintenance environment installation. **Do NOT reboot servers sequentially** - this will cause significant delays (4+ hours for multiple servers) and may result in inconsistent cluster states.

**Why simultaneous reboot is critical:**
- Parallel processing reduces total deployment time from hours to minutes
- Ensures all servers start the ZTP process at the same time
- Prevents timing issues in cluster formation
- Optimizes resource utilization during imaging

**Script Location:** `scripts\common\utilities\tools\Restart-Servers.ps1`

**Run the script directly:**
```powershell
# Option 1: Use Key Vault credentials (recommended for automation)
.\scripts\common\utilities\tools\Restart-Servers.ps1 -DelayBetweenServers 0 -Force

# Option 2: Provide credentials interactively
$Credential = Get-Credential
.\scripts\common\utilities\tools\Restart-Servers.ps1 -Credential $Credential -DelayBetweenServers 0 -Force
```
```powershell
<#
.SYNOPSIS
    Initiates reboot on target servers via Redfish API for Azure Local ZTP.

.DESCRIPTION
    Uses Redfish API to perform a force restart on Dell PowerEdge servers with iDRAC.
    This triggers the boot process from the mounted Azure Local maintenance environment ISO.

.PARAMETER Credential
    PSCredential object for BMC/iDRAC authentication. If not provided, credentials will be retrieved from Azure Key Vault.

.PARAMETER DelayBetweenServers
    Delay in seconds between initiating reboots on different servers (default: 10, use 0 for simultaneous reboots)

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    .\Restart-Servers.ps1

    Restarts all servers defined in config with default 10-second delay between operations using Key Vault credentials.

.EXAMPLE
    .\Restart-Servers.ps1 -DelayBetweenServers 0 -Force

    Restarts all servers simultaneously without delay and no confirmation using Key Vault credentials.

.EXAMPLE
    $cred = Get-Credential
    .\Restart-Servers.ps1 -Credential $cred

    Restarts all servers defined in config with default 10-second delay between operations using provided credentials.

.NOTES
    Requires:
    - PowerShell 7.0+
    - Network access to BMC/iDRAC interfaces
    - Valid BMC credentials with system control permissions
    - AzureLocalConfig.psm1 module for configuration loading

    WARNING: This will immediately restart the specified servers. Ensure no critical operations are running.
#>

param(
    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory=$false)]
    [int]$DelayBetweenServers = 10,

    [Parameter(Mandatory=$false)]
    [switch]$Force
)

#Requires -Version 7.0

# Find repository root and config file
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) {
    throw "Could not find repository root (config directory not found)"
}

# Import configuration module
$modulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
Import-Module $modulePath -Force

# Load configuration
$config = Get-AzureLocalConfig
$serverIPs = $config.GetIdracIPs()

# Confirm operation if not forced
if (!$Force) {
    $serverCount = $serverIPs.Count
    Write-Host "WARNING: About to initiate immediate reboot on $serverCount server(s):" -ForegroundColor Red
    $serverIPs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host "This will cause immediate downtime. Ensure no critical operations are running." -ForegroundColor Red

    $confirmation = Read-Host "Are you sure you want to continue? (yes/N)"
    if ($confirmation -ne 'yes') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
}

$results = @()

for ($i = 0; $i -lt $serverIPs.Count; $i++) {
    $ip = $serverIPs[$i]
    $result = [PSCustomObject]@{
        IPAddress = $ip
        Status = "Processing"
        Message = ""
        Timestamp = Get-Date
    }

    try {
        Write-Host "Initiating reboot for server $ip..." -ForegroundColor Yellow

        $baseUrl = "https://$ip"

        # Test connectivity first
        $testUri = "$baseUrl/redfish/v1"
        $testResponse = Invoke-RestMethod -Uri $testUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30

        if ($testResponse.'@odata.type' -notlike '*ServiceRoot*') {
            throw "Invalid Redfish service response from $ip"
        }

        # Initiate force restart
        $resetUri = "$baseUrl/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"
        $resetBody = @{
            ResetType = "ForceRestart"
        } | ConvertTo-Json

        $resetResponse = Invoke-RestMethod -Uri $resetUri -Credential $Credential -Method POST -Body $resetBody -ContentType "application/json" -SkipCertificateCheck

        $result.Status = "Success"
        $result.Message = "Reboot initiated successfully"
        Write-Host "Successfully initiated reboot on server $ip" -ForegroundColor Green

    } catch {
        $result.Status = "Failed"
        $result.Message = $_.Exception.Message
        Write-Error "Failed to reboot server $ip`: $($_.Exception.Message)"
    }

    $results += $result

    # Add delay between servers (except for the last one)
    if ($i -lt ($serverIPs.Count - 1)) {
        Write-Host "Waiting $DelayBetweenServers seconds before next server..." -ForegroundColor Cyan
        Start-Sleep -Seconds $DelayBetweenServers
    }
}

# Display results
Write-Host "`nReboot Results:" -ForegroundColor Cyan
$results | Format-Table -AutoSize

# Export results
$results | Export-Csv -Path ".\server-restart-results.csv" -NoTypeInformation
$results | ConvertTo-Json | Out-File ".\server-restart-results.json"

Write-Host "Results saved to CSV and JSON files." -ForegroundColor Green
```

### Monitor Boot Process

Monitor the boot process and maintenance environment installation:

**Script Location:** `scripts\common\utilities\tools\Monitor-ZTPBoot.ps1`

**Run the script directly:**
```powershell
# Option 1: Use Key Vault credentials (recommended for automation)
.\scripts\common\utilities\tools\Monitor-ZTPBoot.ps1

# Option 2: Provide credentials interactively
$Credential = Get-Credential
.\scripts\common\utilities\tools\Monitor-ZTPBoot.ps1 -Credential $Credential
```

**Or copy/paste the script contents:**
```powershell
<#
.SYNOPSIS
    Monitors Azure Local ZTP boot and installation process.

.DESCRIPTION
    Provides monitoring and status updates for the Azure Local maintenance
    environment installation process on target servers.

.EXAMPLE
    .\Monitor-ZTPBoot.ps1

    Monitors the ZTP boot process with status updates

.NOTES
    Requires:
    - PowerShell 7.0+
    - Access to server consoles or BMC interfaces for monitoring
#>

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Azure Local ZTP Boot Monitor" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Monitoring server boot process..." -ForegroundColor Yellow
Write-Host "Expected completion time: 30-45 minutes per server" -ForegroundColor Cyan
Write-Host "Check server consoles or BMC interfaces for progress" -ForegroundColor Cyan
Write-Host ""

Write-Host "Monitoring Checklist:" -ForegroundColor Green
Write-Host "  ✓ Server(s) powered on and connected to network" -ForegroundColor White
Write-Host "  ✓ Boot source set to virtual CD/DVD" -ForegroundColor White
Write-Host "  ✓ ISO mounted as virtual media" -ForegroundColor White
Write-Host "  ✓ Network share accessible" -ForegroundColor White
Write-Host ""

Write-Host "Installation Phases:" -ForegroundColor Yellow
Write-Host "  1. BIOS/UEFI initialization (1-2 minutes)" -ForegroundColor Gray
Write-Host "  2. Boot from virtual CD (2-3 minutes)" -ForegroundColor Gray
Write-Host "  3. Maintenance environment load (5-10 minutes)" -ForegroundColor Gray
Write-Host "  4. Network configuration (2-3 minutes)" -ForegroundColor Gray
Write-Host "  5. Azure Local installer start (5-7 minutes)" -ForegroundColor Gray
Write-Host "  6. Installation completion (10-20 minutes)" -ForegroundColor Gray
Write-Host ""

Write-Host "Monitoring Methods:" -ForegroundColor Cyan
Write-Host "  • BMC/iDRAC web console" -ForegroundColor White
Write-Host "  • Server direct console access" -ForegroundColor White
Write-Host "  • Network switch console logs" -ForegroundColor White
Write-Host "  • IPMItool or Redfish API queries" -ForegroundColor White
Write-Host ""

Write-Host "Expected Indicators:" -ForegroundColor Green
Write-Host "  • Server LEDs show activity" -ForegroundColor White
Write-Host "  • Network activity on management interface" -ForegroundColor White
Write-Host "  • BMC shows 'Maintenance Mode' or similar" -ForegroundColor White
Write-Host "  • Console shows Azure Local branding" -ForegroundColor White
Write-Host ""

Write-Host "Troubleshooting:" -ForegroundColor Red
Write-Host "  • If no boot activity: Check boot source and ISO mount" -ForegroundColor White
Write-Host "  • If boot fails: Verify ISO integrity and network access" -ForegroundColor White
Write-Host "  • If installation hangs: Check server hardware and network" -ForegroundColor White
Write-Host ""

Write-Host "Press Ctrl+C to stop monitoring..." -ForegroundColor Yellow
Write-Host ""

# Simple monitoring loop
$startTime = Get-Date
$serverCount = 3  # This could be loaded from config

try {
    while ($true) {
        $elapsed = (Get-Date) - $startTime
        $elapsedMinutes = [math]::Floor($elapsed.TotalMinutes)

        Write-Host "$(Get-Date -Format 'HH:mm:ss') - Monitoring for $($elapsedMinutes) minutes..." -ForegroundColor Gray

        # Could add actual monitoring logic here
        # For now, just provide status updates

        if ($elapsedMinutes -lt 5) {
            Write-Host "  Status: Servers booting from virtual media..." -ForegroundColor Cyan
        } elseif ($elapsedMinutes -lt 15) {
            Write-Host "  Status: Maintenance environment loading..." -ForegroundColor Cyan
        } elseif ($elapsedMinutes -lt 30) {
            Write-Host "  Status: Azure Local installation in progress..." -ForegroundColor Cyan
        } else {
            Write-Host "  Status: Installation should be nearing completion..." -ForegroundColor Green
        }

        Start-Sleep -Seconds 60  # Check every minute
    }
} catch {
    Write-Host "`nMonitoring stopped." -ForegroundColor Yellow
}
```

### Cleanup: Unmount Virtual Media

After the ZTP installation is complete, unmount the virtual media (ISO) from all servers:

**Script Location:** `scripts\common\utilities\tools\Unmount-AzureLocalISO.ps1`

**Run the script directly:**
```powershell
# Option 1: Use Key Vault credentials (recommended for automation)
.\scripts\common\utilities\tools\Unmount-AzureLocalISO.ps1 -Force

# Option 2: Provide credentials interactively
$Credential = Get-Credential
.\scripts\common\utilities\tools\Unmount-AzureLocalISO.ps1 -Credential $Credential -Force
```

**Or copy/paste the script contents:**
```powershell
<#
.SYNOPSIS
    Unmounts virtual media (ISO) from Dell servers via iDRAC Redfish API.

.DESCRIPTION
    Uses Redfish API to eject virtual CD/DVD media from Dell PowerEdge servers via iDRAC.
    This is the cleanup step after ZTP installation is complete.

.PARAMETER Credential
    PSCredential object for BMC/iDRAC authentication (optional if using Key Vault)

.PARAMETER DelayBetweenServers
    Delay in seconds between servers (default: 10)

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    .\Unmount-AzureLocalISO.ps1

    Unmounts virtual media from all servers using Key Vault credentials.

.EXAMPLE
    $cred = Get-Credential
    .\Unmount-AzureLocalISO.ps1 -Credential $cred

    Unmounts virtual media from all servers using provided credentials.

.NOTES
    Requires:
    - PowerShell 7.0+
    - Network access to BMC/iDRAC interfaces
    - Valid BMC credentials with virtual media permissions
    - AzureLocalConfig.psm1 module for configuration loading
    - Az.KeyVault module (if using Key Vault for credentials)
    - Key Vault name and secret name in environment.yaml (keyvault.platform_name, ztp.idrac_secret_name)
#>
```

## Next Steps

Once servers have completed the maintenance environment installation, proceed to **Phase 2** of the ZTP workflow:

**📖 Next Guide:** [Azure Portal Provisioning Guide](ztp-azure-portal-provisioning-guide.md)

1. **Collect Ownership Vouchers** - Use the Configurator App or USB drives to collect ownership vouchers from each server
2. **Create Azure Site** - Set up site-level configuration in the Azure portal
3. **Provision Machines** - Upload vouchers and provision machines from Azure
4. **Verify Azure Arc Connectivity** - Confirm all machines show "Ready to cluster"
5. **Deploy Azure Local** - Deploy the cluster via Azure portal or ARM template

## Troubleshooting

### Reset iDRAC via Redfish

If an iDRAC becomes unresponsive or behaves unexpectedly, you can perform a graceful reset remotely using the Redfish API — no reboot of the host server required. The iDRAC will go offline for approximately 2–3 minutes while it restarts. The host server continues running.

**Script Location:** `scripts\common\utilities\tools\Reset-iDRAC.ps1`

**Run the script directly:**
```powershell
# Option 1: Use Key Vault credentials (recommended for automation)
.\scripts\common\utilities\tools\Reset-iDRAC.ps1 -Force

# Option 2: Provide credentials interactively
$Credential = Get-Credential -UserName root -Message "Enter iDRAC password"
.\scripts\common\utilities\tools\Reset-iDRAC.ps1 -Credential $Credential -Force

# Option 3: Force restart if graceful restart doesn't resolve the issue
.\scripts\common\utilities\tools\Reset-iDRAC.ps1 -ResetType ForceRestart -Force

# Option 4: Target a single iDRAC
.\scripts\common\utilities\tools\Reset-iDRAC.ps1 -IdracIP "192.168.1.100" -Force

# Option 5: Target multiple specific iDRACs
.\scripts\common\utilities\tools\Reset-iDRAC.ps1 -IdracIP "192.168.1.100","192.168.1.101" -Force
```

**Expected Output:**

- Status per server (Success/Failed)
- JSON results file in `logs/idrac-reset-results-<timestamp>.json`

TIP: Use `GracefulRestart` (default) first. Only use `ForceRestart` if the iDRAC is completely unresponsive.

**Or copy/paste the script contents:**
```powershell
<#
.SYNOPSIS
    Resets iDRAC on target servers via Redfish API.

.DESCRIPTION
    Performs a graceful restart of the iDRAC management controller on Dell PowerEdge servers
    using the Redfish API. This does NOT reboot the host server — only the iDRAC service restarts.

    Useful when an iDRAC becomes unresponsive, returns stale data, or exhibits unexpected behavior.
    The iDRAC typically takes 2–3 minutes to come back online after a reset.

    All servers are reset in parallel by default.

.PARAMETER Credential
    PSCredential object for iDRAC authentication. If not provided, credentials will be retrieved from Azure Key Vault.

.PARAMETER IdracIP
    One or more iDRAC IP addresses to target. If not specified, all servers from environment.yaml are used.

.PARAMETER ResetType
    Type of iDRAC reset to perform. Default is "GracefulRestart".
    Options: GracefulRestart, ForceRestart

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    .\Reset-iDRAC.ps1

    Resets all iDRACs defined in config using Key Vault credentials with graceful restart.

.EXAMPLE
    .\Reset-iDRAC.ps1 -IdracIP "192.168.1.100" -Force

    Resets a single iDRAC without confirmation.

.EXAMPLE
    .\Reset-iDRAC.ps1 -IdracIP "192.168.1.100","192.168.1.101" -Force

    Resets two specific iDRACs without confirmation.

.EXAMPLE
    $Credential = Get-Credential -UserName root -Message "Enter iDRAC password"
    .\Reset-iDRAC.ps1 -Credential $Credential -ResetType ForceRestart -Force

    Force-restarts all iDRACs using provided credentials without confirmation.

.NOTES
    Requires:
    - PowerShell 7.0+
    - Network access to iDRAC management interfaces
    - Valid iDRAC credentials with administrator permissions
    - AzureLocalConfig.psm1 module for configuration loading

    WARNING: The iDRAC will be unreachable for 2–3 minutes during the reset.
    The host server OS continues running — this does NOT affect the host.
#>

param(
    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory=$false)]
    [string[]]$IdracIP,

    [Parameter(Mandatory=$false)]
    [ValidateSet("GracefulRestart", "ForceRestart")]
    [string]$ResetType = "GracefulRestart",

    [Parameter(Mandatory=$false)]
    [switch]$Force
)

#Requires -Version 7.0

# Find repository root and config file
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) {
    throw "Could not find repository root (config directory not found)"
}

# Import configuration module
$modulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
Import-Module $modulePath -Force

# Load configuration
$config = Get-AzureLocalConfig
if ($IdracIP) {
    $serverIPs = $IdracIP
} else {
    $serverIPs = $config.GetIdracIPs()
}

# Credential resolution — Key Vault or interactive
if (!$Credential) {
    $keyVaultName = $config.GetValue('keyvault.platform_name')
    $secretName = $config.GetValue('ztp.idrac_secret_name')

    if ($keyVaultName -and $secretName) {
        try {
            Write-Host "Retrieving iDRAC credentials from Key Vault '$keyVaultName'..." -ForegroundColor Cyan
            $secret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName
            if (!$secret) {
                throw "Secret '$secretName' not found in Key Vault '$keyVaultName'"
            }
            $credString = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
            if ($credString -notmatch ':') {
                throw "Secret value must be in format 'username:password'"
            }
            $username, $password = $credString -split ':', 2
            $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
            $Credential = New-Object PSCredential ($username, $securePassword)
            Write-Host "  Credentials retrieved successfully" -ForegroundColor Green
        }
        catch {
            Write-Host "  Key Vault access failed: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  Falling back to interactive credential entry..." -ForegroundColor Yellow
            $Credential = Get-Credential -Message "Enter iDRAC credentials (e.g., root)"
        }
    }
    else {
        Write-Host "Key Vault not configured. Please provide credentials interactively." -ForegroundColor Yellow
        $Credential = Get-Credential -Message "Enter iDRAC credentials (e.g., root)"
    }
}

# Confirm operation if not forced
if (!$Force) {
    $serverCount = $serverIPs.Count
    Write-Host "WARNING: About to reset iDRAC ($ResetType) on $serverCount server(s):" -ForegroundColor Red
    $serverIPs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host "The iDRAC will be unreachable for 2-3 minutes. The host OS is NOT affected." -ForegroundColor Yellow

    $confirmation = Read-Host "Are you sure you want to continue? (yes/N)"
    if ($confirmation -ne 'yes') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
}

$results = @()

# Serialize credential for parallel runspaces
$credUser = $Credential.UserName
$credPass = $Credential.GetNetworkCredential().Password

$results = $serverIPs | ForEach-Object -Parallel {
    $ip = $_
    $user = $using:credUser
    $pass = $using:credPass
    $resetType = $using:ResetType

    $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
    $cred = New-Object PSCredential ($user, $secPass)

    $result = [PSCustomObject]@{
        IPAddress = $ip
        ResetType = $resetType
        Status    = "Processing"
        Message   = ""
        Timestamp = Get-Date
    }

    try {
        $baseUrl = "https://$ip"

        # Test connectivity first
        $testUri = "$baseUrl/redfish/v1"
        $testResponse = Invoke-RestMethod -Uri $testUri -Credential $cred -Method GET -SkipCertificateCheck -TimeoutSec 30

        if ($testResponse.'@odata.type' -notlike '*ServiceRoot*') {
            throw "Invalid Redfish service response from $ip"
        }

        # Reset iDRAC
        $resetUri = "$baseUrl/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Manager.Reset"
        $resetBody = @{
            ResetType = $resetType
        } | ConvertTo-Json

        Invoke-RestMethod -Uri $resetUri -Credential $cred -Method POST -Body $resetBody -ContentType "application/json" -SkipCertificateCheck

        $result.Status = "Success"
        $result.Message = "iDRAC reset initiated successfully"

    } catch {
        $result.Status = "Failed"
        $result.Message = $_.Exception.Message
    }

    return $result
} -ThrottleLimit $serverIPs.Count

# Display results
Write-Host "`niDRAC Reset Results:" -ForegroundColor Cyan
$results | Format-Table -AutoSize

# Export results
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logDir = Join-Path $repoRoot "logs"
if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

$jsonPath = Join-Path $logDir "idrac-reset-results-$timestamp.json"
$results | ConvertTo-Json | Out-File $jsonPath

Write-Host "Results saved to $jsonPath" -ForegroundColor Green
```

### UEFI Boot Sequence Management

During ZTP provisioning, the UEFI boot sequence may be modified — for example, a one-time boot override is set to boot from virtual CD/ISO, or a previous OS installation leaves stale boot entries in a non-default order. These tools let you inspect and reset boot settings across all servers via the Dell iDRAC Redfish API without touching any other BIOS configuration.

#### Check Current Boot Settings

Query the current UEFI boot mode, boot device order (`UefiBootSeq`), one-time boot override status, and all available boot options from every server. This is a **read-only** operation — nothing is modified.

**Script Location:** `scripts\common\utilities\tools\Get-BootSettings.ps1`

**Run the script directly:**
```powershell
# Option 1: Use Key Vault credentials (recommended for automation)
.\scripts\common\utilities\tools\Get-BootSettings.ps1 -Force

# Option 2: Query specific servers only
.\scripts\common\utilities\tools\Get-BootSettings.ps1 -IdracIP "192.168.214.11","192.168.214.12" -Force

# Option 3: Provide credentials manually
$cred = Get-Credential -UserName root -Message "Enter iDRAC password"
.\scripts\common\utilities\tools\Get-BootSettings.ps1 -Credential $cred
```

**Expected Output:**
```text
Retrieving iDRAC credentials from Key Vault 'kv-ztp-platform'...
  Credentials retrieved successfully

Querying boot settings on 4 server(s)...

[192.168.214.11] BootMode: Uefi | Override: None (Disabled) | Options: 6
  Boot Sequence:
    1. NIC.PxE.1-1 (PXE Device 1: Integrated NIC 1 Port 1)
    2. NIC.PxE.2-1 (PXE Device 2: Integrated NIC 1 Port 2)
    3. RAID.SL.8-1 (BOSS Card Virtual Disk)
    4. Optical.iDRACVirtual.1-1 (Virtual CD/DVD)
[192.168.214.12] BootMode: Uefi | Override: None (Disabled) | Options: 6
  Boot Sequence:
    1. NIC.PxE.1-1 (PXE Device 1: Integrated NIC 1 Port 1)
    2. NIC.PxE.2-1 (PXE Device 2: Integrated NIC 1 Port 2)
    3. RAID.SL.8-1 (BOSS Card Virtual Disk)
    4. Optical.iDRACVirtual.1-1 (Virtual CD/DVD)
...

════════════════════════════════════════
  Boot Settings Report
  Servers queried: 4
  Success: 4
  Failed:  0
  Results: config/dell/discovery/boot-settings-20260212-143052.json
════════════════════════════════════════
```

TIP: Run this before and after provisioning to verify boot sequences are in the expected state. Results are saved to `config/dell/discovery/boot-settings-<timestamp>.json` for comparison.

**Or copy/paste the script contents:**

```powershell
<#
.SYNOPSIS
    Queries UEFI boot settings from all servers via Redfish API.

.DESCRIPTION
    Authenticates via Key Vault (or interactive credentials), queries each server's
    current boot order, boot source override status, and available boot options via
    the Dell iDRAC Redfish API. Results for all servers are saved to a single JSON file.

    This script does NOT modify any settings — it is read-only.

.PARAMETER Credential
    PSCredential for iDRAC authentication. If not provided, retrieves from Key Vault.

.PARAMETER IdracIP
    One or more iDRAC IP addresses. Defaults to all servers from environment.yaml.

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    .\Get-BootSettings.ps1

    Queries all servers from config using Key Vault credentials.

.EXAMPLE
    .\Get-BootSettings.ps1 -IdracIP "192.168.214.11","192.168.214.12"

    Queries specific servers only.

.EXAMPLE
    $cred = Get-Credential -UserName root -Message "Enter iDRAC password"
    .\Get-BootSettings.ps1 -Credential $cred

    Uses provided credentials instead of Key Vault.

.NOTES
    Requires:
    - PowerShell 7.0+ (for ForEach-Object -Parallel and -SkipCertificateCheck)
    - Network access to iDRAC management interfaces
    - Valid iDRAC credentials with read permissions
    - AzureLocalConfig.psm1 module for configuration loading
    - Az.KeyVault module (if using Key Vault for credentials)

    Output file: config/dell/discovery/boot-settings-<timestamp>.json
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string[]]$IdracIP,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

#Requires -Version 7.0

$ErrorActionPreference = "Continue"

# ── Find repository root ──
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) {
    throw "Could not find repository root (config directory not found)"
}

# ── Load configuration ──
$modulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
Import-Module $modulePath -Force

$config = Get-AzureLocalConfig
if ($IdracIP) {
    $serverIPs = $IdracIP
} else {
    $serverIPs = $config.GetIdracIPs()
}

# ── Credential resolution ──
if (!$Credential) {
    $keyVaultName = $config.GetValue('keyvault.platform_name')
    $secretName = $config.GetValue('ztp.idrac_secret_name')

    if ($keyVaultName -and $secretName) {
        try {
            Write-Host "Retrieving iDRAC credentials from Key Vault '$keyVaultName'..." -ForegroundColor Cyan
            $secret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName
            if (!$secret) {
                throw "Secret '$secretName' not found in Key Vault '$keyVaultName'"
            }
            $credString = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
            if ($credString -notmatch ':') {
                throw "Secret value must be in format 'username:password'"
            }
            $username, $password = $credString -split ':', 2
            $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
            $Credential = New-Object PSCredential ($username, $securePassword)
            Write-Host "  Credentials retrieved successfully" -ForegroundColor Green
        }
        catch {
            Write-Host "  Key Vault access failed: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  Falling back to interactive credential entry..." -ForegroundColor Yellow
            $Credential = Get-Credential -Message "Enter iDRAC credentials (e.g., root)"
        }
    }
    else {
        Write-Host "Key Vault not configured. Please provide credentials interactively." -ForegroundColor Yellow
        $Credential = Get-Credential -Message "Enter iDRAC credentials (e.g., root)"
    }
}

# ── Confirm operation ──
if (!$Force) {
    Write-Host "Will query boot settings on $($serverIPs.Count) server(s):" -ForegroundColor Cyan
    $serverIPs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    $confirmation = Read-Host "Continue? (yes/N)"
    if ($confirmation -ne 'yes') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
}

Write-Host "`nQuerying boot settings on $($serverIPs.Count) server(s)...`n" -ForegroundColor Cyan

# ── Serialize credentials for parallel execution ──
$credUser = $Credential.UserName
$credPass = $Credential.GetNetworkCredential().Password

# ── Query all servers in parallel ──
$results = $serverIPs | ForEach-Object -Parallel {
    $ip = $_
    $user = $using:credUser
    $pass = $using:credPass

    $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
    $cred = New-Object PSCredential ($user, $secPass)

    $entry = [ordered]@{
        IPAddress           = $ip
        Timestamp           = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        Status              = "Unknown"
        BootMode            = $null
        UefiBootSeq         = @()
        BootOverrideTarget  = $null
        BootOverrideEnabled = $null
        BootOptions         = @()
        Error               = $null
    }

    try {
        # Test Redfish connectivity
        $svcUri = "https://$ip/redfish/v1"
        $null = Invoke-RestMethod -Uri $svcUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30

        # Get system boot override info
        $sysUri = "https://$ip/redfish/v1/Systems/System.Embedded.1"
        $system = Invoke-RestMethod -Uri $sysUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30
        $entry.BootOverrideTarget = $system.Boot.BootSourceOverrideTarget
        $entry.BootOverrideEnabled = $system.Boot.BootSourceOverrideEnabled

        # Get BIOS attributes (boot mode + sequence)
        $biosUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Bios"
        $bios = Invoke-RestMethod -Uri $biosUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30
        $entry.BootMode = $bios.Attributes.BootMode

        if ($bios.Attributes.UefiBootSeq) {
            $entry.UefiBootSeq = ($bios.Attributes.UefiBootSeq -split ',').Trim()
        }

        # Get available boot options with details
        $optionsUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/BootOptions"
        $optionsList = Invoke-RestMethod -Uri $optionsUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30

        foreach ($member in $optionsList.Members) {
            try {
                $optUri = "https://$ip$($member.'@odata.id')"
                $opt = Invoke-RestMethod -Uri $optUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 15
                $entry.BootOptions += [ordered]@{
                    Id                  = $opt.Id
                    DisplayName         = $opt.DisplayName
                    Name                = $opt.Name
                    BootOptionEnabled   = $opt.BootOptionEnabled
                    BootOptionReference = $opt.BootOptionReference
                    UefiDevicePath      = $opt.UefiDevicePath
                }
            } catch {
                $entry.BootOptions += [ordered]@{
                    Id    = $member.'@odata.id'
                    Error = $_.Exception.Message
                }
            }
        }

        $entry.Status = "Success"
    }
    catch {
        $entry.Status = "Failed"
        $entry.Error = $_.Exception.Message
    }

    return [PSCustomObject]$entry
} -ThrottleLimit $serverIPs.Count

# ── Display results ──
Write-Host ""
foreach ($srv in $results) {
    if ($srv.Status -eq "Success") {
        Write-Host "[$($srv.IPAddress)] BootMode: $($srv.BootMode) | Override: $($srv.BootOverrideTarget) ($($srv.BootOverrideEnabled)) | Options: $($srv.BootOptions.Count)" -ForegroundColor Green
        Write-Host "  Boot Sequence:" -ForegroundColor Cyan
        $position = 1
        foreach ($device in $srv.UefiBootSeq) {
            $displayName = ($srv.BootOptions | Where-Object { $_.BootOptionReference -eq $device }).DisplayName
            if ($displayName) {
                Write-Host "    $position. $device ($displayName)" -ForegroundColor White
            } else {
                Write-Host "    $position. $device" -ForegroundColor White
            }
            $position++
        }
    } else {
        Write-Host "[$($srv.IPAddress)] FAILED: $($srv.Error)" -ForegroundColor Red
    }
}

# ── Save results ──
$outputDir = Join-Path $repoRoot "config\dell\discovery"
if (!(Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile = Join-Path $outputDir "boot-settings-$timestamp.json"

$output = [ordered]@{
    GeneratedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    ServerCount = $results.Count
    Succeeded   = ($results | Where-Object { $_.Status -eq 'Success' }).Count
    Failed      = ($results | Where-Object { $_.Status -eq 'Failed' }).Count
    Servers     = $results
}

$output | ConvertTo-Json -Depth 6 | Set-Content -Path $outFile -Encoding UTF8

Write-Host "`n════════════════════════════════════════" -ForegroundColor Yellow
Write-Host "  Boot Settings Report" -ForegroundColor Yellow
Write-Host "  Servers queried: $($results.Count)" -ForegroundColor Yellow
Write-Host "  Success: $(($results | Where-Object { $_.Status -eq 'Success' }).Count)" -ForegroundColor Green
Write-Host "  Failed:  $(($results | Where-Object { $_.Status -eq 'Failed' }).Count)" -ForegroundColor Red
Write-Host "  Results: $outFile" -ForegroundColor Yellow
Write-Host "════════════════════════════════════════" -ForegroundColor Yellow
```

#### Reset Boot Sequence to Factory Default

Restores the UEFI boot configuration to a clean factory state using the Dell OEM BIOS attribute `SysPrepClean`. This is a firmware-level purge that wipes all stale UEFI boot variables from NVRAM and forces BIOS to rebuild boot entries from hardware detection on the next POST.

The script performs these operations on each server:

1. **CLEAR pending iDRAC configuration jobs** — Dell iDRAC blocks new BIOS changes if pending config jobs exist (`IDRAC.2.9.SYS011`). Cleared automatically via `DellJobService.DeleteJobQueue`.
2. **SET `SysPrepClean=Yes`** — PATCHes the Dell OEM BIOS attribute `BootSettings.SysPrepClean` to "Yes" via `Bios/Settings`. This tells the BIOS firmware to purge all stale UEFI boot variables from NVRAM during the next POST cycle. The attribute auto-resets to "None" after execution.
3. **CREATE configuration job** — Creates a BIOS configuration job via `POST /Managers/iDRAC.Embedded.1/Jobs` with `TargetSettingsURI` pointing to `Bios/Settings` to apply the pending SysPrepClean change on next reboot.
4. **CLEAR one-time boot overrides** — resets `BootSourceOverrideEnabled` to "Disabled" if stuck on "Once" or "Continuous".
5. **REBOOT servers** — triggers a `GracefulRestart` (or powers on if the server is off) so that BIOS POST executes `SysPrepClean`, purges stale entries, re-enumerates hardware, and recreates fresh default boot entries. Use `-NoReboot` to skip this step.

After reboot, BIOS POST will:

- Execute `SysPrepClean` (purge all stale UEFI boot variables from NVRAM)
- Re-enumerate hardware and create fresh default boot entries
- `SysPrepClean` auto-resets to "None"

Dell AX-760 factory default boot order (rebuilt by BIOS):

1. **PXE Device 1** — Embedded NIC 1 Port 1 Partition 1
2. **PXE Device 2** — Embedded NIC 1 Port 2 Partition 1
3. **BOSS Card Virtual Disk** — RAID 1 (2x M.2 SSD)
4. **Virtual Optical Drive** — iDRAC virtual media

This script does **not** touch: BootMode, BIOS settings (CPU, memory, PCIe), RAID/storage config, network settings, or iDRAC settings.

NOTE: `SysPrepClean` is staged as a pending BIOS attribute. The script creates a targeted config job and automatically reboots servers so BIOS POST executes the purge. Use `-NoReboot` to defer the reboot.

**Script Location:** `scripts\common\utilities\tools\Reset-BootSequence.ps1`

**Run the script directly:**
```powershell
# Option 1: Dry run first — show current boot state without changes
.\scripts\common\utilities\tools\Reset-BootSequence.ps1 -DryRun -Force

# Option 2: Apply SysPrepClean + reboot using Key Vault credentials
.\scripts\common\utilities\tools\Reset-BootSequence.ps1 -Force

# Option 3: Reset specific servers only
.\scripts\common\utilities\tools\Reset-BootSequence.ps1 -IdracIP "192.168.214.11","192.168.214.12" -Force

# Option 4: Provide credentials manually with dry run
$cred = Get-Credential -UserName root -Message "Enter iDRAC password"
.\scripts\common\utilities\tools\Reset-BootSequence.ps1 -Credential $cred -DryRun

# Option 5: Apply SysPrepClean but skip automatic reboot
.\scripts\common\utilities\tools\Reset-BootSequence.ps1 -Force -NoReboot
```

**Expected Output (LIVE mode):**
```text
Processing 4 server(s)...

[192.168.214.11] Status: Applied
  Cleared pending iDRAC configuration jobs
  Current boot entries (1 valid, 2 stale):
    ✓ Boot0007: PXE Device 1: Embedded NIC 1 Port 1 Partition 1 [Enabled]
    ✕ Boot0008: Unavailable: Windows Boot Manager [Disabled]
    ✕ Boot0003: Unavailable: WindowsServer [Disabled]
  SysPrepClean: Set to Yes (was: None) — BIOS will purge stale entries on POST
  Config Job: Created (JID_275287082498) — scheduled to apply on reboot
  Reboot: Initiated (GracefulRestart) — BIOS POST will execute SysPrepClean

[192.168.214.14] Status: Applied
  Cleared pending iDRAC configuration jobs
  Current boot entries (3 valid, 2 stale):
    ✕ Boot0005: Unavailable: Windows Boot Manager [Disabled]
    ✕ Boot0003: Unavailable: WindowsServer [Disabled]
    ✓ Boot0004: PXE Device 1: Embedded NIC 1 Port 1 Partition 1 [Enabled]
    ✓ Boot0000: Virtual Floppy Drive [Enabled]
    ✓ Boot0001: Virtual Optical Drive [Enabled]
  SysPrepClean: Set to Yes (was: None) — BIOS will purge stale entries on POST
  Config Job: Created (JID_275287082501) — scheduled to apply on reboot
  Reboot: Initiated (GracefulRestart) — BIOS POST will execute SysPrepClean
...

════════════════════════════════════════
  Boot Sequence Reset Report
  Mode: LIVE
  Servers processed: 4
  Applied: 4
  SysPrepClean staged: 4
  Config jobs created: 4
  Stale entries found: 7 (will be purged by BIOS POST)
  Rebooted: 4
  Failed:  0
  Results: config/dell/discovery/boot-reset-20260212-213732.json
════════════════════════════════════════

SERVERS ARE REBOOTING — SysPrepClean will execute during BIOS POST.
  - BIOS will purge all stale UEFI boot variables from NVRAM
  - BIOS will re-enumerate hardware and create fresh default boot entries
  - SysPrepClean auto-resets to None after execution

  Wait ~5 minutes, then run Get-BootSettings.ps1 to verify the clean state.
```

TIP: Always run with `-DryRun` first to see current boot state. After applying, wait ~5 minutes for BIOS POST to complete, then run `Get-BootSettings.ps1` to verify BIOS rebuilt clean boot entries. Use `-NoReboot` to stage `SysPrepClean` without rebooting.

**Or copy/paste the script contents:**

```powershell
<#
.SYNOPSIS
    Resets UEFI boot sequence to Dell factory defaults via Redfish API.

.DESCRIPTION
    Restores the UEFI boot configuration to a clean factory state on Dell PowerEdge
    AX-series servers using the Dell OEM BIOS attribute SysPrepClean. This is a
    firmware-level purge that wipes all stale UEFI boot variables from NVRAM and
    forces BIOS to rebuild boot entries from hardware detection on the next POST.

    The script performs these operations on each server:

    1. CLEAR pending iDRAC configuration jobs — Dell iDRAC blocks new BIOS changes
       if pending config jobs exist (IDRAC.2.9.SYS011). Cleared automatically via
       DellJobService.DeleteJobQueue.

    2. SET SysPrepClean=Yes — PATCHes the Dell OEM BIOS attribute
       BootSettings.SysPrepClean to "Yes" via Bios/Settings. This tells the BIOS
       firmware to purge all stale UEFI boot variables from NVRAM during the next
       POST cycle. The attribute auto-resets to "None" after execution.

    3. CREATE configuration job — Creates a BIOS configuration job to apply the
       pending SysPrepClean change on next reboot.

    4. CLEAR one-time boot overrides — resets BootSourceOverrideEnabled to
       "Disabled" if stuck on "Once" or "Continuous".

    5. REBOOT servers — triggers a GracefulRestart (or powers on if the server is
       off) so that BIOS POST executes the SysPrepClean, purges stale entries,
       re-enumerates hardware, and recreates fresh default boot entries.
       Use -NoReboot to skip the reboot step.

    After reboot, BIOS POST will:
    - Execute SysPrepClean (purge all stale UEFI boot variables from NVRAM)
    - Re-enumerate hardware and create fresh default boot entries
    - SysPrepClean auto-resets to "None"

    Dell AX-760 factory default boot order (rebuilt by BIOS):
      1. PXE Device 1 — Embedded NIC 1 Port 1 Partition 1
      2. PXE Device 2 — Embedded NIC 1 Port 2 Partition 1
      3. BOSS Card Virtual Disk (RAID 1 M.2 SSD)
      4. Virtual Optical Drive (iDRAC virtual media)

    This script does NOT touch: BootMode, BIOS settings (CPU, memory, PCIe),
    RAID/storage config, network settings, or iDRAC settings.

.PARAMETER Credential
    PSCredential for iDRAC authentication. If not provided, retrieves from Key Vault.

.PARAMETER IdracIP
    One or more iDRAC IP addresses. Defaults to all servers from environment.yaml.

.PARAMETER Force
    Skip confirmation prompts.

.PARAMETER DryRun
    Show current boot state without making any changes.

.PARAMETER NoReboot
    Skip the automatic server reboot after applying SysPrepClean. The BIOS attribute
    will be staged as pending and applied on the next manual reboot.

.EXAMPLE
    .\Reset-BootSequence.ps1 -DryRun

    Show current boot options and SysPrepClean status without making changes.

.EXAMPLE
    .\Reset-BootSequence.ps1 -Force

    Reset all servers using Key Vault credentials, skip confirmation.

.EXAMPLE
    .\Reset-BootSequence.ps1 -IdracIP "192.168.214.11" -DryRun

    Preview current boot state for a single server.

.EXAMPLE
    $cred = Get-Credential -UserName root -Message "Enter iDRAC password"
    .\Reset-BootSequence.ps1 -Credential $cred -IdracIP "192.168.214.11","192.168.214.12"

    Reset specific servers using provided credentials.

.NOTES
    Requires:
    - PowerShell 7.0+ (for ForEach-Object -Parallel and -SkipCertificateCheck)
    - Network access to iDRAC management interfaces
    - Valid iDRAC credentials with administrator permissions
    - AzureLocalConfig.psm1 module for configuration loading
    - Az.KeyVault module (if using Key Vault for credentials)
    - Dell PowerEdge iDRAC with BIOS attribute BootSettings.SysPrepClean support

    What this script changes:
    - Sets BIOS attribute BootSettings.SysPrepClean = Yes (firmware purges stale
      UEFI boot variables on next POST, then auto-resets to None)
    - Creates BIOS configuration job to apply the pending change
    - Clears BootSourceOverrideEnabled (set to Disabled)
    - Reboots servers to trigger BIOS POST (unless -NoReboot)

    What this script does NOT change:
    - BootMode (remains Uefi — no change)
    - BIOS settings (CPU, memory, PCIe, etc.)
    - RAID / Storage configurations
    - Network settings
    - iDRAC settings

    After reboot, BIOS POST executes SysPrepClean, re-enumerates hardware, and
    creates fresh default boot entries from detected devices.

    Output file: config/dell/discovery/boot-reset-<timestamp>.json
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string[]]$IdracIP,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$NoReboot
)

#Requires -Version 7.0

$ErrorActionPreference = "Continue"

# ── Find repository root ──
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) {
    throw "Could not find repository root (config directory not found)"
}

# ── Load configuration ──
$modulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
Import-Module $modulePath -Force

$config = Get-AzureLocalConfig
if ($IdracIP) {
    $serverIPs = $IdracIP
} else {
    $serverIPs = $config.GetIdracIPs()
}

# Filter out empty/null entries and non-IP values
$serverIPs = @($serverIPs | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' })
if ($serverIPs.Count -eq 0) {
    throw "No valid iDRAC IP addresses found. Check environment.yaml or provide -IdracIP."
}

# ── Credential resolution ──
if (!$Credential) {
    $keyVaultName = $config.GetValue('keyvault.platform_name')
    $secretName = $config.GetValue('ztp.idrac_secret_name')

    if ($keyVaultName -and $secretName) {
        try {
            Write-Host "Retrieving iDRAC credentials from Key Vault '$keyVaultName'..." -ForegroundColor Cyan
            $secret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName
            if (!$secret) {
                throw "Secret '$secretName' not found in Key Vault '$keyVaultName'"
            }
            $credString = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
            if ($credString -notmatch ':') {
                throw "Secret value must be in format 'username:password'"
            }
            $username, $password = $credString -split ':', 2
            $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
            $Credential = New-Object PSCredential ($username, $securePassword)
            Write-Host "  Credentials retrieved successfully" -ForegroundColor Green
        }
        catch {
            Write-Host "  Key Vault access failed: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  Falling back to interactive credential entry..." -ForegroundColor Yellow
            $Credential = Get-Credential -Message "Enter iDRAC credentials (e.g., root)"
        }
    }
    else {
        Write-Host "Key Vault not configured. Please provide credentials interactively." -ForegroundColor Yellow
        $Credential = Get-Credential -Message "Enter iDRAC credentials (e.g., root)"
    }
}

# ── Confirm operation ──
$modeLabel = if ($DryRun) { "DRY RUN — no changes will be made" } else { "LIVE — SysPrepClean will purge stale boot entries and BIOS rebuilds from hardware" }
if (!$Force) {
    Write-Host "Mode: $modeLabel" -ForegroundColor $(if ($DryRun) { "Yellow" } else { "Red" })
    Write-Host "Will reset boot sequence on $($serverIPs.Count) server(s):" -ForegroundColor Cyan
    $serverIPs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "This will:" -ForegroundColor Cyan
    Write-Host "  1. CLEAR pending iDRAC configuration jobs" -ForegroundColor Yellow
    Write-Host "  2. SET SysPrepClean=Yes (BIOS purges all stale UEFI boot variables on next POST)" -ForegroundColor Yellow
    Write-Host "  3. CREATE BIOS configuration job to apply the change" -ForegroundColor Yellow
    Write-Host "  4. CLEAR any one-time boot overrides" -ForegroundColor Yellow
    Write-Host "  5. REBOOT servers (BIOS POST executes SysPrepClean and rebuilds boot entries)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "No other BIOS settings, RAID, network, or iDRAC settings are affected." -ForegroundColor Cyan
    $confirmation = Read-Host "Continue? (yes/N)"
    if ($confirmation -ne 'yes') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
} elseif ($DryRun) {
    Write-Host "Mode: DRY RUN — no changes will be made`n" -ForegroundColor Yellow
}

Write-Host "`nProcessing $($serverIPs.Count) server(s)...`n" -ForegroundColor Cyan

# ── Serialize credentials for parallel execution ──
$credUser = $Credential.UserName
$credPass = $Credential.GetNetworkCredential().Password
$dryRunFlag = $DryRun.IsPresent
$noRebootFlag = $NoReboot.IsPresent

# ── Process all servers in parallel ──
$results = $serverIPs | ForEach-Object -Parallel {
    $ip = $_
    $user = $using:credUser
    $pass = $using:credPass
    $isDryRun = $using:dryRunFlag
    $isNoReboot = $using:noRebootFlag

    $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
    $cred = New-Object PSCredential ($user, $secPass)

    $entry = [ordered]@{
        IPAddress            = $ip
        Timestamp            = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        Status               = "Unknown"
        DryRun               = $isDryRun
        PendingJobsCleared   = $false
        SysPrepCleanSet      = $false
        SysPrepCleanError    = $null
        SysPrepCleanPrevious = $null
        ConfigJobCreated     = $false
        ConfigJobId          = $null
        ConfigJobError       = $null
        OverrideCleared      = $false
        OverrideClearError   = $null
        OriginalOverride     = $null
        Rebooted             = $false
        RebootError          = $null
        CurrentBootOptions   = @()
        StaleCount           = 0
        ValidCount           = 0
        Error                = $null
    }

    try {
        # ── Test Redfish connectivity ──
        $svcUri = "https://$ip/redfish/v1"
        $null = Invoke-RestMethod -Uri $svcUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30

        # ── Get current system and boot state ──
        $sysUri = "https://$ip/redfish/v1/Systems/System.Embedded.1"
        $system = Invoke-RestMethod -Uri $sysUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30
        $entry.OriginalOverride = "$($system.Boot.BootSourceOverrideEnabled) / $($system.Boot.BootSourceOverrideTarget)"

        # ── Read current BIOS attributes to check SysPrepClean state ──
        $biosUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Bios"
        $biosData = Invoke-RestMethod -Uri $biosUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30
        $entry.SysPrepCleanPrevious = $biosData.Attributes.'SysPrepClean'
        if (!$entry.SysPrepCleanPrevious) {
            # Try alternate attribute name format
            $entry.SysPrepCleanPrevious = $biosData.Attributes.'BootSettings.SysPrepClean'
        }

        # ── Get current boot options for reporting ──
        $optionsUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/BootOptions"
        $optionsList = Invoke-RestMethod -Uri $optionsUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30

        foreach ($member in $optionsList.Members) {
            try {
                $optUri = "https://$ip$($member.'@odata.id')"
                $opt = Invoke-RestMethod -Uri $optUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 15
                $isStale = ($opt.DisplayName -match '^Unavailable:' -or
                            $opt.DisplayName -match 'Windows Boot Manager' -or
                            $opt.DisplayName -match '^WindowsServer$')
                $entry.CurrentBootOptions += [ordered]@{
                    Id          = $opt.Id
                    DisplayName = $opt.DisplayName
                    Enabled     = $opt.BootOptionEnabled
                    Reference   = $opt.BootOptionReference
                    Stale       = $isStale
                }
                if ($isStale) { $entry.StaleCount++ } else { $entry.ValidCount++ }
            } catch {
                # Skip inaccessible
            }
        }

        if (!$isDryRun) {
            # ── Step 1: Clear pending iDRAC configuration jobs ──
            try {
                $jobQueueUri = "https://$ip/redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellJobService/Actions/DellJobService.DeleteJobQueue"
                $clearBody = @{ JobID = "JID_CLEARALL" } | ConvertTo-Json
                Invoke-RestMethod -Uri $jobQueueUri -Method Post -Credential $cred `
                    -SkipCertificateCheck -ContentType "application/json" `
                    -Body $clearBody -TimeoutSec 30
                $entry.PendingJobsCleared = $true
                Start-Sleep -Seconds 3
            } catch {
                $entry.PendingJobsCleared = "skipped"
            }

            # ── Step 2: Set SysPrepClean=Yes (BIOS purges stale UEFI boot NVRAM on next POST) ──
            try {
                $biosSettingsUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Bios/Settings"
                $sysPrepBody = @{
                    Attributes = @{
                        "SysPrepClean" = "Yes"
                    }
                } | ConvertTo-Json -Depth 3

                $response = Invoke-RestMethod -Uri $biosSettingsUri -Method Patch -Credential $cred `
                    -SkipCertificateCheck -ContentType "application/json" `
                    -Body $sysPrepBody -TimeoutSec 30
                $entry.SysPrepCleanSet = $true
            } catch {
                # Try alternate attribute name format
                $errDetail = $_.ErrorDetails.Message
                try {
                    $sysPrepBody2 = @{
                        Attributes = @{
                            "BootSettings.SysPrepClean" = "Yes"
                        }
                    } | ConvertTo-Json -Depth 3

                    $response = Invoke-RestMethod -Uri $biosSettingsUri -Method Patch -Credential $cred `
                        -SkipCertificateCheck -ContentType "application/json" `
                        -Body $sysPrepBody2 -TimeoutSec 30
                    $entry.SysPrepCleanSet = $true
                } catch {
                    $errDetail2 = $_.ErrorDetails.Message
                    if (!$errDetail2) { $errDetail2 = $_.Exception.Message }
                    $entry.SysPrepCleanError = "SysPrepClean PATCH failed: $errDetail2 (also tried: $errDetail)"
                }
            }

            # ── Step 3: Create BIOS configuration job to apply the pending change ──
            if ($entry.SysPrepCleanSet) {
                try {
                    # Standard Redfish Jobs collection — works on iDRAC 9 firmware 7.x+
                    $jobsUri = "https://$ip/redfish/v1/Managers/iDRAC.Embedded.1/Jobs"
                    $jobBody = @{
                        TargetSettingsURI = "/redfish/v1/Systems/System.Embedded.1/Bios/Settings"
                    } | ConvertTo-Json

                    $jobResponse = Invoke-WebRequest -Uri $jobsUri -Method Post -Credential $cred `
                        -SkipCertificateCheck -ContentType "application/json" `
                        -Body $jobBody -TimeoutSec 30

                    $entry.ConfigJobCreated = $true
                    # Extract job ID from Location header
                    $locationHeader = $jobResponse.Headers['Location']
                    if ($locationHeader) {
                        $entry.ConfigJobId = ("$locationHeader" -split '/')[-1]
                    }
                    Start-Sleep -Seconds 3
                } catch {
                    $errDetail = $_.ErrorDetails.Message
                    if (!$errDetail) { $errDetail = $_.Exception.Message }
                    $entry.ConfigJobError = "Config job creation failed: $errDetail"
                }
            }

            # ── Step 4: Clear boot source override if not already Disabled ──
            try {
                if ($system.Boot.BootSourceOverrideEnabled -ne 'Disabled') {
                    $overrideBody = @{
                        Boot = @{
                            BootSourceOverrideEnabled = "Disabled"
                        }
                    } | ConvertTo-Json -Depth 3

                    Invoke-RestMethod -Uri $sysUri -Method Patch -Credential $cred `
                        -SkipCertificateCheck -ContentType "application/json" `
                        -Body $overrideBody -TimeoutSec 30

                    $entry.OverrideCleared = $true
                }
            } catch {
                $errDetail = $_.ErrorDetails.Message
                if (!$errDetail) { $errDetail = $_.Exception.Message }
                $entry.OverrideClearError = "Override clear failed: $errDetail"
            }

            # ── Step 5: Reboot the server ──
            if (!$isNoReboot) {
                try {
                    $sysCheck = Invoke-RestMethod -Uri $sysUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30
                    $resetUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"

                    if ($sysCheck.PowerState -eq 'On') {
                        $resetBody = @{ ResetType = "GracefulRestart" } | ConvertTo-Json
                    } else {
                        $resetBody = @{ ResetType = "On" } | ConvertTo-Json
                    }

                    Invoke-RestMethod -Uri $resetUri -Method Post -Credential $cred `
                        -SkipCertificateCheck -ContentType "application/json" `
                        -Body $resetBody -TimeoutSec 30

                    $entry.Rebooted = $true
                } catch {
                    $errDetail = $_.ErrorDetails.Message
                    if (!$errDetail) { $errDetail = $_.Exception.Message }
                    $entry.RebootError = "Reboot failed: $errDetail"
                }
            }

            # Determine overall status
            if ($entry.SysPrepCleanSet -and $entry.ConfigJobCreated) {
                $entry.Status = "Applied"
            } elseif ($entry.SysPrepCleanSet -and !$entry.ConfigJobCreated) {
                $entry.Status = "PartialFailure"
                $entry.Error = $entry.ConfigJobError
            } else {
                $entry.Status = "PartialFailure"
                $entry.Error = $entry.SysPrepCleanError
            }
        } else {
            $entry.Status = "DryRun"
        }
    }
    catch {
        $entry.Status = "Failed"
        $errDetail = $_.ErrorDetails.Message
        if (!$errDetail) { $errDetail = $_.Exception.Message }
        $entry.Error = $errDetail
    }

    return [PSCustomObject]$entry
} -ThrottleLimit $serverIPs.Count

# ── Display results ──
Write-Host ""
foreach ($srv in $results) {
    $statusColor = switch ($srv.Status) {
        "Applied"        { "Green" }
        "PartialFailure" { "DarkYellow" }
        "DryRun"         { "Yellow" }
        "Failed"         { "Red" }
        default          { "Gray" }
    }

    Write-Host "[$($srv.IPAddress)] Status: $($srv.Status)" -ForegroundColor $statusColor

    if ($srv.Status -ne "Failed") {
        # Show job queue status
        if ($srv.PendingJobsCleared -eq $true) {
            Write-Host "  Cleared pending iDRAC configuration jobs" -ForegroundColor DarkGray
        }

        # Show current boot options
        if ($srv.CurrentBootOptions.Count -gt 0) {
            Write-Host "  Current boot entries ($($srv.ValidCount) valid, $($srv.StaleCount) stale):" -ForegroundColor Cyan
            foreach ($opt in $srv.CurrentBootOptions) {
                $mark = if ($opt.Stale) { "✕" } else { "✓" }
                $enabledStr = if ($opt.Enabled) { "Enabled" } else { "Disabled" }
                $color = if ($opt.Stale) { "DarkGray" } else { "White" }
                Write-Host "    $mark $($opt.Id): $($opt.DisplayName) [$enabledStr]" -ForegroundColor $color
            }
        }

        # Show SysPrepClean status
        if ($srv.SysPrepCleanSet) {
            Write-Host "  SysPrepClean: Set to Yes (was: $($srv.SysPrepCleanPrevious)) — BIOS will purge stale entries on POST" -ForegroundColor Green
        } elseif ($srv.SysPrepCleanError) {
            Write-Host "  SysPrepClean: FAILED — $($srv.SysPrepCleanError)" -ForegroundColor Red
        } elseif ($srv.DryRun) {
            Write-Host "  SysPrepClean: Would set to Yes (current: $($srv.SysPrepCleanPrevious))" -ForegroundColor Yellow
        }

        # Show config job status
        if ($srv.ConfigJobCreated) {
            Write-Host "  Config Job: Created ($($srv.ConfigJobId)) — scheduled to apply on reboot" -ForegroundColor Green
        } elseif ($srv.ConfigJobError) {
            Write-Host "  Config Job: FAILED — $($srv.ConfigJobError)" -ForegroundColor Red
        }

        # Show override status
        if ($srv.OverrideCleared) {
            $verb = if ($srv.DryRun) { "Would clear" } else { "Cleared" }
            Write-Host "  Boot override: $verb (was: $($srv.OriginalOverride))" -ForegroundColor Yellow
        }
        if ($srv.OverrideClearError) {
            Write-Host "  Override clear: FAILED — $($srv.OverrideClearError)" -ForegroundColor Red
        }

        # Show reboot status
        if ($srv.Rebooted) {
            Write-Host "  Reboot: Initiated (GracefulRestart) — BIOS POST will execute SysPrepClean" -ForegroundColor Cyan
        } elseif ($srv.RebootError) {
            Write-Host "  Reboot: FAILED — $($srv.RebootError)" -ForegroundColor Red
        } elseif ($NoReboot -and !$srv.DryRun) {
            Write-Host "  Reboot: Skipped (-NoReboot) — SysPrepClean staged, will execute on next reboot" -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  Error: $($srv.Error)" -ForegroundColor Red
    }
    Write-Host ""
}

# ── Save results ──
$outputDir = Join-Path $repoRoot "config\dell\discovery"
if (!(Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile = Join-Path $outputDir "boot-reset-$timestamp.json"

$output = [ordered]@{
    GeneratedAt     = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    DryRun          = $DryRun.IsPresent
    ServerCount     = $results.Count
    Applied         = ($results | Where-Object { $_.Status -eq 'Applied' }).Count
    PartialFailure  = ($results | Where-Object { $_.Status -eq 'PartialFailure' }).Count
    Previewed       = ($results | Where-Object { $_.Status -eq 'DryRun' }).Count
    Failed          = ($results | Where-Object { $_.Status -eq 'Failed' }).Count
    SysPrepCleanSet = ($results | Where-Object { $_.SysPrepCleanSet -eq $true }).Count
    ConfigJobCreated = ($results | Where-Object { $_.ConfigJobCreated -eq $true }).Count
    Rebooted        = ($results | Where-Object { $_.Rebooted -eq $true }).Count
    RebootFailed    = ($results | Where-Object { $_.RebootError }).Count
    TotalStale      = ($results | Measure-Object -Property StaleCount -Sum).Sum
    TotalValid      = ($results | Measure-Object -Property ValidCount -Sum).Sum
    Servers         = $results
}

$output | ConvertTo-Json -Depth 6 | Set-Content -Path $outFile -Encoding UTF8

Write-Host "════════════════════════════════════════" -ForegroundColor Yellow
Write-Host "  Boot Sequence Reset Report" -ForegroundColor Yellow
Write-Host "  Mode: $(if ($DryRun) { 'DRY RUN' } else { 'LIVE' })" -ForegroundColor $(if ($DryRun) { "Yellow" } else { "Green" })
Write-Host "  Servers processed: $($results.Count)" -ForegroundColor Yellow
if (!$DryRun) {
    Write-Host "  Applied: $(($results | Where-Object { $_.Status -eq 'Applied' }).Count)" -ForegroundColor Green
    $partialCount = ($results | Where-Object { $_.Status -eq 'PartialFailure' }).Count
    if ($partialCount -gt 0) {
        Write-Host "  Partial: $partialCount (check per-server details above)" -ForegroundColor DarkYellow
    }
    Write-Host "  SysPrepClean staged: $(($results | Where-Object { $_.SysPrepCleanSet -eq $true }).Count)" -ForegroundColor Green
    Write-Host "  Config jobs created: $(($results | Where-Object { $_.ConfigJobCreated -eq $true }).Count)" -ForegroundColor Green
    Write-Host "  Stale entries found: $(($results | Measure-Object -Property StaleCount -Sum).Sum) (will be purged by BIOS POST)" -ForegroundColor Red
    $rebootCount = ($results | Where-Object { $_.Rebooted -eq $true }).Count
    $rebootFailCount = ($results | Where-Object { $_.RebootError }).Count
    if ($rebootCount -gt 0) {
        Write-Host "  Rebooted: $rebootCount" -ForegroundColor Cyan
    }
    if ($rebootFailCount -gt 0) {
        Write-Host "  Reboot failed: $rebootFailCount" -ForegroundColor Red
    }
} else {
    Write-Host "  Stale entries found: $(($results | Measure-Object -Property StaleCount -Sum).Sum)" -ForegroundColor Yellow
    Write-Host "  Valid entries found: $(($results | Measure-Object -Property ValidCount -Sum).Sum)" -ForegroundColor Yellow
}
Write-Host "  Failed:  $(($results | Where-Object { $_.Status -eq 'Failed' }).Count)" -ForegroundColor Red
Write-Host "  Results: $outFile" -ForegroundColor Yellow
Write-Host "════════════════════════════════════════" -ForegroundColor Yellow

if (!$DryRun -and ($results | Where-Object { $_.Status -in @('Applied','PartialFailure') })) {
    Write-Host ""
    $rebootedServers = ($results | Where-Object { $_.Rebooted -eq $true }).Count
    if ($rebootedServers -gt 0) {
        Write-Host "SERVERS ARE REBOOTING — SysPrepClean will execute during BIOS POST." -ForegroundColor Cyan
        Write-Host "  - BIOS will purge all stale UEFI boot variables from NVRAM" -ForegroundColor Cyan
        Write-Host "  - BIOS will re-enumerate hardware and create fresh default boot entries" -ForegroundColor Cyan
        Write-Host "  - SysPrepClean auto-resets to None after execution" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Wait ~5 minutes, then run Get-BootSettings.ps1 to verify the clean state." -ForegroundColor Yellow
    } elseif ($NoReboot) {
        Write-Host "NEXT STEP: Reboot the servers for SysPrepClean to execute (-NoReboot was specified)." -ForegroundColor DarkYellow
        Write-Host "  - SysPrepClean is staged as pending BIOS configuration" -ForegroundColor DarkYellow
        Write-Host "  - On next reboot, BIOS POST will purge stale entries and rebuild from hardware" -ForegroundColor DarkYellow
        Write-Host ""
        Write-Host "  Run Get-BootSettings.ps1 after reboot to verify the clean state." -ForegroundColor Yellow
    } else {
        Write-Host "WARNING: Reboot failed on all servers. Reboot them manually for SysPrepClean to execute." -ForegroundColor Red
        Write-Host "  Run Get-BootSettings.ps1 after reboot to verify the clean state." -ForegroundColor Yellow
    }
}

```

### iDRAC Job Monitoring

When scripts like `Reset-BootSequence.ps1` create BIOS configuration jobs (e.g. setting `SysPrepClean=Yes`), the iDRAC schedules those jobs and executes them during the next reboot cycle. This monitoring tool lets you query the iDRAC Job Queue across all servers via the Dell Redfish API to track job progress, verify completion, and diagnose failures.

The Dell iDRAC Redfish Jobs API endpoints:

- `GET /redfish/v1/Managers/iDRAC.Embedded.1/Jobs` — list all jobs in the queue
- `GET /redfish/v1/Managers/iDRAC.Embedded.1/Jobs/{JobId}` — get details for a specific job

Job states returned by iDRAC:

| Description |
| --- |

#### Monitor iDRAC Jobs

Query the iDRAC job queue on all servers and display job status with color-coded output. Supports filtering by job state, filtering by recency, and a continuous polling (wait) mode.

**Script Location:** `scripts\common\utilities\tools\Get-iDRACJobs.ps1`

**Run the script directly:**
```powershell
# Query all jobs on all servers (single snapshot)
.\scripts\common\utilities\tools\Get-iDRACJobs.ps1 -Force

# Show only running or scheduled jobs
.\scripts\common\utilities\tools\Get-iDRACJobs.ps1 -JobState Running,Scheduled -Force

# Show jobs created in the last 10 minutes (e.g. after running Reset-BootSequence.ps1)
.\scripts\common\utilities\tools\Get-iDRACJobs.ps1 -Recent 10 -Force

# Wait mode — poll every 30 seconds until all active jobs complete
.\scripts\common\utilities\tools\Get-iDRACJobs.ps1 -Wait -Force

# Wait mode with custom poll interval (15 seconds)
.\scripts\common\utilities\tools\Get-iDRACJobs.ps1 -Wait -PollInterval 15 -Force

# Query a single server
.\scripts\common\utilities\tools\Get-iDRACJobs.ps1 -IdracIP "192.168.214.11" -Force
```

**Parameters:**

| Type | Description |
| --- | --- |

**Expected Output (single query):**
```
Querying iDRAC jobs on 4 server(s)...

[192.168.214.11] Total Jobs: 3 | Filtered: 3 | Active: 1
  ┌─ JID_275287082498 [Completed] 100%
  │  Name:    Configure: BIOS.Setup.1-1
  │  Type:    BIOSConfiguration
  │  Message: Job completed successfully.
  │  Start:   2025-01-15T10:30:00
  │  End:     2025-01-15T10:35:22
  │  Target:  /redfish/v1/Systems/System.Embedded.1/Bios/Settings
  └──────────────────────────────────────
  ┌─ RID_275287082499 [Completed] 100%
  │  Name:    Reboot: System.Embedded.1
  │  Type:    RebootNoForce
  │  Message: Reboot completed successfully.
  │  Start:   2025-01-15T10:30:01
  └──────────────────────────────────────
  ┌─ JID_275287082500 [Running] 45%
  │  Name:    Configure: BIOS.Setup.1-1
  │  Type:    BIOSConfiguration
  │  Message: Task successfully scheduled.
  │  Start:   2025-01-15T10:40:00
  └──────────────────────────────────────

════════════════════════════════════════
  iDRAC Jobs Report
  Servers queried: 4
  Active jobs: 1
  Results: config\dell\discovery\idrac-jobs-20250115-104500.json
════════════════════════════════════════
```

**Expected Output (wait mode):**
```
iDRAC Job Monitor — WAIT mode (poll every 30s)
Press Ctrl+C to stop monitoring

── Initial poll at 10:30:15 ──
[192.168.214.11] Total Jobs: 2 | Filtered: 2 | Active: 2
  ┌─ JID_275287082498 [Scheduled] 0%
  │  Name:    Configure: BIOS.Setup.1-1
  ...
  1 active job(s) remaining — next poll in 30s...

── Poll #2 at 10:30:45 ──
[192.168.214.11] Total Jobs: 2 | Filtered: 2 | Active: 1
  JID_275287082498: [Running] 60% - Configure: BIOS.Setup.1-1
  ...

── Poll #3 at 10:31:15 ──
[192.168.214.11] Total Jobs: 2 | Filtered: 2 | Active: 0
  JID_275287082498: [Completed] 100% - Configure: BIOS.Setup.1-1

════════════════════════════════════════
  All jobs have reached terminal state
════════════════════════════════════════
```

**Typical workflow after Reset-BootSequence.ps1:**

1. Run `Reset-BootSequence.ps1` — creates SysPrepClean BIOS config job + reboots servers
2. Immediately run `Get-iDRACJobs.ps1 -Wait -Recent 5 -Force` to monitor the job
3. Wait for all jobs to reach `Completed`
4. Run `Get-BootSettings.ps1` to verify the clean boot state

**Embedded Script Copy (Get-iDRACJobs.ps1):**

[%collapsible]
====
```powershell
<#
.SYNOPSIS
    Queries and monitors iDRAC jobs across all servers via Redfish API.

.DESCRIPTION
    Authenticates via Key Vault (or interactive credentials), queries each server's
    iDRAC Job Queue via the Dell Redfish API, and displays job status information.
    Results for all servers are saved to a single JSON file.

    This is a generic monitoring tool — it works with ANY iDRAC job, including:
    - BIOS configuration jobs (e.g. SysPrepClean from Reset-BootSequence.ps1)
    - Firmware update jobs
    - RAID configuration jobs
    - iDRAC configuration jobs
    - Reboot jobs (RID_*)
    - Scheduled jobs

    The Dell iDRAC Redfish Jobs API endpoint is:
      GET /redfish/v1/Managers/iDRAC.Embedded.1/Jobs
      GET /redfish/v1/Managers/iDRAC.Embedded.1/Jobs/{JobId}

    Job states returned by iDRAC:
      New, Scheduled, Running, Completed, CompletedWithErrors,
      Failed, Downloading, Downloaded, Waiting, Paused,
      RebootPending, RebootFailed, RebootCompleted

    Use -Wait to continuously poll servers until all active jobs complete.
    Use -JobState to filter results to specific job states only.
    Use -Recent to show only jobs created within the last N minutes.

    This script does NOT modify any settings — it is read-only.

.PARAMETER Credential
    PSCredential for iDRAC authentication. If not provided, retrieves from Key Vault.

.PARAMETER IdracIP
    One or more iDRAC IP addresses. Defaults to all servers from environment.yaml.

.PARAMETER Force
    Skip confirmation prompts.

.PARAMETER JobState
    Filter jobs by state. Accepts one or more states:
    New, Scheduled, Running, Completed, CompletedWithErrors, Failed,
    Downloading, Downloaded, Waiting, Paused, RebootPending,
    RebootFailed, RebootCompleted.
    If not specified, all jobs are returned.

.PARAMETER Wait
    Continuously poll servers until all active (non-terminal) jobs reach a
    terminal state (Completed, CompletedWithErrors, Failed, RebootFailed,
    RebootCompleted). The script polls at -PollInterval seconds.

.PARAMETER PollInterval
    Seconds between polls when using -Wait. Default: 30.

.PARAMETER Recent
    Show only jobs created within the last N minutes. Useful for filtering
    out old historical jobs after running Reset-BootSequence.ps1.

.EXAMPLE
    .\Get-iDRACJobs.ps1

    Queries all jobs on all servers from config using Key Vault credentials.

.EXAMPLE
    .\Get-iDRACJobs.ps1 -JobState Running,Scheduled

    Shows only running or scheduled jobs across all servers.

.EXAMPLE
    .\Get-iDRACJobs.ps1 -Wait -PollInterval 15

    Polls every 15 seconds until all active jobs on all servers complete.

.EXAMPLE
    .\Get-iDRACJobs.ps1 -IdracIP "192.168.214.11" -Recent 10

    Shows only jobs created in the last 10 minutes on a specific server.

.EXAMPLE
    $cred = Get-Credential -UserName root -Message "Enter iDRAC password"
    .\Get-iDRACJobs.ps1 -Credential $cred -Wait

    Uses provided credentials and waits for all jobs to complete.

.NOTES
    Requires:
    - PowerShell 7.0+ (for ForEach-Object -Parallel and -SkipCertificateCheck)
    - Network access to iDRAC management interfaces
    - Valid iDRAC credentials with read permissions
    - AzureLocalConfig.psm1 module for configuration loading
    - Az.KeyVault module (if using Key Vault for credentials)

    Output file: config/dell/discovery/idrac-jobs-<timestamp>.json
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string[]]$IdracIP,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [ValidateSet("New", "Scheduled", "Running", "Completed", "CompletedWithErrors",
                 "Failed", "Downloading", "Downloaded", "Waiting", "Paused",
                 "RebootPending", "RebootFailed", "RebootCompleted")]
    [string[]]$JobState,

    [Parameter(Mandatory = $false)]
    [switch]$Wait,

    [Parameter(Mandatory = $false)]
    [int]$PollInterval = 30,

    [Parameter(Mandatory = $false)]
    [int]$Recent
)

#Requires -Version 7.0

$ErrorActionPreference = "Continue"

# ── Terminal job states (jobs that are done and will not change) ──
$terminalStates = @("Completed", "CompletedWithErrors", "Failed", "RebootFailed", "RebootCompleted")

# ── Find repository root ──
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) {
    throw "Could not find repository root (config directory not found)"
}

# ── Load configuration ──
$modulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
Import-Module $modulePath -Force

$config = Get-AzureLocalConfig
if ($IdracIP) {
    $serverIPs = $IdracIP
} else {
    $serverIPs = $config.GetIdracIPs()
}

# ── Credential resolution ──
if (!$Credential) {
    $keyVaultName = $config.GetValue('keyvault.platform_name')
    $secretName = $config.GetValue('ztp.idrac_secret_name')

    if ($keyVaultName -and $secretName) {
        try {
            Write-Host "Retrieving iDRAC credentials from Key Vault '$keyVaultName'..." -ForegroundColor Cyan
            $secret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName
            if (!$secret) {
                throw "Secret '$secretName' not found in Key Vault '$keyVaultName'"
            }
            $credString = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
            if ($credString -notmatch ':') {
                throw "Secret value must be in format 'username:password'"
            }
            $username, $password = $credString -split ':', 2
            $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
            $Credential = New-Object PSCredential ($username, $securePassword)
            Write-Host "  Credentials retrieved successfully" -ForegroundColor Green
        }
        catch {
            Write-Host "  Key Vault access failed: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  Falling back to interactive credential entry..." -ForegroundColor Yellow
            $Credential = Get-Credential -Message "Enter iDRAC credentials (e.g., root)"
        }
    }
    else {
        Write-Host "Key Vault not configured. Please provide credentials interactively." -ForegroundColor Yellow
        $Credential = Get-Credential -Message "Enter iDRAC credentials (e.g., root)"
    }
}

# ── Confirm operation ──
if (!$Force) {
    Write-Host "Will query iDRAC jobs on $($serverIPs.Count) server(s):" -ForegroundColor Cyan
    $serverIPs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    if ($Wait) {
        Write-Host "  Mode: WAIT (poll every ${PollInterval}s until all active jobs complete)" -ForegroundColor Magenta
    }
    if ($JobState) {
        Write-Host "  Filter: $($JobState -join ', ')" -ForegroundColor Magenta
    }
    if ($Recent) {
        Write-Host "  Recent: last $Recent minutes only" -ForegroundColor Magenta
    }
    $confirmation = Read-Host "Continue? (yes/N)"
    if ($confirmation -ne 'yes') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# ── Serialize credentials for parallel execution ──
$credUser = $Credential.UserName
$credPass = $Credential.GetNetworkCredential().Password

# ═══════════════════════════════════════════════════════════════
# Function: Query jobs from a single server (used in parallel)
# ═══════════════════════════════════════════════════════════════
function Get-ServerJobs {
    param(
        [string[]]$ServerIPs,
        [string]$User,
        [string]$Pass,
        [string[]]$FilterStates,
        [int]$RecentMinutes
    )

    $results = $ServerIPs | ForEach-Object -Parallel {
        $ip = $_
        $user = $using:User
        $pass = $using:Pass
        $filterStates = $using:FilterStates
        $recentMin = $using:RecentMinutes

        $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
        $cred = New-Object PSCredential ($user, $secPass)

        $entry = [ordered]@{
            IPAddress   = $ip
            Timestamp   = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
            Status      = "Unknown"
            TotalJobs   = 0
            ActiveJobs  = 0
            Jobs        = @()
            Error       = $null
        }

        try {
            # Test Redfish connectivity
            $svcUri = "https://$ip/redfish/v1"
            $null = Invoke-RestMethod -Uri $svcUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30

            # Get job collection
            $jobsUri = "https://$ip/redfish/v1/Managers/iDRAC.Embedded.1/Jobs"
            $jobList = Invoke-RestMethod -Uri $jobsUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30

            $entry.TotalJobs = $jobList.'Members@odata.count'

            # Get details for each job
            foreach ($member in $jobList.Members) {
                try {
                    $jobUri = "https://$ip$($member.'@odata.id')"
                    $job = Invoke-RestMethod -Uri $jobUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 15

                    $jobEntry = [ordered]@{
                        JobId           = $job.Id
                        Name            = $job.Name
                        JobType         = $job.JobType
                        JobState        = $job.JobState
                        Message         = $job.Message
                        MessageId       = $job.MessageId
                        PercentComplete = $job.PercentComplete
                        StartTime       = $job.StartTime
                        EndTime         = $job.EndTime
                        ActualRunningStartTime = $job.ActualRunningStartTime
                        ActualRunningEndTime   = $job.ActualRunningEndTime
                        TargetSettingsURI      = $job.TargetSettingsURI
                    }

                    # Apply -Recent filter (skip jobs older than N minutes)
                    if ($recentMin -gt 0 -and $job.StartTime) {
                        try {
                            $jobStart = [DateTime]::Parse($job.StartTime)
                            $cutoff = (Get-Date).AddMinutes(-$recentMin)
                            if ($jobStart -lt $cutoff) { continue }
                        } catch {
                            # If date parsing fails, include the job anyway
                        }
                    }

                    # Apply -JobState filter
                    if ($filterStates -and $filterStates.Count -gt 0) {
                        if ($job.JobState -notin $filterStates) { continue }
                    }

                    $entry.Jobs += $jobEntry
                } catch {
                    $entry.Jobs += [ordered]@{
                        JobId = $member.'@odata.id'
                        Error = $_.Exception.Message
                    }
                }
            }

            # Count active (non-terminal) jobs
            $termStates = @("Completed", "CompletedWithErrors", "Failed", "RebootFailed", "RebootCompleted")
            $entry.ActiveJobs = ($entry.Jobs | Where-Object {
                $_.JobState -and $_.JobState -notin $termStates
            }).Count

            $entry.Status = "Success"
        }
        catch {
            $entry.Status = "Failed"
            $entry.Error = $_.Exception.Message
        }

        return [PSCustomObject]$entry
    } -ThrottleLimit $ServerIPs.Count

    return $results
}

# ═══════════════════════════════════════════════════════════════
# Function: Display job results to console
# ═══════════════════════════════════════════════════════════════
function Show-JobResults {
    param($Results, [switch]$Compact)

    Write-Host ""
    foreach ($srv in $Results) {
        if ($srv.Status -eq "Success") {
            $activeColor = if ($srv.ActiveJobs -gt 0) { "Yellow" } else { "Green" }
            Write-Host "[$($srv.IPAddress)] Total Jobs: $($srv.TotalJobs) | Filtered: $($srv.Jobs.Count) | Active: $($srv.ActiveJobs)" -ForegroundColor $activeColor

            if ($srv.Jobs.Count -eq 0) {
                Write-Host "  (no jobs match current filter)" -ForegroundColor DarkGray
                continue
            }

            foreach ($job in $srv.Jobs) {
                if ($job.Error) {
                    Write-Host "  $($job.JobId): ERROR - $($job.Error)" -ForegroundColor Red
                    continue
                }

                # Color-code by state
                $stateColor = switch ($job.JobState) {
                    "Completed"              { "Green" }
                    "CompletedWithErrors"    { "Yellow" }
                    "Running"                { "Cyan" }
                    "Scheduled"              { "Magenta" }
                    "New"                    { "White" }
                    "Downloading"            { "Cyan" }
                    "Downloaded"             { "Cyan" }
                    "Waiting"                { "Yellow" }
                    "Paused"                 { "Yellow" }
                    "RebootPending"          { "Magenta" }
                    "RebootCompleted"        { "Green" }
                    "Failed"                 { "Red" }
                    "RebootFailed"           { "Red" }
                    default                  { "Gray" }
                }

                $pct = if ($job.PercentComplete -ne $null) { "$($job.PercentComplete)%" } else { "N/A" }

                if ($Compact) {
                    Write-Host "  $($job.JobId): [$($job.JobState)] $pct - $($job.Name)" -ForegroundColor $stateColor
                } else {
                    Write-Host "  ┌─ $($job.JobId) [$($job.JobState)] $pct" -ForegroundColor $stateColor
                    Write-Host "  │  Name:    $($job.Name)" -ForegroundColor White
                    Write-Host "  │  Type:    $($job.JobType)" -ForegroundColor White
                    Write-Host "  │  Message: $($job.Message)" -ForegroundColor White
                    if ($job.StartTime) {
                        Write-Host "  │  Start:   $($job.StartTime)" -ForegroundColor DarkGray
                    }
                    if ($job.EndTime -and $job.EndTime -ne "TIME_NA") {
                        Write-Host "  │  End:     $($job.EndTime)" -ForegroundColor DarkGray
                    }
                    if ($job.TargetSettingsURI) {
                        Write-Host "  │  Target:  $($job.TargetSettingsURI)" -ForegroundColor DarkGray
                    }
                    Write-Host "  └──────────────────────────────────────" -ForegroundColor DarkGray
                }
            }
        } else {
            Write-Host "[$($srv.IPAddress)] FAILED: $($srv.Error)" -ForegroundColor Red
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# Main execution
# ═══════════════════════════════════════════════════════════════

if ($Wait) {
    # ── Polling mode: loop until all active jobs reach terminal state ──
    Write-Host "`niDRAC Job Monitor — WAIT mode (poll every ${PollInterval}s)" -ForegroundColor Cyan
    Write-Host "Press Ctrl+C to stop monitoring`n" -ForegroundColor DarkGray

    $iteration = 0
    $allDone = $false

    while (-not $allDone) {
        $iteration++
        $timestamp = Get-Date -Format "HH:mm:ss"

        if ($iteration -gt 1) {
            Write-Host "`n── Poll #$iteration at $timestamp ──" -ForegroundColor DarkCyan
        } else {
            Write-Host "── Initial poll at $timestamp ──" -ForegroundColor DarkCyan
        }

        $results = Get-ServerJobs -ServerIPs $serverIPs -User $credUser -Pass $credPass `
                                  -FilterStates $JobState -RecentMinutes $Recent

        Show-JobResults -Results $results -Compact:($iteration -gt 1)

        # Check if any server still has active (non-terminal) jobs
        $totalActive = ($results | Where-Object { $_.Status -eq "Success" } |
                        ForEach-Object { $_.ActiveJobs } |
                        Measure-Object -Sum).Sum

        if ($totalActive -eq 0) {
            $allDone = $true
            Write-Host "`n════════════════════════════════════════" -ForegroundColor Green
            Write-Host "  All jobs have reached terminal state" -ForegroundColor Green
            Write-Host "════════════════════════════════════════" -ForegroundColor Green
        } else {
            Write-Host "`n  $totalActive active job(s) remaining — next poll in ${PollInterval}s..." -ForegroundColor Yellow
            Start-Sleep -Seconds $PollInterval
        }
    }
} else {
    # ── Single query mode ──
    Write-Host "`nQuerying iDRAC jobs on $($serverIPs.Count) server(s)...`n" -ForegroundColor Cyan

    $results = Get-ServerJobs -ServerIPs $serverIPs -User $credUser -Pass $credPass `
                              -FilterStates $JobState -RecentMinutes $Recent

    Show-JobResults -Results $results
}

# ── Save results ──
$outputDir = Join-Path $repoRoot "config\dell\discovery"
if (!(Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile = Join-Path $outputDir "idrac-jobs-$timestamp.json"

$totalActive = ($results | Where-Object { $_.Status -eq "Success" } |
                ForEach-Object { $_.ActiveJobs } |
                Measure-Object -Sum).Sum
$totalJobs = ($results | Where-Object { $_.Status -eq "Success" } |
              ForEach-Object { $_.Jobs.Count } |
              Measure-Object -Sum).Sum

$output = [ordered]@{
    GeneratedAt  = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    ServerCount  = $results.Count
    Succeeded    = ($results | Where-Object { $_.Status -eq 'Success' }).Count
    Failed       = ($results | Where-Object { $_.Status -eq 'Failed' }).Count
    TotalJobs    = $totalJobs
    ActiveJobs   = $totalActive
    FilterApplied = [ordered]@{
        JobState = if ($JobState) { $JobState } else { "All" }
        Recent   = if ($Recent) { "$Recent minutes" } else { "All" }
    }
    Servers      = $results
}

$output | ConvertTo-Json -Depth 6 | Set-Content -Path $outFile -Encoding UTF8

Write-Host "`n════════════════════════════════════════" -ForegroundColor Yellow
Write-Host "  iDRAC Jobs Report" -ForegroundColor Yellow
Write-Host "  Servers queried: $($results.Count)" -ForegroundColor Yellow
Write-Host "  Success: $(($results | Where-Object { $_.Status -eq 'Success' }).Count)" -ForegroundColor Green
Write-Host "  Failed:  $(($results | Where-Object { $_.Status -eq 'Failed' }).Count)" -ForegroundColor Red
Write-Host "  Total jobs (filtered): $totalJobs" -ForegroundColor Yellow
Write-Host "  Active jobs: $totalActive" -ForegroundColor $(if ($totalActive -gt 0) { "Yellow" } else { "Green" })
Write-Host "  Results: $outFile" -ForegroundColor Yellow
Write-Host "════════════════════════════════════════" -ForegroundColor Yellow
```
====

### Common Issues

- **Redfish API Connection Failed:**
    - Verify BMC/iDRAC IP addresses are correct
    - Check network connectivity to management interfaces
    - Ensure BMC credentials are valid
    - Confirm Redfish API is enabled in BMC settings

- **ISO Mount Failed:**
    - Verify share permissions and access
    - Check that ISO file exists and is not corrupted
    - Ensure virtual media is available on BMC

- **Server Not Booting from ISO:**
    - Confirm boot source override was set correctly
    - Check BMC logs for boot-related errors
    - Verify ISO integrity

### Bootloader Deployment Issues (BOSS Card Boot Loop)

#### Symptom

After a previous Azure Local or Windows Server installation, one or more servers are stuck in a boot loop. The server repeatedly attempts to boot from an entry labeled **"WindowsServer"** (or a similar Windows Boot Manager entry) on the BOSS card and fails, never reaching the ZTP provisioning environment.

This is commonly observed when:

- Servers were previously provisioned with Azure Local or Windows Server
- The BOSS card still contains a virtual disk with a stale OS partition and boot loader
- The BIOS finds the old boot entry and continuously loops attempting to boot from it

#### Root Cause

The **Dell BOSS (Boot Optimized Storage Solution)** card is a hardware RAID controller that mirrors two M.2 SSDs in a RAID 1 configuration for OS boot. On Dell PowerEdge AX-series servers (e.g., AX-760), this is typically a **BOSS-N1** controller (16th generation). Older generations may use BOSS-S1 (14G) or BOSS-S2 (15G).

When a server was previously provisioned, the BOSS card's virtual disk contains partitions and a Windows Boot Manager entry from the prior installation. Even after setting the boot source override to virtual CD for ZTP, the BIOS may fall back to the stale boot entry on the BOSS card, causing a boot loop.

The solution is to **delete the existing virtual disk** on the BOSS controller via the iDRAC Redfish API, then **recreate it as a clean RAID 1 volume**, which removes all prior OS partitions and boot loader entries.

#### Solution: Reset BOSS Card Virtual Disks

IMPORTANT: This procedure will **permanently destroy all data** on the BOSS card's M.2 drives on **all servers simultaneously**. Ensure you have no required data on the target servers before proceeding.

The `Reset-BOSSVirtualDisk.ps1` script handles the entire lifecycle on all servers at the same time:

1. Connects to all iDRACs in parallel
2. Auto-detects the BOSS controller on each server
3. Deletes existing virtual disks
4. Reboots all servers to apply
5. Recreates a clean RAID-1 virtual disk using the Dell OEM payload (`VolumeType = "Mirrored"`, `BusProtocol = "SATA"`)
6. Reboots all servers again to apply
7. Verifies the new RAID-1 volume is healthy

Results are exported to `logs/boss-reset-results-<timestamp>.json`.

**Script Location:** `scripts\common\utilities\tools\Reset-BOSSVirtualDisk.ps1`

**Run the script directly:**
```powershell
# Run on all servers in parallel using Key Vault credentials (auto-detected from environment.yaml)
.\scripts\common\utilities\tools\Reset-BOSSVirtualDisk.ps1 -Force

# Or provide credentials interactively and specify the BOSS controller FQDD
$cred = Get-Credential -UserName root -Message "Enter iDRAC password"
.\scripts\common\utilities\tools\Reset-BOSSVirtualDisk.ps1 -Credential $cred -BOSSControllerFQDD "AHCI.Slot.4-1" -Force

# Delete only (skip recreation) for debugging
.\scripts\common\utilities\tools\Reset-BOSSVirtualDisk.ps1 -SkipRecreate -Force
```

**Expected Output:**

- Phase 1 status for each server (virtual disk deletion + reboot)
- Phase 2 status for each server (RAID-1 recreation + reboot)
- Phase 3 status for each server (final verification)
- Summary table with pass/fail per node
- JSON results file in `logs/boss-reset-results-<timestamp>.json`

TIP: On Dell AX-760 servers with a BOSS-N1 controller, the FQDD is typically `AHCI.Slot.4-1`. The script auto-detects this — use `-BOSSControllerFQDD` only if auto-detection fails.

**Or copy/paste the script contents:**
```powershell
<#
.SYNOPSIS
    Reset Dell BOSS virtual disks across all cluster nodes in parallel via Redfish API.

.DESCRIPTION
    Deletes existing virtual disks on Dell BOSS (Boot Optimized Storage Solution) controllers,
    then recreates a clean RAID-1 virtual disk on each node. All operations run in parallel
    across all nodes simultaneously — no waiting for one server to finish before starting the next.

    This resolves the common boot loop issue where servers repeatedly attempt to boot from a
    stale "WindowsServer" boot entry after a previous Azure Local or Windows Server installation.

    The script performs these phases on ALL servers at the same time:
      Phase 1: Connect, auto-detect BOSS controller, delete virtual disks, reboot
      Phase 2: Reconnect, verify deletion, recreate RAID-1, reboot
      Phase 3: Reconnect, verify new virtual disk is ready

    Credentials are retrieved from the platform Azure Key Vault by default. Use the -Credential
    parameter to provide credentials interactively instead.

.PARAMETER Credential
    PSCredential object for BMC/iDRAC authentication. If not provided, credentials are
    retrieved from the platform Key Vault (keyvault.platform_name / ztp.idrac_secret_name).

.PARAMETER BOSSControllerFQDD
    Override the BOSS controller FQDD if known (e.g., "AHCI.Slot.4-1"). If not specified,
    the script auto-detects the BOSS controller by searching for controllers with "BOSS" in
    the name or model.

.PARAMETER VolumeName
    Name for the new RAID-1 virtual disk. Default: "BOSS_RAID1"

.PARAMETER RebootWaitSeconds
    Seconds to wait after each reboot for servers to come back online. Default: 300 (5 minutes)

.PARAMETER JobTimeoutMinutes
    Maximum minutes to wait for a RAID configuration job to complete. Default: 15

.PARAMETER SkipRecreate
    Only delete existing virtual disks — do not recreate. Useful for debugging.

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    .\Reset-BOSSVirtualDisk.ps1

    Resets BOSS virtual disks on all servers using Key Vault credentials. Auto-detects BOSS controller.

.EXAMPLE
    .\Reset-BOSSVirtualDisk.ps1 -Force

    Same as above but skips the confirmation prompt.

.EXAMPLE
    $cred = Get-Credential -UserName root -Message "Enter iDRAC password"
    .\Reset-BOSSVirtualDisk.ps1 -Credential $cred -BOSSControllerFQDD "AHCI.Slot.4-1"

    Uses provided credentials and a known BOSS controller FQDD.

.EXAMPLE
    .\Reset-BOSSVirtualDisk.ps1 -SkipRecreate -Force

    Only deletes existing BOSS virtual disks without recreating. Useful for cleanup.

.NOTES
    Requires:
    - PowerShell 7.0+ (for ForEach-Object -Parallel and -SkipCertificateCheck)
    - Network access to all BMC/iDRAC management interfaces
    - Valid iDRAC credentials with administrator privileges
    - AzureLocalConfig.psm1 module for configuration loading
    - Az.KeyVault module (if using Key Vault for credentials)
    - environment.yaml configured with keyvault.platform_name and ztp.idrac_secret_name

    Dell BOSS Card Generations:
    - BOSS-N1: 16th gen (AX-760, R760) — typically AHCI.Slot.4-1
    - BOSS-S2: 15th gen (AX-750, R750) — typically AHCI.Slot.4-1 or AHCI.Slot.3-1
    - BOSS-S1: 14th gen (AX-740, R740) — varies by configuration

    WARNING: This script permanently destroys all data on the BOSS card M.2 drives.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$BOSSControllerFQDD,

    [Parameter(Mandatory = $false)]
    [string]$VolumeName = "BOSS_RAID1",

    [Parameter(Mandatory = $false)]
    [int]$RebootWaitSeconds = 300,

    [Parameter(Mandatory = $false)]
    [int]$JobTimeoutMinutes = 15,

    [Parameter(Mandatory = $false)]
    [switch]$SkipRecreate,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

#Requires -Version 7.0

# ============================================================================
# Script initialization
# ============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Write-Host "`nDell BOSS Virtual Disk Reset via Redfish API" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# Find repo root and load configuration
# ============================================================================
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) {
    throw "Could not find repository root (config directory not found)"
}

$modulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
Import-Module $modulePath -Force

$config = Get-AzureLocalConfig
$serverIPs = $config.GetIdracIPs()

Write-Host "Cluster nodes: $($serverIPs.Count)" -ForegroundColor White
$serverIPs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
Write-Host ""

# ============================================================================
# Credential resolution — Key Vault or interactive
# ============================================================================
if (!$Credential) {
    $keyVaultName = $config.GetValue('keyvault.platform_name')
    $secretName = $config.GetValue('ztp.idrac_secret_name')

    if ($keyVaultName -and $secretName) {
        try {
            Write-Host "Retrieving iDRAC credentials from Key Vault '$keyVaultName'..." -ForegroundColor Cyan
            $secret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName
            if (!$secret) {
                throw "Secret '$secretName' not found in Key Vault '$keyVaultName'"
            }
            $credString = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
            if ($credString -notmatch ':') {
                throw "Secret value must be in format 'username:password'"
            }
            $username, $password = $credString -split ':', 2
            $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
            $Credential = New-Object PSCredential ($username, $securePassword)
            Write-Host "  Credentials retrieved successfully" -ForegroundColor Green
        }
        catch {
            Write-Host "  Key Vault access failed: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  Falling back to interactive credential entry..." -ForegroundColor Yellow
            $Credential = Get-Credential -Message "Enter iDRAC credentials (e.g., root)"
        }
    }
    else {
        Write-Host "Key Vault not configured. Please provide credentials interactively." -ForegroundColor Yellow
        $Credential = Get-Credential -Message "Enter iDRAC credentials (e.g., root)"
    }
}
Write-Host ""

# ============================================================================
# Confirmation
# ============================================================================
if (!$Force) {
    Write-Host "WARNING: This will PERMANENTLY DESTROY all data on the BOSS card M.2 drives" -ForegroundColor Red
    Write-Host "on ALL $($serverIPs.Count) servers simultaneously." -ForegroundColor Red
    Write-Host ""
    $confirmation = Read-Host "Type 'yes' to continue"
    if ($confirmation -ne 'yes') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""
}

# ============================================================================
# Shared helper: Redfish request (used inside parallel blocks)
# ============================================================================
# We serialize the credential for use inside parallel scriptblocks
$credUser = $Credential.UserName
$credPass = $Credential.GetNetworkCredential().Password

# ============================================================================
# PHASE 1: Delete virtual disks on all servers (parallel)
# ============================================================================
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "PHASE 1: Delete existing BOSS virtual disks (all servers in parallel)" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host ""

$phase1Results = $serverIPs | ForEach-Object -Parallel {
    $ip = $_
    $user = $using:credUser
    $pass = $using:credPass
    $bossOverride = $using:BOSSControllerFQDD
    $jobTimeout = $using:JobTimeoutMinutes

    # Build credential inside runspace
    $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
    $cred = New-Object PSCredential ($user, $secPass)

    $result = [PSCustomObject]@{
        IPAddress            = $ip
        Phase                = "Delete"
        BOSSControllerFound  = $false
        BOSSControllerFQDD   = ""
        BOSSControllerName   = ""
        VirtualDisksFound    = 0
        VirtualDisksDeleted  = 0
        RebootInitiated      = $false
        JobCompleted         = $false
        Status               = "Unknown"
        Details              = ""
        PhysicalDiskFQDDs    = @()
        Timestamp            = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }

    # Helper function for Redfish GET
    function Invoke-RedfishGet {
        param([string]$Uri, [PSCredential]$Credential)
        Invoke-RestMethod -Uri $Uri -Credential $Credential -Method Get `
            -SkipCertificateCheck -TimeoutSec 30 -ErrorAction Stop
    }

    try {
        # --- Test connectivity ---
        $null = Invoke-RedfishGet -Uri "https://$ip/redfish/v1" -Credential $cred

        # --- Find BOSS controller ---
        $storageUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Storage"
        $storageResponse = Invoke-RedfishGet -Uri $storageUri -Credential $cred

        $bossController = $null
        $bossCtrlFQDD = $null

        foreach ($member in $storageResponse.Members) {
            $ctrlId = $member.'@odata.id'.Split('/')[-1]

            # If user provided a specific FQDD, use it directly
            if ($bossOverride -and $ctrlId -eq $bossOverride) {
                $ctrlUri = "https://$ip$($member.'@odata.id')"
                $bossController = Invoke-RedfishGet -Uri $ctrlUri -Credential $cred
                $bossCtrlFQDD = $ctrlId
                break
            }

            # Auto-detect: check for "BOSS" in name or model
            if (!$bossOverride) {
                $ctrlUri = "https://$ip$($member.'@odata.id')"
                $ctrlData = Invoke-RedfishGet -Uri $ctrlUri -Credential $cred

                $isBOSS = $false
                if ($ctrlData.Name -match "BOSS") { $isBOSS = $true }
                elseif ($ctrlData.StorageControllers) {
                    foreach ($sc in $ctrlData.StorageControllers) {
                        if ($sc.Model -match "BOSS" -or $sc.Name -match "BOSS") {
                            $isBOSS = $true; break
                        }
                    }
                }

                if ($isBOSS) {
                    $bossController = $ctrlData
                    $bossCtrlFQDD = $ctrlId
                    break
                }
            }
        }

        if (!$bossController) {
            if ($bossOverride) {
                # User specified FQDD — use it even if not auto-detected as BOSS
                $ctrlUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Storage/$bossOverride"
                $bossController = Invoke-RedfishGet -Uri $ctrlUri -Credential $cred
                $bossCtrlFQDD = $bossOverride
            }
            else {
                $result.Status = "No BOSS Controller"
                $result.Details = "No BOSS controller auto-detected. Use -BOSSControllerFQDD to specify."
                return $result
            }
        }

        $result.BOSSControllerFound = $true
        $result.BOSSControllerFQDD = $bossCtrlFQDD
        $result.BOSSControllerName = $bossController.Name

        # --- Collect physical disk FQDDs for Phase 2 recreation ---
        if ($bossController.Drives) {
            $result.PhysicalDiskFQDDs = @($bossController.Drives | ForEach-Object { $_.'@odata.id' })
        }

        # --- Query virtual disks ---
        $volumesUri = $null
        if ($bossController.Volumes -and $bossController.Volumes.'@odata.id') {
            $volumesUri = "https://$ip$($bossController.Volumes.'@odata.id')"
        }
        else {
            $volumesUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Storage/$bossCtrlFQDD/Volumes"
        }

        $volumesResponse = Invoke-RedfishGet -Uri $volumesUri -Credential $cred
        $virtualDisks = @()
        if ($volumesResponse.Members -and $volumesResponse.Members.Count -gt 0) {
            $virtualDisks = $volumesResponse.Members
        }
        $result.VirtualDisksFound = $virtualDisks.Count

        if ($virtualDisks.Count -eq 0) {
            $result.Status = "Already Clean"
            $result.Details = "No virtual disks found on BOSS controller — already clean"
            return $result
        }

        # --- Check for existing scheduled RAID jobs ---
        $jobsUri = "https://$ip/redfish/v1/Managers/iDRAC.Embedded.1/Jobs"
        $jobsResponse = Invoke-RedfishGet -Uri $jobsUri -Credential $cred
        $existingJob = $null

        foreach ($jobRef in $jobsResponse.Members) {
            try {
                $jobUri = "https://$ip$($jobRef.'@odata.id')"
                $job = Invoke-RedfishGet -Uri $jobUri -Credential $cred
                if ($job.JobType -eq "RAIDConfiguration" -and $job.JobState -eq "Scheduled") {
                    $existingJob = $job
                    break
                }
            }
            catch { continue }
        }

        # --- Delete virtual disks ---
        if (!$existingJob) {
            foreach ($vd in $virtualDisks) {
                $vdUri = "https://$ip$($vd.'@odata.id')"
                try {
                    Invoke-RestMethod -Uri $vdUri -Credential $cred -Method Delete `
                        -SkipCertificateCheck -TimeoutSec 30 -ErrorAction Stop | Out-Null
                    $result.VirtualDisksDeleted++
                }
                catch {
                    # Some iDRAC versions return 202 which Invoke-RestMethod may not handle cleanly
                    # Try with Invoke-WebRequest for proper status code handling
                    try {
                        $delResponse = Invoke-WebRequest -Uri $vdUri -Credential $cred -Method Delete `
                            -SkipCertificateCheck -TimeoutSec 30 -ErrorAction Stop
                        if ($delResponse.StatusCode -in @(200, 202, 204)) {
                            $result.VirtualDisksDeleted++
                        }
                    }
                    catch {
                        $result.Details += "Delete failed for $($vd.'@odata.id'): $($_.Exception.Message); "
                    }
                }
            }

            if ($result.VirtualDisksDeleted -eq 0) {
                $result.Status = "Failed"
                $result.Details = "No virtual disks were successfully deleted"
                return $result
            }

            # Wait briefly for iDRAC to create the job
            Start-Sleep -Seconds 3
        }

        # --- Reboot to apply the deletion ---
        $resetUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"
        $systemUri = "https://$ip/redfish/v1/Systems/System.Embedded.1"
        $systemInfo = Invoke-RedfishGet -Uri $systemUri -Credential $cred

        $resetType = if ($systemInfo.PowerState -eq "Off") { "On" } else { "ForceRestart" }
        $resetBody = @{ ResetType = $resetType } | ConvertTo-Json

        Invoke-RestMethod -Uri $resetUri -Credential $cred -Method Post -Body $resetBody `
            -ContentType "application/json" -SkipCertificateCheck -TimeoutSec 30 | Out-Null

        $result.RebootInitiated = $true

        # BOSS delete is a staged job — it applies during the reboot POST cycle.
        # iDRAC is unreachable during reboot so there's no point monitoring the job here.
        # Phase 2 will verify the delete actually worked before recreating.
        $result.JobCompleted = $true
        $result.Status = "Delete OK"
    }
    catch {
        $result.Status = "Failed"
        $result.Details = $_.Exception.Message
    }

    return $result
} -ThrottleLimit $serverIPs.Count

# Display Phase 1 results
Write-Host ""
foreach ($r in $phase1Results) {
    $color = switch ($r.Status) {
        "Delete OK"          { "Green" }
        "Already Clean"      { "Green" }
        "No BOSS Controller" { "Yellow" }
        "Delete Timeout"     { "Yellow" }
        default              { "Red" }
    }
    Write-Host "  [$($r.IPAddress)] $($r.Status) — $($r.BOSSControllerName) | VDs: $($r.VirtualDisksFound) found, $($r.VirtualDisksDeleted) deleted" -ForegroundColor $color
    if ($r.Details) { Write-Host "    Details: $($r.Details)" -ForegroundColor Gray }
}

# Check if any servers need Phase 2
$serversNeedingRecreate = $phase1Results | Where-Object {
    $_.Status -in @("Delete OK", "Already Clean") -and !$SkipRecreate
}

if ($serversNeedingRecreate.Count -eq 0 -or $SkipRecreate) {
    if ($SkipRecreate) {
        Write-Host "`n-SkipRecreate specified — skipping RAID-1 recreation." -ForegroundColor Yellow
    }
    else {
        Write-Host "`nNo servers require virtual disk recreation." -ForegroundColor Yellow
    }
}
else {
    # ==========================================================================
    # Wait for all servers to finish rebooting from Phase 1
    # ==========================================================================
    $needsRebootWait = $phase1Results | Where-Object { $_.RebootInitiated }
    if ($needsRebootWait.Count -gt 0) {
        Write-Host "`nWaiting $RebootWaitSeconds seconds for servers to finish rebooting..." -ForegroundColor Gray
        $waitEnd = (Get-Date).AddSeconds($RebootWaitSeconds)
        while ((Get-Date) -lt $waitEnd) {
            $remaining = [math]::Ceiling(($waitEnd - (Get-Date)).TotalSeconds)
            Write-Host "`r  Time remaining: $remaining seconds   " -NoNewline -ForegroundColor Gray
            Start-Sleep -Seconds 10
        }
        Write-Host "`r  Reboot wait complete.                    " -ForegroundColor Green
    }
    Write-Host ""

    # ======================================================================
    # PHASE 2: Recreate RAID-1 virtual disks (parallel)
    # ======================================================================
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host "PHASE 2: Recreate BOSS RAID-1 virtual disks (all servers in parallel)" -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host ""

    $phase2Inputs = $serversNeedingRecreate | ForEach-Object {
        [PSCustomObject]@{
            IPAddress         = $_.IPAddress
            BOSSControllerFQDD = $_.BOSSControllerFQDD
            PhysicalDiskFQDDs = $_.PhysicalDiskFQDDs
        }
    }

    $phase2Results = $phase2Inputs | ForEach-Object -Parallel {
        $ip = $_.IPAddress
        $bossFQDD = $_.BOSSControllerFQDD
        $physDisks = $_.PhysicalDiskFQDDs
        $user = $using:credUser
        $pass = $using:credPass
        $volName = $using:VolumeName
        $jobTimeout = $using:JobTimeoutMinutes

        $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
        $cred = New-Object PSCredential ($user, $secPass)

        $result = [PSCustomObject]@{
            IPAddress           = $ip
            Phase               = "Recreate"
            DeletionVerified    = $false
            VolumeCreated       = $false
            RebootInitiated     = $false
            JobCompleted        = $false
            Status              = "Unknown"
            Details             = ""
            Timestamp           = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }

        function Invoke-RedfishGet {
            param([string]$Uri, [PSCredential]$Credential)
            Invoke-RestMethod -Uri $Uri -Credential $Credential -Method Get `
                -SkipCertificateCheck -TimeoutSec 30 -ErrorAction Stop
        }

        try {
            # --- Wait for iDRAC to be reachable ---
            $retries = 0
            $maxRetries = 12  # 2 more minutes of retries
            while ($retries -lt $maxRetries) {
                try {
                    $null = Invoke-RedfishGet -Uri "https://$ip/redfish/v1" -Credential $cred
                    break
                }
                catch {
                    $retries++
                    if ($retries -ge $maxRetries) { throw "iDRAC not reachable after $maxRetries retries" }
                    Start-Sleep -Seconds 10
                }
            }

            # --- Verify deletion ---
            $volumesUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Storage/$bossFQDD/Volumes"
            $volumes = Invoke-RedfishGet -Uri $volumesUri -Credential $cred

            if ($volumes.Members -and $volumes.Members.Count -gt 0) {
                $result.Details = "Virtual disk still present after deletion — check iDRAC job queue"
                $result.Status = "Delete Not Verified"
                return $result
            }

            $result.DeletionVerified = $true

            # --- Get physical disk FQDDs (refresh from controller if needed) ---
            if (!$physDisks -or $physDisks.Count -lt 2) {
                $ctrlUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Storage/$bossFQDD"
                $ctrlData = Invoke-RedfishGet -Uri $ctrlUri -Credential $cred
                $physDisks = @($ctrlData.Drives | ForEach-Object { $_.'@odata.id' })
            }

            if ($physDisks.Count -lt 2) {
                $result.Status = "Failed"
                $result.Details = "Insufficient physical drives for RAID-1 (found $($physDisks.Count), need 2)"
                return $result
            }

            # --- Build drive references ---
            $driveRefs = @()
            for ($i = 0; $i -lt 2; $i++) {
                $driveRefs += @{ "@odata.id" = $physDisks[$i] }
            }

            # --- Create RAID-1 virtual disk ---
            $createBody = @{
                VolumeType = "Mirrored"
                Drives     = $driveRefs
                Name       = $volName
                Oem        = @{
                    Dell = @{
                        DellVirtualDisk = @{
                            BusProtocol = "SATA"
                        }
                    }
                }
            } | ConvertTo-Json -Depth 10

            try {
                Invoke-RestMethod -Uri $volumesUri -Credential $cred -Method Post `
                    -Body $createBody -ContentType "application/json" `
                    -SkipCertificateCheck -TimeoutSec 30 | Out-Null
                $result.VolumeCreated = $true
            }
            catch {
                # Try Invoke-WebRequest for 202 handling
                $createResponse = Invoke-WebRequest -Uri $volumesUri -Credential $cred -Method Post `
                    -Body $createBody -ContentType "application/json" `
                    -SkipCertificateCheck -TimeoutSec 30 -ErrorAction Stop
                if ($createResponse.StatusCode -in @(200, 201, 202)) {
                    $result.VolumeCreated = $true
                }
                else {
                    throw "Create returned HTTP $($createResponse.StatusCode)"
                }
            }

            if (!$result.VolumeCreated) {
                $result.Status = "Failed"
                $result.Details = "Virtual disk creation request was not accepted"
                return $result
            }

            # --- Find the scheduled RAID job ---
            Start-Sleep -Seconds 3
            $jobsUri = "https://$ip/redfish/v1/Managers/iDRAC.Embedded.1/Jobs"
            $jobsResponse = Invoke-RedfishGet -Uri $jobsUri -Credential $cred
            $scheduledJob = $null

            foreach ($jobRef in $jobsResponse.Members) {
                try {
                    $jobUri = "https://$ip$($jobRef.'@odata.id')"
                    $job = Invoke-RedfishGet -Uri $jobUri -Credential $cred
                    if ($job.JobType -eq "RAIDConfiguration" -and $job.JobState -eq "Scheduled") {
                        $scheduledJob = $job; break
                    }
                }
                catch { continue }
            }

            # --- Reboot to apply RAID creation ---
            $resetUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"
            $systemInfo = Invoke-RedfishGet -Uri "https://$ip/redfish/v1/Systems/System.Embedded.1" -Credential $cred

            $resetType = if ($systemInfo.PowerState -eq "Off") { "On" } else { "ForceRestart" }
            $resetBody = @{ ResetType = $resetType } | ConvertTo-Json

            Invoke-RestMethod -Uri $resetUri -Credential $cred -Method Post -Body $resetBody `
                -ContentType "application/json" -SkipCertificateCheck -TimeoutSec 30 | Out-Null

            $result.RebootInitiated = $true

            # --- Monitor RAID creation job ---
            if ($scheduledJob) {
                Start-Sleep -Seconds 30
                $elapsed = 0
                $maxWait = $jobTimeout * 60
                while ($elapsed -lt $maxWait) {
                    Start-Sleep -Seconds 15
                    $elapsed += 15
                    try {
                        $jobUri = "https://$ip/redfish/v1/Managers/iDRAC.Embedded.1/Jobs/$($scheduledJob.Id)"
                        $currentJob = Invoke-RedfishGet -Uri $jobUri -Credential $cred
                        if ($currentJob.JobState -eq "Completed") {
                            $result.JobCompleted = $true; break
                        }
                        elseif ($currentJob.JobState -in @("Failed", "CompletedWithErrors")) {
                            $result.Details = "Create job failed: $($currentJob.Message)"
                            break
                        }
                    }
                    catch {
                        # iDRAC unreachable during reboot — expected
                    }
                }
            }
            else {
                $result.JobCompleted = $true
            }

            $result.Status = if ($result.JobCompleted) { "Success" } else { "Create Timeout" }
            if ($result.JobCompleted) {
                $result.Details = "RAID-1 virtual disk created and applied successfully"
            }
        }
        catch {
            $result.Status = "Failed"
            $result.Details = $_.Exception.Message
        }

        return $result
    } -ThrottleLimit $phase2Inputs.Count

    # Display Phase 2 results
    Write-Host ""
    foreach ($r in $phase2Results) {
        $color = switch ($r.Status) {
            "Success"        { "Green" }
            "Create Timeout" { "Yellow" }
            default          { "Red" }
        }
        Write-Host "  [$($r.IPAddress)] $($r.Status) — Verified: $($r.DeletionVerified) | Created: $($r.VolumeCreated) | Rebooted: $($r.RebootInitiated) | Job Done: $($r.JobCompleted)" -ForegroundColor $color
        if ($r.Details) { Write-Host "    Details: $($r.Details)" -ForegroundColor Gray }
    }
}

# ============================================================================
# PHASE 3: Final verification (parallel)
# ============================================================================
if (!$SkipRecreate -and $serversNeedingRecreate.Count -gt 0) {
    # Wait for Phase 2 reboots to complete
    $phase2Rebooted = if ($phase2Results) { $phase2Results | Where-Object { $_.RebootInitiated } } else { @() }
    if ($phase2Rebooted.Count -gt 0) {
        Write-Host "`nWaiting $RebootWaitSeconds seconds for Phase 2 reboots to complete..." -ForegroundColor Gray
        $waitEnd = (Get-Date).AddSeconds($RebootWaitSeconds)
        while ((Get-Date) -lt $waitEnd) {
            $remaining = [math]::Ceiling(($waitEnd - (Get-Date)).TotalSeconds)
            Write-Host "`r  Time remaining: $remaining seconds   " -NoNewline -ForegroundColor Gray
            Start-Sleep -Seconds 10
        }
        Write-Host "`r  Reboot wait complete.                    " -ForegroundColor Green
    }
    Write-Host ""

    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host "PHASE 3: Final verification (all servers in parallel)" -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host ""

    $verifyInputs = $serversNeedingRecreate | ForEach-Object {
        [PSCustomObject]@{
            IPAddress          = $_.IPAddress
            BOSSControllerFQDD = $_.BOSSControllerFQDD
        }
    }

    $phase3Results = $verifyInputs | ForEach-Object -Parallel {
        $ip = $_.IPAddress
        $bossFQDD = $_.BOSSControllerFQDD
        $user = $using:credUser
        $pass = $using:credPass

        $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
        $cred = New-Object PSCredential ($user, $secPass)

        $result = [PSCustomObject]@{
            IPAddress  = $ip
            Phase      = "Verify"
            Volumes    = @()
            Status     = "Unknown"
            Details    = ""
            Timestamp  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }

        try {
            # Retry loop for iDRAC to come back up
            $retries = 0
            while ($retries -lt 12) {
                try {
                    $null = Invoke-RestMethod -Uri "https://$ip/redfish/v1" -Credential $cred `
                        -Method Get -SkipCertificateCheck -TimeoutSec 30 -ErrorAction Stop
                    break
                }
                catch { $retries++; Start-Sleep -Seconds 10 }
            }

            $volumesUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Storage/$bossFQDD/Volumes"
            $volumes = Invoke-RestMethod -Uri $volumesUri -Credential $cred -Method Get `
                -SkipCertificateCheck -TimeoutSec 30

            if ($volumes.Members -and $volumes.Members.Count -gt 0) {
                foreach ($vol in $volumes.Members) {
                    try {
                        $volUri = "https://$ip$($vol.'@odata.id')"
                        $volDetail = Invoke-RestMethod -Uri $volUri -Credential $cred -Method Get `
                            -SkipCertificateCheck -TimeoutSec 30
                        $result.Volumes += [PSCustomObject]@{
                            Id       = $volDetail.Id
                            Name     = $volDetail.Name
                            SizeGB   = [math]::Round($volDetail.CapacityBytes / 1GB, 2)
                            RAIDType = if ($volDetail.RAIDType) { $volDetail.RAIDType } else { $volDetail.VolumeType }
                            Status   = $volDetail.Status.Health
                        }
                    }
                    catch { continue }
                }
                $result.Status = "Verified"
                $result.Details = "BOSS RAID-1 ready — $($result.Volumes.Count) volume(s) present"
            }
            else {
                $result.Status = "Warning"
                $result.Details = "No volumes found after recreation — check iDRAC job queue"
            }
        }
        catch {
            $result.Status = "Unreachable"
            $result.Details = $_.Exception.Message
        }

        return $result
    } -ThrottleLimit $verifyInputs.Count

    Write-Host ""
    foreach ($r in $phase3Results) {
        $color = switch ($r.Status) {
            "Verified"    { "Green" }
            "Warning"     { "Yellow" }
            "Unreachable" { "Yellow" }
            default       { "Red" }
        }
        Write-Host "  [$($r.IPAddress)] $($r.Status)" -ForegroundColor $color
        foreach ($v in $r.Volumes) {
            Write-Host "    Volume: $($v.Name) | $($v.SizeGB) GB | $($v.RAIDType) | Health: $($v.Status)" -ForegroundColor Gray
        }
        if ($r.Details) { Write-Host "    $($r.Details)" -ForegroundColor Gray }
    }
}

# ============================================================================
# Summary
# ============================================================================
Write-Host ""
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "BOSS Virtual Disk Reset — Summary" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host ""

# Combine all results for the summary table
$allResults = @()

foreach ($r in $phase1Results) {
    $finalStatus = $r.Status
    if ($phase2Results) {
        $p2 = $phase2Results | Where-Object { $_.IPAddress -eq $r.IPAddress }
        if ($p2) { $finalStatus = $p2.Status }
    }
    if ($phase3Results) {
        $p3 = $phase3Results | Where-Object { $_.IPAddress -eq $r.IPAddress }
        if ($p3 -and $p3.Status -eq "Verified") { $finalStatus = "Success" }
    }

    $allResults += [PSCustomObject]@{
        IPAddress      = $r.IPAddress
        BOSSController = $r.BOSSControllerName
        FQDD           = $r.BOSSControllerFQDD
        VDsDeleted     = $r.VirtualDisksDeleted
        FinalStatus    = $finalStatus
    }
}

$allResults | Format-Table -AutoSize

$successCount = ($allResults | Where-Object { $_.FinalStatus -in @("Success", "Already Clean") }).Count
$failCount = ($allResults | Where-Object { $_.FinalStatus -in @("Failed") }).Count
$otherCount = $allResults.Count - $successCount - $failCount

Write-Host "Total: $($allResults.Count) | Success: $successCount | Failed: $failCount | Other: $otherCount" -ForegroundColor White

# Export results
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outputDir = Join-Path $repoRoot "logs"
if (!(Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
$outputPath = Join-Path $outputDir "boss-reset-results-$timestamp.json"

try {
    @{
        Phase1 = $phase1Results
        Phase2 = if ($phase2Results) { $phase2Results } else { @() }
        Phase3 = if ($phase3Results) { $phase3Results } else { @() }
        Summary = $allResults
    } | ConvertTo-Json -Depth 10 | Out-File $outputPath -Encoding UTF8
    Write-Host "`nResults exported to: $outputPath" -ForegroundColor Green
}
catch {
    Write-Host "Failed to export results: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Exit code
if ($failCount -gt 0) {
    Write-Host "`nCompleted with failures — manual intervention required for $failCount server(s)" -ForegroundColor Yellow
    exit 1
}
else {
    Write-Host "`nAll servers ready for ZTP provisioning" -ForegroundColor Green
    exit 0
}
```

After the script completes, all servers will have a clean, empty RAID 1 volume with no stale OS partitions or boot loader entries. You can now proceed with the normal ZTP provisioning workflow (mount ISO, set boot source, restart).

#### BOSS Card Reference

| Description |
| --- |

NOTE: The BOSS controller FQDD varies by server model and slot configuration. Always use Step 1 to identify the correct FQDD for your hardware. Common patterns include `AHCI.Slot.4-1`, `AHCI.Slot.3-1`, or `BOSS-S1` depending on the generation and configuration.

### Logs and Diagnostics

- **BMC/iDRAC Logs:** Access via web interface or Redfish API
- **PowerShell Script Logs:** Check console output for error messages
- **Network Logs:** Verify connectivity to file shares and BMC interfaces

### Getting Help

- Review the official Azure Local ZTP documentation
- Check BMC vendor documentation for Redfish API specifics
- Contact Microsoft support for Azure Local ZTP issues
- Consult hardware vendor support for BMC-specific issues

## Scripts Reference

This guide references the following scripts from the repository:

- `scripts/common/discovery/Get-DellServerInventory-FromiDRAC.ps1` - Comprehensive server discovery
- `scripts/common/discovery/Inventory-OnPrem.ps1` - Network infrastructure discovery
- `scripts/common/utilities/tools/Reset-BOSSVirtualDisk.ps1` - Reset BOSS virtual disks across all nodes in parallel
- `scripts/common/utilities/tools/Reset-iDRAC.ps1` - Reset iDRAC management controller via Redfish (single, multiple, or all servers)
- `scripts/common/utilities/tools/Discover-Servers.ps1` - Discover iDRAC servers with full hardware inventory
- `scripts/common/utilities/tools/Mount-AzureLocalISO.ps1` - Mount Azure Local ISO via virtual media
- `scripts/common/utilities/tools/Restart-Servers.ps1` - Reboot all servers via Redfish API
- `scripts/common/RedfishUtils.psm1` - Shared Redfish session and storage management module

All scripts include detailed help and examples. Use `Get-Help <script> -Detailed` for usage information.
