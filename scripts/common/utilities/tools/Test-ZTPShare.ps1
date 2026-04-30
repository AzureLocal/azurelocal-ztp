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