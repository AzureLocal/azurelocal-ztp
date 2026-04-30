<#
.SYNOPSIS
    Verifies Azure Local ZTP cluster configuration.

.DESCRIPTION
    Tests that the current Azure context matches the expected cluster configuration
    loaded from environment.yaml.

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    .\Test-ZTPConfig.ps1

    Verifies cluster configuration

.EXAMPLE
    .\Test-ZTPConfig.ps1 -Force

    Verifies without confirmation

.NOTES
    Requires:
    - PowerShell 7.0+
    - Azure PowerShell module (Az)
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

Write-Host "Verifying Azure Local ZTP cluster configuration..." -ForegroundColor Cyan

# Get current Azure context
$context = Get-AzContext
if (!$context) {
    Write-Host "✗ No Azure context found. Please run Connect-AzAccount to login." -ForegroundColor Red
    exit 1
}

Write-Host "Current Azure Context:" -ForegroundColor Gray
Write-Host "  Account: $($context.Account.Id)" -ForegroundColor Cyan
Write-Host "  Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))" -ForegroundColor Cyan
Write-Host "  Tenant: $($context.Tenant.Id)" -ForegroundColor Cyan

# Expected values from config
$expectedSubscriptionId = $config.GetValue('azure.mgmt_subscription_id')
$expectedTenantId = $config.GetValue('azure.tenant_id')
$expectedResourceGroup = $config.GetValue('resources.cluster_resource_group')
$expectedClusterName = $config.GetValue('resources.cluster_name')

Write-Host ""
Write-Host "Expected Configuration:" -ForegroundColor Gray
Write-Host "  Subscription ID: $expectedSubscriptionId" -ForegroundColor Gray
Write-Host "  Tenant ID: $expectedTenantId" -ForegroundColor Gray
Write-Host "  Resource Group: $expectedResourceGroup" -ForegroundColor Gray
Write-Host "  Cluster Name: $expectedClusterName" -ForegroundColor Gray

# Verify matches
$allGood = $true

if ($context.Subscription.Id -ne $expectedSubscriptionId) {
    Write-Host "✗ Subscription ID mismatch!" -ForegroundColor Red
    $allGood = $false
} else {
    Write-Host "✓ Subscription ID matches" -ForegroundColor Green
}

if ($context.Tenant.Id -ne $expectedTenantId) {
    Write-Host "✗ Tenant ID mismatch!" -ForegroundColor Red
    $allGood = $false
} else {
    Write-Host "✓ Tenant ID matches" -ForegroundColor Green
}

# Check if resource group exists
$rgExists = Get-AzResourceGroup -Name $expectedResourceGroup -ErrorAction SilentlyContinue
if ($rgExists) {
    Write-Host "✓ Resource group '$expectedResourceGroup' exists" -ForegroundColor Green
} else {
    Write-Host "⚠ Resource group '$expectedResourceGroup' does not exist yet" -ForegroundColor Yellow
}

Write-Host ""
if ($allGood) {
    Write-Host "✓ Cluster configuration verified successfully" -ForegroundColor Green
} else {
    Write-Host "✗ Configuration mismatches found. Please check your Azure context and config." -ForegroundColor Red
}