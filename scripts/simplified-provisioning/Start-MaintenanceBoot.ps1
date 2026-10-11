#Requires -Version 7.0
<#
.SYNOPSIS
Boots the nodes into the Azure Local maintenance environment from per-node virtual-USB images over BMC virtual media
(simplified machine provisioning, device preparation).
.DESCRIPTION
One run in one process, because the share credential lives only in memory.
  1. Publish-MaintenanceIso.ps1 -ReadWrite shares the per-node images New-ZtpVirtualUsbImage.ps1 built in -ImageDirectory
     (in place, no copy), change rights for one generated account, TCP 445 only from the nodes' BMC addresses;
  2. Mount-ZtpVirtualUsb.ps1 inserts each node's image on its USB-stick slot with WriteProtected=false, proves the attach
     and the write access, sets a one-time USB boot and, with -Restart, power-cycles the node. Leave the media inserted:
     Wait-ZtpVoucher.ps1 waits for the voucher in the image, ejects it and extracts <serial>.pem.
BMC addresses come from the bmc_address of each node (-Nodes or -NodesFile); the BMC account is -Credential. When done,
eject the media and remove the share (Publish-MaintenanceIso.ps1 -Remove -ShareName <name>). Without -Execute only the
plan is printed (no share, no BMC call). Run elevated (a share, a local account and a firewall rule are created).
.PARAMETER ImageDirectory
Folder with the per-node virtual-USB images (<ImageNamePrefix><node>.img); it becomes the read-write share.
.PARAMETER ImageNamePrefix
File-name prefix of the per-node images.
.PARAMETER ShareName
SMB share for the per-node images.
.PARAMETER ReadOnlyMedia
Share and insert the images read-only (boots, but the maintenance environment cannot write the voucher back).
.PARAMETER RfsWriteAttribute
Passed to Mount-ZtpVirtualUsb.ps1: also set the iDRAC RFS.<n>.WriteProtected attributes to Read Write.
.PARAMETER ShareHost
Address of this host as the BMCs reach it (for example 192.0.2.10).
.PARAMETER NodeName
Nodes to boot (names in -Nodes or -NodesFile).
.PARAMETER Nodes
Node objects { name, bmc_address }.
.PARAMETER NodesFile
JSON (or YAML) node list, see config/simplified-provisioning/nodes.example.json.
.PARAMETER Credential
BMC account (required with -Execute).
.PARAMETER Restart
Restart each node into the one-time boot after mounting.
.PARAMETER ConfirmNotClustered
Confirms the nodes carry no cluster to keep: the maintenance setup reinstalls the machine.
.PARAMETER SkipCertificateCheck
Accept the BMC's self-signed certificate.
.PARAMETER Execute
Make the changes; without it only the plan is printed.
.EXAMPLE
./Start-MaintenanceBoot.ps1 -ImageDirectory D:\ZtpVirtualUsb -ShareHost 192.0.2.10 -NodeName node-01,node-02 -NodesFile ./nodes.json
.EXAMPLE
./Start-MaintenanceBoot.ps1 -ImageDirectory D:\ZtpVirtualUsb -ShareHost 192.0.2.10 -NodeName node-01,node-02 -NodesFile ./nodes.json -Credential $bmcCredential -Restart -ConfirmNotClustered -SkipCertificateCheck -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$ImageDirectory,
    [ValidatePattern('^[A-Za-z0-9._-]{0,40}$')][string]$ImageNamePrefix = 'ztp-usb-',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,79}$')][string]$ShareName = 'ztp-virtual-usb',
    [switch]$ReadOnlyMedia,
    [switch]$RfsWriteAttribute,
    [Parameter(Mandatory)][string]$ShareHost,
    [Parameter(Mandatory)][ValidateCount(1, 64)][string[]]$NodeName,
    [object[]]$Nodes,
    [string]$NodesFile,
    [pscredential]$Credential,
    [switch]$Restart,
    [switch]$ConfirmNotClustered,
    [switch]$SkipCertificateCheck,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpVirtualUsb.Common.ps1')

if ($Restart -and -not $ConfirmNotClustered) {
    throw 'Restart refused: -ConfirmNotClustered is required because the maintenance setup reinstalls the machine.'
}
if ($Execute -and -not $Credential) { throw '-Credential (the BMC account) is required with -Execute.' }
$publish = Join-Path $PSScriptRoot 'Publish-MaintenanceIso.ps1'
$mountUsb = Join-Path $PSScriptRoot 'Mount-ZtpVirtualUsb.ps1'

$targets = @(Get-ZtpBmcTarget -NodeName $NodeName -Nodes $Nodes -NodesFile $NodesFile)
$bmcs = @($targets | ForEach-Object { $_.Address } | Select-Object -Unique)
$images = @(foreach ($node in $NodeName) { Join-Path $ImageDirectory (Get-ZtpNodeImageName -NodeName $node -Prefix $ImageNamePrefix) })
$absent = @($images | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($absent.Count -gt 0) { throw "Build the images first (New-ZtpVirtualUsbImage.ps1 -NodeName ... -OutputDirectory $ImageDirectory): $($absent -join ', ')" }

$publishArgs = @{ IsoPath = $images; SharePath = $ImageDirectory; ShareName = $ShareName; ShareHost = $ShareHost; AllowedBmcAddress = $bmcs; ReadWrite = (-not $ReadOnlyMedia) }
$usbArgs = @{
    ShareHost = $ShareHost; ShareName = $ShareName; ImageNamePrefix = $ImageNamePrefix; ReadOnly = $ReadOnlyMedia
    RfsWriteAttribute = $RfsWriteAttribute; Restart = $Restart; ConfirmNotClustered = $ConfirmNotClustered; SkipCertificateCheck = $SkipCertificateCheck
}
if ($NodesFile) { $usbArgs.NodesFile = $NodesFile }
elseif ($Nodes) { $usbArgs.Nodes = $Nodes }

if (-not $Execute) {
    & $publish @publishArgs
    & $mountUsb @usbArgs -NodeName $NodeName
    return
}
if (-not $PSCmdlet.ShouldProcess(($NodeName -join ', '), "Boot the maintenance virtual USB; restart: $([bool]$Restart)")) { return }
$share = & $publish @publishArgs -Execute -Confirm:$false
foreach ($node in $NodeName) {
    $row = & $mountUsb @usbArgs -NodeName $node -Credential $Credential -ShareCredential $share.Credential -Execute -Confirm:$false
    $hash = @($share.Images | Where-Object { $_.ImagePath -like "*/$(Get-ZtpNodeImageName -NodeName $node -Prefix $ImageNamePrefix)" })[0].Sha256
    [pscustomobject]@{ Node = $node; Image = $row.Image; Sha256 = $hash; WriteProtected = $row.WriteProtected; Restarted = [bool]$Restart }
}
