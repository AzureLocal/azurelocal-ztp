#Requires -Version 7.0
#Requires -Modules powershell-yaml
<#
.SYNOPSIS
    One command from an environment file to machines ready to join a cluster, for the nodes you name.
.DESCRIPTION
    Reads infrastructure.yml, writes ZTP's settings, node list and Bicep parameters, creates the cluster resource group,
    reads the iDRAC login from the management vault, finds this server's address as the iDRACs reach it, then runs
    Invoke-ZtpProvisioning.ps1. Before the claim, the Device stage (Set-ZtpDeviceConfiguration.ps1) sets each static
    management address on the port with the node's management MAC in the maintenance environment, through the Configurator
    App's REST service; a node without a maintenance address is found by scanning for the service and matching its MAC.
    With static_method device (the default) the site is Automatic and the claim carries no Manual adapter, so that static
    is the only one. A failed OS install is resubmitted once automatically. After Ready to cluster, the Network stage
    (Set-ZtpManagementAddress.ps1) checks each static management address on the port with the node's management MAC
    through Azure's per-NIC API and moves it there if needed. The Restore stage sets the BIOS values that were changed for
    the install only (bios_during_provisioning) back, restarts the node and waits until it is Connected again. ZTP ends
    at the Handoff: each machine is Provisioned in Azure and Arc-connected, with its management address on the management
    port. OEM drivers, the SBE in C:\SBE, DHCP off on the other ports, DNS and time on the host, and the deployment admin
    are OS configuration (azurelocal-toolkit Phase 03), which comes next, before Validate and Deploy:
    https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/. The provisioned OS
    names the ports Port0 to Port6, so find them by MAC there. The SBE settings (hardware.sbe, ztp.node_preparation) are
    accepted and ignored.

    Without -Execute it writes the generated files and shows ZTP's plan. Nothing changes in Azure or on a node.
    With -Execute it REINSTALLS the named nodes. Run it elevated, because it creates the share, a local account and a
    firewall rule. The signed-in account needs Owner, or Contributor and Role Based Access Control Administrator, on the
    resource group, and rights to delegate on the vault that holds the administrator secret.
.PARAMETER InfrastructureFile
    The environment file: a master infrastructure.yml (schema 5, detected by _metadata.schema_version; validated with the
    toolkit's module when an azurelocal-toolkit clone is next to this repository or $env:AZL_TOOLKIT_ROOT names one), or the
    older environment-file layout (docs/environment-file.md, deprecated). See docs/infrastructure-schema-5.md.
.PARAMETER Node
    Nodes to provision. Defaults to every node in the environment file.
.PARAMETER From
    Stage to resume from: Resolve, Media, Boot, Bootstrap, Vouchers, Device, Azure, Ready, Network, Restore or Handoff (each runs with every
    later one).
.PARAMETER MediaPath
    Where the maintenance ISO, node images (about 4 GB each), vouchers and run state are kept. Overrides
    ztp.media_path; without either, %ProgramData%\AzureLocalZtp\<ztp.site_name>\media. Refused inside a git working tree;
    created when missing.
.PARAMETER EvidencePath
    Where the event log (ztp-events.jsonl, which monitors follow), the change logs and the run transcript go. Overrides
    ztp.evidence_path; without either, %ProgramData%\AzureLocalZtp\<ztp.site_name>\evidence. Refused inside a git working
    tree; created when missing.
.PARAMETER ValidatorPath
    An extra validator for the environment file, run with -ConfigFile <file> and expected to leave a non-zero exit code on
    failure. Optional. When not given, tools/Validate-Infrastructure.ps1 beside the environment file is used if it exists;
    when neither exists only the built-in key check runs. The built-in check always runs first.
.PARAMETER UseManagedIdentity
    Sign in as the managed identity attached to this host. Otherwise it uses the current Az sign-in, so a service principal signs in with Connect-AzAccount first.
.PARAMETER Execute
    Make the changes. Without it this is a plan.
.EXAMPLE
    ./Invoke-ZtpEnvironment.ps1 -InfrastructureFile ./infrastructure.yml
.EXAMPLE
    ./Invoke-ZtpEnvironment.ps1 -InfrastructureFile ./infrastructure.yml -Node node-02 -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string[]]$Node,
    [ValidateSet('Resolve', 'Media', 'Boot', 'Bootstrap', 'Vouchers', 'Device', 'Azure', 'Ready', 'Network', 'Restore', 'Handoff')][string]$From,
    [string]$MediaPath,
    [string]$EvidencePath,
    [string]$ValidatorPath,
    [switch]$UseManagedIdentity,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module powershell-yaml
. (Join-Path $PSScriptRoot 'ZtpEnvironment.Common.ps1')

# Az PowerShell needs Bicep on PATH; use the copy the Azure CLI installed.
$env:PATH = "$env:PATH;$(Join-Path $HOME '.azure\bin')"

# The environment file must hold every key this script reads, and then pass the optional external validator, before anything runs.
$env_ = Read-ZtpInfrastructure -Path $InfrastructureFile
Assert-ZtpEnvironment -Environment $env_ -Source $InfrastructureFile
$validator = if ($ValidatorPath) { $ValidatorPath } else { Join-Path (Split-Path (Resolve-Path -LiteralPath $InfrastructureFile)) 'tools\Validate-Infrastructure.ps1' }
if (Test-Path -LiteralPath $validator) {
    $global:LASTEXITCODE = 0
    & $validator -ConfigFile (Resolve-Path -LiteralPath $InfrastructureFile)
    if ($global:LASTEXITCODE -ne 0) { throw "$InfrastructureFile failed validation. Fix it and run again." }
}
elseif ($ValidatorPath) { throw "Validator $ValidatorPath doesn't exist." }
else { Write-Verbose "No validator at $validator; only the built-in key check ran." }

$ztp = $env_.ztp
# Every choice below is a key of the file (schema provisioning.simplified.*, hardware.bmc.*); the default is what ZTP always did.
$setting = { param([string]$Path, $Default) Get-ZtpSetting -Environment $env_ -Path $Path -Default $Default }
$tenant = [string]$env_.azure_identity.azure_tenant_id
$clusterSub = [string]$ztp.subscription_id
$vaultSub = [string]$ztp.admin_secret.subscription_id
$vault = [string]$ztp.admin_secret.vault
$vaultRg = [string]$ztp.admin_secret.resource_group
$rg = [string]$ztp.resource_group

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
# Downloads, images, vouchers and state, and the evidence, live outside any repository: -MediaPath / -EvidencePath, then
# ztp.media_path / ztp.evidence_path, then %ProgramData%\AzureLocalZtp\<site>.
$media = Resolve-ZtpDataPath -Environment $env_ -Kind media -Override $MediaPath
$evidence = Resolve-ZtpDataPath -Environment $env_ -Kind evidence -Override $EvidencePath
Write-Output "Media: $media. Evidence: $evidence."
$events = Join-Path $evidence 'ztp-events.jsonl'
$cfgDir = Join-Path $root 'config\simplified-provisioning'
$nodesFile = Join-Path $cfgDir 'nodes.json'
$config = Join-Path $cfgDir 'ztp-provisioning.json'
$bicepDir = Join-Path $PSScriptRoot 'bicep'
$parameters = Join-Path $bicepDir 'main.parameters.json'
$state = Join-Path $media 'ztp-state'
foreach ($dir in $cfgDir, $bicepDir, $state, (Join-Path $media 'vouchers')) { New-Item -ItemType Directory -Force $dir | Out-Null }

# The address the iDRACs reach: the VPN adapter when it's named in the environment file, otherwise the value given.
$shareHost = if ($ztp.Contains('share_host')) { [string]$ztp.share_host } else { '' }
if ($ztp.Contains('share_host_adapter') -and $ztp.share_host_adapter) {
    $shareHost = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias ([string]$ztp.share_host_adapter) -ErrorAction Stop | Select-Object -First 1).IPAddress
}
if (-not $shareHost) { throw 'Set ztp.share_host or ztp.share_host_adapter in the environment file.' }
Write-Output "Share host: $shareHost"

$nodeList = @($env_.cluster_nodes)
# How the maintenance environment reaches Azure (dhcp, the default, or static), for the summary below. Whether each
# management port takes DHCP while provisioned (Mode B or C) is Get-ZtpManagementDhcp.
$provisioningNetwork = [string](Get-ZtpEnvValue -Environment $env_ -Path 'network_intents.management.provisioning_network')
if (-not $provisioningNetwork) { $provisioningNetwork = 'dhcp' }
$Node = @(Resolve-ZtpNodeSelection -Environment $env_ -Node $Node)
# No SBE: the OS install discovers its own, and staging one is OS configuration (hardware.sbe is accepted and ignored).

# Each set of nodes keeps its own state, so proving one node never disturbs another's run.
$runName = $Node -join '+'

# The node list the stages read. bios (hardware.bios merged with the node's own) is applied by the Boot stage.
# Without a maintenance address, the Device stage scans this range for the maintenance environment and matches it by MAC.
$scanRange = Get-ZtpEnvValue -Environment $env_ -Path 'network_intents.management.provisioning_dhcp_range'
$scanText = if ($scanRange -is [System.Collections.IDictionary] -and $scanRange['start'] -and $scanRange['end']) { "$($scanRange['start'])-$($scanRange['end'])" } else { '' }
@{ nodes = @($nodeList | ForEach-Object {
            $entry = [ordered]@{ name = [string]$_.name; service_tag = [string]$_.service_tag; bmc_address = [string]$_.idrac_ip; management_ip = [string]$_.ip_address }
            # For the handoff's per-port detail and the management address mode: the management port's MAC and
            # ip_assignment, whether it takes DHCP while provisioned, and the file's ports (name, MAC, roles, ip_assignment,
            # ip_address).
            $entry.management_mac = [string]$_.mac_address
            $entry.management_ip_assignment = Get-ZtpManagementAssignment -Environment $env_ -Node $_
            $entry.management_dhcp = Get-ZtpManagementDhcp -Environment $env_ -Node $_
            $entry.network_adapters = @(Get-ZtpEnvironmentPort -Node $_ -Environment $env_)
            # The Device stage reaches the maintenance environment's REST service on this address.
            $maintenance = [string](Get-ZtpEnvValue -Environment $_ -Path 'maintenance_address')
            if ($maintenance) { $entry.maintenance_address = $maintenance }
            elseif ($scanText) { $entry.maintenance_scan_range = $scanText }
            # bios: what the Boot stage applies (the final state with the temporary values merged over it).
            $bios = Get-ZtpEnvironmentBios -Environment $env_ -Node $_ -Kind boot
            if ($bios.Count) { $entry.bios = $bios }
            # bios_reason: why ZTP chose an attribute it derived, for the message when the BMC's BIOS has no such attribute.
            $reasons = (Get-ZtpDerivedBios -Environment $env_ -Node $_).Reasons
            $used = [ordered]@{}; foreach ($k in $reasons.Keys) { if ($bios.Contains($k)) { $used[$k] = $reasons[$k] } }
            if ($used.Count) { $entry.bios_reason = $used }
            # bios_restore: what the Restore stage sets back after Network, for every temporary key: the final value, or
            # '' for the value the BIOS had before Boot changed it (saved in the run state).
            $final = Get-ZtpEnvironmentBios -Environment $env_ -Node $_
            $during = Get-ZtpEnvironmentBios -Environment $env_ -Node $_ -Kind provisioning
            if ($during.Count) {
                $restore = [ordered]@{}
                foreach ($k in $during.Keys) { $restore[$k] = $(if ($final.Contains($k)) { $final[$k] } else { '' }) }
                $entry.bios_restore = $restore
                # A derived slot goes back to the value Boot found; when that is the isolating value itself (a run that crashed
                # left it off), to the vendor's enabled value. Restore reads this for the keys whose restore value is ''.
                $derivedFallback = (Get-ZtpDerivedBios -Environment $env_ -Node $_).Fallback
                $fallbackUsed = [ordered]@{}
                foreach ($k in $restore.Keys) { if ($restore[$k] -eq '' -and $derivedFallback.Contains($k)) { $fallbackUsed[$k] = $derivedFallback[$k] } }
                if ($fallbackUsed.Count) { $entry.bios_restore_fallback = $fallbackUsed }
            }
            $entry
        }) } |
    ConvertTo-Json -Depth 5 | Set-Content $nodesFile
$biosPlan = @(foreach ($n in $nodeList) {
        $b = Get-ZtpEnvironmentBios -Environment $env_ -Node $n -Kind boot
        if ($b.Count) { "$($n.name) $(@($b.Keys | ForEach-Object { "$_=$($b[$_])" }) -join ', ')" }
    })
if ($biosPlan) { Write-Output "BIOS set by the Boot stage before the maintenance boot: $($biosPlan -join '; ')." }
$restorePlan = @(foreach ($n in $nodeList) {
        $d = Get-ZtpEnvironmentBios -Environment $env_ -Node $n -Kind provisioning
        $f = Get-ZtpEnvironmentBios -Environment $env_ -Node $n
        if ($d.Count) { "$($n.name) $(@($d.Keys | ForEach-Object { "$_=$(if ($f.Contains($_)) { $f[$_] } else { '<value before Boot>' })" }) -join ', ')" }
    })
if ($restorePlan) { Write-Output "BIOS set back by the Restore stage after Network: $($restorePlan -join '; ')." }
# What ZTP derived from the inventory (SAN adapters, embedded NICs), with the reason for each. Explicit keys won over it above.
foreach ($line in @(Get-ZtpDerivedBiosPlan -Environment $env_ -Node $Node)) { Write-Output $line }
$withoutMaintenance = @($nodeList | Where-Object { $_.name -in $Node -and -not (Get-ZtpEnvValue -Environment $_ -Path 'maintenance_address') } | ForEach-Object { [string]$_.name })
if ($withoutMaintenance) { Write-Output "Device stage (static address in the maintenance environment): no maintenance address for $($withoutMaintenance -join ', '); it scans $(if ($scanText) { $scanText } else { "the management subnet $([string]$env_.network_intents.management.subnet)" }) for TCP 20001 and finds each node by its management MAC." }
$staticMethod = Get-ZtpStaticMethod -Environment $env_
Write-Output "Static management addresses set by: $(if ($staticMethod -eq 'device') { 'the Device stage, by MAC, before the claim (site network Automatic, no Manual adapter in the claim)' } else { 'the OS install, from the site''s Manual setting and the claim''s Manual adapter (static_method site)' }); the Network stage checks them after the install."
$edgeSecret = Split-ZtpKeyVaultReference (Get-ZtpEnvValue -Environment $env_ -Path 'ztp.maintenance_password_secret')

if ($UseManagedIdentity) {
    Connect-AzAccount -Identity -WarningAction SilentlyContinue | Out-Null
}
Set-AzContext -Tenant $tenant -Subscription $clusterSub -Scope Process -WarningAction SilentlyContinue | Out-Null
# From the environment file, because a managed identity has no directory read rights by default.
$rpObjectId = if ($ztp.Contains('azl_rp_object_id')) { [string]$ztp.azl_rp_object_id } else { (Get-AzADServicePrincipal -ApplicationId '1412d89f-b8a8-4111-b4fd-e82905cbd85d').Id }
if (-not $rpObjectId) { throw 'Set ztp.azl_rp_object_id: the Azure Local resource provider object ID in this tenant.' }

$tags = @{}
if ($ztp.Contains('tags') -and $ztp.tags) { foreach ($k in $ztp.tags.Keys) { $tags[[string]$k] = [string]$ztp.tags[$k] } }

# Per node: the Arc machine name (default: the node name, so the Arc resource matches the host) and, for static, the
# management port by MAC with its address. edgeMachines 2026-10-01: arcMachineResourceId and
# siteDetails.deviceConfiguration.network.networkAdapters[] (ipAssignmentType Manual, macAddress, ipAddress, ...).
$mgmtNet = $env_.network_intents.management
$mgmtMode = Get-ZtpManagementAssignment -Environment $env_
$mgmtMask = ConvertTo-ZtpSubnetMask -PrefixLength ([int](([string]$mgmtNet.subnet) -split '/')[1])
$mgmtVlan = [string](Get-ZtpEnvValue -Environment $env_ -Path 'network_intents.management.vlan_id')
if (-not $mgmtVlan) { $mgmtVlan = '0' }
$bicepNodes = @($nodeList | ForEach-Object {
        $arcName = [string](Get-ZtpEnvValue -Environment $_ -Path 'arc_machine_name')
        [ordered]@{
            name             = [string]$_.name
            service_tag      = [string]$_.service_tag
            arc_machine_name = $(if ($arcName) { $arcName } else { [string]$_.name })
            management       = [ordered]@{
                ip_assignment = (Get-ZtpManagementAssignment -Environment $env_ -Node $_)
                # device: the claim carries no Manual adapter (the Device stage sets it); site: it does.
                static_method = $staticMethod
                # Does the management port take DHCP while provisioned? Mode B (true) or Mode C (false) for a static address.
                management_dhcp = (Get-ZtpManagementDhcp -Environment $env_ -Node $_)
                # The maintenance environment (Linux) reports MACs lower case with colons, as its Arc machine does.
                mac_address   = ([string]$_.mac_address).Replace('-', ':').ToLowerInvariant()
                adapter_name  = [string](Get-ZtpEnvValue -Environment $_ -Path 'adapter_name')
                ip_address    = [string]$_.ip_address
                subnet_mask   = $mgmtMask
                gateway       = [string]$mgmtNet.gateway
                dns_servers   = @($mgmtNet.dns_servers | ForEach-Object { [string]$_ })
                vlan_id       = $mgmtVlan
            }
        }
    })
# The site's network setting: Manual with the nodes' range only for static with static_method site, Automatic otherwise.
$siteNetwork = Get-ZtpSiteNetwork -Environment $env_
Write-Output "Site network: $($siteNetwork.IpAssignmentType)$(if ($siteNetwork.Range) { " $($siteNetwork.Range), gateway $($siteNetwork.Ipv4.defaultGateway), mask $($siteNetwork.Ipv4.subnetMask), DNS $($siteNetwork.Ipv4.dnsServers -join ', '), VLAN $($siteNetwork.Ipv4.vLanId)" }). Maintenance environment to Azure: $provisioningNetwork."
$modes = @($bicepNodes | ForEach-Object { $_.management.ip_assignment } | Select-Object -Unique)
if ($modes.Count -gt 1) { $mgmtMode = 'per node (' + (($bicepNodes | ForEach-Object { "$($_.name) $($_.management.ip_assignment)" }) -join ', ') + ')'; Write-Warning "The management addresses mix $($modes -join ' and ')$(if ($staticMethod -eq 'site') { "; the site's network setting is Manual over the static ones" })." }
Write-Output "Management addresses: $mgmtMode. Arc machine names: $(($bicepNodes | ForEach-Object { "$($_.name) -> $($_.arc_machine_name)" }) -join ', ')."
$bicepParameters = [ordered]@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = [ordered]@{
        location                  = @{ value = [string]$env_.azure_resources.location }
        tags                      = @{ value = $tags }
        azl_rp_app_object_id      = @{ value = $rpObjectId }
        key_vault_name            = @{ value = $vault }
        key_vault_resource_group  = @{ value = $vaultRg }
        key_vault_subscription_id = @{ value = $vaultSub }
        site_name                 = @{ value = [string]$ztp.site_name }
        site_display_name         = @{ value = [string]$env_.site.name }
        configuration_name        = @{ value = [string](& $setting 'ztp.configuration_name' 'default') }
        admin_username            = @{ value = [string]$ztp.admin_secret.username }
        admin_secret_name         = @{ value = [string]$ztp.admin_secret.name }
        time_zone                 = @{ value = [string]$ztp.time_zone }
        nodes                     = @{ value = $bicepNodes }
        apply_site_settings       = @{ value = (ConvertTo-ZtpBoolean (& $setting 'ztp.apply_site_settings' $true) 'ztp.apply_site_settings') }
        use_key_vault_configuration = @{ value = (ConvertTo-ZtpBoolean (& $setting 'ztp.use_key_vault_configuration' $true) 'ztp.use_key_vault_configuration') }
        assign_provisioning_roles = @{ value = (ConvertTo-ZtpBoolean (& $setting 'ztp.assign_provisioning_roles' $true) 'ztp.assign_provisioning_roles') }
        assign_hci_rp_role        = @{ value = (ConvertTo-ZtpBoolean (& $setting 'ztp.assign_hci_rp_role' $true) 'ztp.assign_hci_rp_role') }
        managed_resource_group_name = @{ value = [string](& $setting 'ztp.managed_resource_group_name' '') }
        network_kind              = @{ value = [string](& $setting 'ztp.network_kind' 'LAN') }
        ip_assignment_type        = @{ value = $siteNetwork.IpAssignmentType }
        ipv4                      = @{ value = $siteNetwork.Ipv4 }
        ntp_configuration_choice  = @{ value = [string](& $setting 'ztp.ntp.configuration' 'Automatic') }
        ntp_server                = @{ value = [string](& $setting 'ztp.ntp.server' '') }
        alternate_ntp_server      = @{ value = [string](& $setting 'ztp.ntp.alternate_server' '') }
        # Public is the only connectivity ZTP provisions with: the site setting carries no proxy details (see docs/variables-audit.md).
        connectivity_type         = @{ value = 'Public' }
    }
}
$bicepParameters | ConvertTo-Json -Depth 10 | Set-Content $parameters

[ordered]@{
    BootstrapCacheDirectory        = (Resolve-Path $media).Path
    BootstrapVersion               = [string]$ztp.provisioning_iso
    IncludePreview                 = (ConvertTo-ZtpBoolean (& $setting 'ztp.include_preview' $false) 'ztp.include_preview')
    Oem                            = [string]$env_.hardware.vendor
    NodesFile                      = $nodesFile
    ImageDirectory                 = Join-Path (Resolve-Path $media).Path 'ztp-virtual-usb'
    ImageNamePrefix                = [string](& $setting 'ztp.usb_image.name_prefix' 'ztp-usb-')
    ImageSizeGB                    = [int](& $setting 'ztp.usb_image.size_gb' 4)
    ShareHost                      = $shareHost
    ShareName                      = [string]$ztp.share_name
    ShareAccountName               = [string](& $setting 'ztp.share_account_name' 'svc-ztp-media')
    KeepShare                      = (ConvertTo-ZtpBoolean (& $setting 'ztp.keep_share' $false) 'ztp.keep_share')
    VoucherDirectory               = Join-Path (Resolve-Path $media).Path 'vouchers'
    VoucherWaitMinutes             = [int](& $setting 'ztp.timeouts.voucher_wait_minutes' 120)
    RfsWriteAttribute              = (Get-ZtpRfsWriteAttribute -Environment $env_)
    SkipCertificateCheck           = (-not (ConvertTo-ZtpBoolean (& $setting 'ztp.verify_bmc_certificate' $false) 'ztp.verify_bmc_certificate'))
    EventLogPath                   = $events
    BootstrapTimeoutMinutes        = [int](& $setting 'ztp.timeouts.bootstrap_minutes' 120)
    BootstrapVoucherTimeoutMinutes = [int](& $setting 'ztp.timeouts.bootstrap_voucher_minutes' 90)
    BootstrapStallMinutes          = [int](& $setting 'ztp.timeouts.bootstrap_stall_minutes' 20)
    SkipAzureCheck                 = (ConvertTo-ZtpBoolean (& $setting 'ztp.skip_azure_check' $false) 'ztp.skip_azure_check')
    Location                       = [string]$env_.azure_resources.location
    SubscriptionId                 = $clusterSub
    ResourceGroupName              = $rg
    ParameterFile                  = $parameters
    OsVersion                      = [string]$ztp.os_version
    SiteMode                       = [string](& $setting 'ztp.site_mode' 'Auto')
    DeploymentName                 = [string](& $setting 'ztp.deployment_name' "ztp-$([string]$ztp.site_name)")
    ArcMachineNameMapPath          = Join-Path $state "$runName.arc-machine-names.json"
    ReadyTimeoutMinutes            = [int](& $setting 'ztp.timeouts.ready_minutes' 180)
    PollIntervalSeconds            = [int](& $setting 'ztp.timeouts.poll_interval_seconds' 60)
    DeviceTimeoutMinutes           = [int](& $setting 'ztp.timeouts.device_minutes' 30)
    NetworkTimeoutMinutes          = [int](& $setting 'ztp.timeouts.network_minutes' 60)
    RestoreSettleMinutes           = [int](& $setting 'ztp.timeouts.restore_settle_minutes' 5)
    BiosTimeoutMinutes             = [int](& $setting 'ztp.timeouts.bios_minutes' 30)
    MaintenancePort                = [int](& $setting 'ztp.maintenance_environment.port' 20001)
    MaintenanceUser                = [string](& $setting 'ztp.maintenance_environment.username' 'edgeuser')
    HandoffPath                    = Join-Path $state "$runName.ztp-handoff.json"
    ClusterInputsPath              = Join-Path $state "$runName.ztp-cluster-inputs.yaml"
    StatePath                      = Join-Path $state "$runName.ztp-provisioning.state.json"
} | ForEach-Object {
    $maxTrain = [string](& $setting 'ztp.max_train' '')
    if ($maxTrain) { $_['MaxBootstrapTrain'] = $maxTrain }
    $_
} | ConvertTo-Json | Set-Content $config

$orchestrator = Join-Path $PSScriptRoot 'Invoke-ZtpProvisioning.ps1'
if (-not $Execute) {
    & $orchestrator -ConfigPath $config -NodeName $Node
    return
}

# A run that changes things leaves its transcript with the evidence. Nothing secret is written to the output.
$transcript = Join-Path $evidence ("$runName.{0}.transcript.log" -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
$null = Start-Transcript -LiteralPath $transcript -IncludeInvocationHeader
try {
    Set-AzContext -Tenant $tenant -Subscription $vaultSub -Scope Process -WarningAction SilentlyContinue | Out-Null
    # The BMC user name: the name itself (bmc_secret.username), or a secret, in username_vault when it isn't the password's vault.
    $user = if ($ztp.bmc_secret.Contains('username') -and $ztp.bmc_secret.username) { [string]$ztp.bmc_secret.username }
    else { Get-AzKeyVaultSecret -VaultName $(if ($ztp.bmc_secret.Contains('username_vault') -and $ztp.bmc_secret.username_vault) { [string]$ztp.bmc_secret.username_vault } else { [string]$ztp.bmc_secret.vault }) -Name ([string]$ztp.bmc_secret.username_name) -AsPlainText }
    $password = Get-AzKeyVaultSecret -VaultName ([string]$ztp.bmc_secret.vault) -Name ([string]$ztp.bmc_secret.password_name)
    $bmc = [pscredential]::new($user, $password.SecretValue)
    # The maintenance environment's edgeuser password: the image builder presets it, and the Device stage signs in with it.
    $edgePassword = if ($edgeSecret) { (Get-AzKeyVaultSecret -VaultName $edgeSecret.Vault -Name $edgeSecret.Secret).SecretValue } else { $null }

    Set-AzContext -Tenant $tenant -Subscription $clusterSub -Scope Process -WarningAction SilentlyContinue | Out-Null
    if (-not (Get-AzResourceGroup -Name $rg -ErrorAction SilentlyContinue)) {
        if (-not (ConvertTo-ZtpBoolean (& $setting 'ztp.create_resource_group' $true) 'ztp.create_resource_group')) { throw "Resource group $rg doesn't exist, and provisioning.simplified.create_resource_group is false. Create it first, or set the key to true." }
        New-AzResourceGroup -Name $rg -Location ([string]$env_.azure_resources.location) -Tag $tags | Out-Null
        Write-Output "Created resource group $rg"
    }

    $run = @{
        ConfigPath           = $config
        NodeName             = $Node
        BmcCredential        = $bmc
        ConfirmNotClustered  = $true
        SkipCertificateCheck = (-not (ConvertTo-ZtpBoolean (& $setting 'ztp.verify_bmc_certificate' $false) 'ztp.verify_bmc_certificate'))
        RetryProvisionOs     = (ConvertTo-ZtpBoolean (& $setting 'ztp.retry_provision_os' $true) 'ztp.retry_provision_os')
        Execute              = $true
        Confirm              = $false
    }
    if ($edgePassword) { $run.EdgeUserPassword = $edgePassword }
    if ($From) { $run.From = $From }
    # A run that builds media (from the start, Resolve or Media) is a fresh provisioning, so replace this tool's own images.
    if (-not $From -or $From -in 'Resolve', 'Media') { $run.RebuildImages = $true }
    & $orchestrator @run
}
finally { $null = Stop-Transcript -ErrorAction SilentlyContinue }
