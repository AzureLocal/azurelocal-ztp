<#
.SYNOPSIS
    Unmounts virtual media (ISO) from Dell servers via iDRAC Redfish API.

.DESCRIPTION
    Uses Redfish API to eject virtual CD/DVD media from Dell PowerEdge servers via iDRAC.
    This is the cleanup step after ZTP installation is complete.

.PARAMETER Credential
    PSCredential object for BMC/iDRAC authentication (optional if using Key Vault)

.PARAMETER DelayBetweenServers
    Delay in seconds between servers (default: 10)

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    .\Unmount-AzureLocalISO.ps1

    Unmounts virtual media from all servers using Key Vault credentials.

.EXAMPLE
    $cred = Get-Credential
    .\Unmount-AzureLocalISO.ps1 -Credential $cred

    Unmounts virtual media from all servers using provided credentials.

.NOTES
    Requires:
    - PowerShell 7.0+
    - Network access to BMC/iDRAC interfaces
    - Valid BMC credentials with virtual media permissions
    - AzureLocalConfig.psm1 module for configuration loading
    - Az.KeyVault module (if using Key Vault for credentials)
    - Key Vault name and secret name in environment.yaml (keyvault.platform_name, ztp.idrac_secret_name)
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
    Write-Host "WARNING: About to unmount virtual media from $serverCount server(s):" -ForegroundColor Red
    $serverIPs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host "This will eject any mounted virtual CD/DVD media." -ForegroundColor Red

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
        Write-Host "Unmounting virtual media from server $ip..." -ForegroundColor Yellow

        $baseUrl = "https://$ip"

        # Test connectivity first
        $testUri = "$baseUrl/redfish/v1"
        $testResponse = Invoke-RestMethod -Uri $testUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30

        if ($testResponse.'@odata.type' -notlike '*ServiceRoot*') {
            throw "Invalid Redfish service response from $ip"
        }

        # Check current virtual media status
        $vmUri = "$baseUrl/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD"
        $vmStatus = Invoke-RestMethod -Uri $vmUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30

        if ($vmStatus.Inserted -eq $false) {
            Write-Host "No virtual media mounted on server $ip" -ForegroundColor Gray
            $result.Status = "Success"
            $result.Message = "No virtual media was mounted"
        } else {
            # Eject the virtual media
            $ejectUri = "$baseUrl/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD/Actions/VirtualMedia.EjectMedia"
            $ejectResponse = Invoke-RestMethod -Uri $ejectUri -Credential $Credential -Method POST -Body "{}" -ContentType "application/json" -SkipCertificateCheck -TimeoutSec 30

            # Verify ejection
            Start-Sleep -Seconds 2
            $vmStatusAfter = Invoke-RestMethod -Uri $vmUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30

            if ($vmStatusAfter.Inserted -eq $false) {
                $result.Status = "Success"
                $result.Message = "Virtual media ejected successfully"
                Write-Host "Successfully ejected virtual media from server $ip" -ForegroundColor Green
            } else {
                $result.Status = "Warning"
                $result.Message = "Eject command sent but media still shows as inserted"
                Write-Host "Eject command sent but media still shows as inserted on server $ip" -ForegroundColor Yellow
            }
        }

    } catch {
        $result.Status = "Failed"
        $result.Message = $_.Exception.Message
        Write-Error "Failed to unmount virtual media from server $ip`: $($_.Exception.Message)"
    }

    $results += $result

    # Add delay between servers (except for the last one)
    if ($i -lt ($serverIPs.Count - 1)) {
        Write-Host "Waiting $DelayBetweenServers seconds before next server..." -ForegroundColor Cyan
        Start-Sleep -Seconds $DelayBetweenServers
    }
}

# Display results
Write-Host "`nVirtual Media Unmount Results:" -ForegroundColor Cyan
$results | Format-Table -AutoSize

# Export results
$results | Export-Csv -Path ".\virtual-media-unmount-results.csv" -NoTypeInformation
$results | ConvertTo-Json | Out-File ".\virtual-media-unmount-results.json"

Write-Host "Results saved to CSV and JSON files." -ForegroundColor Green