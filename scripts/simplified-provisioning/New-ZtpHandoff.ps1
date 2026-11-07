#Requires -Version 7.0
<#
.SYNOPSIS
Writes ztp-handoff.json: what Azure generated during ZTP, once every machine is ready to cluster. Plan by default.
.DESCRIPTION
Reads (GET only) each edge machine and its ProvisionOs job, requires every machine to be ready to cluster, and records
only what Azure generated during ZTP, never a value the infrastructure file already holds:
  nodes[]   name, serial, edgeMachineName, edgeMachineId, arcMachineName, arcMachineResourceId, arcMachineResourceGroup,
            ready, and the Network stage's result: managementAddressVerified (true when the management port, the port
            with the management MAC, carries the infrastructure file's address) and managementAddressReason (why not, in
            plain language: the mode, the port, its MAC, what it has now and what the file expects; null when verified),
            biosRestored: the BIOS attributes the Restore stage set back (attribute -> value; empty when none),
            biosRestoreComplete (false when the node list expected attributes to be set back and Restore did not confirm
            every one) and biosNotRestored (those attribute names), so an unfinished restore is visible to the next tool,
            managementMode { mode (A, B, C or null), name, ipAssignment }: A Reserved (dhcp_reservation), B Static with
            DHCP, C Static without management DHCP; null without a node list, and
            networkAdapters[]: every port as Azure reports it after the install (edgeMachines/<node>/networkAdapters
            reportedProperties): name (the OS name), macAddress, description, roles and fileName (the file's port with
            that MAC; empty and null when the file doesn't list it), isManagement, ipAssignment (Dhcp, Static or
            none), ipAddress, prefix, subnetMask, gateway, and expected { ipAssignment, ipAddress } from the file.
            The fields after biosRestored are additive: schemaVersion stays 2, and a reader of the earlier fields
            (Convert-ZtpHandoffToClusterInputs.ps1, the toolkit's Read-AzlHandoff) reads it unchanged.
  solution  vsrVersion: the solution build actually installed (the infrastructure file may say latest).
  subscriptionId, resourceGroup, site { resourceId, name }, schemaVersion (2), generatedUtc, tool.
The bootstrap ISO and timestamps aren't here: they are in the run's state file, stage evidence and event log. The ports'
addresses after the install are, because they are what OS configuration starts from. A short table per node (ports, MACs,
roles, address now, expected) is also printed.
Feed it to Convert-ZtpHandoffToClusterInputs.ps1 to get the arc_machine_names block for the cluster deployment environment
file. The handoff holds Azure resource IDs of your subscription: keep it out of source control.
.PARAMETER SubscriptionId
Subscription of the edge machines.
.PARAMETER ResourceGroupName
Resource group of the edge machines.
.PARAMETER NodeName
Edge machine names (the node host names).
.PARAMETER Nodes
Node objects { name, service_tag, bmc_address } to record the serial numbers.
.PARAMETER NodesFile
Node list file for the serial numbers.
.PARAMETER ManagementAddressCheck
The Network stage's result per node, as the orchestrator records it: { node, verified, reason } (hashtables or objects).
A node without one is recorded as not verified.
.PARAMETER RestoredBios
Node name -> (BIOS attribute -> value) the Restore stage set back, as the orchestrator records it.
.PARAMETER HandoffPath
Output file (default ./ztp-handoff.json).
.PARAMETER ApiVersion
Microsoft.AzureStackHCI api-version for edgeMachines.
.PARAMETER Execute
Write the file. Without it the content is returned and nothing is written.
.EXAMPLE
./New-ZtpHandoff.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example -NodeName node-01,node-02 -NodesFile ./nodes.json -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroupName,
    [Parameter(Mandatory)][ValidateCount(1, 64)][string[]]$NodeName,
    [object[]]$Nodes,
    [string]$NodesFile,
    [object[]]$ManagementAddressCheck,
    [System.Collections.IDictionary]$RestoredBios = @{},
    [string]$HandoffPath = (Join-Path (Get-Location) 'ztp-handoff.json'),
    [string]$ApiVersion = '2026-10-01',
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpAzure.Common.ps1')
. (Join-Path $PSScriptRoot 'ZtpVirtualUsb.Common.ps1')

$serials = @{}
if ($Nodes -or $NodesFile) { foreach ($n in @(Get-ZtpNodeList -Nodes $Nodes -NodesFile $NodesFile -NodeName $NodeName)) { $serials[$n.Name] = $n.Serial } }
# The file's view of each node, from the node list Invoke-ZtpEnvironment.ps1 writes: the management port's MAC and
# ip_assignment, whether it takes DHCP while provisioned (management_dhcp: Mode B or C), and every port with its roles.
# An older node list without them gives no mode and no file match.
$fileNodes = @{}
foreach ($n in @(if ($Nodes) { $Nodes } elseif ($NodesFile) { Import-ZtpNodeFile -Path $NodesFile })) {
    $key = [string](Get-ZtpPropertyValue $n 'name' '')
    if ($key) { $fileNodes[$key] = $n }
}
function ConvertTo-HandoffMacKey([string]$Mac) { try { ConvertTo-ZtpMacKey $Mac } catch { $Mac.ToLowerInvariant() } }
function ConvertTo-HandoffPrefix([string]$Mask) {
    if (-not $Mask) { return $null }
    $parsed = $null
    if (-not [ipaddress]::TryParse($Mask, [ref]$parsed)) { return $null }
    return (@($parsed.GetAddressBytes() | ForEach-Object { [Convert]::ToString($_, 2) }) -join '').Replace('0', '').Length
}
function Get-HandoffAdapter {
    # The node's ports as Azure reports them after the install (edgeMachines/<node>/networkAdapters reportedProperties),
    # each matched by MAC to the file's port: its roles, its name in the file and what the file expects. isManagement is
    # the port with the management MAC (the port the file gives role management; any make or slot).
    param([string]$Machine, [object]$FileNode)
    $list = Invoke-ZtpArm -Method GET -Path "$rgPath/$Machine/networkAdapters" -ApiVersion $ApiVersion -AllowNotFound
    if ($null -eq $list) { return @() }
    $filePorts = @(@(Get-ZtpPropertyValue $FileNode 'network_adapters' @()) | Where-Object { $null -ne $_ })
    $mgmtMac = ConvertTo-HandoffMacKey ([string](Get-ZtpPropertyValue $FileNode 'management_mac' ''))
    if (-not $mgmtMac) {
        $owner = @($filePorts | Where-Object { 'management' -in @(Get-ZtpPropertyValue $_ 'roles' @()) -and [string](Get-ZtpPropertyValue $_ 'ip_assignment' '') -notin '', 'none' }) | Select-Object -First 1
        if ($owner) { $mgmtMac = ConvertTo-HandoffMacKey ([string](Get-ZtpPropertyValue $owner 'mac_address' '')) }
    }
    $out = @(foreach ($nic in @(Get-ZtpNetworkAdapterRow -List $list)) {
        $file = @($filePorts | Where-Object { (ConvertTo-HandoffMacKey ([string](Get-ZtpPropertyValue $_ 'mac_address' ''))) -eq $nic.Mac }) | Select-Object -First 1
        $r = $nic.Reported
        [ordered]@{
            name         = $nic.AdapterName
            macAddress   = Format-ZtpMac $nic.Mac
            description  = $(if ($nic.Description) { $nic.Description } else { $null })
            roles        = @(if ($file) { @(Get-ZtpPropertyValue $file 'roles' @()) | ForEach-Object { [string]$_ } })
            fileName     = $(if ($file -and (Get-ZtpPropertyValue $file 'name' '')) { [string](Get-ZtpPropertyValue $file 'name' '') } else { $null })
            isManagement = [bool]($mgmtMac -and $nic.Mac -eq $mgmtMac)
            ipAssignment = $(if ($r.Type) { $r.Type } else { 'none' })
            ipAddress    = $(if ($r.Ip) { $r.Ip } else { $null })
            prefix       = ConvertTo-HandoffPrefix $r.Mask
            subnetMask   = $(if ($r.Mask) { $r.Mask } else { $null })
            gateway      = $(if ($r.Gateway) { $r.Gateway } else { $null })
            expected     = $(if ($file) { [ordered]@{ ipAssignment = [string](Get-ZtpPropertyValue $file 'ip_assignment' ''); ipAddress = $(if (Get-ZtpPropertyValue $file 'ip_address' '') { [string](Get-ZtpPropertyValue $file 'ip_address' '') } else { $null }) } } else { $null })
        }
    })
    return $out
}

# The Network stage's result per node (hashtables from the state file, or objects).
$checks = @{}
foreach ($c in @($ManagementAddressCheck | Where-Object { $null -ne $_ })) {
    $node = [string](Get-ZtpPropertyValue $c 'node' '')
    if ($node) { $checks[$node] = $c }
}

$rgPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.AzureStackHCI/edgeMachines"
$rows = [System.Collections.Generic.List[object]]::new()
$notReady = [System.Collections.Generic.List[string]]::new()
$vsr = [System.Collections.Generic.HashSet[string]]::new()
$site = $null
foreach ($name in $NodeName) {
    $machine = Invoke-ZtpArm -Method GET -Path "$rgPath/$name" -ApiVersion $ApiVersion -AllowNotFound
    $job = if ($machine) { Invoke-ZtpArm -Method GET -Path "$rgPath/$name/jobs/ProvisionOs" -ApiVersion $ApiVersion -AllowNotFound -NotFoundStatus 404, 409 } else { $null }
    $status = Get-ZtpEdgeMachineStatus -Name $name -Machine $machine -Job $job
    if (-not $status.Ready) { $notReady.Add("$name ($($status.Lifecycle)$(if ($status.FailureReason) { ": $($status.FailureReason)" }))"); continue }
    $arcId = [string]$status.ArcMachineResourceId
    $arcRg = if ($arcId -match '/resourceGroups/([^/]+)/') { $Matches[1] } else { '' }
    # The build the OS install used: the edge machine's request carries the resolved version (never 'latest'); the
    # ProvisionOs job's copy is the fallback.
    $installed = [string](Get-ZtpPathValue $machine 'properties.provisioningDetails.osProfile.vsrVersion' '')
    if ($installed -notmatch '^\d+(\.\d+)+$' -and $job) { $installed = [string](Get-ZtpPathValue $job 'properties.provisioningRequest.osProfile.vsrVersion' '') }
    if ($installed) { $null = $vsr.Add($installed) }
    if (-not $site) { $site = [string](Get-ZtpPathValue $machine 'properties.siteDetails.siteResourceId' '') }
    $check = if ($checks.ContainsKey($name)) { $checks[$name] } else { $null }
    $verified = $null -ne $check -and [bool](Get-ZtpPropertyValue $check 'verified' $false)
    $reason = if ($verified) { $null }
    elseif ($null -eq $check) { 'no Network stage result for this node' }
    else { $r = [string](Get-ZtpPropertyValue $check 'reason' ''); if ($r) { $r } else { 'not verified' } }
    $fileNode = if ($fileNodes.ContainsKey($name)) { $fileNodes[$name] } else { $null }
    $mode = if ($fileNode -and (Get-ZtpPropertyValue $fileNode 'management_ip_assignment' '')) {
        $m = Get-ZtpManagementMode -IpAssignment ([string](Get-ZtpPropertyValue $fileNode 'management_ip_assignment' '')) -ManagementDhcp ([string](Get-ZtpPropertyValue $fileNode 'management_dhcp' 'true') -ne 'False')
        [ordered]@{ mode = $(if ($m.Mode) { $m.Mode } else { $null }); name = $m.Name; ipAssignment = $m.IpAssignment }
    }
    else { $null }
    # Attributes the node list says Restore must set back (bios_restore), minus the ones it confirmed.
    $expected = @(if ($fileNode) { $br = Get-ZtpPropertyValue $fileNode 'bios_restore' $null; if ($br -is [System.Collections.IDictionary]) { $br.Keys | ForEach-Object { [string]$_ } } elseif ($br) { $br.PSObject.Properties.Name } })
    $confirmed = @(if ($RestoredBios.Contains($name) -and $RestoredBios[$name] -is [System.Collections.IDictionary]) { $RestoredBios[$name].Keys | ForEach-Object { [string]$_ } } elseif ($RestoredBios.Contains($name) -and $RestoredBios[$name]) { $RestoredBios[$name].PSObject.Properties.Name })
    $notRestored = @($expected | Where-Object { $_ -notin $confirmed })
    $rows.Add([ordered]@{
            name                      = $name
            serial                    = $(if ($serials.ContainsKey($name)) { $serials[$name] } else { $null })
            edgeMachineName           = $name
            edgeMachineId             = [string](Get-ZtpPropertyValue $machine 'id' '')
            arcMachineName            = [string]$status.ArcMachineName
            arcMachineResourceId      = $arcId
            arcMachineResourceGroup   = $arcRg
            ready                     = $true
            managementAddressVerified = $verified
            managementAddressReason   = $reason
            biosRestored              = $(if ($RestoredBios.Contains($name)) { $RestoredBios[$name] } else { [ordered]@{} })
            biosRestoreComplete       = ($notRestored.Count -eq 0)
            biosNotRestored           = @($notRestored)
            managementMode            = $mode
            networkAdapters           = @(Get-HandoffAdapter -Machine $name -FileNode $fileNode)
        })
}
if ($notReady.Count -gt 0) { throw "Not ready to cluster: $($notReady -join '; '). No handoff written; rerun Wait-ZtpMachineReady.ps1." }
$names = @($rows | ForEach-Object { $_.arcMachineName })
if (@($names | Select-Object -Unique).Count -ne $names.Count) { throw "Duplicate Arc machine names: $($names -join ', ')." }
if (@($vsr).Count -gt 1) { Write-ZtpLog "The machines carry different vsrVersion values: $(@($vsr) -join ', '). A cluster needs one." -Level Warning }
$unverified = @($rows | Where-Object { -not $_.managementAddressVerified } | ForEach-Object { "$($_.name) ($($_.managementAddressReason))" })
if ($unverified.Count) { Write-ZtpLog "Management address not verified on: $($unverified -join '; '). OS configuration must fix it before Validate." -Level Warning }

$handoff = [ordered]@{
    schemaVersion  = 2
    generatedUtc   = [datetime]::UtcNow.ToString('o')
    tool           = 'azurelocal-ztp'
    subscriptionId = $SubscriptionId
    resourceGroup  = $ResourceGroupName
    site           = [ordered]@{ resourceId = $site; name = $(if ($site) { $site.Split('/')[-1] } else { $null }) }
    solution       = [ordered]@{ vsrVersion = $(if (@($vsr).Count) { @($vsr)[0] } else { $null }) }
    nodes          = @($rows)
}
# Each node's ports on screen: what the operator gets from ZTP, and what OS configuration still has to set.
foreach ($row in $rows) {
    $m = $row.managementMode
    $modeText = if ($m -and $m.mode) { "Mode $($m.mode) ($($m.name), $($m.ipAssignment))" } elseif ($m) { $m.name } else { 'mode unknown (no management settings in the node list)' }
    Write-ZtpLog "$($row.name): $modeText; management address $(if ($row.managementAddressVerified) { 'verified' } else { "not verified: $($row.managementAddressReason)" })"
    if (-not @($row.networkAdapters).Count) { Write-ZtpLog '  the edge machine reports no network adapters'; continue }
    Write-ZtpLog ('  {0,-2} {1,-16} {2,-17} {3,-26} {4,-24} {5}' -f '', 'port', 'MAC', 'roles (name in the file)', 'now', 'expected')
    foreach ($a in $row.networkAdapters) {
        $now = if ($a.ipAddress) { "$($a.ipAssignment) $($a.ipAddress)$(if ($null -ne $a.prefix) { "/$($a.prefix)" })$(if ($a.gateway) { " gw $($a.gateway)" })" } else { "$($a.ipAssignment), no address" }
        $roles = if (@($a.roles).Count) { "$(@($a.roles) -join ',')$(if ($a.fileName) { " ($($a.fileName))" })" } else { 'not in the file' }
        $expected = if ($a.expected) { "$($a.expected.ipAssignment)$(if ($a.expected.ipAddress) { " $($a.expected.ipAddress)" })" } else { '' }
        Write-ZtpLog ('  {0,-2} {1,-16} {2,-17} {3,-26} {4,-24} {5}' -f $(if ($a.isManagement) { '>' } else { '' }), $a.name, $a.macAddress, $roles, $now, $expected)
    }
}

if (-not $Execute) {
    Write-ZtpLog "PLAN: would write $HandoffPath for $($NodeName -join ', ') (all ready to cluster). Add -Execute."
    return [pscustomobject]$handoff
}
$folder = Split-Path -Parent $HandoffPath
if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
$handoff | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $HandoffPath -Encoding utf8NoBOM
Write-ZtpLog "Wrote $HandoffPath ($($rows.Count) node(s)). Next: Convert-ZtpHandoffToClusterInputs.ps1 -HandoffPath $HandoffPath, then OS configuration."
return [pscustomobject]@{ HandoffPath = $HandoffPath; Nodes = @($rows | ForEach-Object { $_.name }); ArcMachineNames = $names }
