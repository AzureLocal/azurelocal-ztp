<#
.SYNOPSIS
    Initiates reboot on target servers via Redfish API for Azure Local ZTP.

.DESCRIPTION
    Uses Redfish API to perform a force restart on Dell PowerEdge servers with iDRAC.
    This triggers the boot process from the mounted Azure Local maintenance environment ISO.

.PARAMETER Credential
    PSCredential object for BMC/iDRAC authentication (optional if using Key Vault)

.PARAMETER DelayBetweenServers
    Delay in seconds between initiating reboots on different servers (default: 10, use 0 for simultaneous reboots)

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    .\Restart-Servers.ps1

    Restarts all servers defined in config with default 10-second delay between operations using Key Vault credentials.

.EXAMPLE
    .\Restart-Servers.ps1 -DelayBetweenServers 0 -Force

    Restarts all servers simultaneously without delay and no confirmation using Key Vault credentials.

.EXAMPLE
    $cred = Get-Credential
    .\Restart-Servers.ps1 -Credential $cred

    Restarts all servers defined in config with default 10-second delay between operations using provided credentials.

.NOTES
    Requires:
    - PowerShell 7.0+
    - Network access to BMC/iDRAC interfaces
    - Valid BMC credentials with system control permissions
    - AzureLocalConfig.psm1 module for configuration loading
    - Az.KeyVault module (if using Key Vault for credentials)
    - Key Vault name and secret name in environment.yaml (keyvault.platform_name, ztp.idrac_secret_name)

    WARNING: This will immediately restart the specified servers. Ensure no critical operations are running.
#>

param(
    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory=$false)]
    [int]$DelayBetweenServers = 10,

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

# Confirm operation if not forced
if (!$Force) {
    $serverCount = $serverIPs.Count
    Write-Host "WARNING: About to initiate immediate reboot on $serverCount server(s):" -ForegroundColor Red
    $serverIPs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host "This will cause immediate downtime. Ensure no critical operations are running." -ForegroundColor Red

    $confirmation = Read-Host "Are you sure you want to continue? (y/N)"
    if ($confirmation -notin @('y', 'yes')) {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
}

$results = @()

for ($i = 0; $i -lt $serverIPs.Count; $i++) {
    $ip = $serverIPs[$i]
    $result = [PSCustomObject]@{
        IPAddress = $ip
        Status = "Processing"
        Message = ""
        Timestamp = Get-Date
    }

    try {
        Write-Host "Initiating reboot for server $ip..." -ForegroundColor Yellow

        $baseUrl = "https://$ip"

        # Test connectivity first
        $testUri = "$baseUrl/redfish/v1"
        $testResponse = Invoke-RestMethod -Uri $testUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30

        if ($testResponse.'@odata.type' -notlike '*ServiceRoot*') {
            throw "Invalid Redfish service response from $ip"
        }

        # Initiate force restart
        $resetUri = "$baseUrl/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"
        $resetBody = @{
            ResetType = "ForceRestart"
        } | ConvertTo-Json

        $resetResponse = Invoke-RestMethod -Uri $resetUri -Credential $Credential -Method POST -Body $resetBody -ContentType "application/json" -SkipCertificateCheck

        $result.Status = "Success"
        $result.Message = "Reboot initiated successfully"
        Write-Host "Successfully initiated reboot on server $ip" -ForegroundColor Green

    } catch {
        $result.Status = "Failed"
        $result.Message = $_.Exception.Message
        Write-Error "Failed to reboot server $ip`: $($_.Exception.Message)"
    }

    $results += $result

    # Add delay between servers (except for the last one)
    if ($i -lt ($serverIPs.Count - 1)) {
        Write-Host "Waiting $DelayBetweenServers seconds before next server..." -ForegroundColor Cyan
        Start-Sleep -Seconds $DelayBetweenServers
    }
}

# Display results
Write-Host "`nReboot Results:" -ForegroundColor Cyan
$results | Format-Table -AutoSize

# Export results
$results | Export-Csv -Path ".\server-restart-results.csv" -NoTypeInformation
$results | ConvertTo-Json | Out-File ".\server-restart-results.json"

Write-Host "Results saved to CSV and JSON files." -ForegroundColor Green