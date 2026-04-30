<#
.SYNOPSIS
    Verifies ISO mount status on servers.

.DESCRIPTION
    Checks that the Azure Local maintenance environment ISO is properly
    mounted as virtual media on target servers via Redfish API.

.PARAMETER ServerIPs
    Array of BMC/iDRAC IP addresses for target servers. Defaults to config values.

.PARAMETER Credential
    PSCredential object for BMC/iDRAC authentication

.EXAMPLE
    $credential = Get-Credential
    .\Verify-ISOMount.ps1 -ServerIPs "192.168.200.11","192.168.200.12" -Credential $credential

    Verifies ISO mount status on specified servers

.EXAMPLE
    .\Verify-ISOMount.ps1 -Credential $credential

    Verifies ISO mount status on all servers from config

.NOTES
    Requires:
    - PowerShell 7.0+
    - Network access to BMC/iDRAC interfaces
    - Valid BMC credentials with virtual media permissions
    - AzureLocalConfig.psm1 module for configuration loading
#>

param(
    [Parameter(Mandatory=$false)]
    [string[]]$ServerIPs,

    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential
)

#Requires -Version 7.0

# ── Load Config ──────────────────────────────────────────────────────────────
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) { throw "Could not find repository root (config directory not found)" }

$configModulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
if (!(Test-Path $configModulePath)) { throw "Config module not found at $configModulePath" }
Import-Module $configModulePath -Force
$config = Get-AzureLocalConfig

# ── Resolve Server IPs ──────────────────────────────────────────────────────
if (-not $ServerIPs) { $ServerIPs = $config.GetIdracIPs() }
if (-not $ServerIPs -or $ServerIPs.Count -eq 0) { throw "No server IPs provided and none found in config" }

# ── Resolve iDRAC Credentials ───────────────────────────────────────────────
if (!$Credential) {
    $keyVaultName = $config.GetValue('keyvault.platform_name', $null)
    $secretName = $config.GetValue('ztp.idrac_secret_name', $null)
    if ($keyVaultName -and $secretName) {
        Write-Host "Retrieving iDRAC credentials from Key Vault '$keyVaultName'..." -ForegroundColor Cyan
        $secret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName
        if (!$secret) { throw "Failed to retrieve secret '$secretName' from Key Vault '$keyVaultName'" }
        $credString = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
        if ($credString -notmatch ':') { throw "Invalid Key Vault secret format. Expected: 'username:password'" }
        $username, $password = $credString -split ':', 2
        $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
        $Credential = New-Object PSCredential ($username, $securePassword)
        Write-Host "✓ iDRAC credentials retrieved" -ForegroundColor Green
    } else {
        $Credential = Get-Credential -Message "Enter iDRAC credentials"
    }
}

Write-Host "Verifying ISO mount status on $($ServerIPs.Count) servers..." -ForegroundColor Cyan

$results = @()

foreach ($ip in $ServerIPs) {
    $result = [PSCustomObject]@{
        IPAddress = $ip
        Status = "Checking"
        ISOMounted = $false
        Message = ""
        Timestamp = Get-Date
    }

    try {
        Write-Host "Checking server $ip..." -ForegroundColor Gray

        $baseUrl = "https://$ip"

        # Check virtual media status
        $vmUri = "$baseUrl/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD"
        $vmResponse = Invoke-RestMethod -Uri $vmUri -Credential $Credential -Method GET -SkipCertificateCheck

        if ($vmResponse.Inserted -eq $true) {
            $result.Status = "Success"
            $result.ISOMounted = $true
            $result.Message = "ISO successfully mounted: $($vmResponse.Image)"
            Write-Host "✓ ISO mounted on server $ip" -ForegroundColor Green
        } else {
            $result.Status = "Not Mounted"
            $result.Message = "ISO not mounted"
            Write-Warning "ISO not mounted on server $ip"
        }

    } catch {
        $result.Status = "Error"
        $result.Message = $_.Exception.Message
        Write-Error "Could not verify ISO mount on server $ip`: $($_.Exception.Message)"
    }

    $results += $result
}

# Display results
Write-Host "`nISO Mount Verification Results:" -ForegroundColor Yellow
$results | Format-Table -AutoSize

# Summary
$mounted = $results | Where-Object { $_.ISOMounted -eq $true }
$notMounted = $results | Where-Object { $_.ISOMounted -eq $false -and $_.Status -ne "Error" }
$errors = $results | Where-Object { $_.Status -eq "Error" }

Write-Host "`nSummary:" -ForegroundColor Cyan
Write-Host "  Successfully mounted: $($mounted.Count)" -ForegroundColor Green
Write-Host "  Not mounted: $($notMounted.Count)" -ForegroundColor Yellow
Write-Host "  Errors: $($errors.Count)" -ForegroundColor Red

if ($notMounted.Count -gt 0) {
    Write-Host "`nServers without ISO mounted:" -ForegroundColor Yellow
    $notMounted | ForEach-Object {
        Write-Host "  - $($_.IPAddress)" -ForegroundColor Yellow
    }
}

if ($errors.Count -gt 0) {
    Write-Host "`nServers with verification errors:" -ForegroundColor Red
    $errors | ForEach-Object {
        Write-Host "  - $($_.IPAddress): $($_.Message)" -ForegroundColor Red
    }
}