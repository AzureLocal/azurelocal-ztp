#Requires -Version 7.0
<#
.SYNOPSIS
Reads each node's Arc machine name from its edge machine and returns the node -> Arc machine name map; optionally writes it
to a JSON file.
.DESCRIPTION
Simplified machine provisioning names the Arc machine <device-id>-1, not the host name, so cluster deployment must use the
edge machine's arcMachineResourceId (or this map), never the host name. This script reads
edgeMachines/<node> properties.arcMachineResourceId (read-only GET) for every node and returns one row per node
{ Node, Lifecycle, Current, ArcMachineName, ArcResourceGroup, ArcMachineResourceId, Change }.
Without -MapPath only the rows are returned. With -MapPath (a JSON file { "node-01": "<arc machine name>", ... }) the rows
are compared with the file's current content; with -Execute the file is written (existing entries of other nodes are kept).
A node that is not Provisioned is refused unless -AllowNotReady: while the maintenance environment runs, the edge machine
points at a temporary maintenance Arc machine that is replaced.
.PARAMETER SubscriptionId
Subscription of the edge machines.
.PARAMETER ResourceGroupName
Resource group of the edge machines.
.PARAMETER NodeName
Node names (= edge machine names).
.PARAMETER MapPath
JSON file that holds the node -> Arc machine name map (for example D:\ZtpState\arc-machine-names.json).
.PARAMETER ApiVersion
edgeMachines api-version.
.PARAMETER AllowNotReady
Accept an edge machine whose lifecycle is not Provisioned.
.PARAMETER Execute
Write -MapPath; without it only the rows are returned.
.EXAMPLE
./Update-ArcMachineNames.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example -NodeName node-01, node-02
.EXAMPLE
./Update-ArcMachineNames.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example -NodeName node-01, node-02 -MapPath ./arc-machine-names.json -Execute
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroupName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$NodeName,
    [string]$MapPath,
    [string]$ApiVersion = '2025-12-01-preview',
    [switch]$AllowNotReady,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpAzure.Common.ps1')

if ($Execute -and -not $MapPath) { throw '-Execute writes the map file: pass -MapPath.' }
$current = [ordered]@{}
if ($MapPath -and (Test-Path -LiteralPath $MapPath -PathType Leaf)) {
    $existing = Get-Content -LiteralPath $MapPath -Raw | ConvertFrom-Json -AsHashtable -Depth 5
    if ($existing) { foreach ($key in $existing.Keys) { $current[[string]$key] = [string]$existing[$key] } }
}

$rows = [System.Collections.Generic.List[object]]::new()
$problems = [System.Collections.Generic.List[string]]::new()
$updates = [ordered]@{}
foreach ($name in $NodeName) {
    $machine = Invoke-ZtpArm -Method GET -ApiVersion $ApiVersion -AllowNotFound `
        -Path "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.AzureStackHCI/edgeMachines/$name"
    if (-not $machine) { $problems.Add("Node ${name}: no edge machine."); continue }
    $lifecycle = [string](Get-ZtpPathValue $machine 'properties.lifecycleDetails.lifecycleStatus.status' '')
    $arcId = [string](Get-ZtpPathValue $machine 'properties.arcMachineResourceId' '')
    if (-not $arcId) { $problems.Add("Node ${name}: the edge machine has no arcMachineResourceId yet (lifecycle $lifecycle)."); continue }
    if ($lifecycle -ne 'Provisioned' -and -not $AllowNotReady) {
        $problems.Add("Node ${name}: lifecycle is '$lifecycle', not Provisioned; its Arc machine can still change. Wait with Wait-ZtpMachineReady.ps1 or pass -AllowNotReady.")
        continue
    }
    $arcName = $arcId.Split('/')[-1]
    $arcGroup = if ($arcId -match '/resourceGroups/([^/]+)/') { $Matches[1] } else { '' }
    if ($arcGroup -and $arcGroup -ne $ResourceGroupName) {
        Write-ZtpLog "Node ${name}: the Arc machine is in resource group '$arcGroup' (the managed resource group), not '$ResourceGroupName'; cluster deployment must use the arcMachineResourceId." -Level Warning
    }
    $old = if ($current.Contains($name)) { $current[$name] } else { '' }
    $change = if ($old -eq $arcName) { 'Unchanged' } elseif ($old) { 'Update' } else { 'Add' }
    if ($change -ne 'Unchanged') { $updates[$name] = $arcName }
    $rows.Add([pscustomobject]@{
            Node = $name; Lifecycle = $lifecycle; Current = $old; ArcMachineName = $arcName
            ArcResourceGroup = $arcGroup; ArcMachineResourceId = $arcId; Change = $change
        })
}
if ($problems.Count -gt 0) { throw ($problems -join [Environment]::NewLine) }

if ($MapPath) {
    if ($updates.Count -eq 0) {
        Write-ZtpLog "$MapPath already matches the edge machines."
    }
    elseif (-not $Execute) {
        Write-ZtpLog "Plan: $($updates.Count) map entr$(if ($updates.Count -eq 1) { 'y' } else { 'ies' }) to write in $MapPath; add -Execute to write."
    }
    elseif ($PSCmdlet.ShouldProcess($MapPath, "Write the Arc machine names of $($updates.Keys -join ', ')")) {
        $merged = [ordered]@{}
        foreach ($key in $current.Keys) { $merged[$key] = $current[$key] }
        foreach ($key in $updates.Keys) { $merged[$key] = $updates[$key] }
        $parent = Split-Path -Parent ([IO.Path]::GetFullPath($MapPath))
        if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
        [System.IO.File]::WriteAllText($MapPath, ($merged | ConvertTo-Json) + "`n", [System.Text.UTF8Encoding]::new($false))
        Write-ZtpLog "Wrote $($updates.Count) map entr$(if ($updates.Count -eq 1) { 'y' } else { 'ies' }) to $MapPath."
    }
}
$rows.ToArray()
