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
$downloadFiles = Get-ChildItem -Path $downloadDir -Recurse -Include "*.zip","*.exe","*.ps1","*.cmd","*.msi","*.msix" -ErrorAction SilentlyContinue
if ($downloadFiles) {
    $downloadFiles | Unblock-File
    Write-Host "✓ Unblocked $($downloadFiles.Count) files in download directory" -ForegroundColor Green
} else {
    Write-Host "No blocked files found in download directory" -ForegroundColor Gray
}

Write-Host "Unblocking files in extracted directory..." -ForegroundColor Cyan
$extractedFiles = Get-ChildItem -Path $extractedDir -Recurse -Include "*.exe","*.ps1","*.cmd","*.iso","*.msi","*.msix" -ErrorAction SilentlyContinue
if ($extractedFiles) {
    $extractedFiles | Unblock-File
    Write-Host "✓ Unblocked $($extractedFiles.Count) files in extracted directory" -ForegroundColor Green
} else {
    Write-Host "No blocked files found in extracted directory" -ForegroundColor Gray
}

Write-Host "✓ All ZTP files have been unblocked" -ForegroundColor Green