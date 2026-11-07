#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
# Invoke-ZtpProvisioning.ps1: stage order, plan by default, -Execute, result checks between stages, resumable state,
# -Stage/-From, the Configurator App fallback and the settings file. Every stage script is a stub in TestDrive that records
# its parameters; nothing touches a BMC, a machine or Azure.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Stub scripts report through globals.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Only a synthetic test credential is converted.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock and stub signatures mirror the real commands; the bodies read only some parameters.')]
param()

BeforeAll {
    $script:repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:orchestrator = Join-Path $script:repoRoot 'scripts/simplified-provisioning/Invoke-ZtpProvisioning.ps1'
    . (Join-Path $script:repoRoot 'scripts/simplified-provisioning/ZtpVirtualUsb.Common.ps1')
    . (Join-Path $script:repoRoot 'scripts/simplified-provisioning/ZtpEvents.Common.ps1')
    $script:stubRoot = Join-Path $TestDrive 'stubs'
    $null = New-Item -ItemType Directory -Path $script:stubRoot -Force
    $names = 'SourcePath', 'NodeName', 'NodesFile', 'OutputDirectory', 'ImageNamePrefix', 'EdgeUserPassword', 'Force', 'Execute', 'ImageDirectory',
    'ShareName', 'ShareHost', 'Restart', 'ConfirmNotClustered', 'RfsWriteAttribute', 'SkipCertificateCheck', 'Credential', 'VoucherFolder',
    'TimeoutMinutes', 'Action', 'Remove', 'SharePath', 'Stage', 'SubscriptionId', 'ResourceGroupName', 'ParameterFile', 'VoucherPath', 'OsVersion',
    'SiteMode', 'Node', 'DeploymentName', 'AdminPassword', 'PollIntervalSeconds', 'RetryProvisionOs', 'ArcMachineNameMapPath', 'ExpectedMachineName',
    'Version', 'CacheDirectory', 'IncludePreview', 'MaxTrain', 'Oem', 'EventLogPath', 'VoucherTimeoutMinutes',
    'SkipAzureCheck', 'ImageBuiltAt', 'ResetAt', 'Location', 'HandoffPath', 'ManagementAddressCheck', 'OutputPath', 'Format', 'BiosLogPath', 'ChangeLogPath', 'SizeBytes', 'AccountName', 'StallMinutes', 'Port', 'UserName', 'BiosTimeoutMinutes', 'Original', 'RestoredBios', 'ApplyThroughAzure', 'ConnectedSince', 'ImageEmptyAtBuild'
    $paramBlock = ($names | ForEach-Object { "[object]`$$_" }) -join ', '
    foreach ($script in 'New-ZtpVirtualUsbImage.ps1', 'Start-MaintenanceBoot.ps1', 'Wait-ZtpVoucher.ps1', 'Mount-ZtpVirtualUsb.ps1', 'Publish-MaintenanceIso.ps1',
        'Invoke-ZtpAzureProvisioning.ps1', 'Test-ProvisionedMachines.ps1', 'Get-ZtpBootstrapIso.ps1', 'Wait-ZtpBootstrapComplete.ps1',
        'Set-ZtpDeviceConfiguration.ps1', 'Set-ZtpManagementAddress.ps1', 'Restore-ZtpBios.ps1', 'New-ZtpHandoff.ps1', 'Convert-ZtpHandoffToClusterInputs.ps1') {
        $body = @"
[CmdletBinding(SupportsShouldProcess)]
param($paramBlock)
`$bound = @{}; foreach (`$k in `$PSBoundParameters.Keys) { `$bound[`$k] = `$PSBoundParameters[`$k] }
`$global:ztpRunCalls.Add([pscustomobject]@{ Script = '$script'; Params = `$bound })
if (`$global:ztpRunBehavior.ContainsKey('$script')) { & `$global:ztpRunBehavior['$script'] `$bound }
"@
        Set-Content -LiteralPath (Join-Path $script:stubRoot $script) -Value $body -Encoding utf8NoBOM
    }

    $script:nodesFile = Join-Path $TestDrive 'nodes.json'
    @{ nodes = @(@{ name = 'node-01'; service_tag = 'EXAMPLE1'; bmc_address = '198.51.100.11' }, @{ name = 'node-02'; service_tag = 'EXAMPLE2'; bmc_address = '198.51.100.12' }) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:nodesFile
    $script:vouchers = Join-Path $TestDrive 'vouchers'
    $script:images = Join-Path $TestDrive 'images'
    $null = New-Item -ItemType Directory -Path $script:vouchers, $script:images -Force
    $script:bmc = [pscredential]::new('bmc-example', (ConvertTo-SecureString 'Example-Not-A-Secret-1' -AsPlainText -Force))

    $script:healthy = {
        @{
            'New-ZtpVirtualUsbImage.ps1'      = { param($p) if ($p['Execute']) { foreach ($n in $p['NodeName']) { $f = Join-Path $p['OutputDirectory'] "ztp-usb-$n.img"; Set-Content -LiteralPath $f -Value 'img'; [pscustomobject]@{ Node = $n; ImagePath = $f; Sha256 = 'AB' } } } else { 'PLAN: build images' } }
            'Get-ZtpBootstrapIso.ps1'         = { param($p) $iso = Join-Path $p['CacheDirectory'] 'provision-os.iso'; if ($p['Execute']) { $null = New-Item -ItemType Directory -Path $p['CacheDirectory'] -Force; Set-Content -LiteralPath $iso -Value 'iso' }; [pscustomobject]@{ Version = '10.2610.0.3061'; Channel = 'GA'; Url = 'https://example.invalid/roe-2610.zip'; IsoPath = $iso; ManifestPath = "$iso.manifest.json"; IsoSha256 = 'CD'; Planned = (-not $p['Execute']) } }
            'Wait-ZtpBootstrapComplete.ps1'   = { param($p) foreach ($n in $p['NodeName']) { [pscustomobject]@{ Node = $n; State = 'ReadyForPortal'; Ready = $true; Evidence = 'ok'; VoucherSha256 = 'AB' } } }
            'New-ZtpHandoff.ps1'              = { param($p) if ($p['Execute']) { Set-Content -LiteralPath $p['HandoffPath'] -Value '{}' } }
            'Convert-ZtpHandoffToClusterInputs.ps1' = { param($p) Set-Content -LiteralPath $p['OutputPath'] -Value 'arc_machine_names: {}' }
            'Start-MaintenanceBoot.ps1'       = { param($p) if ($p['Execute']) { foreach ($n in $p['NodeName']) { [pscustomobject]@{ Node = $n; Image = "ztp-usb-$n.img"; WriteProtected = $false; Restarted = $true; ResetAt = [datetime]::UtcNow } } } }
            'Set-ZtpDeviceConfiguration.ps1'  = { param($p) if ($p['Execute']) { foreach ($n in $p['Node']) { [pscustomobject]@{ Node = $n; Mode = 'static'; Status = $(if ($n -eq 'node-01') { 'Changed' } else { 'Skipped' }); Adapter = 'eno1'; MacAddress = '00:00:5e:00:53:aa'; Address = $(if ($n -eq 'node-01') { '192.0.2.11' } else { '' }); MaintenanceAddress = $(if ($n -eq 'node-01') { '192.0.2.111' } else { '' }); Released = @() } } } else { 'PLAN: node-01: POST SetArcBootstrapDeviceConfiguration' } }
            'Set-ZtpManagementAddress.ps1'    = { param($p) if ($p['Execute']) { foreach ($n in $p['Node']) { [pscustomobject]@{ Node = $n; Mode = 'static'; Status = $(if ($n -eq 'node-01') { 'Changed' } else { 'AlreadySet' }); Adapter = '00000000-0000-0000-0000-000000000001'; AdapterName = 'Port1'; MacAddress = '00:00:5e:00:53:aa'; Address = "192.0.2.1$($n[-1])"; ExpectedAddress = "192.0.2.1$($n[-1])"; Released = @(if ($n -eq 'node-01') { 'Port3' }); Changes = @() } } } else { 'PLAN: node-01: ApplyConfiguration on Port1' } }
            'Wait-ZtpVoucher.ps1'             = { param($p) foreach ($n in $p['NodeName']) { $serial = if ($n -eq 'node-01') { 'EXAMPLE1' } else { 'EXAMPLE2' }; $f = Join-Path $p['OutputDirectory'] "$serial.pem"; Set-Content -LiteralPath $f -Value 'pem'; [pscustomobject]@{ Node = $n; Serial = $serial; OutputFile = $f; Valid = $true } } }
            'Invoke-ZtpAzureProvisioning.ps1' = { param($p)
                switch ($p['Stage']) {
                    'Plan' { [pscustomobject]@{ VoucherProblems = @() } }
                    'Watch' { foreach ($n in $p['Node']) { [pscustomobject]@{ Node = $n; ArcMachineName = "00000000-0000-0000-0000-000000000000-$($n[-1])"; ArcResourceGroup = 'rg-example'; Change = 'Add' } } }
                }
            }
        }
    }
    $script:invoke = {
        param([hashtable]$Arguments)
        $base = @{
            NodesFile = $script:nodesFile; SourcePath = 'D:\Media\provision-os.iso'; ImageDirectory = $script:images; ShareHost = '192.0.2.10'
            VoucherDirectory = $script:vouchers; SubscriptionId = '00000000-0000-0000-0000-000000000000'; ResourceGroupName = 'rg-example'
            ParameterFile = 'main.parameters.json'; StageScriptRoot = $script:stubRoot; StatePath = $script:statePath
            InformationAction = 'SilentlyContinue'; WarningAction = 'SilentlyContinue'; EventLogPath = (Join-Path $TestDrive 'events.jsonl'); HandoffPath = (Join-Path $TestDrive 'handoff.json')
            ClusterInputsPath = (Join-Path $TestDrive 'inputs.yaml')
        }
        foreach ($k in $Arguments.Keys) { $base[$k] = $Arguments[$k] }
        & $script:orchestrator @base
    }
    $script:called = { @($global:ztpRunCalls | ForEach-Object Script) }
}

AfterAll {
    Remove-Variable ztpRunCalls, ztpRunBehavior -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Invoke-ZtpProvisioning.ps1' {
    BeforeEach {
        $global:ztpRunCalls = [System.Collections.Generic.List[object]]::new()
        $global:ztpRunBehavior = & $script:healthy
        $script:statePath = Join-Path $TestDrive "state-$([guid]::NewGuid().ToString('N')).json"
        Get-ChildItem -LiteralPath $script:vouchers, $script:images -File | Remove-Item -Force
        Remove-Item -LiteralPath (Join-Path $TestDrive 'events.jsonl') -Force -ErrorAction SilentlyContinue
    }

    It 'plans by default: shows the next stage''s own plan, acts nowhere and writes no state' {
        $out = & $script:invoke @{}
        & $script:called | Should -Be @('New-ZtpVirtualUsbImage.ps1')
        $global:ztpRunCalls[0].Params.ContainsKey('Execute') | Should -BeFalse
        $global:ztpRunCalls[0].Params.NodeName | Should -Be @('node-01', 'node-02')
        $out | Should -Contain 'PLAN: build images'
        Test-Path $script:statePath | Should -BeFalse
    }

    It 'refuses -Execute without -ConfirmNotClustered before any stage runs' {
        { & $script:invoke @{ Execute = $true; BmcCredential = $script:bmc } } | Should -Throw '*ConfirmNotClustered*'
        $global:ztpRunCalls.Count | Should -Be 0
    }

    It 'requires the BMC credential to act on the Boot stage' {
        { & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; Confirm = $false } } | Should -Throw '*Boot*BmcCredential*'
    }

    It 'runs Resolve (skipped) -> Media -> Boot -> Bootstrap -> Vouchers -> Device -> Azure -> Ready -> Network -> Restore -> Handoff in order and records every stage' {
        $rows = & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false }
        & $script:called | Should -Be @('New-ZtpVirtualUsbImage.ps1', 'Start-MaintenanceBoot.ps1', 'Wait-ZtpBootstrapComplete.ps1', 'Wait-ZtpVoucher.ps1', 'Publish-MaintenanceIso.ps1',
            'Set-ZtpDeviceConfiguration.ps1', 'Invoke-ZtpAzureProvisioning.ps1', 'Invoke-ZtpAzureProvisioning.ps1', 'Invoke-ZtpAzureProvisioning.ps1', 'Invoke-ZtpAzureProvisioning.ps1',
            'Invoke-ZtpAzureProvisioning.ps1', 'Test-ProvisionedMachines.ps1', 'Set-ZtpManagementAddress.ps1', 'Restore-ZtpBios.ps1', 'New-ZtpHandoff.ps1', 'Convert-ZtpHandoffToClusterInputs.ps1')
        @($rows | ForEach-Object Stage) | Should -Be @('Resolve', 'Media', 'Boot', 'Bootstrap', 'Vouchers', 'Device', 'Azure', 'Ready', 'Network', 'Restore', 'Handoff')
        @($global:ztpRunCalls | Where-Object Script -EQ 'Invoke-ZtpAzureProvisioning.ps1' | ForEach-Object { $_.Params.Stage }) | Should -Be @('Prereqs', 'Validate', 'Plan', 'Execute', 'Watch')
        $boot = $global:ztpRunCalls | Where-Object Script -EQ 'Start-MaintenanceBoot.ps1'
        $boot.Params.Restart | Should -BeTrue
        $boot.Params.Credential | Should -Be $script:bmc
        $test = $global:ztpRunCalls | Where-Object Script -EQ 'Test-ProvisionedMachines.ps1'
        $test.Params.ResourceGroupName | Should -Be 'rg-example'
        $test.Params.ExpectedMachineName | Should -Be @('00000000-0000-0000-0000-000000000000-1', '00000000-0000-0000-0000-000000000000-2')
        $state = Get-Content $script:statePath -Raw | ConvertFrom-Json -AsHashtable
        @($state.stages.Keys).Count | Should -Be 11
        $state.stages.Resolve.evidence | Should -Match 'skipped'
    }

    It 'records what Media built and when Boot reset each node, and passes both to Bootstrap (lab gap G20)' {
        $before = [datetime]::UtcNow.AddSeconds(-2)
        $null = & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false }
        $after = [datetime]::UtcNow.AddSeconds(2)
        $state = Get-Content $script:statePath -Raw | ConvertFrom-Json -AsHashtable
        foreach ($n in 'node-01', 'node-02') {
            $img = $state.stages.Media.data.images[$n]
            $img.path | Should -BeLike "*ztp-usb-$n.img"; $img.sha256 | Should -Be 'AB'
            $built = (ConvertTo-ZtpUtcDateTime $img.builtAt); $reset = (ConvertTo-ZtpUtcDateTime $state.stages.Boot.data.resetAt[$n])
            $built | Should -BeGreaterOrEqual $before; $reset | Should -BeLessOrEqual $after
            $reset | Should -BeGreaterOrEqual $built -Because 'Boot resets the node onto an image Media built earlier'
        }
        $wait = $global:ztpRunCalls | Where-Object Script -EQ 'Wait-ZtpBootstrapComplete.ps1'
        @($wait.Params.ImageBuiltAt.Keys | Sort-Object) | Should -Be @('node-01', 'node-02')
        @($wait.Params.ResetAt.Keys | Sort-Object) | Should -Be @('node-01', 'node-02')
        (ConvertTo-ZtpUtcDateTime $wait.Params.ImageBuiltAt['node-01']) | Should -Be (ConvertTo-ZtpUtcDateTime $state.stages.Media.data.images['node-01'].builtAt)
        (ConvertTo-ZtpUtcDateTime $wait.Params.ResetAt['node-02']) | Should -Be (ConvertTo-ZtpUtcDateTime $state.stages.Boot.data.resetAt['node-02'])
    }

    It 'Media reads each image it built and records whether its voucher slot was empty; Bootstrap gets that baseline, also from a later run' {
        # Real FAT32 images: node-01's is empty, node-02's already holds a voucher (an image reused from an earlier run).
        $global:ztpRunBehavior['New-ZtpVirtualUsbImage.ps1'] = {
            param($p)
            if (-not $p['Execute']) { return 'PLAN: build images' }
            $src = Join-Path $p['OutputDirectory'] 'src'; $null = New-Item -ItemType Directory -Force -Path $src
            Set-Content -LiteralPath (Join-Path $src 'boot.catalog') -Value 'c' -NoNewline
            foreach ($n in $p['NodeName']) {
                $f = Join-Path $p['OutputDirectory'] "ztp-usb-$n.img"
                $extra = if ($n -eq 'node-02') { @{ 'vouchers/EXAMPLE2/EXAMPLE2.pem' = [System.Text.Encoding]::ASCII.GetBytes("-----BEGIN OWNERSHIP VOUCHER-----`nAAAA`n-----END OWNERSHIP VOUCHER-----`n") } } else { @{} }
                $null = Build-ZtpFat32Image -SourcePath $src -OutputPath $f -SizeBytes 40MB -ClusterSize 512 -ExtraFiles $extra
                [pscustomobject]@{ Node = $n; ImagePath = $f; Sha256 = 'AB' }
            }
        }
        $null = & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false; Stage = 'Media' }
        $state = Get-Content $script:statePath -Raw | ConvertFrom-Json -AsHashtable
        $state.stages.Media.data.images['node-01'].voucherEmptyAtBuild | Should -BeTrue
        $state.stages.Media.data.images['node-02'].voucherEmptyAtBuild | Should -BeFalse
        $null = & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false; Stage = 'Boot' }
        $global:ztpRunCalls.Clear()
        $null = & $script:invoke @{ Execute = $true; BmcCredential = $script:bmc; Confirm = $false; Stage = 'Bootstrap' }
        $wait = $global:ztpRunCalls | Where-Object Script -EQ 'Wait-ZtpBootstrapComplete.ps1'
        $wait.Params.ImageEmptyAtBuild['node-01'] | Should -BeTrue
        $wait.Params.ImageEmptyAtBuild['node-02'] | Should -BeFalse
    }

    It 'records nothing about the image when Media cannot read it, and passes no ImageEmptyAtBuild (the file-time fallback)' {
        $null = & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false; Stage = 'Media' }
        $state = Get-Content $script:statePath -Raw | ConvertFrom-Json -AsHashtable
        $state.stages.Media.data.images['node-01'].ContainsKey('voucherEmptyAtBuild') | Should -BeFalse
        $null = & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false; Stage = 'Boot' }
        $global:ztpRunCalls.Clear()
        $null = & $script:invoke @{ Execute = $true; BmcCredential = $script:bmc; Confirm = $false; Stage = 'Bootstrap' }
        ($global:ztpRunCalls | Where-Object Script -EQ 'Wait-ZtpBootstrapComplete.ps1').Params.ContainsKey('ImageEmptyAtBuild') | Should -BeFalse
    }

    It 'passes the recorded times to a Bootstrap run later, from the state file' {
        $null = & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false; Stage = 'Media' }
        $null = & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false; Stage = 'Boot' }
        $global:ztpRunCalls.Clear()
        $null = & $script:invoke @{ Execute = $true; BmcCredential = $script:bmc; Confirm = $false; Stage = 'Bootstrap' }
        $wait = $global:ztpRunCalls | Where-Object Script -EQ 'Wait-ZtpBootstrapComplete.ps1'
        @($wait.Params.ImageBuiltAt.Keys | Sort-Object) | Should -Be @('node-01', 'node-02')
        @($wait.Params.ResetAt.Keys | Sort-Object) | Should -Be @('node-01', 'node-02')
        (ConvertTo-ZtpUtcDateTime $wait.Params.ResetAt['node-01']) | Should -BeLessThan ([datetime]::UtcNow.AddSeconds(2))
    }

    It 'passes nothing to Bootstrap for an image Media did not build, or a node Boot did not reset, in this run' {
        # Bootstrap on its own: no state, so nothing says this run built the image.
        $null = & $script:invoke @{ Execute = $true; BmcCredential = $script:bmc; Confirm = $false; Stage = 'Bootstrap' }
        $wait = $global:ztpRunCalls | Where-Object Script -EQ 'Wait-ZtpBootstrapComplete.ps1'
        $wait.Params.ContainsKey('ImageBuiltAt') | Should -BeFalse
        $wait.Params.ContainsKey('ResetAt') | Should -BeFalse
        # Boot and Bootstrap with the images built by an earlier run (Media not recorded): only the reset is known.
        $global:ztpRunCalls.Clear()
        $null = & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false; From = 'Boot'; ResetState = $true }
        $wait = $global:ztpRunCalls | Where-Object Script -EQ 'Wait-ZtpBootstrapComplete.ps1'
        $wait.Params.ContainsKey('ImageBuiltAt') | Should -BeFalse
        @($wait.Params.ResetAt.Keys | Sort-Object) | Should -Be @('node-01', 'node-02')
        # A Boot that reports no reset time (an older script) records none.
        $global:ztpRunBehavior['Start-MaintenanceBoot.ps1'] = { param($p) foreach ($n in $p['NodeName']) { [pscustomobject]@{ Node = $n; Image = "ztp-usb-$n.img"; WriteProtected = $false; Restarted = $true } } }
        $global:ztpRunCalls.Clear()
        $null = & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false; From = 'Media'; ResetState = $true }
        $wait = $global:ztpRunCalls | Where-Object Script -EQ 'Wait-ZtpBootstrapComplete.ps1'
        @($wait.Params.ImageBuiltAt.Keys | Sort-Object) | Should -Be @('node-01', 'node-02')
        $wait.Params.ContainsKey('ResetAt') | Should -BeFalse
    }

    It 'does not pass the times when the vouchers come from the Configurator App folder' {
        $null = & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false; VoucherFolder = 'D:\Downloads\vouchers'; SkipAzureCheck = $true; Stage = 'Media' }
        $null = & $script:invoke @{ Execute = $true; BmcCredential = $script:bmc; Confirm = $false; VoucherFolder = 'D:\Downloads\vouchers'; SkipAzureCheck = $true; Stage = 'Bootstrap' }
        $wait = $global:ztpRunCalls | Where-Object Script -EQ 'Wait-ZtpBootstrapComplete.ps1'
        $wait.Params.ContainsKey('ImageBuiltAt') | Should -BeFalse
    }

    It 'Network sets the management addresses after Ready, logs the changes beside the event log and records each node' {
        $null = & $script:invoke @{ Execute = $true; Stage = 'Network'; Confirm = $false; NetworkTimeoutMinutes = 15; PollIntervalSeconds = 5 }
        $net = $global:ztpRunCalls | Where-Object Script -EQ 'Set-ZtpManagementAddress.ps1'
        $net.Params.Execute | Should -BeTrue
        $net.Params.Node | Should -Be @('node-01', 'node-02')
        $net.Params.ParameterFile | Should -Be 'main.parameters.json'
        $net.Params.SubscriptionId | Should -Be '00000000-0000-0000-0000-000000000000'
        $net.Params.ResourceGroupName | Should -Be 'rg-example'
        $net.Params.TimeoutMinutes | Should -Be 15
        $net.Params.PollIntervalSeconds | Should -Be 5
        $net.Params.ChangeLogPath | Should -Be (Join-Path $TestDrive 'network-changes.jsonl')
        $net.Params.EventLogPath | Should -Be (Join-Path $TestDrive 'events.jsonl')
        $net.Params.ContainsKey('ApplyThroughAzure') | Should -BeFalse -Because 'the Network stage is verify-only unless asked'
        $state = Get-Content $script:statePath -Raw | ConvertFrom-Json -AsHashtable
        $state.stages.Network.evidence | Should -Be 'node-01 Port1 00:00:5e:00:53:aa static 192.0.2.11 (Changed; released from Port3); node-02 Port1 00:00:5e:00:53:aa static 192.0.2.12 (AlreadySet)'
    }

    It 'Network is verify-only by default: a static address the OS install reset is Deferred to OS configuration, not a failure' {
        $reason = 'Mode B (Static with DHCP): the management port Port1 (MAC 00:00:5e:00:53:aa) has DHCP 192.0.2.116 after the install; expected static 192.0.2.11; OS configuration sets it by MAC.'
        $global:ztpRunBehavior['Set-ZtpManagementAddress.ps1'] = { param($p) foreach ($n in $p['Node']) { [pscustomobject]@{ Node = $n; Mode = 'static'; Status = 'Deferred'; AdapterName = 'Port1'; MacAddress = '00:00:5e:00:53:aa'; Address = '192.0.2.116'; ExpectedAddress = '192.0.2.11'; Verified = $false; Reason = $reason; Released = @() } } }.GetNewClosure()
        $null = & $script:invoke @{ Execute = $true; Stage = 'Network'; Confirm = $false }
        $state = Get-Content $script:statePath -Raw | ConvertFrom-Json -AsHashtable
        $state.stages.Network.evidence | Should -BeLike "node-01 Port1 00:00:5e:00:53:aa static 192.0.2.116 (Deferred: $reason); node-02 *"
        $one = @($state.stages.Network.data.managementAddress) | Where-Object { $_.node -eq 'node-01' }
        $one.verified | Should -BeFalse
        $one.reason | Should -Be $reason
    }

    It 'Network passes -ApplyThroughAzure on, from a parameter or the settings file, and then fails when a static node''s address is not set' {
        $global:ztpRunBehavior['Set-ZtpManagementAddress.ps1'] = { param($p) foreach ($n in $p['Node']) { [pscustomobject]@{ Node = $n; Mode = 'static'; Status = 'Planned'; AdapterName = 'Port1'; MacAddress = ''; Address = ''; Released = @() } } }
        { & $script:invoke @{ Execute = $true; Stage = 'Network'; Confirm = $false } } | Should -Not -Throw -Because 'verify-only never fails on the result'
        $global:ztpRunCalls.Clear()
        { & $script:invoke @{ Execute = $true; Stage = 'Network'; Confirm = $false; ApplyThroughAzure = $true } } | Should -Throw '*Network: the static management address of node-01 is Planned, not set*'
        ($global:ztpRunCalls | Where-Object Script -EQ 'Set-ZtpManagementAddress.ps1').Params.ApplyThroughAzure | Should -BeTrue
        (Get-Command $script:orchestrator).Parameters['ApplyThroughAzure'].SwitchParameter | Should -BeTrue
        (Get-Content -LiteralPath $script:orchestrator -Raw) | Should -Match "'NetworkTimeoutMinutes', 'ApplyThroughAzure'" -Because 'the settings file can turn it on'
    }

    It 'Network shows the stage''s own plan when it is next' {
        $global:ztpRunCalls.Clear(); $global:ztpRunBehavior = & $script:healthy
        $out = & $script:invoke @{ Stage = 'Network' }
        $plan = @($global:ztpRunCalls | Where-Object Script -EQ 'Set-ZtpManagementAddress.ps1')
        $plan.Count | Should -Be 1
        $plan[0].Params.ContainsKey('Execute') | Should -BeFalse
        $out | Should -Contain 'PLAN: node-01: ApplyConfiguration on Port1'
    }

    It 'Device sets the address in the maintenance environment before the claim, with the edgeuser password, and lets a node without a maintenance address through' {
        $edge = ConvertTo-SecureString 'Example-Not-A-Secret-2' -AsPlainText -Force
        $null = & $script:invoke @{ Execute = $true; Stage = 'Device'; Confirm = $false; EdgeUserPassword = $edge; DeviceTimeoutMinutes = 12 }
        $device = $global:ztpRunCalls | Where-Object Script -EQ 'Set-ZtpDeviceConfiguration.ps1'
        $device.Params.Execute | Should -BeTrue
        $device.Params.Node | Should -Be @('node-01', 'node-02')
        $device.Params.NodesFile | Should -Be $script:nodesFile
        $device.Params.ParameterFile | Should -Be 'main.parameters.json'
        $device.Params.EdgeUserPassword | Should -Be $edge
        $device.Params.TimeoutMinutes | Should -Be 12
        $device.Params.ChangeLogPath | Should -Be (Join-Path $TestDrive 'device-changes.jsonl')
        $state = Get-Content $script:statePath -Raw | ConvertFrom-Json -AsHashtable
        $state.stages.Device.evidence | Should -Be 'node-01 eno1 00:00:5e:00:53:aa static 192.0.2.11 (Changed); node-02 not static and no maintenance_address, nothing to set (Skipped)'
        $global:ztpRunBehavior['Set-ZtpDeviceConfiguration.ps1'] = { param($p) foreach ($n in $p['Node']) { [pscustomobject]@{ Node = $n; Mode = 'static'; Status = 'Planned'; MaintenanceAddress = '192.0.2.111' } } }
        { & $script:invoke @{ Execute = $true; Stage = 'Device'; Confirm = $false } } | Should -Throw '*Device: the static management address of node-01 is Planned, not set*'
    }

    It 'runs -From Network: Network, Restore (a no-op here) then Handoff' {
        $null = & $script:invoke @{ Execute = $true; From = 'Network'; Confirm = $false }
        & $script:called | Should -Be @('Set-ZtpManagementAddress.ps1', 'Restore-ZtpBios.ps1', 'New-ZtpHandoff.ps1', 'Convert-ZtpHandoffToClusterInputs.ps1')
        $state = Get-Content $script:statePath -Raw | ConvertFrom-Json -AsHashtable
        $state.stages.Restore.evidence | Should -Be 'nothing to restore: no bios_during_provisioning'
    }

    It 'Boot saves each BIOS attribute''s original value once, Restore sets it back and waits for Connected and ready, and the handoff records it' {
        $nodes = Join-Path $TestDrive "nodes-restore-$([guid]::NewGuid().ToString('N')).json"
        @{ nodes = @(@{ name = 'node-01'; service_tag = 'EXAMPLE1'; bmc_address = '198.51.100.11'; bios = @{ Slot2 = 'Disabled' }; bios_restore = @{ Slot2 = '' } }, @{ name = 'node-02'; service_tag = 'EXAMPLE2'; bmc_address = '198.51.100.12' }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $nodes
        $global:ztpRunBehavior['Start-MaintenanceBoot.ps1'] = { param($p) foreach ($n in $p['NodeName']) { [pscustomobject]@{ Node = $n; Image = "ztp-usb-$n.img"; WriteProtected = $false; Restarted = $true; Bios = @(); BiosOriginal = $(if ($n -eq 'node-01') { [ordered]@{ Slot2 = $global:ztpRunSlot2 } } else { [ordered]@{} }) } } }
        $global:ztpRunBehavior['Restore-ZtpBios.ps1'] = { param($p) foreach ($n in $p['NodeName']) { if ($n -eq 'node-01') { [pscustomobject]@{ Node = $n; Status = 'Restored'; Restored = [ordered]@{ Slot2 = [string]$p['Original']['node-01']['Slot2'] }; Changes = @('Slot2: Disabled -> Enabled') } } else { [pscustomobject]@{ Node = $n; Status = 'NotNeeded'; Restored = [ordered]@{}; Changes = @() } } } }
        $global:ztpRunSlot2 = 'Enabled'
        $null = & $script:invoke @{ Execute = $true; Stage = 'Boot'; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false; NodesFile = $nodes }
        # A second Boot reads the already-changed value; the saved original must not change.
        $global:ztpRunSlot2 = 'Disabled'
        $null = & $script:invoke @{ Execute = $true; Stage = 'Boot'; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false; NodesFile = $nodes }
        $state = Get-Content $script:statePath -Raw | ConvertFrom-Json -AsHashtable
        $state.biosOriginal['node-01']['Slot2'] | Should -Be 'Enabled'
        $global:ztpRunCalls.Clear()
        $null = & $script:invoke @{ Execute = $true; From = 'Restore'; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false; NodesFile = $nodes; RestoreSettleMinutes = 0 }
        & $script:called | Should -Be @('Restore-ZtpBios.ps1', 'Invoke-ZtpAzureProvisioning.ps1', 'Test-ProvisionedMachines.ps1', 'New-ZtpHandoff.ps1', 'Convert-ZtpHandoffToClusterInputs.ps1')
        $restore = $global:ztpRunCalls | Where-Object Script -EQ 'Restore-ZtpBios.ps1'
        $restore.Params.Original['node-01']['Slot2'] | Should -Be 'Enabled'
        $restore.Params.Credential | Should -Be $script:bmc
        $restore.Params.Execute | Should -BeTrue
        $restore.Params.BiosLogPath | Should -Be (Join-Path $TestDrive 'bios-changes.jsonl')
        ($global:ztpRunCalls | Where-Object Script -EQ 'Invoke-ZtpAzureProvisioning.ps1').Params.Stage | Should -Be 'Watch'
        $handoff = $global:ztpRunCalls | Where-Object Script -EQ 'New-ZtpHandoff.ps1'
        $handoff.Params.RestoredBios['node-01']['Slot2'] | Should -Be 'Enabled'
        $state = Get-Content $script:statePath -Raw | ConvertFrom-Json -AsHashtable
        $state.stages.Restore.evidence | Should -Be 'BIOS set back: node-01 Slot2=Enabled; Connected and ready again: node-01'
        # Restore needs the BMC credential only when there is something to restore.
        { & $script:invoke @{ Execute = $true; Stage = 'Restore'; Confirm = $false; NodesFile = $nodes } } | Should -Throw '*Stage Restore: no value for BmcCredential*'
        Remove-Variable ztpRunSlot2 -Scope Global
    }

    Context 'Restore waits for a new Arc connection after the restart' {
        BeforeEach {
            $script:restoreNodes = Join-Path $TestDrive "nodes-restore-$([guid]::NewGuid().ToString('N')).json"
            @{ nodes = @(@{ name = 'node-01'; service_tag = 'EXAMPLE1'; bmc_address = '198.51.100.11'; bios_restore = @{ Slot2 = 'Enabled' } }, @{ name = 'node-02'; service_tag = 'EXAMPLE2'; bmc_address = '198.51.100.12'; bios_restore = @{ Slot2 = 'Enabled' } }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:restoreNodes
            $script:restartedAt = [datetime]::UtcNow
            $global:ztpRunRestartedAt = $script:restartedAt
            $global:ztpRunBehavior['Restore-ZtpBios.ps1'] = { param($p) [pscustomobject]@{ Node = 'node-01'; Status = 'Restored'; Restored = [ordered]@{ Slot2 = 'Enabled' }; Changes = @(); RestartedAt = $global:ztpRunRestartedAt }; [pscustomobject]@{ Node = 'node-02'; Status = 'AlreadySet'; Restored = [ordered]@{ Slot2 = 'Enabled' }; Changes = @(); RestartedAt = $null } }
            $script:rArgs = @{ Execute = $true; From = 'Restore'; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false; NodesFile = $script:restoreNodes; RestoreSettleMinutes = 0; PollIntervalSeconds = 0 }
        }
        AfterEach { Remove-Variable ztpRunRestartedAt, ztpRunTestTries -Scope Global -ErrorAction SilentlyContinue }

        It 'tests with -ConnectedSince for the restarted node only (the AlreadySet node is checked as before)' {
            $null = & $script:invoke $script:rArgs
            $test = $global:ztpRunCalls | Where-Object Script -EQ 'Test-ProvisionedMachines.ps1'
            @($test.Params.ConnectedSince.Keys) | Should -Be @('00000000-0000-0000-0000-000000000000-1')
            (ConvertTo-ZtpUtcDateTime $test.Params.ConnectedSince['00000000-0000-0000-0000-000000000000-1']) | Should -Be (ConvertTo-ZtpUtcDateTime $script:restartedAt)
        }

        It 'keeps checking until a new connection shows, instead of passing on a stale Connected' {
            $global:ztpRunTestTries = 0
            $global:ztpRunBehavior['Test-ProvisionedMachines.ps1'] = { param($p) $global:ztpRunTestTries++; if ($global:ztpRunTestTries -lt 3) { throw 'Provisioned machine verification failed: node (Connected since 2026-01-01T00:00:00.0000000Z, before the restart)' } }
            $null = & $script:invoke $script:rArgs
            @($global:ztpRunCalls | Where-Object Script -EQ 'Test-ProvisionedMachines.ps1').Count | Should -Be 3
        }

        It 'fails the stage when no new connection shows within the Ready timeout' {
            $global:ztpRunBehavior['Test-ProvisionedMachines.ps1'] = { param($p) throw 'Provisioned machine verification failed: node (Connected since the old time)' }
            $script:rArgs.ReadyTimeoutMinutes = 0
            { & $script:invoke $script:rArgs } | Should -Throw '*not Connected again after the BIOS restart*'
        }

        It 'fails the stage when a node that needs a restore reports Skipped, Planned or Failed, or no row' {
            foreach ($status in 'Skipped', 'Planned', 'Failed') {
                $global:ztpRunBehavior['Restore-ZtpBios.ps1'] = [scriptblock]::Create("param(`$p) [pscustomobject]@{ Node = 'node-01'; Status = 'Restored'; Restored = [ordered]@{}; Changes = @() }; [pscustomobject]@{ Node = 'node-02'; Status = '$status'; Restored = [ordered]@{}; Changes = @() }")
                { & $script:invoke $script:rArgs } | Should -Throw "*Restore: node-02 was not restored (result: $status)*"
            }
            $global:ztpRunBehavior['Restore-ZtpBios.ps1'] = { param($p) [pscustomobject]@{ Node = 'node-01'; Status = 'Restored'; Restored = [ordered]@{}; Changes = @() } }
            { & $script:invoke $script:rArgs } | Should -Throw '*Restore: node-02 was not restored (result: none)*'
        }
    }

    It 'writes StageStarted and StageCompleted events for every stage and StageFailed with the reason when a stage throws' {
        $global:ztpRunBehavior['Wait-ZtpBootstrapComplete.ps1'] = { param($p) [pscustomobject]@{ Node = 'node-01'; State = 'VoucherMissing'; Ready = $false; Evidence = 'no voucher in 90 minutes' }; [pscustomobject]@{ Node = 'node-02'; State = 'ReadyForPortal'; Ready = $true; Evidence = 'ok' } }
        { & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false } } | Should -Throw '*Bootstrap: node-01 is in state VoucherMissing: no voucher in 90 minutes*'
        $events = @(Get-Content (Join-Path $TestDrive 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        ($events | Where-Object { $_.state -eq 'StageCompleted' } | ForEach-Object stage) | Should -Be @('Resolve', 'Media', 'Boot')
        $failed = $events | Where-Object state -EQ 'StageFailed'
        $failed.stage | Should -Be 'Bootstrap'; $failed.level | Should -Be 'Error'; $failed.evidence | Should -Match 'VoucherMissing'
        & $script:called | Should -Not -Contain 'Wait-ZtpVoucher.ps1'
    }

    It 'Boot logs BIOS changes beside the event log, records them in the stage evidence and writes a BiosChanged event per node' {
        $global:ztpRunBehavior['Start-MaintenanceBoot.ps1'] = { param($p) if ($p['Execute']) { foreach ($n in $p['NodeName']) { [pscustomobject]@{ Node = $n; Image = "ztp-usb-$n.img"; WriteProtected = $false; Restarted = $true; Bios = $(if ($n -eq 'node-01') { @('Slot2: Enabled -> Disabled') } else { @() }) } } } }
        $null = & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false; Stage = 'Boot' }
        $boot = $global:ztpRunCalls | Where-Object Script -EQ 'Start-MaintenanceBoot.ps1'
        $boot.Params.BiosLogPath | Should -Be (Join-Path $TestDrive 'bios-changes.jsonl')
        $state = Get-Content $script:statePath -Raw | ConvertFrom-Json -AsHashtable
        $state.stages.Boot.evidence | Should -Match 'BIOS node-01 Slot2: Enabled -> Disabled'
        $events = @(Get-Content (Join-Path $TestDrive 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        $changed = @($events | Where-Object state -EQ 'BiosChanged')
        $changed.Count | Should -Be 1
        $changed[0].node | Should -Be 'node-01'
        $changed[0].evidence | Should -Be 'Slot2: Enabled -> Disabled'
    }

    It 'Resolve downloads the ISO and records its details as evidence, Media builds from that ISO, and no SBE is resolved' {
        $cache = Join-Path $TestDrive 'dl'
        $null = & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false; SourcePath = $null; BootstrapCacheDirectory = $cache; MaxBootstrapTrain = '2610' }
        $iso = $global:ztpRunCalls | Where-Object Script -EQ 'Get-ZtpBootstrapIso.ps1'
        $iso.Params.Execute | Should -BeTrue; $iso.Params.MaxTrain | Should -Be '2610'; $iso.Params.CacheDirectory | Should -Be $cache
        & $script:called | Should -Not -Contain 'Get-ZtpSbe.ps1'
        ($global:ztpRunCalls | Where-Object Script -EQ 'New-ZtpVirtualUsbImage.ps1').Params.SourcePath | Should -Be (Join-Path $cache 'provision-os.iso')
        # The ISO details stay with the run (state, stage evidence, event log); the handoff gets none of them.
        $handoff = $global:ztpRunCalls | Where-Object Script -EQ 'New-ZtpHandoff.ps1'
        $handoff.Params.Keys | Should -Not -Contain 'BootstrapManifestPath'
        $handoff.Params.Keys | Should -Not -Contain 'EventLogPath'
        $state = Get-Content $script:statePath -Raw | ConvertFrom-Json -AsHashtable
        $state.stages.Resolve.data.bootstrapVersion | Should -Be '10.2610.0.3061'
        $state.stages.Resolve.data.bootstrapUrl | Should -Be 'https://example.invalid/roe-2610.zip'
        $state.stages.Resolve.evidence | Should -Be 'maintenance ISO 10.2610.0.3061 (GA), SHA256 CD, from https://example.invalid/roe-2610.zip'
        $events = @(Get-Content (Join-Path $TestDrive 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        ($events | Where-Object { $_.state -eq 'StageCompleted' -and $_.stage -eq 'Resolve' }).evidence | Should -BeLike '*10.2610.0.3061*SHA256 CD*'
        @($events | Where-Object stage -EQ 'Handoff' | ForEach-Object state) | Should -Be @('StageStarted', 'StageCompleted') -Because 'the timestamps of every stage stay in the event log'
    }

    It 'records each node''s Network result in the state file and hands it to the handoff' {
        $global:ztpRunBehavior['Set-ZtpManagementAddress.ps1'] = { param($p) foreach ($n in $p['Node']) {
                if ($n -eq 'node-01') { [pscustomobject]@{ Node = $n; Mode = 'static'; Status = 'Changed'; AdapterName = 'Port0'; MacAddress = '00:00:5e:00:53:aa'; Address = '192.0.2.11'; ExpectedAddress = '192.0.2.11'; Released = @() } }
                else { [pscustomobject]@{ Node = $n; Mode = 'dhcp'; Status = 'Reported'; AdapterName = 'Port0'; MacAddress = '00:00:5e:00:53:bb'; Address = '192.0.2.200'; ExpectedAddress = '192.0.2.12'; Released = @() } }
            } }
        $null = & $script:invoke @{ Execute = $true; From = 'Network'; Confirm = $false }
        $state = Get-Content $script:statePath -Raw | ConvertFrom-Json -AsHashtable
        $checks = @($state.stages.Network.data.managementAddress)
        $checks.Count | Should -Be 2
        ($checks | Where-Object { $_.node -eq 'node-01' }).verified | Should -BeTrue
        $two = $checks | Where-Object { $_.node -eq 'node-02' }
        $two.verified | Should -BeFalse
        $two.reason | Should -Be 'dhcp: the management port Port0 reports 192.0.2.200, the infrastructure file expects 192.0.2.12'
        $handoff = $global:ztpRunCalls | Where-Object Script -EQ 'New-ZtpHandoff.ps1'
        @($handoff.Params.ManagementAddressCheck).Count | Should -Be 2
        (@($handoff.Params.ManagementAddressCheck) | Where-Object { $_['node'] -eq 'node-02' })['verified'] | Should -BeFalse
        # A later -Stage Handoff reads the same result back from the state file.
        $global:ztpRunCalls.Clear()
        $null = & $script:invoke @{ Execute = $true; Stage = 'Handoff'; Confirm = $false }
        $again = $global:ztpRunCalls | Where-Object Script -EQ 'New-ZtpHandoff.ps1'
        (@($again.Params.ManagementAddressCheck) | Where-Object { $_['node'] -eq 'node-01' })['verified'] | Should -BeTrue
    }

    It 'turns each kind of Network row into a verified flag or a short reason' {
        $global:ztpRunBehavior['Set-ZtpManagementAddress.ps1'] = { param($p) foreach ($n in $p['Node']) {
                if ($n -eq 'node-01') { [pscustomobject]@{ Node = $n; Mode = ''; Status = 'NotConfigured'; AdapterName = ''; MacAddress = ''; Address = ''; ExpectedAddress = ''; Released = @() } }
                else { [pscustomobject]@{ Node = $n; Mode = 'dhcp_reservation'; Status = 'Reported'; AdapterName = 'Port0'; MacAddress = '00:00:5e:00:53:bb'; Address = '192.0.2.12'; ExpectedAddress = '192.0.2.12'; Released = @() } }
            } }
        $null = & $script:invoke @{ Execute = $true; Stage = 'Network'; Confirm = $false }
        $state = Get-Content $script:statePath -Raw | ConvertFrom-Json -AsHashtable
        $checks = @($state.stages.Network.data.managementAddress)
        $one = $checks | Where-Object { $_.node -eq 'node-01' }
        $one.verified | Should -BeFalse; $one.reason | Should -Be 'no management settings in the infrastructure file'
        ($checks | Where-Object { $_.node -eq 'node-02' }).verified | Should -BeTrue -Because 'a DHCP reservation that hands out the expected address is verified'
        # The plan prints the Handoff call with the node results counted, never their contents.
        $plan = (& $script:invoke @{ Stage = 'Handoff' } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        $plan | Should -BeLike '*New-ZtpHandoff.ps1 *-ManagementAddressCheck <2 node result(s)>*'
    }

    It 'ignores the SBE settings of an older settings file, with a note, instead of failing' {
        $config = Join-Path $TestDrive 'settings-old.json'
        @{ NodesFile = $script:nodesFile; SourcePath = 'D:\Media\from-file.iso'; ImageDirectory = $script:images; ShareHost = '192.0.2.20'; VoucherDirectory = $script:vouchers; SubscriptionId = '00000000-0000-0000-0000-000000000000'; ResourceGroupName = 'rg-example'; ParameterFile = 'main.parameters.json'; SbeModel = 'AX760'; SbeSolutionVersion = 'latest'; SbePackagePath = 'D:\sbe.zip' } | ConvertTo-Json | Set-Content -LiteralPath $config
        $out = (& $script:orchestrator -ConfigPath $config -StageScriptRoot $script:stubRoot -StatePath $script:statePath -WarningAction SilentlyContinue 6>&1 | ForEach-Object { "$_" }) -join "`n"
        $out | Should -BeLike '*SbeModel in*ignored: SBE belongs to OS configuration.*'
        $out | Should -BeLike '*SbePackagePath in*ignored: SBE belongs to OS configuration.*'
        (Get-Command $script:orchestrator).Parameters.Keys | Should -Not -Contain 'SbeModel'
    }

    It 'says at the end that ZTP is done and OS configuration is next' {
        $out = (& $script:invoke @{ Execute = $true; From = 'Handoff'; Confirm = $false; InformationAction = 'Continue' } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        $out | Should -BeLike '*ZTP is done: the machines are Provisioned and Arc-connected*'
        $out | Should -BeLike '*Next: OS configuration*https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/*'
    }

    It 'resumes later stages with the ISO path recorded by Resolve' {
        $cache = Join-Path $TestDrive 'dl2'
        $global:ztpRunBehavior['Start-MaintenanceBoot.ps1'] = { param($p) foreach ($n in $p['NodeName']) { [pscustomobject]@{ Node = $n; WriteProtected = $true; Restarted = $true } } }
        { & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false; SourcePath = $null; BootstrapCacheDirectory = $cache } } | Should -Throw '*write-protected*'
        $global:ztpRunCalls.Clear(); $global:ztpRunBehavior = & $script:healthy
        $null = & $script:invoke @{ Execute = $true; Stage = 'Media'; Confirm = $false; SourcePath = $null; BootstrapCacheDirectory = $cache }
        ($global:ztpRunCalls | Where-Object Script -EQ 'New-ZtpVirtualUsbImage.ps1').Params.SourcePath | Should -Be (Join-Path $cache 'provision-os.iso')
    }

    It 'Bootstrap watches the Configurator App folder without a BMC credential when -VoucherFolder is given' {
        $null = & $script:invoke @{ Execute = $true; Stage = 'Bootstrap'; VoucherFolder = 'D:\Downloads\vouchers'; SkipAzureCheck = $true; Confirm = $false }
        $w = $global:ztpRunCalls[0]
        $w.Script | Should -Be 'Wait-ZtpBootstrapComplete.ps1'; $w.Params.VoucherFolder | Should -Be 'D:\Downloads\vouchers'; $w.Params.ContainsKey('Credential') | Should -BeFalse; $w.Params.SkipAzureCheck | Should -BeTrue
    }

    It 'stops at a stage whose result fails its check and resumes there on the next run' {
        $global:ztpRunBehavior['Start-MaintenanceBoot.ps1'] = { param($p) foreach ($n in $p['NodeName']) { [pscustomobject]@{ Node = $n; WriteProtected = $true; Restarted = $true } } }
        { & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false } } | Should -Throw '*write-protected*'
        & $script:called | Should -Not -Contain 'Wait-ZtpVoucher.ps1'
        $global:ztpRunCalls.Clear()
        $global:ztpRunBehavior = & $script:healthy
        $null = & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false }
        (& $script:called)[0] | Should -Be 'Start-MaintenanceBoot.ps1'
    }

    It 'takes Configurator App vouchers with -Stage Vouchers -VoucherFolder, ejects the media and removes the share' {
        $null = & $script:invoke @{ Execute = $true; Stage = 'Vouchers'; VoucherFolder = 'D:\Downloads\vouchers'; BmcCredential = $script:bmc; Confirm = $false }
        & $script:called | Should -Be @('Wait-ZtpVoucher.ps1', 'Mount-ZtpVirtualUsb.ps1', 'Publish-MaintenanceIso.ps1')
        $global:ztpRunCalls[0].Params.ContainsKey('ImageDirectory') | Should -BeFalse
        $global:ztpRunCalls[1].Params.Action | Should -Be 'Eject'
    }

    It 'refuses to submit the Azure deployment when the plan reports voucher problems' {
        $global:ztpRunBehavior['Invoke-ZtpAzureProvisioning.ps1'] = { param($p) if ($p['Stage'] -eq 'Plan') { [pscustomobject]@{ VoucherProblems = @('node-02: no voucher EXAMPLE2.pem') } } }
        { & $script:invoke @{ Execute = $true; Stage = 'Azure'; Confirm = $false } } | Should -Throw '*voucher problems*'
        @($global:ztpRunCalls | ForEach-Object { $_.Params['Stage'] }) | Should -Not -Contain 'Execute'
    }

    It 'reruns from a stage with -From and refuses a state recorded for other machines' {
        $null = & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false; NodeName = 'node-01' }
        $global:ztpRunCalls.Clear()
        $null = & $script:invoke @{ Execute = $true; From = 'Azure'; Confirm = $false; NodeName = 'node-01' }
        (& $script:called | Select-Object -Unique) | Should -Be @('Invoke-ZtpAzureProvisioning.ps1', 'Test-ProvisionedMachines.ps1', 'Set-ZtpManagementAddress.ps1', 'Restore-ZtpBios.ps1', 'New-ZtpHandoff.ps1', 'Convert-ZtpHandoffToClusterInputs.ps1')
        { & $script:invoke @{ Execute = $true; From = 'Ready'; Confirm = $false } } | Should -Throw '*records nodes node-01*'
    }

    It 'reads its settings from -ConfigPath, lets a parameter win and rejects unknown keys' {
        $config = Join-Path $TestDrive 'settings.json'
        @{ NodesFile = $script:nodesFile; SourcePath = 'D:\Media\from-file.iso'; ImageDirectory = $script:images; ShareHost = '192.0.2.20'; ImageNamePrefix = 'usb-'; VoucherDirectory = $script:vouchers; SubscriptionId = '00000000-0000-0000-0000-000000000000'; ResourceGroupName = 'rg-example'; ParameterFile = 'main.parameters.json' } | ConvertTo-Json | Set-Content -LiteralPath $config
        $null = & $script:orchestrator -ConfigPath $config -SourcePath 'D:\Media\from-parameter.iso' -StageScriptRoot $script:stubRoot -StatePath $script:statePath -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        $global:ztpRunCalls[0].Params.SourcePath | Should -Be 'D:\Media\from-parameter.iso'
        $global:ztpRunCalls[0].Params.ImageNamePrefix | Should -Be 'usb-'
        @{ NodesFile = $script:nodesFile; Password = 'x' } | ConvertTo-Json | Set-Content -LiteralPath $config
        { & $script:orchestrator -ConfigPath $config -StageScriptRoot $script:stubRoot -StatePath $script:statePath -InformationAction SilentlyContinue } | Should -Throw "*Unknown key 'Password'*"
    }

    It 'ships a neutral settings example whose keys the script accepts' {
        $example = Join-Path $script:repoRoot 'config/simplified-provisioning/ztp-provisioning.example.json'
        $text = Get-Content -LiteralPath $example -Raw
        $text | Should -Match '192\.0\.2\.10'
        $text | Should -Match '00000000-0000-0000-0000-000000000000'
        $params = (Get-Command $script:orchestrator).Parameters.Keys
        foreach ($key in ($text | ConvertFrom-Json -AsHashtable).Keys) { if ($key -ne '$schema') { $params | Should -Contain $key } }
    }

    It 'validates the settings example and the node example against their JSON schemas and rejects unknown keys' {
        $dir = Join-Path $script:repoRoot 'config/simplified-provisioning'
        Test-Json -Json (Get-Content (Join-Path $dir 'ztp-provisioning.example.json') -Raw) -SchemaFile (Join-Path $dir 'ztp-provisioning.schema.json') | Should -BeTrue
        Test-Json -Json (Get-Content (Join-Path $dir 'nodes.example.json') -Raw) -SchemaFile (Join-Path $dir 'nodes.schema.json') | Should -BeTrue
        Test-Json -Json '{ "Password": "x" }' -SchemaFile (Join-Path $dir 'ztp-provisioning.schema.json') -ErrorAction SilentlyContinue | Should -BeFalse
        Test-Json -Json '{ "nodes": [ { "name": "n1" } ] }' -SchemaFile (Join-Path $dir 'nodes.schema.json') -ErrorAction SilentlyContinue | Should -BeFalse
        # every parameter-backed setting of the orchestrator is described by the schema
        $schemaKeys = ((Get-Content (Join-Path $dir 'ztp-provisioning.schema.json') -Raw | ConvertFrom-Json -AsHashtable).properties).Keys
        foreach ($key in ($text = Get-Content (Join-Path $dir 'ztp-provisioning.example.json') -Raw | ConvertFrom-Json -AsHashtable).Keys) { $schemaKeys | Should -Contain $key }
    }
}

Describe 'Invoke-ZtpProvisioning.ps1 settings that used to be fixed in the stage scripts (schema 5.4)' {
    BeforeEach {
        $global:ztpRunCalls = [System.Collections.Generic.List[object]]::new()
        $global:ztpRunBehavior = & $script:healthy
        $script:statePath = Join-Path $TestDrive "state-$([guid]::NewGuid().ToString('N')).json"
        Get-ChildItem -LiteralPath $script:vouchers, $script:images -File | Remove-Item -Force
    }

    It 'passes nothing extra to the stages when none of the settings is given (the stage scripts keep their own defaults)' {
        $null = & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false }
        $media = $global:ztpRunCalls | Where-Object Script -EQ 'New-ZtpVirtualUsbImage.ps1'
        $media.Params.ContainsKey('SizeBytes') | Should -BeFalse
        ($global:ztpRunCalls | Where-Object Script -EQ 'Start-MaintenanceBoot.ps1').Params.ContainsKey('AccountName') | Should -BeFalse
        ($global:ztpRunCalls | Where-Object Script -EQ 'Set-ZtpDeviceConfiguration.ps1').Params.ContainsKey('Port') | Should -BeFalse
        ($global:ztpRunCalls | Where-Object Script -EQ 'Set-ZtpDeviceConfiguration.ps1').Params.ContainsKey('UserName') | Should -BeFalse
        ($global:ztpRunCalls | Where-Object Script -EQ 'Wait-ZtpBootstrapComplete.ps1').Params.ContainsKey('StallMinutes') | Should -BeFalse
    }

    It 'passes the image size, the share account, the Configurator port and user, and the stall budget to their stages' {
        $null = & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false; ImageSizeGB = 6; ShareAccountName = 'svc-example'; MaintenancePort = 20011; MaintenanceUser = 'example-user'; BootstrapStallMinutes = 45; BiosTimeoutMinutes = 50 }
        ($global:ztpRunCalls | Where-Object Script -EQ 'New-ZtpVirtualUsbImage.ps1').Params.SizeBytes | Should -Be (6GB)
        $boot = ($global:ztpRunCalls | Where-Object Script -EQ 'Start-MaintenanceBoot.ps1').Params
        $boot.AccountName | Should -Be 'svc-example'
        $boot.BiosTimeoutMinutes | Should -Be 50
        ($global:ztpRunCalls | Where-Object Script -EQ 'Publish-MaintenanceIso.ps1').Params.AccountName | Should -Be 'svc-example' -Because 'the share is removed with the same account name it was created with'
        $device = ($global:ztpRunCalls | Where-Object Script -EQ 'Set-ZtpDeviceConfiguration.ps1').Params
        $device.Port | Should -Be 20011
        $device.UserName | Should -Be 'example-user'
        ($global:ztpRunCalls | Where-Object Script -EQ 'Wait-ZtpBootstrapComplete.ps1').Params.StallMinutes | Should -Be 45
    }

    It 'reads the same settings from the settings file' {
        $cfg = Join-Path $TestDrive 'settings54.json'
        Set-Content -LiteralPath $cfg -Value '{ "ImageSizeGB": 8, "MaintenancePort": 20012, "ShareAccountName": "svc-file" }'
        $null = & $script:invoke @{ ConfigPath = $cfg; Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false }
        ($global:ztpRunCalls | Where-Object Script -EQ 'New-ZtpVirtualUsbImage.ps1').Params.SizeBytes | Should -Be (8GB)
        ($global:ztpRunCalls | Where-Object Script -EQ 'Set-ZtpDeviceConfiguration.ps1').Params.Port | Should -Be 20012
        ($global:ztpRunCalls | Where-Object Script -EQ 'Start-MaintenanceBoot.ps1').Params.AccountName | Should -Be 'svc-file'
    }

    It 'rejects a share account name the stage would refuse' {
        { & $script:invoke @{ ShareAccountName = 'not valid!' } } | Should -Throw
    }
}