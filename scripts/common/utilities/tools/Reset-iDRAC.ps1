<#
.SYNOPSIS
    Resets iDRAC on target servers via Redfish API.

.DESCRIPTION
    Performs a graceful restart of the iDRAC management controller on Dell PowerEdge servers
    using the Redfish API. This does NOT reboot the host server — only the iDRAC service restarts.

    Useful when an iDRAC becomes unresponsive, returns stale data, or exhibits unexpected behavior.
    The iDRAC typically takes 2–3 minutes to come back online after a reset.

    All servers are reset in parallel by default.

.PARAMETER Credential
    PSCredential object for iDRAC authentication. If not provided, credentials will be retrieved from Azure Key Vault.

.PARAMETER IdracIP
    One or more iDRAC IP addresses to target. If not specified, all servers from environment.yaml are used.

.PARAMETER ResetType
    Type of iDRAC reset to perform. Default is "GracefulRestart".
    Options: GracefulRestart, ForceRestart

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    .\Reset-iDRAC.ps1

    Resets all iDRACs defined in config using Key Vault credentials with graceful restart.

.EXAMPLE
    .\Reset-iDRAC.ps1 -IdracIP "192.168.1.100" -Force

    Resets a single iDRAC without confirmation.

.EXAMPLE
    .\Reset-iDRAC.ps1 -IdracIP "192.168.1.100","192.168.1.101" -Force

    Resets two specific iDRACs without confirmation.

.EXAMPLE
    $Credential = Get-Credential -UserName root -Message "Enter iDRAC password"
    .\Reset-iDRAC.ps1 -Credential $Credential -ResetType ForceRestart -Force

    Force-restarts all iDRACs using provided credentials without confirmation.

.NOTES
    Requires:
    - PowerShell 7.0+
    - Network access to iDRAC management interfaces
    - Valid iDRAC credentials with administrator permissions
    - AzureLocalConfig.psm1 module for configuration loading

    WARNING: The iDRAC will be unreachable for 2–3 minutes during the reset.
    The host server OS continues running — this does NOT affect the host.
#>

param(
    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory=$false)]
    [string[]]$IdracIP,

    [Parameter(Mandatory=$false)]
    [ValidateSet("GracefulRestart", "ForceRestart")]
    [string]$ResetType = "GracefulRestart",

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
if ($IdracIP) {
    $serverIPs = $IdracIP
} else {
    $serverIPs = $config.GetIdracIPs()
}

# Credential resolution — Key Vault or interactive
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

# Confirm operation if not forced
if (!$Force) {
    $serverCount = $serverIPs.Count
    Write-Host "WARNING: About to reset iDRAC ($ResetType) on $serverCount server(s):" -ForegroundColor Red
    $serverIPs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host "The iDRAC will be unreachable for 2-3 minutes. The host OS is NOT affected." -ForegroundColor Yellow

    $confirmation = Read-Host "Are you sure you want to continue? (yes/N)"
    if ($confirmation -ne 'yes') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
}

$results = @()

# Serialize credential for parallel runspaces
$credUser = $Credential.UserName
$credPass = $Credential.GetNetworkCredential().Password

$results = $serverIPs | ForEach-Object -Parallel {
    $ip = $_
    $user = $using:credUser
    $pass = $using:credPass
    $resetType = $using:ResetType

    $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
    $cred = New-Object PSCredential ($user, $secPass)

    $result = [PSCustomObject]@{
        IPAddress = $ip
        ResetType = $resetType
        Status    = "Processing"
        Message   = ""
        Timestamp = Get-Date
    }

    try {
        $baseUrl = "https://$ip"

        # Test connectivity first
        $testUri = "$baseUrl/redfish/v1"
        $testResponse = Invoke-RestMethod -Uri $testUri -Credential $cred -Method GET -SkipCertificateCheck -TimeoutSec 30

        if ($testResponse.'@odata.type' -notlike '*ServiceRoot*') {
            throw "Invalid Redfish service response from $ip"
        }

        # Reset iDRAC
        $resetUri = "$baseUrl/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Manager.Reset"
        $resetBody = @{
            ResetType = $resetType
        } | ConvertTo-Json

        Invoke-RestMethod -Uri $resetUri -Credential $cred -Method POST -Body $resetBody -ContentType "application/json" -SkipCertificateCheck

        $result.Status = "Success"
        $result.Message = "iDRAC reset initiated successfully"

    } catch {
        $result.Status = "Failed"
        $result.Message = $_.Exception.Message
    }

    return $result
} -ThrottleLimit $serverIPs.Count

# Display results
Write-Host "`niDRAC Reset Results:" -ForegroundColor Cyan
$results | Format-Table -AutoSize

# Export results
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logDir = Join-Path $repoRoot "logs"
if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

$jsonPath = Join-Path $logDir "idrac-reset-results-$timestamp.json"
$results | ConvertTo-Json | Out-File $jsonPath

Write-Host "Results saved to $jsonPath" -ForegroundColor Green
