<#
.SYNOPSIS
    Performs manual Redfish discovery of servers.

.DESCRIPTION
    Manually discovers Azure Local servers via Redfish API when automated
    discovery scripts are not available or for unsupported hardware.

.PARAMETER ServerIPs
    Array of BMC/iDRAC IP addresses for target servers

.PARAMETER Credential
    PSCredential object for BMC/iDRAC authentication

.EXAMPLE
    $cred = Get-Credential
    .\Discover-Servers-Manual.ps1 -ServerIPs "192.168.200.11","192.168.200.12" -Credential $cred

    Discovers servers manually using provided IPs and credentials

.NOTES
    Requires:
    - PowerShell 7.0+
    - Network access to BMC/iDRAC interfaces
    - Valid BMC credentials with system read permissions
#>

param(
    [Parameter(Mandatory=$true)]
    [string[]]$ServerIPs,

    [Parameter(Mandatory=$true)]
    [PSCredential]$Credential
)

#Requires -Version 7.0

Write-Host "Starting manual server discovery for $($ServerIPs.Count) servers..." -ForegroundColor Green
Write-Host "Server IPs: $($ServerIPs -join ', ')" -ForegroundColor Cyan

$results = @()

foreach ($ip in $ServerIPs) {
    try {
        Write-Host "Discovering server at $ip..." -ForegroundColor Yellow

        $baseUrl = "https://$ip"

        # Test connectivity and get basic system information
        $systemUri = "$baseUrl/redfish/v1/Systems"
        $systemResponse = Invoke-RestMethod -Uri $systemUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30

        # Get the first system (usually the only one)
        $system = $systemResponse.Members[0]
        $systemDetailsUri = "$baseUrl$system.'@odata.id'"
        $systemDetails = Invoke-RestMethod -Uri $systemDetailsUri -Credential $Credential -Method GET -SkipCertificateCheck

        $serverInfo = [PSCustomObject]@{
            IPAddress = $ip
            Model = $systemDetails.Model
            SerialNumber = $systemDetails.SerialNumber
            Manufacturer = $systemDetails.Manufacturer
            Status = "Discovered"
            Timestamp = Get-Date
            PowerState = $systemDetails.PowerState
            BiosVersion = $systemDetails.BiosVersion
            HostName = $systemDetails.HostName
        }

        $results += $serverInfo
        Write-Host "Successfully discovered server at $ip ($($systemDetails.Model))" -ForegroundColor Green

    } catch {
        Write-Warning "Failed to discover server at $ip`: $($_.Exception.Message)"
        $results += [PSCustomObject]@{
            IPAddress = $ip
            Status = "Failed"
            Error = $_.Exception.Message
            Timestamp = Get-Date
        }
    }
}

# Export results
$results | Export-Csv -Path ".\server-discovery-manual-results.csv" -NoTypeInformation
$results | ConvertTo-Json | Out-File ".\server-discovery-manual-results.json"

Write-Host "Manual discovery complete. Results saved to CSV and JSON files." -ForegroundColor Green
Write-Host "Discovered servers: $(($results | Where-Object { $_.Status -eq 'Discovered' }).Count)" -ForegroundColor Cyan
Write-Host "Failed discoveries: $(($results | Where-Object { $_.Status -eq 'Failed' }).Count)" -ForegroundColor Yellow