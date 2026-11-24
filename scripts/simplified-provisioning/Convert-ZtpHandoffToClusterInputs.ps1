#Requires -Version 7.0
<#
.SYNOPSIS
Turns ztp-handoff.json into the change the cluster deployment needs in infrastructure.yml: nodes[].arc_machine_name and
deployment.solution_version. Prints the change, and with -InfrastructureFile writes it into that file.
.DESCRIPTION
The cluster deployment reads nodes[].arc_machine_name (to build the Arc node resource IDs, and in its pre-Deploy Arc-name
gate) and deployment.solution_version (the release to install) from infrastructure.yml. ZTP names each Arc machine after
its node unless the file says otherwise, and the handoff records the name Azure actually has (on the live runs
<device-id>-1), together with the build the maintenance image installed. This script is the one step that carries the
handoff into the file the next tools read.

Without -InfrastructureFile it only prints the patch (YAML by default, or JSON) and optionally writes it to -OutputPath:
no Azure, no hardware, no file other than -OutputPath is touched. With -InfrastructureFile it applies the patch with the
toolkit's AzlInfrastructureEdit module ($env:AZL_TOOLKIT_ROOT, else an azurelocal-toolkit clone next to this repository):
only those values change, comments, order and quoting stay, and a backup (<file>.bak.<time>) is written first. A file
without a deployment block gets one at the end. Nothing is written when a node of the handoff is not in the file or a key
cannot be set: the run stops and lists them. -WhatIf shows the change without writing it.

Reads handoff schema 2 (New-ZtpHandoff.ps1 now) and schema 1 (before ZTP ended at the Network stage); a schema 1 handoff's
sbe block is ignored, because ZTP carries no SBE.
.PARAMETER HandoffPath
ztp-handoff.json from New-ZtpHandoff.ps1.
.PARAMETER Format
Yaml (default) or Json: the printed patch.
.PARAMETER Only
Emit and apply only these keys: nodes (nodes[].arc_machine_name) or deployment (deployment.solution_version). Default: both.
.PARAMETER OutputPath
Also write the printed patch here.
.PARAMETER InfrastructureFile
The infrastructure.yml to change. Without it nothing but the printed patch is produced.
.EXAMPLE
./Convert-ZtpHandoffToClusterInputs.ps1 -HandoffPath ./ztp-handoff.json -InfrastructureFile ./infrastructure.yml
.EXAMPLE
./Convert-ZtpHandoffToClusterInputs.ps1 -HandoffPath ./ztp-handoff.json -Only nodes
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$HandoffPath,
    [ValidateSet('Yaml', 'Json')][string]$Format = 'Yaml',
    [ValidateSet('nodes', 'deployment')][string[]]$Only,
    [string]$OutputPath,
    [string]$InfrastructureFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $HandoffPath -PathType Leaf)) { throw "Handoff file not found: $HandoffPath" }
$h = Get-Content -LiteralPath $HandoffPath -Raw | ConvertFrom-Json -Depth 20
if (-not $h.PSObject.Properties['schemaVersion'] -or [int]$h.schemaVersion -notin 1, 2) { throw "Unsupported handoff schemaVersion in $HandoffPath." }
$nodes = @($h.nodes)
if ($nodes.Count -eq 0) { throw 'The handoff lists no nodes.' }
$map = [ordered]@{}
foreach ($n in $nodes) {
    if ([string]::IsNullOrWhiteSpace([string]$n.name) -or [string]::IsNullOrWhiteSpace([string]$n.arcMachineName)) { throw "Handoff node '$($n.name)' has no Arc machine name; was it ready to cluster?" }
    if ($map.Contains([string]$n.name)) { throw "Duplicate node name $($n.name) in the handoff." }
    $map[[string]$n.name] = [string]$n.arcMachineName
}
if (@($map.Values | Select-Object -Unique).Count -ne $map.Count) { throw 'Two nodes share one Arc machine name.' }
$vsr = if ($h.PSObject.Properties['solution'] -and $h.solution -and $h.solution.PSObject.Properties['vsrVersion']) { [string]$h.solution.vsrVersion } else { '' }
$all = [ordered]@{
    nodes = @($map.Keys | ForEach-Object { [ordered]@{ name = $_; arc_machine_name = $map[$_] } })
}
if ($vsr -and $vsr -ne 'latest') { $all['deployment'] = [ordered]@{ solution_version = $vsr } }
$out = [ordered]@{}
foreach ($key in $all.Keys) { if (-not $Only -or $key -in $Only) { $out[$key] = $all[$key] } }

function ConvertTo-ZtpYamlScalar {
    param([AllowNull()][object]$Value)
    $s = [string]$Value
    if ($s -eq '') { return "''" }
    if ($s -match "^[A-Za-z0-9_.@/-][A-Za-z0-9_./@+-]*$" -and $s -notmatch '^(true|false|null|yes|no|on|off|~)$' -and $s -notmatch '^[0-9.+-]+$') { return $s }
    return "'" + $s.Replace("'", "''") + "'"
}
$text = if ($Format -eq 'Json') { $out | ConvertTo-Json -Depth 6 }
else {
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $out.Keys) {
        $lines.Add("${key}:")
        if ($key -eq 'nodes') {
            foreach ($item in $out[$key]) {
                $lines.Add("  - name: $(ConvertTo-ZtpYamlScalar $item['name'])")
                $lines.Add("    arc_machine_name: $(ConvertTo-ZtpYamlScalar $item['arc_machine_name'])")
            }
        }
        else { foreach ($k in $out[$key].Keys) { $lines.Add("  ${k}: $(ConvertTo-ZtpYamlScalar $out[$key][$k])") } }
    }
    $lines -join "`n"
}
if ($OutputPath) {
    $folder = Split-Path -Parent $OutputPath
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
    Set-Content -LiteralPath $OutputPath -Value $text -Encoding utf8NoBOM
}

if ($InfrastructureFile) {
    if (-not (Test-Path -LiteralPath $InfrastructureFile -PathType Leaf)) { throw "Infrastructure file not found: $InfrastructureFile" }
    . (Join-Path $PSScriptRoot 'ZtpEnvironment.Common.ps1')
    $module = Find-ZtpToolkitFile -Relative 'scripts\common\infrastructure\AzlInfrastructureEdit.psm1'
    if (-not $module) { throw "The toolkit's AzlInfrastructureEdit.psm1 (scripts/common/infrastructure) isn't found under $(Get-ZtpToolkitRoot). Set AZL_TOOLKIT_ROOT to an azurelocal-toolkit clone, or clone azurelocal-toolkit next to this repository." }
    Import-Module $module -Force
    # One change per key: the Arc machine name of each node (by node name), and the solution version.
    $changes = [System.Collections.Generic.List[object]]::new()
    if ($out.Contains('nodes')) {
        foreach ($item in $out['nodes']) { $changes.Add([pscustomobject]@{ Path = @('nodes', "[name=$($item['name'])]", 'arc_machine_name'); New = $item['arc_machine_name']; Display = "nodes[$($item['name'])].arc_machine_name" }) }
    }
    if ($out.Contains('deployment')) { $changes.Add([pscustomobject]@{ Path = @('deployment', 'solution_version'); New = $out['deployment']['solution_version']; Display = 'deployment.solution_version' }) }
    # Every change is made on a copy of the lines first, so a file that lacks a node is left as it is.
    $raw = Get-Content -LiteralPath $InfrastructureFile -Raw
    $newline = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
    $copy = [System.Collections.Generic.List[string]]::new([string[]]($raw -split '\r?\n'))
    if ($out.Contains('deployment') -and -not @($copy | Where-Object { $_ -match '^["'']?deployment["'']?\s*:' }).Count) {
        while ($copy.Count -and [string]::IsNullOrWhiteSpace($copy[$copy.Count - 1])) { $copy.RemoveAt($copy.Count - 1) }
        # Inside the document: before a document end marker, when the file has one.
        $at = if ($copy.Count -and $copy[$copy.Count - 1].Trim() -eq '...') { $copy.Count - 1 } else { $copy.Count }
        $copy.InsertRange($at, [string[]]@('', 'deployment:', '  solution_version: ""'))
        if ($at -eq $copy.Count - 3) { $copy.Add('') }
    }
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $changes) {
        $r = Edit-AzlYamlValue -Lines $copy -Path $c.Path -Value $c.New -InsertIfMissing
        $results.Add([pscustomobject]@{ Display = $c.Display; Result = $r.Result; Old = $r.Old })
    }
    $missing = @($results | Where-Object { $_.Result -in 'NotFound', 'NotScalar' } | ForEach-Object { "$($_.Display) ($(if ($_.Result -eq 'NotFound') { 'the node is not in the file' } else { 'the key holds a block, not a value' }))" })
    if ($missing.Count) { throw "$InfrastructureFile was not changed. These handoff values cannot be placed: $($missing -join '; '). Check the node names in the file against the handoff." }
    if ($PSCmdlet.ShouldProcess($InfrastructureFile, "Write $($changes.Count) value(s) from the handoff")) {
        $backup = "$InfrastructureFile.bak.$([datetime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))"
        Copy-Item -LiteralPath $InfrastructureFile -Destination $backup
        [System.IO.File]::WriteAllText($InfrastructureFile, ($copy -join $newline), [System.Text.UTF8Encoding]::new($false))
        foreach ($r in $results) { Write-Information "$($r.Display): $($r.Result)$(if ($r.Result -eq 'Changed') { " (was '$($r.Old)')" })" -InformationAction Continue }
        Write-Information "Backup: $backup" -InformationAction Continue
    }
}
return $text
