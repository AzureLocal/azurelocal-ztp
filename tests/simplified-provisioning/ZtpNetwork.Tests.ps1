#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
# The Network stage: the network adapter helpers in ZtpAzure.Common.ps1 and Set-ZtpManagementAddress.ps1 against a
# stubbed edge machine (edgeMachines/<node>/networkAdapters and networkAdapters/<name>/jobs/ApplyConfiguration, api-version
# 2026-10-01, in the shapes of Microsoft's spec examples and a live run). MAC matching, releasing the address from the
# wrong adapter first, the idempotent no-op, a queued job, a failed job, no matching MAC, a timeout, the report-only modes
# and the plan. No Azure call; example addresses and documentation MACs (00-00-5E-00-53-xx) only.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The stub edge machine keeps its state in globals.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signatures mirror the real commands.')]
param()

BeforeAll {
    $script:repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:scripts = Join-Path $script:repoRoot 'scripts/simplified-provisioning'
    $script:setNetwork = Join-Path $script:scripts 'Set-ZtpManagementAddress.ps1'
    . (Join-Path $script:scripts 'ZtpAzure.Common.ps1')

    $script:lom = '00000000-0000-0000-0000-000000000001'
    $script:storage = '00000000-0000-0000-0000-000000000002'
    $script:spare = '00000000-0000-0000-0000-000000000003'

    function global:New-NetTResponse { param([int]$Status, [object]$Body) [pscustomobject]@{ StatusCode = $Status; Content = $(if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 30 } else { '' }) } }
    function global:New-NetTAdapter {
        param([string]$AdapterName, [string]$Mac, [string]$Description, [string]$Type = 'Dhcp', [string]$Ip = '', [string]$Mask = '', [string]$Gateway = '', [string[]]$Dns = @(), [int]$Vlan = 0)
        $config = [ordered]@{ adapterName = $AdapterName; ip4Address = $Ip; subnetMask = $Mask; defaultGateway = $Gateway; dnsServers = @($Dns); ipInterfaceType = $Type; vlanId = $Vlan; interfaceState = 'up' }
        $reported = [ordered]@{}
        foreach ($k in $config.Keys) { $reported[$k] = $config[$k] }
        $reported.interfaceDescription = $Description; $reported.componentId = 'PCI\VEN_8086&DEV_1572'; $reported.macAddress = $Mac; $reported.interfaceSpeed = 25000
        @{ desired = $config; reported = $reported }
    }
    # A job body as the service returns it, for a status the sequence names.
    function global:New-NetTJob {
        param([System.Collections.IDictionary]$Target, [string]$Status)
        $p = [ordered]@{ jobType = 'ApplyConfiguration'; deploymentMode = 'Deploy'; jobId = 'job-example'; targetConfiguration = $Target; startTimeUtc = [datetime]::UtcNow.ToString('o') }
        switch ($Status) {
            'Queued' {
                $p.status = 'DeploymentInProgress'; $p.provisioningState = 'Accepted'
                $p.reportedProperties = @{ deploymentStatus = @{ status = 'InProgress'; steps = @(@{ name = 'ApplyConfiguration'; status = 'InProgress'; description = 'Job is not yet triggered as other jobs are still running' }) } }
            }
            'Applying' {
                $p.status = 'DeploymentInProgress'; $p.provisioningState = 'Accepted'
                $p.reportedProperties = @{ deploymentStatus = @{ status = 'InProgress'; steps = @(@{ name = 'ApplyConfiguration'; status = 'Success' }, @{ name = 'ApplyNetworkConfiguration'; status = 'InProgress'; description = 'Apply network adapter configuration.' }) } }
            }
            'Succeeded' {
                $p.status = 'Succeeded'; $p.provisioningState = 'Succeeded'; $p.endTimeUtc = [datetime]::UtcNow.ToString('o')
                $p.reportedProperties = @{ percentComplete = 100; deploymentStatus = @{ status = 'Success'; steps = @(@{ name = 'ApplyConfiguration'; status = 'Success' }, @{ name = 'ApplyNetworkConfiguration'; status = 'Success' }) } }
            }
            'Failed' {
                $p.status = 'DeploymentFailed'; $p.provisioningState = 'Failed'
                $p.reportedProperties = @{ deploymentStatus = @{ status = 'Failed'; steps = @(@{ name = 'ApplyConfiguration'; status = 'Success' }, @{ name = 'ApplyNetworkConfiguration'; status = 'Failed'; description = 'Apply network adapter configuration.' }) } }
                $p.error = @{ code = 'NetworkConfigurationFailed'; message = 'The adapter rejected the configuration.' }
            }
        }
        @{ id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.AzureStackHCI/edgeMachines/node-01/networkAdapters/x/jobs/ApplyConfiguration'; name = 'ApplyConfiguration'; type = 'Microsoft.AzureStackHCI/edgeMachines/networkAdapters/jobs'; properties = $p }
    }
    # The stub edge machine: adapters by resource name; a job per adapter that walks its status sequence one GET at a time
    # and, when it reaches Succeeded, makes the adapter report its target.
    $global:netT_handler = {
        param($Path, $Method, $Payload)
        $global:netT_calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Payload = $Payload })
        if ($Path -match '/edgeMachines/[^/]+/networkAdapters\?') {
            if ($global:netT_noAdapters) { return New-NetTResponse 404 @{ error = @{ code = 'ResourceNotFound'; message = 'not found' } } }
            $value = foreach ($k in $global:netT_adapters.Keys) {
                $a = $global:netT_adapters[$k]
                @{ id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.AzureStackHCI/edgeMachines/node-01/networkAdapters/$k"; name = $k
                    type = 'Microsoft.AzureStackHCI/edgeMachines/networkAdapters'; properties = @{ networkConfiguration = $a.desired; reportedProperties = $a.reported; provisioningState = 'Succeeded' } }
            }
            return New-NetTResponse 200 @{ value = @($value) }
        }
        if ($Path -match '/networkAdapters/([^/?]+)/jobs/ApplyConfiguration\?') {
            $nic = $Matches[1]
            if ($Method -eq 'PUT') {
                $body = $Payload | ConvertFrom-Json -AsHashtable
                $sequence = @(if ($global:netT_sequence.ContainsKey($nic)) { $global:netT_sequence[$nic] } else { 'Succeeded' })
                $global:netT_jobs[$nic] = @{ Target = $body.properties.targetConfiguration; Sequence = $sequence; Index = 0 }
                $accepted = New-NetTJob $body.properties.targetConfiguration 'Queued'
                $accepted.properties.status = 'Running'
                return New-NetTResponse 201 $accepted
            }
            $job = $global:netT_jobs[$nic]
            if (-not $job) { return New-NetTResponse 404 @{ error = @{ code = 'ResourceNotFound'; message = 'not found' } } }
            $sequence = @($job.Sequence)
            $status = $sequence[[Math]::Min($job.Index, $sequence.Count - 1)]
            $job.Index++
            if ($status -eq 'Succeeded' -and $global:netT_adapters.Contains($nic)) {
                $a = $global:netT_adapters[$nic]
                foreach ($k in $job.Target.Keys) { $a.desired[$k] = $job.Target[$k]; $a.reported[$k] = $job.Target[$k] }
                if ($job.Target['ipInterfaceType'] -eq 'Dhcp') { foreach ($k in 'ip4Address', 'subnetMask', 'defaultGateway') { $a.reported[$k] = ''; $a.desired[$k] = '' } }
            }
            return New-NetTResponse 200 (New-NetTJob $job.Target $status)
        }
        New-NetTResponse 404 $null
    }
    function global:Invoke-AzRestMethod { [CmdletBinding()] param([string]$Path, [string]$Method, [string]$Payload) & $global:netT_handler $Path $Method $Payload }

    $script:writeParameters = {
        param([System.Collections.IDictionary]$Management, [string]$Name = 'params')
        $file = Join-Path $TestDrive "$Name-$([guid]::NewGuid().ToString('N')).json"
        $node = [ordered]@{ name = 'node-01'; service_tag = 'EXAMPLE1'; arc_machine_name = 'node-01' }
        if ($Management) { $node.management = $Management }
        @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = @{ nodes = @{ value = @($node) } } } |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $file
        $file
    }
    $script:static = { [ordered]@{ ip_assignment = 'static'; mac_address = '00-00-5E-00-53-AA'; adapter_name = ''; ip_address = '192.0.2.11'; subnet_mask = '255.255.255.0'; gateway = '192.0.2.1'; dns_servers = @('192.0.2.53', '192.0.2.54'); vlan_id = '0' } }
    $script:argsFor = {
        param([hashtable]$Arguments)
        $base = @{ SubscriptionId = '00000000-0000-0000-0000-000000000000'; ResourceGroupName = 'rg-example'; PollIntervalSeconds = 0; TimeoutMinutes = 5
            ChangeLogPath = $script:changeLog; EventLogPath = $script:events; InformationAction = 'SilentlyContinue'; WarningAction = 'SilentlyContinue' }
        foreach ($k in $Arguments.Keys) { $base[$k] = $Arguments[$k] }
        $base
    }
    $script:run = { param([hashtable]$Arguments) $a = & $script:argsFor $Arguments; & $script:setNetwork @a }
    $script:puts = { @($global:netT_calls | Where-Object Method -EQ 'PUT') }
    $script:eventsOf = { if (Test-Path -LiteralPath $script:events) { @(Get-Content -LiteralPath $script:events | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() } }
    $script:changesOf = { if (Test-Path -LiteralPath $script:changeLog) { @(Get-Content -LiteralPath $script:changeLog | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() } }
}

AfterAll {
    foreach ($name in 'Invoke-AzRestMethod', 'New-NetTResponse', 'New-NetTAdapter', 'New-NetTJob') { Remove-Item "Function:global:$name" -ErrorAction SilentlyContinue }
    Get-Variable -Scope Global -Name 'netT_*' -ErrorAction SilentlyContinue | Remove-Variable -Scope Global -Force -ErrorAction SilentlyContinue
}

Describe 'Network adapter helpers' {
    It 'normalises a MAC address whatever its separators and case' {
        foreach ($form in '00:00:5E:00:53:AA', '00-00-5e-00-53-aa', '00005E0053AA', '0000.5e00.53aa', ' 00:00:5e:00:53:aa ') {
            ConvertTo-ZtpMacKey $form | Should -Be '00005e0053aa' -Because $form
        }
        ConvertTo-ZtpMacKey '' | Should -Be ''
        { ConvertTo-ZtpMacKey '00:00:5E:00:53' } | Should -Throw "*isn't a MAC address*"
        { ConvertTo-ZtpMacKey '00:00:5E:00:53:ZZ' } | Should -Throw "*isn't a MAC address*"
        Format-ZtpMac '00005e0053aa' | Should -Be '00:00:5e:00:53:aa'
    }

    It 'reads a queued, a succeeded and a failed ApplyConfiguration job' {
        $target = [ordered]@{ adapterName = 'Port1'; ip4Address = '192.0.2.11'; ipInterfaceType = 'Static' }
        $queued = Get-ZtpNetworkJobState ((New-NetTJob $target 'Queued') | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
        $queued.Done | Should -BeFalse
        $queued.Status | Should -Be 'DeploymentInProgress'
        $queued.Text | Should -Match 'Job is not yet triggered as other jobs are still running'
        $queued.Target.Ip | Should -Be '192.0.2.11'
        $queued.StartTimeUtc | Should -BeOfType [datetime]
        $ok = Get-ZtpNetworkJobState ((New-NetTJob $target 'Succeeded') | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
        $ok.Succeeded | Should -BeTrue; $ok.Done | Should -BeTrue; $ok.Failed | Should -BeFalse
        $bad = Get-ZtpNetworkJobState ((New-NetTJob $target 'Failed') | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
        $bad.Failed | Should -BeTrue; $bad.Succeeded | Should -BeFalse
        $bad.FailureReason | Should -Match 'status DeploymentFailed'
        $bad.FailureReason | Should -Match 'step ApplyNetworkConfiguration Failed'
        $bad.FailureReason | Should -Match 'NetworkConfigurationFailed The adapter rejected the configuration'
        (Get-ZtpNetworkJobState $null).Exists | Should -BeFalse
    }

    It 'compares a reported configuration with the wanted one, DNS order and VLAN included' {
        $want = ConvertTo-ZtpNetworkSetting ([ordered]@{ ipInterfaceType = 'Static'; ip4Address = '192.0.2.11'; subnetMask = '255.255.255.0'; defaultGateway = '192.0.2.1'; dnsServers = @('192.0.2.53', '192.0.2.54'); vlanId = 0; interfaceState = 'up' })
        $same = ConvertTo-ZtpNetworkSetting ([ordered]@{ ipInterfaceType = 'static'; ip4Address = '192.0.2.11'; subnetMask = '255.255.255.0'; defaultGateway = '192.0.2.1'; dnsServers = @('192.0.2.53', '192.0.2.54'); interfaceState = 'Up' })
        Test-ZtpNetworkSettingMatch -Reported $same -Target $want | Should -BeTrue -Because 'case does not matter and an absent vlanId is 0'
        $swapped = ConvertTo-ZtpNetworkSetting ([ordered]@{ ipInterfaceType = 'Static'; ip4Address = '192.0.2.11'; subnetMask = '255.255.255.0'; defaultGateway = '192.0.2.1'; dnsServers = @('192.0.2.54', '192.0.2.53'); vlanId = 0 })
        Test-ZtpNetworkSettingMatch -Reported $swapped -Target $want | Should -BeFalse
        $vlan = ConvertTo-ZtpNetworkSetting ([ordered]@{ ipInterfaceType = 'Static'; ip4Address = '192.0.2.11'; subnetMask = '255.255.255.0'; defaultGateway = '192.0.2.1'; dnsServers = @('192.0.2.53', '192.0.2.54'); vlanId = 7 })
        Test-ZtpNetworkSettingMatch -Reported $vlan -Target $want | Should -BeFalse
    }
}

Describe 'Set-ZtpManagementAddress.ps1' {
    BeforeEach {
        $global:netT_calls = [System.Collections.Generic.List[object]]::new()
        $global:netT_jobs = @{}
        $global:netT_sequence = @{}
        $global:netT_noAdapters = $false
        # The live failure: the LOM named by MAC is on DHCP; the static address sits on a storage port.
        $global:netT_adapters = [ordered]@{
            $script:lom     = New-NetTAdapter -AdapterName 'Port1' -Mac '00005e0053aa' -Description 'Example LOM' -Type 'Dhcp' -Ip '192.0.2.200' -Mask '255.255.255.0' -Gateway '192.0.2.1' -Dns '192.0.2.53'
            $script:storage = New-NetTAdapter -AdapterName 'Port3' -Mac '00005e0053bb' -Description 'Example storage NIC' -Type 'Static' -Ip '192.0.2.11' -Mask '255.255.255.0' -Gateway '192.0.2.1' -Dns '192.0.2.53', '192.0.2.54'
            $script:spare   = New-NetTAdapter -AdapterName 'Port4' -Mac '00005e0053cc' -Description 'Example storage NIC' -Type 'Dhcp'
        }
        $script:changeLog = Join-Path $TestDrive "network-changes-$([guid]::NewGuid().ToString('N')).jsonl"
        $script:events = Join-Path $TestDrive "events-$([guid]::NewGuid().ToString('N')).jsonl"
        Mock Start-Sleep {}
    }

    It 'plans without -Execute: reads the adapters, prints the release and the static address, changes nothing' {
        $params = & $script:writeParameters (& $script:static)
        $out = @(& $script:run @{ ParameterFile = $params })
        & $script:puts | Should -BeNullOrEmpty
        $plan = @($out | Where-Object { $_ -is [string] })
        $plan[0] | Should -BeLike 'PLAN: node-01: release 192.0.2.11 from Port3 (00:00:5e:00:53:bb) first: ApplyConfiguration Dhcp*'
        $plan[1] | Should -BeLike 'PLAN: node-01: ApplyConfiguration on Port1 (00:00:5e:00:53:aa): Static 192.0.2.11 255.255.255.0 gw 192.0.2.1 DNS 192.0.2.53,192.0.2.54 VLAN 0 up*'
        $row = $out | Where-Object { $_ -isnot [string] }
        $row.Status | Should -Be 'Planned'
        $row.Mode | Should -Be 'static'
        Test-Path -LiteralPath $script:changeLog | Should -BeFalse
        Test-Path -LiteralPath $script:events | Should -BeFalse
    }

    It 'plans for a node whose edge machine has no adapters yet' {
        $global:netT_noAdapters = $true
        $out = @(& $script:run @{ ParameterFile = (& $script:writeParameters (& $script:static)) })
        ($out | Where-Object { $_ -is [string] }) | Should -BeLike '*reports no network adapters yet*00:00:5e:00:53:aa*'
        { & $script:run @{ ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false } } | Should -Throw '*reports no network adapters. Run the Network stage after Ready*'
    }

    It 'finds the management adapter by MAC whatever the separators and case on either side' {
        $global:netT_adapters[$script:storage].reported.ip4Address = '192.0.2.21'
        $global:netT_adapters[$script:lom].reported.macAddress = '00:00:5E:00:53:AA'
        $m = & $script:static; $m.mac_address = '00005e0053aa'
        $row = & $script:run @{ ParameterFile = (& $script:writeParameters $m); Execute = $true; Confirm = $false }
        $put = @(& $script:puts)
        $put.Count | Should -Be 1
        $put[0].Path | Should -Match "/edgeMachines/node-01/networkAdapters/$($script:lom)/jobs/ApplyConfiguration\?api-version=2026-10-01$"
        $body = $put[0].Payload | ConvertFrom-Json
        $body.properties.jobType | Should -Be 'ApplyConfiguration'
        $body.properties.deploymentMode | Should -Be 'Deploy'
        $t = $body.properties.targetConfiguration
        $t.adapterName | Should -Be 'Port1' -Because 'adapterName comes from the adapter''s own networkConfiguration'
        $t.ip4Address | Should -Be '192.0.2.11'; $t.subnetMask | Should -Be '255.255.255.0'; $t.defaultGateway | Should -Be '192.0.2.1'
        @($t.dnsServers) | Should -Be @('192.0.2.53', '192.0.2.54'); $t.ipInterfaceType | Should -Be 'Static'; $t.vlanId | Should -Be 0; $t.interfaceState | Should -Be 'up'
        $row.Status | Should -Be 'Changed'
        $row.AdapterName | Should -Be 'Port1'
        $row.MacAddress | Should -Be '00:00:5e:00:53:aa'
        @($row.Released).Count | Should -Be 0
    }

    It 'releases the address from the adapter that holds it first, waits, then sets it on the management adapter' {
        $row = & $script:run @{ ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false }
        $put = @(& $script:puts)
        $put.Count | Should -Be 2
        $put[0].Path | Should -Match "/networkAdapters/$($script:storage)/jobs/ApplyConfiguration\?"
        $release = ($put[0].Payload | ConvertFrom-Json).properties.targetConfiguration
        $release.ipInterfaceType | Should -Be 'Dhcp'; $release.adapterName | Should -Be 'Port3'
        $release.PSObject.Properties['ip4Address'] | Should -BeNullOrEmpty
        $put[1].Path | Should -Match "/networkAdapters/$($script:lom)/jobs/ApplyConfiguration\?"
        ($put[1].Payload | ConvertFrom-Json).properties.targetConfiguration.ipInterfaceType | Should -Be 'Static'
        # The static job is sent only after the release job succeeded and the storage port no longer reported the address.
        $order = @($global:netT_calls | ForEach-Object { "$($_.Method) $(if ($_.Path -match "/networkAdapters/([^/?]+)/jobs") { $Matches[1] } else { 'list' })" })
        $releaseDone = [array]::LastIndexOf($order, "GET $($script:storage)")
        [array]::IndexOf($order, "PUT $($script:lom)") | Should -BeGreaterThan $releaseDone
        $row.Status | Should -Be 'Changed'
        @($row.Released) | Should -Be @('Port3')
        $global:netT_adapters[$script:lom].reported.ip4Address | Should -Be '192.0.2.11'
        $global:netT_adapters[$script:storage].reported.ip4Address | Should -Be ''

        $changes = & $script:changesOf
        @($changes | ForEach-Object { "$($_.action) $($_.phase)" }) | Should -Be @('release requested', 'release applied', 'apply requested', 'apply applied')
        $changes[1].adapterName | Should -Be 'Port3'; $changes[1].before.ip4Address | Should -Be '192.0.2.11'; $changes[1].after.ipInterfaceType | Should -Be 'Dhcp'
        $changes[3].macAddress | Should -Be '00:00:5e:00:53:aa'; $changes[3].after.ip4Address | Should -Be '192.0.2.11'
        $events = & $script:eventsOf
        @($events | ForEach-Object stage | Select-Object -Unique) | Should -Be @('Network')
        $states = @($events | ForEach-Object state)
        [array]::IndexOf($states, 'ManagementAddressReleased') | Should -BeLessThan ([array]::IndexOf($states, 'ManagementAddressSet'))
        ($events | Where-Object state -EQ 'ManagementAddressSet').evidence | Should -Match 'Port1 \(00:00:5e:00:53:aa\) Static 192\.0\.2\.11.*released from Port3'
    }

    It 'changes nothing when the management adapter already reports the static configuration' {
        $global:netT_adapters[$script:storage] = New-NetTAdapter -AdapterName 'Port3' -Mac '00005e0053bb' -Description 'Example storage NIC' -Type 'Dhcp'
        $global:netT_adapters[$script:lom] = New-NetTAdapter -AdapterName 'Port1' -Mac '00005e0053aa' -Description 'Example LOM' -Type 'Static' -Ip '192.0.2.11' -Mask '255.255.255.0' -Gateway '192.0.2.1' -Dns '192.0.2.53', '192.0.2.54'
        $row = & $script:run @{ ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false }
        & $script:puts | Should -BeNullOrEmpty
        $row.Status | Should -Be 'AlreadySet'
        $row.Address | Should -Be '192.0.2.11'
        Test-Path -LiteralPath $script:changeLog | Should -BeFalse
        @(& $script:eventsOf | ForEach-Object state) | Should -Be @('ManagementAddressAlreadySet')
        # And the plan says so.
        $plan = @(& $script:run @{ ParameterFile = (& $script:writeParameters (& $script:static)) } | Where-Object { $_ -is [string] })
        $plan | Should -BeLike '*Port1 (00:00:5e:00:53:aa) already reports Static 192.0.2.11*no change*'
    }

    It 'follows a job that waits queued behind other jobs until it succeeds, logging each status change once' {
        $global:netT_adapters[$script:storage].reported.ip4Address = '192.0.2.21'
        $global:netT_sequence[$script:lom] = @('Queued', 'Queued', 'Queued', 'Applying', 'Succeeded')
        $a = & $script:argsFor @{ ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false }
        $row = & $script:setNetwork @a -InformationVariable info
        $row.Status | Should -Be 'Changed'
        @($global:netT_calls | Where-Object { $_.Method -eq 'GET' -and $_.Path -like "*/$($script:lom)/jobs/*" }).Count | Should -Be 6 -Because 'one look before the PUT, then five polls'
        $text = @($info | ForEach-Object { [string]$_.MessageData }) -join "`n"
        ([regex]::Matches($text, 'Job is not yet triggered as other jobs are still running')).Count | Should -Be 1
        $text | Should -Match 'Port1 \(00:00:5e:00:53:aa\) ApplyConfiguration: DeploymentInProgress'
        $text | Should -Match 'ApplyConfiguration: Succeeded'
        $status = @(& $script:eventsOf | Where-Object state -EQ 'NetworkJobStatus' | ForEach-Object evidence)
        $status.Count | Should -Be 3
        $status[0] | Should -Match 'not yet triggered'
        $status[2] | Should -Match 'Succeeded'
    }

    It 'stops with the reason when the job fails, and records the failure' {
        $global:netT_adapters[$script:storage].reported.ip4Address = '192.0.2.21'
        $global:netT_sequence[$script:lom] = @('Applying', 'Failed')
        { & $script:run @{ ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false } } |
            Should -Throw '*Port1 (00:00:5e:00:53:aa) ApplyConfiguration (apply) failed: status DeploymentFailed*step ApplyNetworkConfiguration Failed*NetworkConfigurationFailed*'
        @(& $script:changesOf | ForEach-Object phase) | Should -Be @('requested', 'failed')
        $failed = & $script:eventsOf | Where-Object state -EQ 'ManagementAddressFailed'
        $failed.level | Should -Be 'Error'
        $failed.nextAction | Should -Match '-From Network'
    }

    It 'stops when a job does not finish within the timeout' {
        $global:netT_adapters[$script:storage].reported.ip4Address = '192.0.2.21'
        $global:netT_sequence[$script:lom] = @('Queued')
        { & $script:run @{ ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false; TimeoutMinutes = 0 } } |
            Should -Throw "*didn't finish within 0 minutes; last: DeploymentInProgress*not yet triggered*"
        @(& $script:changesOf | ForEach-Object phase) | Should -Be @('requested', 'timedOut')
    }

    It 'follows an unfinished job with the same target instead of sending another' {
        $global:netT_adapters[$script:storage].reported.ip4Address = '192.0.2.21'
        $target = [ordered]@{ adapterName = 'Port1'; ip4Address = '192.0.2.11'; subnetMask = '255.255.255.0'; defaultGateway = '192.0.2.1'; dnsServers = @('192.0.2.53', '192.0.2.54'); ipInterfaceType = 'Static'; vlanId = 0; interfaceState = 'up' }
        $global:netT_jobs[$script:lom] = @{ Target = $target; Sequence = @('Queued', 'Queued', 'Succeeded'); Index = 0 }
        $row = & $script:run @{ ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false }
        & $script:puts | Should -BeNullOrEmpty
        $row.Status | Should -Be 'Changed'
    }

    It 'fails clearly when no adapter reports the management MAC, listing the MACs it found' {
        $m = & $script:static; $m.mac_address = '00:00:5E:00:53:DD'
        { & $script:run @{ ParameterFile = (& $script:writeParameters $m); Execute = $true; Confirm = $false } } |
            Should -Throw '*no network adapter of edge machine node-01 reports the management MAC 00:00:5e:00:53:dd. Found: Port1 00:00:5e:00:53:aa (Example LOM); Port3 00:00:5e:00:53:bb (Example storage NIC); Port4 00:00:5e:00:53:cc*'
        & $script:puts | Should -BeNullOrEmpty
        { & $script:run @{ ParameterFile = (& $script:writeParameters $m) } } | Should -Throw '*reports the management MAC 00:00:5e:00:53:dd*' -Because 'the plan fails the same way'
    }

    It 'only reports the management adapter for dhcp, dhcp_reservation and preconfigured' {
        foreach ($mode in 'dhcp', 'dhcp_reservation', 'preconfigured') {
            $global:netT_calls.Clear()
            $m = & $script:static; $m.ip_assignment = $mode
            $row = & $script:run @{ ParameterFile = (& $script:writeParameters $m); Execute = $true; Confirm = $false }
            & $script:puts | Should -BeNullOrEmpty -Because $mode
            $row.Status | Should -Be 'Reported'
            $row.Mode | Should -Be $mode
            $row.AdapterName | Should -Be 'Port1'
            $row.Address | Should -Be '192.0.2.200'
        }
        (& $script:eventsOf | Select-Object -Last 1).state | Should -Be 'ManagementAddressReported'
    }

    It 'leaves a node without a management block alone and refuses an unknown node' {
        $row = & $script:run @{ ParameterFile = (& $script:writeParameters $null); Execute = $true; Confirm = $false }
        $row.Status | Should -Be 'NotConfigured'
        $global:netT_calls.Count | Should -Be 0
        { & $script:run @{ ParameterFile = (& $script:writeParameters (& $script:static)); Node = 'node-09' } } | Should -Throw '*Unknown node(s) node-09*'
    }

    It 'needs the address, mask and gateway for a static node' {
        $m = & $script:static; $m.gateway = ''; $m.subnet_mask = ''
        { & $script:run @{ ParameterFile = (& $script:writeParameters $m) } } | Should -Throw '*needs gateway, subnet_mask in the parameters file*'
    }
}
