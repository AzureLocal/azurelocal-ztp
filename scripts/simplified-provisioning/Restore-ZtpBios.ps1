#Requires -Version 7.0
<#
.SYNOPSIS
Sets back the BIOS values ZTP changed for the install only (bios_during_provisioning), after the Network stage and
before the Handoff. The Restore stage.
.DESCRIPTION
The Boot stage applies hardware.bios with hardware.bios_during_provisioning (and each node's own) merged over it, and
the run state keeps each attribute's value as found before Boot changed it. For every key of bios_during_provisioning,
this script sets the attribute to hardware.bios[key] when the file gives one, otherwise to that saved value. The node
list (Invoke-ZtpEnvironment.ps1 writes it) carries the plan per node as bios_restore: attribute -> final value, or ''
for the saved value.
Per node, through Set-ZtpBios.ps1: PATCH the Bios Settings resource with ApplyTime OnReset (only what differs), restart
the node through Redfish, wait until the BIOS reports the values. All nodes run at once. The orchestrator then waits until
the Arc machines report Connected again and the edge machines are still ready to cluster.
Events (stage Restore, in -EventLogPath): BiosRestoreStarted, then BiosRestored or BiosRestoreFailed, per node. Each
change goes to -BiosLogPath (bios-changes.jsonl). Without -Execute it prints the plan (PLAN: lines). A node without
bios_restore is reported as NotNeeded; when no node has one, the stage is a no-op that says so.
.PARAMETER NodeName
Nodes to restore.
.PARAMETER Nodes
Node objects { name, bmc_address, bios_restore }.
.PARAMETER NodesFile
The node list (see config/simplified-provisioning/nodes.example.json).
.PARAMETER Original
Node name -> (attribute -> value before Boot changed it), from the run state.
.PARAMETER Credential
BMC account (required with -Execute when something is restored).
.PARAMETER ConfirmNotClustered
Confirms the nodes carry no cluster to keep: applying the BIOS restarts them.
.PARAMETER SkipCertificateCheck
Accept the BMC's self-signed certificate.
.PARAMETER BiosLogPath
JSON-lines file each BIOS change is appended to. Optional.
.PARAMETER EventLogPath
The ZTP event file (stage Restore). Optional; written only with -Execute.
.PARAMETER TimeoutMinutes
How long to wait for a node's BIOS to report the restored values after the restart.
.PARAMETER Execute
Make the changes; without it only the plan is printed.
.EXAMPLE
./Restore-ZtpBios.ps1 -NodeName node-01 -NodesFile ./nodes.json -Original @{ 'node-01' = @{ Slot2 = 'Enabled' } }
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The parameters are read inside the helper functions.')]
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateCount(1, 64)][string[]]$NodeName,
    [object[]]$Nodes,
    [string]$NodesFile,
    [System.Collections.IDictionary]$Original = @{},
    [pscredential]$Credential,
    [switch]$ConfirmNotClustered,
    [switch]$SkipCertificateCheck,
    [string]$BiosLogPath,
    [string]$EventLogPath,
    [ValidateRange(1, 240)][int]$TimeoutMinutes = 30,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpVirtualUsb.Common.ps1')
. (Join-Path $PSScriptRoot 'ZtpEvents.Common.ps1')

function Send-RestoreEvent([string]$Node, [string]$State, [string]$Evidence, [string]$Level = 'Info', [string]$NextAction = '') {
    if (-not $Execute -or -not $EventLogPath) { return }
    try { Write-ZtpEvent -Path $EventLogPath -Node $Node -State $State -Evidence $Evidence -NextAction $NextAction -Level $Level -Stage 'Restore' }
    catch { Write-Warning "Couldn't write the Restore event to ${EventLogPath}: $($_.Exception.Message)" }
}
function Get-Value([object]$Map, [string]$Key) {
    if ($null -eq $Map) { return $null }
    if ($Map -is [System.Collections.IDictionary]) { if ($Map.Contains($Key)) { return $Map[$Key] } return $null }
    $p = $Map.PSObject.Properties[$Key]; if ($p) { return $p.Value } return $null
}
function Get-MapKey([object]$Map) {
    if ($null -eq $Map) { return @() }
    if ($Map -is [System.Collections.IDictionary]) { return @($Map.Keys | ForEach-Object { [string]$_ }) }
    return @($Map.PSObject.Properties.Name)
}

$listed = if ($Nodes) { @($Nodes) } elseif ($NodesFile) { @(Import-ZtpNodeFile -Path $NodesFile) } else { @() }
$targets = @(Get-ZtpBmcTarget -NodeName $NodeName -Nodes $Nodes -NodesFile $NodesFile)

# Per node: attribute -> the value to set back, and where it comes from.
$plan = [ordered]@{}
$problems = [System.Collections.Generic.List[string]]::new()
foreach ($node in $NodeName) {
    $entry = @($listed | Where-Object { [string](Get-Value $_ 'name') -eq $node }) | Select-Object -First 1
    $restore = Get-Value $entry 'bios_restore'
    $keys = @(Get-MapKey $restore)
    if ($keys.Count -eq 0) { continue }
    $saved = Get-Value $Original $node
    $set = [ordered]@{}; $from = [ordered]@{}
    foreach ($k in $keys) {
        $final = [string](Get-Value $restore $k)
        if ($final) { $set[$k] = $final; $from[$k] = 'hardware.bios' }
        else {
            $before = Get-Value $saved $k
            if ($null -eq $before -or "$before" -eq '') { $problems.Add("${node}: no value saved for $k before Boot changed it (the run state lost it). Set hardware.bios.$k to the final value.") }
            else { $set[$k] = [string]$before; $from[$k] = 'the value before Boot' }
        }
    }
    $plan[$node] = [pscustomobject]@{ Set = $set; From = $from }
}

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($node in $NodeName) { if (-not $plan.Contains($node)) { $rows.Add([pscustomobject]@{ Node = $node; Status = 'NotNeeded'; Restored = [ordered]@{}; Changes = @() }) } }
if ($plan.Count -eq 0) {
    Write-Information -MessageData "Restore: no node has bios_during_provisioning; nothing to set back." -InformationAction Continue
    if (-not $Execute) { 'PLAN: Restore: no bios_during_provisioning in the environment file; nothing to set back.' }
    return $rows.ToArray()
}
if ($problems.Count) {
    foreach ($p in $problems) { $n = $p.Split(':')[0]; Send-RestoreEvent $n 'BiosRestoreFailed' $p 'Error' 'Set hardware.bios to the final values and rerun -From Restore.' }
    throw "Restore: $($problems -join ' ')"
}

$setBios = Join-Path $PSScriptRoot 'Set-ZtpBios.ps1'
if (-not $Execute) {
    foreach ($node in $plan.Keys) {
        $p = $plan[$node]
        "PLAN: $node Restore BIOS $(@($p.Set.Keys | ForEach-Object { "$_=$($p.Set[$_]) (from $($p.From[$_]))" }) -join ', '): PATCH OnReset, restart through Redfish, wait until the BIOS reports them; then wait until the Arc machine reports Connected and the edge machine is still ready to cluster."
        if ($Credential) {
            $address = @($targets | Where-Object Node -EQ $node)[0].Address
            $a = @{ NodeName = $node; BmcAddress = $address; Attributes = $p.Set; Credential = $Credential; SkipCertificateCheck = $SkipCertificateCheck }
            & $setBios @a
        }
    }
    foreach ($node in $plan.Keys) { $rows.Add([pscustomobject]@{ Node = $node; Status = 'Planned'; Restored = $plan[$node].Set; Changes = @() }) }
    return $rows.ToArray()
}
if (-not $Credential) { throw 'Restore: -Credential (the BMC account) is required with -Execute.' }
if (-not $ConfirmNotClustered) { throw 'Restore: applying the BIOS restarts the nodes. Pass -ConfirmNotClustered.' }
if (-not $PSCmdlet.ShouldProcess(($plan.Keys -join ', '), 'Set the provisioning-only BIOS values back and restart')) { return $rows.ToArray() }

foreach ($node in $plan.Keys) { Send-RestoreEvent $node 'BiosRestoreStarted' "BIOS $(@($plan[$node].Set.Keys | ForEach-Object { "$_=$($plan[$node].Set[$_])" }) -join ', ')" }
$biosArgs = @{ ConfirmNotClustered = $true; SkipCertificateCheck = $SkipCertificateCheck; TimeoutMinutes = $TimeoutMinutes }
if ($BiosLogPath) { $biosArgs.ChangeLogPath = $BiosLogPath }
$work = @(foreach ($node in $plan.Keys) { [pscustomobject]@{ Node = $node; Address = @($targets | Where-Object Node -EQ $node)[0].Address; Set = $plan[$node].Set } })
$done = @($work | ForEach-Object -ThrottleLimit ([Math]::Max(1, $work.Count)) -Parallel {
        $w = $_
        try {
            $b = ([hashtable]$using:biosArgs).Clone()
            $result = @(& $using:setBios @b -NodeName $w.Node -BmcAddress $w.Address -Attributes $w.Set -Credential $using:Credential -Execute -Confirm:$false) | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Changes'] } | Select-Object -Last 1
            [pscustomobject]@{ Node = $w.Node; Status = $(if ($result) { [string]$result.Status } else { 'Unknown' }); Changes = @(if ($result) { $result.Changes }); Error = $null }
        }
        catch { [pscustomobject]@{ Node = $w.Node; Status = 'Failed'; Changes = @(); Error = $_.Exception.Message } }
    })
$failed = [System.Collections.Generic.List[string]]::new()
foreach ($d in $done) {
    if ($d.Error) {
        Send-RestoreEvent $d.Node 'BiosRestoreFailed' $d.Error 'Error' 'Fix the cause and rerun -From Restore; values already right are left alone.'
        $failed.Add("$($d.Node): $($d.Error)")
        continue
    }
    $set = $plan[$d.Node].Set
    $status = if ($d.Status -eq 'AlreadySet') { 'AlreadySet' } else { 'Restored' }
    Send-RestoreEvent $d.Node 'BiosRestored' "BIOS $(@($set.Keys | ForEach-Object { "$_=$($set[$_])" }) -join ', ')$(if ($status -eq 'AlreadySet') { ' (already set; no restart)' } else { " ($(@($d.Changes) -join '; '))" })"
    $rows.Add([pscustomobject]@{ Node = $d.Node; Status = $status; Restored = $set; Changes = @($d.Changes) })
}
if ($failed.Count) { throw "Restore failed on $($failed -join ' | ')" }
return $rows.ToArray()
