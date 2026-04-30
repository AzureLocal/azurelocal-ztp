<#
.SYNOPSIS
    Configures boot source override on target servers via Redfish API for Azure Local ZTP.

.DESCRIPTION
    Uses Redfish API to set one-time boot source to virtual CD/DVD on Dell PowerEdge servers
    with iDRAC. This ensures servers boot from the mounted Azure Local maintenance environment
    ISO during the next restart.

.PARAMETER Credential
    PSCredential object for BMC/iDRAC authentication (optional if using Key Vault)

.PARAMETER BootSource
    Boot source to set (default: Cd). Valid values: Cd, Hdd, Pxe

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    $Credential = Get-Credential
    .\Set-ServerBootSource.ps1 -Credential $Credential

    Sets boot source to CD for all servers defined in config using interactive credentials.

.EXAMPLE
    .\Set-ServerBootSource.ps1 -BootSource "Pxe" -Force

    Sets boot source to PXE without confirmation using Key Vault credentials.

.NOTES
    Requires:
    - PowerShell 7.0+
    - Network access to BMC/iDRAC interfaces
    - Valid BMC credentials with system control permissions
    - AzureLocalConfig.psm1 module for configuration loading
    - Az.KeyVault module (if using Key Vault for credentials)
    - Key Vault name and secret name in environment.yaml (keyvault.platform_name, ztp.idrac_secret_name)
#>

param(
    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory=$false)]
    [ValidateSet("Cd", "Hdd", "Pxe")]
    [string]$BootSource = "Cd",

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
    } else {
        Write-Host "Key Vault configuration not found. Please provide credentials interactively." -ForegroundColor Yellow
        $Credential = Get-Credential -Message "Enter iDRAC credentials"
    }
}

# Confirm operation if not forced
if (!$Force) {
    $serverCount = $serverIPs.Count
    Write-Host "WARNING: About to set boot source to '$BootSource' on $serverCount server(s):" -ForegroundColor Red
    $serverIPs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host "This will change the one-time boot source for these servers." -ForegroundColor Red

    $confirmation = Read-Host "Are you sure you want to continue? (y/N)"
    if ($confirmation -notin @('y', 'yes')) {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
}

$results = @()

foreach ($ip in $serverIPs) {
    $result = [PSCustomObject]@{
        IPAddress = $ip
        Status = "Processing"
        BootSource = $BootSource
        Message = ""
        Timestamp = Get-Date
    }

    try {
        Write-Host "Checking boot source for server $ip..." -ForegroundColor Gray

        $baseUrl = "https://$ip"

        # Test connectivity first
        $testUri = "$baseUrl/redfish/v1"
        $testResponse = Invoke-RestMethod -Uri $testUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30

        if ($testResponse.'@odata.type' -notlike '*ServiceRoot*') {
            throw "Invalid Redfish service response from $ip"
        }

        # Check current boot source override
        $bootUri = "$baseUrl/redfish/v1/Systems/System.Embedded.1"
        $currentBoot = Invoke-RestMethod -Uri $bootUri -Credential $Credential -Method GET -SkipCertificateCheck

        $currentEnabled = $currentBoot.Boot.BootSourceOverrideEnabled
        $currentTarget = $currentBoot.Boot.BootSourceOverrideTarget

        if ($currentEnabled -eq "Once" -and $currentTarget -eq $BootSource) {
            $result.Status = "Already Set"
            $result.Message = "Boot source already set to $BootSource"
            Write-Host "Boot source already correctly set on server $ip" -ForegroundColor Green
        } else {
            Write-Host "Setting boot source to $BootSource for server $ip..." -ForegroundColor Yellow

            # Set one-time boot source override
            $bootBody = @{
                Boot = @{
                    BootSourceOverrideEnabled = "Once"
                    BootSourceOverrideTarget = $BootSource
                }
            } | ConvertTo-Json -Depth 3

            $bootResponse = Invoke-RestMethod -Uri $bootUri -Credential $Credential -Method PATCH -Body $bootBody -ContentType "application/json" -SkipCertificateCheck

            $result.Status = "Success"
            $result.Message = "Boot source set to $BootSource"
            Write-Host "Successfully set boot source on server $ip" -ForegroundColor Green
        }

    } catch {
        $result.Status = "Failed"
        $result.Message = $_.Exception.Message
        Write-Error "Failed to set boot source on server $ip`: $($_.Exception.Message)"
    }

    $results += $result
}

# Display results
Write-Host "`nBoot Source Configuration Results:" -ForegroundColor Cyan
$results | Format-Table -AutoSize

# Export results
$results | Export-Csv -Path ".\server-boot-source-results.csv" -NoTypeInformation
$results | ConvertTo-Json | Out-File ".\server-boot-source-results.json"

Write-Host "Results saved to CSV and JSON files." -ForegroundColor Green