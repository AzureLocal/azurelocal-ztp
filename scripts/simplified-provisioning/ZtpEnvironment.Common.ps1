#Requires -Version 7.0
<#
.SYNOPSIS
Shared helpers for the environment file (dot-sourced by Invoke-ZtpEnvironment.ps1).
.DESCRIPTION
Reads the environment file (YAML), checks the keys Invoke-ZtpEnvironment.ps1 uses so a bad file fails before anything runs
and every problem is named at once, and resolves which nodes a run covers. Nothing here talks to Azure or to a node.

The keys Invoke-ZtpEnvironment.ps1 reads:
    cluster_nodes[].name, .ip_address, .mac_address (the management port), .service_tag, .idrac_ip
    cluster_nodes[].adapter_name, .arc_machine_name   (optional; the Arc name defaults to the node name)
    cluster_nodes[].maintenance_address               (optional; where the Device stage reaches the maintenance environment)
    azure_identity.azure_tenant_id
    network_intents.management.subnet, .gateway, .dns_servers
    network_intents.management.ip_assignment, .vlan_id   (optional; static, dhcp_reservation, dhcp or preconfigured;
                                                          default static)
    network_intents.management.static_method             (optional; device (default) or site; who sets a static
                                                          address: the Device stage by MAC, with the site Automatic and
                                                          no Manual adapter in the claim, or Microsoft's OS install from
                                                          the site's Manual setting and the claim)
    network_intents.management.site_ip_range.start, .end (optional; the site's Manual range with static_method site;
                                                          default the nodes' range)
    network_intents.management.provisioning_dhcp_range.start, .end (optional; where the Device stage scans for the
                                                          maintenance environment of a node without maintenance_address;
                                                          default the management subnet)
    network_intents.management.provisioning_network      (optional; dhcp or static; how the maintenance environment
                                                          reaches Azure: dhcp, DHCP on the management network
                                                          (Mode A or B); static, none there (Mode C: another port
                                                          with role provisioning must have DHCP))
    hardware.bios, cluster_nodes[].bios                  (optional; BIOS attribute -> string value: the machine's final
                                                          state, set by the Boot stage)
    hardware.bios_during_provisioning, cluster_nodes[].bios_during_provisioning (optional; temporary values for the
                                                          install only: Boot applies them over hardware.bios, Restore sets
                                                          each back to hardware.bios or the value saved before Boot)
    hardware.vendor                                       (picks config/oem/<vendor>.json)
    azure_resources.location
    site.name
    ztp.subscription_id, .resource_group
    ztp.site_name, .time_zone, .provisioning_iso, .os_version, .share_name
    ztp.share_host or ztp.share_host_adapter
    ztp.admin_secret.subscription_id, .resource_group, .vault, .name, .username
    ztp.bmc_secret.vault, .username_name, .password_name
    ztp.maintenance_password_secret (optional keyvault://<vault>/<secret>)
    ztp.tags (optional mapping), ztp.azl_rp_object_id (optional GUID)
    ztp.media_path      downloads, images, vouchers and run state  (default %ProgramData%\AzureLocalZtp\<site_name>\media)
    ztp.evidence_path   the event log, change logs and run logs    (default %ProgramData%\AzureLocalZtp\<site_name>\evidence)
    Neither may be inside a git working tree: Resolve-ZtpDataPath refuses one, and creates the folder.
ZTP ends at the Handoff, so it reads nothing for OS configuration: ztp.node_preparation and hardware.sbe (the SBE),
credentials.local_admin_* and identity.local_admin (the deployment admin), onprem.ntp_servers and the other ports'
settings may stay in a file and are ignored (Get-ZtpEnvironmentNote names the SBE ones).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-ZtpEnvironmentFile {
    <#
    .SYNOPSIS
    Parses the environment file into an ordered dictionary, or throws one clear message.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Environment file '$Path' doesn't exist." }
    $full = (Resolve-Path -LiteralPath $Path).Path
    $text = [IO.File]::ReadAllText($full)
    if ([string]::IsNullOrWhiteSpace($text)) { throw "Environment file '$full' is empty." }
    try { $parsed = ConvertFrom-Yaml $text -Ordered }
    catch { throw "Environment file '$full' isn't valid YAML: $($_.Exception.Message)" }
    if ($parsed -isnot [System.Collections.IDictionary]) { throw "Environment file '$full' must be a YAML mapping of keys at the top level." }
    return $parsed
}

function Get-ZtpEnvValue {
    # StrictMode-safe dotted read from the parsed environment ('ztp.admin_secret.vault'); a missing key gives $null.
    [CmdletBinding()]
    param([AllowNull()][object]$Environment, [Parameter(Mandatory)][string]$Path)
    $current = $Environment
    foreach ($part in $Path.Split('.')) {
        if ($current -is [System.Collections.IDictionary] -and $current.Contains($part)) { $current = $current[$part] }
        else { return $null }
    }
    return , $current
}

function Test-ZtpEnvironment {
    <#
    .SYNOPSIS
    Returns every problem found in the parsed environment file as a string; no output means it is valid. Checks every
    key Invoke-ZtpEnvironment.ps1 reads, and nothing else.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Environment)
    $problems = [System.Collections.Generic.List[string]]::new()
    $isText = { param($v) $null -ne $v -and $v -isnot [System.Collections.IDictionary] -and $v -isnot [System.Collections.IList] -and -not [string]::IsNullOrWhiteSpace([string]$v) }
    $isIp = { param($v) $ip = [ipaddress]::None; $v -is [string] -and $v -match '^\d{1,3}(\.\d{1,3}){3}$' -and [ipaddress]::TryParse($v, [ref]$ip) }
    $isGuid = { param($v) $guid = [guid]::Empty; $null -ne $v -and [guid]::TryParse([string]$v, [ref]$guid) }
    # Kind: text | guid | ip | cidr | mac | textlist | iplist
    $check = {
        param([object]$Root, [string]$Path, [string]$Label, [string]$Kind, [switch]$Optional)
        $v = Get-ZtpEnvValue -Environment $Root -Path $Path
        if ($null -eq $v -or ($v -is [string] -and -not $v.Trim())) {
            if (-not $Optional) { $problems.Add("$Label is required.") }
            return
        }
        switch ($Kind) {
            'text' { if (-not (& $isText $v)) { $problems.Add("$Label must be a single value.") } }
            'guid' { if (-not (& $isGuid $v)) { $problems.Add("$Label must be a GUID.") } }
            'ip' { if (-not (& $isIp ([string]$v))) { $problems.Add("$Label must be an IPv4 address, not '$v'.") } }
            'cidr' {
                $parts = ([string]$v) -split '/'
                $prefix = 0
                if ($parts.Count -ne 2 -or -not (& $isIp $parts[0]) -or -not [int]::TryParse($parts[1], [ref]$prefix) -or [int]$parts[1] -lt 1 -or [int]$parts[1] -gt 32) {
                    $problems.Add("$Label must be an IPv4 subnet such as 192.0.2.0/24, not '$v'.")
                }
            }
            'mac' { if (([string]$v) -notmatch '^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$') { $problems.Add("$Label must be a MAC address such as AA:BB:CC:DD:EE:FF, not '$v'.") } }
            'textlist' {
                $items = @($v)
                if ($v -isnot [System.Collections.IList] -or $items.Count -eq 0 -or @($items | Where-Object { -not (& $isText $_) }).Count) { $problems.Add("$Label must be a non-empty list of values.") }
            }
            'iplist' {
                $items = @($v)
                if ($v -isnot [System.Collections.IList] -or $items.Count -eq 0) { $problems.Add("$Label must be a non-empty list of IPv4 addresses.") }
                else { foreach ($i in $items) { if (-not (& $isIp ([string]$i))) { $problems.Add("$Label has '$i', which isn't an IPv4 address.") } } }
            }
        }
    }

    # BIOS attributes: a mapping of attribute names to string values (quote numbers and words YAML reads as booleans).
    $checkBios = {
        param([object]$Bios, [string]$Label)
        if ($null -eq $Bios) { return }
        if ($Bios -isnot [System.Collections.IDictionary]) { $problems.Add("$Label must be a mapping of BIOS attribute names to values."); return }
        foreach ($k in $Bios.Keys) {
            if ([string]$k -notmatch '^[A-Za-z0-9_.\[\]-]{1,128}$') { $problems.Add("$Label has '$k', which isn't a BIOS attribute name.") }
            if ($Bios[$k] -isnot [string]) { $problems.Add("$Label.$k must be a string; quote it ('$($Bios[$k])').") }
        }
    }
    & $checkBios (Get-ZtpEnvValue -Environment $Environment -Path 'hardware.bios') 'hardware.bios'
    & $checkBios (Get-ZtpEnvValue -Environment $Environment -Path 'hardware.bios_during_provisioning') 'hardware.bios_during_provisioning'

    $nodes = Get-ZtpEnvValue -Environment $Environment -Path 'cluster_nodes'
    if ($nodes -isnot [System.Collections.IList] -or @($nodes).Count -eq 0) { $problems.Add('cluster_nodes is required: a list with one entry per node.') }
    else {
        $seen = @{}
        $index = 0
        foreach ($n in @($nodes)) {
            $name = [string](Get-ZtpEnvValue -Environment $n -Path 'name')
            $label = if ($name) { "cluster_nodes[$index] ($name)" } else { "cluster_nodes[$index]" }
            if ($n -isnot [System.Collections.IDictionary]) { $problems.Add("$label must be a mapping with name, ip_address and mac_address."); $index++; continue }
            & $check $n 'name' "$label.name" 'text'
            if ($name) { if ($seen.ContainsKey($name.ToLowerInvariant())) { $problems.Add("$label.name '$name' is used twice.") } else { $seen[$name.ToLowerInvariant()] = $true } }
            # A static address needs ip_address; Mode A (dhcp_reservation), dhcp and preconfigured can go without (nothing to compare).
            & $check $n 'ip_address' "$label.ip_address" 'ip' -Optional:((Get-ZtpManagementAssignment -Environment $Environment -Node $n) -ne 'static')
            & $check $n 'mac_address' "$label.mac_address" 'mac'
            & $check $n 'adapter_name' "$label.adapter_name" 'text' -Optional
            & $check $n 'arc_machine_name' "$label.arc_machine_name" 'text' -Optional
            $arcName = [string](Get-ZtpEnvValue -Environment $n -Path 'arc_machine_name')
            # Microsoft.HybridCompute/machines name rule: 1-54 characters, letters, digits, '-', '_' and '.', not ending in '.'.
            if ($arcName -and ($arcName -notmatch '^[A-Za-z0-9_.-]{1,54}$' -or $arcName.EndsWith('.'))) { $problems.Add("$label.arc_machine_name '$arcName' isn't a valid Arc machine name (1-54 letters, digits, '-', '_', '.').") }
            & $check $n 'service_tag' "$label.service_tag" 'text'
            & $check $n 'idrac_ip' "$label.idrac_ip" 'ip'
            # Where the Device stage reaches the maintenance environment's REST service (without it, the stage scans for it).
            & $check $n 'maintenance_address' "$label.maintenance_address" 'ip' -Optional
            & $checkBios (Get-ZtpEnvValue -Environment $n -Path 'bios') "$label.bios"
            & $checkBios (Get-ZtpEnvValue -Environment $n -Path 'bios_during_provisioning') "$label.bios_during_provisioning"
            $nodeMode = Get-ZtpEnvValue -Environment $n -Path 'ip_assignment'
            if ($null -ne $nodeMode -and [string]$nodeMode -notin 'static', 'dhcp_reservation', 'dhcp', 'preconfigured') { $problems.Add("$label.ip_assignment must be static, dhcp_reservation, dhcp or preconfigured, not '$nodeMode'.") }
            $index++
        }
    }

    & $check $Environment 'azure_identity.azure_tenant_id' 'azure_identity.azure_tenant_id' 'guid'
    & $check $Environment 'network_intents.management.subnet' 'network_intents.management.subnet' 'cidr'
    & $check $Environment 'network_intents.management.gateway' 'network_intents.management.gateway' 'ip'
    & $check $Environment 'network_intents.management.dns_servers' 'network_intents.management.dns_servers' 'iplist'
    $mode = Get-ZtpEnvValue -Environment $Environment -Path 'network_intents.management.ip_assignment'
    if ($null -ne $mode -and [string]$mode -notin 'static', 'dhcp_reservation', 'dhcp', 'preconfigured') { $problems.Add("network_intents.management.ip_assignment must be static, dhcp_reservation, dhcp or preconfigured, not '$mode'.") }
    $vlan = Get-ZtpEnvValue -Environment $Environment -Path 'network_intents.management.vlan_id'
    $vlanNumber = 0
    if ($null -ne $vlan -and (-not [int]::TryParse([string]$vlan, [ref]$vlanNumber) -or $vlanNumber -lt 0 -or $vlanNumber -gt 4094)) { $problems.Add("network_intents.management.vlan_id must be 0-4094, not '$vlan'.") }
    # The site's network setting: with static addresses, a Manual range that holds every node's address.
    $subnetText = [string](Get-ZtpEnvValue -Environment $Environment -Path 'network_intents.management.subnet')
    $subnetOk = $subnetText -match '^\d{1,3}(\.\d{1,3}){3}/([1-9]|[12]\d|3[0-2])$' -and (& $isIp ($subnetText -split '/')[0])
    $range = Get-ZtpEnvValue -Environment $Environment -Path 'network_intents.management.site_ip_range'
    $rangeOk = $false
    if ($null -ne $range) {
        if ($range -isnot [System.Collections.IDictionary]) { $problems.Add('network_intents.management.site_ip_range must be a mapping with start and end.') }
        else {
            & $check $range 'start' 'network_intents.management.site_ip_range.start' 'ip'
            & $check $range 'end' 'network_intents.management.site_ip_range.end' 'ip'
            if ((& $isIp ([string]$range['start'])) -and (& $isIp ([string]$range['end']))) {
                if ((ConvertTo-ZtpIpNumber $range['start']) -gt (ConvertTo-ZtpIpNumber $range['end'])) { $problems.Add("network_intents.management.site_ip_range starts at $($range['start']), after its end $($range['end']).") }
                elseif ($subnetOk -and -not ((Test-ZtpAddressInSubnet $range['start'] $subnetText) -and (Test-ZtpAddressInSubnet $range['end'] $subnetText))) { $problems.Add("network_intents.management.site_ip_range $($range['start'])-$($range['end']) isn't inside network_intents.management.subnet $subnetText.") }
                else { $rangeOk = $true }
            }
        }
    }
    $nodeValue = Get-ZtpEnvValue -Environment $Environment -Path 'cluster_nodes'
    $nodeList = @(@($nodeValue) | Where-Object { $_ -is [System.Collections.IDictionary] })
    $i = 0
    foreach ($n in $nodeList) {
        if ((Get-ZtpManagementAssignment -Environment $Environment -Node $n) -eq 'static') {
            $ip = [string]$n['ip_address']
            if (& $isIp $ip) {
                if ($subnetOk -and -not (Test-ZtpAddressInSubnet $ip $subnetText)) { $problems.Add("cluster_nodes[$i] ($($n['name'])).ip_address $ip isn't in network_intents.management.subnet $subnetText.") }
                elseif ($rangeOk -and (Get-ZtpStaticMethod -Environment $Environment) -eq 'site' -and ((ConvertTo-ZtpIpNumber $ip) -lt (ConvertTo-ZtpIpNumber $range['start']) -or (ConvertTo-ZtpIpNumber $ip) -gt (ConvertTo-ZtpIpNumber $range['end']))) {
                    $problems.Add("cluster_nodes[$i] ($($n['name'])).ip_address $ip is outside network_intents.management.site_ip_range $($range['start'])-$($range['end']); with ip_assignment static every node address is in the site range.")
                }
            }
        }
        $i++
    }
    $provisioning = Get-ZtpEnvValue -Environment $Environment -Path 'network_intents.management.provisioning_network'
    if ($null -ne $provisioning -and [string]$provisioning -notin 'dhcp', 'static') { $problems.Add("network_intents.management.provisioning_network must be dhcp or static, not '$provisioning'.") }
    # Who sets a static management address: the Device stage by MAC (device, the default), or Microsoft's OS install from
    # the site's Manual setting and the claim's Manual adapter (site, for environments without the Device stage).
    $method = Get-ZtpEnvValue -Environment $Environment -Path 'network_intents.management.static_method'
    if ($null -ne $method -and "$method" -ne '' -and ([string]$method).ToLowerInvariant() -notin 'device', 'site') { $problems.Add("network_intents.management.static_method must be device or site, not '$method'.") }
    # Where the Device stage scans for a maintenance environment it has no address for (the DHCP pool of the provisioning network).
    $scan = Get-ZtpEnvValue -Environment $Environment -Path 'network_intents.management.provisioning_dhcp_range'
    if ($null -ne $scan) {
        if ($scan -isnot [System.Collections.IDictionary]) { $problems.Add('network_intents.management.provisioning_dhcp_range must be a mapping with start and end.') }
        else {
            & $check $scan 'start' 'network_intents.management.provisioning_dhcp_range.start' 'ip'
            & $check $scan 'end' 'network_intents.management.provisioning_dhcp_range.end' 'ip'
            if ((& $isIp ([string]$scan['start'])) -and (& $isIp ([string]$scan['end']))) {
                $size = (ConvertTo-ZtpIpNumber $scan['end']) - (ConvertTo-ZtpIpNumber $scan['start'])
                if ($size -lt 0) { $problems.Add("network_intents.management.provisioning_dhcp_range starts at $($scan['start']), after its end $($scan['end']).") }
                elseif ($size -ge 4096) { $problems.Add("network_intents.management.provisioning_dhcp_range $($scan['start'])-$($scan['end']) has more than 4096 addresses; narrow it to the DHCP pool.") }
            }
        }
    }
    # Static node addresses: unique, and not inside the provisioning DHCP pool (the pool would lease them to another device).
    $scanLow = $null; $scanHigh = $null
    if ($scan -is [System.Collections.IDictionary] -and (& $isIp ([string]$scan['start'])) -and (& $isIp ([string]$scan['end']))) { $scanLow = ConvertTo-ZtpIpNumber $scan['start']; $scanHigh = ConvertTo-ZtpIpNumber $scan['end'] }
    $seenIp = @{}
    $nodeIndex = 0
    foreach ($n in $nodeList) {
        if ((Get-ZtpManagementAssignment -Environment $Environment -Node $n) -eq 'static' -and (& $isIp ([string]$n['ip_address']))) {
            $ip = [string]$n['ip_address']
            if ($seenIp.ContainsKey($ip)) { $problems.Add("cluster_nodes[$nodeIndex] ($($n['name'])).ip_address $ip is also the address of $($seenIp[$ip]); every node needs its own.") } else { $seenIp[$ip] = "cluster_nodes[$nodeIndex] ($($n['name']))" }
            if ($null -ne $scanLow -and (ConvertTo-ZtpIpNumber $ip) -ge $scanLow -and (ConvertTo-ZtpIpNumber $ip) -le $scanHigh) {
                $problems.Add("cluster_nodes[$nodeIndex] ($($n['name'])).ip_address $ip is inside network_intents.management.provisioning_dhcp_range $($scan['start'])-$($scan['end']), where it could be leased to another device. Use an address outside the pool.")
            }
        }
        $nodeIndex++
    }
    & $check $Environment 'hardware.vendor' 'hardware.vendor' 'text'
    & $check $Environment 'ztp.subscription_id' 'ztp.subscription_id' 'guid'
    & $check $Environment 'ztp.resource_group' 'ztp.resource_group' 'text'
    & $check $Environment 'ztp.admin_secret.subscription_id' 'ztp.admin_secret.subscription_id' 'guid'
    foreach ($k in 'vault', 'name', 'username') { & $check $Environment "ztp.admin_secret.$k" "ztp.admin_secret.$k" 'text' }
    foreach ($k in 'media_path', 'evidence_path') {
        & $check $Environment "ztp.$k" "ztp.$k" 'text' -Optional
        $p = Get-ZtpEnvValue -Environment $Environment -Path "ztp.$k"
        if ($p -is [string] -and $p.Trim()) {
            if (-not [IO.Path]::IsPathFullyQualified($p)) { $problems.Add("ztp.$k must be a full path such as D:\Data\azl-ztp\site\$($k -replace '_path$'), not '$p'.") }
            else {
                $repo = Find-ZtpGitWorkTree -Path $p
                if ($repo) { $problems.Add("ztp.$k '$p' is inside the git working tree $repo; run data must stay out of repositories.") }
            }
        }
    }

    & $check $Environment 'azure_resources.location' 'azure_resources.location' 'text'
    & $check $Environment 'site.name' 'site.name' 'text'
    foreach ($k in 'site_name', 'time_zone', 'provisioning_iso', 'os_version', 'share_name') { & $check $Environment "ztp.$k" "ztp.$k" 'text' }
    $shareHost = Get-ZtpEnvValue -Environment $Environment -Path 'ztp.share_host'
    $shareAdapter = Get-ZtpEnvValue -Environment $Environment -Path 'ztp.share_host_adapter'
    if (-not $shareHost -and -not $shareAdapter) { $problems.Add('ztp.share_host or ztp.share_host_adapter is required: the address the BMCs reach this server on.') }
    elseif ($shareHost) { & $check $Environment 'ztp.share_host' 'ztp.share_host' 'ip' }
    & $check $Environment 'ztp.admin_secret.resource_group' 'ztp.admin_secret.resource_group' 'text'
    foreach ($k in 'vault', 'password_name') { & $check $Environment "ztp.bmc_secret.$k" "ztp.bmc_secret.$k" 'text' }
    # The BMC user name: a secret in the vault (username_name, optionally in username_vault), or the name itself (username).
    if (-not (Get-ZtpEnvValue -Environment $Environment -Path 'ztp.bmc_secret.username')) { & $check $Environment 'ztp.bmc_secret.username_name' 'ztp.bmc_secret.username_name' 'text' }
    & $check $Environment 'ztp.azl_rp_object_id' 'ztp.azl_rp_object_id' 'guid' -Optional
    $tags = Get-ZtpEnvValue -Environment $Environment -Path 'ztp.tags'
    if ($null -ne $tags -and $tags -isnot [System.Collections.IDictionary]) { $problems.Add('ztp.tags must be a mapping of tag names to values.') }
    # The maintenance environment's edgeuser password: preset in the image and used by the Device stage. Default Password1.
    $edge = Get-ZtpEnvValue -Environment $Environment -Path 'ztp.maintenance_password_secret'
    if ($null -ne $edge -and "$edge" -ne '' -and [string]$edge -notmatch '^keyvault://([^/]+)/(.+)$') { $problems.Add('ztp.maintenance_password_secret must be keyvault://<vault>/<secret>.') }
    return $problems.ToArray()
}

function Assert-ZtpEnvironment {
    <#
    .SYNOPSIS
    Throws one message naming every problem in the environment file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Environment,
        [string]$Source = 'The environment file'
    )
    $problems = @(Test-ZtpEnvironment -Environment $Environment)
    $warnings = @(Get-ZtpEnvironmentWarning -Environment $Environment)
    # A schema 5 file (Read-ZtpInfrastructure): its validator's findings first, then the key check in schema 5 paths.
    $origin = $Environment['_source']
    if ($origin -is [System.Collections.IDictionary] -and $origin['format'] -eq 'schema5') {
        $problems = @(@($origin['problems']) + @($problems | ForEach-Object { ConvertTo-ZtpSchema5Message -Message $_ }) | Where-Object { $_ } | Select-Object -Unique)
        $warnings = @(@($origin['warnings']) + @($warnings | ForEach-Object { ConvertTo-ZtpSchema5Message -Message $_ }) | Where-Object { $_ })
        $Source = "$Source (schema $($origin['schema_version']), checked by $($origin['validator']))"
    }
    if ($problems.Count) {
        throw "$Source is invalid ($($problems.Count) problem$(if ($problems.Count -ne 1) { 's' })):`n  - $($problems -join "`n  - ")"
    }
    foreach ($w in $warnings) { Write-Warning $w }
    foreach ($n in @(Get-ZtpEnvironmentNote -Environment $Environment)) { Write-Information -MessageData "Note: $n" -InformationAction Continue }
}

function Get-ZtpEnvironmentNote {
    <#
    .SYNOPSIS
    One line per setting a file carries that provisioning accepts and ignores, because a later phase owns it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Environment)
    $origin = $Environment['_source']
    $schema5 = $origin -is [System.Collections.IDictionary] -and $origin['format'] -eq 'schema5'
    # A schema 5 file: Read-ZtpInfrastructure records the keys it ignores in _source.ignored.
    if ($schema5) { foreach ($k in @($origin['ignored'])) { if ($k) { "$k ignored: SBE belongs to OS configuration." } }; return }
    $ztp = Get-ZtpEnvValue -Environment $Environment -Path 'ztp'
    if ($ztp -is [System.Collections.IDictionary] -and $ztp.Contains('node_preparation')) { 'ztp.node_preparation ignored: SBE belongs to OS configuration.' }
}

function Get-ZtpEnvironmentPort {
    <#
    .SYNOPSIS
    A node's ports from the file, one ordered dictionary each { name, mac_address, roles, ip_assignment, ip_address }:
    cluster_nodes[].network_adapters (mapped from a schema 5 file), else the one management port cluster_nodes[] describes
    (mac_address, adapter_name, ip_address). For the handoff's per-port detail. Nothing assumes a make or a slot: the
    management port is the one with role management.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Node, [System.Collections.IDictionary]$Environment)
    $listed = Get-ZtpEnvValue -Environment $Node -Path 'network_adapters'
    if ($listed) {
        foreach ($p in @($listed)) {
            if ($p -isnot [System.Collections.IDictionary]) { continue }
            [ordered]@{ name = [string]$p['name']; mac_address = [string]$p['mac_address']; roles = @(@($p['roles']) | Where-Object { $_ } | ForEach-Object { [string]$_ }); ip_assignment = [string]$p['ip_assignment']; ip_address = [string]$p['ip_address'] }
        }
        return
    }
    if (-not $Node['mac_address']) { return }
    $mode = if ($Environment) { Get-ZtpManagementAssignment -Environment $Environment -Node $Node } elseif ($Node['ip_assignment']) { [string]$Node['ip_assignment'] } else { 'static' }
    [ordered]@{ name = [string]$Node['adapter_name']; mac_address = [string]$Node['mac_address']; roles = @('management'); ip_assignment = $mode; ip_address = [string]$Node['ip_address'] }
}

function Test-ZtpProvisioningDhcpPort {
    # True when the node has a port with role provisioning, other than the management port, whose ip_assignment gives it
    # DHCP (dhcp or dhcp_reservation): the maintenance environment's way to Azure in Mode C (no DHCP on the management
    # network). Reads schema 5 network_adapters, raw or mapped (cluster_nodes[].network_adapters).
    param([System.Collections.IDictionary]$Node)
    if (-not $Node) { return $false }
    foreach ($p in @($Node['network_adapters'])) {
        if ($p -isnot [System.Collections.IDictionary]) { continue }
        $roles = @(@($p['roles']) | ForEach-Object { [string]$_ })
        if ('provisioning' -in $roles -and 'management' -notin $roles -and [string]$p['ip_assignment'] -in 'dhcp', 'dhcp_reservation') { return $true }
    }
    return $false
}

function Get-ZtpManagementDhcp {
    <#
    .SYNOPSIS
    Does the node's management port (role management, found by its MAC) take DHCP while the machine is provisioned? That
    tells Mode B (Static with DHCP) from Mode C (Static without management DHCP) for a static address. True when
    network_intents.management.provisioning_network is dhcp (the default) and the management port also has role
    provisioning, or the file lists no ports for the node (one management port, the maintenance environment's way to Azure).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Environment, [Parameter(Mandatory)][System.Collections.IDictionary]$Node)
    if ([string](Get-ZtpEnvValue -Environment $Environment -Path 'network_intents.management.provisioning_network') -eq 'static') { return $false }
    $ports = @(@($Node['network_adapters']) | Where-Object { $_ -is [System.Collections.IDictionary] })
    $owner = @($ports | Where-Object { 'management' -in @($_['roles']) -and [string]$_['ip_assignment'] -notin '', 'none' }) | Select-Object -First 1
    if (-not $owner) { return $true }
    return ('provisioning' -in @($owner['roles']))
}

function Test-ZtpV5ManagementReach {
    <#
    .SYNOPSIS
    Mode C without a way to Azure, in a schema 5 file: a static management port, no DHCP on the management network
    (networking.management.provisioning_network static), and no other port with role provisioning on DHCP. The
    maintenance environment then can't reach Azure (G23). The toolkit's AZL-024 is the same rule; this one runs only when
    the toolkit isn't there, so the run still stops before it touches the hardware.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data)
    if ([string](Get-ZtpEnvValue -Environment $Data -Path 'networking.management.provisioning_network') -ne 'static') { return }
    $i = 0
    $nodeValue = Get-ZtpEnvValue -Environment $Data -Path 'nodes'
    foreach ($n in @($nodeValue)) {
        if ($n -is [System.Collections.IDictionary]) {
            $port = Get-ZtpV5ManagementPort -Data $Data -Node $n
            if ($port.Count -eq 1 -and $port.Mode -eq 'static' -and -not (Test-ZtpProvisioningDhcpPort -Node $n)) {
                "nodes[$i] ($($n['name'])): Mode C (Static without management DHCP): the maintenance environment can't reach Azure: no DHCP anywhere (G23); give a provisioning port with DHCP (a port with role provisioning and ip_assignment dhcp or dhcp_reservation)."
            }
        }
        $i++
    }
}

function Get-ZtpEnvironmentWarning {
    <#
    .SYNOPSIS
    What in a valid environment file deserves a warning, one string each: settings ZTP accepts but doesn't act on.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Environment)
    # The toolkit warns about a schema 5 file itself (AZL-024), for the same reason.
    $origin = $Environment['_source']
    if ($origin -is [System.Collections.IDictionary] -and $origin['format'] -eq 'schema5' -and @($origin['warnings'] | Where-Object { $_ -like 'AZL-024 *' }).Count) { return }
    # Mode C: no DHCP on the management network, but every node has another port with role provisioning on DHCP, which the
    # maintenance environment reaches Azure through. Nothing to warn about.
    $nodeValue = Get-ZtpEnvValue -Environment $Environment -Path 'cluster_nodes'
    $nodes = @(@($nodeValue) | Where-Object { $_ -is [System.Collections.IDictionary] })
    if ($nodes.Count -and @($nodes | Where-Object { -not (Test-ZtpProvisioningDhcpPort -Node $_) }).Count -eq 0) { return }
    if ([string](Get-ZtpEnvValue -Environment $Environment -Path 'network_intents.management.provisioning_network') -eq 'static') {
        'network_intents.management.provisioning_network is static: the maintenance environment needs a static address to reach Azure before the machine is claimed. Learn documents only the Configurator app for that, and whether the USB image can carry a preset address is an open research item, so ZTP sets nothing for it. Without DHCP on a provisioning port, the machine never reaches Azure and no voucher is written.'
    }
}

function ConvertTo-ZtpIpNumber {
    # 192.0.2.1 -> its 32-bit value, for comparisons. Unsigned arithmetic only.
    param([Parameter(Mandatory)][string]$Address)
    $b = [ipaddress]::Parse($Address).GetAddressBytes()
    return [uint64]$b[0] * 16777216 + [uint64]$b[1] * 65536 + [uint64]$b[2] * 256 + [uint64]$b[3]
}

function Test-ZtpAddressInSubnet {
    # Is 192.0.2.11 inside 192.0.2.0/24?
    param([Parameter(Mandatory)][string]$Address, [Parameter(Mandatory)][string]$Subnet)
    $network, $bits = $Subnet -split '/'
    $size = [uint64]1 -shl (32 - [int]$bits)
    $start = (ConvertTo-ZtpIpNumber $network) - ((ConvertTo-ZtpIpNumber $network) % $size)
    $value = ConvertTo-ZtpIpNumber $Address
    return ($value -ge $start -and $value -lt $start + $size)
}

function Get-ZtpSiteNetwork {
    <#
    .SYNOPSIS
    The site's network setting for simplified provisioning (Microsoft.Edge/configurations/networkConfigurations), from
    the management mode.
    .DESCRIPTION
    static with static_method device (the default): Automatic. The Device stage sets the static address on the port with
    the management MAC before the claim, and the claim carries no Manual adapter: a Manual site makes Microsoft's OS
    install put the static address on the first ready port and ignore the MAC (seen live on a Dell AX-760: a ConnectX
    port), so with Automatic the only static is ZTP's. The Network stage checks it after the install.
    static with static_method site: Manual, with ipv4 { addressRange { startIp, endIp }, defaultGateway, dnsServers,
    subnetMask, vLanId }. The range is network_intents.management.site_ip_range, else the lowest to the highest node
    address. Each edge machine also gets a Manual adapter keyed by MAC in the claim. For environments without the Device
    stage; the Network stage moves the address to the right port after the install.
    dhcp: Automatic. preconfigured: Automatic too: ZTP doesn't manage the address, and the freshly installed OS takes DHCP
    until whatever preconfigures the port does so.
    .OUTPUTS
    IpAssignmentType (Manual or Automatic), Ipv4 (the object for the template's ipv4 parameter; empty for Automatic),
    Range (start-end text, or '').
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Environment)
    $nodeValue = Get-ZtpEnvValue -Environment $Environment -Path 'cluster_nodes'
    $static = @(@($nodeValue) | Where-Object { $_ -is [System.Collections.IDictionary] -and (Get-ZtpManagementAssignment -Environment $Environment -Node $_) -eq 'static' })
    if ($static.Count -eq 0 -or (Get-ZtpStaticMethod -Environment $Environment) -eq 'device') {
        return [pscustomobject]@{ IpAssignmentType = 'Automatic'; Ipv4 = [ordered]@{}; Range = '' }
    }
    $mgmt = Get-ZtpEnvValue -Environment $Environment -Path 'network_intents.management'
    $range = Get-ZtpEnvValue -Environment $Environment -Path 'network_intents.management.site_ip_range'
    if ($range -is [System.Collections.IDictionary] -and $range['start'] -and $range['end']) { $start = [string]$range['start']; $end = [string]$range['end'] }
    else {
        $addresses = @($static | ForEach-Object { [string]$_['ip_address'] } | Sort-Object { ConvertTo-ZtpIpNumber $_ })
        $start = $addresses[0]; $end = $addresses[-1]
    }
    $vlan = Get-ZtpEnvValue -Environment $Environment -Path 'network_intents.management.vlan_id'
    $ipv4 = [ordered]@{
        addressRange   = [ordered]@{ startIp = $start; endIp = $end }
        defaultGateway = [string]$mgmt['gateway']
        dnsServers     = @($mgmt['dns_servers'] | ForEach-Object { [string]$_ })
        subnetMask     = ConvertTo-ZtpSubnetMask -PrefixLength ([int](([string]$mgmt['subnet']) -split '/')[1])
        vLanId         = $(if ($null -ne $vlan -and "$vlan" -ne '') { [int]$vlan } else { 0 })
    }
    return [pscustomobject]@{ IpAssignmentType = 'Manual'; Ipv4 = $ipv4; Range = "$start-$end" }
}

function Get-ZtpStaticMethod {
    <#
    .SYNOPSIS
    Who sets a static management address: device (the default; the Device stage, by MAC, before the claim, with the site
    Automatic and no Manual adapter in the claim) or site (Microsoft's OS install, from the site's Manual setting and the
    claim's Manual adapter). network_intents.management.static_method.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Environment)
    $method = [string](Get-ZtpEnvValue -Environment $Environment -Path 'network_intents.management.static_method')
    if ($method) { return $method.ToLowerInvariant() }
    return 'device'
}

function Get-ZtpManagementAssignment {
    <#
    .SYNOPSIS
    How each node's management address is set: static (Mode B or C: the Device stage sets ip_address on the port with
    mac_address, OS configuration again after the install), dhcp_reservation (Mode A: stays DHCP, the DHCP server reserves
    ip_address for the MAC), dhcp (stays DHCP, no reservation) or preconfigured (ZTP doesn't
    change the port). Default static. With -Node, the node's own cluster_nodes[].ip_assignment wins (the schema 5 reader sets
    it from each node's management port).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Environment, [System.Collections.IDictionary]$Node)
    if ($Node) { $own = [string](Get-ZtpEnvValue -Environment $Node -Path 'ip_assignment'); if ($own) { return $own.ToLowerInvariant() } }
    $mode = [string](Get-ZtpEnvValue -Environment $Environment -Path 'network_intents.management.ip_assignment')
    if ($mode) { return $mode.ToLowerInvariant() }
    return 'static'
}

function Get-ZtpEnvironmentBios {
    <#
    .SYNOPSIS
    A node's BIOS attributes from the environment file: hardware.bios with cluster_nodes[].bios merged over it (the node
    wins). An ordered dictionary of strings; empty when neither is set.
    .PARAMETER Kind
    final (default): hardware.bios and cluster_nodes[].bios, the machine's final state. provisioning:
    hardware.bios_during_provisioning and cluster_nodes[].bios_during_provisioning, the temporary values for the install
    only (the Boot stage applies them over the final ones; the Restore stage undoes them). boot: what the Boot stage
    applies, final with provisioning merged over it.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Environment,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Node,
        [ValidateSet('final', 'provisioning', 'boot')][string]$Kind = 'final'
    )
    $keys = @(if ($Kind -ne 'provisioning') { 'bios' }) + @(if ($Kind -ne 'final') { 'bios_during_provisioning' })
    $sources = [System.Collections.Generic.List[object]]::new()
    foreach ($k in $keys) { $sources.Add((Get-ZtpEnvValue -Environment $Environment -Path "hardware.$k")); $sources.Add((Get-ZtpEnvValue -Environment $Node -Path $k)) }
    $merged = [ordered]@{}
    foreach ($source in $sources) {
        if ($source -is [System.Collections.IDictionary]) { foreach ($k in $source.Keys) { $merged[[string]$k] = [string]$source[$k] } }
    }
    return $merged
}

function Find-ZtpGitWorkTree {
    <#
    .SYNOPSIS
    The git working tree that holds a path (the nearest folder above it with a .git folder or file), or $null. The path
    doesn't have to exist yet.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $dir = [IO.Path]::GetFullPath($Path)
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { return $dir }
        $parent = [IO.Path]::GetDirectoryName($dir)
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Resolve-ZtpDataPath {
    <#
    .SYNOPSIS
    The folder for a run's media (downloads, images, vouchers, state) or evidence (event log, change logs, run logs), created
    when missing. Refuses a folder inside a git working tree: 4 GB images and one-time vouchers never belong in a repository.
    .DESCRIPTION
    Order: -Override (the script's -MediaPath or -EvidencePath), then ztp.media_path or ztp.evidence_path, then
    %ProgramData%\AzureLocalZtp\<ztp.site_name>\<media|evidence> (site 'default' when the file names none).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Environment,
        [Parameter(Mandatory)][ValidateSet('media', 'evidence')][string]$Kind,
        [string]$Override
    )
    $key = "ztp.$($Kind)_path"
    $parameter = if ($Kind -eq 'media') { '-MediaPath' } else { '-EvidencePath' }
    $from = if ($Override) { $parameter } else { $key }
    $path = if ($Override) { $Override } else { [string](Get-ZtpEnvValue -Environment $Environment -Path $key) }
    if (-not $path) {
        $root = if ($env:ProgramData) { $env:ProgramData } else { [Environment]::GetFolderPath('CommonApplicationData') }
        $site = [string](Get-ZtpEnvValue -Environment $Environment -Path 'ztp.site_name')
        if ($site -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,62}$') { $site = 'default' }
        $path = Join-Path $root "AzureLocalZtp\$site\$Kind"
        $from = 'the default'
    }
    $full = [IO.Path]::GetFullPath($path)
    $repo = Find-ZtpGitWorkTree -Path $full
    if ($repo) {
        throw "The $Kind folder $full (from $from) is inside the git working tree $repo. Run data doesn't belong in a repository: set $key, or $parameter, to a folder outside it."
    }
    New-Item -ItemType Directory -Force -Path $full | Out-Null
    return $full
}

function ConvertTo-ZtpSubnetMask {
    # 24 -> 255.255.255.0
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(0, 32)][int]$PrefixLength)
    # 4294967295, not 0xFFFFFFFF: PowerShell reads that literal as Int32 -1.
    $all = [uint64]4294967295
    $bits = if ($PrefixLength -eq 0) { [uint64]0 } else { ([uint64]($all -shl (32 - $PrefixLength))) -band $all }
    return (3, 2, 1, 0 | ForEach-Object { ($bits -shr (8 * $_)) -band 0xFF }) -join '.'
}

function Resolve-ZtpNodeSelection {
    <#
    .SYNOPSIS
    The node names a run covers: every node in the environment file, or the ones named (each must be in the file).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Environment, [string[]]$Node)
    $known = @(@($Environment['cluster_nodes']) | ForEach-Object { [string]$_['name'] })
    if (-not $Node) { return $known }
    foreach ($n in $Node) {
        if ($known -notcontains $n) { throw "Node $n isn't in the environment file. Nodes there: $($known -join ', ')." }
    }
    return @($Node | Select-Object -Unique)
}

# ======================================================================================================================
# Schema 5: the master infrastructure.yml (azurelocal-toolkit config/infrastructure). Read-ZtpInfrastructure detects the
# format, validates a schema 5 file (with the toolkit's AzlInfrastructure module when the toolkit sits next to this
# repository, otherwise with the built-in checks here) and maps it onto the keys above, so every script reads one shape.
# The mapping is in docs/infrastructure-schema-5.md.
# ======================================================================================================================

# A schema 5 port's ip_assignment as ZTP's management mode: dhcp_reservation (Mode A) and dhcp stay apart, so the Network
# stage and the handoff can tell a reservation from a lease that can change.
$script:ZtpPortMode = @{ static = 'static'; dhcp_reservation = 'dhcp_reservation'; dhcp = 'dhcp'; preconfigured = 'preconfigured' }

function Get-ZtpEnvironmentFormat {
    <#
    .SYNOPSIS
    schema5 for a master infrastructure.yml (it has _metadata.schema_version, or schema_version at the top), else legacy
    (the environment-file layout in docs/environment-file.md).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data)
    if ((Get-ZtpEnvValue -Environment $Data -Path '_metadata.schema_version') -or $Data.Contains('schema_version')) { return 'schema5' }
    return 'legacy'
}

function Find-ZtpToolkitModule {
    <#
    .SYNOPSIS
    The toolkit's AzlInfrastructure.psm1: under $env:AZL_TOOLKIT_ROOT when that is set (only there), else in an
    azurelocal-toolkit clone next to this repository. $null when there is none.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $relative = 'scripts\common\infrastructure\AzlInfrastructure.psm1'
    $root = if ($env:AZL_TOOLKIT_ROOT) { $env:AZL_TOOLKIT_ROOT } else { Join-Path $PSScriptRoot '..\..\..\azurelocal-toolkit' }
    $candidate = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}

function Get-ZtpV5ManagementPort {
    # The port that owns a schema 5 node's management address (nodes[].network_adapters, else nodes[].management), with the
    # VLAN the host tags. Count is how many ports claim it, so a caller can tell none from several.
    param([System.Collections.IDictionary]$Data, [System.Collections.IDictionary]$Node)
    $siteVlan = Get-ZtpEnvValue -Environment $Data -Path 'networking.management.vlan_id'
    $siteVlan = if ($null -ne $siteVlan -and "$siteVlan" -ne '') { [int]$siteVlan } else { 0 }
    if ($Node.Contains('network_adapters')) {
        $owners = @(@($Node['network_adapters']) | Where-Object { $_ -is [System.Collections.IDictionary] -and 'management' -in @($_['roles']) -and [string]$_['ip_assignment'] -in $script:ZtpPortMode.Keys })
        if ($owners.Count -ne 1) { return [pscustomobject]@{ Count = $owners.Count } }
        $o = $owners[0]
        $vlan = if ([string]$o['vlan_mode'] -eq 'access') { 0 } elseif ($null -ne $o['vlan_id']) { [int]$o['vlan_id'] } else { $siteVlan }
        return [pscustomobject]@{ Count = 1; Name = [string]$o['name']; Mac = [string]$o['mac_address']; Ip = [string]$o['ip_address']; Mode = $script:ZtpPortMode[[string]$o['ip_assignment']]; Vlan = $vlan; Listed = $true }
    }
    $m = $Node['management']
    if ($m -isnot [System.Collections.IDictionary]) { return [pscustomobject]@{ Count = 0 } }
    $site = [string](Get-ZtpEnvValue -Environment $Data -Path 'networking.management.ip_assignment')
    $mode = if ($site) { $site.ToLowerInvariant() } else { 'static' }
    return [pscustomobject]@{ Count = 1; Name = [string]$m['adapter_name']; Mac = [string]$m['mac_address']; Ip = [string]$m['ip_address']; Mode = $mode; Vlan = $siteVlan; Listed = $false }
}

function Split-ZtpKeyVaultReference([object]$Reference) {
    if ([string]$Reference -match '^keyvault://([^/]+)/(.+)$') { return [pscustomobject]@{ Vault = $Matches[1]; Secret = $Matches[2] } }
    return $null
}

function Test-ZtpInfrastructureV5 {
    <#
    .SYNOPSIS
    The problems in a schema 5 file that ZTP's own key check (run on the mapped keys) can't name: the format, the scenario,
    each node's management port, and the vaults and BMC login ZTP can use. Messages use schema 5 key paths.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data)
    $version = [string](Get-ZtpEnvValue -Environment $Data -Path '_metadata.schema_version')
    if (-not $version) { $version = [string]$Data['schema_version'] }
    if ($version -notmatch '^5\.\d+\.\d+$') { "_metadata.schema_version is '$version'; ZTP reads schema 5.x." }
    if ([string](Get-ZtpEnvValue -Environment $Data -Path 'scenario.os_install') -ne 'simplified') {
        "scenario.os_install is '$(Get-ZtpEnvValue -Environment $Data -Path 'scenario.os_install')'; ZTP provisions with simplified machine provisioning (os_install: simplified)."
    }
    $nodeValue = Get-ZtpEnvValue -Environment $Data -Path 'nodes'
    $i = 0
    foreach ($n in @($nodeValue)) {
        if ($n -is [System.Collections.IDictionary]) {
            $port = Get-ZtpV5ManagementPort -Data $Data -Node $n
            if ($port.Count -ne 1) { "nodes[$i] ($($n['name'])): $($port.Count) ports own the management address; exactly one port with role management has an ip_assignment other than none." }
            if ($n['bmc'] -is [System.Collections.IDictionary] -and $n['bmc'].Contains('password')) {
                $hw = Get-ZtpEnvValue -Environment $Data -Path 'hardware.bmc'
                if ($hw -isnot [System.Collections.IDictionary] -or [string]$hw['username'] -ne [string]$n['bmc']['username'] -or [string]$hw['password'] -ne [string]$n['bmc']['password']) {
                    "nodes[$i] ($($n['name'])).bmc has its own login; ZTP uses one BMC login for every node (hardware.bmc)."
                }
            }
        }
        $i++
    }
    $vaults = @{}
    $vaultList = Get-ZtpEnvValue -Environment $Data -Path 'key_vaults'
    foreach ($kv in @($vaultList)) { if ($kv -is [System.Collections.IDictionary] -and $kv['name']) { $vaults[[string]$kv['name']] = $kv } }
    $admin = Split-ZtpKeyVaultReference (Get-ZtpEnvValue -Environment $Data -Path 'provisioning.simplified.admin.password')
    if ($admin -and -not $vaults.ContainsKey($admin.Vault)) { "provisioning.simplified.admin.password names vault '$($admin.Vault)', which isn't in key_vaults (ZTP needs its subscription_id and resource_group)." }
    elseif ($admin) {
        $sub = [string]$vaults[$admin.Vault]['subscription_id']
        foreach ($ref in @(
                @{ Path = 'hardware.bmc.password'; Value = (Get-ZtpEnvValue -Environment $Data -Path 'hardware.bmc.password') }
                @{ Path = 'hardware.bmc.username'; Value = (Get-ZtpEnvValue -Environment $Data -Path 'hardware.bmc.username') }
                @{ Path = 'provisioning.simplified.maintenance_password'; Value = (Get-ZtpEnvValue -Environment $Data -Path 'provisioning.simplified.maintenance_password') })) {
            $r = Split-ZtpKeyVaultReference $ref.Value
            if (-not $r) { continue }
            if (-not $vaults.ContainsKey($r.Vault)) { "$($ref.Path) names vault '$($r.Vault)', which isn't in key_vaults." }
            elseif ([string]$vaults[$r.Vault]['subscription_id'] -ne $sub) { "$($ref.Path) is in vault '$($r.Vault)', in another subscription than the provisioning admin's vault '$($admin.Vault)'. ZTP reads its secrets in one subscription." }
        }
    }
    if (-not (Get-ZtpEnvValue -Environment $Data -Path 'hardware.bmc.password')) { 'hardware.bmc (username and password) is required: ZTP mounts the image and boots each node through its BMC.' }
}

function ConvertFrom-ZtpInfrastructureV5 {
    <#
    .SYNOPSIS
    Maps a schema 5 infrastructure.yml onto the environment-file keys the ZTP scripts read. Missing values stay missing,
    so the key check names them (in schema 5 paths, through Assert-ZtpEnvironment).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data)
    $v = { param($p) Get-ZtpEnvValue -Environment $Data -Path $p }
    $put = { param([System.Collections.IDictionary]$Into, [string]$Key, [object]$Value) if ($null -ne $Value -and "$Value" -ne '') { $Into[$Key] = $Value } }
    $simplified = & $v 'provisioning.simplified'
    if ($simplified -isnot [System.Collections.IDictionary]) { $simplified = [ordered]@{} }

    $nodes = [System.Collections.Generic.List[object]]::new()
    $modes = [System.Collections.Generic.List[string]]::new()
    $vlans = [System.Collections.Generic.List[int]]::new()
    $nodeValue = & $v 'nodes'
    foreach ($n in @($nodeValue)) {
        if ($n -isnot [System.Collections.IDictionary]) { $nodes.Add($n); continue }
        $port = Get-ZtpV5ManagementPort -Data $Data -Node $n
        $node = [ordered]@{}
        & $put $node 'name' $n['name']
        if ($port.Count -eq 1) {
            & $put $node 'ip_address' $port.Ip
            & $put $node 'mac_address' $port.Mac
            & $put $node 'adapter_name' $port.Name
            $node['ip_assignment'] = $port.Mode
            $modes.Add($port.Mode); $vlans.Add([int]$port.Vlan)
        }
        $arc = if ($n['arc_machine_name']) { $n['arc_machine_name'] } else { $n['arc_resource_name'] }
        & $put $node 'arc_machine_name' $arc
        & $put $node 'service_tag' $n['serial_number']
        if ($n['bmc'] -is [System.Collections.IDictionary]) { & $put $node 'idrac_ip' $n['bmc']['ip_address'] }
        # The maintenance environment's address (the Device stage): the ip_address of the node's port with role
        # provisioning that the file gives one (its DHCP reservation), when that port isn't the management port.
        $provisioning = @(@($n['network_adapters']) | Where-Object { $_ -is [System.Collections.IDictionary] -and 'provisioning' -in @($_['roles']) -and 'management' -notin @($_['roles']) -and $_['ip_address'] })
        if ($n['maintenance_address']) { & $put $node 'maintenance_address' ([string]$n['maintenance_address']) }
        elseif ($provisioning.Count -ge 1) { & $put $node 'maintenance_address' ([string]$provisioning[0]['ip_address']) }
        if ($n['rack_position']) { $node['rack_position'] = $n['rack_position'] }
        if ($n['bios'] -is [System.Collections.IDictionary]) { $node['bios'] = $n['bios'] }
        if ($n['bios_during_provisioning'] -is [System.Collections.IDictionary]) { $node['bios_during_provisioning'] = $n['bios_during_provisioning'] }
        # The node's ports, as the file lists them, for the handoff's per-port detail and the Mode C check. ZTP doesn't
        # set them up: DHCP and the gateway off on the other ports is OS configuration.
        if ($n['network_adapters']) { $node['network_adapters'] = @(Get-ZtpEnvironmentPort -Node $n) }
        $nodes.Add($node)
    }

    $mgmt = [ordered]@{}
    foreach ($k in 'subnet', 'gateway', 'dns_servers', 'site_ip_range', 'provisioning_network', 'static_method', 'provisioning_dhcp_range') { & $put $mgmt $k (& $v "networking.management.$k") }
    $distinct = @($modes | Select-Object -Unique)
    $mgmt['ip_assignment'] = if ($distinct.Count -eq 1) { $distinct[0] } else { 'static' }
    $siteVlan = & $v 'networking.management.vlan_id'
    $mgmt['vlan_id'] = if ($null -ne $siteVlan -and "$siteVlan" -ne '') { [int]$siteVlan } elseif ($vlans.Count) { $vlans[0] } else { 0 }

    $env_ = [ordered]@{}
    $env_['azure_identity'] = [ordered]@{}; & $put $env_.azure_identity 'azure_tenant_id' (& $v 'azure.tenant_id')
    $env_['azure_resources'] = [ordered]@{}; & $put $env_.azure_resources 'location' (& $v 'azure.location')
    $env_['site'] = [ordered]@{}; & $put $env_.site 'name' (& $v 'site.name'); & $put $env_.site 'code' (& $v 'site.code')
    $env_['hardware'] = [ordered]@{}
    foreach ($k in 'vendor', 'model') { & $put $env_.hardware $k (& $v "hardware.$k") }
    if ((& $v 'hardware.bios') -is [System.Collections.IDictionary]) { $env_.hardware['bios'] = & $v 'hardware.bios' }
    if ((& $v 'hardware.bios_during_provisioning') -is [System.Collections.IDictionary]) { $env_.hardware['bios_during_provisioning'] = & $v 'hardware.bios_during_provisioning' }
    # identity.local_admin (the deployment admin), networking.ntp_servers and hardware.sbe aren't mapped: OS configuration
    # and deployment read them; ZTP doesn't.
    $env_['network_intents'] = [ordered]@{ management = $mgmt }
    $env_['cluster_nodes'] = $nodes.ToArray()

    $ztp = [ordered]@{}
    & $put $ztp 'subscription_id' $(if ($simplified['subscription_id']) { $simplified['subscription_id'] } else { & $v 'azure.subscription_id' })
    & $put $ztp 'resource_group' $(if ($simplified['resource_group']) { $simplified['resource_group'] } else { & $v 'azure.resource_group' })
    & $put $ztp 'site_name' $simplified['site_name']
    & $put $ztp 'time_zone' (& $v 'site.time_zone')
    & $put $ztp 'provisioning_iso' $simplified['maintenance_iso']
    & $put $ztp 'os_version' (& $v 'provisioning.os_version')
    $share = $simplified['media_share']
    if ($share -is [System.Collections.IDictionary]) { & $put $ztp 'share_name' $share['name']; & $put $ztp 'share_host' $share['host']; & $put $ztp 'share_host_adapter' $share['host_adapter'] }
    & $put $ztp 'media_path' $simplified['media_path']
    & $put $ztp 'evidence_path' $simplified['evidence_path']
    & $put $ztp 'azl_rp_object_id' (& $v 'azure.hci_resource_provider_object_id')
    if ((& $v 'tags') -is [System.Collections.IDictionary]) { $ztp['tags'] = & $v 'tags' }
    $vaults = @{}
    $vaultList = & $v 'key_vaults'
    foreach ($kv in @($vaultList)) { if ($kv -is [System.Collections.IDictionary] -and $kv['name']) { $vaults[[string]$kv['name']] = $kv } }
    $adminSecret = [ordered]@{}
    if ($simplified['admin'] -is [System.Collections.IDictionary]) { & $put $adminSecret 'username' $simplified['admin']['username'] }
    $adminRef = Split-ZtpKeyVaultReference (& $v 'provisioning.simplified.admin.password')
    if ($adminRef) {
        $adminSecret['vault'] = $adminRef.Vault; $adminSecret['name'] = $adminRef.Secret
        if ($vaults.ContainsKey($adminRef.Vault)) { & $put $adminSecret 'subscription_id' $vaults[$adminRef.Vault]['subscription_id']; & $put $adminSecret 'resource_group' $vaults[$adminRef.Vault]['resource_group'] }
    }
    $ztp['admin_secret'] = $adminSecret
    & $put $ztp 'maintenance_password_secret' $simplified['maintenance_password']
    $bmcSecret = [ordered]@{}
    $passwordRef = Split-ZtpKeyVaultReference (& $v 'hardware.bmc.password')
    if ($passwordRef) { $bmcSecret['vault'] = $passwordRef.Vault; $bmcSecret['password_name'] = $passwordRef.Secret }
    $user = & $v 'hardware.bmc.username'
    $userRef = Split-ZtpKeyVaultReference $user
    if ($userRef) { $bmcSecret['username_name'] = $userRef.Secret; if (-not $passwordRef -or $userRef.Vault -ne $passwordRef.Vault) { $bmcSecret['username_vault'] = $userRef.Vault } }
    elseif ($user) { $bmcSecret['username'] = [string]$user }
    $ztp['bmc_secret'] = $bmcSecret
    $env_['ztp'] = $ztp
    return $env_
}

function ConvertTo-ZtpSchema5Message {
    # A key-check message in environment-file paths, rewritten in the schema 5 paths the operator wrote.
    param([Parameter(Mandatory)][string]$Message)
    $m = $Message
    $m = $m -replace 'cluster_nodes\[(\d+)\]( \([^)]*\))?\.(ip_address|mac_address)', 'nodes[$1]$2 management port $3'
    $m = $m -replace 'cluster_nodes\[(\d+)\]( \([^)]*\))?\.adapter_name', 'nodes[$1]$2 management port name'
    $m = $m -replace 'cluster_nodes\[(\d+)\]( \([^)]*\))?\.service_tag', 'nodes[$1]$2.serial_number'
    $m = $m -replace 'cluster_nodes\[(\d+)\]( \([^)]*\))?\.idrac_ip', 'nodes[$1]$2.bmc.ip_address'
    $m = $m -replace 'cluster_nodes\[(\d+)\]( \([^)]*\))?\.ip_assignment', 'nodes[$1]$2 management port ip_assignment'
    $m = $m -replace 'cluster_nodes\[(\d+)\]( \([^)]*\))?\.maintenance_address', 'nodes[$1]$2 provisioning port ip_address'
    $map = [ordered]@{
        'ztp.maintenance_password_secret'              = 'provisioning.simplified.maintenance_password'
        'cluster_nodes'                                = 'nodes'
        'azure_identity.azure_tenant_id'               = 'azure.tenant_id'
        'azure_resources.location'                     = 'azure.location'
        'network_intents.management.'                  = 'networking.management.'
        'ztp.subscription_id'                          = 'azure.subscription_id (or provisioning.simplified.subscription_id)'
        'ztp.resource_group'                           = 'azure.resource_group (or provisioning.simplified.resource_group)'
        'ztp.site_name'                                = 'provisioning.simplified.site_name'
        'ztp.time_zone'                                = 'site.time_zone'
        'ztp.provisioning_iso'                         = 'provisioning.simplified.maintenance_iso'
        'ztp.os_version'                               = 'provisioning.os_version'
        'ztp.share_name'                               = 'provisioning.simplified.media_share.name'
        'ztp.share_host or ztp.share_host_adapter'     = 'provisioning.simplified.media_share.host or host_adapter'
        'ztp.share_host_adapter'                       = 'provisioning.simplified.media_share.host_adapter'
        'ztp.share_host'                               = 'provisioning.simplified.media_share.host'
        'ztp.media_path'                               = 'provisioning.simplified.media_path'
        'ztp.evidence_path'                            = 'provisioning.simplified.evidence_path'
        'ztp.azl_rp_object_id'                         = 'azure.hci_resource_provider_object_id'
        'ztp.tags'                                     = 'tags'
        'ztp.admin_secret.username'                    = 'provisioning.simplified.admin.username'
        'ztp.admin_secret.vault'                       = 'provisioning.simplified.admin.password (keyvault://<vault>/<secret>)'
        'ztp.admin_secret.name'                        = 'provisioning.simplified.admin.password (keyvault://<vault>/<secret>)'
        'ztp.admin_secret.subscription_id'             = 'key_vaults[].subscription_id of the provisioning admin''s vault'
        'ztp.admin_secret.resource_group'              = 'key_vaults[].resource_group of the provisioning admin''s vault'
        'ztp.bmc_secret.username_name'                 = 'hardware.bmc.username'
        'ztp.bmc_secret.password_name'                 = 'hardware.bmc.password'
        'ztp.bmc_secret.vault'                         = 'hardware.bmc.password (keyvault://<vault>/<secret>)'
    }
    foreach ($k in $map.Keys) { $m = $m.Replace($k, $map[$k]) }
    return $m
}

function Read-ZtpInfrastructure {
    <#
    .SYNOPSIS
    Reads the file -InfrastructureFile names, in either format, and returns the environment-file keys the scripts read.
    .DESCRIPTION
    A legacy environment file (docs/environment-file.md) is returned as it is. A schema 5 infrastructure.yml is validated
    and mapped (ConvertFrom-ZtpInfrastructureV5); the result carries _source { format, schema_version, path, validator,
    problems, warnings }, which Assert-ZtpEnvironment reports with the key check, in schema 5 paths.
    Validation: the toolkit's Test-AzlInfrastructure when Find-ZtpToolkitModule finds the toolkit (its errors and warnings,
    with their rule IDs), always followed by Test-ZtpInfrastructureV5 for what ZTP itself needs.
    .PARAMETER ToolkitModulePath
    The toolkit's AzlInfrastructure.psm1. Default: Find-ZtpToolkitModule. 'none' skips the toolkit.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ToolkitModulePath
    )
    $data = Read-ZtpEnvironmentFile -Path $Path
    if ((Get-ZtpEnvironmentFormat -Data $data) -eq 'legacy') { return $data }
    $full = (Resolve-Path -LiteralPath $Path).Path
    $problems = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $module = if ($ToolkitModulePath -eq 'none') { $null } elseif ($ToolkitModulePath) { $ToolkitModulePath } else { Find-ZtpToolkitModule }
    $validator = 'built-in'
    if ($module) {
        if (-not (Test-Path -LiteralPath $module -PathType Leaf)) { throw "The toolkit module $module doesn't exist." }
        Import-Module $module -Force -ErrorAction Stop
        foreach ($finding in @(Test-AzlInfrastructure -Path $full)) {
            $line = "$($finding.Id) $($finding.Path): $($finding.Message)"
            if ($finding.Severity -eq 'error') { $problems.Add($line) } elseif ($finding.Severity -eq 'warning') { $warnings.Add($line) }
        }
        $validator = "azurelocal-toolkit ($module)"
    }
    foreach ($p in @(Test-ZtpInfrastructureV5 -Data $data)) { $problems.Add($p) }
    # The toolkit's AZL-024 stops Mode C without a DHCP provisioning port; without the toolkit, ZTP's own check does.
    if (-not $module) { foreach ($p in @(Test-ZtpV5ManagementReach -Data $data)) { $problems.Add($p) } }
    $env_ = ConvertFrom-ZtpInfrastructureV5 -Data $data
    $version = [string](Get-ZtpEnvValue -Environment $data -Path '_metadata.schema_version')
    $env_['_source'] = [ordered]@{ format = 'schema5'; schema_version = $version; path = $full; validator = $validator; problems = $problems.ToArray(); warnings = $warnings.ToArray(); ignored = @(if ((Get-ZtpEnvValue -Environment $data -Path 'hardware.sbe') -is [System.Collections.IDictionary]) { 'hardware.sbe' }) }
    return $env_
}
