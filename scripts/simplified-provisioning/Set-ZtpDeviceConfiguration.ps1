#Requires -Version 7.0
<#
.SYNOPSIS
Sets each node's static management address on the port with its management MAC in the maintenance environment, before
the Azure claim. The Device stage, between Vouchers and Azure.
.DESCRIPTION
The maintenance environment runs the Configurator App's REST service (BootstrapOobeService, CoreWCF WebHttp, JSON,
Basic auth) at https://<maintenance address>:20001/BootstrapOobeService/<Operation>. This script uses it the way the
Configurator App does, so the address is on the right port before the OS install instead of on the first ready port.
With static_method device (the default of Invoke-ZtpEnvironment.ps1) this is the only static the node gets: the site is
Automatic and the claim carries no Manual adapter.
Finding the maintenance environment: the node list's maintenance_address when it has one. Otherwise the script scans for
it: every address of the node's maintenance_scan_range (start-end; Invoke-ZtpEnvironment.ps1 writes it from
network_intents.management.provisioning_dhcp_range), else of the management subnet (the parameters file's ip_address and
subnet_mask), is probed on TCP -Port in parallel; each one that answers is asked GET GetNetworkAdapters, and the node is
the one whose adapters include its management MAC. The scan repeats every -PollIntervalSeconds until every node is found
or -TimeoutMinutes passes (the node may still be booting); a plan scans once. Each node of the maintenance environment
takes a DHCP lease on every port, so it answers on several addresses; one not on the management port is preferred.
Verified live (Dell AX-760, 2026-11-07, maintenance environment on DHCP with no reservation): found by MAC in a .100-.250
scan. The probes run in batches of 256 sockets and every client is disposed; the sweep repeats until the deadline.
The scan needs dotted-quad IPv4 addresses and a contiguous mask; a /31 or /32 management subnet isn't supported for it (set
maintenance_address or provisioning_dhcp_range). Run it only on an isolated provisioning network (see Credentials below).
Per node:
1. GET GetNetworkAdapters (verified live: HTTP 200, { NetworkAdapters: [ { MacAddress, Name, EnableDhcp, IpAddress,
   Gateway, SubnetMask, DnsAddressArray, VlanId, ... } ] }, MACs as 12 lower-case hex digits) and finds the adapter with
   the management MAC of the parameters file (separators and case don't matter). No match stops the node, listing the
   MACs found.
2. static: an adapter that already reports EnableDhcp false with the address, mask, gateway, DNS and VLAN is left
   alone. Otherwise POST SetArcBootstrapDeviceConfiguration with { Network: { NetworkAdapters: [ { MacAddress (12
   lower-case hex digits, as GetNetworkAdapters reports it), EnableDhcp false, IpAddress, SubnetMask, Gateway,
   DnsAddressArray, VlanId 0 } ] } }. Verified live (2026-11-07): the response and the status report NetworkConfig
   Succeeded, and GetNetworkAdapters then reads the static address back on the management port (an onboard LOM there). No HostName is sent (the claim sets
   the host name; the verified request had none). Another adapter that already holds the target address statically stops
   the node before anything is sent (the message names the port, its MAC and the address): releasing another port isn't a
   request shape verified live, so ZTP never sends it. That is a known limit.
3. Polls GET GetArcBootstrapDeviceConfigurationStatus (verified live: { Response: { Name: Bootstrap, Status,
   DetailedResponse: [ { Name: NetworkConfig | RemoteConfig | WebProxy | TimeServer | HostName, Status } ] }, Version };
   a Status that reads Failed stops the node) and GET GetNetworkAdapters until the management adapter reports the static
   configuration, or -TimeoutMinutes passes. When the management port is the one the maintenance address is on, the
   service answers on the new address afterwards, so both are tried. A read-back counts only when its adapter list holds
   the management MAC: the old DHCP lease is free once the static applies and another device could take it, so a response
   without the MAC is ignored, and the status is read only from an address that passed that check.
Before anything is sent, two nodes with the same static ip_address, or an ip_address inside a node's explicit
maintenance_scan_range (the DHCP pool would lease it out), stop the run.
Credentials: the script signs in as edgeuser with the maintenance environment's default password (Password1, documented by
Learn, or the one the image was built with) over TLS with the certificate check skipped, to every host that answers on TCP
20001 in the scan range. The maintenance environment can't be certificate-pinned, so a device that imitates the service could
receive that password. Scan only an isolated provisioning network and keep maintenance_scan_range to the DHCP pool.
dhcp, dhcp_reservation and preconfigured nodes are only reported, and only when the node list gives their maintenance
address; they aren't scanned for.
The service's certificate is self-signed by the maintenance environment and there is no CA to check it against, so this
script, and only this script's calls, skip the certificate check. The password is the edgeuser password the image was
built with (-EdgeUserPassword of the Media stage); without one, the maintenance environment's default Password1.
Without -Execute only reads: it prints what it would do (PLAN: lines) and returns one row per node. With -Execute each
change is appended to -ChangeLogPath (JSON lines) and the progress goes to -EventLogPath (stage Device).
.PARAMETER ParameterFile
The parameters file of bicep/main.bicep (JSON, or a .bicepparam compiled with az bicep build-params): each node's
management block (ip_assignment, mac_address, ip_address, subnet_mask, gateway, dns_servers, vlan_id).
.PARAMETER NodesFile
The node list (see config/simplified-provisioning/nodes.example.json): maintenance_address per node, the address the
maintenance environment has on its provisioning port (the address its console shows), or maintenance_scan_range
(start-end) to scan when the address isn't known in advance. With neither, the management subnet is scanned.
.PARAMETER Node
Nodes to handle (default: every node in the parameters file).
.PARAMETER EdgeUserPassword
The edgeuser password of the maintenance environment. Without it, Password1.
.PARAMETER Port
The REST service port.
.PARAMETER TimeoutMinutes
How long to scan for a maintenance environment without an address, and then to wait for the configuration to show on
the management adapter. 0 checks once.
.PARAMETER PollIntervalSeconds
How often to scan again, and to read the status and the adapters while waiting.
.PARAMETER ProbeTimeoutMilliseconds
How long one TCP probe of the scan waits for a connection.
.PARAMETER RequestTimeoutSeconds
Timeout of one REST call.
.PARAMETER EventLogPath
The ZTP event file (JSON lines, stage Device). Optional; written only with -Execute.
.PARAMETER ChangeLogPath
JSON-lines file every change is appended to (the run's evidence folder: device-changes.jsonl). Optional.
.PARAMETER Execute
Change the maintenance environment. Without it only the plan is printed.
.EXAMPLE
./Set-ZtpDeviceConfiguration.ps1 -ParameterFile ./bicep/main.parameters.json -NodesFile ../../config/simplified-provisioning/nodes.json
.EXAMPLE
./Set-ZtpDeviceConfiguration.ps1 -ParameterFile ./bicep/main.parameters.json -NodesFile ../../config/simplified-provisioning/nodes.json -EdgeUserPassword $edge -ChangeLogPath D:\ZtpEvidence\device-changes.jsonl -Execute
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The parameters are read inside the helper functions.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Password1 is the maintenance environment''s published default, not a secret.')]
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$ParameterFile,
    [Parameter(Mandatory)][string]$NodesFile,
    [string[]]$Node,
    [securestring]$EdgeUserPassword,
    [ValidateRange(1, 65535)][int]$Port = 20001,
    [ValidateRange(0, 1440)][int]$TimeoutMinutes = 30,
    [ValidateRange(0, 3600)][int]$PollIntervalSeconds = 15,
    [ValidateRange(5, 600)][int]$RequestTimeoutSeconds = 30,
    [ValidateRange(50, 10000)][int]$ProbeTimeoutMilliseconds = 500,
    [string]$EventLogPath,
    [string]$ChangeLogPath,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpAzure.Common.ps1')
. (Join-Path $PSScriptRoot 'ZtpEvents.Common.ps1')

# ------------------------------------------------------------------ inputs
foreach ($f in $ParameterFile, $NodesFile) { if (-not (Test-Path -LiteralPath $f)) { throw "File not found: $f." } }
$parameters = if ([IO.Path]::GetExtension($ParameterFile) -eq '.bicepparam') {
    $built = (& az bicep build-params --file $ParameterFile --stdout 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "az bicep build-params $ParameterFile failed: $built" }
    (($built | ConvertFrom-Json -Depth 64).parametersJson | ConvertFrom-Json -AsHashtable -Depth 64).parameters
}
else { (Get-Content -LiteralPath $ParameterFile -Raw | ConvertFrom-Json -AsHashtable -Depth 64).parameters }
if (-not $parameters -or -not $parameters.Contains('nodes') -or -not $parameters['nodes']['value']) { throw "The parameters file $ParameterFile has no nodes." }
$nodeEntries = @($parameters['nodes']['value'])
$listed = @((Get-Content -LiteralPath $NodesFile -Raw | ConvertFrom-Json -AsHashtable -Depth 10)['nodes'])
if ($Node) {
    $unknown = @($Node | Where-Object { $_ -notin @($nodeEntries | ForEach-Object { [string]$_['name'] }) })
    if ($unknown.Count -gt 0) { throw "Unknown node(s) $($unknown -join ', '): not in $ParameterFile." }
}
$selected = @($nodeEntries | Where-Object { -not $Node -or [string]$_['name'] -in $Node })
$password = if ($EdgeUserPassword) { $EdgeUserPassword } else { ConvertTo-SecureString 'Password1' -AsPlainText -Force }
$credential = [pscredential]::new('edgeuser', $password)
if (-not $EdgeUserPassword) { Write-ZtpLog 'No -EdgeUserPassword: signing in to the maintenance environment as edgeuser with its default password.' -Level Verbose }

# ------------------------------------------------------------------ evidence
function Send-DeviceEvent([string]$NodeName, [string]$State, [string]$Evidence, [string]$Level = 'Info', [string]$NextAction = '') {
    if (-not $Execute -or -not $EventLogPath) { return }
    try { Write-ZtpEvent -Path $EventLogPath -Node $NodeName -State $State -Evidence $Evidence -NextAction $NextAction -Level $Level -Stage 'Device' }
    catch { Write-Warning "Couldn't write the Device event to ${EventLogPath}: $($_.Exception.Message)" }
}
function Write-DeviceChange([string]$NodeName, [string]$Address, [object]$Adapter, [object]$Request, [string]$Phase, [string]$Status) {
    if (-not $ChangeLogPath) { return }
    $dir = Split-Path -Parent $ChangeLogPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    $line = [ordered]@{
        timestamp = [datetime]::UtcNow.ToString('o'); node = $NodeName; maintenanceAddress = $Address; adapter = $Adapter.Name; macAddress = Format-ZtpMac $Adapter.Mac
        before = [ordered]@{ EnableDhcp = $Adapter.EnableDhcp; IpAddress = $Adapter.Ip; SubnetMask = $Adapter.Mask; Gateway = $Adapter.Gateway; DnsAddressArray = @($Adapter.Dns); VlanId = $Adapter.Vlan }
        request = $Request; phase = $Phase; status = $Status
    } | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $ChangeLogPath -Value $line
}

# ------------------------------------------------------------------ the REST service
function Invoke-OobeCall([string]$Address, [string]$Operation, [string]$Method = 'GET', [object]$Body) {
    # The maintenance environment signs its own certificate; nothing can verify it, so this call alone skips the check.
    $request = @{
        Uri = "https://${Address}:$Port/BootstrapOobeService/$Operation"; Method = $Method; Authentication = 'Basic'; Credential = $credential
        SkipCertificateCheck = $true; TimeoutSec = $RequestTimeoutSeconds; ContentType = 'application/json'; ErrorAction = 'Stop'
    }
    if ($null -ne $Body) { $request.Body = ($Body | ConvertTo-Json -Depth 10 -Compress) }
    Invoke-RestMethod @request
}
function ConvertTo-OobeAdapter([object]$Response) {
    foreach ($a in @(Get-ZtpPropertyValue $Response 'NetworkAdapters' @())) {
        if ($null -eq $a) { continue }
        $rawMac = [string](Get-ZtpPropertyValue $a 'MacAddress' '')
        $vlanRaw = Get-ZtpPropertyValue $a 'VlanId'
        [pscustomobject]@{
            Name       = [string](Get-ZtpPropertyValue $a 'Name' '')
            RawMac     = $rawMac
            Mac        = $(try { ConvertTo-ZtpMacKey $rawMac } catch { $rawMac.ToLowerInvariant() })
            EnableDhcp = [bool](Get-ZtpPropertyValue $a 'EnableDhcp' $false)
            Ip         = [string](Get-ZtpPropertyValue $a 'IpAddress' '')
            Mask       = [string](Get-ZtpPropertyValue $a 'SubnetMask' '')
            Gateway    = [string](Get-ZtpPropertyValue $a 'Gateway' '')
            Dns        = @(@(Get-ZtpPropertyValue $a 'DnsAddressArray' @()) | Where-Object { $_ } | ForEach-Object { [string]$_ })
            Vlan       = $(if ($null -ne $vlanRaw -and "$vlanRaw" -ne '') { [int]"$vlanRaw" } else { 0 })
            VlanIsText = ($vlanRaw -is [string])
        }
    }
}
function Get-OobeAdapter([string[]]$Addresses, [string]$MacKey = '') {
    # The adapters, from the first address that answers: @{ Address; Adapters } or $null with the last error in Error.
    $lastError = ''
    foreach ($address in $Addresses) {
        try {
            $adapters = @(ConvertTo-OobeAdapter (Invoke-OobeCall $address 'GetNetworkAdapters'))
            # With -MacKey, an address whose adapters lack that MAC is not this node (its lease may have gone to another device).
            if ($MacKey -and -not @($adapters | Where-Object { $_.Mac -eq $MacKey }).Count) { $lastError = "${address}: answers, but none of its adapters has the management MAC $(Format-ZtpMac $MacKey) (another device?)"; continue }
            return [pscustomobject]@{ Address = $address; Adapters = $adapters; Error = '' }
        }
        catch { $lastError = "${address}: $($_.Exception.Message)" }
    }
    return [pscustomobject]@{ Address = ''; Adapters = @(); Error = $lastError }
}
function Format-OobeAdapter([object]$Adapter) {
    if ($Adapter.EnableDhcp) { return "DHCP$(if ($Adapter.Ip) { " $($Adapter.Ip)" })" }
    "static $($Adapter.Ip) $($Adapter.Mask) gw $($Adapter.Gateway)$(if (@($Adapter.Dns).Count) { " DNS $(@($Adapter.Dns) -join ',')" }) VLAN $($Adapter.Vlan)"
}
function Test-OobeStatic([object]$Adapter, [string]$Ip, [string]$Mask, [string]$Gateway, [string[]]$Dns, [int]$Vlan) {
    -not $Adapter.EnableDhcp -and $Adapter.Ip -eq $Ip -and $Adapter.Mask -eq $Mask -and $Adapter.Gateway -eq $Gateway -and (@($Adapter.Dns) -join ',') -eq (@($Dns) -join ',') -and $Adapter.Vlan -eq $Vlan
}
function Get-OobeStatus([object]$Response) {
    # GetArcBootstrapDeviceConfigurationStatus, verified live: { Response: { Name: Bootstrap, Status, DetailedResponse:
    # [ { Name, Status } ] }, Version }. A flat status-like property is read too.
    if ($null -eq $Response) { return [pscustomobject]@{ Text = 'no status'; Failed = $false } }
    if ($Response -is [string]) { return [pscustomobject]@{ Text = $Response; Failed = ($Response -match 'Fail') } }
    $inner = Get-ZtpPropertyValue $Response 'Response'
    if ($null -ne $inner -and $inner -isnot [string]) {
        $overall = [string](Get-ZtpPropertyValue $inner 'Status' '')
        $steps = @(foreach ($s in @(Get-ZtpPropertyValue $inner 'DetailedResponse' @())) { if ($null -ne $s) { [pscustomobject]@{ Name = [string](Get-ZtpPropertyValue $s 'Name' ''); Status = [string](Get-ZtpPropertyValue $s 'Status' '') } } })
        $text = "$(Get-ZtpPropertyValue $inner 'Name' 'Bootstrap') $(if ($overall) { $overall } else { 'no status' })$(if ($steps) { " ($(@($steps | ForEach-Object { "$($_.Name) $($_.Status)" }) -join ', '))" })"
        return [pscustomobject]@{ Text = $text; Failed = ($overall -match 'Fail' -or [bool]@($steps | Where-Object { $_.Status -match 'Fail' }).Count) }
    }
    $values = @(foreach ($k in 'Status', 'State', 'ConfigurationStatus', 'DeploymentStatus') { $v = Get-ZtpPropertyValue $Response $k; if ($null -ne $v -and "$v" -ne '') { "$k $v" } })
    $text = if ($values) { $values -join ', ' } else { ($Response | ConvertTo-Json -Compress -Depth 5) }
    if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + '...' }
    return [pscustomobject]@{ Text = $text; Failed = [bool](@($values | Where-Object { $_ -match 'Fail' }).Count) }
}
function Find-OobeManagementAdapter([string]$NodeName, [object[]]$Adapters, [string]$MacKey) {
    $match = @($Adapters | Where-Object { $_.Mac -eq $MacKey })
    if ($match.Count -eq 1) { return $match[0] }
    $found = @($Adapters | ForEach-Object { "$($_.Name) $(Format-ZtpMac $_.Mac)" }) -join '; '
    if ($match.Count -eq 0) { throw "${NodeName}: no network adapter in the maintenance environment reports the management MAC $(Format-ZtpMac $MacKey). Found: $(if ($found) { $found } else { 'none' }). Fix the MAC in the environment file." }
    throw "${NodeName}: $($match.Count) network adapters in the maintenance environment report the management MAC $(Format-ZtpMac $MacKey): $found."
}

# ------------------------------------------------------------------ finding a maintenance environment by MAC
function ConvertTo-IpNumber([string]$Address) {
    # Dotted-quad IPv4 only: no IPv6, no shortened, hexadecimal or zero-padded forms, each part 0-255.
    if ($Address -notmatch '^(0|[1-9]\d{0,2})(\.(0|[1-9]\d{0,2})){3}$') { throw "'$Address' isn't a dotted-quad IPv4 address (IPv6 and shortened, hexadecimal or zero-padded forms aren't accepted)." }
    $parts = @($Address.Split('.') | ForEach-Object { [uint64]$_ })
    if (@($parts | Where-Object { $_ -gt 255 }).Count) { throw "'$Address' isn't an IPv4 address: a part is above 255." }
    return $parts[0] * 16777216 + $parts[1] * 65536 + $parts[2] * 256 + $parts[3]
}
function ConvertFrom-IpNumber([uint64]$Value) { (3, 2, 1, 0 | ForEach-Object { ($Value -shr (8 * $_)) -band 255 }) -join '.' }
function Get-ScanAddress([string]$Range, [string]$Ip, [string]$Mask) {
    # The addresses to probe: start-end, else every host of the management subnet. At most 4096.
    if ($Range) {
        if ($Range -notmatch '^\s*(\d{1,3}(\.\d{1,3}){3})\s*-\s*(\d{1,3}(\.\d{1,3}){3})\s*$') { throw "maintenance_scan_range '$Range' isn't start-end (for example 192.0.2.100-192.0.2.250)." }
        $first = ConvertTo-IpNumber $Matches[1]; $last = ConvertTo-IpNumber $Matches[3]
    }
    else {
        if (-not $Ip -or -not $Mask) { throw 'no maintenance_address, no maintenance_scan_range and no management ip_address and subnet_mask to scan the subnet of.' }
        $m = ConvertTo-IpNumber $Mask
        $hostBits = 4294967295 - $m
        if (($hostBits -band ($hostBits + 1)) -ne 0) { throw "the subnet mask $Mask isn't contiguous." }
        if ($hostBits -le 1) { throw "the management subnet mask $Mask is a /$(32 - [int][Math]::Log2($hostBits + 1)) network; the scan doesn't support /31 or /32. Set maintenance_address or network_intents.management.provisioning_dhcp_range." }
        $network = (ConvertTo-IpNumber $Ip) -band $m
        $broadcast = $network + $hostBits
        $first = $network + 1; $last = $broadcast - 1
    }
    if ($last -lt $first) { throw "the scan range $(ConvertFrom-IpNumber $first)-$(ConvertFrom-IpNumber $last) is empty." }
    if ($last - $first -ge 4096) { throw "the scan range $(ConvertFrom-IpNumber $first)-$(ConvertFrom-IpNumber $last) has more than 4096 addresses; set network_intents.management.provisioning_dhcp_range to the DHCP pool." }
    @(for ($v = $first; $v -le $last; $v++) { ConvertFrom-IpNumber $v })
}
if (-not (Get-Command Test-ZtpTcpPort -ErrorAction SilentlyContinue)) {
    # The addresses that accept a TCP connection on the port within the timeout, probed in parallel (tests supply their own).
    function Test-ZtpTcpPort([string[]]$Address, [int]$Port, [int]$TimeoutMilliseconds) {
        # Bounded batches (256 sockets at a time); each client is created inside the try and every one is disposed, so a
        # socket or ephemeral-port failure part-way leaks nothing.
        $open = [System.Collections.Generic.List[string]]::new()
        $batchSize = 256
        for ($offset = 0; $offset -lt @($Address).Count; $offset += $batchSize) {
            $batch = @($Address | Select-Object -Skip $offset -First $batchSize)
            $probes = [System.Collections.Generic.List[object]]::new()
            try {
                foreach ($a in $batch) {
                    $p = [pscustomobject]@{ Address = $a; Client = [System.Net.Sockets.TcpClient]::new(); Task = $null }
                    $probes.Add($p)
                    try { $p.Task = $p.Client.ConnectAsync($a, $Port) } catch { Write-Verbose "${a}:${Port} couldn't start a probe: $($_.Exception.Message)" }
                }
                $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
                foreach ($p in $probes) {
                    if (-not $p.Task) { continue }
                    $left = [int][Math]::Max(0, ($deadline - [datetime]::UtcNow).TotalMilliseconds)
                    try { $null = $p.Task.Wait($left) } catch { Write-Verbose "$($p.Address):${Port} refused or unreachable." }
                }
                foreach ($p in $probes) { if ($p.Task -and $p.Task.Status -eq 'RanToCompletion' -and $p.Client.Connected) { $open.Add($p.Address) } }
            }
            finally { foreach ($p in $probes) { $p.Client.Dispose() } }
        }
        return $open.ToArray()
    }
}
function Find-OobeNode([object[]]$Wanted) {
    # One scan: each wanted { Name; MacKey; Candidates } found gets Address set. Returns how many answered on the port.
    $all = @($Wanted | ForEach-Object { $_.Candidates } | Select-Object -Unique)
    $open = @(Test-ZtpTcpPort -Address $all -Port $Port -TimeoutMilliseconds $ProbeTimeoutMilliseconds)
    foreach ($address in $open) {
        $adapters = try { @(ConvertTo-OobeAdapter (Invoke-OobeCall $address 'GetNetworkAdapters')) } catch { Write-ZtpLog "${address}:$Port answers but GetNetworkAdapters failed: $($_.Exception.Message)" -Level Verbose; continue }
        foreach ($w in @($Wanted | Where-Object { $address -in $_.Candidates })) {
            $nic = @($adapters | Where-Object { $_.Mac -eq $w.MacKey }) | Select-Object -First 1
            if (-not $nic) { continue }
            # Every port of the maintenance environment takes a lease; prefer one that isn't the management port, which
            # changes address when the static one is applied.
            if (-not $w.Address -or ($w.Address -eq $w.ManagementLease -and $address -ne $nic.Ip)) { $w.Address = $address; $w.ManagementLease = $nic.Ip }
        }
    }
    return $open.Count
}

# ------------------------------------------------------------------ per node
$failed = [System.Collections.Generic.List[string]]::new()
# Static nodes the node list gives no maintenance address for: scan for them by MAC, all at once, until found or the deadline.
$found = @{}
$scanProblem = @{}
# Before any request: two nodes can't share a static address, and a node's static address can't sit inside its own explicit
# scan range (the DHCP pool would lease it out).
$targets = @(foreach ($n in $selected) {
        $mgmt = Get-ZtpPropertyValue $n 'management'
        if ($null -eq $mgmt) { continue }
        if (([string](Get-ZtpPropertyValue $mgmt 'ip_assignment' 'static')).ToLowerInvariant() -notin '', 'static') { continue }
        $tip = [string](Get-ZtpPropertyValue $mgmt 'ip_address' '')
        if ($tip -notmatch '^(0|[1-9]\d{0,2})(\.(0|[1-9]\d{0,2})){3}$') { continue }
        $tentry = @($listed | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['name'] -eq [string]$n['name'] }) | Select-Object -First 1
        [pscustomobject]@{ Name = [string]$n['name']; Ip = $tip; Range = $(if ($tentry) { [string](Get-ZtpPropertyValue $tentry 'maintenance_scan_range' '') } else { '' }) }
    })
$preProblems = [System.Collections.Generic.List[string]]::new()
foreach ($g in @($targets | Group-Object Ip | Where-Object Count -GT 1)) { $preProblems.Add("nodes $(@($g.Group.Name) -join ', ') share the management ip_address $($g.Name); every node needs its own.") }
foreach ($t in @($targets | Where-Object Range)) {
    $inRange = try { $t.Ip -in @(Get-ScanAddress $t.Range '' '') } catch { $false }
    if ($inRange) { $preProblems.Add("$($t.Name): the management ip_address $($t.Ip) is inside its maintenance_scan_range $($t.Range), the DHCP pool, where it could be leased to another device. Use an address outside the pool.") }
}
if ($preProblems.Count) { throw "Device: $($preProblems -join ' ')" }
$wanted = @(foreach ($n in $selected) {
        $name = [string]$n['name']
        $mgmt = Get-ZtpPropertyValue $n 'management'
        if ($null -eq $mgmt) { continue }
        $mode = ([string](Get-ZtpPropertyValue $mgmt 'ip_assignment' 'static')).ToLowerInvariant()
        if ($mode -and $mode -ne 'static') { continue }
        $entry = @($listed | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['name'] -eq $name }) | Select-Object -First 1
        if ($entry -and [string](Get-ZtpPropertyValue $entry 'maintenance_address' '')) { continue }
        try {
            $macKey = ConvertTo-ZtpMacKey ([string](Get-ZtpPropertyValue $mgmt 'mac_address' ''))
            if (-not $macKey) { throw 'the parameters file''s management block has no mac_address.' }
            $range = if ($entry) { [string](Get-ZtpPropertyValue $entry 'maintenance_scan_range' '') } else { '' }
            $candidates = @(Get-ScanAddress $range ([string](Get-ZtpPropertyValue $mgmt 'ip_address' '')) ([string](Get-ZtpPropertyValue $mgmt 'subnet_mask' '')))
            [pscustomobject]@{ Name = $name; MacKey = $macKey; Candidates = $candidates; Address = ''; ManagementLease = ''; Range = "$($candidates[0])-$($candidates[-1])" }
        }
        catch { $scanProblem[$name] = "${name}: $($_.Exception.Message)" }
    })
if ($wanted.Count) {
    $deadline = [datetime]::UtcNow.AddMinutes($(if ($Execute) { $TimeoutMinutes } else { 0 }))
    $sweeps = 0
    while ($true) {
        $answered = Find-OobeNode $wanted
        $sweeps++
        $missing = @($wanted | Where-Object { -not $_.Address })
        foreach ($w in @($wanted | Where-Object { $_.Address -and -not $found.ContainsKey($_.Name) })) {
            $found[$w.Name] = $w.Address
            $text = "maintenance environment found by its management MAC $(Format-ZtpMac $w.MacKey) at $($w.Address) (scan of $($w.Range))"
            Write-ZtpLog "$($w.Name): $text."
            Send-DeviceEvent $w.Name 'MaintenanceEnvironmentFound' $text
        }
        if ($missing.Count -eq 0 -or [datetime]::UtcNow -ge $deadline) { break }
        Write-ZtpLog "Scan $sweeps for $(@($missing | ForEach-Object Name) -join ', '): $answered address(es) answer on TCP $Port, none with their management MAC yet; scanning again in $PollIntervalSeconds s." -Level Verbose
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    foreach ($w in @($wanted | Where-Object { -not $_.Address })) {
        $scanProblem[$w.Name] = "$($w.Name): no maintenance environment with the management MAC $(Format-ZtpMac $w.MacKey) answers on TCP $Port in $($w.Range)$(if ($Execute) { " within $TimeoutMinutes minutes ($sweeps scan(s))" } else { ' now' }). Check that the node booted the maintenance environment, that this host reaches that network on TCP $Port, and the MAC; or set maintenance_address (or network_intents.management.provisioning_dhcp_range)."
    }
}
foreach ($n in $selected) {
    $name = [string]$n['name']
    $mgmt = Get-ZtpPropertyValue $n 'management'
    $entry = @($listed | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['name'] -eq $name }) | Select-Object -First 1
    $maintenance = if ($entry) { [string](Get-ZtpPropertyValue $entry 'maintenance_address' '') } else { '' }
    $row = [ordered]@{ Node = $name; Mode = ''; Status = ''; Adapter = ''; MacAddress = ''; Address = ''; MaintenanceAddress = $maintenance; Released = @() }
    try {
        if ($null -eq $mgmt) {
            if (-not $Execute) { "PLAN: ${name}: no management settings in the parameters file; nothing to do." }
            $row.Status = 'NotConfigured'; [pscustomobject]$row; continue
        }
        $mode = ([string](Get-ZtpPropertyValue $mgmt 'ip_assignment' 'static')).ToLowerInvariant()
        if (-not $mode) { $mode = 'static' }
        if ($mode -notin 'static', 'dhcp', 'dhcp_reservation', 'preconfigured') { throw "${name}: management.ip_assignment must be static, dhcp, dhcp_reservation or preconfigured, not '$mode'." }
        $row.Mode = $mode
        $macKey = ConvertTo-ZtpMacKey ([string](Get-ZtpPropertyValue $mgmt 'mac_address' ''))
        $row.MacAddress = Format-ZtpMac $macKey
        $ip = [string](Get-ZtpPropertyValue $mgmt 'ip_address' '')
        if (-not $maintenance -and $mode -ne 'static') {
            $why = "${name}: $mode, and no maintenance_address in the node list; nothing to report in the maintenance environment."
            Write-ZtpLog $why
            if (-not $Execute) { "PLAN: $why" }
            $row.Status = 'Skipped'; [pscustomobject]$row; continue
        }
        if (-not $maintenance) {
            if ($found.ContainsKey($name)) { $maintenance = $found[$name]; $row.MaintenanceAddress = $maintenance }
            elseif (-not $Execute) {
                "PLAN: $($scanProblem[$name]) With -Execute the Device stage scans for up to $TimeoutMinutes minutes."
                $row.Status = 'Planned'; [pscustomobject]$row; continue
            }
            else { throw $scanProblem[$name] }
        }
        if (-not $macKey) { throw "${name}: the parameters file's management block has no mac_address." }

        $read = Get-OobeAdapter @($maintenance)
        if (-not $read.Address) { throw "${name}: the maintenance environment's REST service at ${maintenance}:$Port doesn't answer ($($read.Error)). Check maintenance_address (the address on the node's console) and that TCP $Port is reachable from this host." }
        $nic = Find-OobeManagementAdapter $name $read.Adapters $macKey
        $row.Adapter = $nic.Name; $row.Address = $nic.Ip

        if ($mode -ne 'static') {
            $text = "management port $($nic.Name) ($(Format-ZtpMac $macKey)) is $mode and reports $(Format-OobeAdapter $nic)"
            Write-ZtpLog "${name}: $text; the Device stage doesn't change it."
            if (-not $Execute) { "PLAN: ${name}: $mode; no change. The $text." }
            Send-DeviceEvent $name 'DeviceAddressReported' $text
            $row.Status = 'Reported'; [pscustomobject]$row; continue
        }

        $mask = [string](Get-ZtpPropertyValue $mgmt 'subnet_mask' '')
        $gateway = [string](Get-ZtpPropertyValue $mgmt 'gateway' '')
        $dns = @(@(Get-ZtpPropertyValue $mgmt 'dns_servers' @()) | Where-Object { $_ } | ForEach-Object { [string]$_ })
        $vlanValue = Get-ZtpPropertyValue $mgmt 'vlan_id' 0
        $vlan = if ($null -ne $vlanValue -and "$vlanValue" -ne '') { [int]"$vlanValue" } else { 0 }
        $missing = @(@{ ip_address = $ip; subnet_mask = $mask; gateway = $gateway }.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object Key | Sort-Object)
        if ($missing) { throw "${name}: a static management address needs $($missing -join ', ') in the parameters file's management block." }
        $wanted = "static $ip $mask gw $gateway$(if ($dns) { " DNS $($dns -join ',')" }) VLAN $vlan"
        $already = Test-OobeStatic $nic $ip $mask $gateway $dns $vlan
        $holders = @($read.Adapters | Where-Object { $_.Mac -ne $macKey -and $_.Ip -eq $ip -and -not $_.EnableDhcp })
        if ($holders.Count) {
            $h = $holders[0]
            throw "${name}: the adapter $($h.Name) ($(Format-ZtpMac $h.Mac)) in the maintenance environment already holds the target static address $ip. ZTP doesn't release another port's address (that request shape isn't verified live), so nothing was changed. Free the address on that port, or correct ip_address or mac_address in the environment file, then rerun the Device stage."
        }
        Write-ZtpLog "${name}: maintenance environment at ${maintenance}: management port $($nic.Name) ($(Format-ZtpMac $macKey)) reports $(Format-OobeAdapter $nic); wanted $wanted."

        $adapters = [System.Collections.Generic.List[object]]::new()
        $adapters.Add([ordered]@{ MacAddress = $nic.RawMac; EnableDhcp = $false; IpAddress = $ip; SubnetMask = $mask; Gateway = $gateway; DnsAddressArray = @($dns); VlanId = $(if ($nic.VlanIsText) { [string]$vlan } else { $vlan }) })
        # The request shape verified live (2026-11-07): Network.NetworkAdapters only; the claim sets the host name.
        $request = [ordered]@{ Network = [ordered]@{ NetworkAdapters = @($adapters) } }

        if (-not $Execute) {
            if ($already) { "PLAN: ${name}: $($nic.Name) ($(Format-ZtpMac $macKey)) already reports $wanted in the maintenance environment; no change." }
            else {
                "PLAN: ${name}: POST SetArcBootstrapDeviceConfiguration to ${maintenance}: $($nic.Name) ($(Format-ZtpMac $macKey)) $wanted (reports $(Format-OobeAdapter $nic) now); then wait up to $TimeoutMinutes minutes for the adapter to report it."
            }
            $row.Status = if ($already) { 'AlreadySet' } else { 'Planned' }
            [pscustomobject]$row; continue
        }
        if ($already) {
            Write-ZtpLog "${name}: $($nic.Name) already reports $wanted; nothing to change."
            Send-DeviceEvent $name 'DeviceAddressAlreadySet' "$($nic.Name) ($(Format-ZtpMac $macKey)) already reports $wanted"
            $row.Status = 'AlreadySet'; $row.Address = $ip; [pscustomobject]$row; continue
        }
        if (-not $PSCmdlet.ShouldProcess("maintenance environment of $name ($maintenance)", "Set $wanted on $($nic.Name)")) { continue }

        $null = Invoke-OobeCall $maintenance 'SetArcBootstrapDeviceConfiguration' 'POST' $request
        Write-ZtpLog "${name}: SetArcBootstrapDeviceConfiguration sent: $($nic.Name) $wanted."
        Write-DeviceChange $name $maintenance $nic $request 'requested' ''
        Send-DeviceEvent $name 'DeviceConfigurationSubmitted' "$($nic.Name) ($(Format-ZtpMac $macKey)) $wanted"

        # When the management port carries the maintenance address, the service comes back on the static one.
        $addresses = @($maintenance) + @(if ($ip -ne $maintenance) { $ip })
        $deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
        $last = ''
        $done = $false
        while (-not $done) {
            # Only an address whose adapters include the management MAC is this node: the old lease may have gone to another
            # device, and the status carries no MAC, so it is read from the verified address only.
            $verified = Get-OobeAdapter $addresses $macKey
            $status = [pscustomobject]@{ Text = "not answering or not this node ($($verified.Error))"; Failed = $false }
            $now = $verified
            if ($verified.Address) {
                try { $status = Get-OobeStatus (Invoke-OobeCall $verified.Address 'GetArcBootstrapDeviceConfigurationStatus') } catch { $status = [pscustomobject]@{ Text = "not answering ($($_.Exception.Message))"; Failed = $false } }
                # Read the adapters again after the status (the change shows in this read), still from the verified address and MAC.
                $now = Get-OobeAdapter @($verified.Address) $macKey
            }
            $mine = @($now.Adapters | Where-Object { $_.Mac -eq $macKey }) | Select-Object -First 1
            $text = "status: $($status.Text); $(if ($mine) { "$($mine.Name) reports $(Format-OobeAdapter $mine)" } else { 'adapters not readable' })"
            if ($text -ne $last) {
                Write-ZtpLog "${name}: $text"
                Send-DeviceEvent $name 'DeviceConfigurationStatus' $text
                $last = $text
            }
            if ($status.Failed) {
                Write-DeviceChange $name $maintenance $nic $request 'failed' $status.Text
                throw "${name}: SetArcBootstrapDeviceConfiguration failed: $($status.Text)"
            }
            if ($mine -and (Test-OobeStatic $mine $ip $mask $gateway $dns $vlan) -and -not @($now.Adapters | Where-Object { $_.Mac -ne $macKey -and $_.Ip -eq $ip -and -not $_.EnableDhcp }).Count) { $done = $true; break }
            if ([datetime]::UtcNow -ge $deadline) {
                Write-DeviceChange $name $maintenance $nic $request 'timedOut' $status.Text
                throw "${name}: the maintenance environment didn't report $wanted on $($nic.Name) within $TimeoutMinutes minutes; last: $text."
            }
            Start-Sleep -Seconds $PollIntervalSeconds
        }
        Write-DeviceChange $name $maintenance $nic $request 'applied' $status.Text
        Write-ZtpLog "${name}: $($nic.Name) reports $wanted in the maintenance environment."
        Send-DeviceEvent $name 'DeviceAddressSet' "$($nic.Name) ($(Format-ZtpMac $macKey)) $wanted"
        $row.Status = 'Changed'; $row.Address = $ip; $row.Released = @()
        [pscustomobject]$row
    }
    catch {
        Write-Warning "$($_.Exception.Message)"
        $failed.Add($_.Exception.Message)
        Send-DeviceEvent $name 'DeviceConfigurationFailed' $_.Exception.Message 'Error' 'Fix the cause and rerun the Device stage (-From Device); a port already right is left alone.'
    }
}
if ($failed.Count -gt 0) { throw "Device: $($failed -join ' ')" }
