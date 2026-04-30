<#
.SYNOPSIS
    Creates a secure SMB network share for Azure Local ZTP ISO files.

.DESCRIPTION
    Creates the share directory (if missing), ensures the local service account exists,
    applies NTFS permissions, and creates/replaces the SMB share. Share-level access
    is managed separately via `Create-ShareAccessUser.ps1`.

.PARAMETER Force
    Skip confirmation prompts.

.NOTES
    - Requires Administrator privileges.
    - PowerShell 7+ recommended.
#>

param(
    [Parameter(Mandatory = $false)]
    [switch]$Force
)

# ── Ensure running elevated (Administrator)
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {
    $isAdmin = $false
}
if (-not $isAdmin) {
    Write-Error "This script must be run as Administrator. Please re-run in an elevated PowerShell session."
    exit 1
}

# ── Load repository config
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot 'config'))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) { throw "Could not find repository root (config directory not found)" }

$configModulePath = Join-Path $repoRoot 'scripts\common\AzureLocalConfig.psm1'
if (!(Test-Path $configModulePath)) { throw "Config module not found at $configModulePath" }
Import-Module $configModulePath -Force
$config = Get-AzureLocalConfig

# ── Read ZTP Config
$shareLocation    = $config.GetValue('ztp.share_location')
$shareName        = $config.GetValue('ztp.share_name')
$shareNetworkPath = $config.GetValue('ztp.share_network_path')
$shareUsername    = $config.GetValue('ztp.share_username')
$sharePassword    = $config.GetValue('ztp.share_password')

if (-not $shareLocation -or -not $shareName -or -not $shareUsername -or -not $sharePassword) {
    throw "Missing required ZTP share configuration values"
}

# Extract server name from UNC for informational output
$shareServer = if ($shareNetworkPath) { ($shareNetworkPath -replace '^\\\\', '') -split '\\' | Select-Object -First 1 } else { $null }
$qualifiedUser = if ($shareServer) { "$shareServer\$shareUsername" } else { $shareUsername }

# ── Confirm
if (-not $Force) {
    Write-Host "About to create Azure Local ZTP share:" -ForegroundColor Yellow
    Write-Host "  Location : $shareLocation" -ForegroundColor Gray
    Write-Host "  Share    : \\$env:COMPUTERNAME\$shareName" -ForegroundColor Gray
    Write-Host "  Account  : $qualifiedUser" -ForegroundColor Gray
    Write-Host ""
    $confirm = Read-Host "Continue? (y/N)"
    if ($confirm -notin @('y','Y')) { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
}

# ── Create Directory
Write-Host "Creating share directory..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path $shareLocation -Force -ErrorAction Stop | Out-Null

# ── Ensure Local Share Account
Write-Host "Validating share account..." -ForegroundColor Cyan
$localUser = Get-LocalUser -Name $shareUsername -ErrorAction SilentlyContinue
if (-not $localUser) {
    Write-Host "Creating local user '$shareUsername'" -ForegroundColor Gray
    $securePassword = ConvertTo-SecureString $sharePassword -AsPlainText -Force
    New-LocalUser -Name $shareUsername -Password $securePassword -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires | Out-Null
} else {
    Write-Host "Local user '$shareUsername' already exists" -ForegroundColor Gray
}

# ── Apply NTFS Permissions
Write-Host "Applying NTFS permissions..." -ForegroundColor Cyan
$acl = Get-Acl $shareLocation
$accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $shareUsername,
    "FullControl",
    "ContainerInherit,ObjectInherit",
    "None",
    "Allow"
)
$acl.SetAccessRule($accessRule)
Set-Acl -Path $shareLocation -AclObject $acl

# ── Create / Replace SMB Share
Write-Host "Configuring SMB share..." -ForegroundColor Cyan
$existingShare = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
if ($existingShare) {
    Write-Host "Removing existing share '$shareName'" -ForegroundColor Gray
    Remove-SmbShare -Name $shareName -Force
}

# Create the share; share-level access can be granted separately
New-SmbShare -Name $shareName -Path $shareLocation -CachingMode None | Out-Null

# ── Summary
Write-Host ""
Write-Host "✓ ZTP network share created/updated successfully" -ForegroundColor Green
Write-Host "  Share Path : \\$env:COMPUTERNAME\$shareName" -ForegroundColor Green
Write-Host "  Account    : $qualifiedUser" -ForegroundColor Green
Write-Host "  Note: Share-level access is not granted here. Run 'Create-ShareAccessUser.ps1' to grant SMB/NTFS access." -ForegroundColor Yellow
