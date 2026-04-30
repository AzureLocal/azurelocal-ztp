# Restart-Servers.ps1
# Restarts servers via iDRAC Redfish API

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string[]]$ServerIPs,

    [Parameter(Mandatory = $true)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [bool]$ForceRestart = $true,

    [Parameter(Mandatory = $false)]
    [int]$DelayBetweenRestarts = 30,

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

$resetType = if ($ForceRestart) { "ForceRestart" } else { "GracefulRestart" }

Write-Host "Starting server restart operation for $($ServerIPs.Count) servers..."
Write-Host "Reset Type: $resetType"
Write-Host "Delay between restarts: $DelayBetweenRestarts seconds"
Write-Host "Timestamp: $timestamp"

$serverIndex = 0
foreach ($ip in $ServerIPs) {
    $serverIndex++
    Write-Host "Restarting server $serverIndex/$($ServerIPs.Count): $ip"

    $result = @{
        ip = $ip
        timestamp = $timestamp
        reset_type = $resetType
        success = $false
        error = $null
    }

    try {
        # Create Redfish session
        $session = New-RedfishSession -IdracIP $ip -Credential $Credential

        # Restart server
        $restartResult = Restart-System -Session $session -ForceRestart $ForceRestart

        if ($restartResult -and $restartResult.success) {
            $result.success = $true
            Write-Host "  ✅ Restart command sent successfully"
        } else {
            $result.error = "Restart command failed"
            if ($restartResult.error) {
                $result.error = $restartResult.error
            }
            Write-Warning "  ❌ Restart failed: $($result.error)"
        }

        # Disconnect session
        $session.Disconnect()

    } catch {
        $result.error = $_.Exception.Message
        Write-Warning "  ❌ Restart failed for $ip`: $($_.Exception.Message)"
    }

    $results += $result

    # Add delay between restarts (except for the last server)
    if ($serverIndex -lt $ServerIPs.Count) {
        Write-Host "  Waiting $DelayBetweenRestarts seconds before next restart..."
        Start-Sleep -Seconds $DelayBetweenRestarts
    }
}

# Save results
$restartResults = @{
    timestamp = $timestamp
    operation = "server_restart"
    reset_type = $resetType
    force_restart = $ForceRestart
    delay_between_restarts = $DelayBetweenRestarts
    total_servers = $ServerIPs.Count
    successful_restarts = ($results | Where-Object { $_.success }).Count
    failed_restarts = ($results | Where-Object { -not $_.success }).Count
    results = $results
}

$outputFile = Join-Path $OutputPath "server-restart-results.json"
$restartResults | ConvertTo-Json -Depth 10 | Out-File -FilePath $outputFile -Encoding UTF8

# Log operation
$logEntry = @{
    timestamp = $timestamp
    operation = "server_restart"
    reset_type = $resetType
    force_restart = $ForceRestart
    delay_between_restarts = $DelayBetweenRestarts
    servers_processed = $ServerIPs.Count
    successful = ($results | Where-Object { $_.success }).Count
    failed = ($results | Where-Object { -not $_.success }).Count
    output_path = $OutputPath
    log_path = $LogPath
} | ConvertTo-Json

$logFile = Join-Path $LogPath "server-restart-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$logEntry | Out-File -FilePath $logFile -Encoding UTF8

Write-Host ""
Write-Host "Server Restart Summary:"
Write-Host "  Reset Type: $resetType"
Write-Host "  Total servers: $($ServerIPs.Count)"
Write-Host "  Successful: $(($results | Where-Object { $_.success }).Count)"
Write-Host "  Failed: $(($results | Where-Object { -not $_.success }).Count)"
Write-Host "  Results saved to: $outputFile"
Write-Host "  Log saved to: $logFile"

# Return results for pipeline usage
return $restartResults