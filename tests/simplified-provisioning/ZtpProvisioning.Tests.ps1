#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
# Invoke-ZtpProvisioning.ps1: stage order, plan by default, -Execute, result checks between stages, resumable state,
# -Stage/-From, the Configurator App fallback and the settings file. Every stage script is a stub in TestDrive that records
# its parameters; nothing touches a BMC, a machine or Azure.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Stub scripts report through globals.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Only a synthetic test credential is converted.')]
param()

BeforeAll {
    $script:repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:orchestrator = Join-Path $script:repoRoot 'scripts/simplified-provisioning/Invoke-ZtpProvisioning.ps1'
    $script:stubRoot = Join-Path $TestDrive 'stubs'
    $null = New-Item -ItemType Directory -Path $script:stubRoot -Force
    $names = 'SourcePath', 'NodeName', 'NodesFile', 'OutputDirectory', 'ImageNamePrefix', 'EdgeUserPassword', 'Force', 'Execute', 'ImageDirectory',
    'ShareName', 'ShareHost', 'Restart', 'ConfirmNotClustered', 'RfsWriteAttribute', 'SkipCertificateCheck', 'Credential', 'VoucherFolder',
    'TimeoutMinutes', 'Action', 'Remove', 'SharePath', 'Stage', 'SubscriptionId', 'ResourceGroupName', 'ParameterFile', 'VoucherPath', 'OsVersion',
    'SiteMode', 'Node', 'DeploymentName', 'AdminPassword', 'PollIntervalSeconds', 'RetryProvisionOs', 'ArcMachineNameMapPath', 'ExpectedMachineName'
    $paramBlock = ($names | ForEach-Object { "[object]`$$_" }) -join ', '
    foreach ($script in 'New-ZtpVirtualUsbImage.ps1', 'Start-MaintenanceBoot.ps1', 'Wait-ZtpVoucher.ps1', 'Mount-ZtpVirtualUsb.ps1', 'Publish-MaintenanceIso.ps1',
        'Invoke-ZtpAzureProvisioning.ps1', 'Test-ProvisionedMachines.ps1') {
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
            'Start-MaintenanceBoot.ps1'       = { param($p) if ($p['Execute']) { foreach ($n in $p['NodeName']) { [pscustomobject]@{ Node = $n; Image = "ztp-usb-$n.img"; WriteProtected = $false; Restarted = $true } } } }
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
            InformationAction = 'SilentlyContinue'; WarningAction = 'SilentlyContinue'
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

    It 'runs Media -> Boot -> Vouchers -> Azure -> Ready in order and records every stage' {
        $rows = & $script:invoke @{ Execute = $true; ConfirmNotClustered = $true; BmcCredential = $script:bmc; Confirm = $false }
        & $script:called | Should -Be @('New-ZtpVirtualUsbImage.ps1', 'Start-MaintenanceBoot.ps1', 'Wait-ZtpVoucher.ps1', 'Publish-MaintenanceIso.ps1',
            'Invoke-ZtpAzureProvisioning.ps1', 'Invoke-ZtpAzureProvisioning.ps1', 'Invoke-ZtpAzureProvisioning.ps1', 'Invoke-ZtpAzureProvisioning.ps1',
            'Invoke-ZtpAzureProvisioning.ps1', 'Test-ProvisionedMachines.ps1')
        @($rows | ForEach-Object Stage) | Should -Be @('Media', 'Boot', 'Vouchers', 'Azure', 'Ready')
        @($global:ztpRunCalls | Where-Object Script -EQ 'Invoke-ZtpAzureProvisioning.ps1' | ForEach-Object { $_.Params.Stage }) | Should -Be @('Prereqs', 'Validate', 'Plan', 'Execute', 'Watch')
        $boot = $global:ztpRunCalls | Where-Object Script -EQ 'Start-MaintenanceBoot.ps1'
        $boot.Params.Restart | Should -BeTrue
        $boot.Params.Credential | Should -Be $script:bmc
        $test = $global:ztpRunCalls | Where-Object Script -EQ 'Test-ProvisionedMachines.ps1'
        $test.Params.ResourceGroupName | Should -Be 'rg-example'
        $test.Params.ExpectedMachineName | Should -Be @('00000000-0000-0000-0000-000000000000-1', '00000000-0000-0000-0000-000000000000-2')
        $state = Get-Content $script:statePath -Raw | ConvertFrom-Json -AsHashtable
        @($state.stages.Keys).Count | Should -Be 5
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
        (& $script:called | Select-Object -Unique) | Should -Be @('Invoke-ZtpAzureProvisioning.ps1', 'Test-ProvisionedMachines.ps1')
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
        foreach ($key in ($text | ConvertFrom-Json -AsHashtable).Keys) { $params | Should -Contain $key }
    }
}
