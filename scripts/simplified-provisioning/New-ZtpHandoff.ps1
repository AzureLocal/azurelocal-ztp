#Requires -Version 7.0
<#
.SYNOPSIS
Writes ztp-handoff.json: what Azure generated during ZTP, once every machine is ready to cluster. Plan by default.
.DESCRIPTION
Reads (GET only) each edge machine and its ProvisionOs job, requires every machine to be ready to cluster, and records
only what Azure generated during ZTP, never a value the infrastructure file already holds:
  nodes[]   name, serial, edgeMachineName, edgeMachineId, arcMachineName, arcMachineResourceId, arcMachineResourceGroup,
            ready, and the Network stage's result: managementAddressVerified (true when the port with the management MAC
            carries the infrastructure file's address) and managementAddressReason (why not; null when verified), and
            biosRestored: the BIOS attributes the Restore stage set back (attribute -> value; empty when none).
  solution  vsrVersion: the solution build actually installed (the infrastructure file may say latest).
  subscriptionId, resourceGroup, site { resourceId, name }, schemaVersion (2), generatedUtc, tool.
Addresses, MACs, the bootstrap ISO and timestamps aren't here: the addresses and MACs are in the infrastructure file every
tool reads, and the ISO details and timestamps are in the run's state file, stage evidence and event log.
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
if (-not $Execute) {
    Write-ZtpLog "PLAN: would write $HandoffPath for $($NodeName -join ', ') (all ready to cluster). Add -Execute."
    return [pscustomobject]$handoff
}
$folder = Split-Path -Parent $HandoffPath
if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
$handoff | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $HandoffPath -Encoding utf8NoBOM
Write-ZtpLog "Wrote $HandoffPath ($($rows.Count) node(s)). Next: Convert-ZtpHandoffToClusterInputs.ps1 -HandoffPath $HandoffPath, then OS configuration."
return [pscustomobject]@{ HandoffPath = $HandoffPath; Nodes = @($rows | ForEach-Object { $_.name }); ArcMachineNames = $names }
