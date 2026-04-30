<#
.SYNOPSIS
    Creates local user for iDRAC virtual media share access with correct SMB + NTFS permissions (PS7 compatible).

.DESCRIPTION
    Ensures a local Windows user exists, sets NTFS permissions, and assigns SMB share read access.
    Works in PowerShell 7 by invoking Windows PowerShell 5.1 for SMB cmdlets.

.PARAMETER Force
    Skip confirmation prompts.
#>

param(
    [switch]$Force
)

# Load repository config
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) { throw "Could not find repository root (config directory not found)" }

$configModulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
Import-Module $configModulePath -Force
$config = Get-AzureLocalConfig

# Get config
$username   = $config.GetValue('ztp.share_username')
$password   = $config.GetValue('ztp.share_password')
$sharePath  = $config.GetValue('ztp.share_location')
$shareName  = $config.GetValue('ztp.share_name')

if (!(Test-Path $sharePath)) { throw "Share path '$sharePath' not found. Run Create-ZTPShare.ps1 first." }

# Confirm
if (-not $Force) {
    Write-Host "About to create share access user:" -ForegroundColor Yellow
    Write-Host "  Username: $env:COMPUTERNAME\$username" -ForegroundColor Gray
    Write-Host "  Share Path: $sharePath" -ForegroundColor Gray
    Write-Host "  Share Name: $shareName" -ForegroundColor Gray
    Write-Host "  Permissions: Read-Only" -ForegroundColor Gray
    $confirm = Read-Host "Continue? (y/N)"
    if ($confirm -notin @('y','Y')) { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
}

Write-Host "`nCreating share access user..." -ForegroundColor Cyan

# Step 1: Create or reset local user
$securePass = ConvertTo-SecureString $password -AsPlainText -Force
$existingUser = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
if ($existingUser) {
    Set-LocalUser -Name $username -Password $securePass
    Write-Host "  ⚠ User '$username' already exists - password reset" -ForegroundColor Yellow
} else {
    New-LocalUser -Name $username -Password $securePass `
        -Description "iDRAC virtual media share access" `
        -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires | Out-Null
    Write-Host "  ✓ User created" -ForegroundColor Green
}
Enable-LocalUser -Name $username

# Step 2: Apply NTFS permissions
Write-Host "  Granting NTFS read access..." -ForegroundColor Gray
$acl = Get-Acl $sharePath
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "$env:COMPUTERNAME\$username",
    "ReadAndExecute",
    "ContainerInherit,ObjectInherit",
    "None",
    "Allow"
)
$acl.SetAccessRule($rule)
Set-Acl $sharePath $acl
Write-Host "  ✓ NTFS read access granted" -ForegroundColor Green

# Step 3: Grant SMB share read access using Windows PowerShell 5.1 compat session
Write-Host "  Granting SMB read access..." -ForegroundColor Gray

$psCommand = @"
Import-Module SmbShare
# Remove any existing access
if (Get-SmbShareAccess -Name '$shareName' -AccountName '$env:COMPUTERNAME\$username' -ErrorAction SilentlyContinue) {
    Revoke-SmbShareAccess -Name '$shareName' -AccountName '$env:COMPUTERNAME\$username' -Force
}
# Grant read access
Grant-SmbShareAccess -Name '$shareName' -AccountName '$env:COMPUTERNAME\$username' -AccessRight Read -Force
"@

# Invoke in Windows PowerShell
powershell -NoProfile -Command $psCommand | Out-Null
Write-Host "  ✓ SMB read access granted" -ForegroundColor Green

Write-Host "`n✓ Share access user configured successfully" -ForegroundColor Green
Write-Host "  Username: $env:COMPUTERNAME\$username" -ForegroundColor Cyan
Write-Host "  Share: \\$env:COMPUTERNAME\$shareName" -ForegroundColor Cyan
Write-Host "  Permissions: Read-Only (SMB + NTFS)" -ForegroundColor Cyan
Write-Host "`nUse this credential for iDRAC virtual media operations." -ForegroundColor Gray
