#Requires -Version 7.0
<#
.SYNOPSIS
Checks each node's management address on the adapter with the node's management MAC, through Azure's per-NIC report,
after the OS install. The Network stage, between Ready and Handoff. Verify-only by default.
.DESCRIPTION
Per node, it lists edgeMachines/<node>/networkAdapters and finds the management port: the adapter whose reported
macAddress is the MAC of the port the file gives role management (any make or slot: an onboard LOM, a PCIe or ConnectX
port, a converged port; separators and case don't matter). No match stops the node, listing the MACs found. Then it
compares what that port reports with the parameters file's management block, by mode (docs/prerequisites.md):
  Mode A, Reserved (dhcp_reservation)    verified when the port has ip_address, or, without one in the file, any address.
  Mode B, Static with DHCP (static)      verified when the port reports Static with ip_address and no other port has it.
  Mode C, Static without management DHCP (static, management_dhcp false)   the same check.
                    In Modes B and C the OS install resets every port, so after ZTP the management port normally has a
                    DHCP address (B) or none (C). The row is then Deferred: OS configuration (azurelocal-toolkit,
                    Set-AzureLocalNodeConfiguration.ps1, Network step) sets the static by MAC over Arc Run Command. The
                    reason says so, for example "Mode B (Static with DHCP): the management port Port1 (MAC
                    00:00:5e:00:53:aa) has DHCP 192.0.2.116 after the install; expected static 192.0.2.11; OS
                    configuration sets it by MAC."
  dhcp, preconfigured  reported only: verified when the port has ip_address; never changed.
Each row carries Verified and Reason (null when verified), which the orchestrator records in the state file and the
handoff (managementAddressVerified, managementAddressReason). Nothing is changed and no job is sent or waited on.
Why verify-only: the Device stage sets a static address by MAC in the maintenance environment, and that works, but
Microsoft's OS install then resets every port to DHCP (the maintenance environment's network settings don't carry into the
OS; Dell AX-760, build 2610, 2026-11-07). Fixing it through Azure's jobs/ApplyConfiguration proved unreliable: on two
separate runs the job never started ("Job is not yet triggered as other jobs are still running") and Azure marked it
Failed after about 35 minutes. OS configuration runs next anyway, and sets the address by MAC.
-ApplyThroughAzure keeps the old fix, for static nodes only (unreliable, see above): when another adapter reports the
node's management address, that adapter is set to Dhcp first (jobs/ApplyConfiguration) and the run waits until it no
longer reports it; then the management adapter gets ApplyConfiguration Static with the address, the mask, the gateway, the
DNS servers, the VLAN and interfaceState up. An adapter already right is left alone. Each job is followed until it succeeds
or fails, or -TimeoutMinutes passes, and a job that doesn't succeed fails the node.
Without -Execute only reads and prints PLAN: lines; with -Execute the result goes to -EventLogPath (stage Network), which
monitors follow, and with -ApplyThroughAzure each change is appended to -ChangeLogPath (JSON lines: time, node, adapter,
MAC, action, before, after, phase, job status).
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
-ApplyThroughAzure: how long to wait for each ApplyConfiguration job, and then for the adapter to report the result.
0 checks once.
.PARAMETER PollIntervalSeconds
-ApplyThroughAzure: how often to read a job or the adapters while waiting.
.PARAMETER EventLogPath
The ZTP event file (JSON lines, stage Network). Optional; written only with -Execute.
.PARAMETER ChangeLogPath
-ApplyThroughAzure: JSON-lines file every change is appended to (the run's evidence folder: network-changes.jsonl).
.PARAMETER ApplyThroughAzure
Opt-in, unreliable: move a static address that isn't on the management port there through Azure's
jobs/ApplyConfiguration, and wait for the jobs. Without it (the default) the stage only verifies.
.PARAMETER Execute
Record the result in -EventLogPath; with -ApplyThroughAzure, also change the adapters. Without it only the plan is printed.
.EXAMPLE
./Set-ZtpManagementAddress.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example -ParameterFile ./bicep/main.parameters.json
.EXAMPLE
./Set-ZtpManagementAddress.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example -ParameterFile ./bicep/main.parameters.json -EventLogPath D:\ZtpEvidence\ztp-events.jsonl -Execute
.EXAMPLE
./Set-ZtpManagementAddress.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example -ParameterFile ./bicep/main.parameters.json -Node node-01 -ChangeLogPath D:\ZtpEvidence\network-changes.jsonl -ApplyThroughAzure -Execute
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
    [switch]$ApplyThroughAzure,
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

# ------------------------------------------------------------------ verify
function Get-ManagementVerdict {
    # What the management port (the port with role management in the file, found by its MAC; any make or slot) reports
    # after the OS install, against the parameters file. Verified, Reason (null when verified), Status (AlreadySet,
    # Deferred or Reported), the event state and level, a one-line Text and the adapter row (Nic). Every message names the
    # mode (A Reserved, B Static with DHCP, C Static without management DHCP), the port, its MAC, what it has now and what
    # the file expects. $Rows is $null or empty when the edge machine reports no adapters yet. A MAC no adapter reports throws.
    param([string]$NodeName, [string]$Mode, [string]$MacKey, [string]$Ip, [bool]$ManagementDhcp = $true, [AllowNull()][object[]]$Rows)
    $label = (Get-ZtpManagementMode -IpAssignment $Mode -ManagementDhcp $ManagementDhcp).Label
    $v = [ordered]@{ Verified = $false; Reason = $null; Status = 'Reported'; State = 'ManagementAddressReported'; Level = 'Warning'; Text = ''; Nic = $null }
    $expectedText = switch ($Mode) {
        'static' { if ($Ip) { "expected static $Ip" } else { 'expected a static address, but the file gives no ip_address' } }
        'dhcp_reservation' { if ($Ip) { "expected the reserved $Ip" } else { 'expected a reserved DHCP address (the file gives no ip_address to compare)' } }
        default { if ($Ip) { "expected $Ip" } else { 'the file gives no address to compare' } }
    }
    $setBy = if (-not $ManagementDhcp) { 'OS configuration sets it by MAC over Arc' } else { 'OS configuration sets it by MAC' }
    # static: an address that isn't on the management port yet is left to OS configuration.
    $defer = {
        param([string]$Now)
        $v.Status = 'Deferred'; $v.State = 'ManagementAddressDeferredToOsConfiguration'; $v.Level = 'Info'
        $v.Reason = "${label}: $Now; $expectedText; $setBy."; $v.Text = $v.Reason
    }
    $notVerified = { param([string]$Now, [string]$Then) $v.Reason = "${label}: $Now; $expectedText$(if ($Then) { "; $Then" })."; $v.Text = $v.Reason }
    $verified = {
        param([string]$Now)
        $v.Verified = $true; $v.Reason = $null; $v.Level = 'Info'; $v.Text = "${label}: $Now."
        if ($Mode -eq 'static') { $v.Status = 'AlreadySet'; $v.State = 'ManagementAddressAlreadySet' }
    }
    if (-not $MacKey) {
        & $notVerified "no management MAC in the infrastructure file, so the management port wasn't checked" ''
        return [pscustomobject]$v
    }
    $portText = "the management port (MAC $(Format-ZtpMac $MacKey))"
    if ($null -eq $Rows -or @($Rows).Count -eq 0) {
        $now = "the edge machine reports no network adapters yet, so $portText wasn't checked"
        if ($Mode -eq 'static') { & $defer $now } else { & $notVerified $now '' }
        return [pscustomobject]$v
    }
    $nic = Find-ManagementAdapter $NodeName $Rows $MacKey
    $v.Nic = $nic
    $r = $nic.Reported
    $portText = "the management port $($nic.AdapterName) (MAC $(Format-ZtpMac $MacKey)$(if ($nic.Description) { ", $($nic.Description)" }))"
    $has = if ($r.Type -eq 'Dhcp' -and $r.Ip) { "DHCP $($r.Ip)" }
    elseif ($r.Type -eq 'Dhcp') { 'DHCP and no address' }
    elseif ($r.Type -eq 'Static' -and $r.Ip) { "static $($r.Ip)" }
    elseif ($r.Ip) { $r.Ip }
    else { 'no address' }
    $holders = @($Rows | Where-Object { $Ip -and $_.Mac -ne $MacKey -and $_.Reported.Ip -eq $Ip } | ForEach-Object { "$($_.AdapterName) (MAC $(Format-ZtpMac $_.Mac))" })
    $also = if ($holders.Count) { "; $($holders -join ', ') also $(if ($holders.Count -eq 1) { 'has' } else { 'have' }) $Ip" } else { '' }
    switch ($Mode) {
        'static' {
            if ($r.Type -eq 'Static' -and $Ip -and $r.Ip -eq $Ip -and $holders.Count -eq 0) { & $verified "$portText has static $Ip after the install, as expected" }
            else { & $defer "$portText has $has after the install$also" }
        }
        'dhcp_reservation' {
            if (-not $r.Ip) { & $notVerified "$portText has $has after the install" "check that the DHCP server answers and holds the reservation for MAC $(Format-ZtpMac $MacKey)" }
            elseif (-not $Ip) { & $verified "$portText has $has after the install; the file gives no ip_address, so the reserved address can't be compared" }
            elseif ($r.Ip -eq $Ip -and $holders.Count -eq 0) { & $verified "$portText has $has after the install, the reserved address" }
            else { & $notVerified "$portText has $has after the install$also" "check the DHCP reservation for MAC $(Format-ZtpMac $MacKey)" }
        }
        default {
            # dhcp and preconfigured: reported only, never changed.
            if ($Ip -and $r.Ip -eq $Ip) { & $verified "$portText has $has after the install, as expected" }
            else { & $notVerified "$portText has $has after the install" $(if ($Mode -eq 'dhcp') { 'reserve the address for the MAC (Mode A) or make it static (Mode B or C)' } else { 'preconfigured: the operator sets it' }) }
        }
    }
    return [pscustomobject]$v
}

# ------------------------------------------------------------------ per node
$failed = [System.Collections.Generic.List[string]]::new()
foreach ($n in $selected) {
    $name = [string]$n['name']
    $mgmt = Get-ZtpPropertyValue $n 'management'
    $row = [ordered]@{ Node = $name; Mode = ''; Status = ''; Adapter = ''; AdapterName = ''; MacAddress = ''; Address = ''; ExpectedAddress = ''; Verified = $false; Reason = $null; Released = @(); Changes = @() }
    try {
        if ($null -eq $mgmt) {
            Write-ZtpLog "${name}: no management block in the parameters file; the Network stage leaves its adapters alone."
            if (-not $Execute) { "PLAN: ${name}: no management settings in the parameters file; nothing to do." }
            $row.Status = 'NotConfigured'; $row.Reason = 'no management settings in the infrastructure file'
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
        $row.ExpectedAddress = $ip

        if ($mode -ne 'static' -or -not $ApplyThroughAzure) {
            # Verify only (the default; dhcp, dhcp_reservation and preconfigured always): read, compare, record.
            $rows = if ($macKey) { Get-NodeAdapter $name } else { $null }
            $verdict = Get-ManagementVerdict -NodeName $name -Mode $mode -MacKey $macKey -Ip $ip -ManagementDhcp ([string](Get-ZtpPropertyValue $mgmt 'management_dhcp' 'true') -ne 'False') -Rows $rows
            if ($verdict.Nic) { $row.Adapter = $verdict.Nic.Name; $row.AdapterName = $verdict.Nic.AdapterName; $row.Address = $verdict.Nic.Reported.Ip }
            $row.Status = $verdict.Status; $row.Verified = $verdict.Verified; $row.Reason = $verdict.Reason
            $verdictText = "$($verdict.Text)$(if ($verdict.Verified) { ' Verified.' })"
            Write-ZtpLog "${name}: $verdictText The Network stage doesn't change it." -Level $(if ($verdict.Level -eq 'Warning') { 'Warning' } else { 'Info' })
            if (-not $Execute) { "PLAN: ${name}: $mode; verify only, no change. $verdictText" }
            $next = if ($verdict.Status -eq 'Deferred') { 'OS configuration (azurelocal-toolkit Set-AzureLocalNodeConfiguration.ps1, Network step) sets the static address on the port with the management MAC.' } else { '' }
            Send-NetworkEvent $name $verdict.State $verdict.Text $verdict.Level $next
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
            $row.Status = 'Planned'; $row.Reason = 'static: not checked yet (plan; the edge machine reports no network adapters yet)'
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
            $row.Verified = $row.Status -eq 'AlreadySet'; if (-not $row.Verified) { $row.Reason = "static: not set yet (plan); $adapterName reports $(Format-ZtpNetworkSetting $nic.Reported)" }
            $row.Address = $nic.Reported.Ip
            [pscustomobject]$row
            continue
        }

        if ($already -and $holders.Count -eq 0) {
            Write-ZtpLog "${name}: $adapterName already reports $wanted; nothing to change."
            Send-NetworkEvent $name 'ManagementAddressAlreadySet' "$adapterName ($(Format-ZtpMac $macKey)) already reports $wanted"
            $row.Status = 'AlreadySet'; $row.Address = $ip; $row.Verified = $true
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
        $row.Status = 'Changed'; $row.Address = $ip; $row.Verified = $true; $row.Changes = @($changes)
        [pscustomobject]$row
    }
    catch {
        Write-Warning "$($_.Exception.Message)"
        $failed.Add($_.Exception.Message)
        Send-NetworkEvent $name 'ManagementAddressFailed' $_.Exception.Message 'Error' 'Fix the cause and rerun the Network stage (-From Network); a port already right is left alone.'
    }
}
if ($failed.Count -gt 0) { throw "Network: $($failed -join ' ')" }
