#Requires -Version 7.0
<#
.SYNOPSIS
Sets each node's static management address on the port with its management MAC, and its host name, in the maintenance
environment, before the Azure claim. The Device stage, between Vouchers and Azure.
.DESCRIPTION
The maintenance environment runs the Configurator App's REST service (BootstrapOobeService, CoreWCF WebHttp, JSON,
Basic auth) at https://<maintenance address>:20001/BootstrapOobeService/<Operation>. This script uses it the way the
Configurator App does, so the address is on the right port before the OS install instead of on the first ready port.
Per node:
1. GET GetNetworkAdapters (verified live: HTTP 200, { NetworkAdapters: [ { MacAddress, Name, EnableDhcp, IpAddress,
   Gateway, SubnetMask, DnsAddressArray, VlanId, ... } ] }, MACs as 12 lower-case hex digits) and finds the adapter with
   the management MAC of the parameters file (separators and case don't matter). No match stops the node, listing the
   MACs found.
2. static: an adapter that already reports EnableDhcp false with the address, mask, gateway, DNS and VLAN is left
   alone. Otherwise POST SetArcBootstrapDeviceConfiguration with { HostName, Network: { NetworkAdapters: [ { MacAddress,
   EnableDhcp false, IpAddress, SubnetMask, Gateway, DnsAddressArray, VlanId } ] } }; another adapter that holds the
   address statically gets an entry { MacAddress, EnableDhcp true } in the same request. The request body follows the
   service's data contract; it isn't proven live yet.
3. Polls GET GetArcBootstrapDeviceConfigurationStatus (response shape not verified live: a property named Status, State,
   ConfigurationStatus or DeploymentStatus that reads Failed stops the node) and GET GetNetworkAdapters until the
   management adapter reports the static configuration, or -TimeoutMinutes passes. When the management port is the one
   the maintenance address is on, the service answers on the new address afterwards, so both are tried.
dhcp, dhcp_reservation and preconfigured nodes are only reported. A node without a maintenance address in the node list
(maintenance_address) is skipped: the Network stage after the OS install sets the address through Azure instead.
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
maintenance environment has on its provisioning port (the address its console shows; give it a DHCP reservation).
.PARAMETER Node
Nodes to handle (default: every node in the parameters file).
.PARAMETER EdgeUserPassword
The edgeuser password of the maintenance environment. Without it, Password1.
.PARAMETER Port
The REST service port.
.PARAMETER TimeoutMinutes
How long to wait for the configuration to show on the management adapter. 0 checks once.
.PARAMETER PollIntervalSeconds
How often to read the status and the adapters while waiting.
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
function Get-OobeAdapter([string[]]$Addresses) {
    # The adapters, from the first address that answers: @{ Address; Adapters } or $null with the last error in Error.
    $lastError = ''
    foreach ($address in $Addresses) {
        try { return [pscustomobject]@{ Address = $address; Adapters = @(ConvertTo-OobeAdapter (Invoke-OobeCall $address 'GetNetworkAdapters')); Error = '' } }
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
    # GetArcBootstrapDeviceConfigurationStatus: the response shape isn't verified live, so read any status-like property.
    if ($null -eq $Response) { return [pscustomobject]@{ Text = 'no status'; Failed = $false } }
    if ($Response -is [string]) { return [pscustomobject]@{ Text = $Response; Failed = ($Response -match 'Fail') } }
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

# ------------------------------------------------------------------ per node
$failed = [System.Collections.Generic.List[string]]::new()
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
        if (-not $maintenance) {
            $why = "${name}: no maintenance_address in the node list, so the maintenance environment can't be reached; the Network stage sets the address after the OS install."
            Write-ZtpLog $why -Level Warning
            if (-not $Execute) { "PLAN: $why" }
            Send-DeviceEvent $name 'DeviceConfigurationSkipped' $why 'Warning'
            $row.Status = 'Skipped'; [pscustomobject]$row; continue
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
        Write-ZtpLog "${name}: maintenance environment at ${maintenance}: management port $($nic.Name) ($(Format-ZtpMac $macKey)) reports $(Format-OobeAdapter $nic); wanted $wanted."

        $adapters = [System.Collections.Generic.List[object]]::new()
        $adapters.Add([ordered]@{ MacAddress = $nic.RawMac; EnableDhcp = $false; IpAddress = $ip; SubnetMask = $mask; Gateway = $gateway; DnsAddressArray = @($dns); VlanId = $(if ($nic.VlanIsText) { [string]$vlan } else { $vlan }) })
        foreach ($h in $holders) { $adapters.Add([ordered]@{ MacAddress = $h.RawMac; EnableDhcp = $true }) }
        $request = [ordered]@{ HostName = $name; Network = [ordered]@{ NetworkAdapters = @($adapters) } }

        if (-not $Execute) {
            if ($already -and $holders.Count -eq 0) { "PLAN: ${name}: $($nic.Name) ($(Format-ZtpMac $macKey)) already reports $wanted in the maintenance environment; no change." }
            else {
                foreach ($h in $holders) { "PLAN: ${name}: $($h.Name) ($(Format-ZtpMac $h.Mac)) holds $ip; the same request puts it on DHCP." }
                "PLAN: ${name}: POST SetArcBootstrapDeviceConfiguration to ${maintenance}: host name $name, $($nic.Name) ($(Format-ZtpMac $macKey)) $wanted (reports $(Format-OobeAdapter $nic) now); then wait up to $TimeoutMinutes minutes for the adapter to report it."
            }
            $row.Status = if ($already -and $holders.Count -eq 0) { 'AlreadySet' } else { 'Planned' }
            [pscustomobject]$row; continue
        }
        if ($already -and $holders.Count -eq 0) {
            Write-ZtpLog "${name}: $($nic.Name) already reports $wanted; nothing to change."
            Send-DeviceEvent $name 'DeviceAddressAlreadySet' "$($nic.Name) ($(Format-ZtpMac $macKey)) already reports $wanted"
            $row.Status = 'AlreadySet'; $row.Address = $ip; [pscustomobject]$row; continue
        }
        if (-not $PSCmdlet.ShouldProcess("maintenance environment of $name ($maintenance)", "Set $wanted on $($nic.Name) and host name $name")) { continue }

        $null = Invoke-OobeCall $maintenance 'SetArcBootstrapDeviceConfiguration' 'POST' $request
        Write-ZtpLog "${name}: SetArcBootstrapDeviceConfiguration sent: host name $name, $($nic.Name) $wanted$(if ($holders) { "; DHCP on $(@($holders | ForEach-Object Name) -join ', ')" })."
        Write-DeviceChange $name $maintenance $nic $request 'requested' ''
        Send-DeviceEvent $name 'DeviceConfigurationSubmitted' "$($nic.Name) ($(Format-ZtpMac $macKey)) $wanted, host name $name"

        # When the management port carries the maintenance address, the service comes back on the static one.
        $addresses = @($maintenance) + @(if ($ip -ne $maintenance) { $ip })
        $deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
        $last = ''
        $done = $false
        while (-not $done) {
            $status = $null
            foreach ($address in $addresses) {
                try { $status = Get-OobeStatus (Invoke-OobeCall $address 'GetArcBootstrapDeviceConfigurationStatus'); break } catch { $status = [pscustomobject]@{ Text = "not answering ($($_.Exception.Message))"; Failed = $false } }
            }
            $now = Get-OobeAdapter $addresses
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
        Send-DeviceEvent $name 'DeviceAddressSet' "$($nic.Name) ($(Format-ZtpMac $macKey)) $wanted, host name $name$(if ($holders) { "; DHCP on $(@($holders | ForEach-Object Name) -join ', ')" })"
        $row.Status = 'Changed'; $row.Address = $ip; $row.Released = @($holders | ForEach-Object Name)
        [pscustomobject]$row
    }
    catch {
        Write-Warning "$($_.Exception.Message)"
        $failed.Add($_.Exception.Message)
        Send-DeviceEvent $name 'DeviceConfigurationFailed' $_.Exception.Message 'Error' 'Fix the cause and rerun the Device stage (-From Device); a port already right is left alone.'
    }
}
if ($failed.Count -gt 0) { throw "Device: $($failed -join ' ')" }
