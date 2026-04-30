# Mount-AzureLocalISO.ps1
# Mounts Azure Local ISO to virtual media on iDRAC endpoints

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string[]]$ServerIPs,

    [Parameter(Mandatory = $true)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $true)]
    [string]$IsoSharePath,

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

Write-Host "Starting ISO mount operation for $($ServerIPs.Count) servers..."
Write-Host "ISO Path: $IsoSharePath"
Write-Host "Timestamp: $timestamp"

# Verify ISO exists
if (-not (Test-Path $IsoSharePath)) {
    throw "ISO file not found: $IsoSharePath"
}

$isoInfo = Get-Item $IsoSharePath
Write-Host "ISO Size: $($isoInfo.Length) bytes"

foreach ($ip in $ServerIPs) {
    Write-Host "Mounting ISO on server: $ip"

    $result = @{
        ip = $ip
        timestamp = $timestamp
        iso_path = $IsoSharePath
        success = $false
        error = $null
    }

    try {
        # Create Redfish session
        $session = New-RedfishSession -IdracIP $ip -Credential $Credential

        # Insert virtual media
        $insertResult = Insert-VirtualMedia -Session $session -IsoPath $IsoSharePath

        if ($insertResult -and $insertResult.success) {
            # Set boot source to virtual CD
            $bootResult = Set-BootSource -Session $session -BootSource "Cd"
            
            if ($bootResult -and $bootResult.success) {
                $result.success = $true
                Write-Host "  ✅ ISO inserted and boot source set to virtual CD"
            } else {
                $result.error = "Mount succeeded but failed to set boot source"
                Write-Warning "  ⚠️ Mount succeeded but boot source setting failed"
            }
        } else {
            $result.error = "Mount operation failed"
            if ($mountResult.error) {
                $result.error = $mountResult.error
            }
            Write-Warning "  ❌ Mount failed: $($result.error)"
        }

        # Disconnect session
        $session.Disconnect()

    } catch {
        $result.error = $_.Exception.Message
        Write-Warning "  ❌ Mount failed for $ip`: $($_.Exception.Message)"
    }

    $results += $result
}

# Save results
$mountResults = @{
    timestamp = $timestamp
    operation = "iso_mount"
    iso_path = $IsoSharePath
    total_servers = $ServerIPs.Count
    successful_mounts = ($results | Where-Object { $_.success }).Count
    failed_mounts = ($results | Where-Object { -not $_.success }).Count
    results = $results
}

$outputFile = Join-Path $OutputPath "iso-mount-results.json"
$mountResults | ConvertTo-Json -Depth 10 | Out-File -FilePath $outputFile -Encoding UTF8

# Log operation
$logEntry = @{
    timestamp = $timestamp
    operation = "iso_mount"
    iso_path = $IsoSharePath
    servers_processed = $ServerIPs.Count
    successful = ($results | Where-Object { $_.success }).Count
    failed = ($results | Where-Object { -not $_.success }).Count
    output_path = $OutputPath
    log_path = $LogPath
} | ConvertTo-Json

$logFile = Join-Path $LogPath "iso-mount-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$logEntry | Out-File -FilePath $logFile -Encoding UTF8

Write-Host ""
Write-Host "ISO Mount Summary:"
Write-Host "  Total servers: $($ServerIPs.Count)"
Write-Host "  Successful: $(($results | Where-Object { $_.success }).Count)"
Write-Host "  Failed: $(($results | Where-Object { -not $_.success }).Count)"
Write-Host "  Results saved to: $outputFile"
Write-Host "  Log saved to: $logFile"

# Return results for pipeline usage
return $mountResults