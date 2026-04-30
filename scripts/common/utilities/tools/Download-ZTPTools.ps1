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