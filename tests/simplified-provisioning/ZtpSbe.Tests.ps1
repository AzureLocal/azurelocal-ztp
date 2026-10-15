#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
# OEM definitions, the SBE discovery manifest parser and selector, and Get-ZtpSbe.ps1. The manifest is a trimmed copy of the real
# Dell discovery manifest (fixtures/sbe-discovery-dell.xml); the HTTP layer is mocked.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The HTTP mock reports through globals.')]
param()

BeforeAll {
    $global:ztpS_scripts = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts/simplified-provisioning'
    $global:ztpS_root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    . (Join-Path $global:ztpS_scripts 'ZtpAzure.Common.ps1')
    . (Join-Path $global:ztpS_scripts 'ZtpHttp.Transport.ps1')
    . (Join-Path $global:ztpS_scripts 'ZtpBootstrap.Common.ps1')
    . (Join-Path $global:ztpS_scripts 'ZtpSbe.Common.ps1')
    $global:ztpS_xml = Get-Content (Join-Path $PSScriptRoot 'fixtures/sbe-discovery-dell.xml') -Raw
    $global:ztpS_updates = @(Read-ZtpSbeManifest -Text $global:ztpS_xml)
}
AfterAll { Get-Variable -Scope Global -Name 'ztpS_*' -ErrorAction SilentlyContinue | Remove-Variable -Scope Global -Force -ErrorAction SilentlyContinue }

Describe 'OEM definitions (config/oem)' {
    It 'ships Dell, Lenovo, HPE and Supermicro, each loadable and complete' {
        foreach ($oem in 'dell', 'lenovo', 'hpe', 'supermicro') {
            $c = Get-ZtpOemConfig -Oem $oem
            $c.oem | Should -Not -BeNullOrEmpty; $c.bmc.kind | Should -Not -BeNullOrEmpty
        }
        (Get-ZtpOemConfig -Oem Dell).sbe.discoveryManifestUrl | Should -Be 'https://aka.ms/AzureStackSBEUpdate/DellEMC'
        (Get-ZtpOemConfig -Oem Dell).bmc.kind | Should -Be 'idrac'
    }
    It 'names the known OEMs when one is missing and rejects a definition without the required fields' {
        { Get-ZtpOemConfig -Oem acme } | Should -Throw '*Known OEMs: dell*'
        $root = Join-Path $TestDrive 'oem'; $null = New-Item -ItemType Directory $root
        Set-Content (Join-Path $root 'broken.json') '{ "oem": "Broken" }'
        { Get-ZtpOemConfig -Oem broken -ConfigRoot $root } | Should -Throw "*lacks 'publisher'*"
        Set-Content (Join-Path $root 'plain.json') '{ "oem": "P", "publisher": "P", "sbe": { "discoveryManifestUrl": "http://insecure", "downloadMethod": "x" }, "bmc": {} }'
        { Get-ZtpOemConfig -Oem plain -ConfigRoot $root } | Should -Throw '*must be https*'
    }
    It 'contains no tenant, subscription or private address data' {
        foreach ($f in Get-ChildItem (Join-Path $global:ztpS_root 'config/oem') -Filter *.json) {
            (Get-Content $f.FullName -Raw) | Should -Not -Match '(?i)\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-(?!000000000000)[0-9a-f]{12}'
        }
    }
}

Describe 'Read-ZtpSbeManifest' {
    It 'parses one object per SBE with models, solution patterns, hash, size and the download type' {
        @($global:ztpS_updates).Count | Should -Be 6
        $u = $global:ztpS_updates | Where-Object Version -EQ '5.0.2606.1616'
        $u.Family | Should -Be '16G-45n0c-Intel'; $u.Publisher | Should -Be 'Dell'
        $u.SupportedModels | Should -Contain 'AX760'
        $u.PackageHash | Should -Match '^[0-9A-F]{64}$'; $u.PackageSizeInMb | Should -Be 916
        $u.DownloadType | Should -Be 'DownloadConnector'; $u.DownloadUri | Should -BeNullOrEmpty
        $u.PackageFileName | Should -Be 'SBE_Dell_16G-45n0c-Intel_5.0.2606.1616.zip'
        @($u.SolutionPatterns).Count | Should -Be 2
        ($u.SolutionPatterns | Where-Object Version -EQ '12.*.1002.*').MinVersionRequired | Should -Be '12.2603.1002.502'
        $u.ManifestCreationDate | Should -Be '2026-06-24T05:58:20Z'
    }
    It 'rejects text that is not a discovery manifest and DTDs' {
        { Read-ZtpSbeManifest -Text '<html/>' } | Should -Throw '*SBEUpdatesManifest*'
        { Read-ZtpSbeManifest -Text '<!DOCTYPE x [<!ENTITY a "b">]><SBEUpdatesManifest/>' } | Should -Throw
    }
}

Describe 'Test-ZtpSbeSolutionMatch' {
    It 'matches wildcard patterns and honours MinVersionRequired' {
        $p = @([pscustomobject]@{ Version = '12.*.1003.*'; MinVersionRequired = $null }, [pscustomobject]@{ Version = '12.*.1002.*'; MinVersionRequired = '12.2603.1002.502' })
        Test-ZtpSbeSolutionMatch -Patterns $p -SolutionVersion '12.2609.1003.7' | Should -BeTrue
        Test-ZtpSbeSolutionMatch -Patterns $p -SolutionVersion '12.2604.1002.600' | Should -BeTrue
        Test-ZtpSbeSolutionMatch -Patterns $p -SolutionVersion '12.2602.1002.600' | Should -BeFalse
        Test-ZtpSbeSolutionMatch -Patterns $p -SolutionVersion '12.2609.1001.5' | Should -BeFalse
        Test-ZtpSbeSolutionMatch -Patterns $p -SolutionVersion '11.2609.1003.7' | Should -BeFalse
    }
    It 'compares a partial solution version on the segments it has' {
        $p = @([pscustomobject]@{ Version = '12.*.1003.*'; MinVersionRequired = '12.2604.1003.209' })
        Test-ZtpSbeSolutionMatch -Patterns $p -SolutionVersion '12.2609' | Should -BeTrue
        Test-ZtpSbeSolutionMatch -Patterns $p -SolutionVersion '12.2603' | Should -BeFalse
    }
}

Describe 'Select-ZtpSbeUpdate' {
    It 'returns the newest SBE for a model, newest by version number not by text' {
        (Select-ZtpSbeUpdate -Updates $global:ztpS_updates -Model AX760).Version | Should -Be '5.0.2606.1616'
        (Select-ZtpSbeUpdate -Updates $global:ztpS_updates -Model AX650).Version | Should -Be '5.0.2606.1510'
        (Select-ZtpSbeUpdate -Updates $global:ztpS_updates -Model ax770).Version | Should -Be '5.0.2606.1713'
    }
    It 'skips an entry whose version cannot be parsed instead of failing' {
        $bad = [pscustomobject]@{ Version = '4.0.0.99999999999'; Family = 'X'; SupportedModels = @('AX760'); SolutionPatterns = @() }
        (Select-ZtpSbeUpdate -Updates (@($global:ztpS_updates) + $bad) -Model AX760).Version | Should -Be '5.0.2606.1616'
    }
    It 'filters by family and by the solution version the SBE was validated with' {
        (Select-ZtpSbeUpdate -Updates $global:ztpS_updates -Family 'AX-16G-45n0c' -SolutionVersion '12.2609.1003.7').Version | Should -Be '5.0.2603.1641' -Because 'its 12.*.1003.* needs at least 12.2604.1003.209, which 12.2609 satisfies'
        (Select-ZtpSbeUpdate -Updates $global:ztpS_updates -Model AX760 -SolutionVersion '12.2602.1003.1') | Should -Not -BeNullOrEmpty -Because 'the 5.0.2606 SBE has no minimum for 1003 recipes'
        Select-ZtpSbeUpdate -Updates $global:ztpS_updates -Model AX760 -SolutionVersion '10.2504.0.1' | Should -BeNullOrEmpty
        Select-ZtpSbeUpdate -Updates $global:ztpS_updates -Model NoSuchModel | Should -BeNullOrEmpty
        Select-ZtpSbeUpdate -Updates @() | Should -BeNullOrEmpty
    }
    It 'builds the deployment parameters of the portal template' {
        $u = Select-ZtpSbeUpdate -Updates $global:ztpS_updates -Model AX760
        $d = ConvertTo-ZtpSbeDeploymentParameter -Update $u -ManifestUrl 'https://aka.ms/AzureStackSBEUpdate/DellEMC'
        $d.sbeVersion | Should -Be '5.0.2606.1616'; $d.sbeFamily | Should -Be '16G-45n0c-Intel'; $d.sbePublisher | Should -Be 'Dell'
        $d.sbeManifestSource | Should -Be 'https://aka.ms/AzureStackSBEUpdate/DellEMC'; $d.sbeManifestCreationDate | Should -Be '2026-06-24T05:58:20Z'
    }
}

Describe 'Get-ZtpSbe.ps1' {
    BeforeEach {
        Mock Invoke-ZtpHttp { New-ZtpSbeFake -Status 200 -Text $global:ztpS_xml }
        function global:New-ZtpSbeFake { param([int]$Status, [string]$Text, [hashtable]$Headers = @{}, [byte[]]$Bytes)
            $h = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase); foreach ($k in $Headers.Keys) { $h[$k] = [string]$Headers[$k] }
            [pscustomobject]@{ StatusCode = $Status; Headers = $h; Location = $null; Stream = $(if ($Bytes) { [System.IO.MemoryStream]::new($Bytes) } else { $null }); Text = $Text; Disposable = $null } }
        $global:ztpS_run = { param([hashtable]$Extra) $a = @{ Oem = 'Dell'; InformationAction = 'SilentlyContinue'; WarningAction = 'SilentlyContinue' }; foreach ($k in $Extra.Keys) { $a[$k] = $Extra[$k] }; & (Join-Path $global:ztpS_scripts 'Get-ZtpSbe.ps1') @a }
    }
    AfterAll { Remove-Item Function:\global:New-ZtpSbeFake -ErrorAction SilentlyContinue }

    It 'selects the newest Dell SBE for a model and solution version from the OEM manifest, writing nothing' {
        $r = & $global:ztpS_run @{ Model = 'AX760'; SolutionVersion = '12.2609.1003.7'; CacheDirectory = (Join-Path $TestDrive 'c1') }
        $r.Version | Should -Be '5.0.2606.1616'; $r.Status | Should -Be 'ManualOrConnector'; $r.ConnectorRequired | Should -BeTrue; $r.CompatibilityChecked | Should -BeTrue
        $r.PackageSha256 | Should -Match '^[0-9A-F]{64}$'; $r.DeploymentParameters.sbePublisher | Should -Be 'Dell'
        Should -Invoke Invoke-ZtpHttp -ParameterFilter { $Uri -eq 'https://aka.ms/AzureStackSBEUpdate/DellEMC' } -Times 1
        Test-Path (Join-Path $TestDrive 'c1') | Should -BeFalse
    }
    It 'says compatibility was not checked for -SolutionVersion latest and returns one row per family without a model' {
        $one = & $global:ztpS_run @{ Model = 'AX650' }
        $one.CompatibilityChecked | Should -BeFalse
        $all = @(& $global:ztpS_run @{})
        $all.Count | Should -Be 5
        ($all | ForEach-Object Family) | Should -Contain '17G-Intel'
    }
    It 'fails with a hint when no SBE is validated with the solution version' {
        { & $global:ztpS_run @{ Model = 'AX760'; SolutionVersion = '10.2504.0.1' } } | Should -Throw '*No Dell SBE for model AX760*validated with solution 10.2504.0.1*'
    }
    It 'stages sbe-manifest.json and the discovery manifest on -Execute, and verifies a package you supply against the published hash' {
        $cache = Join-Path $TestDrive 'c2'
        $row = & $global:ztpS_run @{ Model = 'AX760'; SolutionVersion = '12.2609.1003.7'; CacheDirectory = $cache; Execute = $true }
        $row.Staged | Should -BeTrue; $row.PackageStaged | Should -BeFalse
        $m = Get-Content (Join-Path $row.StagingFolder 'sbe-manifest.json') -Raw | ConvertFrom-Json
        $m.version | Should -Be '5.0.2606.1616'; $m.connectorRequired | Should -BeTrue; $m.usedAt | Should -Match 'never on the maintenance media'
        Test-Path (Join-Path $row.StagingFolder 'SBE_Discovery_Dell.xml') | Should -BeTrue
        $bad = Join-Path $TestDrive 'SBE_wrong.zip'; Set-Content $bad 'not the package'
        { & $global:ztpS_run @{ Model = 'AX760'; SolutionVersion = '12.2609.1003.7'; CacheDirectory = $cache; PackagePath = $bad; Execute = $true } } | Should -Throw '*the OEM published*'
    }
    It 'accepts a package whose SHA256 equals the published one and copies it into the staging folder' {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes('synthetic sbe payload')
        $hash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($bytes)) -Algorithm SHA256).Hash
        $xml = $global:ztpS_xml -replace '(?s)(<ApplicableUpdate Version="5.0.2606.1616".*?<PackageHash>)[0-9A-F]{64}(</PackageHash>)', "`${1}$hash`${2}"
        $mf = Join-Path $TestDrive 'dell-test.xml'; Set-Content $mf $xml
        $pkg = Join-Path $TestDrive 'SBE_Dell_16G-45n0c-Intel_5.0.2606.1616.zip'; [System.IO.File]::WriteAllBytes($pkg, $bytes)
        $row = & $global:ztpS_run @{ Model = 'AX760'; ManifestPath = $mf; CacheDirectory = (Join-Path $TestDrive 'c3'); PackagePath = $pkg; Execute = $true }
        $row.PackageStaged | Should -BeTrue
        Test-Path (Join-Path $row.StagingFolder 'SBE_Dell_16G-45n0c-Intel_5.0.2606.1616.zip') | Should -BeTrue
        Should -Invoke Invoke-ZtpHttp -Times 0
    }
    It 'downloads and verifies a package when the manifest does carry a URI, and deletes it when the hash is wrong' {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes('payload from a vendor that publishes a uri')
        $hash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($bytes)) -Algorithm SHA256).Hash
        $uri = 'https://downloads.example.com/SBE_Dell_16G-45n0c-Intel_5.0.2606.1616.zip'
        $xml = $global:ztpS_xml -replace '(?s)(<ApplicableUpdate Version="5.0.2606.1616".*?<PackageHash>)[0-9A-F]{64}(</PackageHash>)', "`${1}$hash`${2}"
        $xml = $xml -replace '(<File Name="SBE_Dell_16G-45n0c-Intel_5.0.2606.1616.zip" Uri=)""', "`$1""$uri"""
        $mf = Join-Path $TestDrive 'dell-uri.xml'; Set-Content $mf $xml
        Mock Invoke-ZtpHttp { if ($Method -eq 'Head') { New-ZtpSbeFake -Status 200 -Headers @{ 'Content-Length' = $global:ztpS_bytes.Length } } else { New-ZtpSbeFake -Status 200 -Bytes $global:ztpS_bytes } }
        $global:ztpS_bytes = $bytes
        $row = & $global:ztpS_run @{ Model = 'AX760'; ManifestPath = $mf; CacheDirectory = (Join-Path $TestDrive 'c4'); Execute = $true }
        $row.Status | Should -Be 'DownloadableFromManifest'; $row.PackageStaged | Should -BeTrue
        $global:ztpS_bytes = [System.Text.Encoding]::ASCII.GetBytes('tampered payload!!')
        { & $global:ztpS_run @{ Model = 'AX760'; ManifestPath = $mf; CacheDirectory = (Join-Path $TestDrive 'c5'); Execute = $true } } | Should -Throw '*Deleted*'
        Test-Path (Join-Path $TestDrive 'c5/sbe/dell/5.0.2606.1616/SBE_Dell_16G-45n0c-Intel_5.0.2606.1616.zip') | Should -BeFalse
    }
    It 'reports an OEM without a discovery manifest and refuses -Execute without a cache directory' {
        (& $global:ztpS_run @{ Oem = 'Supermicro'; Model = 'X' }) | Should -BeNullOrEmpty
        { & $global:ztpS_run @{ Model = 'AX760'; Execute = $true } } | Should -Throw '*needs -CacheDirectory*'
        { & $global:ztpS_run @{ SolutionVersion = 'newest'; Model = 'AX760' } } | Should -Throw '*-SolutionVersion must be*'
    }
}
