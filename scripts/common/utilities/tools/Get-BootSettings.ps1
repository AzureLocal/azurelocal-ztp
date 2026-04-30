<#
.SYNOPSIS
    Queries UEFI boot settings from all servers via Redfish API.

.DESCRIPTION
    Authenticates via Key Vault (or interactive credentials), queries each server's
    current boot order, boot source override status, and available boot options via
    the Dell iDRAC Redfish API. Results for all servers are saved to a single JSON file.

    This script does NOT modify any settings — it is read-only.

.PARAMETER Credential
    PSCredential for iDRAC authentication. If not provided, retrieves from Key Vault.

.PARAMETER IdracIP
    One or more iDRAC IP addresses. Defaults to all servers from environment.yaml.

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    .\Get-BootSettings.ps1

    Queries all servers from config using Key Vault credentials.

.EXAMPLE
    .\Get-BootSettings.ps1 -IdracIP "192.168.214.11","192.168.214.12"

    Queries specific servers only.

.EXAMPLE
    $cred = Get-Credential -UserName root -Message "Enter iDRAC password"
    .\Get-BootSettings.ps1 -Credential $cred

    Uses provided credentials instead of Key Vault.

.NOTES
    Requires:
    - PowerShell 7.0+ (for ForEach-Object -Parallel and -SkipCertificateCheck)
    - Network access to iDRAC management interfaces
    - Valid iDRAC credentials with read permissions
    - AzureLocalConfig.psm1 module for configuration loading
    - Az.KeyVault module (if using Key Vault for credentials)

    Output file: config/dell/discovery/boot-settings-<timestamp>.json
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string[]]$IdracIP,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

#Requires -Version 7.0

$ErrorActionPreference = "Continue"

# ── Find repository root ──
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) {
    throw "Could not find repository root (config directory not found)"
}

# ── Load configuration ──
$modulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
Import-Module $modulePath -Force

$config = Get-AzureLocalConfig
if ($IdracIP) {
    $serverIPs = $IdracIP
} else {
    $serverIPs = $config.GetIdracIPs()
}

# ── Credential resolution ──
if (!$Credential) {
    $keyVaultName = $config.GetValue('keyvault.platform_name')
    $secretName = $config.GetValue('ztp.idrac_secret_name')

    if ($keyVaultName -and $secretName) {
        try {
            Write-Host "Retrieving iDRAC credentials from Key Vault '$keyVaultName'..." -ForegroundColor Cyan
            $secret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName
            if (!$secret) {
                throw "Secret '$secretName' not found in Key Vault '$keyVaultName'"
            }
            $credString = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
            if ($credString -notmatch ':') {
                throw "Secret value must be in format 'username:password'"
            }
            $username, $password = $credString -split ':', 2
            $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
            $Credential = New-Object PSCredential ($username, $securePassword)
            Write-Host "  Credentials retrieved successfully" -ForegroundColor Green
        }
        catch {
            Write-Host "  Key Vault access failed: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  Falling back to interactive credential entry..." -ForegroundColor Yellow
            $Credential = Get-Credential -Message "Enter iDRAC credentials (e.g., root)"
        }
    }
    else {
        Write-Host "Key Vault not configured. Please provide credentials interactively." -ForegroundColor Yellow
        $Credential = Get-Credential -Message "Enter iDRAC credentials (e.g., root)"
    }
}

# ── Confirm operation ──
if (!$Force) {
    Write-Host "Will query boot settings on $($serverIPs.Count) server(s):" -ForegroundColor Cyan
    $serverIPs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    $confirmation = Read-Host "Continue? (yes/N)"
    if ($confirmation -ne 'yes') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
}

Write-Host "`nQuerying boot settings on $($serverIPs.Count) server(s)...`n" -ForegroundColor Cyan

# ── Serialize credentials for parallel execution ──
$credUser = $Credential.UserName
$credPass = $Credential.GetNetworkCredential().Password

# ── Query all servers in parallel ──
$results = $serverIPs | ForEach-Object -Parallel {
    $ip = $_
    $user = $using:credUser
    $pass = $using:credPass

    $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
    $cred = New-Object PSCredential ($user, $secPass)

    $entry = [ordered]@{
        IPAddress           = $ip
        Timestamp           = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        Status              = "Unknown"
        BootMode            = $null
        UefiBootSeq         = @()
        BootOverrideTarget  = $null
        BootOverrideEnabled = $null
        BootOptions         = @()
        Error               = $null
    }

    try {
        # Test Redfish connectivity
        $svcUri = "https://$ip/redfish/v1"
        $null = Invoke-RestMethod -Uri $svcUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30

        # Get system boot override info
        $sysUri = "https://$ip/redfish/v1/Systems/System.Embedded.1"
        $system = Invoke-RestMethod -Uri $sysUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30
        $entry.BootOverrideTarget = $system.Boot.BootSourceOverrideTarget
        $entry.BootOverrideEnabled = $system.Boot.BootSourceOverrideEnabled

        # Get BIOS attributes (boot mode + sequence)
        $biosUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Bios"
        $bios = Invoke-RestMethod -Uri $biosUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30
        $entry.BootMode = $bios.Attributes.BootMode

        if ($bios.Attributes.UefiBootSeq) {
            $entry.UefiBootSeq = ($bios.Attributes.UefiBootSeq -split ',').Trim()
        }

        # Get available boot options with details
        $optionsUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/BootOptions"
        $optionsList = Invoke-RestMethod -Uri $optionsUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30

        foreach ($member in $optionsList.Members) {
            try {
                $optUri = "https://$ip$($member.'@odata.id')"
                $opt = Invoke-RestMethod -Uri $optUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 15
                $entry.BootOptions += [ordered]@{
                    Id                  = $opt.Id
                    DisplayName         = $opt.DisplayName
                    Name                = $opt.Name
                    BootOptionEnabled   = $opt.BootOptionEnabled
                    BootOptionReference = $opt.BootOptionReference
                    UefiDevicePath      = $opt.UefiDevicePath
                }
            } catch {
                $entry.BootOptions += [ordered]@{
                    Id    = $member.'@odata.id'
                    Error = $_.Exception.Message
                }
            }
        }

        $entry.Status = "Success"
    }
    catch {
        $entry.Status = "Failed"
        $entry.Error = $_.Exception.Message
    }

    return [PSCustomObject]$entry
} -ThrottleLimit $serverIPs.Count

# ── Display results ──
Write-Host ""
foreach ($srv in $results) {
    if ($srv.Status -eq "Success") {
        Write-Host "[$($srv.IPAddress)] BootMode: $($srv.BootMode) | Override: $($srv.BootOverrideTarget) ($($srv.BootOverrideEnabled)) | Options: $($srv.BootOptions.Count)" -ForegroundColor Green
        Write-Host "  Boot Sequence:" -ForegroundColor Cyan
        $position = 1
        foreach ($device in $srv.UefiBootSeq) {
            $displayName = ($srv.BootOptions | Where-Object { $_.BootOptionReference -eq $device }).DisplayName
            if ($displayName) {
                Write-Host "    $position. $device ($displayName)" -ForegroundColor White
            } else {
                Write-Host "    $position. $device" -ForegroundColor White
            }
            $position++
        }
    } else {
        Write-Host "[$($srv.IPAddress)] FAILED: $($srv.Error)" -ForegroundColor Red
    }
}

# ── Save results ──
$outputDir = Join-Path $repoRoot "config\dell\discovery"
if (!(Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile = Join-Path $outputDir "boot-settings-$timestamp.json"

$output = [ordered]@{
    GeneratedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    ServerCount = $results.Count
    Succeeded   = ($results | Where-Object { $_.Status -eq 'Success' }).Count
    Failed      = ($results | Where-Object { $_.Status -eq 'Failed' }).Count
    Servers     = $results
}

$output | ConvertTo-Json -Depth 6 | Set-Content -Path $outFile -Encoding UTF8

Write-Host "`n════════════════════════════════════════" -ForegroundColor Yellow
Write-Host "  Boot Settings Report" -ForegroundColor Yellow
Write-Host "  Servers queried: $($results.Count)" -ForegroundColor Yellow
Write-Host "  Success: $(($results | Where-Object { $_.Status -eq 'Success' }).Count)" -ForegroundColor Green
Write-Host "  Failed:  $(($results | Where-Object { $_.Status -eq 'Failed' }).Count)" -ForegroundColor Red
Write-Host "  Results: $outFile" -ForegroundColor Yellow
Write-Host "════════════════════════════════════════" -ForegroundColor Yellow
