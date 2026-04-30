<#
.SYNOPSIS
    Extracts Azure Local ZTP tools from downloaded archive.

.DESCRIPTION
    Extracts the Azure Local maintenance environment package to the configured
    extracted directory for further processing.

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    .\Extract-ZTPTools.ps1

    Extracts ZTP tools to the configured extracted directory

.EXAMPLE
    .\Extract-ZTPTools.ps1 -Force

    Extracts without confirmation

.NOTES
    Requires:
    - PowerShell 7.0+
    - Downloaded ZTP tools archive
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
$extractedDir = $config.GetValue('ztp.extracted_directory')
$zipFile = Join-Path $downloadDir "maintenance-env.zip"

# Confirm operation if not forced
if (!$Force) {
    Write-Host "About to extract Azure Local ZTP tools:" -ForegroundColor Yellow
    Write-Host "  Source: $zipFile" -ForegroundColor Gray
    Write-Host "  Destination: $extractedDir" -ForegroundColor Gray
    Write-Host ""

    $confirmation = Read-Host "Continue? (y/N)"
    if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
        Write-Host "Extraction cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# Validate source file exists
if (!(Test-Path $zipFile)) {
    throw "Source file not found: $zipFile"
}

Write-Host "Extracting maintenance environment package..." -ForegroundColor Cyan

# Use .NET ZipFile class directly to avoid Expand-Archive issues
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($zipFile, $extractedDir, $true)

Write-Host "✓ Extraction completed successfully" -ForegroundColor Green

# Verify extraction
$extractedItems = Get-ChildItem -Path $extractedDir -Recurse | Measure-Object
Write-Host "Extracted $($extractedItems.Count) files/folders to $extractedDir" -ForegroundColor Green

# List key files
$isoFile = Get-ChildItem -Path $extractedDir -Filter "*.iso" -Recurse | Select-Object -First 1
if ($isoFile) {
    Write-Host "Found ISO file: $($isoFile.FullName)" -ForegroundColor Green
}