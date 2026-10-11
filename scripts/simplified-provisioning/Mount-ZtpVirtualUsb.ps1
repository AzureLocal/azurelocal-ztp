#Requires -Version 7.0
<#
.SYNOPSIS
Inserts each node's maintenance virtual-USB image READ-WRITE on its iDRAC USB-stick slot, boots it once, ejects it, or
shows its state.
.DESCRIPTION
Mount: Redfish VirtualMedia.InsertMedia of //<ShareHost>/<ShareName>/<ImageNamePrefix><node>.img on the manager's
USB-stick (RemovableDisk) slot over CIFS with WriteProtected=false, then a read-back that proves the image is attached and
not write-protected, then a one-time boot override to Usb and, with -Restart, a power-cycle (ForceRestart when on, On
when off). The image stays inserted after the maintenance environment installs itself on the boot disk: its setup
service writes the ownership voucher back to the one writable USB drive it finds (\vouchers\<serial>\), so the slot must
stay attached and writable until Wait-ZtpVoucher.ps1 sees the voucher.
Eject: VirtualMedia.EjectMedia on the USB-stick slot that holds this node's image (another image is left alone unless
-Force), so the image file is closed before Read-ZtpVoucherFromImage.ps1 opens it.
Status: Inserted, Image, WriteProtected, power state and boot override per node (read-only).

-RfsWriteAttribute additionally sets the iDRAC attributes RFS.<n>.WriteProtected to 'Read Write' before the insert
(restored to 'Read Only' on Eject), for firmware that ignores WriteProtected in InsertMedia (the 7.30 registry exposes
the attribute). The share needs change rights for the share account: Publish-MaintenanceIso.ps1 -ReadWrite.

BMC addresses come from the bmc_address of each node in -Nodes or -NodesFile (or -BmcAddress for one node); the BMC account is\n-Credential. The share credential is the in-memory PSCredential that Publish-MaintenanceIso.ps1 returns.\nWithout -Execute only the plan is printed and no session is opened (no BMC call, no credential needed).
.PARAMETER NodeName
Node names (the names in -Nodes or -NodesFile; they select the per-node image <ImageNamePrefix><node>.img).
.PARAMETER Action
Mount, Eject or Status.
.PARAMETER ShareHost
Address of the share host as the iDRACs reach it (Mount).
.PARAMETER ShareName
SMB share that holds the per-node images.
.PARAMETER ImageNamePrefix
File-name prefix of the per-node images.
.PARAMETER ShareCredential
Share account credential (Publish-MaintenanceIso.ps1 Credential). Sent only in the InsertMedia body.
.PARAMETER ReadOnly
Insert write-protected (the proven boot; the maintenance environment then cannot write the voucher back).
.PARAMETER RfsWriteAttribute
Also set RFS.<n>.WriteProtected = Read Write before the insert (Read Only again on Eject).
.PARAMETER Restart
Power-cycle each node into the one-time USB boot after mounting.
.PARAMETER ConfirmNotClustered
Confirms the restart cannot disrupt a cluster: the maintenance boot reinstalls the machine.
.PARAMETER Force
Eject the USB-stick slot even when it holds another image.
.PARAMETER Nodes
Node objects { name, bmc_address } (service_tag is not needed here).
.PARAMETER NodesFile
JSON (or YAML) node list, see config/simplified-provisioning/nodes.example.json.
.PARAMETER BmcAddress
One BMC address instead of the node list (exactly one -NodeName).
.PARAMETER Credential
BMC account (required with -Execute).
.PARAMETER SkipCertificateCheck
Accept the BMC's self-signed certificate.
.PARAMETER Execute
Make the changes; without it only the plan is printed.
.EXAMPLE
$share = ./Publish-MaintenanceIso.ps1 -IsoPath D:\ZtpVirtualUsb\ztp-usb-node-01.img -SharePath D:\ZtpVirtualUsb -ShareName ztp-virtual-usb -ShareHost 192.0.2.10 -AllowedBmcAddress 198.51.100.11 -ReadWrite -Execute
./Mount-ZtpVirtualUsb.ps1 -NodeName node-01 -NodesFile ./nodes.json -Credential $bmcCredential -ShareHost 192.0.2.10 -ShareName ztp-virtual-usb -ShareCredential $share.Credential -Restart -ConfirmNotClustered -SkipCertificateCheck -Execute
.EXAMPLE
./Mount-ZtpVirtualUsb.ps1 -NodeName node-01 -BmcAddress 198.51.100.11 -Credential $bmcCredential -Action Eject -SkipCertificateCheck -Execute
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The parameters are read inside the stage functions and script blocks.')]
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateCount(1, 64)][string[]]$NodeName,
    [ValidateSet('Mount', 'Eject', 'Status')][string]$Action = 'Mount',
    [string]$ShareHost,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,79}$')][string]$ShareName = 'ztp-virtual-usb',
    [ValidatePattern('^[A-Za-z0-9._-]{0,40}$')][string]$ImageNamePrefix = 'ztp-usb-',
    [pscredential]$ShareCredential,
    [switch]$ReadOnly,
    [switch]$RfsWriteAttribute,
    [switch]$Restart,
    [switch]$ConfirmNotClustered,
    [switch]$Force,
    [object[]]$Nodes,
    [string]$NodesFile,
    [string]$BmcAddress,
    [pscredential]$Credential,
    [switch]$SkipCertificateCheck,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpVirtualUsb.Common.ps1')
if (-not (Get-Command New-ZtpRedfishSession -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ZtpRedfish.Common.ps1') }


if ($Action -eq 'Mount' -and [string]::IsNullOrWhiteSpace($ShareHost)) { throw '-ShareHost is required to mount.' }
if ($Restart -and $Action -ne 'Mount') { throw 'Restart is only valid with Mount.' }
if ($Restart -and -not $ConfirmNotClustered) { throw 'Restart refused: -ConfirmNotClustered is required because the maintenance boot reinstalls the machine.' }
if ($BmcAddress -and $NodeName.Count -ne 1) { throw '-BmcAddress targets one BMC: pass exactly one -NodeName.' }

foreach ($name in $NodeName) { $null = Get-ZtpNodeImageName -NodeName $name -Prefix $ImageNamePrefix }
$imageUrl = { param([string]$Node) "//$ShareHost/$ShareName/$(Get-ZtpNodeImageName -NodeName $Node -Prefix $ImageNamePrefix)" }
$writeProtected = [bool]$ReadOnly

if (-not $Execute) {
    foreach ($node in $NodeName) {
        switch ($Action) {
            'Mount' {
                if ($RfsWriteAttribute -and -not $ReadOnly) { "PLAN: $node set RFS.<n>.WriteProtected = Read Write" }
                "PLAN: $node insert $(& $imageUrl $node) on the USB-stick (RemovableDisk) slot over CIFS, WriteProtected=$writeProtected"
                "PLAN: $node verify Inserted, Image and WriteProtected=$writeProtected; one-time boot override Usb"
                if ($Restart) { "PLAN: $node power-cycle (ForceRestart, or On when off)" }
            }
            'Eject' {
                "PLAN: $node eject the USB-stick slot that holds $(Get-ZtpNodeImageName -NodeName $node -Prefix $ImageNamePrefix)"
                if ($RfsWriteAttribute) { "PLAN: $node set RFS.<n>.WriteProtected = Read Only" }
            }
            'Status' { "PLAN: $node read the USB-stick slot, power state and boot override" }
        }
    }
    return
}

function Set-ZtpRfsWriteProtection {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$ManagerPath, [Parameter(Mandatory)][ValidateSet('Read Only', 'Read Write')][string]$Value)
    $current = Invoke-ZtpRedfish -Session $Session -Path "$ManagerPath/Attributes"
    $names = @()
    if ($current -and $current.PSObject.Properties['Attributes']) {
        $names = @($current.Attributes.PSObject.Properties.Name | Where-Object { $_ -match '^RFS\.\d+\.WriteProtected$' })
    }
    if ($names.Count -eq 0) { throw 'The iDRAC exposes no RFS.<n>.WriteProtected attribute; drop -RfsWriteAttribute.' }
    $patch = @{}
    foreach ($name in $names) { $patch[$name] = $Value }
    if ($PSCmdlet.ShouldProcess($ManagerPath, "Set $($names -join ', ') to $Value")) {
        $null = Invoke-ZtpRedfish -Session $Session -Path "$ManagerPath/Attributes" -Method Patch -Body @{ Attributes = $patch }
    }
}

if (-not $Credential) { throw '-Credential (the BMC account) is required with -Execute.' }
$targets = @(Get-ZtpBmcTarget -NodeName $NodeName -Nodes $Nodes -NodesFile $NodesFile -BmcAddress $BmcAddress)
foreach ($target in $targets) {
    $node = [string]$target.Node

    $fileName = Get-ZtpNodeImageName -NodeName $node -Prefix $ImageNamePrefix
    if ($Action -ne 'Status' -and -not $PSCmdlet.ShouldProcess("$node ($($target.Address))", "$Action virtual USB $fileName; restart: $([bool]$Restart)")) { continue }
        $sessionParameters = @{ BmcAddress = $target.Address; Credential = $Credential }
    if ($SkipCertificateCheck) { $sessionParameters.SkipCertificateCheck = $true }
    $session = New-ZtpRedfishSession @sessionParameters
    try {
        $manager = Get-ZtpRedfishManager -Session $session
        $system = Get-ZtpRedfishSystem -Session $session
        $slots = @(Get-ZtpRedfishMember -Session $session -CollectionPath "$($manager.'@odata.id')/VirtualMedia" | Where-Object { @($_.MediaTypes) -contains 'USBStick' })
        if ($slots.Count -eq 0) { throw "$($node): the iDRAC has no USB-stick (RemovableDisk) virtual-media slot." }
        $ours = { param($Slot) [bool]$Slot.Inserted -and [string]$Slot.Image -like "*$fileName" }
        $state = {
            param($Slot, [string]$Did)
            $sys = Invoke-ZtpRedfish -Session $session -Path $system.'@odata.id'
            $boot = if ($sys -and $sys.PSObject.Properties['Boot']) { $sys.Boot } else { $null }
            [pscustomobject]@{
                Node           = $node
                Bmc            = $target.Address
                Action         = $Did
                Slot           = $Slot.'@odata.id'
                Inserted       = [bool]$Slot.Inserted
                Image          = [string]$Slot.Image
                WriteProtected = if ($Slot.PSObject.Properties['WriteProtected']) { $Slot.WriteProtected } else { $null }
                PowerState     = if ($sys -and $sys.PSObject.Properties['PowerState']) { [string]$sys.PowerState } else { $null }
                BootOverride   = if ($boot -and $boot.PSObject.Properties['BootSourceOverrideTarget']) { "$($boot.BootSourceOverrideEnabled)/$($boot.BootSourceOverrideTarget)" } else { $null }
            }
        }

        if ($Action -eq 'Status') {
            $slot = @($slots | Where-Object { & $ours $_ }) + @($slots) | Select-Object -First 1
            & $state $slot 'Status'
            continue
        }

        if ($Action -eq 'Eject') {
            $slot = @($slots | Where-Object { & $ours $_ }) | Select-Object -First 1
            if (-not $slot -and $Force) { $slot = @($slots | Where-Object { [bool]$_.Inserted }) | Select-Object -First 1 }
            if (-not $slot) {
                $other = @($slots | Where-Object { [bool]$_.Inserted } | ForEach-Object { [string]$_.Image })
                if ($other.Count -gt 0) { Write-Warning "$($node): the USB-stick slot holds $($other -join ', '), not $fileName; left inserted (use -Force to eject it)." }
                else { Write-Verbose "$($node): nothing inserted on the USB-stick slot." }
                & $state $slots[0] 'NotInserted'
            }
            else {
                $null = Invoke-ZtpRedfish -Session $session -Path "$($slot.'@odata.id')/Actions/VirtualMedia.EjectMedia" -Method Post -Body @{}
                $after = Invoke-ZtpRedfish -Session $session -Path $slot.'@odata.id'
                if ([bool]$after.Inserted) { throw "$($node): the USB-stick slot still reports Inserted after EjectMedia." }
                if ($RfsWriteAttribute) { Set-ZtpRfsWriteProtection -Session $session -ManagerPath $manager.'@odata.id' -Value 'Read Only' -Confirm:$false }
                & $state $after 'Ejected'
            }
            continue
        }

        # Mount
        $url = & $imageUrl $node
        $slot = @($slots | Where-Object { & $ours $_ }) + @($slots | Where-Object { -not [bool]$_.Inserted }) + @($slots) | Select-Object -First 1
        if ([bool]$slot.Inserted) {
            $sameImage = & $ours $slot
            $protection = if ($slot.PSObject.Properties['WriteProtected']) { $slot.WriteProtected } else { $null }
            if (-not $sameImage -or ($null -ne $protection -and [bool]$protection -ne $writeProtected)) {
                # The slot holds another image, or ours with the wrong write protection: re-insert.
                $null = Invoke-ZtpRedfish -Session $session -Path "$($slot.'@odata.id')/Actions/VirtualMedia.EjectMedia" -Method Post -Body @{}
                Start-Sleep -Seconds 2
                $slot = Invoke-ZtpRedfish -Session $session -Path $slot.'@odata.id'
            }
        }
        if ($RfsWriteAttribute -and -not $ReadOnly) { Set-ZtpRfsWriteProtection -Session $session -ManagerPath $manager.'@odata.id' -Value 'Read Write' -Confirm:$false }
        if (-not [bool]$slot.Inserted) {
            $insertBody = @{ Image = $url; Inserted = $true; WriteProtected = $writeProtected; TransferProtocolType = 'CIFS' }
            if ($ShareCredential) {
                $insertBody.UserName = $ShareCredential.UserName
                $insertBody.Password = $ShareCredential.GetNetworkCredential().Password
            }
            try {
                $null = Invoke-ZtpRedfish -Session $session -Path "$($slot.'@odata.id')/Actions/VirtualMedia.InsertMedia" -Method Post -Body $insertBody
            }
            finally {
                $insertBody.Remove('Password')
            }
        }
        # Read back: the iDRAC accepts InsertMedia before it has opened the share; prove the attach and the protection.
        $check = Invoke-ZtpRedfish -Session $session -Path $slot.'@odata.id'
        if (-not (& $ours $check)) {
            throw "$($node): virtual media did not attach $url (Inserted=$($check.Inserted), Image=$($check.Image))."
        }
        $reported = if ($check.PSObject.Properties['WriteProtected']) { $check.WriteProtected } else { $null }
        if ($null -eq $reported) { Write-Warning "$($node): the iDRAC does not report WriteProtected; write access is unverified until a voucher appears in the image." }
        elseif ([bool]$reported -ne $writeProtected) {
            throw "$($node): the image is attached with WriteProtected=$reported, not $writeProtected (retry with -RfsWriteAttribute; the maintenance environment cannot write the voucher to a read-only drive)."
        }
        $null = Invoke-ZtpRedfish -Session $session -Path $system.'@odata.id' -Method Patch -Body @{ Boot = @{ BootSourceOverrideEnabled = 'Once'; BootSourceOverrideTarget = 'Usb' } }
        $did = 'Mounted'
        if ($Restart) {
            $power = Invoke-ZtpRedfish -Session $session -Path $system.'@odata.id'
            $resetType = if ($power -and $power.PSObject.Properties['PowerState'] -and [string]$power.PowerState -eq 'Off') { 'On' } else { 'ForceRestart' }
            $null = Invoke-ZtpRedfish -Session $session -Path "$($system.'@odata.id')/Actions/ComputerSystem.Reset" -Method Post -Body @{ ResetType = $resetType }
            $did = "Mounted+$resetType"
        }
        & $state $check $did
    }
    finally {
        Remove-ZtpRedfishSession -Session $session
    }
}
