#Requires -Version 7.0
<#
.SYNOPSIS
Finds the newest Solution Builder Extension (SBE) of an OEM for a model and solution version, and stages it for
deployment or update. Plan by default.
.DESCRIPTION
Reads the OEM definition config/oem/<Oem>.json, downloads the OEM's SBE discovery manifest (the XML Microsoft's update
service queries, for Dell https://aka.ms/AzureStackSBEUpdate/DellEMC), and selects the newest SBE that supports -Model (or
-Family) and was validated with -SolutionVersion (RequiredPackages patterns and MinVersionRequired). It returns the SBE
identity, the SHA256 and size the OEM published, and the SBE values of the Azure Local deployment (sbeVersion, sbeFamily,
sbePublisher, sbeManifestSource, sbeManifestCreationDate).
Where the SBE belongs: NOT on the maintenance media. The maintenance ISO has no SBE slot. The SBE is used (1) at cluster
deployment, where the portal or the ARM template takes the SBE values above and the SBE download connector fetches the
package with the OEM's credentials, and (2) at update time, where a package that the connector cannot fetch
("AdditionalContentRequired") is imported from a share together with SBE_Discovery_<oem>.xml, SBE_<oem>_<family>_<version>.xml
and .zip. This script stages that set.
The Dell, Lenovo and HPE manifests carry NO package URI (File Type DownloadConnector or Notify, Uri empty): the package comes from
the OEM's support site or connector. So -Execute writes the selection to <CacheDirectory>/sbe/<oem>/<version>/sbe-manifest.json
and, when you pass -PackagePath (the .zip you downloaded from the OEM), verifies its SHA256 against the published hash before
copying it into the staging folder. If an OEM ever publishes a URI, -Execute downloads it and verifies the same hash.
.PARAMETER Oem
OEM definition name (a file in config/oem): Dell, Lenovo, HPE, Supermicro.
.PARAMETER SolutionVersion
latest (newest SBE, compatibility not checked) or the solution version the SBE must be validated with, for example 12.2609.1003.7
(or 12.2609).
.PARAMETER Model
Hardware model as the manifest lists it (for example AX760, AX650). Without -Model and -Family the newest SBE of every family is returned.
.PARAMETER Family
SBE family (for example 16G-45n0c-Intel).
.PARAMETER CacheDirectory
Staging root; the SBE goes to <CacheDirectory>/sbe/<oem>/<version>/.
.PARAMETER ManifestPath
Use this local discovery manifest instead of downloading it (offline use, tests).
.PARAMETER PackagePath
The SBE .zip obtained from the OEM; its SHA256 must equal the published one.
.PARAMETER MetadataPath
Optional SBE_<oem>_<family>_<version>.xml obtained with the package; copied into the staging folder.
.PARAMETER Execute
Write the staging folder (and download or copy the package). Without it nothing is written.
.EXAMPLE
./Get-ZtpSbe.ps1 -Oem Dell -Model AX760 -SolutionVersion 12.2609.1003.7
.EXAMPLE
./Get-ZtpSbe.ps1 -Oem Dell -Model AX760 -SolutionVersion latest -CacheDirectory D:\ZtpDownloads -PackagePath D:\Downloads\SBE_Dell_16G-45n0c-Intel_5.0.2606.1616.zip -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,40}$')][string]$Oem,
    [string]$SolutionVersion = 'latest',
    [string]$Model,
    [string]$Family,
    [string]$CacheDirectory,
    [string]$ManifestPath,
    [string]$PackagePath,
    [string]$MetadataPath,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Get-Command Invoke-ZtpHttp -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ZtpHttp.Transport.ps1') }
if (-not (Get-Command Get-ZtpBootstrapTrainList -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ZtpBootstrap.Common.ps1') }
if (-not (Get-Command Select-ZtpSbeUpdate -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ZtpSbe.Common.ps1') }
if (-not (Get-Command Write-ZtpLog -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ZtpAzure.Common.ps1') }

if ($SolutionVersion -ne 'latest' -and $SolutionVersion -notmatch '^\d+(\.\d+){1,3}$') { throw "-SolutionVersion must be latest or a version such as 12.2609.1003.7; got '$SolutionVersion'." }
if (($PackagePath -or $MetadataPath) -and -not ($Model -or $Family)) { throw '-PackagePath needs -Model or -Family so that exactly one SBE is selected.' }
if ($Execute -and -not $CacheDirectory) { throw '-Execute needs -CacheDirectory.' }
$config = Get-ZtpOemConfig -Oem $Oem
if (-not $config.sbe.discoveryManifestUrl -and -not $ManifestPath) {
    Write-ZtpLog "$($config.oem): $($config.sbe.note)" -Level Warning
    return $null
}

$manifestSource = if ($ManifestPath) { $ManifestPath } else { [string]$config.sbe.discoveryManifestUrl }
if ($ManifestPath) { $text = Get-Content -LiteralPath $ManifestPath -Raw }
else {
    $response = Invoke-ZtpHttp -Uri $manifestSource -Method Get -FollowRedirect
    if ($response.StatusCode -ne 200 -or [string]::IsNullOrWhiteSpace($response.Text)) { throw "The SBE discovery manifest $manifestSource answered HTTP $($response.StatusCode)." }
    $text = $response.Text
}
$updates = @(Read-ZtpSbeManifest -Text $text)
if ($updates.Count -eq 0) { throw "The manifest $manifestSource lists no SBE." }

$families = if ($Model -or $Family) { @('') } else { @($updates | ForEach-Object Family | Select-Object -Unique) }
$rows = foreach ($f in $families) {
    $pick = @{ Updates = $updates; SolutionVersion = $SolutionVersion }
    if ($Model) { $pick.Model = $Model }
    $familyFilter = if ($f) { $f } elseif ($Family) { $Family } else { $null }
    if ($familyFilter) { $pick.Family = $familyFilter }
    $update = Select-ZtpSbeUpdate @pick
    if (-not $update) { continue }
    $deployment = ConvertTo-ZtpSbeDeploymentParameter -Update $update -ManifestUrl $manifestSource
    $folder = if ($CacheDirectory) { Join-Path (Join-Path (Join-Path $CacheDirectory 'sbe') $config.oem.ToLowerInvariant()) $update.Version } else { $null }
    [pscustomobject]@{
        Oem                  = $config.oem
        Publisher            = $update.Publisher
        Version              = $update.Version
        Family               = $update.Family
        SupportedModels      = $update.SupportedModels
        SolutionVersion      = $SolutionVersion
        CompatibilityChecked = ($SolutionVersion -ne 'latest')
        PackageSha256        = $update.PackageHash
        PackageSizeInMb      = $update.PackageSizeInMb
        PackageFileName      = $update.PackageFileName
        MetadataFileName     = $update.MetadataFileName
        DownloadType         = $update.DownloadType
        DownloadUri          = $update.DownloadUri
        ConnectorRequired    = (-not $update.DownloadUri)
        ReleaseNotesUri      = $update.ReleaseNotesUri
        NotifyMessage        = $update.NotifyMessage
        ManifestSource       = $manifestSource
        ManifestCreationDate = $update.ManifestCreationDate
        DeploymentParameters = $deployment
        StagingFolder        = $folder
        Staged               = $false
        PackageStaged        = $false
        Status               = $(if ($update.DownloadUri) { 'DownloadableFromManifest' } else { 'ManualOrConnector' })
    }
}
$rows = @($rows)
if ($rows.Count -eq 0) {
    throw "No $($config.oem) SBE$(if ($Model) { " for model $Model" })$(if ($Family) { " in family $Family" }) is validated with solution $SolutionVersion in $manifestSource. Try -SolutionVersion latest to see the newest SBE anyway."
}

foreach ($row in $rows) {
    Write-ZtpLog "$($row.Oem) SBE $($row.Version) (family $($row.Family); $($row.SupportedModels -join ', ')); SHA256 $($row.PackageSha256), $($row.PackageSizeInMb) MB; $($row.Status)$(if (-not $row.CompatibilityChecked) { '; solution compatibility NOT checked' })."
}
if (-not $Execute) {
    foreach ($row in $rows) {
        if ($row.ConnectorRequired) { Write-ZtpLog "PLAN: $($row.Version) has no package URI in the manifest: obtain $($row.PackageFileName) from the OEM ($($row.ReleaseNotesUri)) and pass -PackagePath, or let the SBE download connector fetch it at deployment." }
        else { Write-ZtpLog "PLAN: download $($row.DownloadUri) and verify SHA256 $($row.PackageSha256)." }
        if ($row.StagingFolder) { Write-ZtpLog "PLAN: stage in $($row.StagingFolder) (sbe-manifest.json, the package, the discovery manifest)." }
    }
    return $rows
}

foreach ($row in $rows) {
    $null = New-Item -ItemType Directory -Path $row.StagingFolder -Force
    $manifestCopy = Join-Path $row.StagingFolder "SBE_Discovery_$($row.Oem).xml"
    Set-Content -LiteralPath $manifestCopy -Value $text -Encoding utf8NoBOM
    $packageTarget = Join-Path $row.StagingFolder $row.PackageFileName
    if ($PackagePath) {
        if (@($rows).Count -ne 1) { throw '-PackagePath needs exactly one selected SBE.' }
        $actual = Get-ZtpFileSha256 -Path $PackagePath
        if ($actual -ne $row.PackageSha256.ToUpperInvariant()) { throw "$PackagePath has SHA256 $actual; the OEM published $($row.PackageSha256) for $($row.Version). Not staged." }
        Copy-Item -LiteralPath $PackagePath -Destination $packageTarget -Force
        $row.PackageStaged = $true
    }
    elseif ($row.DownloadUri) {
        $head = Invoke-ZtpHttp -Uri $row.DownloadUri -Method Head -FollowRedirect
        $length = [long]0
        if ($head.StatusCode -ne 200 -or -not [long]::TryParse($head.Headers['Content-Length'], [ref]$length)) { throw "HEAD $($row.DownloadUri) answered HTTP $($head.StatusCode)." }
        $null = Save-ZtpHttpFile -Url $row.DownloadUri -Path $packageTarget -ExpectedLength $length
        $actual = Get-ZtpFileSha256 -Path $packageTarget
        if ($actual -ne $row.PackageSha256.ToUpperInvariant()) { Remove-Item -LiteralPath $packageTarget -Force; throw "Downloaded $($row.PackageFileName) has SHA256 $actual; the manifest says $($row.PackageSha256). Deleted." }
        $row.PackageStaged = $true
    }
    if ($MetadataPath) { Copy-Item -LiteralPath $MetadataPath -Destination (Join-Path $row.StagingFolder $row.MetadataFileName) -Force }
    $record = [ordered]@{
        oem = $row.Oem; version = $row.Version; family = $row.Family; supportedModels = $row.SupportedModels; solutionVersion = $row.SolutionVersion
        compatibilityChecked = $row.CompatibilityChecked; packageSha256 = $row.PackageSha256; packageSizeInMb = $row.PackageSizeInMb
        packageFileName = $row.PackageFileName; packageStaged = $row.PackageStaged; connectorRequired = $row.ConnectorRequired
        releaseNotesUri = $row.ReleaseNotesUri; manifestSource = $row.ManifestSource; manifestCreationDate = $row.ManifestCreationDate
        deploymentParameters = $row.DeploymentParameters; stagedUtc = [datetime]::UtcNow.ToString('o')
        usedAt = 'cluster deployment (sbe* parameters, download connector) or update import (AdditionalContentRequired); never on the maintenance media'
    }
    $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $row.StagingFolder 'sbe-manifest.json') -Encoding utf8NoBOM
    $row.Staged = $true
    Write-ZtpLog "Staged $($row.Oem) SBE $($row.Version) in $($row.StagingFolder)$(if (-not $row.PackageStaged) { ' (no package: obtain it from the OEM or use the download connector)' })."
}
return $rows
