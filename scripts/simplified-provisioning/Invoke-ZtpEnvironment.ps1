#Requires -Version 7.0
#Requires -Modules powershell-yaml
<#
.SYNOPSIS
    One command from an environment file to machines ready to join a cluster, for the nodes you name.
.DESCRIPTION
    Reads infrastructure.yml, writes ZTP's settings, node list and Bicep parameters, creates the cluster resource group,
    reads the iDRAC login from the management vault, finds this server's address as the iDRACs reach it, then runs
    Invoke-ZtpProvisioning.ps1. A failed OS install is resubmitted once automatically. After Ready to cluster, the
    Prepare stage (Initialize-ZtpNode.ps1) installs the OEM's network drivers from the SBE, copies the SBE to C:\SBE, creates the
    deployment admin and leaves one static management address, so the nodes are ready for Validate.

    Without -Execute it writes the generated files and shows ZTP's plan. Nothing changes in Azure or on a node.
    With -Execute it REINSTALLS the named nodes. Run it elevated, because it creates the share, a local account and a
    firewall rule. The signed-in account needs Owner, or Contributor and Role Based Access Control Administrator, on the
    resource group, and rights to delegate on the vault that holds the administrator secret.
.PARAMETER InfrastructureFile
    The environment file.
.PARAMETER Node
    Nodes to provision. Defaults to every node in the environment file.
.PARAMETER From
    Stage to resume from.
.PARAMETER MediaPath
    Where the maintenance ISO, node images (about 4 GB each), vouchers, unpacked drivers and run state are kept. Overrides
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
    [ValidateSet('Resolve', 'Media', 'Boot', 'Bootstrap', 'Vouchers', 'Azure', 'Ready', 'Handoff', 'Prepare')][string]$From,
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
$env_ = Read-ZtpEnvironmentFile -Path $InfrastructureFile
Assert-ZtpEnvironment -Environment $env_ -For Provision -Source $InfrastructureFile
$validator = if ($ValidatorPath) { $ValidatorPath } else { Join-Path (Split-Path (Resolve-Path -LiteralPath $InfrastructureFile)) 'tools\Validate-Infrastructure.ps1' }
if (Test-Path -LiteralPath $validator) {
    $global:LASTEXITCODE = 0
    & $validator -ConfigFile (Resolve-Path -LiteralPath $InfrastructureFile)
    if ($global:LASTEXITCODE -ne 0) { throw "$InfrastructureFile failed validation. Fix it and run again." }
}
elseif ($ValidatorPath) { throw "Validator $ValidatorPath doesn't exist." }
else { Write-Verbose "No validator at $validator; only the built-in key check ran." }

$ztp = $env_.ztp
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
$Node = @(Resolve-ZtpNodeSelection -Environment $env_ -Node $Node)
# The OEM's SBE files named in the environment file: found now, so a wrong folder fails before the long stages.
$sbeZip = (Get-ZtpSbeBundle -Path ([string]$ztp.node_preparation.sbe_bundle)).Zip.FullName
# Opt-in only: use an SBE the OEM hasn't validated with the pinned OS build. The SBE is still the supplied package and
# its hash is still checked; only the OEM's solution-compatibility check is skipped, and the handoff records that.
$allowUnvalidatedSbe = (Get-ZtpEnvValue -Environment $env_ -Path 'ztp.node_preparation.allow_unvalidated_sbe') -eq $true
if ($allowUnvalidatedSbe) {
    Write-Warning "ztp.node_preparation.allow_unvalidated_sbe is true: the SBE in $([string]$ztp.node_preparation.sbe_bundle) is used without checking that the OEM validated it with $([string]$ztp.os_version). The OEM doesn't support this combination; the handoff records compatibilityChecked: false."
}

# Each set of nodes keeps its own state, so proving one node never disturbs another's run.
$runName = $Node -join '+'

# The node list the stages read. bios (hardware.bios merged with the node's own) is applied by the Boot stage.
@{ nodes = @($nodeList | ForEach-Object {
            $entry = [ordered]@{ name = [string]$_.name; service_tag = [string]$_.service_tag; bmc_address = [string]$_.idrac_ip; management_ip = [string]$_.ip_address }
            $bios = Get-ZtpEnvironmentBios -Environment $env_ -Node $_
            if ($bios.Count) { $entry.bios = $bios }
            $entry
        }) } |
    ConvertTo-Json -Depth 5 | Set-Content $nodesFile
$biosPlan = @(foreach ($n in $nodeList) {
        $b = Get-ZtpEnvironmentBios -Environment $env_ -Node $n
        if ($b.Count) { "$($n.name) $(@($b.Keys | ForEach-Object { "$_=$($b[$_])" }) -join ', ')" }
    })
if ($biosPlan) { Write-Output "BIOS set by the Boot stage before the maintenance boot: $($biosPlan -join '; ')." }

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
                ip_assignment = $mgmtMode
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
        configuration_name        = @{ value = 'default' }
        admin_username            = @{ value = [string]$ztp.admin_secret.username }
        admin_secret_name         = @{ value = [string]$ztp.admin_secret.name }
        time_zone                 = @{ value = [string]$ztp.time_zone }
        nodes                     = @{ value = $bicepNodes }
        apply_site_settings       = @{ value = $true }
        use_key_vault_configuration = @{ value = $true }
        assign_provisioning_roles = @{ value = $true }
        assign_hci_rp_role        = @{ value = $true }
        managed_resource_group_name = @{ value = '' }
        network_kind              = @{ value = 'LAN' }
        ip_assignment_type        = @{ value = 'Automatic' }
        ipv4                      = @{ value = @{} }
        ntp_configuration_choice  = @{ value = 'Automatic' }
        ntp_server                = @{ value = '' }
        alternate_ntp_server      = @{ value = '' }
        connectivity_type         = @{ value = 'Public' }
    }
}
$bicepParameters | ConvertTo-Json -Depth 10 | Set-Content $parameters

[ordered]@{
    BootstrapCacheDirectory        = (Resolve-Path $media).Path
    BootstrapVersion               = [string]$ztp.provisioning_iso
    IncludePreview                 = $false
    Oem                            = [string]$env_.hardware.vendor
    SbeModel                       = ([string]$env_.hardware.model -replace '-', '')
    # The SBE in ztp.node_preparation.sbe_bundle, so the handoff's SBE values match what Prepare copies to C:\SBE,
    # checked for compatibility with the pinned OS build unless ztp.node_preparation.allow_unvalidated_sbe is true.
    SbeSolutionVersion             = $(if ($allowUnvalidatedSbe) { 'latest' } else { [string]$ztp.os_version })
    SbePackagePath                 = $sbeZip
    NodesFile                      = $nodesFile
    ImageDirectory                 = Join-Path (Resolve-Path $media).Path 'ztp-virtual-usb'
    ImageNamePrefix                = 'ztp-usb-'
    ShareHost                      = $shareHost
    ShareName                      = [string]$ztp.share_name
    VoucherDirectory               = Join-Path (Resolve-Path $media).Path 'vouchers'
    VoucherWaitMinutes             = 120
    RfsWriteAttribute              = $true
    SkipCertificateCheck           = $true
    EventLogPath                   = $events
    BootstrapTimeoutMinutes        = 120
    BootstrapVoucherTimeoutMinutes = 90
    SkipAzureCheck                 = $false
    Location                       = [string]$env_.azure_resources.location
    SubscriptionId                 = $clusterSub
    ResourceGroupName              = $rg
    ParameterFile                  = $parameters
    OsVersion                      = [string]$ztp.os_version
    SiteMode                       = 'Auto'
    DeploymentName                 = "ztp-$([string]$ztp.site_name)"
    ArcMachineNameMapPath          = Join-Path $state "$runName.arc-machine-names.json"
    ReadyTimeoutMinutes            = 180
    PollIntervalSeconds            = 60
    HandoffPath                    = Join-Path $state "$runName.ztp-handoff.json"
    ClusterInputsPath              = Join-Path $state "$runName.ztp-cluster-inputs.yaml"
    StatePath                      = Join-Path $state "$runName.ztp-provisioning.state.json"
} | ConvertTo-Json | Set-Content $config

$orchestrator = Join-Path $PSScriptRoot 'Invoke-ZtpProvisioning.ps1'
# After Ready to cluster: drivers, SBE files, deployment admin and one management address, so the nodes pass Validate.
$prepare = Join-Path $PSScriptRoot 'Initialize-ZtpNode.ps1'
$driverStaging = Join-Path $media 'sbe-drivers'
if (-not $Execute) {
    if ($From -eq 'Prepare') { & $prepare -InfrastructureFile $InfrastructureFile -Node $Node -DriverStagingPath $driverStaging -EventLogPath $events; return }
    & $orchestrator -ConfigPath $config -NodeName $Node
    Write-Output '--- Prepare (after Ready to cluster)'
    try { & $prepare -InfrastructureFile $InfrastructureFile -Node $Node -DriverStagingPath $driverStaging -EventLogPath $events } catch { Write-Warning $_.Exception.Message }
    return
}

# A run that changes things leaves its transcript with the evidence. Nothing secret is written to the output.
$transcript = Join-Path $evidence ("$runName.{0}.transcript.log" -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
$null = Start-Transcript -LiteralPath $transcript -IncludeInvocationHeader
try {
    if ($From -eq 'Prepare') {
        & $prepare -InfrastructureFile $InfrastructureFile -Node $Node -DriverStagingPath $driverStaging -EventLogPath $events -Execute
        return
    }

    Set-AzContext -Tenant $tenant -Subscription $vaultSub -Scope Process -WarningAction SilentlyContinue | Out-Null
    $user = Get-AzKeyVaultSecret -VaultName ([string]$ztp.bmc_secret.vault) -Name ([string]$ztp.bmc_secret.username_name) -AsPlainText
    $password = Get-AzKeyVaultSecret -VaultName ([string]$ztp.bmc_secret.vault) -Name ([string]$ztp.bmc_secret.password_name)
    $bmc = [pscredential]::new($user, $password.SecretValue)

    Set-AzContext -Tenant $tenant -Subscription $clusterSub -Scope Process -WarningAction SilentlyContinue | Out-Null
    if (-not (Get-AzResourceGroup -Name $rg -ErrorAction SilentlyContinue)) {
        New-AzResourceGroup -Name $rg -Location ([string]$env_.azure_resources.location) -Tag $tags | Out-Null
        Write-Output "Created resource group $rg"
    }

    $run = @{
        ConfigPath           = $config
        NodeName             = $Node
        BmcCredential        = $bmc
        ConfirmNotClustered  = $true
        SkipCertificateCheck = $true
        RetryProvisionOs     = $true
        Execute              = $true
        Confirm              = $false
    }
    if ($From) { $run.From = $From }
    # A run that builds media (from the start, Resolve or Media) is a fresh provisioning, so replace this tool's own images.
    if (-not $From -or $From -in 'Resolve', 'Media') { $run.RebuildImages = $true }
    & $orchestrator @run
    & $prepare -InfrastructureFile $InfrastructureFile -Node $Node -DriverStagingPath $driverStaging -EventLogPath $events -Execute
}
finally { $null = Stop-Transcript -ErrorAction SilentlyContinue }
