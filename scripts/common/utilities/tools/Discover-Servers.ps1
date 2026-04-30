<#
.SYNOPSIS
    Discovers Azure Local servers via Redfish API for ZTP deployment with comprehensive hardware inventory.

.DESCRIPTION
    Uses Redfish API to discover Dell PowerEdge servers with iDRAC, collecting
    detailed hardware information including system details, chassis, power, thermal,
    CPUs, memory, storage, network adapters, BIOS configuration, iDRAC settings,
    and firmware inventory for comprehensive ZTP preparation.

.PARAMETER Credential
    PSCredential object for BMC/iDRAC authentication

.PARAMETER ServerIPs
    One or more iDRAC IP addresses to target. If not specified, all servers from environment.yaml are used.

.PARAMETER Full
    Include detailed hardware inventory in discovery results (enabled by default for comprehensive discovery)

.EXAMPLE
    .\Discover-Servers.ps1 -Full

    Discovers all servers from config using Key Vault credentials with full hardware inventory.

.EXAMPLE
    $Credential = Get-Credential
    .\Discover-Servers.ps1 -Credential $Credential -Full

    Discovers all servers defined in config with full hardware inventory details.

.EXAMPLE
    .\Discover-Servers.ps1 -ServerIPs "192.168.1.100","192.168.1.101" -Full

    Discovers specific servers with full hardware inventory.

.NOTES
    Requires:
    - PowerShell 7.0+
    - Network access to BMC/iDRAC interfaces
    - Valid BMC credentials with system read permissions
    - AzureLocalConfig.psm1 module for configuration loading
    - Az.KeyVault module (if using Key Vault for credentials)
    - Key Vault name and secret name in environment.yaml (keyvault.platform_name, ztp.idrac_secret_name)
#>

param(
    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory=$false)]
    [string[]]$ServerIPs,

    [Parameter(Mandatory=$false)]
    [switch]$Full
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
if ($ServerIPs) {
    $serverIPs = $ServerIPs
} else {
    $serverIPs = $config.GetIdracIPs()
}

# Retrieve credentials from Key Vault if not provided
if (!$Credential) {
    $keyVaultName = $config.GetValue('keyvault.platform_name')
    $secretName = $config.GetValue('ztp.idrac_secret_name')
    if (!$keyVaultName -or !$secretName) {
        throw "Key Vault name and secret name must be configured in environment.yaml under keyvault.platform_name and ztp.idrac_secret_name"
    }
    Write-Host "Retrieving credentials from Azure Key Vault '$keyVaultName'..." -ForegroundColor Cyan
    $secret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName
    if (!$secret) {
        throw "Failed to retrieve secret '$secretName' from Key Vault '$keyVaultName'"
    }
    $credString = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
    if ($credString -notmatch ':') {
        throw "Secret value must be in format 'username:password'"
    }
    $username, $password = $credString -split ':', 2
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    $Credential = New-Object PSCredential ($username, $securePassword)
    Write-Host "✓ Credentials retrieved successfully" -ForegroundColor Green
}

Write-Host "Starting server discovery for $($serverIPs.Count) servers..." -ForegroundColor Green
Write-Host "Server IPs: $($serverIPs -join ', ')" -ForegroundColor Cyan

$results = @()

foreach ($ip in $serverIPs) {
    try {
        Write-Host "Discovering server at $ip..." -ForegroundColor Yellow

        $baseUrl = "https://$ip"

        # Test connectivity and get basic system information
        $systemUri = "$baseUrl/redfish/v1/Systems"
        $systemResponse = Invoke-RestMethod -Uri $systemUri -Credential $Credential -Method GET -SkipCertificateCheck -TimeoutSec 30

        # Get the first system (usually the only one)
        $system = $systemResponse.Members[0]
        $systemDetailsUri = "$baseUrl$($system.'@odata.id')"
        $systemDetails = Invoke-RestMethod -Uri $systemDetailsUri -Credential $Credential -Method GET -SkipCertificateCheck

        # Initialize the comprehensive discovery object
        $discovery = [PSCustomObject]@{
            CollectedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            iDRACIP = $ip
            ScriptVersion = "2.0.0"
            System = [PSCustomObject]@{
                ServiceTag = $systemDetails.SerialNumber
                Model = $systemDetails.Model
                Manufacturer = $systemDetails.Manufacturer
                SerialNumber = $systemDetails.SerialNumber
                HostName = $systemDetails.HostName
                PowerState = $systemDetails.PowerState
                IndicatorLED = $systemDetails.IndicatorLED
                BiosVersion = $systemDetails.BiosVersion
                MemorySummary = [PSCustomObject]@{
                    TotalGB = ($systemDetails.MemorySummary.TotalSystemMemoryGiB)
                    Status = $systemDetails.MemorySummary.Status.Health
                }
                ProcessorSummary = [PSCustomObject]@{
                    Model = $systemDetails.ProcessorSummary.Model
                    Count = $systemDetails.ProcessorSummary.Count
                    Status = $systemDetails.ProcessorSummary.Status.Health
                }
            }
            Chassis = $null
            Power = $null
            Thermal = $null
            PCIDevices = @()
            Sensors = @()
            CPUs = @()
            Memory = @()
            Storage = [PSCustomObject]@{
                Controllers = @()
                Drives = @()
                Volumes = @()
            }
            NetworkAdapters = @()
            BIOSConfiguration = $null
            iDRACConfiguration = $null
            Firmware = @()
            Errors = @()
        }

        # Include hardware inventory if requested
        if ($Full) {
            try {
                Write-Host "  Collecting detailed hardware inventory..." -ForegroundColor Gray

                # Get Chassis information
                try {
                    $chassisUri = "$baseUrl/redfish/v1/Chassis"
                    $chassisResponse = Invoke-RestMethod -Uri $chassisUri -Credential $Credential -Method GET -SkipCertificateCheck
                    $chassis = $chassisResponse.Members[0]
                    $chassisDetailsUri = "$baseUrl$($chassis.'@odata.id')"
                    $chassisDetails = Invoke-RestMethod -Uri $chassisDetailsUri -Credential $Credential -Method GET -SkipCertificateCheck
                    $discovery.Chassis = [PSCustomObject]@{
                        ChassisType = $chassisDetails.ChassisType
                        Manufacturer = $chassisDetails.Manufacturer
                        Model = $chassisDetails.Model
                        SKU = $chassisDetails.SKU
                        SerialNumber = $chassisDetails.SerialNumber
                        PartNumber = $chassisDetails.PartNumber
                        AssetTag = $chassisDetails.AssetTag
                        Status = $chassisDetails.Status
                    }
                } catch {
                    $discovery.Errors += [PSCustomObject]@{ Component = "Chassis"; Error = $_.Exception.Message }
                }

                # Get Power information
                try {
                    $powerUri = "$baseUrl/redfish/v1/Power"
                    $powerDetails = Invoke-RestMethod -Uri $powerUri -Credential $Credential -Method GET -SkipCertificateCheck
                    $discovery.Power = [PSCustomObject]@{
                        PowerControl = $powerDetails.PowerControl
                        PowerSupplies = $powerDetails.PowerSupplies
                    }
                } catch {
                    $discovery.Errors += [PSCustomObject]@{ Component = "Power"; Error = $_.Exception.Message }
                }

                # Get Thermal information
                try {
                    $thermalUri = "$baseUrl/redfish/v1/Thermal"
                    $thermalDetails = Invoke-RestMethod -Uri $thermalUri -Credential $Credential -Method GET -SkipCertificateCheck
                    $discovery.Thermal = [PSCustomObject]@{
                        Temperatures = $thermalDetails.Temperatures
                        Fans = $thermalDetails.Fans
                    }
                } catch {
                    $discovery.Errors += [PSCustomObject]@{ Component = "Thermal"; Error = $_.Exception.Message }
                }

                # Get PCIe Devices (may not exist)
                try {
                    $pciUri = "$baseUrl/redfish/v1/PCIeDevices"
                    $pciDetails = Invoke-RestMethod -Uri $pciUri -Credential $Credential -Method GET -SkipCertificateCheck
                    $discovery.PCIDevices = $pciDetails.Members
                } catch {
                    $discovery.Errors += [PSCustomObject]@{ Component = "PCIDevices"; Error = $_.Exception.Message }
                }

                # Get Sensors
                try {
                    $sensorsUri = "$baseUrl/redfish/v1/Sensors"
                    $sensorsDetails = Invoke-RestMethod -Uri $sensorsUri -Credential $Credential -Method GET -SkipCertificateCheck
                    $discovery.Sensors = $sensorsDetails.Members
                } catch {
                    $discovery.Errors += [PSCustomObject]@{ Component = "Sensors"; Error = $_.Exception.Message }
                }

                # Get CPUs
                try {
                    $processorsUri = "$baseUrl/redfish/v1/Systems/System.Embedded.1/Processors"
                    $processorsResponse = Invoke-RestMethod -Uri $processorsUri -Credential $Credential -Method GET -SkipCertificateCheck
                    $cpus = @()
                    foreach ($proc in $processorsResponse.Members) {
                        $procDetailsUri = "$baseUrl$($proc.'@odata.id')"
                        $procDetails = Invoke-RestMethod -Uri $procDetailsUri -Credential $Credential -Method GET -SkipCertificateCheck
                        $cpus += [PSCustomObject]@{
                            Socket = $procDetails.Socket
                            Manufacturer = $procDetails.Manufacturer
                            Model = $procDetails.Model
                            ProcessorType = $procDetails.ProcessorType
                            TotalCores = $procDetails.TotalCores
                            TotalThreads = $procDetails.TotalThreads
                            MaxSpeedMHz = $procDetails.MaxSpeedMHz
                            Status = $procDetails.Status
                        }
                    }
                    $discovery.CPUs = $cpus
                } catch {
                    $discovery.Errors += [PSCustomObject]@{ Component = "CPUs"; Error = $_.Exception.Message }
                }

                # Get Memory
                try {
                    $memoryUri = "$baseUrl/redfish/v1/Systems/System.Embedded.1/Memory"
                    $memoryResponse = Invoke-RestMethod -Uri $memoryUri -Credential $Credential -Method GET -SkipCertificateCheck
                    $memories = @()
                    foreach ($mem in $memoryResponse.Members) {
                        $memDetailsUri = "$baseUrl$($mem.'@odata.id')"
                        $memDetails = Invoke-RestMethod -Uri $memDetailsUri -Credential $Credential -Method GET -SkipCertificateCheck
                        $memories += [PSCustomObject]@{
                            Slot = $memDetails.DeviceLocator
                            Manufacturer = $memDetails.Manufacturer
                            PartNumber = $memDetails.PartNumber
                            SerialNumber = $memDetails.SerialNumber
                            CapacityGB = $memDetails.CapacityMiB / 1024
                            SpeedMHz = $memDetails.OperatingSpeedMhz
                            MemoryType = $memDetails.MemoryType
                            DataWidthBits = $memDetails.DataWidthBits
                            RankCount = $memDetails.RankCount
                            Status = $memDetails.Status
                        }
                    }
                    $discovery.Memory = $memories
                } catch {
                    $discovery.Errors += [PSCustomObject]@{ Component = "Memory"; Error = $_.Exception.Message }
                }

                # Get Storage
                try {
                    $storageUri = "$baseUrl/redfish/v1/Systems/System.Embedded.1/Storage"
                    $storageResponse = Invoke-RestMethod -Uri $storageUri -Credential $Credential -Method GET -SkipCertificateCheck
                    $controllers = @()
                    $drives = @()
                    foreach ($storage in $storageResponse.Members) {
                        $storageDetailsUri = "$baseUrl$($storage.'@odata.id')"
                        $storageDetails = Invoke-RestMethod -Uri $storageDetailsUri -Credential $Credential -Method GET -SkipCertificateCheck
                        $controllers += [PSCustomObject]@{
                            Id = $storageDetails.Id
                            Name = $storageDetails.Name
                            StorageControllers = $storageDetails.StorageControllers
                        }
                        foreach ($drive in $storageDetails.Drives) {
                            $driveDetailsUri = "$baseUrl$($drive.'@odata.id')"
                            $driveDetails = Invoke-RestMethod -Uri $driveDetailsUri -Credential $Credential -Method GET -SkipCertificateCheck
                            $drives += [PSCustomObject]@{
                                Id = $driveDetails.Id
                                Name = $driveDetails.Name
                                Manufacturer = $driveDetails.Manufacturer
                                Model = $driveDetails.Model
                                MediaType = $driveDetails.MediaType
                                Protocol = $driveDetails.Protocol
                                CapacityBytes = $driveDetails.CapacityBytes
                                CapacityGB = [math]::Round($driveDetails.CapacityBytes / 1GB, 2)
                                SerialNumber = $driveDetails.SerialNumber
                                PartNumber = $driveDetails.PartNumber
                                Revision = $driveDetails.Revision
                                RotationSpeedRPM = $driveDetails.RotationSpeedRPM
                                Status = $driveDetails.Status
                            }
                        }
                    }
                    $discovery.Storage.Controllers = $controllers
                    $discovery.Storage.Drives = $drives
                    # Volumes would be under Volumes if present, but example shows empty
                } catch {
                    $discovery.Errors += [PSCustomObject]@{ Component = "Storage"; Error = $_.Exception.Message }
                }

                # Get Network Adapters
                try {
                    $networkUri = "$baseUrl/redfish/v1/Systems/System.Embedded.1/NetworkInterfaces"
                    $networkResponse = Invoke-RestMethod -Uri $networkUri -Credential $Credential -Method GET -SkipCertificateCheck
                    $adapters = @()
                    foreach ($nic in $networkResponse.Members) {
                        $nicDetailsUri = "$baseUrl$($nic.'@odata.id')"
                        $nicDetails = Invoke-RestMethod -Uri $nicDetailsUri -Credential $Credential -Method GET -SkipCertificateCheck
                        $adapters += [PSCustomObject]@{
                            Id = $nicDetails.Id
                            Name = $nicDetails.Name
                            Manufacturer = $nicDetails.Manufacturer
                            Model = $nicDetails.Model
                            PartNumber = $nicDetails.PartNumber
                            SerialNumber = $nicDetails.SerialNumber
                            Status = $nicDetails.Status
                            Ports = $nicDetails.NetworkPorts
                        }
                    }
                    $discovery.NetworkAdapters = $adapters
                } catch {
                    $discovery.Errors += [PSCustomObject]@{ Component = "NetworkAdapters"; Error = $_.Exception.Message }
                }

                # Get BIOS Configuration
                try {
                    $biosUri = "$baseUrl/redfish/v1/Systems/System.Embedded.1/Bios"
                    $biosDetails = Invoke-RestMethod -Uri $biosUri -Credential $Credential -Method GET -SkipCertificateCheck
                    $discovery.BIOSConfiguration = [PSCustomObject]@{
                        BiosVersion = $biosDetails.Version
                        Attributes = $biosDetails.Attributes
                    }
                } catch {
                    $discovery.Errors += [PSCustomObject]@{ Component = "BIOSConfiguration"; Error = $_.Exception.Message }
                }

                # Get iDRAC Configuration
                try {
                    $idracUri = "$baseUrl/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DellAttributes/iDRAC.Embedded.1"
                    $idracDetails = Invoke-RestMethod -Uri $idracUri -Credential $Credential -Method GET -SkipCertificateCheck
                    $discovery.iDRACConfiguration = [PSCustomObject]@{
                        Attributes = $idracDetails.Attributes
                    }
                } catch {
                    $discovery.Errors += [PSCustomObject]@{ Component = "iDRACConfiguration"; Error = $_.Exception.Message }
                }

                # Get Firmware Inventory
                try {
                    $firmwareUri = "$baseUrl/redfish/v1/UpdateService/FirmwareInventory"
                    $firmwareResponse = Invoke-RestMethod -Uri $firmwareUri -Credential $Credential -Method GET -SkipCertificateCheck
                    $firmwares = @()
                    foreach ($fw in $firmwareResponse.Members) {
                        $fwDetailsUri = "$baseUrl$($fw.'@odata.id')"
                        $fwDetails = Invoke-RestMethod -Uri $fwDetailsUri -Credential $Credential -Method GET -SkipCertificateCheck
                        $firmwares += [PSCustomObject]@{
                            Id = $fwDetails.Id
                            Name = $fwDetails.Name
                            Version = $fwDetails.Version
                            Updateable = $fwDetails.Updateable
                            Status = $fwDetails.Status
                        }
                    }
                    $discovery.Firmware = $firmwares
                } catch {
                    $discovery.Errors += [PSCustomObject]@{ Component = "Firmware"; Error = $_.Exception.Message }
                }

            } catch {
                Write-Warning "Could not retrieve hardware inventory for $ip`: $($_.Exception.Message)"
                $discovery.Errors += [PSCustomObject]@{ Component = "General"; Error = $_.Exception.Message }
            }
        }

        $results += $discovery
        Write-Host "Successfully discovered server at $ip ($($systemDetails.Model))" -ForegroundColor Green

    } catch {
        Write-Warning "Failed to discover server at $ip`: $($_.Exception.Message)"
        $results += [PSCustomObject]@{
            iDRACIP = $ip
            CollectedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            ScriptVersion = "2.0.0"
            Errors = @([PSCustomObject]@{ Component = "Discovery"; Error = $_.Exception.Message })
        }
    }
}

# Export results
$outputDir = Join-Path $repoRoot "config\dell\discovery"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# Create individual JSON files for each server
foreach ($result in $results) {
    $serverName = $result.iDRACIP -replace '\.', '-'
    $individualJsonPath = Join-Path $outputDir "$serverName.json"
    $result | ConvertTo-Json -Depth 10 | Out-File $individualJsonPath -Encoding UTF8
}

# Create combined CSV and JSON files (basic summary for CSV)
$csvPath = Join-Path $outputDir "server-discovery-results.csv"
$jsonPath = Join-Path $outputDir "server-discovery-results.json"

# For CSV, create basic summary
$csvResults = $results | ForEach-Object {
    [PSCustomObject]@{
        iDRACIP = $_.iDRACIP
        CollectedAt = $_.CollectedAt
        Model = $_.System.Model
        SerialNumber = $_.System.SerialNumber
        Manufacturer = $_.System.Manufacturer
        PowerState = $_.System.PowerState
        BiosVersion = $_.System.BiosVersion
        HostName = $_.System.HostName
        TotalMemoryGB = $_.System.MemorySummary.TotalGB
        ProcessorCount = $_.System.ProcessorSummary.Count
        ProcessorModel = $_.System.ProcessorSummary.Model
        DriveCount = $_.Storage.Drives.Count
        Errors = ($_.Errors | ForEach-Object { "$($_.Component): $($_.Error)" }) -join "; "
    }
}
$csvResults | Export-Csv -Path $csvPath -NoTypeInformation
$results | ConvertTo-Json -Depth 10 | Out-File $jsonPath -Encoding UTF8

Write-Host "Discovery complete. Results saved to:" -ForegroundColor Green
Write-Host "  Individual JSON files: config/dell/discovery/<server-ip>.json" -ForegroundColor Cyan
Write-Host "  Combined CSV: $csvPath" -ForegroundColor Cyan
Write-Host "  Combined JSON: $jsonPath" -ForegroundColor Cyan
Write-Host "Discovered servers: $(($results | Where-Object { $_.System -and $_.System.Model }).Count)" -ForegroundColor Cyan
Write-Host "Failed discoveries: $(($results | Where-Object { -not $_.System -or -not $_.System.Model }).Count)" -ForegroundColor Yellow