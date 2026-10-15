#Requires -Version 7.0
<#
.SYNOPSIS
Resolves, downloads and verifies the newest Azure Local maintenance (bootstrap) ISO. Plan by default.
.DESCRIPTION
Resolve: probes https://aka.ms/aep/installeros/<YYMM> (HEAD, no redirects) for the last -MonthsBack calendar months. A published
month redirects to a blob on a Microsoft download host; an unpublished month redirects to a search page and is ignored.
"Latest" is the highest published train whose month is 01..12 and not after the current calendar month (never the highest
string); preview trains (a month above 12) count only with -IncludePreview; -MaxTrain caps the train.
Download: the blob (a zip with usb_prep.exe, provision-os.iso and readme.txt, or for older trains the ISO itself) goes to
<CacheDirectory>/bootstrap/<version>/ with resume (<file>.partial plus an HTTP Range request) and progress; then the zip
structure is checked, provision-os.iso is extracted and checked for the ISO 9660 signature.
Integrity: Microsoft publishes no hash for this download. The first good download is recorded as a trust-on-first-use
manifest (bootstrap-manifest.json: version, url, sha256, size, downloadedUtc, isoPath, isoSha256, etag, lastModified). A later
run reuses the cached ISO only when its SHA256 still equals the manifest; a re-download of the same version whose SHA256
differs from the manifest is refused unless -RefreshTrust. This detects corruption, truncation and a changed publication; it
does not detect a poisoned first download (see docs/bootstrap-media-and-sbe.md).
Without -Execute the script only resolves (read-only HEAD requests) and prints what it would download and where.
.PARAMETER Version
latest (default), a train (2610), a build (10.2610.0.3061) or an https download URL on a Microsoft download host.
.PARAMETER CacheDirectory
Cache root. The download lands in <CacheDirectory>/bootstrap/<version>/.
.PARAMETER IncludePreview
Also consider preview trains (month above 12).
.PARAMETER MaxTrain
Highest train to consider (for example 2609 to stay on the train of a given solution release).
.PARAMETER MonthsBack
How many calendar months back to probe (default 24).
.PARAMETER KeepArchive
Keep the downloaded zip after the ISO is extracted (default: delete it, the ISO and the manifest remain).
.PARAMETER RefreshTrust
Accept a changed publication: re-download and replace the recorded hash.
.PARAMETER Execute
Download and verify. Without it nothing is written.
.EXAMPLE
./Get-ZtpBootstrapIso.ps1 -CacheDirectory D:\ZtpDownloads
.EXAMPLE
(./Get-ZtpBootstrapIso.ps1 -CacheDirectory D:\ZtpDownloads -Execute).IsoPath
#>
[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [Parameter(Mandatory)][string]$CacheDirectory,
    [switch]$IncludePreview,
    [ValidatePattern('^\d{4}$')][string]$MaxTrain,
    [ValidateRange(1, 120)][int]$MonthsBack = 24,
    [switch]$KeepArchive,
    [switch]$RefreshTrust,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Get-Command Invoke-ZtpHttp -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ZtpHttp.Transport.ps1') }
if (-not (Get-Command Get-ZtpBootstrapTrainList -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ZtpBootstrap.Common.ps1') }
if (-not (Get-Command Write-ZtpLog -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ZtpAzure.Common.ps1') }

$resolveArgs = @{ Version = $Version; IncludePreview = $IncludePreview; MonthsBack = $MonthsBack }
if ($MaxTrain) { $resolveArgs.MaxTrain = $MaxTrain }
$build = Resolve-ZtpBootstrapBuild @resolveArgs
Write-ZtpLog "Resolved $($build.Version) (train $($build.Train), $($build.Channel)): $($build.BlobUrl) ($([math]::Round($build.Length / 1MB)) MB, ETag $($build.ETag), modified $($build.LastModified))."

$folder = Join-Path (Join-Path $CacheDirectory 'bootstrap') $build.Version
$archiveName = (Get-ZtpBootstrapBuildFromUrl -Url $build.BlobUrl).FileName
$archivePath = Join-Path $folder $archiveName
$isoPath = Join-Path $folder 'provision-os.iso'
if ($build.Kind -eq 'Iso') { $isoPath = $archivePath }
$manifestPath = Join-Path $folder 'bootstrap-manifest.json'
$manifest = if (Test-Path -LiteralPath $manifestPath) { Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable } else { $null }

$result = [pscustomobject]@{
    Version = $build.Version; Train = $build.Train; Channel = $build.Channel; Url = $build.BlobUrl; ShortUrl = $build.ShortUrl
    IsoPath = $isoPath; ManifestPath = $manifestPath; Sha256 = $null; IsoSha256 = $null; Size = $build.Length; Reused = $false; Planned = (-not $Execute)
}

# ---- reuse: the cached ISO must still equal the recorded hash
if ($manifest -and (Test-Path -LiteralPath $isoPath)) {
    if (-not $Execute) {
        Write-ZtpLog "PLAN: cached $($build.Version) found at $isoPath; its hash would be checked against $manifestPath and reused."
        $result.Sha256 = $manifest['sha256']; $result.IsoSha256 = $manifest['isoSha256']; $result.Reused = $true
        return $result
    }
    $actual = Get-ZtpFileSha256 -Path $isoPath
    if ($actual -eq $manifest['isoSha256']) {
        if ($manifest['etag'] -and $build.ETag -and $manifest['etag'] -ne $build.ETag) {
            Write-ZtpLog "The published file's ETag changed since the first download (recorded $($manifest['etag']), now $($build.ETag)). Keeping the cached ISO; use -RefreshTrust to download the new publication." -Level Warning
        }
        Write-ZtpLog "Reusing the verified cached ISO $isoPath."
        $result.Sha256 = $manifest['sha256']; $result.IsoSha256 = $actual; $result.Reused = $true
        return $result
    }
    if (-not $RefreshTrust) { throw "The cached ISO $isoPath does not match its manifest (recorded $($manifest['isoSha256']), actual $actual). Delete the folder or pass -RefreshTrust." }
    Write-ZtpLog 'Cached ISO differs from the manifest; -RefreshTrust given, downloading again.' -Level Warning
}

# ---- plan
$need = if ($build.Kind -eq 'Zip') { 2 * $build.Length + 256MB } else { $build.Length + 256MB }
if (-not $Execute) {
    Write-ZtpLog "PLAN: download $($build.BlobUrl) to $archivePath ($([math]::Round($build.Length / 1MB)) MB, resumable); $(if ($build.Kind -eq 'Zip') { "extract provision-os.iso to $isoPath, " })write $manifestPath."
    Write-ZtpLog "PLAN: needs about $([math]::Round($need / 1GB, 1)) GB free on the cache volume. Add -Execute to download."
    if ($build.Kind -eq 'Zip') {
        try {
            $entries = Get-ZtpRemoteZipEntry -Url $build.BlobUrl -TotalLength $build.Length
            if ($entries) { Write-ZtpLog "PLAN: the archive holds $(($entries | ForEach-Object { "$($_.Name) ($([math]::Round($_.Length / 1MB, 1)) MB)" }) -join ', ')." }
        }
        catch { Write-ZtpLog "PLAN: could not read the remote archive directory ($($_.Exception.Message))." -Level Warning }
    }
    return $result
}

# ---- execute
$null = New-Item -ItemType Directory -Path $folder -Force
$free = Get-ZtpFreeSpace -Path $folder
$havePartial = (Test-Path -LiteralPath "$archivePath.partial") ? (Get-Item -LiteralPath "$archivePath.partial").Length : 0
if ($free + $havePartial -lt $need) { throw "Not enough free space on the cache volume: $([math]::Round($free / 1GB, 1)) GB free, about $([math]::Round($need / 1GB, 1)) GB needed. Choose another -CacheDirectory." }

$null = Save-ZtpHttpFile -Url $build.BlobUrl -Path $archivePath -ExpectedLength $build.Length -ETag $build.ETag
$archiveHash = Get-ZtpFileSha256 -Path $archivePath
if ($manifest -and $manifest['sha256'] -and $manifest['sha256'] -ne $archiveHash -and -not $RefreshTrust) {
    throw "Version $($build.Version) was downloaded before with SHA256 $($manifest['sha256']); this download is $archiveHash. The publication changed or a download is damaged. Delete $folder or pass -RefreshTrust to accept it."
}
if ($build.Kind -eq 'Zip') {
    $null = Expand-ZtpZipEntry -ZipPath $archivePath -EntryName 'provision-os.iso' -Destination $isoPath
}
if (-not (Test-ZtpIso9660 -Path $isoPath)) { throw "$isoPath is not an ISO 9660 image (no CD001 signature)." }
$isoHash = if ($build.Kind -eq 'Zip') { Get-ZtpFileSha256 -Path $isoPath } else { $archiveHash }

$record = [ordered]@{
    version       = $build.Version
    train         = $build.Train
    channel       = $build.Channel
    url           = $build.BlobUrl
    shortUrl      = $build.ShortUrl
    sha256        = $archiveHash
    size          = [long](Get-Item -LiteralPath $archivePath).Length
    downloadedUtc = [datetime]::UtcNow.ToString('o')
    kind          = $build.Kind
    isoPath       = $isoPath
    isoSha256     = $isoHash
    isoSize       = [long](Get-Item -LiteralPath $isoPath).Length
    etag          = $build.ETag
    lastModified  = $build.LastModified
    trust         = 'TrustOnFirstUse: Microsoft publishes no hash for this download'
}
$record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
if ($build.Kind -eq 'Zip' -and -not $KeepArchive) { Remove-Item -LiteralPath $archivePath -Force }
Write-ZtpLog "Verified $($build.Version): ISO $isoPath, SHA256 $isoHash. Manifest $manifestPath."
$result.Sha256 = $archiveHash; $result.IsoSha256 = $isoHash; $result.Planned = $false
return $result
