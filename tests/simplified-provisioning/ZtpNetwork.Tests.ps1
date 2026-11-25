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
        $p = [ordered]@{ jobType = 'ApplyConfiguration'; deploymentMode = 'Deploy'; jobId = 'job-iic-01'; targetConfiguration = $Target; startTimeUtc = [datetime]::UtcNow.ToString('o') }
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
        @{ id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-iic-azl-01/providers/Microsoft.AzureStackHCI/edgeMachines/node-01/networkAdapters/x/jobs/ApplyConfiguration'; name = 'ApplyConfiguration'; type = 'Microsoft.AzureStackHCI/edgeMachines/networkAdapters/jobs'; properties = $p }
    }
    # The stub edge machine: adapters by resource name; a job per adapter that walks its status sequence one GET at a time
    # and, when it reaches Succeeded, makes the adapter report its target.
    $global:netT_handler = {
        param($Path, $Method, $Payload)
        $global:netT_calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Payload = $Payload })
        if ($Path -match '/edgeMachines/[^/]+/networkAdapters\?') {
            $emptyNow = $global:netT_noAdapters -or ((Get-Variable netT_emptyReads -Scope Global -ErrorAction SilentlyContinue) -and $global:netT_emptyReads -gt 0)
            if ($emptyNow) { if (-not $global:netT_noAdapters) { $global:netT_emptyReads-- }; return New-NetTResponse 404 @{ error = @{ code = 'ResourceNotFound'; message = 'not found' } } }
            $value = foreach ($k in $global:netT_adapters.Keys) {
                $a = $global:netT_adapters[$k]
                @{ id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-iic-azl-01/providers/Microsoft.AzureStackHCI/edgeMachines/node-01/networkAdapters/$k"; name = $k
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
        $node = [ordered]@{ name = 'node-01'; service_tag = 'IICSN0001'; arc_machine_name = 'node-01' }
        if ($Management) { $node.management = $Management }
        @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = @{ nodes = @{ value = @($node) } } } |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $file
        $file
    }
    $script:static = { [ordered]@{ ip_assignment = 'static'; mac_address = '00-00-5E-00-53-AA'; adapter_name = ''; ip_address = '192.0.2.11'; subnet_mask = '255.255.255.0'; gateway = '192.0.2.1'; dns_servers = @('192.0.2.53', '192.0.2.54'); vlan_id = '0' } }
    $script:argsFor = {
        param([hashtable]$Arguments)
        $base = @{ SubscriptionId = '00000000-0000-0000-0000-000000000000'; ResourceGroupName = 'rg-iic-azl-01'; PollIntervalSeconds = 0; TimeoutMinutes = 5; AdaptersTimeoutMinutes = 0
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

Describe 'Set-ZtpManagementAddress.ps1 -ApplyThroughAzure (opt-in, unreliable)' {
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
        $out = @(& $script:run @{ ApplyThroughAzure = $true; ParameterFile = $params })
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
        $out = @(& $script:run @{ ApplyThroughAzure = $true; ParameterFile = (& $script:writeParameters (& $script:static)) })
        ($out | Where-Object { $_ -is [string] }) | Should -BeLike '*reports no network adapters yet*00:00:5e:00:53:aa*'
        { & $script:run @{ ApplyThroughAzure = $true; ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false } } | Should -Throw '*reports no network adapters. Run the Network stage after Ready*'
    }

    It 'finds the management adapter by MAC whatever the separators and case on either side' {
        $global:netT_adapters[$script:storage].reported.ip4Address = '192.0.2.21'
        $global:netT_adapters[$script:lom].reported.macAddress = '00:00:5E:00:53:AA'
        $m = & $script:static; $m.mac_address = '00005e0053aa'
        $row = & $script:run @{ ApplyThroughAzure = $true; ParameterFile = (& $script:writeParameters $m); Execute = $true; Confirm = $false }
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
        $row = & $script:run @{ ApplyThroughAzure = $true; ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false }
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
        $row = & $script:run @{ ApplyThroughAzure = $true; ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false }
        & $script:puts | Should -BeNullOrEmpty
        $row.Status | Should -Be 'AlreadySet'
        $row.Address | Should -Be '192.0.2.11'
        Test-Path -LiteralPath $script:changeLog | Should -BeFalse
        @(& $script:eventsOf | ForEach-Object state) | Should -Be @('ManagementAddressAlreadySet')
        # And the plan says so.
        $plan = @(& $script:run @{ ApplyThroughAzure = $true; ParameterFile = (& $script:writeParameters (& $script:static)) } | Where-Object { $_ -is [string] })
        $plan | Should -BeLike '*Port1 (00:00:5e:00:53:aa) already reports Static 192.0.2.11*no change*'
    }

    It 'follows a job that waits queued behind other jobs until it succeeds, logging each status change once' {
        $global:netT_adapters[$script:storage].reported.ip4Address = '192.0.2.21'
        $global:netT_sequence[$script:lom] = @('Queued', 'Queued', 'Queued', 'Applying', 'Succeeded')
        $a = & $script:argsFor @{ ApplyThroughAzure = $true; ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false }
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
        { & $script:run @{ ApplyThroughAzure = $true; ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false } } |
            Should -Throw '*Port1 (00:00:5e:00:53:aa) ApplyConfiguration (apply) failed: status DeploymentFailed*step ApplyNetworkConfiguration Failed*NetworkConfigurationFailed*'
        @(& $script:changesOf | ForEach-Object phase) | Should -Be @('requested', 'failed')
        $failed = & $script:eventsOf | Where-Object state -EQ 'ManagementAddressFailed'
        $failed.level | Should -Be 'Error'
        $failed.nextAction | Should -Match '-From Network'
    }

    It 'stops when a job does not finish within the timeout' {
        $global:netT_adapters[$script:storage].reported.ip4Address = '192.0.2.21'
        $global:netT_sequence[$script:lom] = @('Queued')
        { & $script:run @{ ApplyThroughAzure = $true; ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false; TimeoutMinutes = 0 } } |
            Should -Throw "*didn't finish within 0 minutes; last: DeploymentInProgress*not yet triggered*"
        @(& $script:changesOf | ForEach-Object phase) | Should -Be @('requested', 'timedOut')
    }

    It 'follows an unfinished job with the same target instead of sending another' {
        $global:netT_adapters[$script:storage].reported.ip4Address = '192.0.2.21'
        $target = [ordered]@{ adapterName = 'Port1'; ip4Address = '192.0.2.11'; subnetMask = '255.255.255.0'; defaultGateway = '192.0.2.1'; dnsServers = @('192.0.2.53', '192.0.2.54'); ipInterfaceType = 'Static'; vlanId = 0; interfaceState = 'up' }
        $global:netT_jobs[$script:lom] = @{ Target = $target; Sequence = @('Queued', 'Queued', 'Succeeded'); Index = 0 }
        $row = & $script:run @{ ApplyThroughAzure = $true; ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false }
        & $script:puts | Should -BeNullOrEmpty
        $row.Status | Should -Be 'Changed'
    }

    It 'fails clearly when no adapter reports the management MAC, listing the MACs it found' {
        $m = & $script:static; $m.mac_address = '00:00:5E:00:53:DD'
        { & $script:run @{ ApplyThroughAzure = $true; ParameterFile = (& $script:writeParameters $m); Execute = $true; Confirm = $false } } |
            Should -Throw '*no network adapter of edge machine node-01 reports the management MAC 00:00:5e:00:53:dd. Found: Port1 00:00:5e:00:53:aa (Example LOM); Port3 00:00:5e:00:53:bb (Example storage NIC); Port4 00:00:5e:00:53:cc*'
        & $script:puts | Should -BeNullOrEmpty
        { & $script:run @{ ApplyThroughAzure = $true; ParameterFile = (& $script:writeParameters $m) } } | Should -Throw '*reports the management MAC 00:00:5e:00:53:dd*' -Because 'the plan fails the same way'
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
        { & $script:run @{ ApplyThroughAzure = $true; ParameterFile = (& $script:writeParameters $m) } } | Should -Throw '*needs gateway, subnet_mask in the parameters file*'
    }
}

Describe 'Set-ZtpManagementAddress.ps1 verify-only (the default)' {
    BeforeEach {
        $global:netT_calls = [System.Collections.Generic.List[object]]::new()
        $global:netT_jobs = @{}
        $global:netT_sequence = @{}
        $global:netT_noAdapters = $false
        # The live finding (Dell AX-760, build 2610): the Device stage set the static by MAC, then the OS install reset every
        # port to DHCP. The management port (an onboard LOM in this example) has a DHCP lease; nothing holds the static.
        $global:netT_adapters = [ordered]@{
            $script:lom     = New-NetTAdapter -AdapterName 'Port1' -Mac '00005e0053aa' -Description 'Example LOM' -Type 'Dhcp' -Ip '192.0.2.116' -Mask '255.255.255.0' -Gateway '192.0.2.1' -Dns '192.0.2.53'
            $script:storage = New-NetTAdapter -AdapterName 'Port3' -Mac '00005e0053bb' -Description 'Example storage NIC' -Type 'Dhcp'
            $script:spare   = New-NetTAdapter -AdapterName 'Port4' -Mac '00005e0053cc' -Description 'Example storage NIC' -Type 'Dhcp'
        }
        $script:changeLog = Join-Path $TestDrive "network-changes-$([guid]::NewGuid().ToString('N')).jsonl"
        $script:events = Join-Path $TestDrive "events-$([guid]::NewGuid().ToString('N')).jsonl"
        Mock Start-Sleep {}
        $script:execute = { param([System.Collections.IDictionary]$Management) & $script:run @{ ParameterFile = (& $script:writeParameters $Management); Execute = $true; Confirm = $false } }
        $script:noJobs = { @($global:netT_calls | Where-Object { $_.Method -ne 'GET' -or $_.Path -match '/jobs/' }) | Should -BeNullOrEmpty -Because 'verify-only never sends, reads or waits on a Microsoft job' }
    }

    It 'Mode B: records a static address the OS install reset to DHCP as Deferred to OS configuration, and never sends a job' {
        $row = & $script:execute (& $script:static)
        & $script:noJobs
        $row.Status | Should -Be 'Deferred'
        $row.Verified | Should -BeFalse
        $row.Reason | Should -Be 'Mode B (Static with DHCP): the management port Port1 (MAC 00:00:5e:00:53:aa, Example LOM) has DHCP 192.0.2.116 after the install; expected static 192.0.2.11; OS configuration sets it by MAC.'
        $row.AdapterName | Should -Be 'Port1'
        $row.Address | Should -Be '192.0.2.116'
        Test-Path -LiteralPath $script:changeLog | Should -BeFalse
        $events = @(& $script:eventsOf)
        @($events | ForEach-Object state) | Should -Be @('ManagementAddressDeferredToOsConfiguration')
        $events[0].stage | Should -Be 'Network'
        $events[0].level | Should -Be 'Info'
        $events[0].nextAction | Should -Match 'OS configuration.*Set-AzureLocalNodeConfiguration\.ps1.*management MAC'
    }

    It 'Mode C: names the mode and says OS configuration sets it over Arc when the management port has no address' {
        $global:netT_adapters[$script:lom] = New-NetTAdapter -AdapterName 'Port1' -Mac '00005e0053aa' -Description 'Example LOM' -Type 'Dhcp'
        $m = & $script:static; $m.management_dhcp = $false
        $row = & $script:execute $m
        & $script:noJobs
        $row.Status | Should -Be 'Deferred'
        $row.Reason | Should -Be 'Mode C (Static without management DHCP): the management port Port1 (MAC 00:00:5e:00:53:aa, Example LOM) has DHCP and no address after the install; expected static 192.0.2.11; OS configuration sets it by MAC over Arc.'
    }

    It 'keys off the MAC alone: a management port on any card or slot, under any name' {
        # A converged ConnectX port carries the management role here; the onboard ports aren't the management port.
        $global:netT_adapters[$script:storage] = New-NetTAdapter -AdapterName 'Slot 3 Port 1' -Mac '00005e0053bb' -Description 'Example ConnectX-6 Dx' -Type 'Static' -Ip '192.0.2.11' -Mask '255.255.255.0' -Gateway '192.0.2.1'
        $m = & $script:static; $m.mac_address = '00:00:5E:00:53:BB'
        $row = & $script:execute $m
        $row.Status | Should -Be 'AlreadySet'
        $row.Verified | Should -BeTrue
        $row.AdapterName | Should -Be 'Slot 3 Port 1'
    }

    It 'verifies a static address that is already on the management port' {
        $global:netT_adapters[$script:lom] = New-NetTAdapter -AdapterName 'Port1' -Mac '00005e0053aa' -Description 'Example LOM' -Type 'Static' -Ip '192.0.2.11' -Mask '255.255.255.0' -Gateway '192.0.2.1' -Dns '192.0.2.53', '192.0.2.54'
        $row = & $script:execute (& $script:static)
        & $script:noJobs
        $row.Status | Should -Be 'AlreadySet'
        $row.Verified | Should -BeTrue
        $row.Reason | Should -BeNullOrEmpty
        @(& $script:eventsOf | ForEach-Object state) | Should -Be @('ManagementAddressAlreadySet')
    }

    It 'does not verify a static address another port holds, and names that port' {
        $global:netT_adapters[$script:storage] = New-NetTAdapter -AdapterName 'Port3' -Mac '00005e0053bb' -Description 'Example storage NIC' -Type 'Static' -Ip '192.0.2.11' -Mask '255.255.255.0'
        $row = & $script:execute (& $script:static)
        & $script:noJobs
        $row.Status | Should -Be 'Deferred'
        $row.Reason | Should -Match 'Port1 \(MAC 00:00:5e:00:53:aa, Example LOM\) has DHCP 192\.0\.2\.116 after the install; Port3 \(MAC 00:00:5e:00:53:bb\) also has 192\.0\.2\.11; expected static 192\.0\.2\.11'
    }

    It 'Mode A: verifies the reserved address, and says what to check when the port has another one' {
        $m = & $script:static; $m.ip_assignment = 'dhcp_reservation'; $m.ip_address = '192.0.2.116'
        $row = & $script:execute $m
        & $script:noJobs
        $row.Status | Should -Be 'Reported'
        $row.Verified | Should -BeTrue
        (& $script:eventsOf | Select-Object -Last 1).level | Should -Be 'Info'
        $m.ip_address = '192.0.2.11'
        $row = & $script:execute $m
        $row.Verified | Should -BeFalse
        $row.Reason | Should -Be 'Mode A (Reserved): the management port Port1 (MAC 00:00:5e:00:53:aa, Example LOM) has DHCP 192.0.2.116 after the install; expected the reserved 192.0.2.11; check the DHCP reservation for MAC 00:00:5e:00:53:aa.'
        (& $script:eventsOf | Select-Object -Last 1).level | Should -Be 'Warning'
    }

    It 'Mode A without ip_address: verified when the port has any DHCP address' {
        $m = & $script:static; $m.ip_assignment = 'dhcp_reservation'; $m.ip_address = ''
        (& $script:execute $m).Verified | Should -BeTrue
        $global:netT_adapters[$script:lom] = New-NetTAdapter -AdapterName 'Port1' -Mac '00005e0053aa' -Description 'Example LOM' -Type 'Dhcp'
        $row = & $script:execute $m
        $row.Verified | Should -BeFalse
        $row.Reason | Should -Match '^Mode A \(Reserved\): the management port Port1 .* has DHCP and no address after the install; expected a reserved DHCP address'
    }

    It 'only reports dhcp and preconfigured, never changing them' {
        foreach ($mode in 'dhcp', 'preconfigured') {
            $m = & $script:static; $m.ip_assignment = $mode
            $row = & $script:execute $m
            $row.Status | Should -Be 'Reported' -Because $mode
            $row.Verified | Should -BeFalse -Because $mode
            $row.Reason | Should -Match "^$mode.*Port1 .* has DHCP 192\.0\.2\.116 after the install; expected 192\.0\.2\.11" -Because $mode
        }
        $row.Reason | Should -Match 'preconfigured: the operator sets it'
        & $script:noJobs
    }

    It 'records a node whose edge machine reports no adapters yet instead of failing' {
        $global:netT_noAdapters = $true
        $row = & $script:execute (& $script:static)
        $row.Status | Should -Be 'Deferred'
        $row.Reason | Should -Match 'reports no network adapters yet'
        $m = & $script:static; $m.ip_assignment = 'dhcp_reservation'
        $row = & $script:execute $m
        $row.Status | Should -Be 'Reported'
        $row.Verified | Should -BeFalse
    }

    It 'still stops on a management MAC no port reports: the file is wrong, and OS configuration would fail the same way' {
        $m = & $script:static; $m.mac_address = '00:00:5E:00:53:DD'
        { & $script:execute $m } | Should -Throw '*no network adapter of edge machine node-01 reports the management MAC 00:00:5e:00:53:dd*'
        (& $script:eventsOf | Select-Object -Last 1).state | Should -Be 'ManagementAddressFailed'
    }

    It 'plans without -Execute: prints the verdict, writes no event' {
        $out = @(& $script:run @{ ParameterFile = (& $script:writeParameters (& $script:static)) })
        ($out | Where-Object { $_ -is [string] }) | Should -BeLike 'PLAN: node-01: static; verify only, no change. Mode B (Static with DHCP): the management port Port1*expected static 192.0.2.11; OS configuration sets it by MAC.'
        Test-Path -LiteralPath $script:events | Should -BeFalse
        & $script:noJobs
    }
}

Describe 'Get-ZtpManagementMode' {
    It 'names <IpAssignment> with management DHCP <Dhcp> as <Label>' -ForEach @(
        @{ IpAssignment = 'dhcp_reservation'; Dhcp = $true; Mode = 'A'; Label = 'Mode A (Reserved)' }
        @{ IpAssignment = 'static'; Dhcp = $true; Mode = 'B'; Label = 'Mode B (Static with DHCP)' }
        @{ IpAssignment = 'STATIC'; Dhcp = $true; Mode = 'B'; Label = 'Mode B (Static with DHCP)' }
        @{ IpAssignment = 'static'; Dhcp = $false; Mode = 'C'; Label = 'Mode C (Static without management DHCP)' }
        @{ IpAssignment = 'dhcp'; Dhcp = $true; Mode = ''; Label = 'dhcp without a reservation (not Mode A, B or C)' }
        @{ IpAssignment = 'preconfigured'; Dhcp = $true; Mode = ''; Label = 'preconfigured' }
    ) {
        $m = Get-ZtpManagementMode -IpAssignment $IpAssignment -ManagementDhcp $Dhcp
        $m.Mode | Should -Be $Mode
        $m.Label | Should -Be $Label
    }
}

Describe 'Set-ZtpManagementAddress.ps1 waits for the machine to report its network adapters' {
    BeforeEach {
        $global:netT_calls = [System.Collections.Generic.List[object]]::new()
        $global:netT_jobs = @{}; $global:netT_sequence = @{}
        $global:netT_noAdapters = $false
        $global:netT_emptyReads = 0
        $global:netT_adapters = [ordered]@{
            $script:lom = New-NetTAdapter -AdapterName 'Port1' -Mac '00005e0053aa' -Description 'Example LOM' -Type 'Static' -Ip '192.0.2.11' -Mask '255.255.255.0' -Gateway '192.0.2.1' -Dns '192.0.2.53'
        }
        $script:changeLog = Join-Path $TestDrive "network-changes-$([guid]::NewGuid().ToString('N')).jsonl"
        $script:events = Join-Path $TestDrive "events-$([guid]::NewGuid().ToString('N')).jsonl"
        Mock Start-Sleep {}
        $script:eventsNow = { if (Test-Path -LiteralPath $script:events) { @(Get-Content -LiteralPath $script:events | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() } }
        $script:reads = { @($global:netT_calls | Where-Object { $_.Method -eq 'GET' -and $_.Path -match '/networkAdapters\?' }).Count }
    }
    AfterAll { Remove-Variable -Scope Global -Name netT_emptyReads -ErrorAction SilentlyContinue }

    It 'polls until the management MAC appears, says it is waiting, then judges the port as usual' {
        $global:netT_emptyReads = 2
        $row = & $script:run @{ ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false; AdaptersTimeoutMinutes = 1 }
        (& $script:reads) | Should -Be 3 -Because 'two empty reads, then the list'
        $row.Verified | Should -BeTrue
        $row.Status | Should -Be 'AlreadySet'
        $row.AdaptersReported | Should -BeTrue
        $waiting = @(& $script:eventsNow | Where-Object state -EQ 'WaitingForNetworkAdapters')
        $waiting.Count | Should -Be 1
        $waiting[0].level | Should -Be 'Info'
        $waiting[0].evidence | Should -BeLike 'waiting for the machine to report its network adapters*'
    }

    It 'does not wait, or write the event, when the adapters are there at once' {
        $row = & $script:run @{ ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false; AdaptersTimeoutMinutes = 1 }
        (& $script:reads) | Should -Be 1
        @(& $script:eventsNow | Where-Object state -EQ 'WaitingForNetworkAdapters').Count | Should -Be 0
        $row.Verified | Should -BeTrue
    }

    It 'after the budget: not verified, adapters never reported within N minutes, a Warning event, and the handoff is told to look again' {
        $global:netT_noAdapters = $true
        $row = & $script:run @{ ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false; AdaptersTimeoutMinutes = 0.02 }
        $row.Verified | Should -BeFalse
        $row.Status | Should -Be 'NeverReported' -Because 'a static node whose port was never seen is not the Deferred success (Sonar counts ManagementAddressDeferredToOsConfiguration as success)'
        $row.AdaptersReported | Should -BeFalse
        $row.Reason | Should -BeLike '*adapters never reported within 0.02 minutes*the management port (MAC 00:00:5e:00:53:aa) wasn''t checked*'
        (& $script:reads) | Should -BeGreaterThan 1
        $events = & $script:eventsNow
        @($events | Where-Object state -EQ 'WaitingForNetworkAdapters').Count | Should -Be 1
        $never = @($events | Where-Object state -EQ 'ManagementAdaptersNeverReported')
        $never.Count | Should -Be 1
        $never[0].level | Should -Be 'Warning'
        @($events | Where-Object state -EQ 'ManagementAddressDeferredToOsConfiguration').Count | Should -Be 0
        $never[0].nextAction | Should -Not -BeLike '*OS configuration*sets the static address*'
    }

    It 'after the budget, other adapters listed but not the management MAC: the same Warning, not verified, no throw' {
        $global:netT_adapters = [ordered]@{
            $script:storage = New-NetTAdapter -AdapterName 'Port2' -Mac '00005e0053bb' -Description 'Example storage' -Type 'Dhcp'
        }
        $row = & $script:run @{ ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false; AdaptersTimeoutMinutes = 0.02 }
        $row.Verified | Should -BeFalse
        $row.Status | Should -Be 'NeverReported'
        $row.AdaptersReported | Should -BeFalse
        $row.Reason | Should -BeLike '*adapters never reported within 0.02 minutes*Port2 00:00:5e:00:53:bb*'
        $never = @(& $script:eventsNow | Where-Object state -EQ 'ManagementAdaptersNeverReported')
        $never.Count | Should -Be 1
        $never[0].level | Should -Be 'Warning'
    }

    It 'with no wait budget, other adapters but not the management MAC still stops the stage with the list it found' {
        $global:netT_adapters = [ordered]@{ $script:storage = New-NetTAdapter -AdapterName 'Port2' -Mac '00005e0053bb' -Description 'Example storage' -Type 'Dhcp' }
        { & $script:run @{ ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false; AdaptersTimeoutMinutes = 0 } } | Should -Throw '*reports the management MAC*'
    }

    It 'static with -ApplyThroughAzure: the budget spent with no adapters writes the Warning event and refuses to change anything' {
        $global:netT_noAdapters = $true
        { & $script:run @{ ApplyThroughAzure = $true; ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false; AdaptersTimeoutMinutes = 0.02 } } | Should -Throw '*reports no network adapters within 0.02 minutes*'
        $events = & $script:eventsNow
        $never = @($events | Where-Object state -EQ 'ManagementAdaptersNeverReported')
        $never.Count | Should -Be 1
        $never[0].level | Should -Be 'Warning'
        $never[0].evidence | Should -BeLike '*adapters never reported within 0.02 minutes*no address was set*'
        @($events | Where-Object state -EQ 'ManagementAddressFailed').Count | Should -Be 1
        @(& $script:puts).Count | Should -Be 0
    }

    It 'sleeps at the poll interval but never past the time left, and never faster than every 5 seconds' {
        $global:netT_noAdapters = $true
        $global:netT_sleeps = [System.Collections.Generic.List[int]]::new()
        Mock Start-Sleep { $global:netT_sleeps.Add($Milliseconds) }
        $null = & $script:run @{ ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false; AdaptersTimeoutMinutes = 0.05; PollIntervalSeconds = 0 }
        $global:netT_sleeps.Count | Should -BeGreaterThan 0
        $global:netT_sleeps[0] | Should -BeGreaterThan 2000 -Because 'a poll interval of 0 is raised to 5 seconds, then cut to the 3 seconds of budget'
        ($global:netT_sleeps | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual 3000 -Because 'no sleep runs past the budget'
        $global:netT_sleeps.Clear()
        $null = & $script:run @{ ParameterFile = (& $script:writeParameters (& $script:static)); Execute = $true; Confirm = $false; AdaptersTimeoutMinutes = 0.05; PollIntervalSeconds = 3600 }
        ($global:netT_sleeps | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual 3000 -Because 'a long poll interval is cut to the time left'
        Remove-Variable -Scope Global -Name netT_sleeps -ErrorAction SilentlyContinue
    }

    It 'says the same for a DHCP-reservation port, and reads once when the budget is 0' {
        $global:netT_noAdapters = $true
        $m = & $script:static; $m.ip_assignment = 'dhcp_reservation'
        $row = & $script:run @{ ParameterFile = (& $script:writeParameters $m); Execute = $true; Confirm = $false; AdaptersTimeoutMinutes = 0.02 }
        $row.Verified | Should -BeFalse
        $row.Reason | Should -BeLike '*adapters never reported within 0.02 minutes*'
        $global:netT_calls.Clear()
        $row = & $script:run @{ ParameterFile = (& $script:writeParameters $m); Execute = $true; Confirm = $false; AdaptersTimeoutMinutes = 0 }
        (& $script:reads) | Should -Be 1
        $row.Reason | Should -Match 'reports no network adapters yet'
        $row.AdaptersReported | Should -BeFalse
    }

    It 'a plan reads once and never waits' {
        $global:netT_noAdapters = $true
        $null = @(& $script:run @{ ParameterFile = (& $script:writeParameters (& $script:static)); AdaptersTimeoutMinutes = 5 })
        (& $script:reads) | Should -Be 1
    }
}
