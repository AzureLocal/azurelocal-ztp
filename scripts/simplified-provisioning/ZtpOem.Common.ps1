#Requires -Version 7.0
<#
.SYNOPSIS
Shared helpers for the OEM layer (dot-sourced by Wait-ZtpBootstrapComplete.ps1).
.DESCRIPTION
OEM data lives in config/oem/<oem>.json: the BMC kind, its manager and system IDs, the virtual-media slot, the log services
and the signal patterns the Bootstrap watch reads. Adding an OEM is adding a file. ZTP carries no SBE: the OS install
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
    return $config
}
