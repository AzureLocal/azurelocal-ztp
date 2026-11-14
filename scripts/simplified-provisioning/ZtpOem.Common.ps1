#Requires -Version 7.0
<#
.SYNOPSIS
Shared helpers for the OEM layer (dot-sourced by Wait-ZtpBootstrapComplete.ps1 and Mount-ZtpVirtualUsb.ps1).
.DESCRIPTION
OEM data lives in config/oem/<oem>.json: the BMC kind, its manager and system IDs, the virtual-media slot, the log services
and the signal patterns the Bootstrap watch reads, and how the Boot stage boots the USB-stick slot once on a BMC without a
Usb override target (bmc.usbBootOnce). Adding an OEM is adding a file. ZTP carries no SBE: the OS install
discovers its own, and staging one is OS configuration, so the OEM files hold no SBE settings.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ZtpOemConfigRoot {
    [CmdletBinding()]
    param()
    return (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'config/oem')
}

function Get-ZtpOemConfig {
    <#
    .SYNOPSIS
    Reads config/oem/<Oem>.json (or -ConfigRoot) and checks the fields the scripts rely on.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,40}$')][string]$Oem, [string]$ConfigRoot = (Get-ZtpOemConfigRoot))
    $path = Join-Path $ConfigRoot "$($Oem.ToLowerInvariant()).json"
    if (-not (Test-Path -LiteralPath $path)) {
        $known = @(Get-ChildItem -LiteralPath $ConfigRoot -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object BaseName)
        throw "No OEM definition $path. Known OEMs: $($known -join ', '). To add one, copy config/oem/dell.json and edit it."
    }
    $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 20
    foreach ($field in 'oem', 'publisher', 'bmc') {
        if (-not $config.PSObject.Properties[$field]) { throw "OEM definition $path lacks '$field'." }
    }
    foreach ($field in 'kind', 'logServices') {
        if (-not $config.bmc.PSObject.Properties[$field]) { throw "OEM definition $path lacks bmc.$field." }
    }
    if ($config.bmc.PSObject.Properties['usbBootOnce']) {
        $once = $config.bmc.usbBootOnce
        if ($null -eq $once -or $once -isnot [pscustomobject]) { throw "OEM definition $path has a bmc.usbBootOnce that is not an object." }
        if ($once.PSObject.Properties['managerAttributes']) {
            if ($once.managerAttributes -isnot [pscustomobject]) { throw "OEM definition $path has a bmc.usbBootOnce.managerAttributes that is not an object of attribute names and values." }
            foreach ($p in $once.managerAttributes.PSObject.Properties) { if ($p.Value -isnot [string]) { throw "OEM definition $path has bmc.usbBootOnce.managerAttributes.$($p.Name) that is not a string." } }
        }
        if ($once.PSObject.Properties['overrideTarget'] -and $once.overrideTarget -isnot [string]) { throw "OEM definition $path has a bmc.usbBootOnce.overrideTarget that is not a string." }
        if (-not $once.PSObject.Properties['managerAttributes'] -and -not $once.PSObject.Properties['overrideTarget']) { throw "OEM definition $path has a bmc.usbBootOnce with neither managerAttributes nor overrideTarget." }
    }
    return $config
}

function Get-ZtpOemUsbBootOnce {
    <#
    .SYNOPSIS
    How a BMC that offers no Usb boot override target boots its USB-stick slot once, from the OEM definition
    (bmc.usbBootOnce): the manager attributes to set (name -> value) and the standard one-time override target to set with
    them. $null when the definition has none.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][object]$Config)
    if (-not $Config.bmc.PSObject.Properties['usbBootOnce']) { return $null }
    $once = $Config.bmc.usbBootOnce
    $attributes = [ordered]@{}
    if ($once.PSObject.Properties['managerAttributes']) { foreach ($p in $once.managerAttributes.PSObject.Properties) { $attributes[$p.Name] = [string]$p.Value } }
    $target = if ($once.PSObject.Properties['overrideTarget']) { [string]$once.overrideTarget } else { $null }
    return [pscustomobject]@{ ManagerAttributes = $attributes; OverrideTarget = $target }
}
