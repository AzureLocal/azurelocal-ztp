<#
.SYNOPSIS
    Discovers and inventories servers via Redfish API for Azure Local ZTP preparation.

.DESCRIPTION
    Performs comprehensive discovery of target servers using Redfish API. Collects
    system information, hardware details, and validates server readiness for Azure
    Local ZTP. Supports Dell PowerEdge servers with iDRAC and other Redfish-compatible
    BMC implementations.

.PARAMETER ServerIPs
    Array of BMC/iDRAC IP addresses for target servers

.PARAMETER Credential
    PSCredential object for BMC/iDRAC authentication

.PARAMETER OutputPath
    Directory for output files (default: .\discovery)

.PARAMETER Full
    Perform detailed hardware inventory (CPU, memory, storage, network)

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    $cred = Get-Credential
    .\Discover-Servers.ps1 -ServerIPs "192.168.200.11","192.168.200.12" -Credential $cred

    Discovers basic information from multiple servers.

.EXAMPLE
    .\Discover-Servers.ps1 -ServerIPs "192.168.200.11" -Credential $cred -Full -OutputPath "C:\Discovery"

    Performs detailed hardware discovery and saves to custom output path.

.NOTES
    Requires:
    - PowerShell 7.0+
    - Network access to BMC/iDRAC interfaces
    - Valid BMC credentials with read permissions
#>
param(
    [Parameter(Mandatory=$true)]
    [string[]]$ServerIPs,

    [Parameter(Mandatory=$true)]
    [PSCredential]$Credential,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\discovery",

    [Parameter(Mandatory=$false)]
    [switch]$Full,

    [Parameter(Mandatory=$false)]
    [switch]$Force
)

#Requires -Version 7.0

# Import helper modules if available
$helperPath = Join-Path $PSScriptRoot "..\helpers"
if (Test-Path $helperPath) {
    $helperFiles = Get-ChildItem -Path $helperPath -Filter "*.ps1" -File
    foreach ($helper in $helperFiles) {
        . $helper.FullName
    }
}

# Create output directory
if (!(Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# Confirm operation if not forced
if (!$Force) {
    $serverCount = $ServerIPs.Count
    $inventoryText = if ($Full) { "detailed hardware " } else { "" }
    Write-Host "About to perform ${inventoryText}discovery on $serverCount server(s):" -ForegroundColor Yellow
    $ServerIPs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Cyan }

    $confirmation = Read-Host "Continue? (y/N)"
    if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
}

$results = @()

foreach ($ip in $ServerIPs) {
    $result = [PSCustomObject]@{
        IPAddress = $ip
        Status = "Processing"
        Message = ""
        Model = ""
        SerialNumber = ""
        Manufacturer = ""
        FirmwareVersion = ""
        PowerState = ""
        Timestamp = Get-Date
    }

    try {
        Write-Host "Discovering server $ip..." -ForegroundColor Yellow

        $baseUrl = "https://$ip"

        # Test basic connectivity
        $testUri = "$baseUrl/redfish/v1"
        $serviceRoot = Invoke-RestMethod -Uri $testUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30

        if ($serviceRoot.'@odata.type' -notlike '*ServiceRoot*') {
            throw "Invalid Redfish service response from $ip"
        }

        # Get system information
        $systemUri = "$baseUrl/redfish/v1/Systems"
        $systemsResponse = Invoke-RestMethod -Uri $systemUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30

        $systemUri = "$baseUrl$($systemsResponse.Members[0].'@odata.id')"
        $systemInfo = Invoke-RestMethod -Uri $systemUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30

        # Extract basic information
        $result.Model = $systemInfo.Model
        $result.SerialNumber = $systemInfo.SerialNumber
        $result.Manufacturer = $systemInfo.Manufacturer
        $result.PowerState = $systemInfo.PowerState

        # Get BMC/firmware information
        $bmcUri = "$baseUrl/redfish/v1/Managers"
        $managersResponse = Invoke-RestMethod -Uri $bmcUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30

        $bmcUri = "$baseUrl$($managersResponse.Members[0].'@odata.id')"
        $bmcInfo = Invoke-RestMethod -Uri $bmcUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30

        $result.FirmwareVersion = $bmcInfo.FirmwareVersion

        # Perform detailed hardware inventory if requested
        if ($Full) {
            Write-Host "  Collecting hardware inventory..." -ForegroundColor Cyan

            # CPU Information
            $cpuUri = "$baseUrl$($systemInfo.Processors.'@odata.id')"
            try {
                $cpuResponse = Invoke-RestMethod -Uri $cpuUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30
                $cpuCount = $cpuResponse.Members.Count
                $result | Add-Member -MemberType NoteProperty -Name "CPUCount" -Value $cpuCount
            } catch {
                $result | Add-Member -MemberType NoteProperty -Name "CPUCount" -Value "Unknown"
            }

            # Memory Information
            $memoryUri = "$baseUrl$($systemInfo.Memory.'@odata.id')"
            try {
                $memoryResponse = Invoke-RestMethod -Uri $memoryUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30
                $totalMemoryGB = ($memoryResponse.Members | Measure-Object -Property CapacityMiB -Sum).Sum / 1024
                $result | Add-Member -MemberType NoteProperty -Name "TotalMemoryGB" -Value ([math]::Round($totalMemoryGB, 2))
            } catch {
                $result | Add-Member -MemberType NoteProperty -Name "TotalMemoryGB" -Value "Unknown"
            }

            # Storage Information
            $storageUri = "$baseUrl$($systemInfo.Storage.'@odata.id')"
            try {
                $storageResponse = Invoke-RestMethod -Uri $storageUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30
                $totalStorageTB = 0
                foreach ($controller in $storageResponse.Members) {
                    $controllerUri = "$baseUrl$($controller.'@odata.id')"
                    $controllerInfo = Invoke-RestMethod -Uri $controllerUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30
                    foreach ($drive in $controllerInfo.Drives) {
                        $driveUri = "$baseUrl$($drive.'@odata.id')"
                        $driveInfo = Invoke-RestMethod -Uri $driveUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30
                        if ($driveInfo.CapacityBytes) {
                            $totalStorageTB += $driveInfo.CapacityBytes / 1TB
                        }
                    }
                }
                $result | Add-Member -MemberType NoteProperty -Name "TotalStorageTB" -Value ([math]::Round($totalStorageTB, 2))
            } catch {
                $result | Add-Member -MemberType NoteProperty -Name "TotalStorageTB" -Value "Unknown"
            }

            # Network Information
            $networkUri = "$baseUrl$($systemInfo.NetworkInterfaces.'@odata.id')"
            try {
                $networkResponse = Invoke-RestMethod -Uri $networkUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30
                $nicCount = $networkResponse.Members.Count
                $result | Add-Member -MemberType NoteProperty -Name "NetworkInterfaces" -Value $nicCount
            } catch {
                $result | Add-Member -MemberType NoteProperty -Name "NetworkInterfaces" -Value "Unknown"
            }
        }

        Write-Host "Successfully discovered server $ip ($($result.Model))" -ForegroundColor Green
        $result.Status = "Success"
        $result.Message = "Discovery completed successfully"

    } catch {
        Write-Error "Failed to discover server $ip`: $($_.Exception.Message)"
        $result.Status = "Failed"
        $result.Message = $_.Exception.Message
    }

    $results += $result
}

# Display results summary
Write-Host "`n=== Discovery Summary ===" -ForegroundColor Cyan
$successCount = ($results | Where-Object { $_.Status -eq "Success" }).Count
$failedCount = ($results | Where-Object { $_.Status -ne "Success" }).Count

Write-Host "Total servers processed: $($results.Count)" -ForegroundColor White
Write-Host "Successfully discovered: $successCount" -ForegroundColor Green
Write-Host "Failed: $failedCount" -ForegroundColor Red

if ($successCount -gt 0) {
    Write-Host "`n=== Discovered Servers ===" -ForegroundColor Green
    $results | Where-Object { $_.Status -eq "Success" } | Format-Table IPAddress, Model, SerialNumber, Manufacturer, PowerState -AutoSize
}

if ($failedCount -gt 0) {
    Write-Host "`n=== Failed Operations ===" -ForegroundColor Red
    $results | Where-Object { $_.Status -ne "Success" } | Format-Table IPAddress, Status, Message -AutoSize
}

# Export results
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$results | Export-Csv -Path (Join-Path $OutputPath "server-discovery-results-$timestamp.csv") -NoTypeInformation
$results | ConvertTo-Json | Out-File (Join-Path $OutputPath "server-discovery-results-$timestamp.json")

Write-Host "`nResults exported to:" -ForegroundColor Cyan
Write-Host "  CSV: $(Join-Path $OutputPath "server-discovery-results-$timestamp.csv")" -ForegroundColor White
Write-Host "  JSON: $(Join-Path $OutputPath "server-discovery-results-$timestamp.json")" -ForegroundColor White

# Create consolidated inventory file
$consolidatedPath = Join-Path $OutputPath "server-inventory.json"
if (Test-Path $consolidatedPath) {
    $existingInventory = Get-Content $consolidatedPath | ConvertFrom-Json
    $updatedInventory = @($existingInventory) + @($results | Where-Object { $_.Status -eq "Success" })
} else {
    $updatedInventory = $results | Where-Object { $_.Status -eq "Success" }
}

$updatedInventory | ConvertTo-Json -Depth 10 | Out-File $consolidatedPath -Encoding UTF8
Write-Host "  Consolidated inventory: $consolidatedPath" -ForegroundColor White