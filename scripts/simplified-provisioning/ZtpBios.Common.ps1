#Requires -Version 7.0
<#
.SYNOPSIS
BIOS settings for the Boot stage (dot-sourced by Set-ZtpBios.ps1 and Start-MaintenanceBoot.ps1).
.DESCRIPTION
The environment file names BIOS attributes to set before the maintenance boot (hardware.bios, with cluster_nodes[].bios
merged over it). Invoke-ZtpEnvironment.ps1 writes each node's merged map to the node list as bios; the Boot stage applies
it through Redfish. Nothing here talks to a BMC: these functions read the node list and compare values.
Functions: Get-ZtpNodeBiosSetting, Get-ZtpBiosChange, ConvertTo-ZtpBiosValue.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ZtpNodeBiosSetting {
    <#
    .SYNOPSIS
    The BIOS attributes of one node in the node list (its bios mapping), as an ordered dictionary of strings. Empty when
    the node has none.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$NodeName, [object[]]$Nodes)
    $settings = [ordered]@{}
    foreach ($n in @($Nodes)) {
        $name = if ($n -is [System.Collections.IDictionary]) { [string]$n['name'] } elseif ($n.PSObject.Properties['name']) { [string]$n.name } else { '' }
        if ($name -ne $NodeName) { continue }
        $bios = if ($n -is [System.Collections.IDictionary]) { if ($n.Contains('bios')) { $n['bios'] } } elseif ($n.PSObject.Properties['bios']) { $n.bios } else { $null }
        if ($null -eq $bios) { break }
        if ($bios -is [System.Collections.IDictionary]) { foreach ($k in $bios.Keys) { $settings[[string]$k] = [string]$bios[$k] } }
        else { foreach ($p in $bios.PSObject.Properties) { $settings[$p.Name] = [string]$p.Value } }
        break
    }
    return $settings
}

function Get-ZtpNodeBiosReason {
    <#
    .SYNOPSIS
    Why ZTP chose the BIOS attributes it derived for one node (attribute -> reason), from the node list's bios_reason. Empty
    for attributes the file wrote itself.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$NodeName, [object[]]$Nodes)
    $reasons = [ordered]@{}
    foreach ($n in @($Nodes)) {
        $name = if ($n -is [System.Collections.IDictionary]) { [string]$n['name'] } elseif ($n.PSObject.Properties['name']) { [string]$n.name } else { '' }
        if ($name -ne $NodeName) { continue }
        $r = if ($n -is [System.Collections.IDictionary]) { if ($n.Contains('bios_reason')) { $n['bios_reason'] } } elseif ($n.PSObject.Properties['bios_reason']) { $n.bios_reason } else { $null }
        if ($r -is [System.Collections.IDictionary]) { foreach ($k in $r.Keys) { $reasons[[string]$k] = [string]$r[$k] } }
        elseif ($null -ne $r) { foreach ($p in $r.PSObject.Properties) { $reasons[$p.Name] = [string]$p.Value } }
        break
    }
    return $reasons
}

function ConvertTo-ZtpBiosValue {
    <#
    .SYNOPSIS
    The file's string value in the type the BMC reports for the attribute now (integer, boolean or string), so the PATCH
    sends what the BIOS expects.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Current, [Parameter(Mandatory)][AllowEmptyString()][string]$Value, [string]$Attribute = 'the attribute')
    if ($Current -is [bool]) {
        if ($Value -in 'true', 'false') { return [bool]::Parse($Value) }
        throw "BIOS attribute $Attribute is a boolean; '$Value' isn't true or false."
    }
    if ($Current -is [int] -or $Current -is [long] -or $Current -is [double] -or $Current -is [decimal]) {
        $number = 0L
        if ([long]::TryParse($Value, [ref]$number)) { return $number }
        throw "BIOS attribute $Attribute is a number; '$Value' isn't one."
    }
    return $Value
}

function Get-ZtpBiosChange {
    <#
    .SYNOPSIS
    What has to change: one object per desired attribute whose current value differs. Throws when the BIOS has no such
    attribute, before anything is changed, so a misspelt name never half-applies.
    .PARAMETER Current
    The Attributes object of the BMC's Bios resource.
    .PARAMETER Desired
    Attribute name -> value (strings) from the environment file.
    .OUTPUTS
    Attribute, Current (as the BIOS reports it), Desired (the file's string), Value (typed for the PATCH).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowNull()][object]$Current, [Parameter(Mandatory)][System.Collections.IDictionary]$Desired, [System.Collections.IDictionary]$Reason)
    $names = @(if ($Current -is [System.Collections.IDictionary]) { $Current.Keys } elseif ($null -ne $Current) { $Current.PSObject.Properties.Name })
    $read = { param($n) if ($Current -is [System.Collections.IDictionary]) { $Current[$n] } else { $Current.$n } }
    $unknown = @($Desired.Keys | Where-Object { $_ -cnotin $names })
    if ($unknown) {
        # An attribute ZTP derived from the inventory says why it looked for it; one the file wrote needs only its name.
        $text = @($unknown | ForEach-Object { if ($Reason -and $Reason.Contains($_)) { "$_ ($($Reason[$_]))" } else { $_ } }) -join '; '
        throw "The BIOS has no attribute $text. Attribute names are case-sensitive; read them from /redfish/v1/Systems/<id>/Bios."
    }
    foreach ($name in $Desired.Keys) {
        $now = & $read $name
        $want = [string]$Desired[$name]
        $nowText = if ($now -is [bool]) { $now.ToString().ToLowerInvariant() } else { [string]$now }
        if ($nowText -ceq $want) { continue }
        [pscustomobject]@{ Attribute = [string]$name; Current = $now; Desired = $want; Value = (ConvertTo-ZtpBiosValue -Current $now -Value $want -Attribute $name) }
    }
}
