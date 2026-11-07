#Requires -Version 7.0
<#
.SYNOPSIS
Boots the nodes into the Azure Local maintenance environment from per-node virtual-USB images over BMC virtual media
(simplified machine provisioning, device preparation).
.DESCRIPTION
One run in one process, because the share credential lives only in memory.
  1. Publish-MaintenanceIso.ps1 -ReadWrite shares the per-node images New-ZtpVirtualUsbImage.ps1 built in -ImageDirectory
     (in place, no copy), change rights for one generated account, TCP 445 only from the nodes' BMC addresses;
  2. For a node whose list entry has bios (attribute -> value), Set-ZtpBios.ps1 sets those BIOS attributes over Redfish
     first: it changes only those that differ, applies them with a power-on or restart and waits until the BIOS reports
     them, logging each change to -BiosLogPath. A node whose BIOS already matches isn't restarted for it.
  3. Mount-ZtpVirtualUsb.ps1 inserts each node's image on its USB-stick slot read-write, proves the attach, sets a
     one-time boot to that slot and, with -Restart, power-cycles the node. Every node runs in its own worker, at once. Leave the media inserted:
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
.PARAMETER BiosLogPath
JSON-lines file each BIOS change is appended to (the run's evidence folder). Optional.
.PARAMETER BiosTimeoutMinutes
How long to wait for a node's BIOS to report its new values after the reset.
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
    [string]$BiosLogPath,
    [ValidateRange(1, 240)][int]$BiosTimeoutMinutes = 30,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpVirtualUsb.Common.ps1')
. (Join-Path $PSScriptRoot 'ZtpBios.Common.ps1')

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

# BIOS attributes per node, from the node list (Invoke-ZtpEnvironment.ps1 writes hardware.bios merged with each node's).
$listed = if ($Nodes) { @($Nodes) } elseif ($NodesFile) { @(Import-ZtpNodeFile -Path $NodesFile) } else { @() }
$biosByNode = @{}
foreach ($node in $NodeName) { $s = Get-ZtpNodeBiosSetting -NodeName $node -Nodes $listed; if ($s.Count) { $biosByNode[$node] = $s } }
$setBios = Join-Path $PSScriptRoot 'Set-ZtpBios.ps1'
$biosArgs = @{ ConfirmNotClustered = $ConfirmNotClustered; SkipCertificateCheck = $SkipCertificateCheck; TimeoutMinutes = $BiosTimeoutMinutes }
if ($BiosLogPath) { $biosArgs.ChangeLogPath = $BiosLogPath }

if (-not $Execute) {
    & $publish @publishArgs
    foreach ($node in $NodeName) {
        if (-not $biosByNode.ContainsKey($node)) { continue }
        $address = @($targets | Where-Object Node -EQ $node)[0].Address
        $plan = @{ NodeName = $node; BmcAddress = $address; Attributes = $biosByNode[$node]; SkipCertificateCheck = $SkipCertificateCheck }
        if ($Credential) { $plan.Credential = $Credential }
        & $setBios @plan
    }
    & $mountUsb @usbArgs -NodeName $NodeName
    return
}
if ($biosByNode.Count -and -not $Restart) { throw 'BIOS settings are applied with a restart: pass -Restart (and -ConfirmNotClustered) with -Execute.' }
if (-not $PSCmdlet.ShouldProcess(($NodeName -join ', '), "Boot the maintenance virtual USB; restart: $([bool]$Restart)")) { return }
$share = & $publish @publishArgs -Execute -Confirm:$false
# All machines boot at once: each gets its own worker, which mounts, restarts and watches its own BMC. A failure on one
# doesn't stop the others; the stage fails afterwards with every machine's error.
$shareCredential = $share.Credential
$booted = @($NodeName | ForEach-Object -ThrottleLimit ([Math]::Max(1, @($NodeName).Count)) -Parallel {
        $node = $_
        $bios = @()
        try {
            # The BIOS first: its reset must not consume the one-time boot to the virtual USB that the mount sets.
            $settings = ([hashtable]$using:biosByNode)[$node]
            if ($settings) {
                $b = ([hashtable]$using:biosArgs).Clone()
                $target = @(([object[]]$using:targets) | Where-Object Node -EQ $node)[0]
                $result = @(& $using:setBios @b -NodeName $node -BmcAddress $target.Address -Attributes $settings -Credential $using:Credential -Execute -Confirm:$false) | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Changes'] } | Select-Object -Last 1
                if ($result) { $bios = @($result.Changes) }
            }
            $a = ([hashtable]$using:usbArgs).Clone()
            $out = @(& $using:mountUsb @a -NodeName $node -Credential $using:Credential -ShareCredential $using:shareCredential -Execute -Confirm:$false)
            [pscustomobject]@{ Node = $node; Row = @($out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Image'] })[-1]; Bios = $bios; Error = $null }
        }
        catch { [pscustomobject]@{ Node = $node; Row = $null; Bios = $bios; Error = $_.Exception.Message } }
    })
$failed = @($booted | Where-Object Error)
if ($failed.Count -gt 0) { throw "Boot failed on $(@($failed | ForEach-Object { "$($_.Node): $($_.Error)" }) -join ' | ')" }
foreach ($node in $NodeName) {
    $done = @($booted | Where-Object Node -EQ $node)[0]
    $row = $done.Row
    $hash = @($share.Images | Where-Object { $_.ImagePath -like "*/$(Get-ZtpNodeImageName -NodeName $node -Prefix $ImageNamePrefix)" })[0].Sha256
    [pscustomobject]@{ Node = $node; Image = $row.Image; Sha256 = $hash; WriteProtected = $row.WriteProtected; Restarted = [bool]$Restart; Bios = @($done.Bios) }
}
