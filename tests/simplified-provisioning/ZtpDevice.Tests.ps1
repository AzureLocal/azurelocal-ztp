#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
# The Device stage: Set-ZtpDeviceConfiguration.ps1 against a stubbed BootstrapOobeService (the Configurator App's REST
# service in the maintenance environment: GetNetworkAdapters in the shape a live run returned, SetArcBootstrapDeviceConfiguration
# and GetArcBootstrapDeviceConfigurationStatus as the service contract names them). Invoke-RestMethod is mocked; nothing is
# contacted. Example addresses and documentation MACs (00-00-5E-00-53-xx) only.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The stub service keeps its state in globals.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Only a synthetic test secret is converted.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signatures mirror the real commands.')]
param()

BeforeAll {
    $script:repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:setDevice = Join-Path $script:repoRoot 'scripts/simplified-provisioning/Set-ZtpDeviceConfiguration.ps1'

    function global:New-DevTAdapter {
        param([string]$Name, [string]$Mac, [bool]$Dhcp = $true, [string]$Ip = '', [string]$Mask = '', [string]$Gateway = '', [string[]]$Dns = @(), [int]$Vlan = 0, [int]$Index = 0)
        [ordered]@{ MacAddress = $Mac; Name = $Name; EnableDhcp = $Dhcp; IpAddress = $Ip; Gateway = $Gateway; SubnetMask = $Mask; DnsAddressArray = @($Dns); VlanId = $Vlan; LogicalIndex = $Index }
    }
    # The stub service: answers on the addresses in devT_up; a POST is kept pending and applied when the status sequence
    # reaches Succeeded; an address in devT_downAfterApply stops answering once the change is applied.
    $global:devT_handler = {
        param([string]$Uri, [string]$Method, [string]$Body, [pscredential]$Credential)
        $global:devT_calls.Add([pscustomobject]@{ Uri = $Uri; Method = $Method; Body = $Body; User = $Credential.UserName; Password = $Credential.GetNetworkCredential().Password })
        if ($Uri -notmatch '^https://([^:/]+):(\d+)/BootstrapOobeService/(\w+)$') { throw "unexpected URI $Uri" }
        $address = $Matches[1]; $operation = $Matches[3]
        if ($address -notin $global:devT_up) { throw "No connection could be made to $address" }
        if ($Credential.GetNetworkCredential().Password -ne $global:devT_password) { throw 'Response status code does not indicate success: 401 (Unauthorized).' }
        switch ($operation) {
            'GetNetworkAdapters' {
                $list = if ($global:devT_other.ContainsKey($address)) { $global:devT_other[$address] } else { $global:devT_adapters }
                return ([ordered]@{ NetworkAdapters = @($list) } | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
            }
            'SetArcBootstrapDeviceConfiguration' { $global:devT_pending = $Body | ConvertFrom-Json -AsHashtable; $global:devT_statusIndex = 0; return $null }
            'GetArcBootstrapDeviceConfigurationStatus' {
                $sequence = @($global:devT_status)
                $status = $sequence[[Math]::Min($global:devT_statusIndex, $sequence.Count - 1)]
                $global:devT_statusIndex++
                if ($status -eq 'Succeeded' -and $global:devT_pending) {
                    # A request with only WebProxy changes no adapter.
                    $pendingAdapters = if ($global:devT_pending.Contains('Network')) { @($global:devT_pending.Network.NetworkAdapters) } else { @() }
                    foreach ($entry in $pendingAdapters) {
                        $a = @($global:devT_adapters | Where-Object { $_.MacAddress -eq $entry.MacAddress })[0]
                        foreach ($k in $entry.Keys) { $a[$k] = $entry[$k] }
                        if ($entry.EnableDhcp) { $a.IpAddress = ''; $a.SubnetMask = ''; $a.Gateway = '' }
                    }
                    $global:devT_pending = $null
                    foreach ($down in @($global:devT_downAfterApply)) { $global:devT_up = @($global:devT_up | Where-Object { $_ -ne $down }) }
                    foreach ($swap in @($global:devT_swapAfterApply.Keys)) { $global:devT_other[$swap] = $global:devT_swapAfterApply[$swap] }
                }
                return [pscustomobject]@{ Status = $status }
            }
        }
        throw "unexpected operation $operation"
    }

    function global:Test-ZtpTcpPort {
        param([string[]]$Address, [int]$Port, [int]$TimeoutMilliseconds)
        $global:devT_sweeps++
        $global:devT_probes.Add([pscustomobject]@{ Count = @($Address).Count; First = @($Address)[0]; Last = @($Address)[-1]; Port = $Port })
        if ($global:devT_sweeps -lt $global:devT_appearAt) { return @() }
        @($Address | Where-Object { $_ -in $global:devT_up })
    }
    $script:writeInputs = {
        param([System.Collections.IDictionary]$Management, [string]$Maintenance = '192.0.2.111', [string]$ScanRange, [System.Collections.IDictionary]$WebProxy)
        $id = [guid]::NewGuid().ToString('N')
        $params = Join-Path $TestDrive "params-$id.json"
        $node = [ordered]@{ name = 'node-01'; service_tag = 'EXAMPLE1' }
        if ($Management) { $node.management = $Management }
        @{ parameters = @{ nodes = @{ value = @($node) } } } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $params
        $nodes = Join-Path $TestDrive "nodes-$id.json"
        $entry = [ordered]@{ name = 'node-01'; service_tag = 'EXAMPLE1'; bmc_address = '198.51.100.11' }
        if ($Maintenance) { $entry.maintenance_address = $Maintenance }
        if ($ScanRange) { $entry.maintenance_scan_range = $ScanRange }
        if ($WebProxy) { $entry.web_proxy = $WebProxy }
        @{ nodes = @($entry) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $nodes
        @{ ParameterFile = $params; NodesFile = $nodes }
    }
    $script:static = { [ordered]@{ ip_assignment = 'static'; mac_address = '00-00-5E-00-53-AA'; ip_address = '192.0.2.11'; subnet_mask = '255.255.255.0'; gateway = '192.0.2.1'; dns_servers = @('192.0.2.53', '192.0.2.54'); vlan_id = '0' } }
    $script:argsFor = {
        param([hashtable]$Inputs, [hashtable]$Arguments = @{})
        $base = @{ PollIntervalSeconds = 0; TimeoutMinutes = 5; ChangeLogPath = $script:changeLog; EventLogPath = $script:events; InformationAction = 'SilentlyContinue'; WarningAction = 'SilentlyContinue' }
        foreach ($k in $Inputs.Keys) { $base[$k] = $Inputs[$k] }
        foreach ($k in $Arguments.Keys) { $base[$k] = $Arguments[$k] }
        $base
    }
    $script:run = { param([hashtable]$Inputs, [hashtable]$Arguments = @{}) $a = & $script:argsFor $Inputs $Arguments; & $script:setDevice @a }
    $script:posts = { @($global:devT_calls | Where-Object Method -EQ 'POST') }
    $script:eventsOf = { if (Test-Path -LiteralPath $script:events) { @(Get-Content -LiteralPath $script:events | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() } }
    $script:changesOf = { if (Test-Path -LiteralPath $script:changeLog) { @(Get-Content -LiteralPath $script:changeLog | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() } }
}

AfterAll {
    Remove-Item 'Function:global:New-DevTAdapter', 'Function:global:Test-ZtpTcpPort' -ErrorAction SilentlyContinue
    Get-Variable -Scope Global -Name 'devT_*' -ErrorAction SilentlyContinue | Remove-Variable -Scope Global -Force -ErrorAction SilentlyContinue
}

Describe 'Set-ZtpDeviceConfiguration.ps1' {
    BeforeEach {
        $global:devT_calls = [System.Collections.Generic.List[object]]::new()
        $global:devT_up = @('192.0.2.111', '192.0.2.11')
        $global:devT_downAfterApply = @()
        $global:devT_password = 'Password1'
        $global:devT_status = @('Succeeded')
        $global:devT_statusIndex = 0
        $global:devT_pending = $null
        $global:devT_other = @{}
        $global:devT_swapAfterApply = @{}
        $global:devT_sweeps = 0
        $global:devT_appearAt = 1
        $global:devT_probes = [System.Collections.Generic.List[object]]::new()
        # As in the live failure: the LOM named by MAC on DHCP, the provisioning lease on a storage port.
        $global:devT_adapters = @(
            (New-DevTAdapter -Name 'eno1' -Mac '00005e0053aa' -Dhcp $true -Ip '192.0.2.200' -Mask '255.255.255.0' -Gateway '192.0.2.1' -Dns '192.0.2.53' -Index 0)
            (New-DevTAdapter -Name 'ens3f0np0' -Mac '00005e0053bb' -Dhcp $true -Ip '192.0.2.111' -Mask '255.255.255.0' -Gateway '192.0.2.1' -Dns '192.0.2.53' -Index 1)
            (New-DevTAdapter -Name 'ens3f1np1' -Mac '00005e0053cc' -Dhcp $true -Index 2)
        )
        $script:changeLog = Join-Path $TestDrive "device-changes-$([guid]::NewGuid().ToString('N')).jsonl"
        $script:events = Join-Path $TestDrive "events-$([guid]::NewGuid().ToString('N')).jsonl"
        Mock Invoke-RestMethod { & $global:devT_handler ([string]$Uri) ([string]$Method) ([string]$Body) $Credential }
        Mock Start-Sleep {}
    }

    It 'plans without -Execute: reads the adapters and prints the request, changes nothing' {
        $out = @(& $script:run (& $script:writeInputs (& $script:static)))
        & $script:posts | Should -BeNullOrEmpty
        $plan = @($out | Where-Object { $_ -is [string] })
        $plan | Should -BeLike 'PLAN: node-01: POST SetArcBootstrapDeviceConfiguration to 192.0.2.111: eno1 (00:00:5e:00:53:aa) static 192.0.2.11 255.255.255.0 gw 192.0.2.1 DNS 192.0.2.53,192.0.2.54 VLAN 0 (reports DHCP 192.0.2.200 now)*'
        ($out | Where-Object { $_ -isnot [string] }).Status | Should -Be 'Planned'
        Test-Path -LiteralPath $script:changeLog | Should -BeFalse
        Test-Path -LiteralPath $script:events | Should -BeFalse
    }

    It 'calls the service over HTTPS on port 20001 as edgeuser, skipping the certificate check, with Password1 by default' {
        $null = & $script:run (& $script:writeInputs (& $script:static))
        $global:devT_calls[0].Uri | Should -Be 'https://192.0.2.111:20001/BootstrapOobeService/GetNetworkAdapters'
        $global:devT_calls[0].Method | Should -Be 'GET'
        $global:devT_calls[0].User | Should -Be 'edgeuser'
        $global:devT_calls[0].Password | Should -Be 'Password1'
        Should -Invoke Invoke-RestMethod -ParameterFilter { $SkipCertificateCheck -and $Authentication -eq 'Basic' } -Times 1 -Exactly
    }

    It 'signs in with -EdgeUserPassword when the image was built with one' {
        $global:devT_password = 'Example-Not-A-Secret-1'
        $edge = ConvertTo-SecureString 'Example-Not-A-Secret-1' -AsPlainText -Force
        $row = & $script:run (& $script:writeInputs (& $script:static)) @{ EdgeUserPassword = $edge; Execute = $true; Confirm = $false }
        $row.Status | Should -Be 'Changed'
        @($global:devT_calls | ForEach-Object Password | Select-Object -Unique) | Should -Be @('Example-Not-A-Secret-1')
    }

    It 'matches the management MAC whatever its separators and case, and sends the data contract in PascalCase' {
        $row = & $script:run (& $script:writeInputs (& $script:static)) @{ Execute = $true; Confirm = $false }
        $post = @(& $script:posts)
        $post.Count | Should -Be 1
        $post[0].Uri | Should -Be 'https://192.0.2.111:20001/BootstrapOobeService/SetArcBootstrapDeviceConfiguration'
        $body = $post[0].Body | ConvertFrom-Json
        $body.PSObject.Properties.Name | Should -Be @('Network') -Because 'the request shape verified live carries Network only, no HostName'
        @($body.Network.NetworkAdapters).Count | Should -Be 1
        $a = $body.Network.NetworkAdapters[0]
        $a.MacAddress | Should -BeExactly '00005e0053aa'
        $a.EnableDhcp | Should -BeFalse
        "$($a.IpAddress) $($a.SubnetMask) $($a.Gateway) $(@($a.DnsAddressArray) -join ',')" | Should -Be '192.0.2.11 255.255.255.0 192.0.2.1 192.0.2.53,192.0.2.54'
        $a.VlanId | Should -BeOfType [long] -Because 'VlanId goes in the type GetNetworkAdapters reports it in'
        $row.Status | Should -Be 'Changed'
        $row.Adapter | Should -Be 'eno1'
        $row.MacAddress | Should -Be '00:00:5e:00:53:aa'
        @(& $script:changesOf | ForEach-Object phase) | Should -Be @('requested', 'applied')
        (& $script:changesOf)[1].request.Network.NetworkAdapters[0].IpAddress | Should -Be '192.0.2.11'
        @(& $script:eventsOf | ForEach-Object stage | Select-Object -Unique) | Should -Be @('Device')
        (& $script:eventsOf | Select-Object -Last 1).state | Should -Be 'DeviceAddressSet'
    }

    It 'stops the node, naming the port, MAC and address, when another adapter holds the target address; sends nothing' {
        $global:devT_adapters[2] = New-DevTAdapter -Name 'ens3f1np1' -Mac '00005e0053cc' -Dhcp $false -Ip '192.0.2.11' -Mask '255.255.255.0' -Gateway '192.0.2.1' -Index 2
        { & $script:run (& $script:writeInputs (& $script:static)) @{ Execute = $true; Confirm = $false } } | Should -Throw '*node-01: the adapter ens3f1np1 (00:00:5e:00:53:cc)*already holds the target static address 192.0.2.11*'
        & $script:posts | Should -BeNullOrEmpty
        (& $script:eventsOf | Where-Object state -EQ 'DeviceConfigurationFailed').level | Should -Be 'Error'
        $global:devT_adapters[2].IpAddress | Should -Be '192.0.2.11' -Because 'nothing was edited'
    }

    It 'ignores a response without the management MAC on the old address after the change (its lease went to another device)' {
        $global:devT_adapters[0].IpAddress = '192.0.2.111'
        $global:devT_status = @('Succeeded', 'Succeeded', 'Succeeded')
        $stranger = @(New-DevTAdapter -Name 'eth0' -Mac '00005e0053ee' -Dhcp $true -Ip '192.0.2.111' -Mask '255.255.255.0' -Gateway '192.0.2.1')
        $global:devT_swapAfterApply = @{ '192.0.2.111' = $stranger }
        $row = & $script:run (& $script:writeInputs (& $script:static)) @{ Execute = $true; Confirm = $false }
        $row.Status | Should -Be 'Changed'
        $statusCalls = @($global:devT_calls | Where-Object { $_.Uri -like '*GetArcBootstrapDeviceConfigurationStatus' })
        $statusCalls.Count | Should -BeGreaterOrEqual 2
        $statusCalls[0].Uri | Should -BeLike 'https://192.0.2.111:*'
        @($statusCalls | Select-Object -Skip 1 | ForEach-Object Uri) | Should -Not -Contain 'https://192.0.2.111:20001/BootstrapOobeService/GetArcBootstrapDeviceConfigurationStatus' -Because 'the stranger on the old address is never read as this node'
    }

    It 'times out rather than counting a read-back from another device as this node''s' {
        $global:devT_up = @('192.0.2.111')
        $global:devT_status = @('Succeeded')
        $global:devT_swapAfterApply = @{ '192.0.2.111' = @(New-DevTAdapter -Name 'eth0' -Mac '00005e0053ee' -Dhcp $false -Ip '192.0.2.11' -Mask '255.255.255.0' -Gateway '192.0.2.1' -Dns '192.0.2.53', '192.0.2.54') }
        $global:devT_adapters[0].IpAddress = '192.0.2.111'
        { & $script:run (& $script:writeInputs (& $script:static)) @{ Execute = $true; Confirm = $false; TimeoutMinutes = 0 } } | Should -Throw "*didn't report static 192.0.2.11*"
    }

    It 'fails before any request when two nodes share a static address' {
        $id = [guid]::NewGuid().ToString('N')
        $params = Join-Path $TestDrive "params-dup-$id.json"
        $mk = { param($n) $m = & $script:static; $m.mac_address = "00-00-5E-00-53-0$n"; [ordered]@{ name = "node-0$n"; service_tag = "EXAMPLE$n"; management = $m } }
        @{ parameters = @{ nodes = @{ value = @((& $mk 1), (& $mk 2)) } } } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $params
        $nodes = Join-Path $TestDrive "nodes-dup-$id.json"
        @{ nodes = @(@{ name = 'node-01'; service_tag = 'EXAMPLE1'; bmc_address = '198.51.100.11'; maintenance_address = '192.0.2.111' }, @{ name = 'node-02'; service_tag = 'EXAMPLE2'; bmc_address = '198.51.100.12'; maintenance_address = '192.0.2.112' }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $nodes
        { & $script:run @{ ParameterFile = $params; NodesFile = $nodes } @{ Execute = $true; Confirm = $false } } | Should -Throw '*nodes node-01, node-02 share the management ip_address 192.0.2.11*'
        $global:devT_calls.Count | Should -Be 0
    }

    It 'fails before any request when the target address is inside the node''s scan range (the DHCP pool)' {
        { & $script:run (& $script:writeInputs (& $script:static) -Maintenance '' -ScanRange '192.0.2.5-192.0.2.50') @{ Execute = $true; Confirm = $false } } | Should -Throw '*node-01: the management ip_address 192.0.2.11 is inside its maintenance_scan_range 192.0.2.5-192.0.2.50*'
        $global:devT_calls.Count | Should -Be 0
        $global:devT_sweeps | Should -Be 0
    }

    It 'rejects scan input that is not dotted-quad IPv4 or a contiguous mask, and says /31 and /32 are unsupported' {
        $bad = @(
            @{ Range = 'fe80::1-fe80::2'; Mask = '255.255.255.0'; Expect = "*maintenance_scan_range 'fe80::1-fe80::2' isn't start-end*" }
            @{ Range = '192.0.2.1-192.0.2.300'; Mask = '255.255.255.0'; Expect = '*a part is above 255*' }
            @{ Range = '192.0.2.001-192.0.2.20'; Mask = '255.255.255.0'; Expect = "*isn't a dotted-quad IPv4 address*" }
            @{ Range = ''; Mask = '255.0.255.0'; Expect = "*the subnet mask 255.0.255.0 isn't contiguous*" }
            @{ Range = ''; Mask = '255.255.255.254'; Expect = '*is a /31 network; the scan doesn''t support /31 or /32*' }
            @{ Range = ''; Mask = '255.255.255.255'; Expect = '*is a /32 network; the scan doesn''t support /31 or /32*' }
            @{ Range = ''; Mask = '2001:db8::'; Expect = "*isn't a dotted-quad IPv4 address*" }
        )
        foreach ($case in $bad) {
            $m = & $script:static; $m.subnet_mask = $case.Mask
            $inputs = & $script:writeInputs $m -Maintenance '' -ScanRange $case.Range
            { & $script:run $inputs @{ Execute = $true; Confirm = $false } } | Should -Throw $case.Expect
        }
        $global:devT_calls.Count | Should -Be 0
    }

    It 'scans in bounded batches with the real probe: 300 loopback addresses finish without leaking or failing' {
        $saved = (Get-Item Function:global:Test-ZtpTcpPort).ScriptBlock
        Remove-Item Function:global:Test-ZtpTcpPort
        try {
            $m = & $script:static; $m.ip_address = '192.0.2.200'
            $inputs = & $script:writeInputs $m -Maintenance '' -ScanRange '127.0.0.1-127.0.1.44'
            $out = @(& $script:run $inputs @{ Port = 1; ProbeTimeoutMilliseconds = 200 })
            ($out | Where-Object { $_ -is [string] }) | Should -BeLike 'PLAN: node-01: no maintenance environment*127.0.0.1-127.0.1.44*'
        }
        finally { Set-Item Function:global:Test-ZtpTcpPort -Value $saved }
    }
    It 'changes nothing when the management adapter already reports the static configuration' {
        $global:devT_adapters[0] = New-DevTAdapter -Name 'eno1' -Mac '00005e0053aa' -Dhcp $false -Ip '192.0.2.11' -Mask '255.255.255.0' -Gateway '192.0.2.1' -Dns '192.0.2.53', '192.0.2.54'
        $row = & $script:run (& $script:writeInputs (& $script:static)) @{ Execute = $true; Confirm = $false }
        & $script:posts | Should -BeNullOrEmpty
        $row.Status | Should -Be 'AlreadySet'
        @(& $script:eventsOf | ForEach-Object state) | Should -Be @('DeviceAddressAlreadySet')
    }

    It 'polls the status until the change shows, logging each change once' {
        $global:devT_status = @('InProgress', 'InProgress', 'Succeeded')
        $a = & $script:argsFor (& $script:writeInputs (& $script:static)) @{ Execute = $true; Confirm = $false }
        $row = & $script:setDevice @a -InformationVariable info
        $row.Status | Should -Be 'Changed'
        @($global:devT_calls | Where-Object { $_.Uri -like '*GetArcBootstrapDeviceConfigurationStatus' }).Count | Should -Be 3
        $text = @($info | ForEach-Object { [string]$_.MessageData }) -join "`n"
        ([regex]::Matches($text, 'status: Status InProgress')).Count | Should -Be 1
        $text | Should -Match 'status: Status Succeeded; eno1 reports static 192\.0\.2\.11'
        @(& $script:eventsOf | Where-Object state -EQ 'DeviceConfigurationStatus').Count | Should -Be 2
    }

    It 'follows the service to the static address when the management port carried the maintenance address' {
        $global:devT_adapters[0].IpAddress = '192.0.2.111'; $global:devT_adapters[1].IpAddress = '192.0.2.201'
        $global:devT_status = @('InProgress', 'Succeeded', 'Succeeded')
        $global:devT_downAfterApply = @('192.0.2.111')
        $row = & $script:run (& $script:writeInputs (& $script:static)) @{ Execute = $true; Confirm = $false }
        $row.Status | Should -Be 'Changed'
        ($global:devT_calls | Select-Object -Last 1).Uri | Should -Be 'https://192.0.2.11:20001/BootstrapOobeService/GetNetworkAdapters'
    }

    It 'stops with the reason when the status reports a failure' {
        $global:devT_status = @('InProgress', 'Failed')
        { & $script:run (& $script:writeInputs (& $script:static)) @{ Execute = $true; Confirm = $false } } | Should -Throw '*node-01: SetArcBootstrapDeviceConfiguration failed: Status Failed*'
        @(& $script:changesOf | ForEach-Object phase) | Should -Be @('requested', 'failed')
        $failed = & $script:eventsOf | Where-Object state -EQ 'DeviceConfigurationFailed'
        $failed.level | Should -Be 'Error'
        $failed.nextAction | Should -Match '-From Device'
    }

    It 'stops when the change does not show within the timeout' {
        $global:devT_status = @('InProgress')
        { & $script:run (& $script:writeInputs (& $script:static)) @{ Execute = $true; Confirm = $false; TimeoutMinutes = 0 } } | Should -Throw "*didn't report static 192.0.2.11*within 0 minutes*"
        @(& $script:changesOf | ForEach-Object phase) | Should -Be @('requested', 'timedOut')
    }

    It 'fails clearly when no adapter reports the management MAC, listing the MACs it found' {
        $m = & $script:static; $m.mac_address = '00:00:5E:00:53:DD'
        { & $script:run (& $script:writeInputs $m) @{ Execute = $true; Confirm = $false } } |
            Should -Throw '*no network adapter in the maintenance environment reports the management MAC 00:00:5e:00:53:dd. Found: eno1 00:00:5e:00:53:aa; ens3f0np0 00:00:5e:00:53:bb; ens3f1np1 00:00:5e:00:53:cc*'
        & $script:posts | Should -BeNullOrEmpty
    }

    It 'names the address and port when the service does not answer' {
        $global:devT_up = @()
        { & $script:run (& $script:writeInputs (& $script:static)) } | Should -Throw "*REST service at 192.0.2.111:20001 doesn't answer*"
    }

    It 'finds a node without a maintenance address by scanning its range for TCP 20001 and matching the management MAC' {
        # Another machine answers in the range too; the node itself answers on a port that isn't the management port.
        $global:devT_up = @('192.0.2.140', '192.0.2.150', '192.0.2.11')
        $global:devT_other['192.0.2.140'] = @(New-DevTAdapter -Name 'eno1' -Mac '00005e0053ee' -Ip '192.0.2.140')
        $global:devT_adapters[1].IpAddress = '192.0.2.150'
        $row = & $script:run (& $script:writeInputs (& $script:static) -Maintenance '' -ScanRange '192.0.2.100-192.0.2.250') @{ Execute = $true; Confirm = $false }
        $row.Status | Should -Be 'Changed'
        $row.MaintenanceAddress | Should -Be '192.0.2.150'
        $global:devT_probes[0].Count | Should -Be 151; $global:devT_probes[0].First | Should -Be '192.0.2.100'; $global:devT_probes[0].Last | Should -Be '192.0.2.250'; $global:devT_probes[0].Port | Should -Be 20001
        (& $script:posts)[0].Uri | Should -Be 'https://192.0.2.150:20001/BootstrapOobeService/SetArcBootstrapDeviceConfiguration'
        @(& $script:eventsOf | ForEach-Object state)[0] | Should -Be 'MaintenanceEnvironmentFound'
        (& $script:eventsOf)[0].evidence | Should -Be 'maintenance environment found by its management MAC 00:00:5e:00:53:aa at 192.0.2.150 (scan of 192.0.2.100-192.0.2.250)'
    }

    It 'prefers a lease that is not on the management port, which moves when the static address is applied' {
        $global:devT_up = @('192.0.2.111', '192.0.2.200', '192.0.2.11')
        $row = & $script:run (& $script:writeInputs (& $script:static) -Maintenance '' -ScanRange '192.0.2.100-192.0.2.250') @{ Execute = $true; Confirm = $false }
        $row.MaintenanceAddress | Should -Be '192.0.2.111' -Because '192.0.2.200 is the management port''s own lease'
    }

    It 'keeps scanning until the node answers, because it may still be booting' {
        $global:devT_appearAt = 3
        $row = & $script:run (& $script:writeInputs (& $script:static) -Maintenance '' -ScanRange '192.0.2.100-192.0.2.120') @{ Execute = $true; Confirm = $false }
        $row.Status | Should -Be 'Changed'
        $global:devT_sweeps | Should -Be 3
    }

    It 'stops with what it scanned when no maintenance environment has the MAC by the deadline, and a plan scans once' {
        $global:devT_up = @('192.0.2.140')
        $global:devT_other['192.0.2.140'] = @(New-DevTAdapter -Name 'eno1' -Mac '00005e0053ee' -Ip '192.0.2.140')
        { & $script:run (& $script:writeInputs (& $script:static) -Maintenance '' -ScanRange '192.0.2.100-192.0.2.250') @{ Execute = $true; Confirm = $false; TimeoutMinutes = 0 } } |
            Should -Throw '*node-01: no maintenance environment with the management MAC 00:00:5e:00:53:aa answers on TCP 20001 in 192.0.2.100-192.0.2.250 within 0 minutes (1 scan(s))*'
        & $script:posts | Should -BeNullOrEmpty
        $global:devT_sweeps = 0
        $out = @(& $script:run (& $script:writeInputs (& $script:static) -Maintenance '' -ScanRange '192.0.2.100-192.0.2.250'))
        $global:devT_sweeps | Should -Be 1
        ($out | Where-Object { $_ -is [string] }) | Should -BeLike 'PLAN: node-01: no maintenance environment*answers on TCP 20001 in 192.0.2.100-192.0.2.250 now*With -Execute the Device stage scans for up to 5 minutes.'
        ($out | Where-Object { $_ -isnot [string] }).Status | Should -Be 'Planned'
    }

    It 'scans the management subnet when the node list gives no range, and refuses a range that is too big' {
        $global:devT_up = @('192.0.2.150')
        $global:devT_adapters[1].IpAddress = '192.0.2.150'
        $row = & $script:run (& $script:writeInputs (& $script:static) -Maintenance '') @{ Execute = $true; Confirm = $false }
        $row.MaintenanceAddress | Should -Be '192.0.2.150'
        @($global:devT_probes[0].Count, $global:devT_probes[0].First, $global:devT_probes[0].Last) -join ' ' | Should -Be '254 192.0.2.1 192.0.2.254'
        { & $script:run (& $script:writeInputs (& $script:static) -Maintenance '' -ScanRange '192.0.0.1-192.0.20.1') @{ Execute = $true; Confirm = $false } } | Should -Throw '*more than 4096 addresses*provisioning_dhcp_range*'
    }

    It 'does not scan for a dhcp or preconfigured node without a maintenance address' {
        $m = & $script:static; $m.ip_assignment = 'dhcp'
        $row = & $script:run (& $script:writeInputs $m -Maintenance '') @{ Execute = $true; Confirm = $false }
        $row.Status | Should -Be 'Skipped'
        $global:devT_calls.Count | Should -Be 0
        $global:devT_sweeps | Should -Be 0
    }

    It 'reads the status in the shape the service returned live, and stops on a failed step' {
        $live = '{"Response":{"DetailedResponse":[{"Name":"NetworkConfig","Status":"Succeeded"},{"Name":"RemoteConfig","Status":"NotApplicable"}],"Name":"Bootstrap","Status":"Succeeded"},"Version":"V1"}'
        $a = & $script:argsFor (& $script:writeInputs (& $script:static)) @{ Execute = $true; Confirm = $false }
        $global:devT_liveStatus = $live
        Mock Invoke-RestMethod { if ($Uri -like '*GetArcBootstrapDeviceConfigurationStatus') { $null = & $global:devT_handler ([string]$Uri) ([string]$Method) ([string]$Body) $Credential; return ($global:devT_liveStatus | ConvertFrom-Json) }; & $global:devT_handler ([string]$Uri) ([string]$Method) ([string]$Body) $Credential }
        $row = & $script:setDevice @a -InformationVariable info
        $row.Status | Should -Be 'Changed'
        (@($info | ForEach-Object { [string]$_.MessageData }) -join "`n") | Should -Match 'status: Bootstrap Succeeded \(NetworkConfig Succeeded, RemoteConfig NotApplicable\)'
        $global:devT_adapters[0].EnableDhcp = $true; $global:devT_adapters[0].IpAddress = '192.0.2.200'
        $global:devT_liveStatus = $live.Replace('"NetworkConfig","Status":"Succeeded"', '"NetworkConfig","Status":"Failed"').Replace('"Bootstrap","Status":"Succeeded"', '"Bootstrap","Status":"InProgress"')
        { & $script:setDevice @a } | Should -Throw '*SetArcBootstrapDeviceConfiguration failed: Bootstrap InProgress (NetworkConfig Failed*'
    }

    It 'only reports the management adapter for dhcp and preconfigured' {
        foreach ($mode in 'dhcp', 'preconfigured') {
            $global:devT_calls.Clear()
            $m = & $script:static; $m.ip_assignment = $mode
            $row = & $script:run (& $script:writeInputs $m) @{ Execute = $true; Confirm = $false }
            & $script:posts | Should -BeNullOrEmpty -Because $mode
            $row.Status | Should -Be 'Reported'
            $row.Address | Should -Be '192.0.2.200'
        }
    }
}

Describe 'Set-ZtpDeviceConfiguration.ps1 reaches the service on the port and as the user the file names (schema 5.4)' {
    It 'uses -Port and -UserName instead of 20001 and edgeuser' {
        $global:devT_calls = [System.Collections.Generic.List[object]]::new()
        $global:devT_up = @('192.0.2.111', '192.0.2.11'); $global:devT_downAfterApply = @(); $global:devT_password = 'Password1'
        $global:devT_status = @('Succeeded'); $global:devT_statusIndex = 0; $global:devT_pending = $null; $global:devT_other = @{}; $global:devT_swapAfterApply = @{}
        $global:devT_sweeps = 0; $global:devT_appearAt = 1; $global:devT_probes = [System.Collections.Generic.List[object]]::new()
        $global:devT_adapters = @(
            (New-DevTAdapter -Name 'eno1' -Mac '00005e0053aa' -Dhcp $true -Ip '192.0.2.200' -Mask '255.255.255.0' -Gateway '192.0.2.1' -Dns '192.0.2.53' -Index 0)
            (New-DevTAdapter -Name 'ens3f0np0' -Mac '00005e0053bb' -Dhcp $true -Ip '192.0.2.111' -Mask '255.255.255.0' -Gateway '192.0.2.1' -Dns '192.0.2.53' -Index 1)
        )
        $script:changeLog = Join-Path $TestDrive "device-changes-$([guid]::NewGuid().ToString('N')).jsonl"
        $script:events = Join-Path $TestDrive "events-$([guid]::NewGuid().ToString('N')).jsonl"
        Mock Invoke-RestMethod { & $global:devT_handler ([string]$Uri) ([string]$Method) ([string]$Body) $Credential }
        Mock Start-Sleep {}
        $null = & $script:run (& $script:writeInputs (& $script:static)) @{ Port = 20011; UserName = 'lab-user' }
        $global:devT_calls[0].Uri | Should -Be 'https://192.0.2.111:20011/BootstrapOobeService/GetNetworkAdapters'
        $global:devT_calls[0].User | Should -Be 'lab-user'
    }
}

Describe 'Set-ZtpDeviceConfiguration.ps1 sets the proxy of scenario.outbound_path proxy' {
    BeforeEach {
        $global:devT_calls = [System.Collections.Generic.List[object]]::new()
        $global:devT_up = @('192.0.2.111', '192.0.2.11'); $global:devT_downAfterApply = @(); $global:devT_password = 'Password1'
        $global:devT_status = @('Succeeded'); $global:devT_statusIndex = 0; $global:devT_pending = $null; $global:devT_other = @{}; $global:devT_swapAfterApply = @{}
        $global:devT_sweeps = 0; $global:devT_appearAt = 1; $global:devT_probes = [System.Collections.Generic.List[object]]::new()
        $global:devT_adapters = @(
            (New-DevTAdapter -Name 'eno1' -Mac '00005e0053aa' -Dhcp $true -Ip '192.0.2.200' -Mask '255.255.255.0' -Gateway '192.0.2.1' -Dns '192.0.2.53' -Index 0)
            (New-DevTAdapter -Name 'ens3f0np0' -Mac '00005e0053bb' -Dhcp $true -Ip '192.0.2.111' -Mask '255.255.255.0' -Gateway '192.0.2.1' -Dns '192.0.2.53' -Index 1)
        )
        $script:changeLog = Join-Path $TestDrive "device-changes-$([guid]::NewGuid().ToString('N')).jsonl"
        $script:events = Join-Path $TestDrive "events-$([guid]::NewGuid().ToString('N')).jsonl"
        $script:proxy = [ordered]@{ connection_uri = 'http://proxy.improbability.cloud:3128'; bypass_list = @('localhost', '192.0.2.*', 'node-01', '*.improbability.cloud') }
        Mock Invoke-RestMethod { & $global:devT_handler ([string]$Uri) ([string]$Method) ([string]$Body) $Credential }
        Mock Start-Sleep {}
    }

    It 'sends WebProxy (ConnectionUri, BypassList) with the static address in one request' {
        $row = & $script:run (& $script:writeInputs (& $script:static) -WebProxy $script:proxy) @{ Execute = $true; Confirm = $false }
        $post = @(& $script:posts)
        $post.Count | Should -Be 1
        $body = $post[0].Body | ConvertFrom-Json
        $body.PSObject.Properties.Name | Should -Be @('Network', 'WebProxy')
        $body.WebProxy.ConnectionUri | Should -Be 'http://proxy.improbability.cloud:3128'
        @($body.WebProxy.BypassList) -join ',' | Should -Be 'localhost,192.0.2.*,node-01,*.improbability.cloud'
        $row.Status | Should -Be 'Changed'
        @(& $script:eventsOf | ForEach-Object state | Select-Object -Last 2) | Should -Be @('DeviceAddressSet', 'DeviceProxySet')
    }

    It 'sends only WebProxy when the static address is already on the management port' {
        $global:devT_adapters[0] = New-DevTAdapter -Name 'eno1' -Mac '00005e0053aa' -Dhcp $false -Ip '192.0.2.11' -Mask '255.255.255.0' -Gateway '192.0.2.1' -Dns '192.0.2.53', '192.0.2.54'
        $row = & $script:run (& $script:writeInputs (& $script:static) -WebProxy $script:proxy) @{ Execute = $true; Confirm = $false }
        $body = (@(& $script:posts)[0]).Body | ConvertFrom-Json
        $body.PSObject.Properties.Name | Should -Be @('WebProxy')
        $row.Status | Should -Be 'Changed'
        @(& $script:eventsOf | ForEach-Object state) | Should -Not -Contain 'DeviceAddressSet'
    }

    It 'sets the proxy on a dhcp node with a maintenance address, and plans it without -Execute' {
        $m = & $script:static; $m.ip_assignment = 'dhcp'; $m.ip_address = ''
        $out = @(& $script:run (& $script:writeInputs $m -WebProxy $script:proxy))
        ($out | Where-Object { $_ -is [string] }) | Should -BeLike 'PLAN: node-01: POST SetArcBootstrapDeviceConfiguration to 192.0.2.111: web proxy http://proxy.improbability.cloud:3128 bypassing localhost,192.0.2.*,node-01,*.improbability.cloud; then wait up to 5 minutes for the WebProxy step to succeed.'
        & $script:posts | Should -BeNullOrEmpty
        $row = & $script:run (& $script:writeInputs $m -WebProxy $script:proxy) @{ Execute = $true; Confirm = $false }
        $body = (@(& $script:posts)[0]).Body | ConvertFrom-Json
        $body.PSObject.Properties.Name | Should -Be @('WebProxy')
        $row.Status | Should -Be 'Changed'
        $row.Address | Should -Be '192.0.2.200'
    }

    It 'waits for the WebProxy step of the status tree to succeed' {
        $global:devT_adapters[0] = New-DevTAdapter -Name 'eno1' -Mac '00005e0053aa' -Dhcp $false -Ip '192.0.2.11' -Mask '255.255.255.0' -Gateway '192.0.2.1' -Dns '192.0.2.53', '192.0.2.54'
        $global:devT_tree = @(
            '{"Response":{"DetailedResponse":[{"Name":"NetworkConfig","Status":"NotApplicable"},{"Name":"WebProxy","Status":"InProgress"}],"Name":"Bootstrap","Status":"InProgress"},"Version":"V1"}'
            '{"Response":{"DetailedResponse":[{"Name":"NetworkConfig","Status":"NotApplicable"},{"Name":"WebProxy","Status":"Succeeded"}],"Name":"Bootstrap","Status":"Succeeded"},"Version":"V1"}')
        $global:devT_treeIndex = 0
        Mock Invoke-RestMethod {
            if ($Uri -like '*GetArcBootstrapDeviceConfigurationStatus') { $null = & $global:devT_handler ([string]$Uri) ([string]$Method) ([string]$Body) $Credential; $s = $global:devT_tree[[Math]::Min($global:devT_treeIndex, 1)]; $global:devT_treeIndex++; return ($s | ConvertFrom-Json) }
            & $global:devT_handler ([string]$Uri) ([string]$Method) ([string]$Body) $Credential
        }
        $row = & $script:run (& $script:writeInputs (& $script:static) -WebProxy $script:proxy) @{ Execute = $true; Confirm = $false }
        $row.Status | Should -Be 'Changed'
        $global:devT_treeIndex | Should -Be 2
    }

    It 'stops a dhcp node with a proxy that it can neither reach nor scan for' {
        $m = & $script:static; $m.ip_assignment = 'dhcp'; $m.ip_address = ''
        { & $script:run (& $script:writeInputs $m -Maintenance '' -WebProxy $script:proxy) @{ Execute = $true; Confirm = $false } } | Should -Throw '*node-01: no maintenance_address, no maintenance_scan_range and no management ip_address*'
        & $script:posts | Should -BeNullOrEmpty
    }

    It 'refuses a proxy without a bypass list before sending anything' {
        $bad = [ordered]@{ connection_uri = 'http://proxy.improbability.cloud:3128'; bypass_list = @() }
        { & $script:run (& $script:writeInputs (& $script:static) -WebProxy $bad) @{ Execute = $true; Confirm = $false } } | Should -Throw '*web_proxy has no bypass_list*'
        & $script:posts | Should -BeNullOrEmpty
    }
}