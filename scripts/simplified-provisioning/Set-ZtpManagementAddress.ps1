#Requires -Version 7.0
<#
.SYNOPSIS
Puts each node's management address on the adapter with the node's management MAC, through Azure's per-NIC API, after
the OS install. The Network stage, between Ready and Handoff.
.DESCRIPTION
The OS-install request carries the management port's MAC (siteDetails.deviceConfiguration.network.networkAdapters[].
macAddress). Azure accepts it, but the maintenance environment ignores it: it puts the static address on the first ready
port, which on a Dell AX-760 was a ConnectX storage port, not the LOM named by MAC. Azure Local's 2026-10-01 API has a
resource per NIC of a provisioned edge machine, and this script uses it to move the address to the right port. Per node:
1. Lists edgeMachines/<node>/networkAdapters and finds the adapter whose reported macAddress is the management MAC of
   the parameters file (separators and case don't matter). No match stops the node, listing the MACs found.
2. static: when another adapter reports the node's management address, that adapter is set to Dhcp first
   (jobs/ApplyConfiguration) and the run waits until it no longer reports the address, so two ports never carry it.
   Then the management adapter gets ApplyConfiguration Static with the address, the mask, the gateway, the DNS servers,
   the VLAN and interfaceState up; adapterName is the adapter's own networkConfiguration.adapterName. An adapter that
   already reports that configuration is left alone. Each job is followed until it succeeds or fails, or -TimeoutMinutes
   passes; every status change is logged (a job can wait queued with "Job is not yet triggered as other jobs are still
   running" right after the OS install). After the job, the run waits until the adapter reports the new configuration.
3. dhcp, dhcp_reservation, preconfigured: nothing changes; the management adapter's reported state is shown.
Without -Execute only reads: it prints what it would do (PLAN: lines) and returns one row per node. With -Execute each
change is appended to -ChangeLogPath (JSON lines: time, node, adapter, MAC, action, before, after, phase, job status),
and the progress goes to -EventLogPath (stage Network), which monitors follow. Prepare (Initialize-ZtpNode.ps1) checks
the same address in the OS and changes nothing that is already right.
Sign in first (Connect-AzAccount). The edge machine is named after the node, as bicep/main.bicep names it.
.PARAMETER SubscriptionId
Subscription of the edge machines (for example 00000000-0000-0000-0000-000000000000).
.PARAMETER ResourceGroupName
Resource group of the edge machines (for example rg-example).
.PARAMETER ParameterFile
The parameters file of bicep/main.bicep (JSON, or a .bicepparam compiled with az bicep build-params). Each node's
management block gives ip_assignment, mac_address, ip_address, subnet_mask, gateway, dns_servers and vlan_id;
Invoke-ZtpEnvironment.ps1 writes it from the environment file. A node without one is reported and left alone.
.PARAMETER Node
Nodes to handle (default: every node in the parameters file).
.PARAMETER ApiVersion
Microsoft.AzureStackHCI api-version of edgeMachines/networkAdapters and their jobs.
.PARAMETER TimeoutMinutes
How long to wait for each ApplyConfiguration job, and then for the adapter to report the result. 0 checks once.
.PARAMETER PollIntervalSeconds
How often to read a job or the adapters while waiting.
.PARAMETER EventLogPath
The ZTP event file (JSON lines, stage Network). Optional; written only with -Execute.
.PARAMETER ChangeLogPath
JSON-lines file every change is appended to (the run's evidence folder: network-changes.jsonl). Optional.
.PARAMETER Execute
Change the adapters. Without it only the plan is printed.
.EXAMPLE
./Set-ZtpManagementAddress.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example -ParameterFile ./bicep/main.parameters.json
.EXAMPLE
./Set-ZtpManagementAddress.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example -ParameterFile ./bicep/main.parameters.json -Node node-01 -ChangeLogPath D:\ZtpEvidence\network-changes.jsonl -Execute
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The parameters are read inside the helper functions.')]
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$ParameterFile,
    [string[]]$Node,
    [string]$ApiVersion = '2026-10-01',
    [ValidateRange(0, 1440)][int]$TimeoutMinutes = 60,
    [ValidateRange(0, 3600)][int]$PollIntervalSeconds = 30,
    [string]$EventLogPath,
    [string]$ChangeLogPath,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpAzure.Common.ps1')
. (Join-Path $PSScriptRoot 'ZtpEvents.Common.ps1')

$machineRoot = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.AzureStackHCI/edgeMachines"

# ------------------------------------------------------------------ inputs
if (-not (Test-Path -LiteralPath $ParameterFile)) { throw "Parameter file not found: $ParameterFile." }
$parameters = if ([IO.Path]::GetExtension($ParameterFile) -eq '.bicepparam') {
    $built = (& az bicep build-params --file $ParameterFile --stdout 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "az bicep build-params $ParameterFile failed: $built" }
    (($built | ConvertFrom-Json -Depth 64).parametersJson | ConvertFrom-Json -AsHashtable -Depth 64).parameters
}
else { (Get-Content -LiteralPath $ParameterFile -Raw | ConvertFrom-Json -AsHashtable -Depth 64).parameters }
if (-not $parameters -or -not $parameters.Contains('nodes') -or -not $parameters['nodes']['value']) { throw "The parameters file $ParameterFile has no nodes." }
$nodeEntries = @($parameters['nodes']['value'])
if ($Node) {
    $unknown = @($Node | Where-Object { $_ -notin @($nodeEntries | ForEach-Object { [string]$_['name'] }) })
    if ($unknown.Count -gt 0) { throw "Unknown node(s) $($unknown -join ', '): not in $ParameterFile." }
}
$selected = @($nodeEntries | Where-Object { -not $Node -or [string]$_['name'] -in $Node })

# ------------------------------------------------------------------ evidence
function Send-NetworkEvent([string]$NodeName, [string]$State, [string]$Evidence, [string]$Level = 'Info', [string]$NextAction = '') {
    if (-not $Execute -or -not $EventLogPath) { return }
    try { Write-ZtpEvent -Path $EventLogPath -Node $NodeName -State $State -Evidence $Evidence -NextAction $NextAction -Level $Level -Stage 'Network' }
    catch { Write-Warning "Couldn't write the Network event to ${EventLogPath}: $($_.Exception.Message)" }
}
function ConvertTo-ChangeRecord([object]$Setting) {
    [ordered]@{ ipInterfaceType = $Setting.Type; ip4Address = $Setting.Ip; subnetMask = $Setting.Mask; defaultGateway = $Setting.Gateway; dnsServers = @($Setting.Dns); vlanId = $Setting.Vlan; interfaceState = $Setting.InterfaceState }
}
function Write-NetworkChange([string]$NodeName, [object]$Adapter, [string]$Action, [object]$Before, [object]$After, [string]$Phase, [string]$JobStatus) {
    if (-not $ChangeLogPath) { return }
    $dir = Split-Path -Parent $ChangeLogPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    $line = [ordered]@{
        timestamp = [datetime]::UtcNow.ToString('o'); node = $NodeName; edgeMachine = $NodeName; adapter = $Adapter.Name; adapterName = $Adapter.AdapterName
        macAddress = Format-ZtpMac $Adapter.Mac; action = $Action; before = (ConvertTo-ChangeRecord $Before); after = (ConvertTo-ChangeRecord $After); phase = $Phase; jobStatus = $JobStatus
    } | ConvertTo-Json -Compress -Depth 5
    Add-Content -LiteralPath $ChangeLogPath -Value $line
}

# ------------------------------------------------------------------ ARM
function Get-NodeAdapter([string]$NodeName) {
    # $null when the edge machine has no networkAdapters collection yet (before the OS install, or no such machine).
    $list = Invoke-ZtpArm -Method GET -Path "$machineRoot/$NodeName/networkAdapters" -ApiVersion $ApiVersion -AllowNotFound
    if ($null -eq $list) { return $null }
    return , @(Get-ZtpNetworkAdapterRow -List $list)
}

function Wait-AdapterReport([string]$NodeName, [scriptblock]$Done, [string]$What) {
    $deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
    while ($true) {
        $rows = Get-NodeAdapter $NodeName
        if ($null -ne $rows -and (& $Done $rows)) { return , $rows }
        if ([datetime]::UtcNow -ge $deadline) { throw "${NodeName}: the job succeeded, but the adapters didn't report $What within $TimeoutMinutes minutes." }
        Write-ZtpLog "$NodeName waiting for the adapters to report $What." -Level Verbose
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

function Invoke-AdapterJob {
    # One jobs/ApplyConfiguration on one adapter, followed to its end. An unfinished job with the same target (an
    # interrupted run) is followed instead of being sent again.
    param([string]$NodeName, [object]$Adapter, [System.Collections.IDictionary]$Target, [string]$Action)
    $jobPath = "$machineRoot/$NodeName/networkAdapters/$([uri]::EscapeDataString($Adapter.Name))/jobs/ApplyConfiguration"
    $want = ConvertTo-ZtpNetworkSetting $Target
    $label = "$NodeName $($Adapter.AdapterName) ($(Format-ZtpMac $Adapter.Mac))"
    $ours = { param($st) $null -eq $st.Target -or ($st.Target.Type -eq $want.Type -and $st.Target.Ip -eq $want.Ip) }
    $existing = Get-ZtpNetworkJobState (Invoke-ZtpArm -Method GET -Path $jobPath -ApiVersion $ApiVersion -AllowNotFound)
    $submittedAt = $null
    if ($existing.Exists -and -not $existing.Done -and $null -ne $existing.Target -and (& $ours $existing)) {
        Write-ZtpLog "$label an unfinished ApplyConfiguration with this target is there ($($existing.Status)); following it instead of sending another."
    }
    else {
        $submittedAt = [datetime]::UtcNow
        $body = @{ properties = [ordered]@{ jobType = 'ApplyConfiguration'; deploymentMode = 'Deploy'; targetConfiguration = $Target } }
        $null = Invoke-ZtpArm -Method PUT -Path $jobPath -ApiVersion $ApiVersion -Body $body
        Write-ZtpLog "$label ApplyConfiguration sent ($Action): $(Format-ZtpNetworkSetting $want)."
    }
    Write-NetworkChange $NodeName $Adapter $Action $Adapter.Reported $want 'requested' ''
    Send-NetworkEvent $NodeName 'NetworkJobSubmitted' "$($Adapter.AdapterName) ($(Format-ZtpMac $Adapter.Mac)) ApplyConfiguration ${Action}: $(Format-ZtpNetworkSetting $want)"
    $deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
    $last = ''
    while ($true) {
        $st = Get-ZtpNetworkJobState (Invoke-ZtpArm -Method GET -Path $jobPath -ApiVersion $ApiVersion -AllowNotFound)
        # A job that ended before this request was sent is the previous one: ignore it until the new one shows.
        $mine = $st.Exists -and (& $ours $st) -and -not ($submittedAt -and $st.Done -and $null -ne $st.StartTimeUtc -and $st.StartTimeUtc -lt $submittedAt.AddMinutes(-5))
        $text = if (-not $st.Exists) { 'not readable yet' } elseif (-not $mine) { "still shows an earlier job: $($st.Text)" } else { $st.Text }
        if ($text -ne $last) {
            Write-ZtpLog "$label ApplyConfiguration: $text"
            Send-NetworkEvent $NodeName 'NetworkJobStatus' "$($Adapter.AdapterName) ApplyConfiguration: $text"
            $last = $text
        }
        if ($mine -and $st.Failed) {
            Write-NetworkChange $NodeName $Adapter $Action $Adapter.Reported $want 'failed' $st.Status
            throw "$label ApplyConfiguration ($Action) failed: $($st.FailureReason)"
        }
        if ($mine -and $st.Succeeded) { return $st }
        if ([datetime]::UtcNow -ge $deadline) {
            Write-NetworkChange $NodeName $Adapter $Action $Adapter.Reported $want 'timedOut' $st.Status
            throw "$label ApplyConfiguration ($Action) didn't finish within $TimeoutMinutes minutes; last: $text. Rerun the Network stage to follow it, or raise -TimeoutMinutes."
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

function Find-ManagementAdapter([string]$NodeName, [object[]]$Rows, [string]$MacKey) {
    $match = @($Rows | Where-Object { $_.Mac -eq $MacKey })
    if ($match.Count -eq 1) { return $match[0] }
    $found = @($Rows | ForEach-Object { "$($_.AdapterName) $(Format-ZtpMac $_.Mac)$(if ($_.Description) { " ($($_.Description))" })" }) -join '; '
    if ($match.Count -eq 0) { throw "${NodeName}: no network adapter of edge machine $NodeName reports the management MAC $(Format-ZtpMac $MacKey). Found: $(if ($found) { $found } else { 'none' }). Fix the MAC in the environment file." }
    throw "${NodeName}: $($match.Count) network adapters report the management MAC $(Format-ZtpMac $MacKey): $found."
}

# ------------------------------------------------------------------ per node
$failed = [System.Collections.Generic.List[string]]::new()
foreach ($n in $selected) {
    $name = [string]$n['name']
    $mgmt = Get-ZtpPropertyValue $n 'management'
    $row = [ordered]@{ Node = $name; Mode = ''; Status = ''; Adapter = ''; AdapterName = ''; MacAddress = ''; Address = ''; Released = @(); Changes = @() }
    try {
        if ($null -eq $mgmt) {
            Write-ZtpLog "${name}: no management block in the parameters file; the Network stage leaves its adapters alone."
            if (-not $Execute) { "PLAN: ${name}: no management settings in the parameters file; nothing to do." }
            $row.Status = 'NotConfigured'
            [pscustomobject]$row
            continue
        }
        $mode = ([string](Get-ZtpPropertyValue $mgmt 'ip_assignment' 'static')).ToLowerInvariant()
        if (-not $mode) { $mode = 'static' }
        if ($mode -notin 'static', 'dhcp', 'dhcp_reservation', 'preconfigured') { throw "${name}: management.ip_assignment must be static, dhcp, dhcp_reservation or preconfigured, not '$mode'." }
        $row.Mode = $mode
        $macKey = ConvertTo-ZtpMacKey ([string](Get-ZtpPropertyValue $mgmt 'mac_address' ''))
        $row.MacAddress = Format-ZtpMac $macKey
        $ip = [string](Get-ZtpPropertyValue $mgmt 'ip_address' '')

        if ($mode -ne 'static') {
            if (-not $macKey) {
                Write-ZtpLog "${name}: $mode, and no management MAC in the parameters file; nothing to report."
                if (-not $Execute) { "PLAN: ${name}: $mode; no change (no management MAC to report on)." }
                $row.Status = 'Reported'
                [pscustomobject]$row
                continue
            }
            $rows = Get-NodeAdapter $name
            if ($null -eq $rows -or $rows.Count -eq 0) {
                if ($Execute) { throw "${name}: edge machine $name reports no network adapters. Run the Network stage after Ready (the OS install)." }
                "PLAN: ${name}: $mode; no change. The edge machine reports no network adapters yet (they appear after the OS install)."
                $row.Status = 'Reported'
                [pscustomobject]$row
                continue
            }
            $nic = Find-ManagementAdapter $name $rows $macKey
            $row.Adapter = $nic.Name; $row.AdapterName = $nic.AdapterName; $row.Address = $nic.Reported.Ip
            $text = "management port $($nic.AdapterName) ($(Format-ZtpMac $macKey)$(if ($nic.Description) { ", $($nic.Description)" })) is $mode and reports $(Format-ZtpNetworkSetting $nic.Reported)"
            Write-ZtpLog "${name}: $text; the Network stage doesn't change it."
            if ($ip -and $nic.Reported.Ip -and $nic.Reported.Ip -ne $ip) { Write-ZtpLog "${name}: the environment file expects $ip on $($nic.AdapterName); with $mode that takes a DHCP reservation for its MAC." -Level Warning }
            foreach ($other in @($rows | Where-Object { $ip -and $_.Mac -ne $macKey -and $_.Reported.Ip -eq $ip })) {
                Write-ZtpLog "${name}: $($other.AdapterName) ($(Format-ZtpMac $other.Mac)) also reports $ip." -Level Warning
            }
            if (-not $Execute) { "PLAN: ${name}: $mode; no change. The $text." }
            Send-NetworkEvent $name 'ManagementAddressReported' $text
            $row.Status = 'Reported'
            [pscustomobject]$row
            continue
        }

        # ---------------------------------------------------------- static
        $mask = [string](Get-ZtpPropertyValue $mgmt 'subnet_mask' '')
        $gateway = [string](Get-ZtpPropertyValue $mgmt 'gateway' '')
        $dns = @(@(Get-ZtpPropertyValue $mgmt 'dns_servers' @()) | Where-Object { $_ } | ForEach-Object { [string]$_ })
        $vlanValue = Get-ZtpPropertyValue $mgmt 'vlan_id' 0
        $vlan = if ($null -ne $vlanValue -and "$vlanValue" -ne '') { [int]"$vlanValue" } else { 0 }
        $missing = @(@{ mac_address = $macKey; ip_address = $ip; subnet_mask = $mask; gateway = $gateway }.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object Key | Sort-Object)
        if ($missing) { throw "${name}: a static management address needs $($missing -join ', ') in the parameters file's management block." }
        $wanted = "Static $ip $mask gw $gateway$(if ($dns) { " DNS $($dns -join ',')" }) VLAN $vlan up"

        $rows = Get-NodeAdapter $name
        if ($null -eq $rows -or $rows.Count -eq 0) {
            if ($Execute) { throw "${name}: edge machine $name reports no network adapters. Run the Network stage after Ready (the OS install)." }
            "PLAN: ${name}: the edge machine reports no network adapters yet (they appear after the OS install). Then: ApplyConfiguration $wanted on the adapter with MAC $(Format-ZtpMac $macKey), after moving any other adapter that holds $ip to Dhcp."
            $row.Status = 'Planned'
            [pscustomobject]$row
            continue
        }
        $nic = Find-ManagementAdapter $name $rows $macKey
        $adapterName = $nic.Desired.AdapterName
        if (-not $adapterName) { $adapterName = $nic.AdapterName }
        if (-not $adapterName) { throw "${name}: the adapter with MAC $(Format-ZtpMac $macKey) ($($nic.Name)) has no adapterName to configure." }
        $row.Adapter = $nic.Name; $row.AdapterName = $adapterName
        $target = [ordered]@{ adapterName = $adapterName; ip4Address = $ip; subnetMask = $mask; defaultGateway = $gateway; dnsServers = @($dns); ipInterfaceType = 'Static'; vlanId = $vlan; interfaceState = 'up' }
        $want = ConvertTo-ZtpNetworkSetting $target
        $holders = @($rows | Where-Object { $_.Mac -ne $macKey -and $_.Reported.Ip -eq $ip })
        $already = Test-ZtpNetworkSettingMatch -Reported $nic.Reported -Target $want
        Write-ZtpLog "${name}: management port $adapterName ($(Format-ZtpMac $macKey)$(if ($nic.Description) { ", $($nic.Description)" })) reports $(Format-ZtpNetworkSetting $nic.Reported); wanted $wanted."
        foreach ($h in $holders) { Write-ZtpLog "${name}: $($h.AdapterName) ($(Format-ZtpMac $h.Mac)$(if ($h.Description) { ", $($h.Description)" })) holds $ip." -Level Warning }

        if (-not $Execute) {
            foreach ($h in $holders) { "PLAN: ${name}: release $ip from $($h.AdapterName) ($(Format-ZtpMac $h.Mac)) first: ApplyConfiguration Dhcp, then wait until it no longer reports $ip." }
            if ($already) { "PLAN: ${name}: $adapterName ($(Format-ZtpMac $macKey)) already reports $wanted; no change." }
            else { "PLAN: ${name}: ApplyConfiguration on $adapterName ($(Format-ZtpMac $macKey)): $wanted (reports $(Format-ZtpNetworkSetting $nic.Reported) now); wait up to $TimeoutMinutes minutes for the job, then for the adapter to report it." }
            $row.Status = if ($already -and $holders.Count -eq 0) { 'AlreadySet' } else { 'Planned' }
            $row.Address = $nic.Reported.Ip
            [pscustomobject]$row
            continue
        }

        if ($already -and $holders.Count -eq 0) {
            Write-ZtpLog "${name}: $adapterName already reports $wanted; nothing to change."
            Send-NetworkEvent $name 'ManagementAddressAlreadySet' "$adapterName ($(Format-ZtpMac $macKey)) already reports $wanted"
            $row.Status = 'AlreadySet'; $row.Address = $ip
            [pscustomobject]$row
            continue
        }
        $what = @(foreach ($h in $holders) { "release $ip from $($h.AdapterName)" }) + @(if (-not $already) { "set $wanted on $adapterName" })
        if (-not $PSCmdlet.ShouldProcess("edge machine $name", ($what -join ', then '))) { continue }

        $changes = [System.Collections.Generic.List[string]]::new()
        foreach ($h in $holders) {
            if (-not $nic.Reported.Ip) { Write-ZtpLog "${name}: $adapterName reports no address, so the node may have no path to Azure between the release and the static address; the static job is sent at once, and the device applies it when it is back." -Level Warning }
            $hName = $h.Desired.AdapterName
            if (-not $hName) { $hName = $h.AdapterName }
            $release = [ordered]@{ adapterName = $hName; dnsServers = @(); ipInterfaceType = 'Dhcp'; vlanId = $h.Reported.Vlan; interfaceState = $(if ($h.Reported.InterfaceState) { $h.Reported.InterfaceState } else { 'up' }) }
            $job = Invoke-AdapterJob -NodeName $name -Adapter $h -Target $release -Action 'release'
            $holderName = $h.Name
            $null = Wait-AdapterReport $name { param($r) @($r | Where-Object { $_.Name -eq $holderName -and $_.Reported.Ip -eq $ip }).Count -eq 0 } "$ip gone from $hName"
            Write-NetworkChange $name $h 'release' $h.Reported (ConvertTo-ZtpNetworkSetting $release) 'applied' $job.Status
            Send-NetworkEvent $name 'ManagementAddressReleased' "$ip released from $hName ($(Format-ZtpMac $h.Mac)): Dhcp"
            $changes.Add("$hName $(Format-ZtpMac $h.Mac): $(Format-ZtpNetworkSetting $h.Reported) -> Dhcp")
            $row.Released = @($row.Released) + @($hName)
        }
        if (-not $already) {
            $job = Invoke-AdapterJob -NodeName $name -Adapter $nic -Target $target -Action 'apply'
            $nicName = $nic.Name
            $null = Wait-AdapterReport $name { param($r) @($r | Where-Object { $_.Name -eq $nicName -and (Test-ZtpNetworkSettingMatch -Reported $_.Reported -Target $want) }).Count -eq 1 } $wanted
            Write-NetworkChange $name $nic 'apply' $nic.Reported $want 'applied' $job.Status
            $changes.Add("$adapterName $(Format-ZtpMac $macKey): $(Format-ZtpNetworkSetting $nic.Reported) -> $wanted")
        }
        Write-ZtpLog "${name}: $adapterName reports $wanted."
        Send-NetworkEvent $name 'ManagementAddressSet' "$adapterName ($(Format-ZtpMac $macKey)) $wanted$(if ($row.Released) { "; released from $(@($row.Released) -join ', ')" })"
        $row.Status = 'Changed'; $row.Address = $ip; $row.Changes = @($changes)
        [pscustomobject]$row
    }
    catch {
        Write-Warning "$($_.Exception.Message)"
        $failed.Add($_.Exception.Message)
        Send-NetworkEvent $name 'ManagementAddressFailed' $_.Exception.Message 'Error' 'Fix the cause and rerun the Network stage (-From Network); a port already right is left alone.'
    }
}
if ($failed.Count -gt 0) { throw "Network: $($failed -join ' ')" }
