#Requires -Version 7.0
<#
.SYNOPSIS
Launches AzureLocal Sonar on the ZTP provisioning: the event file of the bootstrap watch and the edge machine progress in
Azure. Plan by default.
.DESCRIPTION
Builds a Sonar config (provisioningRoute simplified, the nodes of the node list, ztpEvents.path = the event file that
Wait-ZtpBootstrapComplete.ps1 writes) and starts Start-AzlSonar.ps1 from the Sonar repository on the
feature/ztp-provisioning branch or later (the branch that adds the ztpEvents option). Sonar then shows, in one page, the ZTP events
(Mounted, Booting, MaintenanceEnvironmentRunning, VoucherWritten, ReadyForPortal) in its log pane and, once the edge machines
exist, their ProvisionOs jobs and lifecycle stages read from Azure (read-only; sign in with Connect-AzAccount first). Sonar
only reads; this script changes nothing but the generated config file.
A Sonar without the ztpEvents option ignores the key and still shows the edge machines; the events stay in the file
(Get-Content -Wait -Path <EventLogPath>).
.PARAMETER SonarPath
Folder of the Sonar repository (contains Start-AzlSonar.ps1).
.PARAMETER SubscriptionId
Subscription of the resource group the edge machines are created in.
.PARAMETER ResourceGroupName
Resource group of the edge machines.
.PARAMETER NodesFile
Node list (name, service_tag, bmc_address; optional management_ip is used as the node address).
.PARAMETER NodeName
Nodes to follow (default: all).
.PARAMETER EventLogPath
The event file of Wait-ZtpBootstrapComplete.ps1 (default ./ztp-events.jsonl).
.PARAMETER ClusterName
Label Sonar shows (default ztp-provisioning).
.PARAMETER SonarConfigPath
Where the generated Sonar config is written (default ./ztp-sonar.config.json).
.PARAMETER Port
Local port of the Sonar page.
.PARAMETER NoBrowser
Do not open the browser.
.PARAMETER Record
Also record the run to this file (replayable with Start-AzlSonar.ps1 -Replay).
.PARAMETER Execute
Write the config and start Sonar. Without it the config and the command are printed.
.EXAMPLE
./Start-ZtpMonitor.ps1 -SonarPath D:\git\azurelocal-sonar -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example -NodesFile ./nodes.json -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SonarPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$NodesFile,
    [string[]]$NodeName,
    [string]$EventLogPath = (Join-Path (Get-Location) 'ztp-events.jsonl'),
    [string]$ClusterName = 'ztp-provisioning',
    [string]$SonarConfigPath = (Join-Path (Get-Location) 'ztp-sonar.config.json'),
    [ValidateRange(1, 65535)][int]$Port = 8642,
    [switch]$NoBrowser,
    [string]$Record,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpVirtualUsb.Common.ps1')

$start = Join-Path $SonarPath 'Start-AzlSonar.ps1'
if (-not (Test-Path -LiteralPath $start)) { throw "Start-AzlSonar.ps1 not found in $SonarPath. Pass the folder of the azurelocal-sonar repository." }
$raw = Import-ZtpNodeFile -Path $NodesFile
$list = @(Get-ZtpNodeList -Nodes $raw -NodeName $(if ($NodeName) { $NodeName } else { @($raw | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_['name'] } else { $_.name } }) }))
$address = @{}
foreach ($n in $raw) {
    $name = if ($n -is [System.Collections.IDictionary]) { $n['name'] } else { $n.name }
    $mgmt = if ($n -is [System.Collections.IDictionary]) { $n['management_ip'] } else { $n.PSObject.Properties['management_ip']?.Value }
    $address[[string]$name] = [string]$mgmt
}
$nodes = foreach ($n in $list) {
    $a = if ($address[$n.Name]) { $address[$n.Name] } else { $n.BmcAddress }
    if (-not $a) { throw "Node $($n.Name) has neither management_ip nor bmc_address." }
    [ordered]@{ name = $n.Name; address = $a }
}
$nodes = @($nodes)
$nodes[0].seed = $true
$config = [ordered]@{
    subscriptionId    = $SubscriptionId.ToLowerInvariant()
    resourceGroup     = $ResourceGroupName
    clusterName       = $ClusterName
    provisioningRoute = 'simplified'
    identityModel     = 'LocalIdentity'
    pollSeconds       = 20
    nodes             = $nodes
    ztpEvents         = [ordered]@{ path = [System.IO.Path]::GetFullPath($EventLogPath) }
    credential        = [ordered]@{ source = 'prompt' }
}
$sonarArgs = @{ ConfigPath = $SonarConfigPath; Port = $Port }
if ($NoBrowser) { $sonarArgs.NoBrowser = $true }
if ($Record) { $sonarArgs.Record = $Record }
if (-not $Execute) {
    "PLAN: write $SonarConfigPath :"
    ($config | ConvertTo-Json -Depth 6)
    "PLAN: & $start $(($sonarArgs.GetEnumerator() | ForEach-Object { if ($_.Value -is [bool]) { "-$($_.Key)" } else { "-$($_.Key) $($_.Value)" } }) -join ' ')   (read-only; sign in with Connect-AzAccount first)"
    return
}
$folder = Split-Path -Parent $SonarConfigPath
if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
$config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $SonarConfigPath -Encoding utf8NoBOM
& $start @sonarArgs
