<#
.SYNOPSIS
    Monitors Azure Local ZTP boot and installation process via Redfish API.

.DESCRIPTION
    Provides real-time monitoring and status updates for the Azure Local maintenance
    environment installation process on target servers using Redfish API.

.PARAMETER Credential
    PSCredential object for BMC/iDRAC authentication (optional if using Key Vault)

.PARAMETER Interval
    Monitoring interval in seconds (default: 60)

.EXAMPLE
    .\Monitor-ZTPBoot.ps1

    Monitors the ZTP boot process with status updates using Key Vault credentials.

.EXAMPLE
    $cred = Get-Credential
    .\Monitor-ZTPBoot.ps1 -Credential $cred

    Monitors the ZTP boot process with status updates using provided credentials.

.NOTES
    Requires:
    - PowerShell 7.0+
    - Network access to BMC/iDRAC interfaces
    - Valid BMC credentials with system read permissions
    - AzureLocalConfig.psm1 module for configuration loading
    - Az.KeyVault module (if using Key Vault for credentials)
    - Key Vault name and secret name in environment.yaml (keyvault.platform_name, ztp.idrac_secret_name)
#>

param(
    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory=$false)]
    [int]$Interval = 60
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
$serverIPs = $config.GetIdracIPs()

# Retrieve credentials from Key Vault if not provided
if (!$Credential) {
    $keyVaultName = $config.GetValue('keyvault.platform_name')
    $secretName = $config.GetValue('ztp.idrac_secret_name')
    if ($keyVaultName -and $secretName) {
        try {
            Write-Host "Retrieving credentials from Azure Key Vault '$keyVaultName'..." -ForegroundColor Cyan
            $secret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName
            if (!$secret) {
                throw "Failed to retrieve secret '$secretName' from Key Vault '$keyVaultName'"
            }
            $credString = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
            if ($credString -notmatch ':') {
                throw "Invalid credential format in Key Vault secret. Expected format: 'username:password'"
            }
            $username, $password = $credString -split ':', 2
            $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
            $Credential = New-Object PSCredential ($username, $securePassword)
            Write-Host "✓ Credentials retrieved successfully" -ForegroundColor Green
        } catch {
            Write-Host "Key Vault access failed: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "Falling back to interactive credential entry..." -ForegroundColor Yellow
            $Credential = Get-Credential -Message "Enter iDRAC credentials"
        }
    } else {
        Write-Host "Key Vault configuration not found. Please provide credentials interactively." -ForegroundColor Yellow
        $Credential = Get-Credential -Message "Enter iDRAC credentials"
    }
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Azure Local ZTP Boot Monitor" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Monitoring $($serverIPs.Count) server(s) every $Interval seconds..." -ForegroundColor Yellow
Write-Host "Expected completion time: 30-45 minutes per server" -ForegroundColor Cyan
Write-Host "Press Ctrl+C to stop monitoring..." -ForegroundColor Yellow
Write-Host ""

$startTime = Get-Date

function Get-ServerStatus {
    param([string]$IPAddress, [PSCredential]$Credential)

    try {
        $baseUrl = "https://$IPAddress"

        # Get system information
        $systemUri = "$baseUrl/redfish/v1/Systems/System.Embedded.1"
        $systemResponse = Invoke-RestMethod -Uri $systemUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 10

        # Get power state
        $powerState = $systemResponse.PowerState

        # Get boot source
        $bootSource = $systemResponse.Boot.BootSourceOverrideEnabled
        $bootMode = $systemResponse.Boot.BootSourceOverrideMode

        # Get health status
        $health = $systemResponse.Status.Health

        return [PSCustomObject]@{
            IPAddress = $IPAddress
            PowerState = $powerState
            BootSourceOverride = $bootSource
            BootMode = $bootMode
            Health = $health
            Status = "Online"
            LastChecked = Get-Date
        }

    } catch {
        return [PSCustomObject]@{
            IPAddress = $IPAddress
            PowerState = "Unknown"
            BootSourceOverride = "Unknown"
            BootMode = "Unknown"
            Health = "Unknown"
            Status = "Offline/Error: $($_.Exception.Message)"
            LastChecked = Get-Date
        }
    }
}

try {
    while ($true) {
        $elapsed = (Get-Date) - $startTime
        $elapsedMinutes = [math]::Floor($elapsed.TotalMinutes)

        Write-Host "$(Get-Date -Format 'HH:mm:ss') - Monitoring for $($elapsedMinutes) minutes..." -ForegroundColor Gray

        $serverStatuses = @()

        foreach ($ip in $serverIPs) {
            $status = Get-ServerStatus -IPAddress $ip -Credential $Credential
            $serverStatuses += $status
        }

        # Display status table
        Write-Host "Server Status:" -ForegroundColor Cyan
        $serverStatuses | Format-Table -AutoSize -Property IPAddress, PowerState, BootSourceOverride, Health, Status

        # Provide phase guidance based on elapsed time
        Write-Host "Installation Phase Guidance:" -ForegroundColor Yellow
        if ($elapsedMinutes -lt 5) {
            Write-Host "  Expected: BIOS/UEFI initialization, booting from virtual media" -ForegroundColor Gray
        } elseif ($elapsedMinutes -lt 15) {
            Write-Host "  Expected: Maintenance environment loading, network configuration" -ForegroundColor Gray
        } elseif ($elapsedMinutes -lt 30) {
            Write-Host "  Expected: Azure Local installer running, system preparation" -ForegroundColor Gray
        } else {
            Write-Host "  Expected: Installation nearing completion or completed" -ForegroundColor Green
        }

        Write-Host ""
        Start-Sleep -Seconds $Interval
    }
} catch {
    Write-Host "`nMonitoring stopped." -ForegroundColor Yellow
}