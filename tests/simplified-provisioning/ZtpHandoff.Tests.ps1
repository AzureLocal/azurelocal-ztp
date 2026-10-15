#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
# ztp-handoff.json (New-ZtpHandoff.ps1), its conversion to the cluster deployment inputs (Convert-ZtpHandoffToClusterInputs.ps1),
# the prepare-everything wrapper (Invoke-ZtpPrepareMedia.ps1) and the Sonar launcher (Start-ZtpMonitor.ps1). ARM is mocked
# with the recorded fixtures; the wrapper runs against stub stage scripts; Sonar is a stub script.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Mocks and stubs report through globals.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock and stub signatures mirror the real commands; the bodies read only some parameters.')]
param()

BeforeAll {
    $global:ztpH_scripts = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts/simplified-provisioning'
    $global:ztpH_root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $global:ztpH_fixtures = Join-Path $PSScriptRoot 'fixtures'
    function global:Invoke-AzRestMethod { [CmdletBinding()] param([string]$Path, [string]$Method, [string]$Payload) }
    function global:New-ZtpHResponse { param([int]$Status, $Body) [pscustomobject]@{ StatusCode = $Status; Content = $(if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 40 } else { '' }) } }
    $global:ztpH_ready = Get-Content (Join-Path $global:ztpH_fixtures 'edge-machine-provisioned.json') -Raw | ConvertFrom-Json
    $global:ztpH_job = Get-Content (Join-Path $global:ztpH_fixtures 'job-provisionos-succeeded.json') -Raw | ConvertFrom-Json
    $global:ztpH_installing = Get-Content (Join-Path $global:ztpH_fixtures 'edge-machine-installing-os.json') -Raw | ConvertFrom-Json
    $global:ztpH_nodes = Join-Path $TestDrive 'nodes.json'
    @{ nodes = @(@{ name = 'node-01'; service_tag = 'EXAMPLE1'; bmc_address = '198.51.100.11' }, @{ name = 'node-02'; service_tag = 'EXAMPLE2'; bmc_address = '198.51.100.12' }) } | ConvertTo-Json -Depth 5 | Set-Content $global:ztpH_nodes
    # node-02 is node-01's fixture under another name and device ID.
    $two = ($global:ztpH_ready | ConvertTo-Json -Depth 40).Replace('edgeMachines/node-01', 'edgeMachines/node-02').Replace('"name": "node-01"', '"name": "node-02"').Replace('00000000-0000-0000-0000-000000000000-1', '11111111-1111-1111-1111-111111111111-1')
    $global:ztpH_ready2 = $two | ConvertFrom-Json
}
AfterAll {
    Remove-Item Function:\global:Invoke-AzRestMethod, Function:\global:New-ZtpHResponse -ErrorAction SilentlyContinue
    Get-Variable -Scope Global -Name 'ztpH_*' -ErrorAction SilentlyContinue | Remove-Variable -Scope Global -Force -ErrorAction SilentlyContinue
}

Describe 'New-ZtpHandoff.ps1' {
    BeforeEach {
        Remove-Item (Join-Path $TestDrive 'out') -Recurse -Force -ErrorAction SilentlyContinue
        $global:ztpH_machines = @{ 'node-01' = $global:ztpH_ready; 'node-02' = $global:ztpH_ready2 }
        Mock Invoke-AzRestMethod {
            if ($Path -match 'edgeMachines/([^/?]+)/jobs/ProvisionOs') { return New-ZtpHResponse 200 $global:ztpH_job }
            if ($Path -match 'edgeMachines/([^/?]+)\?') { $m = $global:ztpH_machines[$Matches[1]]; if ($m) { return New-ZtpHResponse 200 $m } }
            New-ZtpHResponse 404 $null
        }
        $global:ztpH_run = {
            param([hashtable]$Extra = @{})
            $a = @{ SubscriptionId = '00000000-0000-0000-0000-000000000000'; ResourceGroupName = 'rg-example'; NodeName = 'node-01', 'node-02'; NodesFile = $global:ztpH_nodes
                HandoffPath = (Join-Path $TestDrive 'out/ztp-handoff.json'); InformationAction = 'SilentlyContinue'; WarningAction = 'SilentlyContinue' }
            foreach ($k in $Extra.Keys) { $a[$k] = $Extra[$k] }
            & (Join-Path $global:ztpH_scripts 'New-ZtpHandoff.ps1') @a
        }
    }
    It 'plans by default: returns the content and writes nothing' {
        $h = & $global:ztpH_run @{}
        $h.nodes.Count | Should -Be 2
        Test-Path (Join-Path $TestDrive 'out/ztp-handoff.json') | Should -BeFalse
    }
    It 'writes node names, device-ID Arc machine names, resource group, site, solution version, SBE and bootstrap versions and timestamps' {
        $sbe = Join-Path $TestDrive 'sbe-manifest.json'
        @{ oem = 'Dell'; version = '5.0.2606.1616'; family = '16G-45n0c-Intel'; manifestSource = 'https://aka.ms/AzureStackSBEUpdate/DellEMC'; manifestCreationDate = '2026-06-24T05:58:20Z'; packageSha256 = ('A' * 64); compatibilityChecked = $true; deploymentParameters = @{ sbePublisher = 'Dell' } } | ConvertTo-Json | Set-Content $sbe
        $boot = Join-Path $TestDrive 'bootstrap-manifest.json'
        @{ version = '10.2610.0.3061'; isoSha256 = ('B' * 64); url = 'https://example.invalid/roe.zip' } | ConvertTo-Json | Set-Content $boot
        $events = Join-Path $TestDrive 'ev.jsonl'
        Set-Content $events @('{"timestamp":"2026-10-15T12:00:00Z","node":"node-01","state":"NotStarted"}', '{"timestamp":"2026-10-15T13:10:00Z","node":"node-01","state":"ReadyForPortal"}')
        $r = & $global:ztpH_run @{ Execute = $true; SbeManifestPath = $sbe; BootstrapManifestPath = $boot; EventLogPath = $events }
        $r.ArcMachineNames | Should -Be @('00000000-0000-0000-0000-000000000000-1', '11111111-1111-1111-1111-111111111111-1')
        $h = Get-Content $r.HandoffPath -Raw | ConvertFrom-Json
        $h.schemaVersion | Should -Be 1; $h.tool | Should -Be 'azurelocal-ztp'; $h.resourceGroup | Should -Be 'rg-example'
        $h.site.name | Should -Be 'site-example'; $h.solution.vsrVersion | Should -Be '12.2609.1003.7'
        $h.sbe.version | Should -Be '5.0.2606.1616'; $h.sbe.publisher | Should -Be 'Dell'; $h.bootstrap.version | Should -Be '10.2610.0.3061'
        $raw = Get-Content $r.HandoffPath -Raw
        $raw | Should -Match '"bootstrapFirstEvent": "2026-10-15T12:00:00.0000000Z"|"bootstrapFirstEvent": "2026-10-15T12:00:00Z"'
        $raw | Should -Match '"bootstrapLastEvent": "2026-10-15T13:10:00'
        $raw | Should -Match '"manifestCreationDate": "2026-06-24T05:58:20Z"'
        $n1 = $h.nodes | Where-Object name -EQ 'node-01'
        $n1.arcMachineName | Should -Be '00000000-0000-0000-0000-000000000000-1'; $n1.serial | Should -Be 'EXAMPLE1'; $n1.ready | Should -BeTrue
        $n1.arcMachineResourceGroup | Should -Be 'rg-example'
        ($h | ConvertTo-Json -Depth 8) | Should -Not -Match 'BEGIN OWNERSHIP'
    }
    It 'refuses to write a handoff while a machine is not ready to cluster, naming it' {
        $global:ztpH_machines['node-02'] = $global:ztpH_installing
        { & $global:ztpH_run @{ Execute = $true } } | Should -Throw '*Not ready to cluster: node-02*'
        Test-Path (Join-Path $TestDrive 'out/ztp-handoff.json') | Should -BeFalse
    }
    It 'refuses a missing edge machine and duplicate Arc names' {
        $global:ztpH_machines.Remove('node-02')
        { & $global:ztpH_run @{} } | Should -Throw '*Not ready to cluster: node-02*'
        $global:ztpH_machines['node-02'] = $global:ztpH_ready
        { & $global:ztpH_run @{} } | Should -Throw '*Duplicate Arc machine names*'
    }
}

Describe 'Convert-ZtpHandoffToClusterInputs.ps1' {
    BeforeAll {
        $global:ztpH_handoff = Join-Path $TestDrive 'ztp-handoff.json'
        [ordered]@{ schemaVersion = 1; solution = @{ vsrVersion = '12.2609.1003.7' }
            sbe = @{ oem = 'Dell'; version = '5.0.2606.1616'; family = '16G-45n0c-Intel'; publisher = 'Dell'; manifestSource = 'https://aka.ms/AzureStackSBEUpdate/DellEMC'; manifestCreationDate = '2026-06-24T05:58:20Z' }
            nodes = @(@{ name = 'node-01'; arcMachineName = '00000000-0000-0000-0000-000000000000-1' }, @{ name = 'node-02'; arcMachineName = '11111111-1111-1111-1111-111111111111-1' }) } | ConvertTo-Json -Depth 6 | Set-Content $global:ztpH_handoff
        $global:ztpH_convert = Join-Path $global:ztpH_scripts 'Convert-ZtpHandoffToClusterInputs.ps1'
    }
    It 'emits the arc_machine_names map (host name -> Arc machine name), the sbe block and the release versions as YAML' {
        $y = & $global:ztpH_convert -HandoffPath $global:ztpH_handoff
        $y | Should -Match "(?m)^arc_machine_names:\r?\n  node-01: '?00000000-0000-0000-0000-000000000000-1'?\r?\n  node-02: '?11111111-1111-1111-1111-111111111111-1'?"
        $y | Should -Match '(?m)^sbe:'; $y | Should -Match "  version: '?5.0.2606.1616'?"
        $y | Should -Match "  manifest_creation_date: '2026-06-24T05:58:20Z'"; $y | Should -Match '  publisher: Dell'
        $y | Should -Match "(?m)^release:\r?\n  azure_local_version: '?12.2609.1003.7'?"
    }
    It 'emits JSON that the cluster deployment inputs read (arc_machine_names is a map of strings)' {
        $j = & $global:ztpH_convert -HandoffPath $global:ztpH_handoff -Format Json -Only arc_machine_names | ConvertFrom-Json
        $j.arc_machine_names.'node-02' | Should -Be '11111111-1111-1111-1111-111111111111-1'
        $j.PSObject.Properties.Name | Should -Be @('arc_machine_names')
    }
    It 'writes -OutputPath and leaves sbe empty when the handoff has none' {
        $h = Get-Content $global:ztpH_handoff -Raw | ConvertFrom-Json; $h.PSObject.Properties.Remove('sbe'); $nosbe = Join-Path $TestDrive 'nosbe.json'; $h | ConvertTo-Json -Depth 6 | Set-Content $nosbe
        $out = Join-Path $TestDrive 'cluster/inputs.yaml'
        $y = & $global:ztpH_convert -HandoffPath $nosbe -OutputPath $out
        (Get-Content $out -Raw).TrimEnd() | Should -Be $y.TrimEnd()
        $y | Should -Match '(?m)^sbe: \{\}'
    }
    It 'refuses a handoff without Arc names, with duplicates, or of another schema' {
        $bad = Get-Content $global:ztpH_handoff -Raw | ConvertFrom-Json; $bad.nodes[1].arcMachineName = ''; $p = Join-Path $TestDrive 'bad1.json'; $bad | ConvertTo-Json -Depth 6 | Set-Content $p
        { & $global:ztpH_convert -HandoffPath $p } | Should -Throw '*no Arc machine name*'
        $bad.nodes[1].arcMachineName = $bad.nodes[0].arcMachineName; $p2 = Join-Path $TestDrive 'bad2.json'; $bad | ConvertTo-Json -Depth 6 | Set-Content $p2
        { & $global:ztpH_convert -HandoffPath $p2 } | Should -Throw '*share one Arc machine name*'
        $bad.schemaVersion = 2; $p3 = Join-Path $TestDrive 'bad3.json'; $bad | ConvertTo-Json -Depth 6 | Set-Content $p3
        { & $global:ztpH_convert -HandoffPath $p3 } | Should -Throw '*Unsupported handoff schemaVersion*'
        { & $global:ztpH_convert -HandoffPath (Join-Path $TestDrive 'missing.json') } | Should -Throw '*not found*'
    }
    It 'matches the arc_machine_names rule of the cluster deployment: a missing node falls back to its host name, so every node is listed' {
        $y = & $global:ztpH_convert -HandoffPath $global:ztpH_handoff -Only arc_machine_names
        @($y -split "`n" | Where-Object { $_ -match '^  ' }).Count | Should -Be 2
    }
}

Describe 'Invoke-ZtpPrepareMedia.ps1' {
    BeforeAll {
        $global:ztpH_stubs = Join-Path $TestDrive 'stubs'; $null = New-Item -ItemType Directory $global:ztpH_stubs
        $global:ztpH_calls = [System.Collections.Generic.List[object]]::new()
        $iso = @'
[CmdletBinding()] param([string]$Version, [string]$CacheDirectory, [switch]$IncludePreview, [string]$MaxTrain, [switch]$Execute)
$b = @{}; foreach ($k in $PSBoundParameters.Keys) { $b[$k] = $PSBoundParameters[$k] }; $global:ztpH_calls.Add([pscustomobject]@{ Script = 'iso'; P = $b })
$p = Join-Path $CacheDirectory 'bootstrap/10.2610.0.3061/provision-os.iso'
if ($Execute) { $null = New-Item -ItemType Directory (Split-Path $p) -Force; Set-Content $p 'iso' }
[pscustomobject]@{ Version = '10.2610.0.3061'; Channel = 'GA'; IsoPath = $p; ManifestPath = "$p.json"; IsoSha256 = 'AB'; Planned = (-not $Execute) }
'@
        $sbe = @'
[CmdletBinding()] param([string]$Oem, [string]$SolutionVersion, [string]$Model, [string]$Family, [string]$CacheDirectory, [string]$PackagePath, [switch]$Execute)
$b = @{}; foreach ($k in $PSBoundParameters.Keys) { $b[$k] = $PSBoundParameters[$k] }; $global:ztpH_calls.Add([pscustomobject]@{ Script = 'sbe'; P = $b })
[pscustomobject]@{ Oem = $Oem; Version = '5.0.2606.1616'; Status = 'ManualOrConnector'; StagingFolder = (Join-Path $CacheDirectory 'sbe/dell/5.0.2606.1616') }
'@
        $img = @'
[CmdletBinding(SupportsShouldProcess)] param([string]$SourcePath, [string[]]$NodeName, [string]$OutputDirectory, [string]$ImageNamePrefix, [securestring]$EdgeUserPassword, [switch]$Force, [switch]$Execute)
$b = @{}; foreach ($k in $PSBoundParameters.Keys) { $b[$k] = $PSBoundParameters[$k] }; $global:ztpH_calls.Add([pscustomobject]@{ Script = 'img'; P = $b })
if ($Execute) { foreach ($n in $NodeName) { $f = Join-Path $OutputDirectory "$ImageNamePrefix$n.img"; $null = New-Item -ItemType Directory $OutputDirectory -Force; Set-Content $f 'x'; [pscustomobject]@{ Node = $n; ImagePath = $f } } } else { "PLAN: $($NodeName -join ',')" }
'@
        Set-Content (Join-Path $global:ztpH_stubs 'Get-ZtpBootstrapIso.ps1') $iso; Set-Content (Join-Path $global:ztpH_stubs 'Get-ZtpSbe.ps1') $sbe; Set-Content (Join-Path $global:ztpH_stubs 'New-ZtpVirtualUsbImage.ps1') $img
        $global:ztpH_cfg = Join-Path $TestDrive 'cfg.json'
        @{ NodesFile = $global:ztpH_nodes; ImageDirectory = (Join-Path $TestDrive 'images'); BootstrapCacheDirectory = (Join-Path $TestDrive 'dl'); Oem = 'Dell'; SbeModel = 'AX760'; SbeSolutionVersion = '12.2609.1003.7'; MaxBootstrapTrain = '2610'; ShareHost = '192.0.2.10' } | ConvertTo-Json | Set-Content $global:ztpH_cfg
        $global:ztpH_prep = Join-Path $global:ztpH_scripts 'Invoke-ZtpPrepareMedia.ps1'
    }
    BeforeEach { $global:ztpH_calls.Clear(); Remove-Item (Join-Path $TestDrive 'images'), (Join-Path $TestDrive 'dl') -Recurse -Force -ErrorAction SilentlyContinue }
    It 'plans by default from the config alone: resolves, selects the SBE, plans the images, writes nothing' {
        $r = & $global:ztpH_prep -ConfigPath $global:ztpH_cfg -StageScriptRoot $global:ztpH_stubs -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        $r.Planned | Should -BeTrue
        @($global:ztpH_calls | ForEach-Object Script) | Should -Be @('iso', 'sbe')
        ($global:ztpH_calls | Where-Object Script -EQ 'iso').P.ContainsKey('Execute') | Should -BeFalse
        ($global:ztpH_calls | Where-Object Script -EQ 'iso').P.MaxTrain | Should -Be '2610'
        ($global:ztpH_calls | Where-Object Script -EQ 'sbe').P.Model | Should -Be 'AX760'
        Test-Path (Join-Path $TestDrive 'images') | Should -BeFalse
    }
    It 'plans the image stage with its own script once the ISO is on disk' {
        $c = Join-Path $TestDrive 'cfg3.json'; $iso = Join-Path $TestDrive 'have.iso'; Set-Content $iso 'x'
        @{ NodesFile = $global:ztpH_nodes; ImageDirectory = (Join-Path $TestDrive 'images'); SourcePath = $iso } | ConvertTo-Json | Set-Content $c
        $out = & $global:ztpH_prep -ConfigPath $c -StageScriptRoot $global:ztpH_stubs -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        @($global:ztpH_calls | ForEach-Object Script) | Should -Be @('img')
        $global:ztpH_calls[0].P.ContainsKey('Execute') | Should -BeFalse
        $out | Should -Contain 'PLAN: node-01,node-02'
    }
    It 'with -Execute downloads, selects the SBE, builds an image per node from that ISO and verifies each image' {
        function global:Test-ZtpMediaImage { param([string]$Path) [pscustomobject]@{ Path = $Path; Size = 4GB; Gpt = $true; Label = 'CDROM'; Missing = @(); Valid = $true } }
        try {
            $r = & $global:ztpH_prep -ConfigPath $global:ztpH_cfg -StageScriptRoot $global:ztpH_stubs -Execute -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        }
        finally { Remove-Item Function:\global:Test-ZtpMediaImage -ErrorAction SilentlyContinue }
        $r.Planned | Should -BeFalse; @($r.Images).Count | Should -Be 2
        $img = $global:ztpH_calls | Where-Object Script -EQ 'img'
        $img.P.SourcePath | Should -Be $r.IsoPath; $img.P.NodeName | Should -Be @('node-01', 'node-02'); $img.P.Execute | Should -BeTrue
        ($r.Sbe).Version | Should -Be '5.0.2606.1616'
        Test-Path (Join-Path $TestDrive 'images/ztp-usb-node-02.img') | Should -BeTrue
    }
    It 'fails when an image does not pass the read-back check' {
        function global:Test-ZtpMediaImage { param([string]$Path) [pscustomobject]@{ Path = $Path; Size = 1; Gpt = $true; Label = 'CDROM'; Missing = @('/liveos/rootfs.img'); Valid = $false } }
        try { { & $global:ztpH_prep -ConfigPath $global:ztpH_cfg -StageScriptRoot $global:ztpH_stubs -Execute -InformationAction SilentlyContinue -WarningAction SilentlyContinue } | Should -Throw '*failed the read-back check*rootfs.img*' }
        finally { Remove-Item Function:\global:Test-ZtpMediaImage -ErrorAction SilentlyContinue }
    }
    It 'uses SourcePath as it is without a cache directory and needs one of the two' {
        $c = Join-Path $TestDrive 'cfg2.json'; $iso = Join-Path $TestDrive 'mine.iso'; Set-Content $iso 'x'
        @{ NodesFile = $global:ztpH_nodes; ImageDirectory = (Join-Path $TestDrive 'images'); SourcePath = $iso } | ConvertTo-Json | Set-Content $c
        $r = & $global:ztpH_prep -ConfigPath $c -StageScriptRoot $global:ztpH_stubs -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        $r.IsoPath | Should -Be $iso
        @($global:ztpH_calls | Where-Object Script -EQ 'iso').Count | Should -Be 0
        @{ NodesFile = $global:ztpH_nodes; ImageDirectory = (Join-Path $TestDrive 'images') } | ConvertTo-Json | Set-Content $c
        { & $global:ztpH_prep -ConfigPath $c -StageScriptRoot $global:ztpH_stubs } | Should -Throw '*BootstrapCacheDirectory*SourcePath*'
    }
}

Describe 'Start-ZtpMonitor.ps1' {
    BeforeAll {
        $global:ztpH_sonar = Join-Path $TestDrive 'sonar'; $null = New-Item -ItemType Directory $global:ztpH_sonar
        Set-Content (Join-Path $global:ztpH_sonar 'Start-AzlSonar.ps1') 'param([string]$ConfigPath, [int]$Port, [switch]$NoBrowser, [string]$Record) $global:ztpH_sonarArgs = @{ ConfigPath = $ConfigPath; Port = $Port; NoBrowser = [bool]$NoBrowser; Record = $Record }'
        $global:ztpH_mon = Join-Path $global:ztpH_scripts 'Start-ZtpMonitor.ps1'
    }
    It 'prints the Sonar config and the command by default and starts nothing' {
        $out = & $global:ztpH_mon -SonarPath $global:ztpH_sonar -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example -NodesFile $global:ztpH_nodes -EventLogPath (Join-Path $TestDrive 'ev.jsonl') -SonarConfigPath (Join-Path $TestDrive 'sonar.json')
        ($out -join "`n") | Should -Match '"provisioningRoute": "simplified"'
        ($out -join "`n") | Should -Match 'ev.jsonl'
        Test-Path (Join-Path $TestDrive 'sonar.json') | Should -BeFalse
    }
    It 'writes a Sonar config that follows the event file and starts Sonar on it with -Execute' {
        $cfg = Join-Path $TestDrive 'sonar2.json'; $global:ztpH_sonarArgs = $null
        & $global:ztpH_mon -SonarPath $global:ztpH_sonar -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example -NodesFile $global:ztpH_nodes -EventLogPath (Join-Path $TestDrive 'ev.jsonl') -SonarConfigPath $cfg -Port 9001 -NoBrowser -Execute
        $c = Get-Content $cfg -Raw | ConvertFrom-Json
        $c.ztpEvents.path | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $TestDrive 'ev.jsonl')))
        $c.provisioningRoute | Should -Be 'simplified'; $c.nodes.Count | Should -Be 2; $c.nodes[0].seed | Should -BeTrue
        $c.nodes[0].address | Should -Be '198.51.100.11'
        $c.PSObject.Properties.Name | Should -Not -Contain 'password'
        $global:ztpH_sonarArgs.ConfigPath | Should -Be $cfg; $global:ztpH_sonarArgs.Port | Should -Be 9001; $global:ztpH_sonarArgs.NoBrowser | Should -BeTrue
    }
    It 'needs the Sonar folder' {
        { & $global:ztpH_mon -SonarPath (Join-Path $TestDrive 'nothing') -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg -NodesFile $global:ztpH_nodes } | Should -Throw '*Start-AzlSonar.ps1 not found*'
    }
}
