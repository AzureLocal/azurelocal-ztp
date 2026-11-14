#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
# BIOS settings before the maintenance boot: ZtpBios.Common.ps1 (node list lookup, comparison, typing), Set-ZtpBios.ps1
# against a stubbed Redfish BMC (plan, idempotent apply, pending values, unknown attributes, timeout, change log), and the
# Boot stage wiring in Start-MaintenanceBoot.ps1. No BMC is contacted: the Redfish functions are global stubs, which the
# scripts use instead of dot-sourcing ZtpRedfish.Common.ps1.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The stub BMC keeps its state in globals.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Only a synthetic test secret is converted.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signatures mirror the real functions.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'BIOS is an acronym; Settings and Nodes name the helpers'' subject.')]
param()

BeforeAll {
    $script:root = Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) 'scripts/simplified-provisioning'
    . (Join-Path $script:root 'ZtpBios.Common.ps1')
    $script:setBios = Join-Path $script:root 'Set-ZtpBios.ps1'
    $script:bmc = [pscredential]::new('iic-bmc-user', (ConvertTo-SecureString 'Iic-Not-A-Secret-1' -AsPlainText -Force))

    # The stub BMC: current BIOS values, values pending for the next reset, power state, and every request.
    function global:Reset-TestBmc {
        param([hashtable]$Current, [string]$Power = 'On', [hashtable]$Pending = @{}, [bool]$ApplyOnReset = $true)
        $global:biosT_current = [ordered]@{}; foreach ($k in $Current.Keys) { $global:biosT_current[$k] = $Current[$k] }
        $global:biosT_pending = [ordered]@{}; foreach ($k in $Pending.Keys) { $global:biosT_pending[$k] = $Pending[$k] }
        $global:biosT_power = $Power
        $global:biosT_apply = $ApplyOnReset
        $global:biosT_calls = [System.Collections.Generic.List[object]]::new()
    }
    function global:New-ZtpRedfishSession { param([string]$BmcAddress, [pscredential]$Credential, [switch]$SkipCertificateCheck) $global:biosT_calls.Add([pscustomobject]@{ Method = 'Session'; Path = $BmcAddress; Body = $null }); 'test-session' }
    function global:Remove-ZtpRedfishSession { param($Session) }
    function global:Get-ZtpRedfishSystem { param($Session, [string]$SystemId) [pscustomobject]@{ '@odata.id' = '/redfish/v1/Systems/System.Embedded.1'; Bios = [pscustomobject]@{ '@odata.id' = '/redfish/v1/Systems/System.Embedded.1/Bios' } } }
    function global:Invoke-ZtpRedfish {
        param($Session, [string]$Path, [string]$Method = 'Get', [hashtable]$Body, [int]$MaxAttempts)
        $global:biosT_calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body })
        switch -Wildcard ("$Method $Path") {
            'Get */Bios' { return [pscustomobject]@{ Attributes = [pscustomobject]$global:biosT_current; '@Redfish.Settings' = [pscustomobject]@{ SettingsObject = [pscustomobject]@{ '@odata.id' = '/redfish/v1/Systems/System.Embedded.1/Bios/Settings' } } } }
            'Get */Bios/Settings' { return [pscustomobject]@{ Attributes = [pscustomobject]$global:biosT_pending } }
            'Patch */Bios/Settings' { foreach ($k in $Body.Attributes.Keys) { $global:biosT_pending[$k] = $Body.Attributes[$k] }; return $null }
            'Get */System.Embedded.1' { return [pscustomobject]@{ PowerState = $global:biosT_power } }
            'Post */ComputerSystem.Reset' {
                $global:biosT_power = 'On'
                if ($global:biosT_apply) { foreach ($k in @($global:biosT_pending.Keys)) { $global:biosT_current[$k] = $global:biosT_pending[$k] }; $global:biosT_pending.Clear() }
                return $null
            }
        }
    }
    $script:run = {
        param([hashtable]$Arguments)
        $base = @{ NodeName = 'node-01'; BmcAddress = '198.51.100.11'; Attributes = [ordered]@{ Slot2 = 'Disabled'; EmbNic1Nic2 = 'Enabled' }; PollSeconds = 1; InformationAction = 'SilentlyContinue' }
        foreach ($k in $Arguments.Keys) { $base[$k] = $Arguments[$k] }
        & $script:setBios @base
    }
    $script:writes = { @($global:biosT_calls | Where-Object { $_.Method -in 'Patch', 'Post' }) }
}

AfterAll {
    foreach ($name in 'Reset-TestBmc', 'New-ZtpRedfishSession', 'Remove-ZtpRedfishSession', 'Get-ZtpRedfishSystem', 'Invoke-ZtpRedfish') { Remove-Item "Function:global:$name" -ErrorAction SilentlyContinue }
    Get-Variable -Scope Global -Name 'biosT_*' -ErrorAction SilentlyContinue | Remove-Variable -Scope Global -Force -ErrorAction SilentlyContinue
}

Describe 'Comparing BIOS values' {
    It 'lists only the attributes that differ, in the type the BIOS reports' {
        $current = [pscustomobject]@{ Slot2 = 'Enabled'; EmbNic1Nic2 = 'Enabled'; ProcCores = 32; SriovGlobalEnable = $false }
        $changes = @(Get-ZtpBiosChange -Current $current -Desired ([ordered]@{ Slot2 = 'Disabled'; EmbNic1Nic2 = 'Enabled'; ProcCores = '16'; SriovGlobalEnable = 'true' }))
        $changes.Attribute | Should -Be @('Slot2', 'ProcCores', 'SriovGlobalEnable')
        $changes[0].Current | Should -Be 'Enabled'; $changes[0].Value | Should -Be 'Disabled'
        $changes[1].Value | Should -BeOfType [long]; $changes[1].Value | Should -Be 16
        $changes[2].Value | Should -BeOfType [bool]; $changes[2].Value | Should -BeTrue
    }
    It 'compares case-sensitively and treats a boolean written in lowercase as equal' {
        @(Get-ZtpBiosChange -Current ([pscustomobject]@{ Slot2 = 'disabled' }) -Desired @{ Slot2 = 'Disabled' }).Count | Should -Be 1
        @(Get-ZtpBiosChange -Current ([pscustomobject]@{ Flag = $true }) -Desired @{ Flag = 'true' }).Count | Should -Be 0
    }
    It 'refuses an attribute the BIOS does not have, naming it, and a value of the wrong type' {
        { Get-ZtpBiosChange -Current ([pscustomobject]@{ Slot2 = 'Enabled' }) -Desired @{ slot2 = 'Disabled' } } | Should -Throw '*no attribute slot2*case-sensitive*'
        { Get-ZtpBiosChange -Current ([pscustomobject]@{ ProcCores = 32 }) -Desired @{ ProcCores = 'all' } } | Should -Throw "*ProcCores is a number; 'all' isn't one*"
    }
    It 'reads a node''s bios from a JSON node list (objects) or a YAML one (mappings), and nothing for a node without it' {
        $json = '{ "nodes": [ { "name": "node-01", "bios": { "Slot2": "Disabled" } }, { "name": "node-02" } ] }' | ConvertFrom-Json
        (Get-ZtpNodeBiosSetting -NodeName node-01 -Nodes $json.nodes)['Slot2'] | Should -Be 'Disabled'
        (Get-ZtpNodeBiosSetting -NodeName node-02 -Nodes $json.nodes).Count | Should -Be 0
        (Get-ZtpNodeBiosSetting -NodeName node-01 -Nodes @([ordered]@{ name = 'node-01'; bios = [ordered]@{ EmbNic1Nic2 = 'Enabled' } }))['EmbNic1Nic2'] | Should -Be 'Enabled'
    }
}

Describe 'Set-ZtpBios.ps1' {
    BeforeEach { Reset-TestBmc -Current @{ Slot2 = 'Enabled'; EmbNic1Nic2 = 'DisabledOs'; SysProfile = 'PerfOptimized' } }

    It 'plans without a BMC call when no credential is given' {
        $out = @(& $script:run @{})
        $out[0] | Should -BeLike 'PLAN: node-01 BIOS Slot2=Disabled, EmbNic1Nic2=Enabled (reads the current values first*'
        $global:biosT_calls.Count | Should -Be 0
    }
    It 'plans from the current values with a credential, and changes nothing' {
        $out = @(& $script:run @{ Credential = $script:bmc })
        $out | Should -Contain 'PLAN: node-01 BIOS Slot2 Enabled -> Disabled'
        $out | Should -Contain 'PLAN: node-01 BIOS EmbNic1Nic2 DisabledOs -> Enabled'
        @(& $script:writes).Count | Should -Be 0
    }
    It 'refuses -Execute without -ConfirmNotClustered or a credential' {
        { & $script:run @{ Credential = $script:bmc; Execute = $true; Confirm = $false } } | Should -Throw '*ConfirmNotClustered*'
        { & $script:run @{ ConfirmNotClustered = $true; Execute = $true; Confirm = $false } } | Should -Throw '*-Credential*'
    }
    It 'PATCHes only what differs to Bios/Settings OnReset, restarts, waits for the BIOS to report it and logs every change' {
        $global:biosT_current['EmbNic1Nic2'] = 'Enabled'
        $log = Join-Path $TestDrive 'evidence/bios-changes.jsonl'
        $row = & $script:run @{ Credential = $script:bmc; ConfirmNotClustered = $true; Execute = $true; Confirm = $false; ChangeLogPath = $log }
        $row.Status | Should -Be 'Changed'
        $row.Changes | Should -Be @('Slot2: Enabled -> Disabled')
        $patch = @($global:biosT_calls | Where-Object Method -EQ 'Patch')
        $patch.Count | Should -Be 1
        $patch[0].Path | Should -Be '/redfish/v1/Systems/System.Embedded.1/Bios/Settings'
        @($patch[0].Body.Attributes.Keys) | Should -Be @('Slot2')
        $patch[0].Body['@Redfish.SettingsApplyTime'].ApplyTime | Should -Be 'OnReset'
        $reset = @($global:biosT_calls | Where-Object Method -EQ 'Post')
        $reset[0].Body.ResetType | Should -Be 'ForceRestart'
        $global:biosT_current['Slot2'] | Should -Be 'Disabled'
        $lines = @(Get-Content -LiteralPath $log | ForEach-Object { $_ | ConvertFrom-Json })
        $lines.phase | Should -Be @('original', 'requested', 'applied') -Because 'the value found is logged before the first change, for the Restore stage'
        $lines[0].attribute | Should -Be 'Slot2'; $lines[0].before | Should -Be 'Enabled'; $lines[0].after | Should -Be 'Enabled'; $lines[0].node | Should -Be 'node-01'
        $lines[1].attribute | Should -Be 'Slot2'; $lines[1].before | Should -Be 'Enabled'; $lines[1].after | Should -Be 'Disabled'
        $row.Original['Slot2'] | Should -Be 'Enabled' -Because 'the value found goes to the run state for the Restore stage'
        $row.Original['EmbNic1Nic2'] | Should -Be 'Enabled' -Because 'every requested attribute is recorded, changed or not'
    }
    It 'powers a node that is off on to apply the settings' {
        Reset-TestBmc -Current @{ Slot2 = 'Enabled'; EmbNic1Nic2 = 'Enabled' } -Power 'Off'
        $null = & $script:run @{ Credential = $script:bmc; ConfirmNotClustered = $true; Execute = $true; Confirm = $false }
        @($global:biosT_calls | Where-Object Method -EQ 'Post')[0].Body.ResetType | Should -Be 'On'
    }
    It 'changes and restarts nothing when the BIOS already holds every value' {
        Reset-TestBmc -Current @{ Slot2 = 'Disabled'; EmbNic1Nic2 = 'Enabled' }
        $row = & $script:run @{ Credential = $script:bmc; ConfirmNotClustered = $true; Execute = $true; Confirm = $false }
        $row.Status | Should -Be 'AlreadySet'
        @(& $script:writes).Count | Should -Be 0
    }
    It 'does not send a value again that is already pending, but still applies it' {
        Reset-TestBmc -Current @{ Slot2 = 'Enabled'; EmbNic1Nic2 = 'Enabled' } -Pending @{ Slot2 = 'Disabled' }
        $row = & $script:run @{ Credential = $script:bmc; ConfirmNotClustered = $true; Execute = $true; Confirm = $false }
        @($global:biosT_calls | Where-Object Method -EQ 'Patch').Count | Should -Be 0
        @($global:biosT_calls | Where-Object Method -EQ 'Post').Count | Should -Be 1
        $row.Status | Should -Be 'Changed'
    }
    It 'stops before any change when an attribute is unknown' {
        { & $script:run @{ Credential = $script:bmc; ConfirmNotClustered = $true; Execute = $true; Confirm = $false; Attributes = @{ Slot2 = 'Disabled'; NoSuchAttribute = 'x' } } } | Should -Throw '*no attribute NoSuchAttribute*'
        @(& $script:writes).Count | Should -Be 0
    }
    It 'fails, naming what is still different, when the BIOS does not report the values in time' {
        Reset-TestBmc -Current @{ Slot2 = 'Enabled'; EmbNic1Nic2 = 'Enabled' } -ApplyOnReset $false
        { & $script:run @{ Credential = $script:bmc; ConfirmNotClustered = $true; Execute = $true; Confirm = $false; TimeoutMinutes = 0 } } | Should -Throw '*BIOS still reports Slot2=Enabled 0 minutes after the ForceRestart*'
    }
}

Describe 'BIOS in the Boot stage (Start-MaintenanceBoot.ps1)' {
    BeforeAll {
        $script:bin = Join-Path $TestDrive 'boot-bin'
        $null = New-Item -ItemType Directory -Path $script:bin
        Copy-Item -Path (Join-Path $script:root 'Start-MaintenanceBoot.ps1'), (Join-Path $script:root '*.Common.ps1') -Destination $script:bin
        Set-Content -LiteralPath (Join-Path $script:bin 'Publish-MaintenanceIso.ps1') -Value @'
[CmdletBinding(SupportsShouldProcess)]
param([string[]]$IsoPath, $SharePath, $ShareName, $ShareHost, $AllowedBmcAddress, $ReadWrite, [switch]$Execute)
if (-not $Execute) { return 'PLAN: share' }
[pscustomobject]@{ Credential = $null; Images = @($IsoPath | ForEach-Object { [pscustomobject]@{ ImagePath = "//$ShareHost/$ShareName/$(Split-Path $_ -Leaf)"; Sha256 = 'AB' } }) }
'@
        # The mount records when it ran, so the test can prove the BIOS step came first.
        Set-Content -LiteralPath (Join-Path $script:bin 'Mount-ZtpVirtualUsb.ps1') -Value @'
[CmdletBinding(SupportsShouldProcess)]
param($ShareHost, $ShareName, $ImageNamePrefix, $ReadOnly, $RfsWriteAttribute, $Restart, $ConfirmNotClustered, $SkipCertificateCheck, $NodesFile, $Nodes, [string[]]$NodeName, $Credential, $ShareCredential, [switch]$Execute)
if (-not $Execute) { return "PLAN: mount $($NodeName -join ',')" }
# The nodes run in parallel runspaces: retry when the other one holds the file.
foreach ($try in 1..50) { try { Add-Content -LiteralPath (Join-Path $env:ZTP_TEST_BIOS_DIR 'order.txt') -Value "mount $($NodeName[0])" -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 20 } }
[pscustomobject]@{ Node = $NodeName[0]; Image = "//$ShareHost/$ShareName/ztp-usb-$($NodeName[0]).img"; WriteProtected = $false }
'@
        Set-Content -LiteralPath (Join-Path $script:bin 'Set-ZtpBios.ps1') -Value @'
[CmdletBinding(SupportsShouldProcess)]
param([string]$NodeName, [string]$BmcAddress, [System.Collections.IDictionary]$Attributes, $Credential, $ChangeLogPath, $TimeoutMinutes, $PollSeconds, [switch]$ConfirmNotClustered, [switch]$SkipCertificateCheck, [switch]$Execute)
if (-not $Execute) { return "PLAN: $NodeName BIOS $(@($Attributes.Keys | ForEach-Object { "$_=$($Attributes[$_])" }) -join ', ') on $BmcAddress" }
# The nodes run in parallel runspaces: retry when the other one holds the file.
foreach ($try in 1..50) { try { Add-Content -LiteralPath (Join-Path $env:ZTP_TEST_BIOS_DIR 'order.txt') -Value "bios $NodeName $ChangeLogPath" -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 20 } }
[pscustomobject]@{ Node = $NodeName; Bmc = $BmcAddress; Status = 'Changed'; Changes = @($Attributes.Keys | ForEach-Object { "${_}: Enabled -> $($Attributes[$_])" }) }
'@
        $script:images = Join-Path $TestDrive 'boot-images'
        $null = New-Item -ItemType Directory -Path $script:images
        foreach ($n in 'node-01', 'node-02') { Set-Content -LiteralPath (Join-Path $script:images "ztp-usb-$n.img") -Value 'x' }
        $script:nodesFile = Join-Path $TestDrive 'boot-nodes.json'
        @{ nodes = @(
                [ordered]@{ name = 'node-01'; service_tag = 'IICSN0001'; bmc_address = '198.51.100.11'; bios = [ordered]@{ Slot2 = 'Disabled' } }
                [ordered]@{ name = 'node-02'; service_tag = 'IICSN0002'; bmc_address = '198.51.100.12' }
            ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:nodesFile
        $script:boot = Join-Path $script:bin 'Start-MaintenanceBoot.ps1'
    }

    It 'shows the BIOS plan for the nodes that have bios, and none for the others' {
        $out = @(& $script:boot -ImageDirectory $script:images -ShareHost 192.0.2.10 -NodeName node-01, node-02 -NodesFile $script:nodesFile)
        $out | Should -Contain 'PLAN: node-01 BIOS Slot2=Disabled on 198.51.100.11'
        @($out | Where-Object { $_ -like 'PLAN: node-02 BIOS*' }).Count | Should -Be 0
    }
    It 'sets the BIOS before the mount, with the change log, and reports the changes on the node''s row' {
        $dir = Join-Path $TestDrive 'boot-order'; $null = New-Item -ItemType Directory -Force -Path $dir
        $env:ZTP_TEST_BIOS_DIR = $dir
        try { $rows = @(& $script:boot -ImageDirectory $script:images -ShareHost 192.0.2.10 -NodeName node-01, node-02 -NodesFile $script:nodesFile -Credential $script:bmc -Restart -ConfirmNotClustered -BiosLogPath (Join-Path $TestDrive 'ev/bios-changes.jsonl') -Execute -Confirm:$false) }
        finally { $env:ZTP_TEST_BIOS_DIR = $null }
        $order = @(Get-Content -LiteralPath (Join-Path $dir 'order.txt'))
        $node1 = @($order | Where-Object { $_ -like '* node-01*' })
        $node1[0] | Should -BeLike 'bios node-01 *ev*bios-changes.jsonl'
        $node1[1] | Should -Be 'mount node-01'
        @($order | Where-Object { $_ -like 'bios node-02*' }).Count | Should -Be 0
        ($rows | Where-Object Node -EQ 'node-01').Bios | Should -Be @('Slot2: Enabled -> Disabled')
        @(($rows | Where-Object Node -EQ 'node-02').Bios).Count | Should -Be 0
    }
    It 'refuses to apply BIOS settings without -Restart' {
        { & $script:boot -ImageDirectory $script:images -ShareHost 192.0.2.10 -NodeName node-01 -NodesFile $script:nodesFile -Credential $script:bmc -Execute -Confirm:$false } | Should -Throw '*BIOS settings are applied with a restart*'
    }
}

Describe 'Derived BIOS attributes: the reason, and the check before anything changes' {
    BeforeAll {
        $script:reason = [ordered]@{ Slot9 = 'derived: nodes[0].san.hbas[0] is in Slot 9, so ZTP looked for the BIOS attribute Slot9; check the slot label' }
    }

    It 'names the reason when the BIOS has no such attribute, and an attribute the file wrote only by its name' {
        $current = [pscustomobject]@{ Slot2 = 'Enabled' }
        { Get-ZtpBiosChange -Current $current -Desired ([ordered]@{ Slot9 = 'Disabled' }) -Reason $script:reason } | Should -Throw '*no attribute Slot9 (derived: nodes[[]0].san.hbas[[]0] is in Slot 9*check the slot label)*'
        { Get-ZtpBiosChange -Current $current -Desired ([ordered]@{ Slot9 = 'Disabled' }) } | Should -Throw '*no attribute Slot9. Attribute names are case-sensitive*'
        $plain = try { Get-ZtpBiosChange -Current $current -Desired ([ordered]@{ Slot9 = 'Disabled' }); '' } catch { $_.Exception.Message }
        $plain | Should -Not -BeLike '*derived*'
    }

    It 'reads the reasons of a node from the node list and nothing for a node without any' {
        $nodes = @(
            [ordered]@{ name = 'node-01'; bios = [ordered]@{ Slot2 = 'Disabled' }; bios_reason = [ordered]@{ Slot2 = 'derived: why' } }
            [pscustomobject]@{ name = 'node-02'; bios = [pscustomobject]@{ Slot2 = 'Disabled' }; bios_reason = [pscustomobject]@{ Slot2 = 'derived: json' } }
            [ordered]@{ name = 'node-03' })
        (Get-ZtpNodeBiosReason -NodeName 'node-01' -Nodes $nodes)['Slot2'] | Should -Be 'derived: why'
        (Get-ZtpNodeBiosReason -NodeName 'node-02' -Nodes $nodes)['Slot2'] | Should -Be 'derived: json'
        (Get-ZtpNodeBiosReason -NodeName 'node-03' -Nodes $nodes).Count | Should -Be 0
    }

    It 'Set-ZtpBios.ps1 stops before it writes anything and says why ZTP looked for the missing slot' {
        Reset-TestBmc -Current @{ Slot2 = 'Enabled'; EmbNic1Nic2 = 'DisabledOs' }
        $message = try { & $script:run @{ Attributes = [ordered]@{ Slot9 = 'Disabled' }; Reason = $script:reason; Credential = $script:bmc; ConfirmNotClustered = $true; Execute = $true; Confirm = $false }; '' } catch { $_.Exception.Message }
        $message | Should -BeLike '*no attribute Slot9 (derived: nodes[[]0].san.hbas[[]0] is in Slot 9*'
        @(& $script:writes).Count | Should -Be 0
    }
}

Describe 'Boot reads every node''s BIOS before it changes one' {
    BeforeAll {
        $script:bin2 = Join-Path $TestDrive 'boot-bin2'
        $null = New-Item -ItemType Directory -Path $script:bin2
        Copy-Item -Path (Join-Path $script:root 'Start-MaintenanceBoot.ps1'), (Join-Path $script:root '*.Common.ps1') -Destination $script:bin2
        Set-Content -LiteralPath (Join-Path $script:bin2 'Publish-MaintenanceIso.ps1') -Value @'
[CmdletBinding(SupportsShouldProcess)]
param([string[]]$IsoPath, $SharePath, $ShareName, $ShareHost, $AllowedBmcAddress, $ReadWrite, $AccountName, [switch]$Execute)
if ($Execute) { Add-Content -LiteralPath (Join-Path $env:ZTP_TEST_BIOS_DIR 'order.txt') -Value "publish $AccountName" }
if (-not $Execute) { return 'PLAN: share' }
[pscustomobject]@{ Credential = $null; Images = @($IsoPath | ForEach-Object { [pscustomobject]@{ ImagePath = "//$ShareHost/$ShareName/$(Split-Path $_ -Leaf)"; Sha256 = 'AB' } }) }
'@
        Set-Content -LiteralPath (Join-Path $script:bin2 'Mount-ZtpVirtualUsb.ps1') -Value @'
[CmdletBinding(SupportsShouldProcess)]
param($ShareHost, $ShareName, $ImageNamePrefix, $ReadOnly, $RfsWriteAttribute, $Restart, $ConfirmNotClustered, $SkipCertificateCheck, $NodesFile, $Nodes, [string[]]$NodeName, $Credential, $ShareCredential, [switch]$Execute)
if (-not $Execute) { return "PLAN: mount $($NodeName -join ',')" }
Set-Content -LiteralPath (Join-Path $env:ZTP_TEST_BIOS_DIR "mount-$($NodeName[0]).txt") -Value 'x'
[pscustomobject]@{ Node = $NodeName[0]; Image = "//$ShareHost/$ShareName/ztp-usb-$($NodeName[0]).img"; WriteProtected = $false }
'@
        # A read (no -Execute, with a credential) throws for an attribute the BMC of that node lacks, like the real script.
        Set-Content -LiteralPath (Join-Path $script:bin2 'Set-ZtpBios.ps1') -Value @'
[CmdletBinding(SupportsShouldProcess)]
param([string]$NodeName, [string]$BmcAddress, [System.Collections.IDictionary]$Attributes, [System.Collections.IDictionary]$Reason, $Credential, $ChangeLogPath, $TimeoutMinutes, $PollSeconds, [switch]$ConfirmNotClustered, [switch]$SkipCertificateCheck, [switch]$Execute)
if (-not $Execute) {
    if ($Credential -and $Attributes.Contains('Slot9')) { throw "The BIOS has no attribute Slot9 ($($Reason['Slot9'])). Attribute names are case-sensitive." }
    return "PLAN: $NodeName BIOS read"
}
Set-Content -LiteralPath (Join-Path $env:ZTP_TEST_BIOS_DIR "bios-$NodeName.txt") -Value 'x'
[pscustomobject]@{ Node = $NodeName; Bmc = $BmcAddress; Status = 'Changed'; Changes = @($Attributes.Keys | ForEach-Object { "${_}: Enabled -> $($Attributes[$_])" }) }
'@
        $script:images2 = Join-Path $TestDrive 'boot-images2'
        $null = New-Item -ItemType Directory -Path $script:images2
        foreach ($n in 'node-01', 'node-02') { Set-Content -LiteralPath (Join-Path $script:images2 "ztp-usb-$n.img") -Value 'x' }
        $script:boot2 = Join-Path $script:bin2 'Start-MaintenanceBoot.ps1'
        function script:New-BootNodes([string]$Slot2) {
            $path = Join-Path $TestDrive "boot-nodes-$([guid]::NewGuid().ToString('N')).json"
            @{ nodes = @(
                    [ordered]@{ name = 'node-01'; service_tag = 'IICSN0001'; bmc_address = '198.51.100.11'; bios = [ordered]@{ Slot2 = 'Disabled' }; bios_reason = [ordered]@{ Slot2 = 'derived: nodes[0] slot 2' } }
                    [ordered]@{ name = 'node-02'; service_tag = 'IICSN0002'; bmc_address = '198.51.100.12'; bios = [ordered]@{ $Slot2 = 'Disabled' }; bios_reason = [ordered]@{ $Slot2 = 'derived: nodes[1].san.hbas[0] is in Slot 9, so ZTP looked for the BIOS attribute Slot9; check the slot label' } }
                ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
            $path
        }
    }

    It 'stops with the reason when one node has no such slot, and has changed nothing: no share, no BIOS, no mount' {
        $dir = Join-Path $TestDrive 'boot2-order'; $null = New-Item -ItemType Directory -Force -Path $dir
        $env:ZTP_TEST_BIOS_DIR = $dir
        try {
            $message = try { $null = & $script:boot2 -ImageDirectory $script:images2 -ShareHost 192.0.2.10 -NodeName node-01, node-02 -NodesFile (New-BootNodes 'Slot9') -Credential $script:bmc -Restart -ConfirmNotClustered -Execute -Confirm:$false; '' } catch { $_.Exception.Message }
        }
        finally { $env:ZTP_TEST_BIOS_DIR = $null }
        $message | Should -BeLike '*no attribute Slot9 (derived: nodes[[]1].san.hbas[[]0] is in Slot 9*'
        @(Get-ChildItem -LiteralPath $dir -File).Count | Should -Be 0 -Because 'node-01 was not changed, the share was not published and nothing was mounted'
    }

    It 'goes on when every node has its slot, and gives the share its account name' {
        $dir = Join-Path $TestDrive 'boot2-ok'; $null = New-Item -ItemType Directory -Force -Path $dir
        $env:ZTP_TEST_BIOS_DIR = $dir
        try { $null = & $script:boot2 -ImageDirectory $script:images2 -ShareHost 192.0.2.10 -NodeName node-01, node-02 -NodesFile (New-BootNodes 'Slot3') -Credential $script:bmc -Restart -ConfirmNotClustered -AccountName svc-iic-media -Execute -Confirm:$false }
        finally { $env:ZTP_TEST_BIOS_DIR = $null }
        @(Get-Content -LiteralPath (Join-Path $dir 'order.txt')) | Should -Be @('publish svc-iic-media')
        @(Get-ChildItem -LiteralPath $dir -Filter 'bios-*.txt').Count | Should -Be 2
        @(Get-ChildItem -LiteralPath $dir -Filter 'mount-*.txt').Count | Should -Be 2
    }
}

Describe 'Allowed values: a value the BMC does not allow stops the run before any change' {
    BeforeAll {
        $global:biosT_origRedfish = ${function:global:Invoke-ZtpRedfish}
        function global:Invoke-ZtpRedfish {
            param($Session, [string]$Path, [string]$Method = 'Get', [hashtable]$Body, [int]$MaxAttempts = 3)
            if ($Path -eq '/redfish/v1/Registries/BiosAttributeRegistryT') { $global:biosT_calls.Add([pscustomobject]@{ Method = 'Get'; Path = $Path; Body = $null }); return [pscustomobject]@{ Location = @([pscustomobject]@{ Language = 'en'; Uri = '/redfish/v1/Registries/BiosAttributeRegistryT/doc.json' }) } }
            if ($Path -eq '/redfish/v1/Registries/BiosAttributeRegistryT/doc.json') {
                if ($global:biosT_regFail) { throw 'Redfish Get on 198.51.100.11 failed with HTTP 404' }
                $names = @('Enabled', 'BootDriverDisabled')
                if ($global:biosT_allowDisabled) { $names += 'Disabled' }
                $slot2 = [pscustomobject]@{ AttributeName = 'Slot2'; Type = 'Enumeration'; Value = @($names | ForEach-Object { [pscustomobject]@{ ValueName = $_ } }) }
                $emb = [pscustomobject]@{ AttributeName = 'EmbNic1Nic2'; Type = 'Enumeration'; Value = @('Enabled', 'DisabledOs' | ForEach-Object { [pscustomobject]@{ ValueName = $_ } }) }
                $serial = [pscustomobject]@{ AttributeName = 'SerialNumber'; Type = 'String' }
                return [pscustomobject]@{ RegistryEntries = [pscustomobject]@{ Attributes = @($slot2, $emb, $serial) } }
            }
            $r = & $global:biosT_origRedfish -Session $Session -Path $Path -Method $Method -Body $Body -MaxAttempts $MaxAttempts
            if ($Method -eq 'Get' -and $Path -like '*/Bios' -and $r) { $r | Add-Member -NotePropertyName '@Redfish.AttributeRegistry' -NotePropertyValue 'BiosAttributeRegistryT' -Force }
            $r
        }
    }
    AfterAll {
        Set-Item -Path Function:global:Invoke-ZtpRedfish -Value $global:biosT_origRedfish
        Remove-Variable -Scope Global -Name biosT_regFail, biosT_allowDisabled -ErrorAction SilentlyContinue
    }
    BeforeEach { $global:biosT_regFail = $false; $global:biosT_allowDisabled = $false }

    It 'names the attribute, node, value and the allowed ones, and writes nothing' {
        Reset-TestBmc -Current @{ Slot2 = 'Enabled'; EmbNic1Nic2 = 'DisabledOs' }
        $message = try { & $script:run @{ Attributes = [ordered]@{ Slot2 = 'Disabled' }; Credential = $script:bmc; ConfirmNotClustered = $true; Execute = $true; Confirm = $false }; '' } catch { $_.Exception.Message }
        $message | Should -BeLike "Nothing was changed. node-01 (198.51.100.11): the BIOS attribute Slot2 can't be set to 'Disabled'; the BMC allows: Enabled, BootDriverDisabled."
        @(& $script:writes).Count | Should -Be 0
    }

    It 'also stops in the read-only pass the Boot stage runs on every node first' {
        Reset-TestBmc -Current @{ Slot2 = 'Enabled'; EmbNic1Nic2 = 'DisabledOs' }
        { & $script:run @{ Attributes = [ordered]@{ Slot2 = 'Disabled' }; Credential = $script:bmc } } | Should -Throw "*can't be set to 'Disabled'*"
        @(& $script:writes).Count | Should -Be 0
    }

    It 'goes on when the registry allows the value' {
        $global:biosT_allowDisabled = $true
        Reset-TestBmc -Current @{ Slot2 = 'Enabled'; EmbNic1Nic2 = 'DisabledOs' }
        $row = & $script:run @{ Attributes = [ordered]@{ Slot2 = 'Disabled' }; Credential = $script:bmc; ConfirmNotClustered = $true; Execute = $true; Confirm = $false }
        $row.Status | Should -Be 'Changed'
    }

    It 'checks only enumerations, and a value that is already there needs no check' {
        Reset-TestBmc -Current @{ Slot2 = 'Disabled'; EmbNic1Nic2 = 'DisabledOs' }
        $row = & $script:run @{ Attributes = [ordered]@{ Slot2 = 'Disabled' }; Credential = $script:bmc; ConfirmNotClustered = $true; Execute = $true; Confirm = $false }
        $row.Status | Should -Be 'AlreadySet'
    }

    It 'warns and continues when the registry can not be read, but still fails on an attribute the BMC does not have' {
        $global:biosT_regFail = $true
        Reset-TestBmc -Current @{ Slot2 = 'Enabled'; EmbNic1Nic2 = 'DisabledOs' }
        $out = @(& $script:run @{ Attributes = [ordered]@{ Slot2 = 'Disabled' }; Credential = $script:bmc; ConfirmNotClustered = $true; Execute = $true; Confirm = $false; WarningAction = 'Continue' } 3>&1)
        ($out | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] -and $_.PSObject.Properties['Status'] }).Status | Should -Be 'Changed'
        (@($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object Message) -join ' ') | Should -BeLike "*couldn't read the attribute registry BiosAttributeRegistryT*the allowed values aren't checked*"
        Reset-TestBmc -Current @{ Slot2 = 'Enabled' }
        { & $script:run @{ Attributes = [ordered]@{ Slot9 = 'Disabled' }; Credential = $script:bmc; WarningAction = 'SilentlyContinue' } } | Should -Throw '*The BIOS has no attribute Slot9*'
    }
}
