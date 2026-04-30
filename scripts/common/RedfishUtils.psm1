# Azure Local ZTP Redfish Utilities
# PowerShell module for iDRAC Redfish API operations
# Uses Invoke-RestMethod with -SkipCertificateCheck for proper SSL handling

#Requires -Version 7.0

class RedfishSession {
    [string]$BaseUrl
    [PSCredential]$Credential
    [hashtable]$Headers

    RedfishSession([string]$idracIP, [PSCredential]$credential) {
        $this.BaseUrl = "https://$idracIP"
        $this.Credential = $credential
        $this.Headers = @{
            'Content-Type' = 'application/json'
            'Accept'       = 'application/json'
        }
    }

    [bool] Connect() {
        try {
            Write-Host "Attempting to connect to iDRAC at $($this.BaseUrl)..." -ForegroundColor Gray
            $response = Invoke-RestMethod -Uri "$($this.BaseUrl)/redfish/v1" `
                -Credential $this.Credential `
                -SkipCertificateCheck `
                -Headers $this.Headers `
                -TimeoutSec 30 `
                -ErrorAction Stop

            Write-Host "✓ Connected to iDRAC - Redfish version: $($response.RedfishVersion)" -ForegroundColor Green
            return $true
        }
        catch {
            Write-Host "✗ Failed to connect to iDRAC at $($this.BaseUrl)" -ForegroundColor Red
            Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
            if ($_.Exception.InnerException) {
                Write-Host "  Details: $($_.Exception.InnerException.Message)" -ForegroundColor Red
            }
            return $false
        }
    }

    [PSCustomObject] Get([string]$endpoint) {
        try {
            $response = Invoke-RestMethod -Uri "$($this.BaseUrl)$endpoint" `
                -Credential $this.Credential `
                -SkipCertificateCheck `
                -Headers $this.Headers `
                -TimeoutSec 30 `
                -ErrorAction Stop
            return $response
        }
        catch {
            Write-Host "✗ GET $endpoint failed: $($_.Exception.Message)" -ForegroundColor Red
            return $null
        }
    }

    [PSCustomObject] Post([string]$endpoint, [object]$data) {
        try {
            $body = $data | ConvertTo-Json -Depth 10
            $response = Invoke-RestMethod -Uri "$($this.BaseUrl)$endpoint" `
                -Method Post `
                -Credential $this.Credential `
                -SkipCertificateCheck `
                -Headers $this.Headers `
                -Body $body `
                -TimeoutSec 30 `
                -ErrorAction Stop
            return @{ success = $true; data = $response }
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = $_.Exception.Response.StatusCode
            }
            Write-Host "✗ POST $endpoint failed: $statusCode $($_.Exception.Message)" -ForegroundColor Red
            return @{ success = $false; error = $_.Exception.Message }
        }
    }

    [PSCustomObject] Patch([string]$endpoint, [object]$data) {
        try {
            $body = $data | ConvertTo-Json -Depth 10
            $response = Invoke-RestMethod -Uri "$($this.BaseUrl)$endpoint" `
                -Method Patch `
                -Credential $this.Credential `
                -SkipCertificateCheck `
                -Headers $this.Headers `
                -Body $body `
                -TimeoutSec 30 `
                -ErrorAction Stop
            return @{ success = $true; data = $response }
        }
        catch {
            Write-Host "✗ PATCH $endpoint failed: $($_.Exception.Message)" -ForegroundColor Red
            return @{ success = $false; error = $_.Exception.Message }
        }
    }

    [PSCustomObject] Delete([string]$endpoint) {
        try {
            $response = Invoke-WebRequest -Uri "$($this.BaseUrl)$endpoint" `
                -Method Delete `
                -Credential $this.Credential `
                -SkipCertificateCheck `
                -Headers $this.Headers `
                -TimeoutSec 30 `
                -ErrorAction Stop
            $jobId = $null
            if ($response.Headers['Location']) {
                $locationHeader = $response.Headers['Location']
                if ($locationHeader -is [array]) { $locationHeader = $locationHeader[0] }
                $jobId = $locationHeader.Split('/')[-1]
            }
            return @{ success = $true; statusCode = $response.StatusCode; jobId = $jobId }
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            Write-Host "✗ DELETE $endpoint failed: $statusCode $($_.Exception.Message)" -ForegroundColor Red
            return @{ success = $false; error = $_.Exception.Message; statusCode = $statusCode }
        }
    }

    [void] Disconnect() {
        # Basic auth doesn't need session cleanup
    }
}

function New-RedfishSession {
    <#
    .SYNOPSIS
        Creates a new Redfish session to an iDRAC

    .PARAMETER IdracIP
        IP address of the iDRAC

    .PARAMETER Credential
        PSCredential object with iDRAC username and password

    .EXAMPLE
        $cred = Get-Credential
        $session = New-RedfishSession -IdracIP "{idrac_ip_1}" -Credential $cred
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$IdracIP,

        [Parameter(Mandatory = $true)]
        [PSCredential]$Credential
    )

    $session = [RedfishSession]::new($IdracIP, $Credential)

    if ($session.Connect()) {
        return $session
    } else {
        throw "Failed to connect to iDRAC $IdracIP"
    }
}

function Get-SystemInfo {
    <#
    .SYNOPSIS
        Gets system information from iDRAC

    .PARAMETER Session
        Redfish session object

    .EXAMPLE
        $session = New-RedfishSession -IdracIP "{idrac_ip_1}" -Credential $cred
        $systemInfo = Get-SystemInfo -Session $session
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [RedfishSession]$Session
    )

    $system = $Session.Get("/redfish/v1/Systems/System.Embedded.1")

    if ($system) {
        return @{
            Hostname = $system.HostName
            Model = $system.Model
            Manufacturer = $system.Manufacturer
            SerialNumber = $system.SerialNumber
            BiosVersion = $system.BiosVersion
            PowerState = $system.PowerState
            Status = $system.Status
        }
    }

    return $null
}

function Get-StorageInfo {
    <#
    .SYNOPSIS
        Gets storage information from iDRAC

    .PARAMETER Session
        Redfish session object

    .EXAMPLE
        $session = New-RedfishSession -IdracIP "{idrac_ip_1}" -Credential $cred
        $storageInfo = Get-StorageInfo -Session $session
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [RedfishSession]$Session
    )

    $storage = $Session.Get("/redfish/v1/Systems/System.Embedded.1/Storage")

    return $storage
}

function Get-NetworkAdapters {
    <#
    .SYNOPSIS
        Gets network adapter information from iDRAC

    .PARAMETER Session
        Redfish session object

    .EXAMPLE
        $session = New-RedfishSession -IdracIP "{idrac_ip_1}" -Credential $cred
        $adapters = Get-NetworkAdapters -Session $session
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [RedfishSession]$Session
    )

    $adapters = $Session.Get("/redfish/v1/Systems/System.Embedded.1/NetworkAdapters")

    return $adapters
}

function Insert-VirtualMedia {
    <#
    .SYNOPSIS
        Inserts ISO to virtual media

    .PARAMETER Session
        Redfish session object

    .PARAMETER IsoPath
        Network path to the ISO file

    .EXAMPLE
        $session = New-RedfishSession -IdracIP "{idrac_ip_1}" -Credential $cred
        Insert-VirtualMedia -Session $session -IsoPath "{share_network_path}\{iso_filename}"
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [RedfishSession]$Session,

        [Parameter(Mandatory = $true)]
        [string]$IsoPath
    )

    # First, eject any existing virtual media
    $Session.Post("/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD/Actions/VirtualMedia.EjectMedia", @{})

    # Wait a moment
    Start-Sleep -Seconds 2

    # Insert the ISO image
    $insertData = @{
        Image = $IsoPath
        Inserted = $true
        WriteProtected = $true
    }

    $result = $Session.Post("/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD/Actions/VirtualMedia.InsertMedia", $insertData)

    return $result
}

function Set-BootSource {
    <#
    .SYNOPSIS
        Sets the boot source for the next boot

    .PARAMETER Session
        Redfish session object

    .PARAMETER BootSource
        Boot source (e.g., "Cd", "Hdd", "Pxe")

    .EXAMPLE
        $session = New-RedfishSession -IdracIP "{idrac_ip_1}" -Credential $cred
        Set-BootSource -Session $session -BootSource "Cd"
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [RedfishSession]$Session,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Cd", "Hdd", "Pxe")]
        [string]$BootSource
    )

    $bootData = @{
        Boot = @{
            BootSourceOverrideEnabled = "Once"
            BootSourceOverrideTarget = $BootSource
        }
    }

    $result = $Session.Patch("/redfish/v1/Systems/System.Embedded.1", $bootData)

    return $result
}

function Restart-System {
    <#
    .SYNOPSIS
        Restarts the system

    .PARAMETER Session
        Redfish session object

    .PARAMETER ForceRestart
        Force restart even if OS is running

    .EXAMPLE
        $session = New-RedfishSession -IdracIP "{idrac_ip_1}" -Credential $cred
        Restart-System -Session $session -ForceRestart $true
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [RedfishSession]$Session,

        [Parameter(Mandatory = $false)]
        [bool]$ForceRestart = $true
    )

    $resetType = if ($ForceRestart) { "ForceRestart" } else { "GracefulRestart" }

    $resetData = @{
        ResetType = $resetType
    }

    $result = $Session.Post("/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset", $resetData)

    return $result
}

function Get-StorageVolumes {
    <#
    .SYNOPSIS
        Gets storage volumes (virtual disks) for a specific controller from iDRAC

    .PARAMETER Session
        Redfish session object

    .PARAMETER ControllerFQDD
        Storage controller FQDD (e.g., AHCI.Slot.4-1)

    .EXAMPLE
        $session = New-RedfishSession -IdracIP "{idrac_ip_1}" -Credential $cred
        $volumes = Get-StorageVolumes -Session $session -ControllerFQDD "AHCI.Slot.4-1"
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [RedfishSession]$Session,

        [Parameter(Mandatory = $true)]
        [string]$ControllerFQDD
    )

    $volumes = $Session.Get("/redfish/v1/Systems/System.Embedded.1/Storage/$ControllerFQDD/Volumes")

    return $volumes
}

function Remove-StorageVolume {
    <#
    .SYNOPSIS
        Deletes a virtual disk (volume) from a storage controller via iDRAC Redfish API

    .PARAMETER Session
        Redfish session object

    .PARAMETER ControllerFQDD
        Storage controller FQDD (e.g., AHCI.Slot.4-1)

    .PARAMETER VolumeFQDD
        Virtual disk FQDD (e.g., Disk.Virtual.0:AHCI.Slot.4-1)

    .EXAMPLE
        $session = New-RedfishSession -IdracIP "{idrac_ip_1}" -Credential $cred
        Remove-StorageVolume -Session $session -ControllerFQDD "AHCI.Slot.4-1" -VolumeFQDD "Disk.Virtual.0:AHCI.Slot.4-1"
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [RedfishSession]$Session,

        [Parameter(Mandatory = $true)]
        [string]$ControllerFQDD,

        [Parameter(Mandatory = $true)]
        [string]$VolumeFQDD
    )

    $result = $Session.Delete("/redfish/v1/Systems/System.Embedded.1/Storage/$ControllerFQDD/Volumes/$VolumeFQDD")

    return $result
}

function New-StorageVolume {
    <#
    .SYNOPSIS
        Creates a new virtual disk (volume) on a storage controller via iDRAC Redfish API

    .PARAMETER Session
        Redfish session object

    .PARAMETER ControllerFQDD
        Storage controller FQDD (e.g., AHCI.Slot.4-1)

    .PARAMETER RAIDType
        RAID level (e.g., RAID0, RAID1, RAID5, RAID6, RAID10, RAID50, RAID60)

    .PARAMETER DiskFQDDs
        Array of physical disk FQDDs to include in the virtual disk

    .PARAMETER Name
        Optional name for the virtual disk

    .EXAMPLE
        $session = New-RedfishSession -IdracIP "{idrac_ip_1}" -Credential $cred
        $disks = @("Disk.Bay.0:Enclosure.Internal.0-1:AHCI.Slot.4-1", "Disk.Bay.1:Enclosure.Internal.0-1:AHCI.Slot.4-1")
        New-StorageVolume -Session $session -ControllerFQDD "AHCI.Slot.4-1" -RAIDType "RAID1" -DiskFQDDs $disks -Name "BOSS_RAID1"
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [RedfishSession]$Session,

        [Parameter(Mandatory = $true)]
        [string]$ControllerFQDD,

        [Parameter(Mandatory = $true)]
        [ValidateSet("RAID0", "RAID1", "RAID5", "RAID6", "RAID10", "RAID50", "RAID60")]
        [string]$RAIDType,

        [Parameter(Mandatory = $true)]
        [string[]]$DiskFQDDs,

        [Parameter(Mandatory = $false)]
        [string]$Name
    )

    $driveLinks = @()
    foreach ($disk in $DiskFQDDs) {
        $driveLinks += @{ '@odata.id' = "/redfish/v1/Systems/System.Embedded.1/Storage/Drives/$disk" }
    }

    $payload = @{
        RAIDType = $RAIDType
        Links    = @{
            Drives = $driveLinks
        }
    }

    if ($Name) {
        $payload['Name'] = $Name
    }

    $result = $Session.Post("/redfish/v1/Systems/System.Embedded.1/Storage/$ControllerFQDD/Volumes", $payload)

    return $result
}

# Export functions
Export-ModuleMember -Function New-RedfishSession, Get-SystemInfo, Get-StorageInfo, Get-StorageVolumes, Remove-StorageVolume, New-StorageVolume, Get-NetworkAdapters, Insert-VirtualMedia, Set-BootSource, Restart-System