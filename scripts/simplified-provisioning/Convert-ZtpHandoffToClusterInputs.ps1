#Requires -Version 7.0
<#
.SYNOPSIS
Turns ztp-handoff.json into the block the cluster deployment solution wants in its environment file: arc_machine_names
(node host name -> Arc machine name), plus the sbe descriptor and the release versions when the handoff has them.
.DESCRIPTION
Simplified machine provisioning names each Arc machine by device ID, not after the host, so the cluster deployment needs
arc_machine_names[<host name>] to build the Arc node resource IDs (and its pre-Deploy Arc-name gate reads the same map). The
output is plain YAML (default) or JSON, printed and optionally written to -OutputPath, for the attendee to paste into their
environment file. Pure conversion: no Azure, no hardware, no file other than -OutputPath is touched.
Keys: arc_machine_names; sbe { version, family, publisher, manifest_source, manifest_creation_date } (empty when the handoff
has no SBE); release { azure_local_version (the solution recipe version), sbe_version }. Check release.* against your
environment schema before pasting: only arc_machine_names is required by the cluster deployment inputs.
.PARAMETER HandoffPath
ztp-handoff.json from New-ZtpHandoff.ps1.
.PARAMETER Format
Yaml (default) or Json.
.PARAMETER Only
Emit only these keys (default: all that the handoff can fill).
.PARAMETER OutputPath
Also write the text here.
.EXAMPLE
./Convert-ZtpHandoffToClusterInputs.ps1 -HandoffPath ./ztp-handoff.json -Only arc_machine_names
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HandoffPath,
    [ValidateSet('Yaml', 'Json')][string]$Format = 'Yaml',
    [ValidateSet('arc_machine_names', 'sbe', 'release')][string[]]$Only,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $HandoffPath -PathType Leaf)) { throw "Handoff file not found: $HandoffPath" }
$h = Get-Content -LiteralPath $HandoffPath -Raw | ConvertFrom-Json -Depth 20
if (-not $h.PSObject.Properties['schemaVersion'] -or [int]$h.schemaVersion -ne 1) { throw "Unsupported handoff schemaVersion in $HandoffPath." }
function ConvertTo-ZtpUtcText {
    # ConvertFrom-Json turns ISO 8601 strings into DateTime; write them back as the UTC text they were.
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-dd''T''HH:mm:ss''Z''') }
    return [string]$Value
}
$nodes = @($h.nodes)
if ($nodes.Count -eq 0) { throw 'The handoff lists no nodes.' }
$map = [ordered]@{}
foreach ($n in $nodes) {
    if ([string]::IsNullOrWhiteSpace([string]$n.name) -or [string]::IsNullOrWhiteSpace([string]$n.arcMachineName)) { throw "Handoff node '$($n.name)' has no Arc machine name; was it ready to cluster?" }
    if ($map.Contains([string]$n.name)) { throw "Duplicate node name $($n.name) in the handoff." }
    $map[[string]$n.name] = [string]$n.arcMachineName
}
if (@($map.Values | Select-Object -Unique).Count -ne $map.Count) { throw 'Two nodes share one Arc machine name.' }
$sbe = if ($h.PSObject.Properties['sbe'] -and $h.sbe) { $h.sbe } else { $null }
$vsr = if ($h.PSObject.Properties['solution'] -and $h.solution) { [string]$h.solution.vsrVersion } else { '' }
$all = [ordered]@{
    arc_machine_names = $map
    sbe               = $(if ($sbe) { [ordered]@{ version = [string]$sbe.version; family = [string]$sbe.family; publisher = [string]$sbe.publisher; manifest_source = [string]$sbe.manifestSource; manifest_creation_date = (ConvertTo-ZtpUtcText $sbe.manifestCreationDate) } } else { [ordered]@{} })
    release           = [ordered]@{ azure_local_version = $vsr; sbe_version = $(if ($sbe) { [string]$sbe.version } else { '' }) }
}
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
        $value = $out[$key]
        if ($value.Count -eq 0) { $lines.Add("${key}: {}"); continue }
        $lines.Add("${key}:")
        foreach ($k in $value.Keys) { $lines.Add("  $(ConvertTo-ZtpYamlScalar $k): $(ConvertTo-ZtpYamlScalar $value[$k])") }
    }
    $lines -join "`n"
}
if ($OutputPath) {
    $folder = Split-Path -Parent $OutputPath
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
    Set-Content -LiteralPath $OutputPath -Value $text -Encoding utf8NoBOM
}
return $text
