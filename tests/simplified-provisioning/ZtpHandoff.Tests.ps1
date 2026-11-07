#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
# ztp-handoff.json (New-ZtpHandoff.ps1, schema 2: only what Azure generated during ZTP), its conversion to the cluster
# deployment inputs (Convert-ZtpHandoffToClusterInputs.ps1), the media wrapper (Invoke-ZtpPrepareMedia.ps1) and the Sonar launcher (Start-ZtpMonitor.ps1). ARM is mocked
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
    It 'writes schema 2: only what Azure generated during ZTP, with each node''s Network result and restored BIOS' {
        $checks = @(@{ node = 'node-01'; verified = $true; reason = $null }, @{ node = 'node-02'; verified = $false; reason = 'dhcp: the management port Port0 reports 192.0.2.200, the infrastructure file expects 192.0.2.12' })
        $r = & $global:ztpH_run @{ Execute = $true; ManagementAddressCheck = $checks; RestoredBios = @{ 'node-01' = [ordered]@{ Slot2 = 'Enabled' } } }
        $r.ArcMachineNames | Should -Be @('00000000-0000-0000-0000-000000000000-1', '11111111-1111-1111-1111-111111111111-1')
        $h = Get-Content $r.HandoffPath -Raw | ConvertFrom-Json
        @($h.PSObject.Properties.Name) | Should -Be @('schemaVersion', 'generatedUtc', 'tool', 'subscriptionId', 'resourceGroup', 'site', 'solution', 'nodes')
        $h.schemaVersion | Should -Be 2; $h.tool | Should -Be 'azurelocal-ztp'; $h.resourceGroup | Should -Be 'rg-example'
        $h.subscriptionId | Should -Be '00000000-0000-0000-0000-000000000000'
        $h.site.name | Should -Be 'site-example'; $h.site.resourceId | Should -Match '/sites/site-example$'
        $h.solution.vsrVersion | Should -Be '12.2609.1003.7'
        $n1 = $h.nodes | Where-Object name -EQ 'node-01'
        @($n1.PSObject.Properties.Name) | Should -Be @('name', 'serial', 'edgeMachineName', 'edgeMachineId', 'arcMachineName', 'arcMachineResourceId', 'arcMachineResourceGroup', 'ready', 'managementAddressVerified', 'managementAddressReason', 'biosRestored', 'biosRestoreComplete', 'biosNotRestored', 'managementMode', 'networkAdapters')
        $n1.arcMachineName | Should -Be '00000000-0000-0000-0000-000000000000-1'; $n1.serial | Should -Be 'EXAMPLE1'; $n1.ready | Should -BeTrue
        $n1.edgeMachineName | Should -Be 'node-01'; $n1.edgeMachineId | Should -Match '/edgeMachines/node-01$'
        $n1.arcMachineResourceId | Should -Match '/Microsoft.HybridCompute/machines/00000000-0000-0000-0000-000000000000-1$'
        $n1.arcMachineResourceGroup | Should -Be 'rg-example'
        $n1.managementAddressVerified | Should -BeTrue; $n1.managementAddressReason | Should -BeNullOrEmpty
        $n1.biosRestored.Slot2 | Should -Be 'Enabled'
        $n2 = $h.nodes | Where-Object name -EQ 'node-02'
        $n2.managementAddressVerified | Should -BeFalse
        $n2.managementAddressReason | Should -Be 'dhcp: the management port Port0 reports 192.0.2.200, the infrastructure file expects 192.0.2.12'
        @($n2.biosRestored.PSObject.Properties).Count | Should -Be 0
        $raw = Get-Content $r.HandoffPath -Raw
        foreach ($gone in '"sbe"', '"bootstrap"', '"timestamps"', '"connectivity"', 'ipAddress', 'macAddress') { $raw | Should -Not -Match $gone -Because "the handoff carries only what Azure generated ($gone)" }
        $raw | Should -Not -Match 'BEGIN OWNERSHIP'
    }

    It 'says an unfinished BIOS restore is unfinished: biosRestoreComplete false, with the attributes Restore did not confirm' {
        $doc = Get-Content -LiteralPath $global:ztpH_nodes -Raw | ConvertFrom-Json -AsHashtable
        foreach ($n in $doc.nodes) { $n.bios_restore = [ordered]@{ Slot2 = ''; Slot3 = 'Enabled' } }
        $file = Join-Path $TestDrive 'nodes-with-restore.json'
        $doc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $file
        $h = & $global:ztpH_run @{ NodesFile = $file; RestoredBios = @{ 'node-01' = [ordered]@{ Slot2 = 'Enabled'; Slot3 = 'Enabled' }; 'node-02' = [ordered]@{ Slot3 = 'Enabled' } } }
        $n1 = @($h.nodes | Where-Object { $_['name'] -eq 'node-01' })[0]; $n2 = @($h.nodes | Where-Object { $_['name'] -eq 'node-02' })[0]
        $n1.biosRestoreComplete | Should -BeTrue; @($n1.biosNotRestored).Count | Should -Be 0
        $n2.biosRestoreComplete | Should -BeFalse; @($n2.biosNotRestored) | Should -Be @('Slot2')
        # Restore confirmed nothing for a node that needed it (it failed or never ran): false, naming every attribute.
        $h = & $global:ztpH_run @{ NodesFile = $file }
        foreach ($n in $h.nodes) { $n.biosRestoreComplete | Should -BeFalse; @($n.biosNotRestored) | Should -Be @('Slot2', 'Slot3') }
        # A node list with nothing to restore is complete.
        $h = & $global:ztpH_run @{}
        foreach ($n in $h.nodes) { $n.biosRestoreComplete | Should -BeTrue }
    }

    It 'records each port as Azure reports it after the install, matched by MAC to the file, with the mode, and prints a table' {
        # The node list Invoke-ZtpEnvironment.ps1 writes: the management port's MAC and ip_assignment, DHCP on the management
        # network or not, and the file's ports. The management port is a converged ConnectX port here, not an onboard one.
        $nodes = Join-Path $TestDrive "nodes-nic-$([guid]::NewGuid().ToString('N')).json"
        @{ nodes = @(
                [ordered]@{ name = 'node-01'; service_tag = 'EXAMPLE1'; bmc_address = '198.51.100.11'; management_mac = '00:00:5E:00:53:AA'; management_ip_assignment = 'static'; management_dhcp = $true
                    network_adapters = @(
                        [ordered]@{ name = 'Slot 3 Port 1'; mac_address = '00:00:5E:00:53:AA'; roles = @('management', 'compute', 'provisioning'); ip_assignment = 'static'; ip_address = '192.0.2.11' }
                        [ordered]@{ name = 'Slot 3 Port 2'; mac_address = '00:00:5E:00:53:BB'; roles = @('storage'); ip_assignment = 'none'; ip_address = '' }) }
                [ordered]@{ name = 'node-02'; service_tag = 'EXAMPLE2'; bmc_address = '198.51.100.12'; management_mac = '00:00:5E:00:53:CC'; management_ip_assignment = 'dhcp_reservation'; management_dhcp = $true; network_adapters = @() }) } |
            ConvertTo-Json -Depth 6 | Set-Content $nodes
        $adapter = {
            param([string]$Id, [string]$Name, [string]$Mac, [string]$Description, [string]$Type, [string]$Ip, [string]$Mask, [string]$Gateway)
            @{ name = $Id; properties = @{ networkConfiguration = @{ adapterName = $Name }; reportedProperties = @{ adapterName = $Name; macAddress = $Mac; interfaceDescription = $Description; ipInterfaceType = $Type; ip4Address = $Ip; subnetMask = $Mask; defaultGateway = $Gateway } } }
        }
        $global:ztpH_adapters = @{ value = @(
                (& $adapter '00000000-0000-0000-0000-000000000001' 'Port1' '00-00-5E-00-53-AA' 'Example ConnectX-6 Dx' 'Dhcp' '192.0.2.116' '255.255.255.0' '192.0.2.1')
                (& $adapter '00000000-0000-0000-0000-000000000002' 'Port2' '00-00-5E-00-53-BB' 'Example ConnectX-6 Dx' 'Dhcp' '198.51.100.40' '255.255.255.192' '198.51.100.1')
                (& $adapter '00000000-0000-0000-0000-000000000003' 'Port9' '00-00-5E-00-53-DD' 'Example unlisted NIC' '' '' '' '')) }
        Mock Invoke-AzRestMethod {
            if ($Path -match 'edgeMachines/node-01/networkAdapters\?') { return New-ZtpHResponse 200 $global:ztpH_adapters }
            if ($Path -match 'edgeMachines/([^/?]+)/jobs/ProvisionOs') { return New-ZtpHResponse 200 $global:ztpH_job }
            if ($Path -match 'edgeMachines/([^/?]+)\?') { $m = $global:ztpH_machines[$Matches[1]]; if ($m) { return New-ZtpHResponse 200 $m } }
            New-ZtpHResponse 404 $null
        }
        $reason = 'Mode B (Static with DHCP): the management port Port1 (MAC 00:00:5e:00:53:aa, Example ConnectX-6 Dx) has DHCP 192.0.2.116 after the install; expected static 192.0.2.11; OS configuration sets it by MAC.'
        $a = @{ SubscriptionId = '00000000-0000-0000-0000-000000000000'; ResourceGroupName = 'rg-example'; NodeName = 'node-01', 'node-02'; NodesFile = $nodes
            HandoffPath = (Join-Path $TestDrive 'out/ztp-handoff-nic.json'); WarningAction = 'SilentlyContinue'; Execute = $true
            ManagementAddressCheck = @(@{ node = 'node-01'; verified = $false; reason = $reason }, @{ node = 'node-02'; verified = $true; reason = $null }) }
        $r = & (Join-Path $global:ztpH_scripts 'New-ZtpHandoff.ps1') @a -InformationVariable info -InformationAction SilentlyContinue
        $h = Get-Content $r.HandoffPath -Raw | ConvertFrom-Json
        $h.schemaVersion | Should -Be 2 -Because 'the per-port detail is additive'
        $n1 = $h.nodes | Where-Object name -EQ 'node-01'
        $n1.managementMode.mode | Should -Be 'B'; $n1.managementMode.name | Should -Be 'Static with DHCP'; $n1.managementMode.ipAssignment | Should -Be 'static'
        $n1.managementAddressReason | Should -Be $reason
        $ports = @($n1.networkAdapters)
        $ports.Count | Should -Be 3
        $m = $ports | Where-Object isManagement
        @($m).Count | Should -Be 1
        "$($m.name) $($m.macAddress) $($m.fileName) $(@($m.roles) -join ',') $($m.ipAssignment) $($m.ipAddress)/$($m.prefix) $($m.subnetMask) $($m.gateway)" | Should -Be 'Port1 00:00:5e:00:53:aa Slot 3 Port 1 management,compute,provisioning Dhcp 192.0.2.116/24 255.255.255.0 192.0.2.1'
        $m.description | Should -Be 'Example ConnectX-6 Dx'
        "$($m.expected.ipAssignment) $($m.expected.ipAddress)" | Should -Be 'static 192.0.2.11'
        $storage = $ports | Where-Object name -EQ 'Port2'
        $storage.isManagement | Should -BeFalse; $storage.prefix | Should -Be 26; $storage.expected.ipAssignment | Should -Be 'none'; $storage.expected.ipAddress | Should -BeNullOrEmpty
        $unlisted = $ports | Where-Object name -EQ 'Port9'
        $unlisted.ipAssignment | Should -Be 'none'; $unlisted.fileName | Should -BeNullOrEmpty; @($unlisted.roles).Count | Should -Be 0; $unlisted.expected | Should -BeNullOrEmpty
        $n2 = $h.nodes | Where-Object name -EQ 'node-02'
        $n2.managementMode.mode | Should -Be 'A'
        @($n2.networkAdapters).Count | Should -Be 0 -Because 'node-02 reports no adapters here'
        $text = @($info | ForEach-Object { [string]$_.MessageData }) -join "`n"
        $text | Should -Match 'node-01: Mode B \(Static with DHCP, static\); management address not verified: Mode B'
        $text | Should -Match '> +Port1 +00:00:5e:00:53:aa +management,compute,provisioning \(Slot 3 Port 1\) +Dhcp 192\.0\.2\.116/24 gw 192\.0\.2\.1 +static 192\.0\.2\.11'
        $text | Should -Match 'Port9 +00:00:5e:00:53:dd +not in the file +none, no address'
        $text | Should -Match 'node-02: Mode A \(Reserved, dhcp_reservation\); management address verified'
    }

    It 'records a node without a Network result as not verified, and reads the results from state-file hashtables' {
        $h = & $global:ztpH_run @{ ManagementAddressCheck = @(@{ node = 'node-01'; verified = $true; reason = $null }) }
        ($h.nodes | Where-Object { $_.name -eq 'node-01' }).managementAddressVerified | Should -BeTrue
        $two = $h.nodes | Where-Object { $_.name -eq 'node-02' }
        $two.managementAddressVerified | Should -BeFalse
        $two.managementAddressReason | Should -Be 'no Network stage result for this node'
    }

    It 'takes the installed build from the ProvisionOs job when the edge machine''s request has no resolved version' {
        $m = $global:ztpH_ready | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
        $m.properties.provisioningDetails.osProfile.vsrVersion = 'latest'
        $global:ztpH_machines['node-01'] = $m
        $h = & $global:ztpH_run @{ NodeName = @('node-01') }
        $h.solution.vsrVersion | Should -Be '12.2609.1003.7'
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
        [ordered]@{ schemaVersion = 2; solution = @{ vsrVersion = '12.2609.1003.7' }
            nodes = @(@{ name = 'node-01'; arcMachineName = '00000000-0000-0000-0000-000000000000-1'; arcMachineResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.HybridCompute/machines/00000000-0000-0000-0000-000000000000-1'; managementAddressVerified = $true }, @{ name = 'node-02'; arcMachineName = '11111111-1111-1111-1111-111111111111-1'; managementAddressVerified = $true }) } | ConvertTo-Json -Depth 6 | Set-Content $global:ztpH_handoff
        # A handoff written before ZTP ended at Network (schema 1, with an sbe block).
        $global:ztpH_handoffV1 = Join-Path $TestDrive 'ztp-handoff-v1.json'
        [ordered]@{ schemaVersion = 1; solution = @{ vsrVersion = '12.2609.1003.7' }
            sbe = @{ oem = 'Dell'; version = '5.0.2606.1616'; family = '16G-45n0c-Intel'; publisher = 'Dell' }
            nodes = @(@{ name = 'node-01'; arcMachineName = '00000000-0000-0000-0000-000000000000-1' }, @{ name = 'node-02'; arcMachineName = '11111111-1111-1111-1111-111111111111-1' }) } | ConvertTo-Json -Depth 6 | Set-Content $global:ztpH_handoffV1
        $global:ztpH_convert = Join-Path $global:ztpH_scripts 'Convert-ZtpHandoffToClusterInputs.ps1'
    }
    It 'emits the arc_machine_names map (host name -> Arc machine name) and the installed solution version as YAML, and no SBE' {
        $y = & $global:ztpH_convert -HandoffPath $global:ztpH_handoff
        $y | Should -Match "(?m)^arc_machine_names:\r?\n  node-01: '?00000000-0000-0000-0000-000000000000-1'?\r?\n  node-02: '?11111111-1111-1111-1111-111111111111-1'?"
        $y | Should -Match "(?m)^release:\r?\n  azure_local_version: '?12.2609.1003.7'?$"
        $y | Should -Not -Match '(?m)^sbe'
    }
    It 'reads a schema 1 handoff too, and ignores its sbe block' {
        $y = & $global:ztpH_convert -HandoffPath $global:ztpH_handoffV1
        $y | Should -Match '(?m)^arc_machine_names:'
        $y | Should -Not -Match 'sbe'
    }
    It 'emits JSON that the cluster deployment inputs read (arc_machine_names is a map of strings)' {
        $j = & $global:ztpH_convert -HandoffPath $global:ztpH_handoff -Format Json -Only arc_machine_names | ConvertFrom-Json
        $j.arc_machine_names.'node-02' | Should -Be '11111111-1111-1111-1111-111111111111-1'
        $j.PSObject.Properties.Name | Should -Be @('arc_machine_names')
    }
    It 'writes -OutputPath' {
        $out = Join-Path $TestDrive 'cluster/inputs.yaml'
        $y = & $global:ztpH_convert -HandoffPath $global:ztpH_handoff -OutputPath $out
        (Get-Content $out -Raw).TrimEnd() | Should -Be $y.TrimEnd()
    }
    It 'refuses a handoff without Arc names, with duplicates, or of another schema' {
        $bad = Get-Content $global:ztpH_handoff -Raw | ConvertFrom-Json; $bad.nodes[1].arcMachineName = ''; $p = Join-Path $TestDrive 'bad1.json'; $bad | ConvertTo-Json -Depth 6 | Set-Content $p
        { & $global:ztpH_convert -HandoffPath $p } | Should -Throw '*no Arc machine name*'
        $bad.nodes[1].arcMachineName = $bad.nodes[0].arcMachineName; $p2 = Join-Path $TestDrive 'bad2.json'; $bad | ConvertTo-Json -Depth 6 | Set-Content $p2
        { & $global:ztpH_convert -HandoffPath $p2 } | Should -Throw '*share one Arc machine name*'
        $bad.nodes[1].arcMachineName = 'node-02-arc'; $bad.schemaVersion = 3; $p3 = Join-Path $TestDrive 'bad3.json'; $bad | ConvertTo-Json -Depth 6 | Set-Content $p3
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
        $img = @'
[CmdletBinding(SupportsShouldProcess)] param([string]$SourcePath, [string[]]$NodeName, [string]$OutputDirectory, [string]$ImageNamePrefix, [securestring]$EdgeUserPassword, [switch]$Force, [switch]$Execute)
$b = @{}; foreach ($k in $PSBoundParameters.Keys) { $b[$k] = $PSBoundParameters[$k] }; $global:ztpH_calls.Add([pscustomobject]@{ Script = 'img'; P = $b })
if ($Execute) { foreach ($n in $NodeName) { $f = Join-Path $OutputDirectory "$ImageNamePrefix$n.img"; $null = New-Item -ItemType Directory $OutputDirectory -Force; Set-Content $f 'x'; [pscustomobject]@{ Node = $n; ImagePath = $f } } } else { "PLAN: $($NodeName -join ',')" }
'@
        Set-Content (Join-Path $global:ztpH_stubs 'Get-ZtpBootstrapIso.ps1') $iso; Set-Content (Join-Path $global:ztpH_stubs 'New-ZtpVirtualUsbImage.ps1') $img
        $global:ztpH_cfg = Join-Path $TestDrive 'cfg.json'
        @{ NodesFile = $global:ztpH_nodes; ImageDirectory = (Join-Path $TestDrive 'images'); BootstrapCacheDirectory = (Join-Path $TestDrive 'dl'); Oem = 'Dell'; SbeModel = 'AX760'; SbeSolutionVersion = '12.2609.1003.7'; MaxBootstrapTrain = '2610'; ShareHost = '192.0.2.10' } | ConvertTo-Json | Set-Content $global:ztpH_cfg
        $global:ztpH_prep = Join-Path $global:ztpH_scripts 'Invoke-ZtpPrepareMedia.ps1'
    }
    BeforeEach { $global:ztpH_calls.Clear(); Remove-Item (Join-Path $TestDrive 'images'), (Join-Path $TestDrive 'dl') -Recurse -Force -ErrorAction SilentlyContinue }
    It 'plans by default from the config alone: resolves, plans the images, selects no SBE, writes nothing' {
        # The plan lines come first; the result object is the last output.
        $r = @(& $global:ztpH_prep -ConfigPath $global:ztpH_cfg -StageScriptRoot $global:ztpH_stubs -InformationAction SilentlyContinue -WarningAction SilentlyContinue)[-1]
        $r.Planned | Should -BeTrue
        @($global:ztpH_calls | ForEach-Object Script) | Should -Be @('iso') -Because 'the config''s SbeModel is ignored: no SBE in ZTP'
        ($global:ztpH_calls | Where-Object Script -EQ 'iso').P.ContainsKey('Execute') | Should -BeFalse
        ($global:ztpH_calls | Where-Object Script -EQ 'iso').P.MaxTrain | Should -Be '2610'
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
    It 'with -Execute downloads, builds an image per node from that ISO and verifies each image' {
        function global:Test-ZtpMediaImage { param([string]$Path) [pscustomobject]@{ Path = $Path; Size = 4GB; Gpt = $true; Label = 'CDROM'; Missing = @(); Valid = $true } }
        try {
            $r = & $global:ztpH_prep -ConfigPath $global:ztpH_cfg -StageScriptRoot $global:ztpH_stubs -Execute -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        }
        finally { Remove-Item Function:\global:Test-ZtpMediaImage -ErrorAction SilentlyContinue }
        $r.Planned | Should -BeFalse; @($r.Images).Count | Should -Be 2
        $img = $global:ztpH_calls | Where-Object Script -EQ 'img'
        $img.P.SourcePath | Should -Be $r.IsoPath; $img.P.NodeName | Should -Be @('node-01', 'node-02'); $img.P.Execute | Should -BeTrue
        $r.PSObject.Properties.Name | Should -Not -Contain 'Sbe'
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
        $r = @(& $global:ztpH_prep -ConfigPath $c -StageScriptRoot $global:ztpH_stubs -InformationAction SilentlyContinue -WarningAction SilentlyContinue)[-1]
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
