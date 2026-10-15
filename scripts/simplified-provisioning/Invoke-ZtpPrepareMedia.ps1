#Requires -Version 7.0
<#
.SYNOPSIS
Prepares everything the boot stage needs, driven only by the config file: newest maintenance ISO, the OEM's SBE selection,
one verified virtual USB image per node. Plan by default.
.DESCRIPTION
  1. Get-ZtpBootstrapIso.ps1  resolve the newest maintenance ISO, download with resume, verify (TOFU manifest).
  2. Get-ZtpSbe.ps1           select the newest SBE of the OEM for the model and solution version and stage its descriptor.
                              The SBE is NOT written to the media: the maintenance ISO has no SBE slot (it is used at cluster
                              deployment and update; see docs/bootstrap-media-and-sbe.md).
  3. New-ZtpVirtualUsbImage.ps1  one raw GPT + FAT32 (CDROM) image per node from the ISO.
  4. Test-ZtpMediaImage       read-back check of every image (GPT, label, boot files).
Then it prints the plan or the result. Config keys are those of config/simplified-provisioning/ztp-provisioning.example.json
(NodesFile, BootstrapCacheDirectory, BootstrapVersion, IncludePreview, MaxBootstrapTrain, Oem, SbeModel, SbeFamily,
SbeSolutionVersion, SbePackagePath, SourcePath, ImageDirectory, ImageNamePrefix, RebuildImages); keys it does not use are ignored.
A parameter wins over the file. Without -Execute only read-only HEAD requests are made and nothing is written.
.PARAMETER ConfigPath
JSON settings file (no secrets).
.PARAMETER EdgeUserPassword
Optional password for the maintenance environment's edgeuser account (only its SHA-512 crypt hash enters the image).
.PARAMETER StageScriptRoot
Folder of the stage scripts (default: this folder). Tests point it at stubs.
.PARAMETER Execute
Download, stage and build.
.EXAMPLE
./Invoke-ZtpPrepareMedia.ps1 -ConfigPath ./ztp-provisioning.json
.EXAMPLE
./Invoke-ZtpPrepareMedia.ps1 -ConfigPath ./ztp-provisioning.json -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [securestring]$EdgeUserPassword,
    [string]$StageScriptRoot = $PSScriptRoot,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpVirtualUsb.Common.ps1')
if (-not (Get-Command Test-ZtpMediaImage -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ZtpBootstrap.Common.ps1') }
if (-not (Get-Command Write-ZtpLog -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ZtpAzure.Common.ps1') }

$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
$get = { param([string]$Key, $Default = $null) if ($cfg.ContainsKey($Key) -and $null -ne $cfg[$Key] -and "$($cfg[$Key])" -ne '') { $cfg[$Key] } else { $Default } }
$nodesFile = & $get 'NodesFile'
$imageDirectory = & $get 'ImageDirectory'
if (-not $nodesFile) { throw "NodesFile is not set in $ConfigPath." }
if (-not $imageDirectory) { throw "ImageDirectory is not set in $ConfigPath." }
$prefix = & $get 'ImageNamePrefix' 'ztp-usb-'
$nodeNames = @(& $get 'NodeName' @())
$known = @(Get-ZtpNodeList -NodesFile $nodesFile)
if ($nodeNames.Count -eq 0) { $nodeNames = @($known.Name) }
$null = Get-ZtpNodeList -NodesFile $nodesFile -NodeName $nodeNames

# ---- 1. ISO
$explicit = & $get 'SourcePath'
$cache = & $get 'BootstrapCacheDirectory'
if (-not $cache -and -not $explicit) { throw "Set BootstrapCacheDirectory (download) or SourcePath (an ISO you already have) in $ConfigPath." }
$isoPath = $explicit
$isoInfo = $null
if ($cache) {
    $isoArgs = @{ Version = (& $get 'BootstrapVersion' 'latest'); CacheDirectory = $cache }
    if (& $get 'IncludePreview' $false) { $isoArgs.IncludePreview = $true }
    if (& $get 'MaxBootstrapTrain') { $isoArgs.MaxTrain = [string](& $get 'MaxBootstrapTrain') }
    if ($Execute) { $isoArgs.Execute = $true }
    $isoInfo = & (Join-Path $StageScriptRoot 'Get-ZtpBootstrapIso.ps1') @isoArgs | Select-Object -Last 1
    if (-not $explicit) { $isoPath = $isoInfo.IsoPath }
}
Write-ZtpLog "Maintenance ISO: $isoPath$(if ($isoInfo) { " (version $($isoInfo.Version), $($isoInfo.Channel))" })."

# ---- 2. SBE (descriptor only; never on the media)
$sbeInfo = $null
$oem = & $get 'Oem'
if ($oem -and ((& $get 'SbeModel') -or (& $get 'SbeFamily'))) {
    $sbeArgs = @{ Oem = $oem; SolutionVersion = (& $get 'SbeSolutionVersion' 'latest') }
    if (& $get 'SbeModel') { $sbeArgs.Model = & $get 'SbeModel' }
    if (& $get 'SbeFamily') { $sbeArgs.Family = & $get 'SbeFamily' }
    if ($cache) { $sbeArgs.CacheDirectory = $cache }
    if (& $get 'SbePackagePath') { $sbeArgs.PackagePath = & $get 'SbePackagePath' }
    if ($Execute -and $cache) { $sbeArgs.Execute = $true }
    $sbeInfo = @(& (Join-Path $StageScriptRoot 'Get-ZtpSbe.ps1') @sbeArgs) | Where-Object { $_ -is [pscustomobject] } | Select-Object -First 1
    if ($sbeInfo) { Write-ZtpLog "SBE: $($sbeInfo.Oem) $($sbeInfo.Version) ($($sbeInfo.Status)); goes to cluster deployment or update, not onto the media." }
}
else { Write-ZtpLog 'SBE: not selected (set Oem and SbeModel or SbeFamily in the config to select one).' }

# ---- 3. images
$imageArgs = @{ SourcePath = $isoPath; NodeName = $nodeNames; OutputDirectory = $imageDirectory; ImageNamePrefix = $prefix }
if ($EdgeUserPassword) { $imageArgs.EdgeUserPassword = $EdgeUserPassword }
if (& $get 'RebuildImages' $false) { $imageArgs.Force = $true }
if ($Execute) { $imageArgs.Execute = $true }
if (-not $Execute -and -not (Test-Path -LiteralPath $isoPath)) {
    Write-ZtpLog "PLAN: the ISO is not on disk yet ($isoPath); the image plan below uses its future path." -Level Warning
    $planOnly = foreach ($n in $nodeNames) { "PLAN: build $(Join-Path $imageDirectory (Get-ZtpNodeImageName -NodeName $n -Prefix $prefix)) from $isoPath (GPT, one FAT32 partition labelled CDROM)" }
    $planOnly
    return [pscustomobject]@{ Planned = $true; IsoPath = $isoPath; Iso = $isoInfo; Sbe = $sbeInfo; Images = @() }
}
$built = @(& (Join-Path $StageScriptRoot 'New-ZtpVirtualUsbImage.ps1') @imageArgs)
if (-not $Execute) { $built | ForEach-Object { $_ }; return [pscustomobject]@{ Planned = $true; IsoPath = $isoPath; Iso = $isoInfo; Sbe = $sbeInfo; Images = @() } }

# ---- 4. verify
$rows = @($built | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['ImagePath'] })
$checks = foreach ($node in $nodeNames) {
    $row = @($rows | Where-Object Node -EQ $node)
    if ($row.Count -ne 1) { throw "No image was built for $node." }
    $check = Test-ZtpMediaImage -Path $row[0].ImagePath
    if (-not $check.Valid) { throw "Image of $node failed the read-back check: GPT=$($check.Gpt), label=$($check.Label), missing=$($check.Missing -join ', ')." }
    [pscustomobject]@{ Node = $node; ImagePath = $check.Path; SizeMB = [math]::Round($check.Size / 1MB); Label = $check.Label; Valid = $true }
}
$checks | Format-Table -AutoSize | Out-String | Write-Information -InformationAction Continue
Write-ZtpLog "Media ready: $(@($checks).Count) image(s) in $imageDirectory. Next: Start-MaintenanceBoot.ps1 (or Invoke-ZtpProvisioning.ps1 -Stage Boot)."
return [pscustomobject]@{ Planned = $false; IsoPath = $isoPath; Iso = $isoInfo; Sbe = $sbeInfo; Images = @($checks) }
