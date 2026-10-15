#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
# Maintenance (bootstrap) ISO resolution, download with resume, verification and the manifest: Get-ZtpBootstrapIso.ps1 and
# ZtpBootstrap.Common.ps1. The HTTP layer (Invoke-ZtpHttp) is mocked; no request leaves the machine. The media image check uses
# the repo's own image writer on a tiny synthetic tree.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The HTTP mock reports through globals.')]
param()

BeforeAll {
    $global:ztpT_scripts = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts/simplified-provisioning'
    . (Join-Path $global:ztpT_scripts 'ZtpAzure.Common.ps1')
    . (Join-Path $global:ztpT_scripts 'ZtpVirtualUsb.Common.ps1')
    . (Join-Path $global:ztpT_scripts 'ZtpHttp.Transport.ps1')
    . (Join-Path $global:ztpT_scripts 'ZtpBootstrap.Common.ps1')
    $global:ztpT_blobHost = 'https://azurestackreleases.download.prss.microsoft.com/dbazure/AzureLocal/ROE/Composition'

    function global:New-ZtpFakeHttp {
        param([int]$Status = 200, [hashtable]$Headers = @{}, [string]$Location, [byte[]]$Bytes, [string]$Text)
        $h = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($k in $Headers.Keys) { $h[$k] = [string]$Headers[$k] }
        [pscustomobject]@{ StatusCode = $Status; Headers = $h; Location = $Location; Stream = $(if ($Bytes) { [System.IO.MemoryStream]::new($Bytes) } else { $null }); Text = $Text; Disposable = $null }
    }
    # A tiny ISO 9660 look-alike (CD001 at 0x8001) inside a zip with the three entries of the real download.
    $global:ztpT_isoBytes = [byte[]]::new(0x9000)
    [System.Text.Encoding]::ASCII.GetBytes('CD001').CopyTo($global:ztpT_isoBytes, 0x8001)
    [System.Text.Encoding]::ASCII.GetBytes('maintenance-environment-test').CopyTo($global:ztpT_isoBytes, 0x100)
    $ms = [System.IO.MemoryStream]::new()
    Add-Type -AssemblyName System.IO.Compression
    $zip = [System.IO.Compression.ZipArchive]::new($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true)
    foreach ($entry in @(@('usb_prep.exe', [byte[]](1..64)), @('provision-os.iso', $global:ztpT_isoBytes), @('readme.txt', [System.Text.Encoding]::ASCII.GetBytes('readme')))) {
        $e = $zip.CreateEntry($entry[0], [System.IO.Compression.CompressionLevel]::Optimal)
        $s = $e.Open(); $s.Write($entry[1], 0, $entry[1].Length); $s.Dispose()
    }
    $zip.Dispose()
    $global:ztpT_zipBytes = $ms.ToArray()
    $global:ztpT_zipUrl = "$($global:ztpT_blobHost)/10.2610.0.3061/roe-10.2610.0.3061.zip"
    $global:ztpT_zipOld = "$($global:ztpT_blobHost)/10.2607.0.3085/roe-10.2607.0.3085.zip"
    # Which trains the fake aka.ms publishes.
    $global:ztpT_published = @{ '2610' = $global:ztpT_zipUrl; '2607' = $global:ztpT_zipOld; '2611' = "$($global:ztpT_blobHost)/10.2611.0.1/roe-10.2611.0.1.zip" }
    $global:ztpT_httpLog = [System.Collections.Generic.List[string]]::new()
    $global:ztpT_serveMode = 'normal'
}

AfterAll { Get-Variable -Scope Global -Name 'ztpT_*' -ErrorAction SilentlyContinue | Remove-Variable -Scope Global -Force -ErrorAction SilentlyContinue }

Describe 'Get-ZtpBootstrapBuildFromUrl' {
    It 'reads the version and kind from a zip or an ISO download name' {
        (Get-ZtpBootstrapBuildFromUrl -Url "$global:ztpT_blobHost/10.2610.0.3061/roe-10.2610.0.3061.zip") | ForEach-Object { $_.Version, $_.Kind } | Should -Be @('10.2610.0.3061', 'Zip')
        $iso = Get-ZtpBootstrapBuildFromUrl -Url 'https://azurestackreleases.download.prss.microsoft.com/dbazure/AzureLocal/OS-Composition-Linux/10.2507.0.3021/provision-os.iso'
        $iso.Version | Should -Be '10.2507.0.3021'; $iso.Kind | Should -Be 'Iso'
        Get-ZtpBootstrapBuildFromUrl -Url 'https://example.com/readme.html' | Should -BeNullOrEmpty
    }
}

Describe 'Get-ZtpBootstrapTrainList' {
    It 'lists the calendar months back from now and adds the non-calendar months only for preview' {
        $now = [datetime]'2026-10-15'
        $list = Get-ZtpBootstrapTrainList -Now $now -MonthsBack 14
        $list[0] | Should -Be '2610'; $list | Should -Contain '2509'; $list.Count | Should -Be 14
        $list | Should -Not -Contain '2613'
        $preview = Get-ZtpBootstrapTrainList -Now $now -MonthsBack 2 -IncludePreview
        $preview | Should -Contain '2613'; $preview | Should -Contain '2699'; $preview.Count | Should -Be (2 + 87)
    }
}

Describe 'Test-ZtpBootstrapTrain' {
    BeforeEach {
        Mock Invoke-ZtpHttp {
            if ($Uri -like 'https://aka.ms/aep/installeros/*') {
                $train = ([string]$Uri).Split('/')[-1]
                if ($global:ztpT_published.ContainsKey($train)) { return New-ZtpFakeHttp -Status 301 -Location $global:ztpT_published[$train] }
                if ($train -eq '2612') { return New-ZtpFakeHttp -Status 301 -Location 'https://evil.example.net/roe-10.2612.0.1.zip' }
                if ($train -eq '2601') { return New-ZtpFakeHttp -Status 200 }
                return New-ZtpFakeHttp -Status 302 -Location "https://www.bing.com?ref=aka&shorturl=aep/installeros/$train"
            }
            if ($Uri -like '*roe-10.2610*') { return New-ZtpFakeHttp -Status 200 -Headers @{ 'Content-Length' = 1389035592; ETag = '"0xABC"'; 'Last-Modified' = 'Mon, 12 Oct 2026 20:21:27 GMT' } }
            if ($Uri -like '*roe-10.2607*') { return New-ZtpFakeHttp -Status 200 -Headers @{ 'Content-Length' = 967000000; ETag = '"0xDEF"' } }
            if ($Uri -like '*roe-10.2611*') { return New-ZtpFakeHttp -Status 200 -Headers @{ 'Content-Length' = 5 } }
            return New-ZtpFakeHttp -Status 404
        }
    }
    It 'accepts a train that redirects to a Microsoft download blob and records length, ETag and time' {
        $c = Test-ZtpBootstrapTrain -Train '2610'
        $c.Published | Should -BeTrue; $c.Version | Should -Be '10.2610.0.3061'; $c.Kind | Should -Be 'Zip'; $c.Length | Should -Be 1389035592
        $c.ETag | Should -Be '0xABC'; $c.BlobUrl | Should -Be $global:ztpT_zipUrl; $c.LastModified | Should -Match '12 Oct 2026'
    }
    It 'does not trust tenant-hostable storage or CDN hosts, nor a redirect that ends on another host' {
        $global:ztpT_published['2603'] = 'https://someone.blob.core.windows.net/x/roe-10.2603.0.1.zip'
        $global:ztpT_published['2604'] = 'https://someone.azureedge.net/x/roe-10.2604.0.1.zip'
        (Test-ZtpBootstrapTrain -Train '2603').Published | Should -BeFalse
        (Test-ZtpBootstrapTrain -Train '2604').Published | Should -BeFalse
        $global:ztpT_published.Remove('2603'); $global:ztpT_published.Remove('2604')
        Mock Invoke-ZtpHttp {
            if ($Uri -like 'https://aka.ms/*') { return New-ZtpFakeHttp -Status 301 -Location $global:ztpT_zipUrl }
            $r = New-ZtpFakeHttp -Status 200 -Headers @{ 'Content-Length' = 5 }; $r | Add-Member -NotePropertyName FinalUri -NotePropertyValue 'https://evil.example.net/roe-10.2610.0.3061.zip'; $r
        }
        (Test-ZtpBootstrapTrain -Train '2610').Reason | Should -Match 'not https on a Microsoft download host'
    }
    It 'treats the search-page redirect, a foreign host, a missing redirect and a missing length as not published' {
        (Test-ZtpBootstrapTrain -Train '2609').Published | Should -BeFalse
        (Test-ZtpBootstrapTrain -Train '2609').Reason | Should -Match 'not a Microsoft download host'
        (Test-ZtpBootstrapTrain -Train '2612').Reason | Should -Match 'bing|evil|not a Microsoft'
        (Test-ZtpBootstrapTrain -Train '2601').Reason | Should -Match 'without a redirect'
        $global:ztpT_published['2605'] = "$global:ztpT_blobHost/10.2605.0.1/roe-10.2605.0.1.zip"
        (Test-ZtpBootstrapTrain -Train '2605').Reason | Should -Match 'HTTP 404'
        $global:ztpT_published.Remove('2605')
    }
}

Describe 'Select-ZtpBootstrapLatest' {
    BeforeAll {
        $global:ztpT_cand = {
            param($Train, $Version, [bool]$Published = $true)
            [pscustomobject]@{ Train = $Train; Version = $Version; Published = $Published }
        }
        $global:ztpT_now = [datetime]'2026-10-15'
    }
    It 'picks the newest published calendar train, never a future month and never an unpublished one' {
        $all = @((& $global:ztpT_cand '2604' '10.2604.0.3100'), (& $global:ztpT_cand '2607' '10.2607.0.3085'), (& $global:ztpT_cand '2610' '10.2610.0.3061'), (& $global:ztpT_cand '2611' '10.2611.0.1'), (& $global:ztpT_cand '2609' '10.2609.0.1' $false))
        $best = Select-ZtpBootstrapLatest -Candidates $all -Now $global:ztpT_now
        $best.Train | Should -Be '2610'; $best.Channel | Should -Be 'GA'
    }
    It 'does not compare strings: a train of an earlier year is not newer because of its text' {
        $all = @((& $global:ztpT_cand '2512' '10.2512.20.3092'), (& $global:ztpT_cand '2602' '10.2602.20.3005'))
        (Select-ZtpBootstrapLatest -Candidates $all -Now $global:ztpT_now).Train | Should -Be '2602'
    }
    It 'keeps preview trains (month above 12) out unless asked, then labels them' {
        $all = @((& $global:ztpT_cand '2610' '10.2610.0.3061'), (& $global:ztpT_cand '2613' '10.2613.0.5'))
        (Select-ZtpBootstrapLatest -Candidates $all -Now $global:ztpT_now).Train | Should -Be '2610'
        $p = Select-ZtpBootstrapLatest -Candidates $all -Now $global:ztpT_now -IncludePreview
        $p.Train | Should -Be '2613'; $p.Channel | Should -Be 'Preview'
    }
    It 'honours -MaxTrain, breaks a tie by build and returns null when nothing qualifies' {
        $all = @((& $global:ztpT_cand '2607' '10.2607.0.3085'), (& $global:ztpT_cand '2610' '10.2610.0.3061'))
        (Select-ZtpBootstrapLatest -Candidates $all -Now $global:ztpT_now -MaxTrain 2609).Train | Should -Be '2607'
        $tie = @((& $global:ztpT_cand '2610' '10.2610.0.99'), (& $global:ztpT_cand '2610' '10.2610.0.100'))
        (Select-ZtpBootstrapLatest -Candidates $tie -Now $global:ztpT_now).Version | Should -Be '10.2610.0.100'
        Select-ZtpBootstrapLatest -Candidates @() -Now $global:ztpT_now | Should -BeNullOrEmpty
        Select-ZtpBootstrapLatest -Candidates @((& $global:ztpT_cand '2611' '10.2611.0.1')) -Now $global:ztpT_now | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-ZtpBootstrapBuild' {
    BeforeEach {
        Mock Invoke-ZtpHttp {
            if ($Uri -like 'https://aka.ms/aep/installeros/*') {
                $train = ([string]$Uri).Split('/')[-1]
                if ($global:ztpT_published.ContainsKey($train)) { return New-ZtpFakeHttp -Status 301 -Location $global:ztpT_published[$train] }
                return New-ZtpFakeHttp -Status 302 -Location "https://www.bing.com?ref=aka&shorturl=aep/installeros/$train"
            }
            return New-ZtpFakeHttp -Status 200 -Headers @{ 'Content-Length' = 1000; ETag = '"0x1"' }
        }
    }
    It 'resolves latest by probing the trains and applying the calendar rule' {
        $b = Resolve-ZtpBootstrapBuild -Version latest -Now ([datetime]'2026-10-15') -MonthsBack 6
        $b.Version | Should -Be '10.2610.0.3061'
        (Resolve-ZtpBootstrapBuild -Version latest -Now ([datetime]'2026-10-15') -MonthsBack 6 -MaxTrain 2609).Version | Should -Be '10.2607.0.3085'
    }
    It 'resolves a train and an exact build, and refuses a build the train no longer publishes' {
        (Resolve-ZtpBootstrapBuild -Version 2607).Version | Should -Be '10.2607.0.3085'
        (Resolve-ZtpBootstrapBuild -Version '10.2607.0.3085').Train | Should -Be '2607'
        { Resolve-ZtpBootstrapBuild -Version '10.2607.0.1' } | Should -Throw '*currently publishes 10.2607.0.3085*'
        { Resolve-ZtpBootstrapBuild -Version 2609 } | Should -Throw '*not published*'
    }
    It 'accepts a Microsoft download URL and refuses any other host or a bad version word' {
        (Resolve-ZtpBootstrapBuild -Version $global:ztpT_zipUrl).Channel | Should -Be 'Pinned'
        { Resolve-ZtpBootstrapBuild -Version 'https://example.com/roe-10.2610.0.3061.zip' } | Should -Throw '*outside the Microsoft download hosts*'
        { Resolve-ZtpBootstrapBuild -Version 'newest' } | Should -Throw '*-Version must be latest*'
    }
    It 'fails with the probed range in the message when no train is published' {
        $saved = $global:ztpT_published; $global:ztpT_published = @{}
        try { { Resolve-ZtpBootstrapBuild -Version latest -Now ([datetime]'2026-10-15') -MonthsBack 3 } | Should -Throw '*No published maintenance download*' }
        finally { $global:ztpT_published = $saved }
    }
}

Describe 'Read-ZtpZipDirectory and Get-ZtpRemoteZipEntry' {
    It 'lists the entries from the tail of a zip, without Zip64' {
        $entries = Read-ZtpZipDirectory -Bytes $global:ztpT_zipBytes
        @($entries | ForEach-Object Name) | Should -Be @('usb_prep.exe', 'provision-os.iso', 'readme.txt')
        ($entries | Where-Object Name -EQ 'provision-os.iso').Length | Should -Be 0x9000
        Read-ZtpZipDirectory -Bytes ([byte[]](1..100)) | Should -BeNullOrEmpty
    }
    It 'reads only the tail with a Range request' {
        Mock Invoke-ZtpHttp { $global:ztpRangeFrom = $RangeFrom; New-ZtpFakeHttp -Status 206 -Bytes $global:ztpT_zipBytes[([math]::Max(0, $RangeFrom - 0))..($global:ztpT_zipBytes.Length - 1)] }
        $e = Get-ZtpRemoteZipEntry -Url $global:ztpT_zipUrl -TotalLength $global:ztpT_zipBytes.Length -TailBytes 2048
        @($e).Count | Should -Be 3
        $global:ztpRangeFrom | Should -Be ([math]::Max(0, $global:ztpT_zipBytes.Length - 2048))
        Remove-Variable ztpRangeFrom -Scope Global
    }
}

Describe 'Save-ZtpHttpFile' {
    BeforeEach {
        $global:ztpT_payload = [byte[]](0..255) * 40
        $global:ztpT_target = Join-Path $TestDrive "file-$([guid]::NewGuid().ToString('N')).bin"
        $global:ztpGets = [System.Collections.Generic.List[long]]::new()
    }
    AfterAll { Remove-Variable ztpGets -Scope Global -ErrorAction SilentlyContinue }
    It 'downloads the whole file and renames it when the length matches' {
        Mock Invoke-ZtpHttp { $global:ztpGets.Add($RangeFrom); New-ZtpFakeHttp -Status 200 -Bytes $global:ztpT_payload }
        $f = Save-ZtpHttpFile -Url $global:ztpT_zipUrl -Path $global:ztpT_target -ExpectedLength $global:ztpT_payload.Length
        $f.Length | Should -Be $global:ztpT_payload.Length
        Test-Path "$global:ztpT_target.partial" | Should -BeFalse
        $global:ztpGets | Should -Be @(-1)
    }
    It 'resumes from the partial file with a Range request (206)' {
        [System.IO.File]::WriteAllBytes("$global:ztpT_target.partial", $global:ztpT_payload[0..4999])
        Mock Invoke-ZtpHttp { $global:ztpGets.Add($RangeFrom); New-ZtpFakeHttp -Status 206 -Bytes $global:ztpT_payload[$RangeFrom..($global:ztpT_payload.Length - 1)] }
        $null = Save-ZtpHttpFile -Url $global:ztpT_zipUrl -Path $global:ztpT_target -ExpectedLength $global:ztpT_payload.Length
        $global:ztpGets | Should -Be @(5000)
        [System.IO.File]::ReadAllBytes($global:ztpT_target) | Should -Be $global:ztpT_payload
    }
    It 'restarts the file when the server ignores the Range header (200)' {
        [System.IO.File]::WriteAllBytes("$global:ztpT_target.partial", [byte[]](9, 9, 9, 9))
        Mock Invoke-ZtpHttp { New-ZtpFakeHttp -Status 200 -Bytes $global:ztpT_payload }
        $null = Save-ZtpHttpFile -Url $global:ztpT_zipUrl -Path $global:ztpT_target -ExpectedLength $global:ztpT_payload.Length
        [System.IO.File]::ReadAllBytes($global:ztpT_target) | Should -Be $global:ztpT_payload
    }
    It 'resumes with If-Range bound to the ETag and restarts when the server answers 200 with the new file' {
        [System.IO.File]::WriteAllBytes("$global:ztpT_target.partial", $global:ztpT_payload[0..999])
        Mock Invoke-ZtpHttp { $global:ztpT_ifRange = $IfRange; New-ZtpFakeHttp -Status 200 -Headers @{ ETag = '"0xAAA"' } -Bytes $global:ztpT_payload }
        $null = Save-ZtpHttpFile -Url $global:ztpT_zipUrl -Path $global:ztpT_target -ExpectedLength $global:ztpT_payload.Length -ETag '0xAAA'
        $global:ztpT_ifRange | Should -Be '"0xAAA"'
        [System.IO.File]::ReadAllBytes($global:ztpT_target) | Should -Be $global:ztpT_payload
    }
    It 'deletes the partial file and throws when the ETag changes during the download' {
        [System.IO.File]::WriteAllBytes("$global:ztpT_target.partial", $global:ztpT_payload[0..999])
        Mock Invoke-ZtpHttp { New-ZtpFakeHttp -Status 206 -Headers @{ ETag = '"0xBBB"' } -Bytes $global:ztpT_payload[1000..($global:ztpT_payload.Length - 1)] }
        { Save-ZtpHttpFile -Url $global:ztpT_zipUrl -Path $global:ztpT_target -ExpectedLength $global:ztpT_payload.Length -ETag '0xAAA' -MaxAttempts 1 } | Should -Throw '*changed while downloading*'
        Test-Path "$global:ztpT_target.partial" | Should -BeFalse
    }
    It 'keeps the partial file and throws when the stream ends early on every attempt' {
        Mock Invoke-ZtpHttp { New-ZtpFakeHttp -Status 200 -Bytes $global:ztpT_payload[0..99] }
        Mock Start-Sleep {}
        { Save-ZtpHttpFile -Url $global:ztpT_zipUrl -Path $global:ztpT_target -ExpectedLength $global:ztpT_payload.Length -MaxAttempts 2 } | Should -Throw '*incomplete*'
        Test-Path "$global:ztpT_target.partial" | Should -BeTrue
        Test-Path $global:ztpT_target | Should -BeFalse
    }
    It 'throws the HTTP status when the server refuses' {
        Mock Invoke-ZtpHttp { New-ZtpFakeHttp -Status 503 }
        Mock Start-Sleep {}
        { Save-ZtpHttpFile -Url $global:ztpT_zipUrl -Path $global:ztpT_target -ExpectedLength 10 -MaxAttempts 2 } | Should -Throw '*HTTP 503*'
    }
}

Describe 'Get-ZtpBootstrapIso.ps1' {
    BeforeEach {
        $global:ztpT_cache = Join-Path $TestDrive "cache-$([guid]::NewGuid().ToString('N'))"
        $global:ztpT_httpLog.Clear()
        Mock Get-ZtpFreeSpace { [long]100GB }
        Mock Invoke-ZtpHttp {
            $global:ztpT_httpLog.Add("$Method $Uri $RangeFrom")
            if ($Uri -like 'https://aka.ms/aep/installeros/*') {
                $train = ([string]$Uri).Split('/')[-1]
                if ($train -eq '2610') { return New-ZtpFakeHttp -Status 301 -Location $global:ztpT_zipUrl }
                return New-ZtpFakeHttp -Status 302 -Location "https://www.bing.com?ref=aka&shorturl=aep/installeros/$train"
            }
            if ($Method -eq 'Head') { return New-ZtpFakeHttp -Status 200 -Headers @{ 'Content-Length' = $global:ztpT_zipBytes.Length; ETag = '"0xAAA"'; 'Last-Modified' = 'Mon, 12 Oct 2026 20:21:27 GMT' } }
            $from = if ($RangeFrom -ge 0) { $RangeFrom } else { 0 }
            $bytes = if ($global:ztpT_serveMode -eq 'changed') { $b = $global:ztpT_zipBytes.Clone(); $b[10] = $b[10] -bxor 0xFF; $b } else { $global:ztpT_zipBytes }
            return New-ZtpFakeHttp -Status $(if ($RangeFrom -ge 0) { 206 } else { 200 }) -Bytes $bytes[$from..($bytes.Length - 1)]
        }
        $global:ztpT_run = {
            param([hashtable]$Extra = @{})
            $a = @{ CacheDirectory = $global:ztpT_cache; MonthsBack = 3; InformationAction = 'SilentlyContinue'; WarningAction = 'SilentlyContinue' }
            foreach ($k in $Extra.Keys) { $a[$k] = $Extra[$k] }
            & (Join-Path $global:ztpT_scripts 'Get-ZtpBootstrapIso.ps1') @a
        }
        $global:ztpT_serveMode = 'normal'
    }

    It 'resolves read-only by default and writes nothing' {
        $r = & $global:ztpT_run @{}
        $r.Planned | Should -BeTrue; $r.Version | Should -Be '10.2610.0.3061'; $r.ShortUrl | Should -Be 'https://aka.ms/aep/installeros/2610'
        Test-Path $global:ztpT_cache | Should -BeFalse
        @($global:ztpT_httpLog | Where-Object { $_ -like 'Get *' -and $_ -notlike '*-1' -and $_ -notlike '* *roe* 0*' }) | Should -Not -Contain 'unreachable'
    }

    It 'downloads, extracts the ISO, verifies it and writes the manifest (version, url, sha256, size, downloadedUtc)' {
        $r = & $global:ztpT_run @{ Execute = $true }
        $r.Planned | Should -BeFalse; $r.Reused | Should -BeFalse
        Test-Path $r.IsoPath | Should -BeTrue
        [System.IO.File]::ReadAllBytes($r.IsoPath) | Should -Be $global:ztpT_isoBytes
        $m = Get-Content $r.ManifestPath -Raw | ConvertFrom-Json
        $m.version | Should -Be '10.2610.0.3061'; $m.url | Should -Be $global:ztpT_zipUrl; $m.size | Should -Be $global:ztpT_zipBytes.Length
        $m.sha256 | Should -Be (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($global:ztpT_zipBytes)) -Algorithm SHA256).Hash
        $m.isoSha256 | Should -Be (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($global:ztpT_isoBytes)) -Algorithm SHA256).Hash
        [datetime]$m.downloadedUtc | Should -BeLessThan ([datetime]::UtcNow.AddMinutes(1))
        $m.etag | Should -Be '0xAAA'
        Test-Path (Join-Path (Split-Path $r.IsoPath) 'roe-10.2610.0.3061.zip') | Should -BeFalse
    }

    It 'keeps the archive with -KeepArchive' {
        $r = & $global:ztpT_run @{ Execute = $true; KeepArchive = $true }
        Test-Path (Join-Path (Split-Path $r.IsoPath) 'roe-10.2610.0.3061.zip') | Should -BeTrue
    }

    It 'reuses a verified cached ISO without downloading again' {
        $null = & $global:ztpT_run @{ Execute = $true }
        $global:ztpT_httpLog.Clear()
        $again = & $global:ztpT_run @{ Execute = $true }
        $again.Reused | Should -BeTrue
        @($global:ztpT_httpLog | Where-Object { $_ -like 'Get *roe*' }).Count | Should -Be 0
    }

    It 'refuses a cached ISO whose hash no longer matches the manifest, unless -RefreshTrust' {
        $r = & $global:ztpT_run @{ Execute = $true }
        [System.IO.File]::WriteAllBytes($r.IsoPath, [byte[]](1..50))
        { & $global:ztpT_run @{ Execute = $true } } | Should -Throw '*does not match its manifest*'
        $fixed = & $global:ztpT_run @{ Execute = $true; RefreshTrust = $true }
        $fixed.Reused | Should -BeFalse
        [System.IO.File]::ReadAllBytes($fixed.IsoPath) | Should -Be $global:ztpT_isoBytes
    }

    It 'refuses a re-download of the same version whose SHA256 changed, unless -RefreshTrust' {
        $r = & $global:ztpT_run @{ Execute = $true; KeepArchive = $true }
        Remove-Item $r.IsoPath -Force
        $global:ztpT_serveMode = 'changed'
        Remove-Item (Join-Path (Split-Path $r.IsoPath) 'roe-10.2610.0.3061.zip') -Force
        { & $global:ztpT_run @{ Execute = $true } } | Should -Throw '*was downloaded before with SHA256*'
        $ok = & $global:ztpT_run @{ Execute = $true; RefreshTrust = $true }
        $ok.Reused | Should -BeFalse
    }

    It 'refuses to start when the cache volume is too small' {
        Mock Get-ZtpFreeSpace { [long]1KB }
        { & $global:ztpT_run @{ Execute = $true } } | Should -Throw '*Not enough free space*'
    }

    It 'rejects a download that is not an ISO' {
        $bad = $global:ztpT_zipBytes.Clone()   # a zip whose ISO has no CD001 signature
        $ms = [System.IO.MemoryStream]::new(); $z = [System.IO.Compression.ZipArchive]::new($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        $e = $z.CreateEntry('provision-os.iso'); $s = $e.Open(); $s.Write([byte[]](1..100), 0, 100); $s.Dispose(); $z.Dispose()
        $global:ztpT_noIso = $ms.ToArray()
        Mock Invoke-ZtpHttp {
            if ($Uri -like 'https://aka.ms/*') { return New-ZtpFakeHttp -Status 301 -Location $global:ztpT_zipUrl }
            if ($Method -eq 'Head') { return New-ZtpFakeHttp -Status 200 -Headers @{ 'Content-Length' = $global:ztpT_noIso.Length } }
            New-ZtpFakeHttp -Status 200 -Bytes $global:ztpT_noIso
        }
        $bad | Out-Null
        { & $global:ztpT_run @{ Execute = $true } } | Should -Throw '*not an ISO 9660*'
    }
}

Describe 'Test-ZtpMediaImage' {
    BeforeAll {
        $tree = Join-Path $TestDrive 'tree'
        foreach ($d in 'efi/boot', 'boot/grub2', 'liveos', 'prov_config/download') { $null = New-Item -ItemType Directory -Path (Join-Path $tree $d) -Force }
        Set-Content (Join-Path $tree 'efi/boot/bootx64.efi') 'efi'
        Set-Content (Join-Path $tree 'boot/grub2/grub.cfg') 'grub'
        Set-Content (Join-Path $tree 'liveos/rootfs.img') 'root'
        Set-Content (Join-Path $tree 'prov_config/download/download.txt') 'x'
        $global:ztpT_okImage = Join-Path $TestDrive 'ok.img'
        $null = & (Join-Path $global:ztpT_scripts 'New-ZtpVirtualUsbImage.ps1') -SourcePath $tree -OutputPath $global:ztpT_okImage -SizeBytes 64MB -ClusterSize 512 -Execute -Confirm:$false
        Remove-Item (Join-Path $tree 'liveos/rootfs.img')
        $global:ztpT_badImage = Join-Path $TestDrive 'bad.img'
        $null = & (Join-Path $global:ztpT_scripts 'New-ZtpVirtualUsbImage.ps1') -SourcePath $tree -OutputPath $global:ztpT_badImage -SizeBytes 64MB -ClusterSize 512 -Execute -Confirm:$false
    }
    It 'accepts a GPT image with the CDROM volume and the boot files' {
        $c = Test-ZtpMediaImage -Path $global:ztpT_okImage
        $c.Valid | Should -BeTrue; $c.Gpt | Should -BeTrue; $c.Label | Should -Be 'CDROM'; $c.Missing | Should -BeNullOrEmpty
    }
    It 'reports the boot file that is missing' {
        $c = Test-ZtpMediaImage -Path $global:ztpT_badImage
        $c.Valid | Should -BeFalse; $c.Missing | Should -Contain '/liveos/rootfs.img'
    }
}
