#Requires -Version 7.0
<#
.SYNOPSIS
Shared helpers for the OEM layer and Solution Builder Extension (SBE) discovery (dot-sourced by Get-ZtpSbe.ps1 and the
orchestrator).
.DESCRIPTION
OEM data lives in config/oem/<oem>.json (SBE discovery manifest URL, BMC log services and signal patterns); adding an OEM is
adding a file. The SBE discovery manifest is the XML Microsoft's update service queries (SBE_Discovery_<oem>.xml): one
ApplicableUpdate per SBE with its supported models, the solution versions it was validated with (RequiredPackages), a
SHA256 and a size. Pure parsing and selection functions; the network goes through Invoke-ZtpHttp.
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
    Reads config/oem/<Oem>.json (or -Path) and checks the fields the scripts rely on.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,40}$')][string]$Oem, [string]$ConfigRoot = (Get-ZtpOemConfigRoot))
    $path = Join-Path $ConfigRoot "$($Oem.ToLowerInvariant()).json"
    if (-not (Test-Path -LiteralPath $path)) {
        $known = @(Get-ChildItem -LiteralPath $ConfigRoot -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object BaseName)
        throw "No OEM definition $path. Known OEMs: $($known -join ', '). To add one, copy config/oem/dell.json and edit it."
    }
    $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 20
    foreach ($field in 'oem', 'publisher', 'sbe', 'bmc') {
        if (-not $config.PSObject.Properties[$field]) { throw "OEM definition $path lacks '$field'." }
    }
    foreach ($field in 'discoveryManifestUrl', 'downloadMethod') {
        if (-not $config.sbe.PSObject.Properties[$field]) { throw "OEM definition $path lacks sbe.$field." }
    }
    if ($config.sbe.discoveryManifestUrl -and [string]$config.sbe.discoveryManifestUrl -notmatch '^https://') { throw "sbe.discoveryManifestUrl in $path must be https." }
    return $config
}

function Read-ZtpSbeManifest {
    <#
    .SYNOPSIS
    Parses an SBE discovery manifest (XML text) into one object per ApplicableUpdate of Type SBE (pure).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    $xml = [xml]::new()
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($Text), $settings)
    try { $xml.Load($reader) } finally { $reader.Dispose() }
    $root = $xml.SelectSingleNode('/SBEUpdatesManifest')
    if (-not $root) { throw 'Not an SBE discovery manifest (no SBEUpdatesManifest root).' }
    $info = $root.SelectSingleNode('ManifestInfo')
    $created = if ($info -and $info.Attributes['CreationDate']) { $info.Attributes['CreationDate'].Value } else { $null }
    foreach ($node in $root.SelectNodes('ApplicableUpdate')) {
        if ($node.Attributes['Type'] -and $node.Attributes['Type'].Value -ne 'SBE') { continue }
        $patterns = foreach ($p in $node.SelectNodes('ValidatedConfigurations/RequiredPackages/Package[@Type="Solution"]')) {
            [pscustomobject]@{ Version = $p.Attributes['Version'].Value; MinVersionRequired = $(if ($p.Attributes['MinVersionRequired']) { $p.Attributes['MinVersionRequired'].Value } else { $null }) }
        }
        $file = $node.SelectSingleNode('File')
        $meta = $node.SelectSingleNode('MetadataFile')
        $models = @($node.SelectNodes('UpdateInfo/SupportedModels/SupportedModel') | ForEach-Object { $_.InnerText.Trim() })
        $size = 0
        $null = [int]::TryParse($node.SelectSingleNode('UpdateInfo/PackageSizeInMb')?.InnerText, [ref]$size)
        [pscustomobject]@{
            Version              = $node.Attributes['Version'].Value
            Family               = $node.Attributes['Family'].Value
            Publisher            = $node.SelectSingleNode('UpdateInfo/Publisher')?.InnerText
            UpdateName           = $node.SelectSingleNode('UpdateInfo/UpdateName')?.InnerText
            Description          = $node.SelectSingleNode('UpdateInfo/Description')?.InnerText
            SupportedModels      = $models
            SolutionPatterns     = @($patterns)
            PackageHash          = $node.SelectSingleNode('UpdateInfo/PackageHash')?.InnerText
            PackageSizeInMb      = $size
            DownloadType         = $(if ($file -and $file.Attributes['Type']) { $file.Attributes['Type'].Value } else { $null })
            PackageFileName      = $(if ($file -and $file.Attributes['Name']) { $file.Attributes['Name'].Value } else { $null })
            DownloadUri          = $(if ($file -and $file.Attributes['Uri'] -and $file.Attributes['Uri'].Value) { $file.Attributes['Uri'].Value } else { $null })
            ReleaseNotesUri      = $(if ($file -and $file.Attributes['NotifyUri']) { $file.Attributes['NotifyUri'].Value } else { $null })
            NotifyMessage        = $(if ($file -and $file.Attributes['NotifyMsg']) { $file.Attributes['NotifyMsg'].Value } else { $null })
            MetadataFileName     = $(if ($meta -and $meta.Attributes['Name']) { $meta.Attributes['Name'].Value } else { $null })
            MetadataUri          = $(if ($meta -and $meta.Attributes['Uri'] -and $meta.Attributes['Uri'].Value) { $meta.Attributes['Uri'].Value } else { $null })
            Capabilities         = @($node.SelectNodes('UpdateInfo/AdvancedSBECapabilities/Capability') | ForEach-Object { $_.InnerText.Trim() })
            ManifestCreationDate = $created
        }
    }
}

function Test-ZtpSbeSolutionMatch {
    <#
    .SYNOPSIS
    True when a solution version (12.2609.1003.7) satisfies at least one validated Solution pattern of an SBE
    (12.*.1003.* with an optional MinVersionRequired). -SolutionVersion may be partial (12.2609): the pattern then compares
    on the given segments and the minimum is truncated to the same length.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][object[]]$Patterns, [Parameter(Mandatory)][ValidatePattern('^\d+(\.\d+){1,3}$')][string]$SolutionVersion)
    $segments = $SolutionVersion.Split('.')
    foreach ($p in $Patterns) {
        $patternSegments = $p.Version.Split('.')
        $ok = $true
        for ($i = 0; $i -lt $segments.Count -and $i -lt $patternSegments.Count; $i++) {
            if ($patternSegments[$i] -ne '*' -and $patternSegments[$i] -ne $segments[$i]) { $ok = $false; break }
        }
        if (-not $ok) { continue }
        if ($p.MinVersionRequired) {
            $min = $p.MinVersionRequired.Split('.')
            $minTruncated = [version]($min[0..([math]::Min($segments.Count, $min.Count) - 1)] -join '.')
            if ([version]$SolutionVersion -lt $minTruncated) { continue }
        }
        return $true
    }
    return $false
}

function Select-ZtpSbeUpdate {
    <#
    .SYNOPSIS
    The newest SBE for a model or family that was validated with the given solution version, or $null (pure).
    .DESCRIPTION
    -SolutionVersion latest skips the compatibility test (the newest SBE is returned and the caller reports that
    compatibility was not checked). -Model must be in SupportedModels; -Family must equal the entry's Family. Newest is
    the highest [version] of the SBE version.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Updates,
        [string]$SolutionVersion = 'latest',
        [string]$Model,
        [string]$Family
    )
    $pool = @($Updates)
    if ($Model) { $pool = @($pool | Where-Object { @($_.SupportedModels) -contains $Model -or (@($_.SupportedModels) | Where-Object { $_ -ieq $Model }) }) }
    if ($Family) { $pool = @($pool | Where-Object { $_.Family -ieq $Family }) }
    if ($SolutionVersion -ne 'latest') { $pool = @($pool | Where-Object { Test-ZtpSbeSolutionMatch -Patterns $_.SolutionPatterns -SolutionVersion $SolutionVersion }) }
    # An entry whose version does not parse as System.Version (a component above Int32) is skipped, never a terminating error.
    $parsed = [version]::new(0, 0)
    $pool = @($pool | Where-Object { [version]::TryParse([string]$_.Version, [ref]$parsed) })
    if ($pool.Count -eq 0) { return $null }
    return ($pool | Sort-Object -Property @{ Expression = { [version]$_.Version }; Descending = $true } | Select-Object -First 1)
}

function ConvertTo-ZtpSbeDeploymentParameter {
    <#
    .SYNOPSIS
    The SBE values of the Azure Local deployment (portal / ARM template parameters sbeVersion, sbeFamily, sbePublisher,
    sbeManifestSource, sbeManifestCreationDate) for a selected SBE.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Update, [Parameter(Mandatory)][string]$ManifestUrl)
    return [ordered]@{
        sbeVersion              = $Update.Version
        sbeFamily               = $Update.Family
        sbePublisher            = $Update.Publisher
        sbeManifestSource       = $ManifestUrl
        sbeManifestCreationDate = $Update.ManifestCreationDate
    }
}
