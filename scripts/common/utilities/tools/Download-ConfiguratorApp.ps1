<#
.SYNOPSIS
    Downloads the Configurator App for Azure Local V2.

.DESCRIPTION
    Downloads the Configurator App from Microsoft official channels to the same
    download directory used for the ZTP maintenance environment tools.
    The Configurator App is used to download ownership vouchers, configure static
    IP addresses, and monitor machine provisioning progress.

.PARAMETER Force
    Skip confirmation prompts

.PARAMETER OutputPath
    Override the output file path. Defaults to the configured ZTP download directory.

.EXAMPLE
    .\Download-ConfiguratorApp.ps1

    Downloads the Configurator App to the configured download directory

.EXAMPLE
    .\Download-ConfiguratorApp.ps1 -Force

    Downloads without confirmation

.NOTES
    Requires:
    - PowerShell 7.0+
    - Internet connectivity
    - AzureLocalConfig.psm1 module for configuration loading

    Download URL: https://aka.ms/ztp/configuratorapp
#>

param(
    [Parameter(Mandatory=$false)]
    [switch]$Force,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath
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
$downloadUrl = "https://aka.ms/ztp/configuratorapp"

# Determine output path
if (-not $OutputPath) {
    $OutputPath = Join-Path $downloadDir "ConfiguratorApp.msix"
}

# Confirm operation if not forced
if (!$Force) {
    Write-Host "About to download Configurator App for Azure Local:" -ForegroundColor Yellow
    Write-Host "  Download URL: $downloadUrl" -ForegroundColor Gray
    Write-Host "  Output Path: $OutputPath" -ForegroundColor Gray
    Write-Host ""

    $confirmation = Read-Host "Continue? (y/N)"
    if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
        Write-Host "Download cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# Create download directory if needed
$outputDir = Split-Path -Parent $OutputPath
if (!(Test-Path $outputDir)) {
    Write-Host "Creating download directory..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

# Download with redirect following (aka.ms URLs redirect)
Write-Host "Downloading Configurator App from Microsoft..." -ForegroundColor Cyan
try {
    $ProgressPreference = 'SilentlyContinue'

    # First, resolve the final URL to get the actual filename
    $headResponse = Invoke-WebRequest -Uri $downloadUrl -Method Head -MaximumRedirection 10 -ErrorAction SilentlyContinue
    $finalUrl = if ($headResponse.BaseResponse.ResponseUri) {
        $headResponse.BaseResponse.ResponseUri.ToString()
    } elseif ($headResponse.BaseResponse.RequestMessage.RequestUri) {
        $headResponse.BaseResponse.RequestMessage.RequestUri.ToString()
    } else {
        $downloadUrl
    }

    # Extract actual filename from the resolved URL
    $urlFileName = [System.IO.Path]::GetFileName(([Uri]$finalUrl).LocalPath)
    if ($urlFileName -and $urlFileName -match '\.\w{2,5}$') {
        $OutputPath = Join-Path $outputDir $urlFileName
        Write-Host "  Resolved filename: $urlFileName" -ForegroundColor Gray
    }

    # Download the file
    Invoke-WebRequest -Uri $downloadUrl -OutFile $OutputPath -MaximumRedirection 10
    $ProgressPreference = 'Continue'
} catch {
    $ProgressPreference = 'Continue'
    throw "Failed to download Configurator App: $_`nURL: $downloadUrl`nTry downloading manually from the Azure Portal: https://aka.ms/ztp/tryit"
}

# Verify download
if (!(Test-Path $OutputPath)) {
    throw "Download failed — file not found at $OutputPath"
}

$fileInfo = Get-Item $OutputPath
if ($fileInfo.Length -eq 0) {
    Remove-Item $OutputPath -Force
    throw "Download failed — file is empty. Try downloading manually from: https://aka.ms/ztp/tryit"
}

Write-Host "✓ Configurator App downloaded successfully" -ForegroundColor Green
Write-Host "  File: $($fileInfo.Name)" -ForegroundColor Gray
Write-Host "  Size: $([math]::Round($fileInfo.Length / 1MB, 2)) MB" -ForegroundColor Gray
Write-Host "  Path: $OutputPath" -ForegroundColor Gray
Write-Host ""
Write-Host "To install, run the downloaded installer on a Windows 11 PC." -ForegroundColor Cyan
