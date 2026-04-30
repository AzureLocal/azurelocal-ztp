<#
.SYNOPSIS
    Creates Azure resource group for Azure Local deployment.

.DESCRIPTION
    Creates a dedicated resource group for Azure Local ZTP deployment
    using configuration values from environment.yaml.
    Uses Az PowerShell module (not Azure CLI) for authentication consistency.

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
    - Az.Accounts and Az.Resources modules
    - Authenticated via Connect-AzAccount / Get-AzContext
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
$subscriptionId = $config.GetValue('azure.mgmt_subscription_id')
$resourceGroup = $config.GetValue('resources.cluster_resource_group')
$region = $config.GetValue('azure.region')

# Verify Az context
$currentContext = Get-AzContext
if (-not $currentContext) {
    throw "No Azure context found. Run 'Connect-AzAccount' first."
}

# Confirm operation if not forced
if (!$Force) {
    Write-Host "About to create resource group:" -ForegroundColor Yellow
    Write-Host "  Subscription: $subscriptionId" -ForegroundColor Gray
    Write-Host "  Resource Group: $resourceGroup" -ForegroundColor Gray
    Write-Host "  Region: $region" -ForegroundColor Gray
    Write-Host "  Current Az Context: $($currentContext.Subscription.Id) ($($currentContext.Subscription.Name))" -ForegroundColor Gray
    Write-Host ""

    $confirmation = Read-Host "Continue? (y/N)"
    if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# Set subscription context if needed
if ($currentContext.Subscription.Id -ne $subscriptionId) {
    Write-Host "Switching Az context to subscription $subscriptionId..." -ForegroundColor Cyan
    try {
        Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null
    } catch {
        throw "Failed to set Azure subscription context: $_`nRun 'Connect-AzAccount -TenantId <your-tenant-id>' and try again."
    }
} else {
    Write-Host "Az context already set to $subscriptionId" -ForegroundColor Cyan
}

# Check if resource group already exists
$existingRg = Get-AzResourceGroup -Name $resourceGroup -ErrorAction SilentlyContinue
if ($existingRg) {
    Write-Host "✓ Resource group '$resourceGroup' already exists in '$($existingRg.Location)'" -ForegroundColor Green
    return
}

Write-Host "Creating resource group '$resourceGroup' in '$region'..." -ForegroundColor Cyan
try {
    $rg = New-AzResourceGroup -Name $resourceGroup -Location $region -ErrorAction Stop
} catch {
    throw "Failed to create resource group: $_"
}

Write-Host "✓ Resource group '$resourceGroup' created successfully in '$($rg.Location)'" -ForegroundColor Green