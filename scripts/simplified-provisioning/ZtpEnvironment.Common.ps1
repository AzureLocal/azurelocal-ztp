#Requires -Version 7.0
<#
.SYNOPSIS
Shared helpers for the environment file (dot-sourced by Invoke-ZtpEnvironment.ps1 and Initialize-ZtpNode.ps1).
.DESCRIPTION
Reads the environment file (YAML), checks the keys the two scripts use so a bad file fails before anything runs and every
problem is named at once, resolves which nodes a run covers, finds the OEM's SBE files in a folder, and checks the SBE zip
against the SHA-256 the OEM publishes. Nothing here talks to Azure or to a node. The only network call is the optional read
of the OEM's SBE discovery manifest in Test-ZtpSbeHash.

The keys, by what needs them:
  Prepare (Initialize-ZtpNode.ps1) and Provision (Invoke-ZtpEnvironment.ps1, which also runs Prepare) both read
    cluster_nodes[].name, .ip_address, .mac_address
    azure_identity.azure_tenant_id
    network_intents.management.subnet, .gateway, .dns_servers
    onprem.ntp_servers                         (optional)
    credentials.local_admin_username, .local_admin_password_secret   (keyvault://<vault>/<secret>)
    hardware.vendor
    ztp.subscription_id, .resource_group
    ztp.admin_secret.subscription_id, .vault, .name, .username
    ztp.node_preparation.sbe_bundle
  Provision also reads
    cluster_nodes[].service_tag, .idrac_ip
    hardware.model
    azure_resources.location
    site.name
    ztp.site_name, .time_zone, .provisioning_iso, .os_version, .share_name
    ztp.share_host or ztp.share_host_adapter
    ztp.admin_secret.resource_group
    ztp.bmc_secret.vault, .username_name, .password_name
    ztp.tags (optional mapping), ztp.azl_rp_object_id (optional GUID)
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
    Returns every problem found in the parsed environment file as a string; no output means it is valid.
    .PARAMETER For
    Provision checks every key Invoke-ZtpEnvironment.ps1 reads; Prepare checks only those Initialize-ZtpNode.ps1 reads.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Environment,
        [ValidateSet('Provision', 'Prepare')][string]$For = 'Provision'
    )
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
            & $check $n 'ip_address' "$label.ip_address" 'ip'
            & $check $n 'mac_address' "$label.mac_address" 'mac'
            if ($For -eq 'Provision') {
                & $check $n 'service_tag' "$label.service_tag" 'text'
                & $check $n 'idrac_ip' "$label.idrac_ip" 'ip'
            }
            $index++
        }
    }

    & $check $Environment 'azure_identity.azure_tenant_id' 'azure_identity.azure_tenant_id' 'guid'
    & $check $Environment 'network_intents.management.subnet' 'network_intents.management.subnet' 'cidr'
    & $check $Environment 'network_intents.management.gateway' 'network_intents.management.gateway' 'ip'
    & $check $Environment 'network_intents.management.dns_servers' 'network_intents.management.dns_servers' 'iplist'
    & $check $Environment 'onprem.ntp_servers' 'onprem.ntp_servers' 'textlist' -Optional
    & $check $Environment 'credentials.local_admin_username' 'credentials.local_admin_username' 'text'
    $admin = [string](Get-ZtpEnvValue -Environment $Environment -Path 'credentials.local_admin_username')
    if ($admin -in 'Administrator', 'Guest') { $problems.Add("credentials.local_admin_username can't be the built-in account '$admin'.") }
    & $check $Environment 'credentials.local_admin_password_secret' 'credentials.local_admin_password_secret' 'text'
    $ref = [string](Get-ZtpEnvValue -Environment $Environment -Path 'credentials.local_admin_password_secret')
    if ($ref -and $ref -notmatch '^keyvault://([^/]+)/(.+)$') { $problems.Add('credentials.local_admin_password_secret must be keyvault://<vault>/<secret>.') }
    & $check $Environment 'hardware.vendor' 'hardware.vendor' 'text'
    & $check $Environment 'ztp.subscription_id' 'ztp.subscription_id' 'guid'
    & $check $Environment 'ztp.resource_group' 'ztp.resource_group' 'text'
    & $check $Environment 'ztp.admin_secret.subscription_id' 'ztp.admin_secret.subscription_id' 'guid'
    foreach ($k in 'vault', 'name', 'username') { & $check $Environment "ztp.admin_secret.$k" "ztp.admin_secret.$k" 'text' }
    & $check $Environment 'ztp.node_preparation.sbe_bundle' 'ztp.node_preparation.sbe_bundle' 'text'

    if ($For -eq 'Provision') {
        & $check $Environment 'hardware.model' 'hardware.model' 'text'
        & $check $Environment 'azure_resources.location' 'azure_resources.location' 'text'
        & $check $Environment 'site.name' 'site.name' 'text'
        foreach ($k in 'site_name', 'time_zone', 'provisioning_iso', 'os_version', 'share_name') { & $check $Environment "ztp.$k" "ztp.$k" 'text' }
        $shareHost = Get-ZtpEnvValue -Environment $Environment -Path 'ztp.share_host'
        $shareAdapter = Get-ZtpEnvValue -Environment $Environment -Path 'ztp.share_host_adapter'
        if (-not $shareHost -and -not $shareAdapter) { $problems.Add('ztp.share_host or ztp.share_host_adapter is required: the address the BMCs reach this server on.') }
        elseif ($shareHost) { & $check $Environment 'ztp.share_host' 'ztp.share_host' 'ip' }
        & $check $Environment 'ztp.admin_secret.resource_group' 'ztp.admin_secret.resource_group' 'text'
        foreach ($k in 'vault', 'username_name', 'password_name') { & $check $Environment "ztp.bmc_secret.$k" "ztp.bmc_secret.$k" 'text' }
        & $check $Environment 'ztp.azl_rp_object_id' 'ztp.azl_rp_object_id' 'guid' -Optional
        $tags = Get-ZtpEnvValue -Environment $Environment -Path 'ztp.tags'
        if ($null -ne $tags -and $tags -isnot [System.Collections.IDictionary]) { $problems.Add('ztp.tags must be a mapping of tag names to values.') }
        $allow = Get-ZtpEnvValue -Environment $Environment -Path 'ztp.node_preparation.allow_unvalidated_sbe'
        if ($null -ne $allow -and $allow -isnot [bool]) { $problems.Add("ztp.node_preparation.allow_unvalidated_sbe must be true or false, not '$allow'.") }
    }
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
        [ValidateSet('Provision', 'Prepare')][string]$For = 'Provision',
        [string]$Source = 'The environment file'
    )
    $problems = @(Test-ZtpEnvironment -Environment $Environment -For $For)
    if ($problems.Count) {
        throw "$Source is invalid ($($problems.Count) problem$(if ($problems.Count -ne 1) { 's' })):`n  - $($problems -join "`n  - ")"
    }
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

function Get-ZtpSbeBundle {
    <#
    .SYNOPSIS
    Finds the three files an OEM's SBE needs in a folder: SBE_*.zip, its <name>.xml and SBE_Discovery_*.xml.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "SBE folder $Path doesn't exist." }
    $zips = @(Get-ChildItem -LiteralPath $Path -File -Filter 'SBE_*.zip')
    if ($zips.Count -ne 1) { throw "Expected one SBE_*.zip in $Path, found $($zips.Count)." }
    $zip = $zips[0]
    $name = [IO.Path]::GetFileNameWithoutExtension($zip.Name)
    $xml = @(Get-ChildItem -LiteralPath $Path -File -Filter "$name.xml")
    $discovery = @(Get-ChildItem -LiteralPath $Path -File -Filter 'SBE_Discovery_*.xml')
    if (-not $xml -or -not $discovery) { throw "$Path needs $($zip.Name), $name.xml and the SBE_Discovery_*.xml file." }
    return [pscustomobject]@{ Name = $name; Zip = $zip; Files = @($zip, $xml[0], $discovery[0]) }
}

function Test-ZtpSbeHash {
    <#
    .SYNOPSIS
    Checks the SBE zip against the SHA-256 the OEM publishes; throws on a mismatch.
    .DESCRIPTION
    Reads the OEM's SBE discovery manifest from -ManifestUrl when given, and falls back to the SBE_Discovery_*.xml that came
    with the package if it can't be reached. Returns the name, hash and where the expected hash came from.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Bundle, [string]$ManifestUrl)
    $manifest = $null
    $source = ''
    if ($ManifestUrl) {
        try { $manifest = [xml](Invoke-WebRequest -Uri $ManifestUrl -TimeoutSec 60).Content; $source = $ManifestUrl }
        catch { Write-Warning "Couldn't read $ManifestUrl ($($_.Exception.Message)); using the SBE's discovery XML." }
    }
    if (-not $manifest) {
        $discovery = $Bundle.Files[2]
        try { $manifest = [xml](Get-Content -LiteralPath $discovery.FullName -Raw) }
        catch { throw "$($discovery.Name) isn't valid XML: $($_.Exception.Message)" }
        $source = $discovery.Name
    }
    if (-not $manifest.DocumentElement -or $manifest.DocumentElement.LocalName -ne 'SBEUpdatesManifest') { throw "$source isn't an SBE discovery manifest (no SBEUpdatesManifest element)." }
    $update = @($manifest.DocumentElement.ApplicableUpdate | Where-Object { $_ -and $_.UpdateInfo.UpdateName -eq $Bundle.Name })
    if (-not $update) { throw "$($Bundle.Name) isn't in $source." }
    $expected = ([string]$update[0].UpdateInfo.PackageHash).Trim().ToUpperInvariant()
    $actual = (Get-FileHash -LiteralPath $Bundle.Zip.FullName -Algorithm SHA256).Hash
    if ($actual -ne $expected) { throw "$($Bundle.Zip.Name) has SHA-256 $actual; $source says $expected." }
    return [pscustomobject]@{ Name = $Bundle.Name; Hash = $actual; Source = $source }
}
