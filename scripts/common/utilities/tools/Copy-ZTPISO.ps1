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