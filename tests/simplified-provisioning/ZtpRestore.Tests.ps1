#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
# The Restore stage: Restore-ZtpBios.ps1 sets the provisioning-only BIOS values back (to hardware.bios, or to the value
# saved before Boot). It runs from a copy of the scripts in TestDrive beside a stub Set-ZtpBios.ps1 that records its calls
# in a file (the nodes run in parallel runspaces); no BMC is contacted. Example addresses only.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Only a synthetic test credential is converted.')]
param()

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:bin = Join-Path $TestDrive 'scripts/simplified-provisioning'
    $null = New-Item -ItemType Directory -Force -Path $script:bin
    Copy-Item -Path (Join-Path $repoRoot 'scripts/simplified-provisioning/*.ps1') -Destination $script:bin
    # The stub: records each call, then answers like Set-ZtpBios.ps1 (AlreadySet when ZTPR_ALREADY names the node, a failure when ZTPR_FAIL does).
    Set-Content -LiteralPath (Join-Path $script:bin 'Set-ZtpBios.ps1') -Value @'
[CmdletBinding(SupportsShouldProcess)]
param([string]$NodeName, [string]$BmcAddress, [System.Collections.IDictionary]$Attributes, [pscredential]$Credential, [string]$ChangeLogPath, [int]$TimeoutMinutes, [switch]$ConfirmNotClustered, [switch]$SkipCertificateCheck, [switch]$Execute)
$line = [ordered]@{ node = $NodeName; bmc = $BmcAddress; attributes = $Attributes; execute = [bool]$Execute; confirm = [bool]$ConfirmNotClustered; log = $ChangeLogPath } | ConvertTo-Json -Compress -Depth 5
Add-Content -LiteralPath $env:ZTPR_LOG -Value $line
if (-not $Execute) { "PLAN: $NodeName BIOS stub"; return }
if ($env:ZTPR_FAIL -eq $NodeName) { throw "$NodeName BIOS still reports Slot2=Disabled 30 minutes after the ForceRestart." }
$status = if ($env:ZTPR_ALREADY -eq $NodeName) { 'AlreadySet' } else { 'Changed' }
[pscustomobject]@{ Node = $NodeName; Bmc = $BmcAddress; Status = $status; Changes = @(foreach ($k in $Attributes.Keys) { "${k}: Disabled -> $($Attributes[$k])" }); Original = [ordered]@{} }
'@
    $script:restore = Join-Path $script:bin 'Restore-ZtpBios.ps1'
    $script:bmc = [pscredential]::new('bmc-example', (ConvertTo-SecureString 'Example-Not-A-Secret-1' -AsPlainText -Force))
    $script:writeNodes = {
        param([hashtable]$Restore1, [hashtable]$Restore2)
        $n1 = [ordered]@{ name = 'node-01'; service_tag = 'EXAMPLE1'; bmc_address = '198.51.100.11' }
        $n2 = [ordered]@{ name = 'node-02'; service_tag = 'EXAMPLE2'; bmc_address = '198.51.100.12' }
        if ($Restore1) { $n1.bios_restore = $Restore1 }
        if ($Restore2) { $n2.bios_restore = $Restore2 }
        $f = Join-Path $TestDrive "nodes-$([guid]::NewGuid().ToString('N')).json"
        @{ nodes = @($n1, $n2) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $f
        $f
    }
    $script:calls = { if (Test-Path -LiteralPath $env:ZTPR_LOG) { @(Get-Content -LiteralPath $env:ZTPR_LOG | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() } }
    $script:eventsOf = { param($p) if (Test-Path -LiteralPath $p) { @(Get-Content -LiteralPath $p | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() } }
}
AfterAll { Remove-Item Env:\ZTPR_LOG, Env:\ZTPR_FAIL, Env:\ZTPR_ALREADY -ErrorAction SilentlyContinue }

Describe 'Restore-ZtpBios.ps1' {
    BeforeEach {
        $env:ZTPR_LOG = Join-Path $TestDrive "calls-$([guid]::NewGuid().ToString('N')).jsonl"
        Remove-Item Env:\ZTPR_FAIL, Env:\ZTPR_ALREADY -ErrorAction SilentlyContinue
        $script:events = Join-Path $TestDrive "events-$([guid]::NewGuid().ToString('N')).jsonl"
    }

    It 'is a no-op that says so when no node has bios_during_provisioning' {
        $nodes = & $script:writeNodes
        $out = @(& $script:restore -NodeName node-01, node-02 -NodesFile $nodes -InformationAction SilentlyContinue)
        ($out | Where-Object { $_ -is [string] }) | Should -Be 'PLAN: Restore: no bios_during_provisioning in the environment file; nothing to set back.'
        @($out | Where-Object { $_ -isnot [string] } | ForEach-Object Status) | Should -Be @('NotNeeded', 'NotNeeded')
        $rows = @(& $script:restore -NodeName node-01, node-02 -NodesFile $nodes -EventLogPath $script:events -Execute -Confirm:$false -InformationAction SilentlyContinue)
        @($rows | ForEach-Object Status) | Should -Be @('NotNeeded', 'NotNeeded') -Because 'nothing to do needs no credential'
        & $script:calls | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:events | Should -BeFalse
    }

    It 'plans without -Execute: the final value from hardware.bios, else the value saved before Boot' {
        $nodes = & $script:writeNodes @{ Slot2 = 'Enabled'; Slot3 = '' }
        $out = @(& $script:restore -NodeName node-01, node-02 -NodesFile $nodes -Original @{ 'node-01' = @{ Slot3 = 'Enabled'; Slot2 = 'Enabled' } })
        ($out | Where-Object { $_ -is [string] }) | Should -Be 'PLAN: node-01 Restore BIOS Slot2=Enabled (from hardware.bios), Slot3=Enabled (from the value before Boot): PATCH OnReset, restart through Redfish, wait until the BIOS reports them; then wait until the Arc machine reports Connected and the edge machine is still ready to cluster.'
        @($out | Where-Object { $_ -isnot [string] } | ForEach-Object { "$($_.Node) $($_.Status)" }) | Should -Be @('node-02 NotNeeded', 'node-01 Planned')
        & $script:calls | Should -BeNullOrEmpty -Because 'without -Credential the plan asks no BMC'
        $null = & $script:restore -NodeName node-01 -NodesFile $nodes -Original @{ 'node-01' = @{ Slot3 = 'Enabled' } } -Credential $script:bmc
        (& $script:calls)[0].execute | Should -BeFalse
    }

    It 'sets the values back on every node at once with -Execute, writes the Restore events and returns what it restored' {
        $nodes = & $script:writeNodes @{ Slot2 = 'Enabled' } @{ Slot2 = '' }
        $rows = @(& $script:restore -NodeName node-01, node-02 -NodesFile $nodes -Original @{ 'node-02' = @{ Slot2 = 'Enabled' } } -Credential $script:bmc -ConfirmNotClustered -EventLogPath $script:events -BiosLogPath (Join-Path $TestDrive 'bios.jsonl') -Execute -Confirm:$false)
        @($rows | ForEach-Object { "$($_.Node) $($_.Status) $($_.Restored.Slot2)" } | Sort-Object) | Should -Be @('node-01 Restored Enabled', 'node-02 Restored Enabled')
        $calls = @(& $script:calls | Sort-Object node)
        @($calls | ForEach-Object { "$($_.node) $($_.bmc) $($_.attributes.Slot2) $($_.execute) $($_.confirm)" }) | Should -Be @('node-01 198.51.100.11 Enabled True True', 'node-02 198.51.100.12 Enabled True True')
        $calls[0].log | Should -Be (Join-Path $TestDrive 'bios.jsonl')
        $ev = & $script:eventsOf $script:events
        @($ev | ForEach-Object stage | Select-Object -Unique) | Should -Be @('Restore')
        @($ev | Where-Object node -EQ 'node-01' | ForEach-Object state) | Should -Be @('BiosRestoreStarted', 'BiosRestored')
        ($ev | Where-Object { $_.node -eq 'node-01' -and $_.state -eq 'BiosRestored' }).evidence | Should -Be 'BIOS Slot2=Enabled (Slot2: Disabled -> Enabled)'
    }

    It 'reports a node whose BIOS already holds the values without a restart' {
        $env:ZTPR_ALREADY = 'node-01'
        $nodes = & $script:writeNodes @{ Slot2 = 'Enabled' }
        $rows = @(& $script:restore -NodeName node-01 -NodesFile $nodes -Credential $script:bmc -ConfirmNotClustered -EventLogPath $script:events -Execute -Confirm:$false)
        $rows[0].Status | Should -Be 'AlreadySet'
        ((& $script:eventsOf $script:events) | Where-Object state -EQ 'BiosRestored').evidence | Should -BeLike '*already set; no restart*'
    }

    It 'fails with BiosRestoreFailed when a node''s BIOS does not report the values, and names it' {
        $env:ZTPR_FAIL = 'node-02'
        $nodes = & $script:writeNodes @{ Slot2 = 'Enabled' } @{ Slot2 = 'Enabled' }
        { & $script:restore -NodeName node-01, node-02 -NodesFile $nodes -Credential $script:bmc -ConfirmNotClustered -EventLogPath $script:events -Execute -Confirm:$false } | Should -Throw '*Restore failed on node-02: node-02 BIOS still reports Slot2=Disabled*'
        $ev = & $script:eventsOf $script:events
        ($ev | Where-Object state -EQ 'BiosRestoreFailed').node | Should -Be 'node-02'
        ($ev | Where-Object state -EQ 'BiosRestoreFailed').level | Should -Be 'Error'
        ($ev | Where-Object { $_.node -eq 'node-01' -and $_.state -eq 'BiosRestored' }) | Should -Not -BeNullOrEmpty
    }

    It 'refuses when the value to set back was not saved, and needs the credential and -ConfirmNotClustered to act' {
        $nodes = & $script:writeNodes @{ Slot2 = '' }
        { & $script:restore -NodeName node-01 -NodesFile $nodes -Credential $script:bmc -ConfirmNotClustered -EventLogPath $script:events -Execute -Confirm:$false } | Should -Throw '*node-01: no value saved for Slot2 before Boot changed it*Set hardware.bios.Slot2*'
        ((& $script:eventsOf $script:events) | Where-Object state -EQ 'BiosRestoreFailed').node | Should -Be 'node-01'
        $nodes = & $script:writeNodes @{ Slot2 = 'Enabled' }
        { & $script:restore -NodeName node-01 -NodesFile $nodes -ConfirmNotClustered -Execute -Confirm:$false } | Should -Throw '*-Credential*'
        { & $script:restore -NodeName node-01 -NodesFile $nodes -Credential $script:bmc -Execute -Confirm:$false } | Should -Throw '*-ConfirmNotClustered*'
        & $script:calls | Should -BeNullOrEmpty
    }
}
