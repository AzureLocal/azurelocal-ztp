#Requires -Version 7.0
<#
.SYNOPSIS
Shared helpers for resolving, downloading and verifying the Azure Local maintenance (bootstrap) environment download
(dot-sourced by Get-ZtpBootstrapIso.ps1).
.DESCRIPTION
Microsoft publishes the maintenance environment as https://aka.ms/aep/installeros/<YYMM>. A published month answers with a
301 to a blob on download.prss.microsoft.com; an unpublished month answers with a 302 to a search page. The blob is either a
zip (usb_prep.exe, provision-os.iso, readme.txt) or, for older trains, provision-os.iso itself. Microsoft publishes no hash
for it, so integrity is trust-on-first-use: the SHA256 of the first good download is recorded in a manifest and checked
on every reuse (see docs/bootstrap-media-and-sbe.md for what that does and does not protect against).
Everything that touches the network goes through Invoke-ZtpHttp (ZtpHttp.Transport.ps1: one seam; the tests mock it). No secrets are involved.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ZtpBootstrapShortUrl { [CmdletBinding()][OutputType([string])] param() return 'https://aka.ms/aep/installeros' }
# A published short link must land on a Microsoft download host; anything else (the search-page redirect of an unpublished
# month) is "not published".
# Exact Microsoft download hosts only (the observed host is azurestackreleases.download.prss.microsoft.com). Storage and CDN domains such as
# blob.core.windows.net or azureedge.net are NOT allowed: any tenant can host content there.
function Get-ZtpBootstrapAllowedHostPattern { [CmdletBinding()][OutputType([string])] param() return '^([A-Za-z0-9-]+\.)*download\.prss\.microsoft\.com$|^download\.microsoft\.com$' }

function Assert-ZtpBootstrapHost {
    # Throws when a URL is not https on an allowed Microsoft download host (checked on the probe target and on the final URL after redirects).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url, [string]$What = 'download')
    $u = [uri]$Url
    if (-not $u.IsAbsoluteUri -or $u.Scheme -ne 'https' -or $u.Host -notmatch (Get-ZtpBootstrapAllowedHostPattern)) { throw "Refusing the $What URL: not https on a Microsoft download host ($($u.Host))." }
}

function Get-ZtpBootstrapTrainList {
    <#
    .SYNOPSIS
    The YYMM trains to probe: every calendar month from -MonthsBack months before -Now up to the current month. With
    -IncludePreview also the non-calendar months 13..99 of the current year (preview builds are opt-in).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([datetime]$Now = [datetime]::UtcNow, [ValidateRange(1, 120)][int]$MonthsBack = 24, [switch]$IncludePreview)
    $trains = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $MonthsBack; $i++) {
        $d = $Now.AddMonths(-$i)
        $trains.Add(('{0:yy}{0:MM}' -f $d))
    }
    if ($IncludePreview) { foreach ($m in 13..99) { $trains.Add(('{0:yy}{1:00}' -f $Now, $m)) } }
    return , $trains.ToArray()
}

function Get-ZtpBootstrapBuildFromUrl {
    <#
    .SYNOPSIS
    Version and kind of a download URL: roe-10.2610.0.3061.zip -> 10.2610.0.3061 / Zip; .../10.2507.0.3021/provision-os.iso
    -> 10.2507.0.3021 / Iso. Returns $null when the name matches neither.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)
    if ($Url -match '/roe-(\d+\.\d{4}\.\d+\.\d+)\.zip(\?|$)') { return [pscustomobject]@{ Version = $Matches[1]; Kind = 'Zip'; FileName = "roe-$($Matches[1]).zip" } }
    if ($Url -match '/(\d+\.\d{4}\.\d+\.\d+)/([^/?]+\.iso)(\?|$)') { return [pscustomobject]@{ Version = $Matches[1]; Kind = 'Iso'; FileName = $Matches[2] } }
    return $null
}

function Test-ZtpBootstrapTrain {
    <#
    .SYNOPSIS
    Probes one train: HEAD of the short link without redirects, then HEAD of the blob it points at. Returns a candidate
    object (Published true/false). A published train has Version, Kind, BlobUrl, Length, ETag, LastModified.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^\d{4}$')][string]$Train, [string]$ShortUrlBase = (Get-ZtpBootstrapShortUrl))
    $shortUrl = "$ShortUrlBase/$Train"
    $row = [ordered]@{ Train = $Train; ShortUrl = $shortUrl; Published = $false; Version = $null; Kind = $null; BlobUrl = $null; Length = [long]0; ETag = $null; LastModified = $null; Reason = $null }
    $head = Invoke-ZtpHttp -Uri $shortUrl -Method Head
    if ($head.StatusCode -notin 301, 302, 303, 307, 308 -or -not $head.Location) { $row.Reason = "short link answered HTTP $($head.StatusCode) without a redirect"; return [pscustomobject]$row }
    $target = [uri]$head.Location
    if (-not $target.IsAbsoluteUri -or $target.Scheme -ne 'https' -or $target.Host -notmatch (Get-ZtpBootstrapAllowedHostPattern)) {
        $row.Reason = "short link redirects to $($target.Host), not a Microsoft download host (train not published)"
        return [pscustomobject]$row
    }
    $build = Get-ZtpBootstrapBuildFromUrl -Url $head.Location
    if (-not $build) { $row.Reason = 'the redirect target is not a recognised maintenance download name'; return [pscustomobject]$row }
    $blob = Invoke-ZtpHttp -Uri $head.Location -Method Head -FollowRedirect
    if ($blob.StatusCode -ne 200) { $row.Reason = "the download answered HTTP $($blob.StatusCode)"; return [pscustomobject]$row }
    if ($blob.PSObject.Properties['FinalUri'] -and $blob.FinalUri) { try { Assert-ZtpBootstrapHost -Url $blob.FinalUri -What 'redirected download' } catch { $row.Reason = $_.Exception.Message; return [pscustomobject]$row } }
    $length = [long]0
    if (-not $blob.Headers.ContainsKey('Content-Length') -or -not [long]::TryParse($blob.Headers['Content-Length'], [ref]$length) -or $length -le 0) {
        $row.Reason = 'the download reports no Content-Length'; return [pscustomobject]$row
    }
    $row.Published = $true; $row.Version = $build.Version; $row.Kind = $build.Kind; $row.BlobUrl = $head.Location; $row.Length = $length
    $row.ETag = if ($blob.Headers.ContainsKey('ETag')) { $blob.Headers['ETag'].Trim('"') } else { $null }
    $row.LastModified = if ($blob.Headers.ContainsKey('Last-Modified')) { $blob.Headers['Last-Modified'] } else { $null }
    return [pscustomobject]$row
}

function Select-ZtpBootstrapLatest {
    <#
    .SYNOPSIS
    The newest eligible published candidate, or $null. Pure; the only place that decides "latest".
    .DESCRIPTION
    Never the highest string. A train YYMM is general availability only when its month is 01..12 AND it is not later than
    the current calendar month. A month above 12 is a preview train (eligible only with -IncludePreview). A calendar train
    in the future is never eligible. -MaxTrain caps the train (to stay on the train of a given solution release). Highest
    train wins, then the highest [version] build. The result is a copy with a Channel property (GA or Preview).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates,
        [datetime]$Now = [datetime]::UtcNow,
        [switch]$IncludePreview,
        [ValidatePattern('^\d{4}$')][string]$MaxTrain
    )
    $current = [int]('{0:yy}{0:MM}' -f $Now)
    $eligible = foreach ($c in $Candidates) {
        if (-not $c.Published) { continue }
        $train = [int]$c.Train
        $month = $train % 100
        if ($MaxTrain -and $train -gt [int]$MaxTrain) { continue }
        if ($month -ge 1 -and $month -le 12) {
            if ($train -gt $current) { continue }
            $channel = 'GA'
        }
        else {
            if (-not $IncludePreview) { continue }
            $channel = 'Preview'
        }
        $copy = $c.PSObject.Copy()
        $copy | Add-Member -NotePropertyName Channel -NotePropertyValue $channel -Force
        $copy
    }
    $eligible = @($eligible)
    if ($eligible.Count -eq 0) { return $null }
    return ($eligible | Sort-Object -Property @{ Expression = { [int]$_.Train }; Descending = $true }, @{ Expression = { [version]$_.Version }; Descending = $true } | Select-Object -First 1)
}

function Resolve-ZtpBootstrapBuild {
    <#
    .SYNOPSIS
    Resolves "latest" (probe the trains, apply Select-ZtpBootstrapLatest), a train (2610), a build (10.2610.0.3061 as the
    train's published build), or a direct https URL on a Microsoft download host, to one candidate object.
    #>
    [CmdletBinding()]
    param([string]$Version = 'latest', [datetime]$Now = [datetime]::UtcNow, [switch]$IncludePreview, [string]$MaxTrain, [ValidateRange(1, 120)][int]$MonthsBack = 24)
    if ($Version -match '^https://') {
        $uri = [uri]$Version
        if ($uri.Host -notmatch (Get-ZtpBootstrapAllowedHostPattern)) { throw "Refusing a download URL outside the Microsoft download hosts: $($uri.Host)" }
        $build = Get-ZtpBootstrapBuildFromUrl -Url $Version
        if (-not $build) { throw "Not a recognised maintenance download name: $Version" }
        $blob = Invoke-ZtpHttp -Uri $Version -Method Head -FollowRedirect
        if ($blob.StatusCode -ne 200) { throw "HEAD $Version answered HTTP $($blob.StatusCode)." }
        if ($blob.PSObject.Properties['FinalUri'] -and $blob.FinalUri) { Assert-ZtpBootstrapHost -Url $blob.FinalUri -What 'redirected download' }
        $train = ($build.Version.Split('.')[1])
        return [pscustomobject]@{ Train = $train; ShortUrl = $null; Published = $true; Version = $build.Version; Kind = $build.Kind; BlobUrl = $Version; Length = [long]$blob.Headers['Content-Length']
            ETag = $(if ($blob.Headers.ContainsKey('ETag')) { $blob.Headers['ETag'].Trim('"') } else { $null }); LastModified = $(if ($blob.Headers.ContainsKey('Last-Modified')) { $blob.Headers['Last-Modified'] } else { $null }); Reason = $null; Channel = 'Pinned' }
    }
    if ($Version -match '^\d{4}$' -or $Version -match '^\d+\.(\d{4})\.\d+\.\d+$') {
        $train = if ($Version -match '^\d{4}$') { $Version } else { $Matches[1] }
        $candidate = Test-ZtpBootstrapTrain -Train $train
        if (-not $candidate.Published) { throw "Train $train is not published at $($candidate.ShortUrl): $($candidate.Reason)" }
        if ($Version -match '\.' -and $candidate.Version -ne $Version) { throw "Train $train currently publishes $($candidate.Version), not the requested $Version. Pass the build URL to pin an exact build." }
        $month = [int]$train % 100
        $candidate | Add-Member -NotePropertyName Channel -NotePropertyValue $(if ($month -lt 1 -or $month -gt 12) { 'Preview' } else { 'GA' }) -Force
        return $candidate
    }
    if ($Version -ne 'latest') { throw "-Version must be latest, a train (2610), a build (10.2610.0.3061) or an https download URL; got '$Version'." }
    $trains = Get-ZtpBootstrapTrainList -Now $Now -MonthsBack $MonthsBack -IncludePreview:$IncludePreview
    $found = foreach ($t in $trains) { Test-ZtpBootstrapTrain -Train $t }
    $params = @{ Candidates = @($found); Now = $Now; IncludePreview = $IncludePreview }
    if ($MaxTrain) { $params.MaxTrain = $MaxTrain }
    $best = Select-ZtpBootstrapLatest @params
    if (-not $best) { throw "No published maintenance download in the last $MonthsBack months$(if ($MaxTrain) { " up to train $MaxTrain" }) at (Get-ZtpBootstrapShortUrl)/<YYMM>." }
    return $best
}

function Get-ZtpRemoteZipEntry {
    <#
    .SYNOPSIS
    Lists the entries of a remote zip by reading only its central directory (HTTP Range on the last bytes). Returns objects
    with Name, Length, CompressedLength, Method. $null when the zip needs Zip64 or the directory is outside the tail.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][long]$TotalLength, [ValidateRange(1024, 4MB)][int]$TailBytes = 262144)
    $from = [math]::Max(0, $TotalLength - $TailBytes)
    $response = Invoke-ZtpHttp -Uri $Url -Method Get -RangeFrom $from -AsStream -FollowRedirect
    if ($response.StatusCode -notin 200, 206) { throw "Range GET answered HTTP $($response.StatusCode)." }
    try {
        $buffer = [System.IO.MemoryStream]::new()
        $response.Stream.CopyTo($buffer)
        return (Read-ZtpZipDirectory -Bytes $buffer.ToArray())
    }
    finally {
        if ($response.Stream) { $response.Stream.Dispose() }
        if ($response.Disposable) { $response.Disposable.Response.Dispose(); $response.Disposable.Client.Dispose() }
    }
}

function Read-ZtpZipDirectory {
    <#
    .SYNOPSIS
    Parses the central directory from the tail bytes of a zip file (pure).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $eocd = -1
    for ($i = $Bytes.Length - 22; $i -ge 0; $i--) {
        if ($Bytes[$i] -eq 0x50 -and $Bytes[$i + 1] -eq 0x4B -and $Bytes[$i + 2] -eq 5 -and $Bytes[$i + 3] -eq 6) { $eocd = $i; break }
    }
    if ($eocd -lt 0) { return $null }
    $count = [BitConverter]::ToUInt16($Bytes, $eocd + 10)
    $size = [BitConverter]::ToUInt32($Bytes, $eocd + 12)
    if ($count -eq 0xFFFF -or $size -eq [uint32]::MaxValue) { return $null }
    $pos = $eocd - [int]$size
    if ($pos -lt 0) { return $null }
    $entries = [System.Collections.Generic.List[object]]::new()
    while ($pos + 46 -le $eocd -and $Bytes[$pos] -eq 0x50 -and $Bytes[$pos + 1] -eq 0x4B -and $Bytes[$pos + 2] -eq 1 -and $Bytes[$pos + 3] -eq 2) {
        $nameLength = [BitConverter]::ToUInt16($Bytes, $pos + 28)
        $extraLength = [BitConverter]::ToUInt16($Bytes, $pos + 30)
        $commentLength = [BitConverter]::ToUInt16($Bytes, $pos + 32)
        $entries.Add([pscustomobject]@{
                Name             = [System.Text.Encoding]::UTF8.GetString($Bytes, $pos + 46, $nameLength)
                Method           = [int][BitConverter]::ToUInt16($Bytes, $pos + 10)
                CompressedLength = [long][BitConverter]::ToUInt32($Bytes, $pos + 20)
                Length           = [long][BitConverter]::ToUInt32($Bytes, $pos + 24)
            })
        $pos += 46 + $nameLength + $extraLength + $commentLength
    }
    return , $entries.ToArray()
}

function Get-ZtpFreeSpace {
    # Free bytes on the volume that holds -Path (seam for the tests).
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    return [long][System.IO.DriveInfo]::new($root).AvailableFreeSpace
}

function Save-ZtpHttpFile {
    <#
    .SYNOPSIS
    Downloads -Url to -Path with resume: bytes already in "<Path>.partial" are kept and the request continues with a Range
    header (a server that answers 200 instead of 206 restarts the file). Reports progress. The file is renamed to -Path
    only when its length equals -ExpectedLength.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$ExpectedLength,
        [string]$ETag,
        [ValidateRange(1, 10)][int]$MaxAttempts = 5,
        [ValidateRange(64KB, 64MB)][int]$BufferBytes = 4MB
    )
    $partial = "$Path.partial"
    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $have = if (Test-Path -LiteralPath $partial) { (Get-Item -LiteralPath $partial).Length } else { [long]0 }
        if ($have -gt $ExpectedLength) { Remove-Item -LiteralPath $partial -Force; $have = 0 }
        if ($have -eq $ExpectedLength) { break }
        $response = $null
        try {
            $conditional = @{}
            if ($ETag -and $have -gt 0) { $conditional.IfRange = '"' + $ETag.Trim('"') + '"' }
            $response = Invoke-ZtpHttp -Uri $Url -Method Get -RangeFrom $(if ($have -gt 0) { $have } else { -1 }) -AsStream -FollowRedirect -TimeoutSeconds 3600 @conditional
            if ($response.PSObject.Properties['FinalUri'] -and $response.FinalUri) { Assert-ZtpBootstrapHost -Url $response.FinalUri -What 'redirected download' }
            if ($ETag -and $response.Headers.ContainsKey('ETag') -and $response.Headers['ETag'].Trim('"') -ne $ETag.Trim('"')) {
                if (Test-Path -LiteralPath $partial) { [System.IO.File]::Delete($partial) }
                throw "The published file changed while downloading (ETag $($response.Headers['ETag']) instead of $ETag). The partial file was deleted; run again to resolve the newest build."
            }
            if ($response.StatusCode -eq 416) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue; continue }
            if ($response.StatusCode -notin 200, 206) { throw "GET answered HTTP $($response.StatusCode)." }
            # If-Range: a server whose file changed answers 200 with the new body, which restarts the file (never two builds in one file).
            $append = ($response.StatusCode -eq 206 -and $have -gt 0)
            if (-not $append -and $have -gt 0) { Write-Verbose 'The server ignored the Range header; restarting the file.' }
            $mode = if ($append) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
            $out = [System.IO.File]::Open($partial, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $buffer = [byte[]]::new($BufferBytes)
                $written = if ($append) { $have } else { [long]0 }
                $lastReport = [datetime]::UtcNow
                while (($read = $response.Stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $out.Write($buffer, 0, $read)
                    $written += $read
                    if (([datetime]::UtcNow - $lastReport).TotalSeconds -ge 2) {
                        Write-Progress -Activity "Downloading $(Split-Path -Leaf $Path)" -Status ('{0:N0} of {1:N0} MB' -f ($written / 1MB), ($ExpectedLength / 1MB)) -PercentComplete ([int](100 * $written / $ExpectedLength))
                        $lastReport = [datetime]::UtcNow
                    }
                }
            }
            finally { $out.Dispose() }
        }
        catch {
            Write-Warning "Download attempt $attempt of $MaxAttempts stopped: $($_.Exception.Message)"
            if ($attempt -ge $MaxAttempts) { throw }
            Start-Sleep -Seconds ([math]::Min(30, 2 * $attempt))
        }
        finally {
            if ($response -and $response.Stream) { $response.Stream.Dispose() }
            if ($response -and $response.Disposable) { $response.Disposable.Response.Dispose(); $response.Disposable.Client.Dispose() }
            Write-Progress -Activity "Downloading $(Split-Path -Leaf $Path)" -Completed
        }
    }
    $final = if (Test-Path -LiteralPath $partial) { (Get-Item -LiteralPath $partial).Length } else { [long]-1 }
    if ($final -ne $ExpectedLength) { throw "Download incomplete: $final of $ExpectedLength bytes in $partial. Run again to resume." }
    Move-Item -LiteralPath $partial -Destination $Path -Force
    return (Get-Item -LiteralPath $Path)
}

function Test-ZtpIso9660 {
    # True when the file carries the ISO 9660 primary volume descriptor ("CD001" at 0x8001).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -lt 0x8006) { return $false }
        $null = $stream.Seek(0x8001, [System.IO.SeekOrigin]::Begin)
        $bytes = [byte[]]::new(5)
        $null = $stream.Read($bytes, 0, 5)
        return ([System.Text.Encoding]::ASCII.GetString($bytes) -eq 'CD001')
    }
    finally { $stream.Dispose() }
}

function Expand-ZtpZipEntry {
    # Extracts one entry of a local zip to -Destination (streamed; refuses names that are not the plain file name).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)][string]$EntryName, [Parameter(Mandatory)][string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = @($zip.Entries | Where-Object { $_.FullName -eq $EntryName }) | Select-Object -First 1
        if (-not $entry) { throw "The archive has no $EntryName. Entries: $(($zip.Entries | ForEach-Object FullName) -join ', ')" }
        if ($entry.Length -gt 16GB) { throw "$EntryName is $([math]::Round($entry.Length / 1GB)) GB uncompressed; refusing (limit 16 GB)." }
        $folder = Split-Path -Parent $Destination
        if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
        $in = $entry.Open()
        try {
            $out = [System.IO.File]::Create("$Destination.partial")
            try { $in.CopyTo($out, 4MB) } finally { $out.Dispose() }
        }
        finally { $in.Dispose() }
        if ((Get-Item -LiteralPath "$Destination.partial").Length -ne $entry.Length) { throw "Extracted size of $EntryName differs from the archive directory." }
        Move-Item -LiteralPath "$Destination.partial" -Destination $Destination -Force
    }
    finally { $zip.Dispose() }
    return (Get-Item -LiteralPath $Destination)
}

function Get-ZtpFileSha256 {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Test-ZtpMediaImage {
    <#
    .SYNOPSIS
    Read-only structural check of a per-node virtual USB image built from the maintenance ISO: GPT protective MBR and header,
    one FAT32 volume labelled CDROM, and the files the maintenance environment boots from (EFI boot loader, kernel, live
    root file system). Returns { Path, Size, Gpt, Label, Missing, Valid }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string[]]$RequiredFile = @('/efi/boot/bootx64.efi', '/boot/grub2/grub.cfg', '/liveos/rootfs.img'))
    $item = Get-Item -LiteralPath $Path
    $head = [byte[]]::new(1024)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try { $null = $stream.Read($head, 0, 1024) } finally { $stream.Dispose() }
    $gpt = ($head[510] -eq 0x55 -and $head[511] -eq 0xAA -and $head[450] -eq 0xEE -and [System.Text.Encoding]::ASCII.GetString($head, 512, 8) -eq 'EFI PART')
    $volume = Open-ZtpFat32Volume -Path $Path -AllowOpen
    try {
        $tree = @(Get-ZtpFat32Tree -Volume $volume)
        $label = $volume.Label
    }
    finally { Close-ZtpFat32Volume -Volume $volume }
    $paths = @($tree | ForEach-Object { $_.Path.ToLowerInvariant() })
    $missing = @($RequiredFile | Where-Object { $_.ToLowerInvariant() -notin $paths })
    return [pscustomobject]@{ Path = $Path; Size = $item.Length; Gpt = $gpt; Label = $label; Missing = $missing; Valid = ($gpt -and $label -eq 'CDROM' -and $missing.Count -eq 0) }
}
