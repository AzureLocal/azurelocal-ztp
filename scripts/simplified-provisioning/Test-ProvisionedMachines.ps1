#Requires -Version 7.0
<#
.SYNOPSIS
Checks that the provisioned Arc machines are ready to cluster (read-only).
.DESCRIPTION
Each expected machine must exist, be Connected and carry the mandatory Arc extensions of simplified machine provisioning
(AzureEdgeDeviceManagement, AzureEdgeLifecycleManager, AzureEdgeRemoteSupport, AzureEdgeTelemetryAndDiagnostics) in
provisioning state Succeeded. Another Arc machine in the group is reported as 'other machine in the group' and doesn't fail
the check, because nodes can be provisioned one run at a time into the same group; -StrictGroup makes it fail. With
-PassThru the rows are returned even when a check fails; otherwise the script throws.
Simplified provisioning names the Arc machine <device-id>-1: pass the values of arc_machine_names (written by
Update-ArcMachineNames.ps1 from each edge machine's arcMachineResourceId), not the host names.
.PARAMETER SubscriptionId
Azure Local landing-zone subscription ID.
.PARAMETER ResourceGroupName
Resource group that holds the Arc machines.
.PARAMETER ExpectedMachineName
Expected Arc machine names.
.PARAMETER RequiredExtension
Arc extensions that must be Succeeded on every machine.
.PARAMETER PassThru
Return the rows even when a check fails.
.PARAMETER StrictGroup
Fail when the group holds any Arc machine that isn't expected.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string[]]$ExpectedMachineName,
    [string[]]$RequiredExtension = @('AzureEdgeDeviceManagement', 'AzureEdgeLifecycleManager', 'AzureEdgeRemoteSupport', 'AzureEdgeTelemetryAndDiagnostics'),
    [switch]$PassThru,
    [switch]$StrictGroup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$null = Set-AzContext -WhatIf:$false -SubscriptionId $SubscriptionId
$listed = @(Get-AzConnectedMachine -ResourceGroupName $ResourceGroupName -SubscriptionId $SubscriptionId)
$rows = [System.Collections.Generic.List[object]]::new()

foreach ($name in $ExpectedMachineName) {
    $machine = Get-AzConnectedMachine -Name $name -ResourceGroupName $ResourceGroupName -SubscriptionId $SubscriptionId -ErrorAction SilentlyContinue
    $exists = $null -ne $machine
    $connected = $exists -and $machine.Status -eq 'Connected'
    $missing = @($RequiredExtension)
    if ($exists) {
        $extensions = @(Get-AzConnectedMachineExtension -MachineName $name -ResourceGroupName $ResourceGroupName -SubscriptionId $SubscriptionId -ErrorAction SilentlyContinue)
        $missing = @($RequiredExtension | Where-Object {
                $extensionName = $_
                -not @($extensions | Where-Object { $_.Name -eq $extensionName -and $_.ProvisioningState -eq 'Succeeded' })
            })
    }
    $detail = if (-not $exists) { 'Missing' }
    elseif (-not $connected) { "Status: $($machine.Status)" }
    elseif ($missing.Count -gt 0) { "Extensions not Succeeded: $($missing -join ', ')" }
    else { "Ready to cluster; OS: $($machine.OSName)" }
    $rows.Add([pscustomobject]@{
            MachineName       = $name
            Exists            = $exists
            Connected         = $connected
            ExtensionsReady   = $exists -and $missing.Count -eq 0
            MissingExtensions = $missing
            Detail            = $detail
        })
}
foreach ($machine in $listed) {
    if ($machine.Name -notin $ExpectedMachineName) {
        $rows.Add([pscustomobject]@{
                MachineName       = $machine.Name
                Exists            = $true
                Connected         = ($machine.Status -eq 'Connected')
                ExtensionsReady   = $false
                MissingExtensions = @()
                Detail            = if ($StrictGroup) { 'unexpected machine' } else { 'other machine in the group' }
            })
    }
}

$bad = @($rows | Where-Object { -not $_.Exists -or -not $_.Connected -or $_.Detail -eq 'unexpected machine' -or ($_.MachineName -in $ExpectedMachineName -and -not $_.ExtensionsReady) })
if (-not $PassThru -and $bad.Count -gt 0) {
    throw 'Provisioned machine verification failed. Use -PassThru to inspect the results.'
}
$rows.ToArray()
