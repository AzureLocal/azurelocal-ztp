#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
# The bootstrap completion monitor: the pure state machine and backoff, the JSON-lines events, the signal readers, and
# Wait-ZtpBootstrapComplete.ps1 end to end on a virtual clock. Every Redfish, image, ARM and sleep call is mocked; nothing
# touches a BMC, a node or Azure.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Mocks report through globals.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock and stub signatures mirror the real commands; the bodies read only some parameters.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Only a synthetic test credential is converted.')]
param()

BeforeAll {
    $global:ztpE_scripts = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts/simplified-provisioning'
    . (Join-Path $global:ztpE_scripts 'ZtpAzure.Common.ps1')
    . (Join-Path $global:ztpE_scripts 'ZtpVirtualUsb.Common.ps1')
    . (Join-Path $global:ztpE_scripts 'ZtpSbe.Common.ps1')
    . (Join-Path $global:ztpE_scripts 'ZtpRedfish.Common.ps1')
    . (Join-Path $global:ztpE_scripts 'ZtpEvents.Common.ps1')
    $global:ztpE_nodes = Join-Path $TestDrive 'nodes.json'
    @{ nodes = @(@{ name = 'node-01'; service_tag = 'EXAMPLE1'; bmc_address = '198.51.100.11' }, @{ name = 'node-02'; service_tag = 'EXAMPLE2'; bmc_address = '198.51.100.12' }) } | ConvertTo-Json -Depth 5 | Set-Content $global:ztpE_nodes
    $global:ztpE_bmc = [pscredential]::new('bmc-example', (ConvertTo-SecureString 'Example-Not-A-Secret-1' -AsPlainText -Force))
    function global:New-ZtpTestReading {
        param([string]$Power = 'On', [string]$Enabled = 'Once', [string]$Target = 'Usb', [bool]$Inserted = $true, $WriteProtected = $false, [object[]]$Logs = @())
        [pscustomobject]@{ PowerState = $Power; OverrideEnabled = $Enabled; OverrideTarget = $Target; MediaInserted = $Inserted; WriteProtected = $WriteProtected; OtherMedia = @(); LogMatches = @($Logs) }
    }
}
AfterAll {
    Remove-Item Function:\global:New-ZtpTestReading -ErrorAction SilentlyContinue
    Get-Variable -Scope Global -Name 'ztpE_*' -ErrorAction SilentlyContinue | Remove-Variable -Scope Global -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ZtpBootstrapNextState' {
    It 'walks the states in order as the evidence arrives' {
        (Get-ZtpBootstrapNextState -Current NotStarted -Signals @{}).State | Should -Be 'NotStarted'
        (Get-ZtpBootstrapNextState -Current NotStarted -Signals @{ MediaInserted = $true }).State | Should -Be 'Mounted'
        (Get-ZtpBootstrapNextState -Current Mounted -Signals @{ MediaInserted = $true; PowerOn = $true; BootedFromMedia = $true }).State | Should -Be 'Booting'
        (Get-ZtpBootstrapNextState -Current Booting -Signals @{ MediaInserted = $true; PowerOn = $true; BootedFromMedia = $true; ResetCount = 1 }).State | Should -Be 'MaintenanceEnvironmentRunning'
        (Get-ZtpBootstrapNextState -Current Booting -Signals @{ MediaInserted = $true; PowerOn = $true; BootedFromMedia = $true; CompletionLogSeen = $true }).State | Should -Be 'MaintenanceEnvironmentRunning'
        (Get-ZtpBootstrapNextState -Current MaintenanceEnvironmentRunning -Signals @{ VoucherValid = $true }).State | Should -Be 'VoucherWritten'
        (Get-ZtpBootstrapNextState -Current VoucherWritten -Signals @{ VoucherValid = $true; AzureReady = $true }).State | Should -Be 'ReadyForPortal'
    }
    It 'does not reach Booting without power and a consumed boot override, or Running without a reset or the log line' {
        (Get-ZtpBootstrapNextState -Current Mounted -Signals @{ MediaInserted = $true; PowerOn = $false; BootedFromMedia = $true }).State | Should -Be 'Mounted'
        (Get-ZtpBootstrapNextState -Current Mounted -Signals @{ MediaInserted = $true; PowerOn = $true; BootedFromMedia = $false }).State | Should -Be 'Mounted'
        (Get-ZtpBootstrapNextState -Current Booting -Signals @{ MediaInserted = $true; PowerOn = $true; BootedFromMedia = $true; ResetCount = 0 }).State | Should -Be 'Booting'
    }
    It 'treats a valid voucher as proof the environment ran, but never ReadyForPortal without Azure' {
        (Get-ZtpBootstrapNextState -Current NotStarted -Signals @{ VoucherValid = $true }).State | Should -Be 'VoucherWritten'
        (Get-ZtpBootstrapNextState -Current NotStarted -Signals @{ VoucherValid = $false; AzureReady = $true }).State | Should -Be 'NotStarted'
        (Get-ZtpBootstrapNextState -Current NotStarted -Signals @{ VoucherValid = $true; AzureReady = $true }).State | Should -Be 'ReadyForPortal'
    }
    It 'never moves backwards and reports whether it changed' {
        $r = Get-ZtpBootstrapNextState -Current VoucherWritten -Signals @{ MediaInserted = $true }
        $r.State | Should -Be 'VoucherWritten'; $r.Changed | Should -BeFalse
        (Get-ZtpBootstrapNextState -Current NotStarted -Signals @{ MediaInserted = $true }).Changed | Should -BeTrue
        { Get-ZtpBootstrapNextState -Current Nonsense -Signals @{} } | Should -Throw
    }
}

Describe 'Get-ZtpNextPollInterval' {
    It 'starts at the base, grows by 1.5x while nothing changes, caps, and resets on a change' {
        $i = 15.0; $seen = foreach ($n in 1..8) { $i = Get-ZtpNextPollInterval -BaseSeconds 15 -PreviousSeconds $i -StateChanged $false -MaxSeconds 120; $i }
        $seen[0] | Should -Be 22.5; $seen[1] | Should -Be 33.75; ($seen | Measure-Object -Maximum).Maximum | Should -Be 120
        Get-ZtpNextPollInterval -BaseSeconds 15 -PreviousSeconds 120 -StateChanged $true -MaxSeconds 120 | Should -Be 15
    }
}

Describe 'Write-ZtpEvent' {
    It 'appends one JSON object per line with timestamp, node, state, evidence and nextAction' {
        $p = Join-Path $TestDrive 'events/e.jsonl'
        Write-ZtpEvent -Path $p -Node 'node-01' -State 'Mounted' -Evidence 'media inserted' -NextAction 'boot it'
        Write-ZtpEvent -Path $p -Node 'node-01' -State 'MediaRejected' -Evidence 'x' -Level Error
        $lines = @(Get-Content $p)
        $lines.Count | Should -Be 2
        $e = $lines[0] | ConvertFrom-Json
        @($e.PSObject.Properties.Name)[0..4] | Should -Be @('timestamp', 'node', 'state', 'evidence', 'nextAction')
        $e.node | Should -Be 'node-01'; $e.state | Should -Be 'Mounted'; $e.nextAction | Should -Be 'boot it'; $e.level | Should -Be 'Info'
        [datetime]$e.timestamp | Should -BeLessThan ([datetime]::UtcNow.AddMinutes(1))
        ($lines[1] | ConvertFrom-Json).level | Should -Be 'Error'
    }
    It 'can be followed while it is written (read sharing)' {
        $p = Join-Path $TestDrive 'follow.jsonl'
        Write-ZtpEvent -Path $p -Node 'n' -State 'Mounted' -Evidence 'a'
        $reader = [System.IO.File]::Open($p, 'Open', 'Read', 'ReadWrite')
        try { { Write-ZtpEvent -Path $p -Node 'n' -State 'Booting' -Evidence 'b' } | Should -Not -Throw }
        finally { $reader.Dispose() }
    }
}

Describe 'Merge-ZtpBmcTracking' {
    It 'reads a consumed one-time override and the power transitions after it as boot and resets' {
        $t = Initialize-ZtpBmcTracking
        $s = Merge-ZtpBmcTracking -Tracking $t -Reading (New-ZtpTestReading)
        $s.MediaInserted | Should -BeTrue; $s.BootedFromMedia | Should -BeFalse
        $s = Merge-ZtpBmcTracking -Tracking $t -Reading (New-ZtpTestReading -Enabled Disabled -Target None)
        $s.BootedFromMedia | Should -BeTrue; $s.ResetCount | Should -Be 0
        $s = Merge-ZtpBmcTracking -Tracking $t -Reading (New-ZtpTestReading -Power Off -Enabled Disabled -Target None)
        $s = Merge-ZtpBmcTracking -Tracking $t -Reading (New-ZtpTestReading -Power On -Enabled Disabled -Target None)
        $s.ResetCount | Should -Be 2; $s.PowerOn | Should -BeTrue
    }
    It 'counts log matches once and flags boot and completion messages' {
        $t = Initialize-ZtpBmcTracking
        $logs = @([pscustomobject]@{ Id = 'Lclog:1'; Kind = 'completion'; Message = 'x' }, [pscustomobject]@{ Id = 'Lclog:2'; Kind = 'reset'; Message = 'y' }, [pscustomobject]@{ Id = 'Lclog:3'; Kind = 'bootedFromMedia'; Message = 'z' })
        $s = Merge-ZtpBmcTracking -Tracking $t -Reading (New-ZtpTestReading -Logs $logs)
        $s.CompletionLogSeen | Should -BeTrue; $s.ResetCount | Should -Be 1; $s.BootedFromMedia | Should -BeTrue
        $again = Merge-ZtpBmcTracking -Tracking $t -Reading (New-ZtpTestReading -Logs $logs)
        $again.ResetCount | Should -Be 1
    }
}

Describe 'Get-ZtpBmcReading' {
    BeforeEach {
        Mock Get-ZtpRedfishManager { [pscustomobject]@{ '@odata.id' = '/redfish/v1/Managers/M1' } }
        Mock Get-ZtpRedfishSystem { [pscustomobject]@{ '@odata.id' = '/redfish/v1/Systems/S1'; PowerState = 'On'; Boot = [pscustomobject]@{ BootSourceOverrideEnabled = 'Once'; BootSourceOverrideTarget = 'Usb' } } }
        Mock Get-ZtpRedfishMember {
            @([pscustomobject]@{ '@odata.id' = '/vm/CD'; MediaTypes = @('CD'); Inserted = $true; Image = '//host/share/other.iso'; WriteProtected = $true },
                [pscustomobject]@{ '@odata.id' = '/vm/RemovableDisk'; MediaTypes = @('USBStick'); Inserted = $true; Image = '//host/share/ztp-usb-node-01.img'; WriteProtected = $false })
        }
        Mock Invoke-ZtpRedfish {
            [pscustomobject]@{ Members = @(
                    [pscustomobject]@{ Id = '1'; Created = '2026-10-15T10:00:00+00:00'; Message = 'Old entry: system reset' },
                    [pscustomobject]@{ Id = '2'; Created = '2026-10-15T12:30:00+00:00'; Message = 'Virtual Media device attached' },
                    [pscustomobject]@{ Id = '3'; Created = '2026-10-15T12:40:00+00:00'; Message = 'Maintenance environment setup completed successfully' }) }
        }
    }
    It 'reads power, boot override, our slot and the matching log entries newer than the start, with GET requests only' {
        $oem = Get-ZtpOemConfig -Oem Dell
        $r = Get-ZtpBmcReading -Session 's' -ImageFileName 'ztp-usb-node-01.img' -Oem $oem -SinceUtc ([datetime]'2026-10-15T12:00:00Z')
        $r.PowerState | Should -Be 'On'; $r.OverrideEnabled | Should -Be 'Once'; $r.OverrideTarget | Should -Be 'Usb'
        $r.MediaInserted | Should -BeTrue; $r.WriteProtected | Should -BeFalse; $r.OtherMedia | Should -BeNullOrEmpty
        @($r.LogMatches | ForEach-Object Kind) | Should -Contain 'completion'
        @($r.LogMatches | ForEach-Object Kind) | Should -Contain 'bootedFromMedia'
        @($r.LogMatches | Where-Object Message -Like 'Old entry*').Count | Should -Be 0
        Should -Invoke Invoke-ZtpRedfish -ParameterFilter { $Method -and $Method -ne 'Get' } -Times 0
    }
    It 'reports another image in the slot and survives an unreadable log service' {
        Mock Get-ZtpRedfishMember { @([pscustomobject]@{ '@odata.id' = '/vm/RemovableDisk'; MediaTypes = @('USBStick'); Inserted = $true; Image = '//host/share/other.img'; WriteProtected = $false }) }
        Mock Invoke-ZtpRedfish { throw 'HTTP 404' }
        $r = Get-ZtpBmcReading -Session 's' -ImageFileName 'ztp-usb-node-01.img' -Oem (Get-ZtpOemConfig -Oem Dell)
        $r.MediaInserted | Should -BeFalse; $r.OtherMedia | Should -Be @('//host/share/other.img'); @($r.LogMatches).Count | Should -Be 0
    }
}

Describe 'Get-ZtpImageVoucherSignal' {
    BeforeAll {
        function global:New-ZtpETestVoucher { param([string]$Serial)
            $body = [byte[]](@(0x85) + [System.Text.Encoding]::ASCII.GetBytes("device-info:$Serial") + [byte[]](1..48)); $b64 = [Convert]::ToBase64String($body)
            [System.Text.Encoding]::ASCII.GetBytes((@('-----BEGIN OWNERSHIP VOUCHER-----') + @(for ($i = 0; $i -lt $b64.Length; $i += 64) { $b64.Substring($i, [math]::Min(64, $b64.Length - $i)) }) + @('-----END OWNERSHIP VOUCHER-----')) -join "`n") + "`n" }
        $media = Join-Path $TestDrive 'media'; foreach ($d in 'efi/boot', 'boot/grub2', 'liveos') { $null = New-Item -ItemType Directory -Force (Join-Path $media $d) }
        Set-Content (Join-Path $media 'efi/boot/bootx64.efi') 'e'; Set-Content (Join-Path $media 'boot/grub2/grub.cfg') 'g'; Set-Content (Join-Path $media 'liveos/rootfs.img') 'r'
        $global:ztpE_empty = Join-Path $TestDrive 'empty.img'; $null = Build-ZtpFat32Image -SourcePath $media -OutputPath $global:ztpE_empty -SizeBytes 40MB -ClusterSize 512
        $global:ztpE_full = Join-Path $TestDrive 'full.img'; $null = Build-ZtpFat32Image -SourcePath $media -OutputPath $global:ztpE_full -SizeBytes 40MB -ClusterSize 512 -ExtraFiles @{ 'vouchers/EXAMPLE1/EXAMPLE1.pem' = (New-ZtpETestVoucher -Serial 'EXAMPLE1') }
        $global:ztpE_wrong = Join-Path $TestDrive 'wrong.img'; $null = Build-ZtpFat32Image -SourcePath $media -OutputPath $global:ztpE_wrong -SizeBytes 40MB -ClusterSize 512 -ExtraFiles @{ 'vouchers/EXAMPLE1/EXAMPLE1.pem' = (New-ZtpETestVoucher -Serial 'OTHER') }
    }
    AfterAll { Remove-Item Function:\global:New-ZtpETestVoucher -ErrorAction SilentlyContinue }
    It 'reports no voucher yet, a valid voucher, a voucher for another serial and a missing image' {
        (Get-ZtpImageVoucherSignal -ImagePath $global:ztpE_empty -Serial EXAMPLE1).Valid | Should -BeFalse
        (Get-ZtpImageVoucherSignal -ImagePath $global:ztpE_empty -Serial EXAMPLE1).Detail | Should -Match 'no \\vouchers\\ folder'
        $ok = Get-ZtpImageVoucherSignal -ImagePath $global:ztpE_full -Serial EXAMPLE1
        $ok.Valid | Should -BeTrue; $ok.Sha256 | Should -Match '^[0-9A-F]{64}$'
        ($ok | ConvertTo-Json) | Should -Not -Match 'BEGIN OWNERSHIP'
        $wrong = Get-ZtpImageVoucherSignal -ImagePath $global:ztpE_wrong -Serial EXAMPLE1
        $wrong.Valid | Should -BeFalse
        (Get-ZtpImageVoucherSignal -ImagePath (Join-Path $TestDrive 'nope.img') -Serial EXAMPLE1).Detail | Should -Match 'image not found'
    }
}

Describe 'Get-ZtpAzureReadiness' {
    It 'is ready when the feature, the providers and the catalog are in place' {
        Mock Invoke-ZtpArm {
            if ($Path -like '*subscriptionFeatureRegistrations*') { return [pscustomobject]@{ properties = [pscustomobject]@{ state = 'Registered' } } }
            [pscustomobject]@{ registrationState = 'Registered' }
        }
        Mock Get-ZtpOsImageCatalog { @([pscustomobject]@{ VsrVersion = '12.2609.1003.7' }) }
        $r = Get-ZtpAzureReadiness -SubscriptionId '00000000-0000-0000-0000-000000000000' -Location eastus
        $r.Ready | Should -BeTrue; $r.Problems.Count | Should -Be 0
        Should -Invoke Invoke-ZtpArm -ParameterFilter { $Method -eq 'GET' } -Times 5
    }
    It 'lists every problem: feature missing, a provider unregistered, catalog unreadable' {
        Mock Invoke-ZtpArm {
            if ($Path -like '*subscriptionFeatureRegistrations*') { return $null }
            if ($Path -like '*Microsoft.Edge') { return [pscustomobject]@{ registrationState = 'NotRegistered' } }
            [pscustomobject]@{ registrationState = 'Registered' }
        }
        Mock Get-ZtpOsImageCatalog { throw 'ARM GET failed with 403' }
        $r = Get-ZtpAzureReadiness -SubscriptionId '00000000-0000-0000-0000-000000000000' -Location eastus
        $r.Ready | Should -BeFalse
        ($r.Problems -join '|') | Should -Match 'AzureLocalZTP.*not found'
        ($r.Problems -join '|') | Should -Match 'Microsoft.Edge is ''NotRegistered'''
        ($r.Problems -join '|') | Should -Match 'catalog.*unreadable'
    }
}

Describe 'Wait-ZtpBootstrapComplete.ps1' {
    BeforeEach {
        $global:ztpE_now = [datetime]'2026-10-15T12:00:00Z'
        $global:ztpE_sleeps = [System.Collections.Generic.List[double]]::new()
        $global:ztpE_events = Join-Path $TestDrive "events-$([guid]::NewGuid().ToString('N')).jsonl"
        $global:ztpE_poll = @{}            # node -> poll counter
        $global:ztpE_script = @{}          # node -> scriptblock(pollNumber) -> reading
        $global:ztpE_voucherAt = @{}       # node -> poll number from which the voucher is valid
        $global:ztpE_azure = [pscustomobject]@{ Ready = $true; Problems = @(); Detail = 'ok' }
        $global:ztpE_calls = [System.Collections.Generic.List[string]]::new()
        Mock Get-ZtpUtcNow { $global:ztpE_now }
        Mock Wait-ZtpInterval { $global:ztpE_sleeps.Add($Seconds); $global:ztpE_now = $global:ztpE_now.AddSeconds($Seconds) }
        Mock New-ZtpRedfishSession { $global:ztpE_calls.Add("session $BmcAddress"); "session-$BmcAddress" }
        Mock Remove-ZtpRedfishSession { $global:ztpE_calls.Add('closed') }
        Mock Get-ZtpBmcReading {
            $node = if ($Session -like '*.11') { 'node-01' } else { 'node-02' }
            $global:ztpE_poll[$node] = 1 + $(if ($global:ztpE_poll.ContainsKey($node)) { $global:ztpE_poll[$node] } else { 0 })
            & $global:ztpE_script[$node] $global:ztpE_poll[$node]
        }
        Mock Get-ZtpImageVoucherSignal {
            $node = if ($Serial -eq 'EXAMPLE1') { 'node-01' } else { 'node-02' }
            $valid = $global:ztpE_voucherAt.ContainsKey($node) -and $global:ztpE_poll[$node] -ge $global:ztpE_voucherAt[$node]
            [pscustomobject]@{ Present = $valid; Valid = $valid; Sha256 = $(if ($valid) { 'AB' * 32 } else { $null }); Detail = $(if ($valid) { 'valid' } else { 'no \vouchers\ folder yet' }) }
        }
        Mock Get-ZtpAzureReadiness { $global:ztpE_azure }
        $global:ztpE_happy = {
            param($n)
            switch ($n) {
                1 { New-ZtpTestReading }
                2 { New-ZtpTestReading -Enabled Disabled -Target None }
                3 { New-ZtpTestReading -Power Off -Enabled Disabled -Target None }
                default { New-ZtpTestReading -Enabled Disabled -Target None }
            }
        }
        $global:ztpE_run = {
            param([hashtable]$Extra = @{})
            $a = @{ NodeName = 'node-01'; NodesFile = $global:ztpE_nodes; ImageDirectory = $TestDrive; Credential = $global:ztpE_bmc; SubscriptionId = '00000000-0000-0000-0000-000000000000'
                EventLogPath = $global:ztpE_events; PollSeconds = 15; MaxPollSeconds = 60; InformationAction = 'SilentlyContinue'; WarningAction = 'SilentlyContinue'; Execute = $true }
            foreach ($k in $Extra.Keys) { $a[$k] = $Extra[$k] }
            & (Join-Path $global:ztpE_scripts 'Wait-ZtpBootstrapComplete.ps1') @a
        }
        $global:ztpE_read = { @(Get-Content $global:ztpE_events | ForEach-Object { $_ | ConvertFrom-Json }) }
    }
    AfterAll { Get-Variable -Scope Global -Name 'ztpE_*' -ErrorAction SilentlyContinue | Where-Object Name -NotIn 'ztpE_scripts', 'ztpE_nodes', 'ztpE_bmc' | Remove-Variable -Scope Global -Force -ErrorAction SilentlyContinue }

    It 'plans by default: nothing is read and no event is written' {
        $out = & $global:ztpE_run @{ Execute = $false }
        ($out -join "`n") | Should -Match 'PLAN: node-01.*Dell BMC'
        ($out -join "`n") | Should -Match 'states NotStarted'
        Test-Path $global:ztpE_events | Should -BeFalse
        Should -Invoke Get-ZtpBmcReading -Times 0
    }

    It 'walks Mounted -> Booting -> MaintenanceEnvironmentRunning -> VoucherWritten -> ReadyForPortal and emits one event per state' {
        $global:ztpE_script['node-01'] = $global:ztpE_happy
        $global:ztpE_voucherAt['node-01'] = 5
        $rows = & $global:ztpE_run @{}
        $rows.Count | Should -Be 1; $rows[0].State | Should -Be 'ReadyForPortal'; $rows[0].Ready | Should -BeTrue
        $rows[0].VoucherSha256 | Should -Be ('AB' * 32)
        $events = & $global:ztpE_read
        @($events | ForEach-Object state) | Should -Be @('NotStarted', 'Mounted', 'Booting', 'MaintenanceEnvironmentRunning', 'VoucherWritten', 'ReadyForPortal')
        foreach ($e in $events) { $e.node | Should -Not -BeNullOrEmpty; $e.evidence | Should -Not -BeNullOrEmpty; $e.timestamp | Should -Not -BeNullOrEmpty }
        ($events | Where-Object state -EQ 'Booting').evidence | Should -Match 'boot override consumed'
        ($events | Where-Object state -EQ 'ReadyForPortal').nextAction | Should -Match 'Wait-ZtpVoucher'
        ($events | ConvertTo-Json) | Should -Not -Match 'BEGIN OWNERSHIP'
        Should -Invoke Remove-ZtpRedfishSession -Times 1
    }

    It 'backs off while nothing changes and starts again from the base interval after a change' {
        $global:ztpE_script['node-01'] = { param($n) if ($n -le 2) { New-ZtpTestReading } else { New-ZtpTestReading -Enabled Disabled -Target None } }
        $global:ztpE_voucherAt['node-01'] = 8
        $null = & $global:ztpE_run @{}
        $s = @($global:ztpE_sleeps)
        $s[0] | Should -Be 15          # poll 1 changed the state (Mounted): base
        $s[1] | Should -Be 22.5        # poll 2 unchanged: x1.5
        $s[2] | Should -Be 15          # poll 3 changed (Booting): base again
        ($s | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual 60
    }

    It 'goes straight from a valid voucher to ReadyForPortal and still emits VoucherWritten' {
        $global:ztpE_script['node-01'] = { param($n) New-ZtpTestReading }
        $global:ztpE_voucherAt['node-01'] = 2
        $rows = & $global:ztpE_run @{}
        $rows[0].Ready | Should -BeTrue
        @(& $global:ztpE_read | ForEach-Object state) | Should -Contain 'VoucherWritten'
        @(& $global:ztpE_read | ForEach-Object state)[-1] | Should -Be 'ReadyForPortal'
    }

    It 'stays in VoucherWritten with a warning while Azure is not ready, then fails at the overall budget' {
        $global:ztpE_script['node-01'] = $global:ztpE_happy
        $global:ztpE_voucherAt['node-01'] = 1
        $global:ztpE_azure = [pscustomobject]@{ Ready = $false; Problems = @('feature missing'); Detail = 'feature missing' }
        $rows = & $global:ztpE_run @{ TimeoutMinutes = 3; VoucherTimeoutMinutes = 2 }
        $rows[0].Ready | Should -BeFalse; $rows[0].State | Should -Be 'Failed'
        $events = & $global:ztpE_read
        ($events | Where-Object { $_.state -eq 'VoucherWritten' -and $_.level -eq 'Warning' }).evidence | Should -Match 'Azure not ready: feature missing'
        $events[-1].state | Should -Be 'Failed'; $events[-1].level | Should -Be 'Error'
        $events | ForEach-Object state | Should -Not -Contain 'ReadyForPortal'
    }

    It 'skips the Azure check on request and says so in the event' {
        $global:ztpE_script['node-01'] = $global:ztpE_happy
        $global:ztpE_voucherAt['node-01'] = 2
        $null = & $global:ztpE_run @{ SkipAzureCheck = $true; SubscriptionId = '' }
        (& $global:ztpE_read | Where-Object state -EQ 'ReadyForPortal').evidence | Should -Match 'Azure check skipped'
        Should -Invoke Get-ZtpAzureReadiness -Times 0
    }

    It 'rejects a write-protected image at once' {
        $global:ztpE_script['node-01'] = { param($n) New-ZtpTestReading -WriteProtected $true }
        $rows = & $global:ztpE_run @{}
        $rows[0].State | Should -Be 'MediaRejected'
        (& $global:ztpE_read)[-1].evidence | Should -Match 'write-protected'
        (& $global:ztpE_read)[-1].level | Should -Be 'Error'
    }

    It 'rejects media that is not inserted after 3 minutes' {
        $global:ztpE_script['node-01'] = { param($n) New-ZtpTestReading -Inserted $false }
        $rows = & $global:ztpE_run @{ PollSeconds = 60; MaxPollSeconds = 60 }
        $rows[0].State | Should -Be 'MediaRejected'
        $rows[0].Evidence | Should -Match 'not inserted after 3 minutes'
    }

    It 'does not reject a node whose voucher is already valid even when the BMC reports write protection or no media' {
        $global:ztpE_script['node-01'] = { param($n) New-ZtpTestReading -WriteProtected $true }
        $global:ztpE_voucherAt['node-01'] = 3
        $rows = & $global:ztpE_run @{}
        $rows[0].State | Should -Be 'MediaRejected' -Because 'a write-protected attach is rejected while no voucher exists'
        $global:ztpE_poll.Clear(); Remove-Item $global:ztpE_events
        $global:ztpE_script['node-01'] = { param($n) if ($n -eq 1) { New-ZtpTestReading } else { New-ZtpTestReading -WriteProtected $true } }
        $global:ztpE_voucherAt['node-01'] = 2
        (& $global:ztpE_run @{})[0].Ready | Should -BeTrue
    }

    It 'flags a voucher that is already in the image before the first boot signal and does not accept it until the node is seen booting' {
        $global:ztpE_script['node-01'] = { param($n) if ($n -le 2) { New-ZtpTestReading -Enabled Once } else { New-ZtpTestReading -Enabled Disabled -Target None } }
        $global:ztpE_voucherAt['node-01'] = 1
        $rows = & $global:ztpE_run @{ VoucherTimeoutMinutes = 60 }
        $rows[0].Ready | Should -BeTrue
        $events = & $global:ztpE_read
        ($events | Where-Object { $_.level -eq 'Warning' -and $_.evidence -match 'already in the image' }).Count | Should -Be 1
        $events | ForEach-Object state | Should -Contain 'Booting'
        ($events | Where-Object state -EQ 'Booting')[0].timestamp | Should -Not -BeNullOrEmpty
        # VoucherWritten only after Booting
        $order = @($events | ForEach-Object state)
        [array]::IndexOf($order, 'VoucherWritten') | Should -BeGreaterThan ([array]::IndexOf($order, 'Booting'))
    }

    It 'never accepts an unchanged pre-boot voucher when the node is never seen booting' {
        $global:ztpE_script['node-01'] = { param($n) New-ZtpTestReading -Enabled Once }
        $global:ztpE_voucherAt['node-01'] = 1
        $rows = & $global:ztpE_run @{ VoucherTimeoutMinutes = 3; TimeoutMinutes = 10 }
        $rows[0].State | Should -Be 'VoucherMissing'
    }

    It 'fails with VoucherMissing at the voucher deadline and points to the Configurator App' {
        $global:ztpE_script['node-01'] = $global:ztpE_happy
        $rows = & $global:ztpE_run @{ VoucherTimeoutMinutes = 2; TimeoutMinutes = 30 }
        $rows[0].State | Should -Be 'VoucherMissing'
        (& $global:ztpE_read)[-1].nextAction | Should -Match 'Configurator App'
    }

    It 'warns once when a weak-signal state does not change for the stall time, without failing the node' {
        $global:ztpE_script['node-01'] = { param($n) New-ZtpTestReading }
        $global:ztpE_voucherAt['node-01'] = 80
        $rows = & $global:ztpE_run @{ StallMinutes = 5; VoucherTimeoutMinutes = 200; TimeoutMinutes = 240 }
        $rows[0].Ready | Should -BeTrue
        @(& $global:ztpE_read | Where-Object { $_.level -eq 'Warning' -and $_.evidence -match 'no change for 5 minutes' }).Count | Should -Be 1
    }

    It 'watches several nodes in one loop and reports each' {
        $global:ztpE_script['node-01'] = $global:ztpE_happy; $global:ztpE_script['node-02'] = $global:ztpE_happy
        $global:ztpE_voucherAt['node-01'] = 4; $global:ztpE_voucherAt['node-02'] = 7
        $rows = & $global:ztpE_run @{ NodeName = 'node-01', 'node-02' }
        @($rows | ForEach-Object Node) | Should -Be @('node-01', 'node-02')
        @($rows | Where-Object Ready).Count | Should -Be 2
        (& $global:ztpE_read | Where-Object { $_.node -eq 'node-02' -and $_.state -eq 'ReadyForPortal' }) | Should -Not -BeNullOrEmpty
    }

    It 'survives an unreadable BMC for a poll, reopens the session and still finds the voucher in the image' {
        $global:ztpE_script['node-01'] = { param($n) if ($n -eq 1) { throw 'BMC timeout' } else { New-ZtpTestReading -Enabled Disabled -Target None } }
        $global:ztpE_voucherAt['node-01'] = 3
        $rows = & $global:ztpE_run @{}
        $rows[0].Ready | Should -BeTrue
        @($global:ztpE_calls | Where-Object { $_ -like 'session*' }).Count | Should -BeGreaterOrEqual 2
    }

    It 'uses the Configurator App folder without a BMC when -VoucherFolder is given' {
        $folder = Join-Path $TestDrive 'cfgapp'; $null = New-Item -ItemType Directory $folder -Force
        $body = [byte[]](@(0x85) + [System.Text.Encoding]::ASCII.GetBytes('device-info:EXAMPLE1') + [byte[]](1..48)); $b64 = [Convert]::ToBase64String($body)
        $pem = (@('-----BEGIN OWNERSHIP VOUCHER-----') + @(for ($i = 0; $i -lt $b64.Length; $i += 64) { $b64.Substring($i, [math]::Min(64, $b64.Length - $i)) }) + @('-----END OWNERSHIP VOUCHER-----')) -join "`n"
        Set-Content (Join-Path $folder 'EXAMPLE1.pem') $pem
        $rows = & $global:ztpE_run @{ VoucherFolder = $folder; ImageDirectory = $null; Credential = $null; SkipAzureCheck = $true }
        $rows[0].Ready | Should -BeTrue
        Should -Invoke New-ZtpRedfishSession -Times 0
        Should -Invoke Get-ZtpBmcReading -Times 0
    }

    It 'requires a credential to act and an Azure subscription unless the check is skipped' {
        { & $global:ztpE_run @{ Credential = $null } } | Should -Throw '*-Credential*'
        { & $global:ztpE_run @{ SubscriptionId = '' } } | Should -Throw '*-SubscriptionId*'
    }
}
