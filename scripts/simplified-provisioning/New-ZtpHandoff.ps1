#Requires -Version 7.0
<#
.SYNOPSIS
Writes ztp-handoff.json: what cluster deployment needs from provisioning, once every machine is ready to cluster.
Plan by default.
.DESCRIPTION
Reads (GET only) each edge machine and its ProvisionOs job, requires every machine to be ready to cluster, and records
node names, the Arc machine names (simplified machine provisioning names the Arc machine by device ID, for example
<device-id>-1, not by host name), their resource IDs and resource group, the site, the solution recipe version (vsrVersion),
the bootstrap ISO version, the SBE (from Get-ZtpSbe.ps1's sbe-manifest.json) and timestamps. Feed it to
Convert-ZtpHandoffToClusterInputs.ps1 to get the arc_machine_names block for the cluster deployment environment file.
The handoff holds Azure resource IDs of your subscription: keep it out of source control.
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
.PARAMETER SbeManifestPath
sbe-manifest.json written by Get-ZtpSbe.ps1 -Execute (optional).
.PARAMETER BootstrapManifestPath
bootstrap-manifest.json written by Get-ZtpBootstrapIso.ps1 -Execute (optional).
.PARAMETER EventLogPath
The bootstrap event file; its first and last timestamps are recorded (optional).
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
    [string]$SbeManifestPath,
    [string]$BootstrapManifestPath,
    [string]$EventLogPath,
    [string]$HandoffPath = (Join-Path (Get-Location) 'ztp-handoff.json'),
    [string]$ApiVersion = '2025-12-01-preview',
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpAzure.Common.ps1')
. (Join-Path $PSScriptRoot 'ZtpVirtualUsb.Common.ps1')

$serials = @{}
if ($Nodes -or $NodesFile) { foreach ($n in @(Get-ZtpNodeList -Nodes $Nodes -NodesFile $NodesFile -NodeName $NodeName)) { $serials[$n.Name] = $n.Serial } }

$rgPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.AzureStackHCI/edgeMachines"
$rows = [System.Collections.Generic.List[object]]::new()
$notReady = [System.Collections.Generic.List[string]]::new()
$vsr = [System.Collections.Generic.HashSet[string]]::new()
$site = $null
foreach ($name in $NodeName) {
    $machine = Invoke-ZtpArm -Method GET -Path "$rgPath/$name" -ApiVersion $ApiVersion -AllowNotFound
    $job = if ($machine) { Invoke-ZtpArm -Method GET -Path "$rgPath/$name/jobs/ProvisionOs" -ApiVersion $ApiVersion -AllowNotFound } else { $null }
    $status = Get-ZtpEdgeMachineStatus -Name $name -Machine $machine -Job $job
    if (-not $status.Ready) { $notReady.Add("$name ($($status.Lifecycle)$(if ($status.FailureReason) { ": $($status.FailureReason)" }))"); continue }
    $arcId = [string]$status.ArcMachineResourceId
    $arcRg = if ($arcId -match '/resourceGroups/([^/]+)/') { $Matches[1] } else { '' }
    $null = $vsr.Add([string](Get-ZtpPathValue $machine 'properties.provisioningDetails.osProfile.vsrVersion' ''))
    if (-not $site) { $site = [string](Get-ZtpPathValue $machine 'properties.siteDetails.siteResourceId' '') }
    $rows.Add([ordered]@{
            name                  = $name
            serial                = $(if ($serials.ContainsKey($name)) { $serials[$name] } else { $null })
            edgeMachineName       = $name
            edgeMachineId         = [string](Get-ZtpPropertyValue $machine 'id' '')
            arcMachineName        = [string]$status.ArcMachineName
            arcMachineResourceId  = $arcId
            arcMachineResourceGroup = $arcRg
            connectivity          = $status.Connectivity
            ready                 = $true
        })
}
if ($notReady.Count -gt 0) { throw "Not ready to cluster: $($notReady -join '; '). No handoff written; rerun Wait-ZtpMachineReady.ps1." }
$names = @($rows | ForEach-Object { $_.arcMachineName })
if (@($names | Select-Object -Unique).Count -ne $names.Count) { throw "Duplicate Arc machine names: $($names -join ', ')." }
if (@($vsr).Count -gt 1) { Write-ZtpLog "The machines carry different vsrVersion values: $(@($vsr) -join ', '). A cluster needs one." -Level Warning }

function ConvertTo-ZtpUtcText {
    # ConvertFrom-Json turns ISO 8601 strings into DateTime; write them back as the UTC text they were.
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-dd''T''HH:mm:ss''Z''') }
    return [string]$Value
}
$read = { param([string]$Path) if ($Path -and (Test-Path -LiteralPath $Path)) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 20 } else { $null } }
$sbe = & $read $SbeManifestPath
$boot = & $read $BootstrapManifestPath
$first = $null; $last = $null
if ($EventLogPath -and (Test-Path -LiteralPath $EventLogPath)) {
    $stamps = @(Get-Content -LiteralPath $EventLogPath | ForEach-Object { if ($_ -match '"timestamp":"([^"]+)"') { $Matches[1] } })
    if ($stamps.Count -gt 0) { $first = $stamps[0]; $last = $stamps[-1] }
}
$handoff = [ordered]@{
    schemaVersion  = 1
    generatedUtc   = [datetime]::UtcNow.ToString('o')
    tool           = 'azurelocal-ztp'
    subscriptionId = $SubscriptionId
    resourceGroup  = $ResourceGroupName
    site           = [ordered]@{ resourceId = $site; name = $(if ($site) { $site.Split('/')[-1] } else { $null }) }
    arcMachineResourceGroup = @($rows | ForEach-Object { $_.arcMachineResourceGroup } | Select-Object -Unique) -join ','
    solution       = [ordered]@{ vsrVersion = $(@($vsr)[0]) }
    bootstrap      = $(if ($boot) { [ordered]@{ version = $boot.version; isoSha256 = $boot.isoSha256; url = $boot.url } } else { $null })
    sbe            = $(if ($sbe) { [ordered]@{ oem = $sbe.oem; version = $sbe.version; family = $sbe.family; publisher = $sbe.deploymentParameters.sbePublisher; manifestSource = $sbe.manifestSource; manifestCreationDate = (ConvertTo-ZtpUtcText $sbe.manifestCreationDate); packageSha256 = $sbe.packageSha256; compatibilityChecked = $sbe.compatibilityChecked } } else { $null })
    timestamps     = [ordered]@{ bootstrapFirstEvent = $first; bootstrapLastEvent = $last; handoffUtc = [datetime]::UtcNow.ToString('o') }
    nodes          = @($rows)
}
if (-not $Execute) {
    Write-ZtpLog "PLAN: would write $HandoffPath for $($NodeName -join ', ') (all ready to cluster). Add -Execute."
    return [pscustomobject]$handoff
}
$folder = Split-Path -Parent $HandoffPath
if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
$handoff | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $HandoffPath -Encoding utf8NoBOM
Write-ZtpLog "Wrote $HandoffPath ($($rows.Count) node(s)). Next: Convert-ZtpHandoffToClusterInputs.ps1 -HandoffPath $HandoffPath."
return [pscustomobject]@{ HandoffPath = $HandoffPath; Nodes = @($rows | ForEach-Object { $_.name }); ArcMachineNames = $names }
