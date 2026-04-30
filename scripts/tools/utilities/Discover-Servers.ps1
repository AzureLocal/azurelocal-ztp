# Discover-Servers.ps1
# Discovers hardware information from iDRAC endpoints using Redfish API

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string[]]$ServerIPs,

    [Parameter(Mandatory = $true)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [switch]$Full,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\output",

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\logs"
)

# Import required modules
Import-Module "$PSScriptRoot\..\common\AzureLocalConfig.psm1"
Import-Module "$PSScriptRoot\..\common\RedfishUtils.psm1"

# Create output directories
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
New-Item -ItemType Directory -Path $LogPath -Force | Out-Null

# Initialize results
$results = @()
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

Write-Host "Starting hardware discovery for $($ServerIPs.Count) servers..."
Write-Host "Timestamp: $timestamp"

foreach ($ip in $ServerIPs) {
    Write-Host "Discovering server: $ip"

    $result = @{
        ip = $ip
        timestamp = $timestamp
        success = $false
        system_info = $null
        storage_info = $null
        network_info = $null
        error = $null
    }

    try {
        # Create Redfish session
        $session = New-RedfishSession -IdracIP $ip -Credential $Credential

        # Get system information
        $systemInfo = Get-SystemInfo -Session $session
        if ($systemInfo) {
            $result.system_info = $systemInfo
            Write-Host "  System: $($systemInfo.Hostname) ($($systemInfo.Model))"
        }

        if ($Full) {
            # Get storage information
            $storageInfo = Get-StorageInfo -Session $session
            if ($storageInfo) {
                $result.storage_info = $storageInfo
                Write-Host "  Storage controllers: $($storageInfo.Members.Count)"
            }

            # Get network adapter information
            $networkInfo = Get-NetworkAdapters -Session $session
            if ($networkInfo) {
                $result.network_info = $networkInfo
                Write-Host "  Network adapters: $($networkInfo.Members.Count)"
            }
        }

        $result.success = $true
        Write-Host "  ✅ Discovery successful"

        # Disconnect session
        $session.Disconnect()

    } catch {
        $result.error = $_.Exception.Message
        Write-Warning "  ❌ Discovery failed for $ip`: $($_.Exception.Message)"
    }

    $results += $result
}

# Save individual results
foreach ($result in $results) {
    $hostname = if ($result.system_info) { $result.system_info.Hostname } else { $result.ip }
    $outputFile = Join-Path $OutputPath "$hostname-discovery.json"
    $result | ConvertTo-Json -Depth 10 | Out-File -FilePath $outputFile -Encoding UTF8
}

# Save combined results
$combinedResults = @{
    timestamp = $timestamp
    total_servers = $ServerIPs.Count
    successful_discoveries = ($results | Where-Object { $_.success }).Count
    failed_discoveries = ($results | Where-Object { -not $_.success }).Count
    include_hardware_inventory = $Full.IsPresent
    results = $results
}

$combinedFile = Join-Path $OutputPath "combined-discovery-results.json"
$combinedResults | ConvertTo-Json -Depth 10 | Out-File -FilePath $combinedFile -Encoding UTF8

# Log summary
$logEntry = @{
    timestamp = $timestamp
    operation = "hardware_discovery"
    servers_processed = $ServerIPs.Count
    successful = ($results | Where-Object { $_.success }).Count
    failed = ($results | Where-Object { -not $_.success }).Count
    output_path = $OutputPath
    log_path = $LogPath
} | ConvertTo-Json

$logFile = Join-Path $LogPath "discovery-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$logEntry | Out-File -FilePath $logFile -Encoding UTF8

Write-Host ""
Write-Host "Discovery Summary:"
Write-Host "  Total servers: $($ServerIPs.Count)"
Write-Host "  Successful: $(($results | Where-Object { $_.success }).Count)"
Write-Host "  Failed: $(($results | Where-Object { -not $_.success }).Count)"
Write-Host "  Results saved to: $OutputPath"
Write-Host "  Log saved to: $logFile"

# Return results for pipeline usage
return $combinedResults