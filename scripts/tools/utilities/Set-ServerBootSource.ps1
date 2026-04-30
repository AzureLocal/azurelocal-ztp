# Set-ServerBootSource.ps1
# Configures boot source for next boot on iDRAC endpoints

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string[]]$ServerIPs,

    [Parameter(Mandatory = $true)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Cd", "Hdd", "Pxe")]
    [string]$BootSource = "Cd",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\output",

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\logs"
)

# Import required modules
Import-Module "$PSScriptRoot\..\..\common\AzureLocalConfig.psm1"
Import-Module "$PSScriptRoot\..\..\common\RedfishUtils.psm1"

# Create output directories
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
New-Item -ItemType Directory -Path $LogPath -Force | Out-Null

# Initialize results
$results = @()
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

Write-Host "Setting boot source to '$BootSource' for $($ServerIPs.Count) servers..."
Write-Host "Timestamp: $timestamp"

foreach ($ip in $ServerIPs) {
    Write-Host "Configuring boot source on server: $ip"

    $result = @{
        ip = $ip
        timestamp = $timestamp
        boot_source = $BootSource
        success = $false
        error = $null
    }

    try {
        # Create Redfish session
        $session = New-RedfishSession -IdracIP $ip -Credential $Credential

        # Set boot source
        $bootResult = Set-BootSource -Session $session -BootSource $BootSource

        if ($bootResult -and $bootResult.success) {
            $result.success = $true
            Write-Host "  ✅ Boot source set to $BootSource"
        } else {
            $result.error = "Boot source configuration failed"
            if ($bootResult.error) {
                $result.error = $bootResult.error
            }
            Write-Warning "  ❌ Boot configuration failed: $($result.error)"
        }

        # Disconnect session
        $session.Disconnect()

    } catch {
        $result.error = $_.Exception.Message
        Write-Warning "  ❌ Boot configuration failed for $ip`: $($_.Exception.Message)"
    }

    $results += $result
}

# Save results
$bootResults = @{
    timestamp = $timestamp
    operation = "set_boot_source"
    boot_source = $BootSource
    total_servers = $ServerIPs.Count
    successful_configs = ($results | Where-Object { $_.success }).Count
    failed_configs = ($results | Where-Object { -not $_.success }).Count
    results = $results
}

$outputFile = Join-Path $OutputPath "boot-source-config-results.json"
$bootResults | ConvertTo-Json -Depth 10 | Out-File -FilePath $outputFile -Encoding UTF8

# Log operation
$logEntry = @{
    timestamp = $timestamp
    operation = "set_boot_source"
    boot_source = $BootSource
    servers_processed = $ServerIPs.Count
    successful = ($results | Where-Object { $_.success }).Count
    failed = ($results | Where-Object { -not $_.success }).Count
    output_path = $OutputPath
    log_path = $LogPath
} | ConvertTo-Json

$logFile = Join-Path $LogPath "boot-config-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$logEntry | Out-File -FilePath $logFile -Encoding UTF8

Write-Host ""
Write-Host "Boot Source Configuration Summary:"
Write-Host "  Boot Source: $BootSource"
Write-Host "  Total servers: $($ServerIPs.Count)"
Write-Host "  Successful: $(($results | Where-Object { $_.success }).Count)"
Write-Host "  Failed: $(($results | Where-Object { -not $_.success }).Count)"
Write-Host "  Results saved to: $outputFile"
Write-Host "  Log saved to: $logFile"

# Return results for pipeline usage
return $bootResults