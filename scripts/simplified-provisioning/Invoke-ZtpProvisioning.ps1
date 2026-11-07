#Requires -Version 7.0
<#
.SYNOPSIS
Zero-touch provisioning of Azure Local machines, end to end: Resolve -> Media -> Boot -> Bootstrap -> Vouchers -> Device -> Azure -> Ready -> Network -> Restore -> Handoff.
.DESCRIPTION
One orchestrator over the stage scripts in this folder. Every input is a parameter, or a key of the same name in a JSON
settings file (-ConfigPath; see config/simplified-provisioning/ztp-provisioning.example.json). A parameter wins over the
file; nothing is hardcoded.
  Resolve   Get-ZtpBootstrapIso.ps1: finds, downloads and verifies the newest maintenance ISO into -BootstrapCacheDirectory;
            its version, URL and SHA256 go to the stage evidence. Runs only when -BootstrapCacheDirectory is set; otherwise
            -SourcePath must name the ISO and the stage is recorded as skipped. ZTP doesn't resolve or stage an SBE: the OS
            install discovers its own (the ProvisionOs job's SBEDiscoveryDownload step), and staging one is OS configuration.
  Media     New-ZtpVirtualUsbImage.ps1 -NodeName: one virtual-USB image per node (<ImageNamePrefix><node>.img in
            -ImageDirectory) from the maintenance ISO (-SourcePath), GPT with one FAT32 partition labelled CDROM.
  Boot      Start-MaintenanceBoot.ps1: sets each node's BIOS attributes from the node list's bios first (Set-ZtpBios.ps1:
            only what differs, applied at a reset, logged to bios-changes.jsonl beside -EventLogPath),
            shares the images read-write in place (one account, TCP 445 only from the BMCs),
            inserts each node's image on the BMC USB-stick slot read-write, proves the attach, sets a one-time boot to
            that slot and power-cycles every node at once (iDRAC 7.30: the RFS write attribute and the vFDD / Once-Floppy
            boot, see Mount-ZtpVirtualUsb.ps1). Needs -ConfirmNotClustered: the maintenance environment
            reinstalls the machine.
  Bootstrap Wait-ZtpBootstrapComplete.ps1: one read-only watch over Redfish power, boot and virtual-media state, the BMC log, the
            voucher in the image and the Azure prerequisites; structured events go to -EventLogPath (Mounted, Booting,
            MaintenanceEnvironmentRunning, VoucherWritten, ReadyForPortal). Every node must reach ReadyForPortal.
  Vouchers  Wait-ZtpVoucher.ps1: waits until the maintenance environment wrote \vouchers\<serial>\*.pem into each image,
            ejects the media, writes <serial>.pem into -VoucherDirectory. -VoucherFolder takes vouchers downloaded with
            the Configurator App instead (it only works if the USB export did not happen). Then the share, its firewall
            rule and account are removed (-KeepShare keeps them).
  Device    Set-ZtpDeviceConfiguration.ps1: in the maintenance environment, before the claim, sets each static management
            address on the port with the node's management MAC through the Configurator App's REST service
            (https://<maintenance address>:20001/BootstrapOobeService, edgeuser and -EdgeUserPassword, default Password1).
            A static node without a maintenance_address is found by scanning its maintenance_scan_range (else the management
            subnet) on TCP 20001 and matching its management MAC; dhcp and preconfigured nodes without one are skipped.
            Changes are logged to device-changes.jsonl beside -EventLogPath.
  Azure     Invoke-ZtpAzureProvisioning.ps1 stages Prereqs, Validate, Plan, Execute: site, site configuration and edge
            machines claimed with the vouchers. Refuses to submit when a voucher is missing.
  Ready     Invoke-ZtpAzureProvisioning.ps1 -Stage Watch: waits until every machine is ready to cluster and returns (or,
            with -ArcMachineNameMapPath, writes) each node's Arc machine name; then Test-ProvisionedMachines.ps1.
  Network   Set-ZtpManagementAddress.ps1, verify-only: reads each edge machine's networkAdapters report, finds the
            management port by MAC and compares it with the file (static: the address, Static; dhcp_reservation: the
            address, or any DHCP address without one; dhcp and preconfigured: reported only). Each node's result
            (managementAddressVerified and a reason) is recorded in the state file for the handoff. A static address the
            OS install reset to DHCP (it resets every port) is Deferred: OS configuration sets it by MAC. Nothing is
            changed and no Microsoft job is waited on. -ApplyThroughAzure (opt-in, unreliable: the job never started on two
            live runs) moves a static address through jobs/ApplyConfiguration instead, logs the changes to
            network-changes.jsonl beside -EventLogPath, and fails the stage when a static address isn't set.
  Restore   Restore-ZtpBios.ps1: sets each BIOS value changed for the install only (the node list's bios_restore, from
            bios_during_provisioning) back to hardware.bios or to the value the Boot stage saved in the state file before
            changing it; PATCH OnReset, restart through Redfish, wait until the BIOS reports them. Then, after
            -RestoreSettleMinutes, waits until every Arc machine is Connected and every edge machine still ready to cluster
            (the Ready stage's watch and check). Events: stage Restore, BiosRestoreStarted, BiosRestored, BiosRestoreFailed.
            Without bios_during_provisioning it is a no-op that says so.
  Handoff   New-ZtpHandoff.ps1 writes -HandoffPath (ztp-handoff.json: only what Azure generated during ZTP: edge machine
            and Arc machine names and IDs, the site, the installed solution version, each node's Network result and the BIOS
            values Restore set back); Convert-ZtpHandoffToClusterInputs.ps1 writes -ClusterInputsPath (the arc_machine_names
            block for the cluster deployment environment file). Nothing is clustered here.
ZTP ends here: each machine is Provisioned in Azure and Arc-connected, and the handoff says whether its management address
is verified on the management port (by MAC). OS configuration (the static management address by MAC, OEM drivers, the SBE
in C:\SBE, DHCP and the gateway off on the other ports, DNS and time, the deployment admin) comes next, before Validate and Deploy: azurelocal-toolkit Phase 03, documented at
https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/.
Plan by default: without -Execute the stage table and the command of every stage are printed, and the next stage shows its
own plan (Media, Boot, Device, Azure, Network and Restore have a plan mode; Vouchers and Ready are waits). Nothing changes.
With -Execute each stage runs, its result is checked (an image per node, every node booted read-write, a valid voucher per
node, deployment accepted, every node ready and its Arc machine verified) and recorded in the state file; the next stage
starts only after that. A rerun resumes at the first stage that did not complete. -Stage runs one stage again; -From runs
a stage and every later one again; -ResetState forgets the recorded stages.
.PARAMETER Stage
One stage to run (again), or All (resume from the state file).
.PARAMETER From
Run this stage and every later stage, whatever the state file says.
.PARAMETER ConfigPath
JSON settings file whose keys are parameter names of this script (no secrets: credentials and passwords are parameters).
.PARAMETER NodesFile
Node list (name, service_tag, bmc_address); see config/simplified-provisioning/nodes.example.json.
.PARAMETER NodeName
Nodes to provision (default: every node in -NodesFile).
.PARAMETER SourcePath
Maintenance ISO from the Microsoft download, or a folder with its extracted contents.
.PARAMETER BootstrapCacheDirectory
Resolve: download cache of the maintenance ISO. Empty = no Resolve; -SourcePath must name the ISO.
.PARAMETER BootstrapVersion
Resolve: latest (default), a train (2610), a build or a Microsoft download URL.
.PARAMETER IncludePreview
Resolve: also consider preview trains.
.PARAMETER MaxBootstrapTrain
Resolve: highest train to consider.
.PARAMETER Oem
OEM definition in config/oem (default Dell): the BMC log services and signals the Bootstrap watch reads.
.PARAMETER EventLogPath
Bootstrap: JSON-lines event file (Sonar follows it).
.PARAMETER BootstrapTimeoutMinutes
Bootstrap: overall budget.
.PARAMETER BootstrapVoucherTimeoutMinutes
Bootstrap: budget until a valid voucher appears.
.PARAMETER SkipAzureCheck
Bootstrap: do not check the Azure prerequisites (feature, providers, catalog).
.PARAMETER Location
Bootstrap: region of the catalog check (preview: eastus).
.PARAMETER HandoffPath
Handoff: ztp-handoff.json.
.PARAMETER ClusterInputsPath
Handoff: arc_machine_names block for the cluster deployment environment file (.yaml or .json).
.PARAMETER ImageDirectory
Folder of the per-node images; shared in place to the BMCs.
.PARAMETER ImageNamePrefix
Image file-name prefix.
.PARAMETER ShareHost
Address of this host as the BMCs reach it.
.PARAMETER ShareName
SMB share of the images.
.PARAMETER VoucherDirectory
Where <serial>.pem are written (Vouchers) and read (Azure).
.PARAMETER VoucherFolder
Fallback: folder with vouchers downloaded with the Configurator App.
.PARAMETER VoucherWaitMinutes
Vouchers wait budget.
.PARAMETER BmcCredential
BMC account (Boot, Vouchers eject).
.PARAMETER EdgeUserPassword
Optional password of the maintenance environment's edgeuser account (only its SHA-512 crypt hash enters the image). The
Device stage signs in with it; without it, with the maintenance environment's default Password1.
.PARAMETER RfsWriteAttribute
Also set the iDRAC RFS WriteProtected attributes to Read Write before the insert.
.PARAMETER ConfirmNotClustered
Required for the Boot stage with -Execute: confirms the machines carry no cluster to keep.
.PARAMETER SkipCertificateCheck
Accept the BMCs' self-signed certificates.
.PARAMETER RebuildImages
Media: replace existing image files (never after Boot: the images then hold the vouchers).
.PARAMETER KeepShare
Vouchers: keep the read-write share, firewall rule and account.
.PARAMETER SubscriptionId
Azure subscription of the site and the edge machines.
.PARAMETER ResourceGroupName
Resource group of the site and the edge machines.
.PARAMETER ParameterFile
ARM parameters (.json) or .bicepparam for bicep/main.bicep; see bicep/main.example.parameters.json.
.PARAMETER OsVersion
latest, latest-preview or a validated solution recipe version.
.PARAMETER SiteMode
Auto (create what is missing), Create, Reuse.
.PARAMETER DeploymentName
ARM deployment name.
.PARAMETER AdminPassword
Provisioning administrator password, written to the Key Vault only when its secret is missing.
.PARAMETER RetryProvisionOs
Ready: resubmit a failed jobs/ProvisionOs once (with -Execute).
.PARAMETER ArcMachineNameMapPath
Ready: JSON file that receives node -> Arc machine name (with -Execute).
.PARAMETER ReadyTimeoutMinutes
Ready: polling budget.
.PARAMETER PollIntervalSeconds
Ready and Network: poll interval.
.PARAMETER DeviceTimeoutMinutes
Device: how long the maintenance environment may take to report the static address.
.PARAMETER NetworkTimeoutMinutes
Network with -ApplyThroughAzure: how long each ApplyConfiguration job may take, and then the adapter to report its result.
.PARAMETER ApplyThroughAzure
Network: opt-in, unreliable. Move a static management address that isn't on the management port there through Azure's
jobs/ApplyConfiguration, and fail the stage when it isn't set. On two live runs (Dell AX-760, build 2610) the job never
started ("Job is not yet triggered as other jobs are still running") and Azure marked it Failed after about 35 minutes.
Without it the stage only verifies, and OS configuration sets the address.
.PARAMETER RestoreSettleMinutes
Restore: how long to wait after the BIOS restart before checking that the Arc machines are Connected again (an Arc
machine reads Connected for a while after its host went down). The check then needs a new connection: the machine's
LastStatusChange after the restart (Test-ProvisionedMachines.ps1 -ConnectedSince), repeated every -PollIntervalSeconds for up to
-ReadyTimeoutMinutes.
.PARAMETER BiosTimeoutMinutes
Boot and Restore: how long to wait for a node's BIOS to report the new values after the restart.
.PARAMETER BootstrapStallMinutes
Bootstrap: how long the BMC may show no change before the watch reports a stall (default: the stage script's 20).
.PARAMETER ImageSizeGB
Media: size of each virtual USB image in GiB (0 = the stage script's 4).
.PARAMETER ShareAccountName
Boot and Vouchers: the local account the BMCs sign in to the share with (default: the stage script's svc-ztp-media).
.PARAMETER MaintenancePort
Device: TCP port of the maintenance environment's Configurator service (0 = the stage script's 20001).
.PARAMETER MaintenanceUser
Device: the Configurator service's user name (default: the stage script's edgeuser).
.PARAMETER StatePath
Run state file (default ./ztp-provisioning.state.json).
.PARAMETER ResetState
Forget the recorded stages before this run.
.PARAMETER StageScriptRoot
Folder of the stage scripts (default: this folder). Tests point it at stubs.
.PARAMETER Execute
Change the machines, this host's share and Azure. Without it only the plan is shown.
.EXAMPLE
./Invoke-ZtpProvisioning.ps1 -ConfigPath ./ztp-provisioning.json
.EXAMPLE
./Invoke-ZtpProvisioning.ps1 -ConfigPath ./ztp-provisioning.json -BmcCredential $bmc -AdminPassword $admin -ConfirmNotClustered -SkipCertificateCheck -Execute
.EXAMPLE
./Invoke-ZtpProvisioning.ps1 -ConfigPath ./ztp-provisioning.json -BmcCredential $bmc -Stage Vouchers -VoucherFolder D:\Downloads\vouchers -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Resolve', 'Media', 'Boot', 'Bootstrap', 'Vouchers', 'Device', 'Azure', 'Ready', 'Network', 'Restore', 'Handoff', 'All')][string]$Stage = 'All',
    [ValidateSet('Resolve', 'Media', 'Boot', 'Bootstrap', 'Vouchers', 'Device', 'Azure', 'Ready', 'Network', 'Restore', 'Handoff')][string]$From,
    [string]$ConfigPath,
    [string]$NodesFile,
    [string[]]$NodeName,
    [string]$SourcePath,
    [string]$BootstrapCacheDirectory,
    [string]$BootstrapVersion = 'latest',
    [switch]$IncludePreview,
    [ValidatePattern('^$|^\d{4}$')][string]$MaxBootstrapTrain,
    [ValidatePattern('^[A-Za-z0-9_-]{1,40}$')][string]$Oem = 'Dell',
    [string]$EventLogPath = (Join-Path (Get-Location) 'ztp-events.jsonl'),
    [ValidateRange(1, 1440)][int]$BootstrapTimeoutMinutes = 120,
    [ValidateRange(1, 1440)][int]$BootstrapVoucherTimeoutMinutes = 90,
    [switch]$SkipAzureCheck,
    [string]$Location = 'eastus',
    [string]$HandoffPath = (Join-Path (Get-Location) 'ztp-handoff.json'),
    [string]$ClusterInputsPath = (Join-Path (Get-Location) 'ztp-cluster-inputs.yaml'),
    [string]$ImageDirectory,
    [ValidatePattern('^[A-Za-z0-9._-]{0,40}$')][string]$ImageNamePrefix = 'ztp-usb-',
    [string]$ShareHost,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,79}$')][string]$ShareName = 'ztp-virtual-usb',
    [string]$VoucherDirectory,
    [string]$VoucherFolder,
    [ValidateRange(0, 1440)][int]$VoucherWaitMinutes = 120,
    [pscredential]$BmcCredential,
    [securestring]$EdgeUserPassword,
    [switch]$RfsWriteAttribute,
    [switch]$ConfirmNotClustered,
    [switch]$SkipCertificateCheck,
    [switch]$RebuildImages,
    [switch]$KeepShare,
    [string]$SubscriptionId,
    [string]$ResourceGroupName,
    [string]$ParameterFile,
    [string]$OsVersion = 'latest',
    [ValidateSet('Auto', 'Create', 'Reuse')][string]$SiteMode = 'Auto',
    [string]$DeploymentName = 'ztp-provisioning',
    [securestring]$AdminPassword,
    [switch]$RetryProvisionOs,
    [string]$ArcMachineNameMapPath,
    [ValidateRange(0, 1440)][int]$ReadyTimeoutMinutes = 180,
    [ValidateRange(0, 3600)][int]$PollIntervalSeconds = 60,
    [ValidateRange(0, 1440)][int]$DeviceTimeoutMinutes = 30,
    [ValidateRange(0, 1440)][int]$NetworkTimeoutMinutes = 60,
    [switch]$ApplyThroughAzure,
    [ValidateRange(0, 120)][int]$RestoreSettleMinutes = 5,
    [ValidateRange(1, 240)][int]$BiosTimeoutMinutes = 30,
    [ValidateRange(0, 240)][int]$BootstrapStallMinutes = 0,
    [ValidateRange(0, 128)][int]$ImageSizeGB = 0,
    [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9_-]{0,19}$')][string]$ShareAccountName,
    [ValidateRange(0, 65535)][int]$MaintenancePort = 0,
    [string]$MaintenanceUser,
    [string]$StatePath = (Join-Path (Get-Location) 'ztp-provisioning.state.json'),
    [switch]$ResetState,
    [string]$StageScriptRoot = $PSScriptRoot,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpVirtualUsb.Common.ps1')
. (Join-Path $PSScriptRoot 'ZtpEvents.Common.ps1')

$order = @('Resolve', 'Media', 'Boot', 'Bootstrap', 'Vouchers', 'Device', 'Azure', 'Ready', 'Network', 'Restore', 'Handoff')
function Write-ZtpRunLog {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message, [ValidateSet('Info', 'Warning')][string]$Level = 'Info')
    $line = "[$([datetime]::UtcNow.ToString('HH:mm:ss'))Z] [ztp] $Message"
    if ($Level -eq 'Warning') { Write-Warning $line } else { Write-Information -MessageData $line -InformationAction Continue }
}

# ------------------------------------------------------------------ settings: parameter > -ConfigPath > default
$settable = @('BootstrapCacheDirectory', 'BootstrapVersion', 'IncludePreview', 'MaxBootstrapTrain', 'Oem',
    'EventLogPath', 'BootstrapTimeoutMinutes', 'BootstrapVoucherTimeoutMinutes', 'SkipAzureCheck', 'Location', 'HandoffPath', 'ClusterInputsPath',
    'NodesFile', 'NodeName', 'SourcePath', 'ImageDirectory', 'ImageNamePrefix', 'ShareHost', 'ShareName', 'VoucherDirectory',
    'VoucherFolder', 'VoucherWaitMinutes', 'RfsWriteAttribute', 'SkipCertificateCheck', 'KeepShare', 'SubscriptionId', 'ResourceGroupName',
    'ParameterFile', 'OsVersion', 'SiteMode', 'DeploymentName', 'ArcMachineNameMapPath', 'ReadyTimeoutMinutes', 'PollIntervalSeconds', 'DeviceTimeoutMinutes', 'NetworkTimeoutMinutes', 'ApplyThroughAzure', 'RestoreSettleMinutes', 'BiosTimeoutMinutes', 'BootstrapStallMinutes', 'ImageSizeGB', 'ShareAccountName', 'MaintenancePort', 'MaintenanceUser', 'StatePath')
# Settings of the SBE selection ZTP no longer does: an older settings file may still carry them.
$retired = @('SbeModel', 'SbeFamily', 'SbeSolutionVersion', 'SbePackagePath')
if ($ConfigPath) {
    $settings = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
    foreach ($key in $settings.Keys) {
        if ($key -eq '$schema') { continue }
        if ($key -in $retired) { Write-ZtpRunLog "$key in ${ConfigPath} ignored: SBE belongs to OS configuration."; continue }
        if ($key -notin $settable) { throw "Unknown key '$key' in $ConfigPath. Keys: $($settable -join ', ')." }
        if ($PSBoundParameters.ContainsKey($key)) { continue }
        $value = $settings[$key]
        if ($key -in 'RfsWriteAttribute', 'SkipCertificateCheck', 'KeepShare', 'IncludePreview', 'SkipAzureCheck', 'ApplyThroughAzure') { $value = [switch][bool]$value }
        Set-Variable -Name $key -Value $value
    }
}
if (-not $NodesFile) { throw 'Pass -NodesFile (or NodesFile in -ConfigPath); see config/simplified-provisioning/nodes.example.json.' }
$known = @(Get-ZtpNodeList -NodesFile $NodesFile)
if (-not $NodeName) { $NodeName = @($known.Name) }
$null = Get-ZtpNodeList -NodesFile $NodesFile -NodeName $NodeName -RequireSerial

# ------------------------------------------------------------------ state
$state = [ordered]@{ orchestrator = 'Invoke-ZtpProvisioning'; version = 1; nodes = @(); stages = [ordered]@{} }
if (-not $ResetState -and (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -AsHashtable
    if (-not $state -or $state['orchestrator'] -ne 'Invoke-ZtpProvisioning' -or [int]$state['version'] -ne 1) { throw "State file $StatePath belongs to something else. Pass another -StatePath or -ResetState." }
    $recorded = @($state['nodes'] | Sort-Object)
    if ($recorded.Count -gt 0 -and @($state['stages'].Keys).Count -gt 0 -and (Compare-Object $recorded @($NodeName | Sort-Object))) {
        throw "State file $StatePath records nodes $($recorded -join ', '); this run names $($NodeName -join ', '). Use the same nodes, another -StatePath, or -ResetState."
    }
}
function Save-ZtpRunState {
    $state['updated'] = [datetime]::UtcNow.ToString('o')
    $folder = Split-Path -Parent $StatePath
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
    $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$StatePath.tmp" -Encoding utf8NoBOM
    Move-Item -LiteralPath "$StatePath.tmp" -Destination $StatePath -Force
}
if (-not $SourcePath -and $state['stages'].Contains('Resolve') -and $state['stages']['Resolve'] -is [System.Collections.IDictionary] -and $state['stages']['Resolve'].Contains('data') -and $state['stages']['Resolve']['data'] -and $state['stages']['Resolve']['data']['isoPath']) {
    $SourcePath = [string]$state['stages']['Resolve']['data']['isoPath']
}
$run = @(if ($Stage -ne 'All') {
    if ($From) { throw 'Pass -Stage or -From, not both.' }
    @($Stage)
}
elseif ($From) { @($order[([array]::IndexOf($order, $From))..($order.Count - 1)]) }
else {
    $first = @($order | Where-Object { -not $state['stages'].Contains($_) } | Select-Object -First 1)
    if ($first.Count -eq 0) { @() } else { @($order[([array]::IndexOf($order, $first[0]))..($order.Count - 1)]) }
})

# ------------------------------------------------------------------ BIOS restore
# The node list's bios_restore (attribute -> final value, or '' for the value before Boot) of the nodes in this run.
function Get-ZtpRestoreNeed {
    if (-not $NodesFile -or -not (Test-Path -LiteralPath $NodesFile)) { return @() }
    $doc = Get-Content -LiteralPath $NodesFile -Raw | ConvertFrom-Json -AsHashtable
    @(foreach ($n in @($doc['nodes'])) { if ($n -is [System.Collections.IDictionary] -and [string]$n['name'] -in $NodeName -and $n['bios_restore'] -is [System.Collections.IDictionary] -and $n['bios_restore'].Count) { [string]$n['name'] } })
}
function Get-ZtpBiosOriginal {
    if ($state.Contains('biosOriginal') -and $state['biosOriginal'] -is [System.Collections.IDictionary]) { return $state['biosOriginal'] }
    return [ordered]@{}
}

# ------------------------------------------------------------------ stage calls
function Get-ZtpRecordedStageData {
    # The data a stage recorded in the state file (stages.<name>.data), or $null.
    param([Parameter(Mandatory)][string]$Name)
    if ($state['stages'].Contains($Name) -and $state['stages'][$Name] -is [System.Collections.IDictionary] -and $state['stages'][$Name].Contains('data') -and $state['stages'][$Name]['data'] -is [System.Collections.IDictionary]) { return $state['stages'][$Name]['data'] }
    return $null
}
function Get-ZtpBootstrapBaseline {
    # What the Bootstrap watch needs to tell this run's voucher from a left-over one: when Media built each node's image
    # (stages.Media.data.images.<node>.builtAt) and when Boot reset the node onto it (stages.Boot.data.resetAt.<node>). A node
    # whose image Media did not build in this run, or that Boot did not reset in this run, has no entry.
    $built = @{}; $reset = @{}; $empty = @{}
    $media = Get-ZtpRecordedStageData -Name 'Media'
    if ($media -and $media.Contains('images') -and $media['images'] -is [System.Collections.IDictionary]) {
        foreach ($node in $NodeName) {
            $entry = if ($media['images'].Contains($node)) { $media['images'][$node] } else { $null }
            if ($entry -is [System.Collections.IDictionary] -and $entry.Contains('builtAt') -and $entry['builtAt']) { $built[$node] = $entry['builtAt'] }
            # Read right after the build: was the voucher slot empty? Absent in a state file from before the field.
            if ($entry -is [System.Collections.IDictionary] -and $entry.Contains('voucherEmptyAtBuild') -and $entry['voucherEmptyAtBuild'] -is [bool]) { $empty[$node] = $entry['voucherEmptyAtBuild'] }
        }
    }
    $boot = Get-ZtpRecordedStageData -Name 'Boot'
    if ($boot -and $boot.Contains('resetAt') -and $boot['resetAt'] -is [System.Collections.IDictionary]) {
        foreach ($node in $NodeName) { if ($boot['resetAt'].Contains($node) -and $boot['resetAt'][$node]) { $reset[$node] = $boot['resetAt'][$node] } }
    }
    return @{ ImageBuiltAt = $built; ResetAt = $reset; ImageEmptyAtBuild = $empty }
}
function Get-ZtpStageCall {
    param([Parameter(Mandatory)][string]$Name, [switch]$ForExecute)
    $calls = [System.Collections.Generic.List[object]]::new()
    $act = { param($p) if ($ForExecute) { $p.Execute = $true; $p.Confirm = $false } }
    $actPlain = { param($p) if ($ForExecute) { $p.Execute = $true } }
    switch ($Name) {
        'Resolve' {
            if ($BootstrapCacheDirectory) {
                $p = [ordered]@{ Version = $BootstrapVersion; CacheDirectory = $BootstrapCacheDirectory }
                if ($IncludePreview) { $p.IncludePreview = $true }
                if ($MaxBootstrapTrain) { $p.MaxTrain = $MaxBootstrapTrain }
                & $actPlain $p
                $calls.Add([pscustomobject]@{ Script = 'Get-ZtpBootstrapIso.ps1'; Parameters = $p })
            }
        }
        'Bootstrap' {
            $p = [ordered]@{ NodeName = $NodeName; NodesFile = $NodesFile; Oem = $Oem; EventLogPath = $EventLogPath; TimeoutMinutes = $BootstrapTimeoutMinutes; VoucherTimeoutMinutes = $BootstrapVoucherTimeoutMinutes }
            if ($VoucherFolder) { $p.VoucherFolder = $VoucherFolder } else { $p.ImageDirectory = $ImageDirectory; $p.ImageNamePrefix = $ImageNamePrefix }
            if ($BmcCredential -and -not $VoucherFolder) { $p.Credential = $BmcCredential }
            if (-not $VoucherFolder) {
                # A voucher written after this run's image build and node reset belongs to this run, even when the node was fast
                # enough to write it while the Boot stage was still watching the BMC.
                $baseline = Get-ZtpBootstrapBaseline
                if ($baseline.ImageBuiltAt.Count) { $p.ImageBuiltAt = $baseline.ImageBuiltAt }
                if ($baseline.ResetAt.Count) { $p.ResetAt = $baseline.ResetAt }
                if ($baseline.ImageEmptyAtBuild.Count) { $p.ImageEmptyAtBuild = $baseline.ImageEmptyAtBuild }
            }
            if ($BootstrapStallMinutes) { $p.StallMinutes = $BootstrapStallMinutes }
            if ($RfsWriteAttribute) { $p.RfsWriteAttribute = $true }
            if ($SkipCertificateCheck) { $p.SkipCertificateCheck = $true }
            if ($SkipAzureCheck) { $p.SkipAzureCheck = $true } else { $p.SubscriptionId = $SubscriptionId; $p.Location = $Location }
            & $actPlain $p
            $calls.Add([pscustomobject]@{ Script = 'Wait-ZtpBootstrapComplete.ps1'; Parameters = $p })
        }
        'Device' {
            $p = [ordered]@{ ParameterFile = $ParameterFile; NodesFile = $NodesFile; Node = $NodeName; TimeoutMinutes = $DeviceTimeoutMinutes; PollIntervalSeconds = $PollIntervalSeconds; EventLogPath = $EventLogPath }
            if ($EdgeUserPassword) { $p.EdgeUserPassword = $EdgeUserPassword }
            if ($MaintenancePort) { $p.Port = $MaintenancePort }
            if ($MaintenanceUser) { $p.UserName = $MaintenanceUser }
            # Device changes are evidence: they go beside the event log, as the BIOS and adapter changes do.
            if ($EventLogPath) { $p.ChangeLogPath = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($EventLogPath))) 'device-changes.jsonl' }
            & $act $p
            $calls.Add([pscustomobject]@{ Script = 'Set-ZtpDeviceConfiguration.ps1'; Parameters = $p })
        }
        'Network' {
            $p = [ordered]@{ SubscriptionId = $SubscriptionId; ResourceGroupName = $ResourceGroupName; ParameterFile = $ParameterFile; Node = $NodeName; TimeoutMinutes = $NetworkTimeoutMinutes; PollIntervalSeconds = $PollIntervalSeconds; EventLogPath = $EventLogPath }
            # Verify-only unless -ApplyThroughAzure. Adapter changes (only with it) are evidence: they go beside the event
            # log, as the BIOS changes do.
            if ($ApplyThroughAzure) { $p.ApplyThroughAzure = $true }
            if ($EventLogPath) { $p.ChangeLogPath = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($EventLogPath))) 'network-changes.jsonl' }
            & $act $p
            $calls.Add([pscustomobject]@{ Script = 'Set-ZtpManagementAddress.ps1'; Parameters = $p })
        }
        'Restore' {
            $p = [ordered]@{ NodeName = $NodeName; NodesFile = $NodesFile; Original = (Get-ZtpBiosOriginal); TimeoutMinutes = $BiosTimeoutMinutes }
            if ($BmcCredential) { $p.Credential = $BmcCredential }
            if ($ConfirmNotClustered) { $p.ConfirmNotClustered = $true }
            if ($SkipCertificateCheck) { $p.SkipCertificateCheck = $true }
            if ($EventLogPath) { $p.EventLogPath = $EventLogPath; $p.BiosLogPath = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($EventLogPath))) 'bios-changes.jsonl' }
            & $act $p
            $calls.Add([pscustomobject]@{ Script = 'Restore-ZtpBios.ps1'; Parameters = $p })
        }
        'Handoff' {
            # Each node's Network result, as the Network stage recorded it in the state file. A node without one is
            # reported as not verified by the handoff.
            $recorded = if ($state['stages'].Contains('Network') -and $state['stages']['Network'] -is [System.Collections.IDictionary] -and $state['stages']['Network'].Contains('data') -and $state['stages']['Network']['data']) { $state['stages']['Network']['data']['managementAddress'] } else { $null }
            $network = @(@($recorded) | Where-Object { $null -ne $_ })
            $p = [ordered]@{ SubscriptionId = $SubscriptionId; ResourceGroupName = $ResourceGroupName; NodeName = $NodeName; NodesFile = $NodesFile; HandoffPath = $HandoffPath }
            if ($network.Count) { $p.ManagementAddressCheck = $network }
            # The BIOS values the Restore stage set back, per node.
            if ($state['stages'].Contains('Restore') -and $state['stages']['Restore'] -is [System.Collections.IDictionary] -and $state['stages']['Restore'].Contains('data') -and $state['stages']['Restore']['data'] -and $state['stages']['Restore']['data']['restored'] -is [System.Collections.IDictionary] -and $state['stages']['Restore']['data']['restored'].Count) { $p.RestoredBios = $state['stages']['Restore']['data']['restored'] }
            & $actPlain $p
            $calls.Add([pscustomobject]@{ Script = 'New-ZtpHandoff.ps1'; Parameters = $p })
            $c = [ordered]@{ HandoffPath = $HandoffPath; OutputPath = $ClusterInputsPath; Format = $(if ($ClusterInputsPath -like '*.json') { 'Json' } else { 'Yaml' }) }
            $calls.Add([pscustomobject]@{ Script = 'Convert-ZtpHandoffToClusterInputs.ps1'; Parameters = $c })
        }
        'Media' {
            $p = [ordered]@{ SourcePath = $SourcePath; NodeName = $NodeName; OutputDirectory = $ImageDirectory; ImageNamePrefix = $ImageNamePrefix }
            if ($ImageSizeGB) { $p.SizeBytes = [long]$ImageSizeGB * 1GB }
            if ($EdgeUserPassword) { $p.EdgeUserPassword = $EdgeUserPassword }
            if ($RebuildImages) { $p.Force = $true }
            & $act $p
            $calls.Add([pscustomobject]@{ Script = 'New-ZtpVirtualUsbImage.ps1'; Parameters = $p })
        }
        'Boot' {
            $p = [ordered]@{ ImageDirectory = $ImageDirectory; ImageNamePrefix = $ImageNamePrefix; ShareName = $ShareName; ShareHost = $ShareHost; NodeName = $NodeName; NodesFile = $NodesFile; Restart = [bool]$ConfirmNotClustered; ConfirmNotClustered = [bool]$ConfirmNotClustered }
            if ($BmcCredential) { $p.Credential = $BmcCredential }
            if ($ShareAccountName) { $p.AccountName = $ShareAccountName }
            if ($BiosTimeoutMinutes -ne 30) { $p.BiosTimeoutMinutes = $BiosTimeoutMinutes }   # 30 is the stage script's own default
            if ($RfsWriteAttribute) { $p.RfsWriteAttribute = $true }
            if ($SkipCertificateCheck) { $p.SkipCertificateCheck = $true }
            # BIOS changes are evidence: they go beside the event log.
            if ($EventLogPath) { $p.BiosLogPath = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($EventLogPath))) 'bios-changes.jsonl' }
            & $act $p
            $calls.Add([pscustomobject]@{ Script = 'Start-MaintenanceBoot.ps1'; Parameters = $p })
        }
        'Vouchers' {
            $p = [ordered]@{ NodeName = $NodeName; NodesFile = $NodesFile; OutputDirectory = $VoucherDirectory }
            # The image holds the voucher of the machine's current maintenance environment; an earlier local copy is spent
            # (vouchers are one-time use), so the current one replaces it.
            $p.Force = $true
            if ($VoucherFolder) { $p.VoucherFolder = $VoucherFolder }
            else {
                $p.ImageDirectory = $ImageDirectory; $p.ImageNamePrefix = $ImageNamePrefix; $p.TimeoutMinutes = $VoucherWaitMinutes
                if ($BmcCredential) { $p.Credential = $BmcCredential }
                if ($SkipCertificateCheck) { $p.SkipCertificateCheck = $true }
            }
            & $act $p
            $calls.Add([pscustomobject]@{ Script = 'Wait-ZtpVoucher.ps1'; Parameters = $p })
            if (-not $KeepShare) {
                if ($VoucherFolder) {
                    $e = [ordered]@{ NodeName = $NodeName; NodesFile = $NodesFile; Action = 'Eject'; ImageNamePrefix = $ImageNamePrefix }
                    if ($BmcCredential) { $e.Credential = $BmcCredential }
                    if ($SkipCertificateCheck) { $e.SkipCertificateCheck = $true }
                    & $act $e
                    $calls.Add([pscustomobject]@{ Script = 'Mount-ZtpVirtualUsb.ps1'; Parameters = $e })
                }
                $r = [ordered]@{ Remove = $true; ShareName = $ShareName; SharePath = $ImageDirectory }
                if ($ShareAccountName) { $r.AccountName = $ShareAccountName }
                & $act $r
                $calls.Add([pscustomobject]@{ Script = 'Publish-MaintenanceIso.ps1'; Parameters = $r })
            }
        }
        { $_ -in 'Azure', 'Ready' } {
            $base = [ordered]@{ SubscriptionId = $SubscriptionId; ResourceGroupName = $ResourceGroupName; ParameterFile = $ParameterFile; VoucherPath = $VoucherDirectory; OsVersion = $OsVersion; SiteMode = $SiteMode; Node = $NodeName; DeploymentName = $DeploymentName }
            $stages = if ($Name -eq 'Ready') { @('Watch') } elseif ($ForExecute) { @('Prereqs', 'Validate', 'Plan', 'Execute') } else { @('All') }
            foreach ($s in $stages) {
                $p = [ordered]@{ Stage = $s }
                foreach ($k in $base.Keys) { $p[$k] = $base[$k] }
                if ($s -eq 'Execute' -and $AdminPassword) { $p.AdminPassword = $AdminPassword }
                if ($s -eq 'Watch') {
                    $p.TimeoutMinutes = $ReadyTimeoutMinutes; $p.PollIntervalSeconds = $PollIntervalSeconds
                    if ($RetryProvisionOs) { $p.RetryProvisionOs = $true }
                    if ($ArcMachineNameMapPath) { $p.ArcMachineNameMapPath = $ArcMachineNameMapPath }
                }
                if ($s -in 'Execute', 'Watch') { & $act $p }
                $calls.Add([pscustomobject]@{ Script = 'Invoke-ZtpAzureProvisioning.ps1'; Parameters = $p })
            }
            if ($Name -eq 'Ready') {
                $calls.Add([pscustomobject]@{ Script = 'Test-ProvisionedMachines.ps1'; Parameters = [ordered]@{ SubscriptionId = $SubscriptionId; ResourceGroupName = '<Arc resource group>'; ExpectedMachineName = '<Arc machine names from Watch>' } })
            }
        }
    }
    return $calls.ToArray()
}

function Format-ZtpCall {
    param([Parameter(Mandatory)][object]$Call)
    $parts = foreach ($k in $Call.Parameters.Keys) {
        $v = $Call.Parameters[$k]
        if ($v -is [bool]) { if ($v) { "-$k" } else { "-${k}:`$false" } }
        elseif ($v -is [securestring] -or $v -is [pscredential]) { "-$k <in memory>" }
        elseif ($v -is [System.Collections.IEnumerable] -and $v -isnot [string] -and $v -isnot [System.Collections.IDictionary] -and @($v | Where-Object { $_ -is [System.Collections.IDictionary] -or $_ -is [System.Management.Automation.PSCustomObject] }).Count) { "-$k <$(@($v).Count) node result(s)>" }
        elseif ($v -is [System.Collections.IDictionary]) { "-$k <$($v.Count) node(s)>" }
        elseif ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { "-$k $(@($v) -join ',')" }
        else { "-$k $v" }
    }
    "$($Call.Script) $($parts -join ' ')"
}

function Invoke-ZtpStageScript {
    param([Parameter(Mandatory)][object]$Call)
    $path = Join-Path $StageScriptRoot $Call.Script
    if (-not (Test-Path -LiteralPath $path)) { throw "Stage script not found: $path" }
    $p = @{}
    foreach ($k in $Call.Parameters.Keys) { $p[$k] = $Call.Parameters[$k] }
    & $path @p
}

function Get-ZtpManagementAddressCheck {
    # One Network row as the handoff's per-node result: verified when the port with the management MAC carries the address
    # the infrastructure file gives, otherwise a short reason. The stage script's own Verified and Reason win; a row
    # without them (an older stage script) is judged here.
    param([AllowNull()][object]$Row, [Parameter(Mandatory)][string]$Node)
    $result = [ordered]@{ node = $Node; verified = $false; reason = $null }
    if ($null -eq $Row) { $result.reason = 'the Network stage reported nothing for this node'; return $result }
    if ($Row.PSObject.Properties['Verified']) {
        $result.verified = [bool]$Row.Verified
        if (-not $result.verified) { $result.reason = if ($Row.PSObject.Properties['Reason'] -and $Row.Reason) { [string]$Row.Reason } else { 'not verified' } }
        return $result
    }
    $get = { param([string]$Name) if ($Row.PSObject.Properties[$Name]) { [string]$Row.$Name } else { '' } }
    $mode = & $get 'Mode'
    $address = & $get 'Address'
    $expected = & $get 'ExpectedAddress'
    $port = & $get 'AdapterName'
    switch (& $get 'Status') {
        { $_ -in 'AlreadySet', 'Changed' } { $result.verified = $true }
        'NotConfigured' { $result.reason = 'no management settings in the infrastructure file' }
        default {
            if (-not (& $get 'MacAddress')) { $result.reason = "${mode}: no management MAC in the infrastructure file, so the port wasn't checked" }
            elseif ($expected -and $address -eq $expected) { $result.verified = $true }
            elseif (-not $address) { $result.reason = "${mode}: the management port $port reports no address" }
            elseif ($expected) { $result.reason = "${mode}: the management port $port reports $address, the infrastructure file expects $expected" }
            else { $result.reason = "${mode}: the management port $port reports $address; the infrastructure file gives no address to compare" }
        }
    }
    return $result
}

function Assert-ZtpStageInput {
    param([Parameter(Mandatory)][string]$Name, [switch]$ForExecute)
    $need = [ordered]@{}
    switch ($Name) {
        'Resolve' { if ($BootstrapCacheDirectory) { $need.BootstrapCacheDirectory = $BootstrapCacheDirectory } }
        'Bootstrap' { if ($VoucherFolder) { $need.VoucherFolder = $VoucherFolder } else { $need.ImageDirectory = $ImageDirectory; if ($ForExecute) { $need.BmcCredential = $BmcCredential } }; if (-not $SkipAzureCheck -and $ForExecute) { $need.SubscriptionId = $SubscriptionId } }
        'Device' { $need.ParameterFile = $ParameterFile }
        'Network' { $need.SubscriptionId = $SubscriptionId; $need.ResourceGroupName = $ResourceGroupName; $need.ParameterFile = $ParameterFile }
        'Handoff' { $need.SubscriptionId = $SubscriptionId; $need.ResourceGroupName = $ResourceGroupName }
        'Restore' { if ($ForExecute -and @(Get-ZtpRestoreNeed).Count) { $need.BmcCredential = $BmcCredential; $need.SubscriptionId = $SubscriptionId; $need.ResourceGroupName = $ResourceGroupName; $need.ParameterFile = $ParameterFile; $need.VoucherDirectory = $VoucherDirectory } }
        'Media' { if (-not $BootstrapCacheDirectory) { $need.SourcePath = $SourcePath }; $need.ImageDirectory = $ImageDirectory }
        'Boot' { $need.ImageDirectory = $ImageDirectory; $need.ShareHost = $ShareHost; if ($ForExecute) { $need.BmcCredential = $BmcCredential } }
        'Vouchers' { $need.VoucherDirectory = $VoucherDirectory; if (-not $VoucherFolder) { $need.ImageDirectory = $ImageDirectory }; if ($ForExecute) { $need.BmcCredential = $BmcCredential } }
        { $_ -in 'Azure', 'Ready' } { $need.SubscriptionId = $SubscriptionId; $need.ResourceGroupName = $ResourceGroupName; $need.ParameterFile = $ParameterFile; $need.VoucherDirectory = $VoucherDirectory }
    }
    $missing = @($need.Keys | Where-Object { -not $need[$_] })
    if ($missing.Count -gt 0) { throw "Stage ${Name}: no value for $($missing -join ', ')." }
}

# ------------------------------------------------------------------ stage table
Write-ZtpRunLog "Nodes: $($NodeName -join ', '). State: $StatePath."
foreach ($name in $order) {
    $done = $state['stages'].Contains($name)
    $status = if ($name -in $run) { if ($done) { 'run again' } else { 'pending' } } elseif ($done) { "completed $($state['stages'][$name]['completed'])" } else { 'not in this run' }
    Write-ZtpRunLog ("{0,-9} {1}" -f $name, $status)
}
if ($run.Count -eq 0) { Write-ZtpRunLog 'Every stage is recorded as completed. Use -Stage or -From to run one again, or -ResetState.'; return }
foreach ($name in $run) { Assert-ZtpStageInput -Name $name -ForExecute:$Execute }

if (-not $Execute) {
    Write-ZtpRunLog 'Plan only (default). Add -Execute to act; the Boot stage also needs -ConfirmNotClustered.' -Level Warning
    $planSourcePath = $SourcePath
    if (-not $SourcePath -and $BootstrapCacheDirectory -and 'Resolve' -in $run) { $SourcePath = '<newest ISO from Resolve>' }
    foreach ($name in $run) { foreach ($call in (Get-ZtpStageCall -Name $name -ForExecute)) { Write-ZtpRunLog "$name would run: $(Format-ZtpCall -Call $call)" } }
    $SourcePath = $planSourcePath
    $next = @($run | Where-Object { $_ -ne 'Resolve' -or $BootstrapCacheDirectory })[0]
    if ($run[0] -eq 'Resolve' -and -not $BootstrapCacheDirectory) { Write-ZtpRunLog "Resolve is skipped: no BootstrapCacheDirectory, so -SourcePath ($SourcePath) is used as it is." }
    if ($next -in 'Resolve', 'Media', 'Boot', 'Device', 'Azure', 'Network', 'Restore') {
        Write-ZtpRunLog "Plan of the next stage ($next), from its own script:"
        try { foreach ($call in (Get-ZtpStageCall -Name $next)) { Invoke-ZtpStageScript -Call $call | Where-Object { $_ -is [string] } } }
        catch { Write-ZtpRunLog "The $next stage would fail now: $($_.Exception.Message)" -Level Warning }
    }
    else { Write-ZtpRunLog "Next stage ($next) is a wait; it has no separate plan output." }
    return
}

if ('Boot' -in $run -and -not $ConfirmNotClustered) {
    throw 'Refusing to run: the Boot stage restarts the machines into the maintenance environment, which reinstalls them. Pass -ConfirmNotClustered.'
}
if (-not $PSCmdlet.ShouldProcess("machines $($NodeName -join ', ')", "Zero-touch provisioning stages $($run -join ' -> ')")) { return }
$state['nodes'] = @($NodeName)
$results = [System.Collections.Generic.List[object]]::new()
foreach ($name in $run) {
    Write-ZtpRunLog "=== Stage $name ==="
    $stageStart = Get-Date
    $calls = @(Get-ZtpStageCall -Name $name -ForExecute)
    $data = $null
    Write-ZtpEvent -Path $EventLogPath -Node '*' -State 'StageStarted' -Evidence "stage $name" -NextAction '' -Stage $name
    try {
    switch ($name) {
        'Resolve' {
            if (-not $BootstrapCacheDirectory) {
                if (-not $SourcePath) { throw 'Resolve: set BootstrapCacheDirectory (download the newest ISO) or SourcePath (an ISO you already have).' }
                $evidence = "skipped: no BootstrapCacheDirectory; using $SourcePath"
            }
            else {
                $iso = @(Invoke-ZtpStageScript -Call $calls[0] | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['IsoPath'] }) | Select-Object -Last 1
                if (-not $iso -or -not (Test-Path -LiteralPath $iso.IsoPath)) { throw 'Resolve: no verified maintenance ISO was produced.' }
                $SourcePath = [string]$iso.IsoPath
                # The bootstrap ISO's details stay with the run (state file, stage evidence, event log), not in the handoff.
                $url = if ($iso.PSObject.Properties['Url']) { [string]$iso.Url } else { '' }
                $data = @{ isoPath = $SourcePath; bootstrapManifest = $iso.ManifestPath; bootstrapVersion = $iso.Version; isoSha256 = $iso.IsoSha256; bootstrapUrl = $url }
                $evidence = "maintenance ISO $($iso.Version) ($($iso.Channel)), SHA256 $($iso.IsoSha256)$(if ($url) { ", from $url" })"
            }
        }
        'Bootstrap' {
            $rows = @(Invoke-ZtpStageScript -Call $calls[0] | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Ready'] })
            foreach ($node in $NodeName) {
                $row = @($rows | Where-Object Node -EQ $node)
                if ($row.Count -ne 1) { throw "Bootstrap: no result for $node." }
                if (-not [bool]$row[0].Ready) { throw "Bootstrap: $node is in state $($row[0].State): $($row[0].Evidence). Events: $EventLogPath." }
            }
            $evidence = "ReadyForPortal: $(@($rows | ForEach-Object { "$($_.Node) (voucher SHA256 $($_.VoucherSha256))" }) -join ', ')"
        }
        'Device' {
            $rows = @(Invoke-ZtpStageScript -Call $calls[0] | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Mode'] -and $_.PSObject.Properties['MaintenanceAddress'] })
            foreach ($node in $NodeName) {
                $row = @($rows | Where-Object Node -EQ $node)
                if ($row.Count -ne 1) { throw "Device: no result for $node." }
                if ($row[0].Mode -eq 'static' -and $row[0].Status -notin 'AlreadySet', 'Changed', 'Skipped') { throw "Device: the static management address of $node is $($row[0].Status), not set." }
            }
            $evidence = @($rows | ForEach-Object {
                    $r = $_
                    $what = switch ($r.Status) { 'NotConfigured' { 'no management settings' } 'Skipped' { 'not static and no maintenance_address, nothing to set' } default { "$($r.Adapter) $($r.MacAddress) $($r.Mode) $($r.Address)".Trim() } }
                    "$($r.Node) $what ($($r.Status))"
                }) -join '; '
        }
        'Network' {
            $rows = @(Invoke-ZtpStageScript -Call $calls[0] | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Mode'] -and $_.PSObject.Properties['Status'] })
            foreach ($node in $NodeName) {
                $row = @($rows | Where-Object Node -EQ $node)
                if ($row.Count -ne 1) { throw "Network: no result for $node." }
                # Verify-only (the default) never fails on the result: a static address the OS install reset is Deferred
                # to OS configuration. Only -ApplyThroughAzure promises the address is set when the stage ends.
                if ($ApplyThroughAzure -and $row[0].Mode -eq 'static' -and $row[0].Status -notin 'AlreadySet', 'Changed') { throw "Network: the static management address of $node is $($row[0].Status), not set." }
            }
            $evidence = @($rows | ForEach-Object {
                    $what = if ($_.Status -eq 'NotConfigured') { 'no management settings' } else { "$($_.AdapterName) $($_.MacAddress) $($_.Mode) $($_.Address)".Trim() }
                    $why = if ($_.PSObject.Properties['Verified'] -and -not $_.Verified -and $_.PSObject.Properties['Reason'] -and $_.Reason -and $_.Status -ne 'NotConfigured') { ": $($_.Reason)" } else { '' }
                    "$($_.Node) $what ($($_.Status)$(if (@($_.Released).Count) { "; released from $(@($_.Released) -join ', ')" })$why)"
                }) -join '; '
            # Per node for the handoff: is the infrastructure file's management address on the port with the management MAC?
            $data = @{ managementAddress = @(foreach ($node in $NodeName) { Get-ZtpManagementAddressCheck -Row ($rows | Where-Object Node -EQ $node | Select-Object -First 1) -Node $node }) }
        }
        'Restore' {
            $rows = @(Invoke-ZtpStageScript -Call $calls[0] | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Restored'] })
            # Fail closed: a node that needs a restore must report Restored or AlreadySet. Skipped, Planned, Failed or no row
            # at all is not done, whatever the script returned instead of throwing.
            foreach ($node in @(Get-ZtpRestoreNeed)) {
                $row = @($rows | Where-Object { $_.Node -eq $node })
                if ($row.Count -ne 1 -or [string]$row[0].Status -notin 'Restored', 'AlreadySet') { throw "Restore: $node was not restored (result: $(if ($row.Count -eq 1) { [string]$row[0].Status } else { 'none' }))." }
            }
            $restarted = @($rows | Where-Object Status -EQ 'Restored')
            if ($restarted.Count) {
                # The Arc machine reads Connected for a while after its host went down: let it notice the restart first, then
                # accept Connected only as a NEW observation (Arc changed the machine's status after the restart began), not a
                # Connected left over from before it.
                Write-ZtpRunLog "Restore: BIOS set back on $(@($restarted.Node) -join ', '); waiting $RestoreSettleMinutes min, then until the Arc machines are Connected again after the restart and the edge machines ready to cluster."
                if ($RestoreSettleMinutes -gt 0) { Start-Sleep -Seconds ($RestoreSettleMinutes * 60) }
                $restartedAt = @{}
                foreach ($r in $restarted) { $t = if ($r.PSObject.Properties['RestartedAt']) { ConvertTo-ZtpUtcDateTime $r.RestartedAt } else { $null }; if ($t) { $restartedAt[[string]$r.Node] = $t } }
                $watch = @(Get-ZtpStageCall -Name 'Ready' -ForExecute)[0]
                $arcRows = @(Invoke-ZtpStageScript -Call $watch | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['ArcMachineName'] -and $_.PSObject.Properties['ArcResourceGroup'] })
                foreach ($node in $NodeName) { if (@($arcRows | Where-Object { $_.Node -eq $node -and $_.ArcMachineName }).Count -ne 1) { throw "Restore: $node isn't ready to cluster after the BIOS restart." } }
                $deadline = [datetime]::UtcNow.AddMinutes($ReadyTimeoutMinutes)
                foreach ($group in @($arcRows | Group-Object ArcResourceGroup)) {
                    $test = [ordered]@{ SubscriptionId = $SubscriptionId; ResourceGroupName = $group.Name; ExpectedMachineName = @($group.Group.ArcMachineName) }
                    $since = @{}
                    foreach ($g in $group.Group) { if ($restartedAt.ContainsKey([string]$g.Node)) { $since[[string]$g.ArcMachineName] = $restartedAt[[string]$g.Node] } }
                    if ($since.Count) { $test.ConnectedSince = $since }
                    while ($true) {
                        try { $null = Invoke-ZtpStageScript -Call ([pscustomobject]@{ Script = 'Test-ProvisionedMachines.ps1'; Parameters = $test }); break }
                        catch {
                            if ([datetime]::UtcNow -ge $deadline) { throw "Restore: the Arc machines are not Connected again after the BIOS restart within $ReadyTimeoutMinutes minutes: $($_.Exception.Message)" }
                            Write-ZtpRunLog "Restore: not Connected again after the restart yet ($($_.Exception.Message)); checking again in $PollIntervalSeconds s."
                            Start-Sleep -Seconds $PollIntervalSeconds
                        }
                    }
                }
            }
            $restored = [ordered]@{}
            foreach ($r in @($rows | Where-Object { $_.Status -in 'Restored', 'AlreadySet' })) { $restored[$r.Node] = $r.Restored }
            $data = @{ restored = $restored }
            $evidence = if ($restored.Count) { "BIOS set back: $(@($restored.Keys | ForEach-Object { $n = $_; "$n $(@($restored[$n].Keys | ForEach-Object { "$_=$($restored[$n][$_])" }) -join ', ')" }) -join '; ')$(if ($restarted.Count) { "; Connected and ready again: $(@($restarted.Node) -join ', ')" })" } else { 'nothing to restore: no bios_during_provisioning' }
        }
        'Handoff' {
            $null = Invoke-ZtpStageScript -Call $calls[0]
            $null = Invoke-ZtpStageScript -Call $calls[1]
            foreach ($path in $HandoffPath, $ClusterInputsPath) { if (-not (Test-Path -LiteralPath $path)) { throw "Handoff: $path was not written." } }
            $evidence = "handoff $HandoffPath; cluster inputs $ClusterInputsPath"
        }
        'Media' {
            $mediaStartedAt = [datetime]::UtcNow
            $rows = @(Invoke-ZtpStageScript -Call $calls[0] | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['ImagePath'] })
            foreach ($node in $NodeName) {
                $row = @($rows | Where-Object Node -EQ $node)
                if ($row.Count -ne 1 -or -not (Test-Path -LiteralPath $row[0].ImagePath)) { throw "Media: no image was built for $node." }
            }
            # The images are built here, without a voucher. The Bootstrap stage uses the build time to tell a voucher this run's
            # node wrote from one left in a reused image. builtAt is when the build started: the image is never older.
            $images = [ordered]@{}
            foreach ($node in $NodeName) {
                $row = @($rows | Where-Object Node -EQ $node)[0]
                $images[$node] = [ordered]@{ path = [string]$row.ImagePath; sha256 = $(if ($row.PSObject.Properties['Sha256']) { [string]$row.Sha256 } else { '' }); builtAt = $mediaStartedAt.ToString('o') }
                # Read-only look into the image just built: its voucher slot must be empty. The Bootstrap stage accepts a
                # voucher as this run's only when it was (an image reused from an earlier run may already hold one). When the
                # image cannot be read here, nothing is recorded and Bootstrap falls back to the weaker file-time rule.
                try {
                    $probe = Find-ZtpVoucherInImage -ImagePath ([string]$row.ImagePath) -AllowOpen
                    $images[$node].voucherEmptyAtBuild = (@($probe.Pem | Where-Object UnderVouchers).Count -eq 0)
                }
                catch { Write-ZtpRunLog "Media: couldn't read the image of $node to check that it holds no voucher ($($_.Exception.Message)); the Bootstrap stage will use the image file's write time instead." -Level Warning }
            }
            $data = @{ images = $images }
            $evidence = "images $(@($rows | ForEach-Object { Split-Path $_.ImagePath -Leaf }) -join ', ')"
        }
        'Boot' {
            $rows = @(Invoke-ZtpStageScript -Call $calls[0] | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Restarted'] })
            foreach ($node in $NodeName) {
                $row = @($rows | Where-Object Node -EQ $node)
                if ($row.Count -ne 1) { throw "Boot: no result for $node." }
                if ([bool]$row[0].WriteProtected -and -not $RfsWriteAttribute) { throw "Boot: the image of $node is attached write-protected; the voucher cannot be written back. Retry with -RfsWriteAttribute." }
                if (-not [bool]$row[0].Restarted) { throw "Boot: $node was not restarted into the maintenance environment." }
            }
            $bios = @(foreach ($r in $rows) { if ($r.PSObject.Properties['Bios'] -and @($r.Bios).Count) { "$($r.Node) $(@($r.Bios) -join ', ')" } })
            # Each attribute's value as found, before Boot changed it: the Restore stage sets temporary values back to it.
            # Saved once: a later Boot run reads the already-changed value and must not overwrite it.
            if (-not $state.Contains('biosOriginal') -or $state['biosOriginal'] -isnot [System.Collections.IDictionary]) { $state['biosOriginal'] = [ordered]@{} }
            foreach ($r in @($rows | Where-Object { $_.PSObject.Properties['BiosOriginal'] -and $_.BiosOriginal })) {
                if (-not $state['biosOriginal'].Contains($r.Node)) { $state['biosOriginal'][$r.Node] = [ordered]@{} }
                foreach ($k in @($r.BiosOriginal.Keys)) { if (-not $state['biosOriginal'][$r.Node].Contains($k)) { $state['biosOriginal'][$r.Node][$k] = [string]$r.BiosOriginal[$k] } }
            }
            # When each node was reset onto its image. The Bootstrap stage starts after the Boot stage has watched the BMC for
            # up to 10 minutes; a fast node has written its voucher by then, and a voucher written after this reset is this run's.
            $resetAt = [ordered]@{}
            foreach ($r in @($rows | Where-Object { $_.PSObject.Properties['ResetAt'] -and $_.ResetAt })) { $resetAt[$r.Node] = ([datetime]$r.ResetAt).ToUniversalTime().ToString('o') }
            if ($resetAt.Count) { $data = @{ resetAt = $resetAt } }
            Save-ZtpRunState
            foreach ($r in @($rows | Where-Object { $_.PSObject.Properties['Bios'] -and @($_.Bios).Count })) {
                Write-ZtpEvent -Path $EventLogPath -Node $r.Node -State 'BiosChanged' -Evidence (@($r.Bios) -join '; ') -NextAction '' -Stage 'Boot'
            }
            $evidence = "read-write image and one-time boot on $($NodeName -join ', ')$(if ($bios) { "; BIOS $($bios -join '; ')" })"
        }
        'Vouchers' {
            $rows = @(Invoke-ZtpStageScript -Call $calls[0] | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Valid'] })
            foreach ($node in $NodeName) {
                $row = @($rows | Where-Object { $_.Node -eq $node -and $_.Valid })
                if ($row.Count -lt 1 -or -not $row[0].OutputFile -or -not (Test-Path -LiteralPath $row[0].OutputFile)) { throw "Vouchers: no valid voucher was written for $node." }
            }
            foreach ($cleanup in @($calls | Select-Object -Skip 1)) { $null = Invoke-ZtpStageScript -Call $cleanup }
            $evidence = "$(if ($VoucherFolder) { 'Configurator App folder' } else { 'read back from the images' }): $(@($rows | Where-Object Valid | ForEach-Object { Split-Path $_.OutputFile -Leaf }) -join ', ')"
        }
        'Azure' {
            foreach ($call in $calls) {
                $out = @(Invoke-ZtpStageScript -Call $call)
                if ($call.Parameters.Stage -eq 'Plan') {
                    $plan = @($out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['VoucherProblems'] }) | Select-Object -Last 1
                    if ($plan -and @($plan.VoucherProblems).Count -gt 0) { throw "Azure: refusing to submit, voucher problems: $(@($plan.VoucherProblems) -join ' ')" }
                }
            }
            $evidence = "deployment accepted for $($NodeName -join ', ')"
        }
        'Ready' {
            $arcRows = @(Invoke-ZtpStageScript -Call $calls[0] | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['ArcMachineName'] -and $_.PSObject.Properties['ArcResourceGroup'] })
            foreach ($node in $NodeName) {
                if (@($arcRows | Where-Object { $_.Node -eq $node -and $_.ArcMachineName }).Count -ne 1) { throw "Ready: no Arc machine name for $node." }
            }
            foreach ($group in @($arcRows | Group-Object ArcResourceGroup)) {
                if (-not $group.Name) { throw 'Ready: an Arc machine resource ID without a resource group.' }
                $test = [ordered]@{ SubscriptionId = $SubscriptionId; ResourceGroupName = $group.Name; ExpectedMachineName = @($group.Group.ArcMachineName) }
                $null = Invoke-ZtpStageScript -Call ([pscustomobject]@{ Script = 'Test-ProvisionedMachines.ps1'; Parameters = $test })
            }
            $evidence = "ready to cluster: $(@($arcRows | ForEach-Object { "$($_.Node)=$($_.ArcMachineName)" }) -join ', ')"
        }
    }
    }
    catch {
        Write-ZtpEvent -Path $EventLogPath -Node '*' -State 'StageFailed' -Evidence "stage $name failed: $($_.Exception.Message)" -NextAction 'Fix the cause and rerun; completed stages are not repeated.' -Level Error -Stage $name
        throw
    }
    $state['stages'][$name] = [ordered]@{ completed = [datetime]::UtcNow.ToString('o'); evidence = $evidence }
    if ($data) { $state['stages'][$name]['data'] = $data }
    Write-ZtpEvent -Path $EventLogPath -Node '*' -State 'StageCompleted' -Evidence "stage ${name}: $evidence" -NextAction '' -Stage $name
    Save-ZtpRunState
    $minutes = [int]((Get-Date) - $stageStart).TotalMinutes
    Write-ZtpRunLog "Stage $name completed in $minutes min: $evidence"
    $results.Add([pscustomobject]@{ Stage = $name; Result = 'Completed'; Minutes = $minutes; Evidence = $evidence })
}
if ('Handoff' -in $run) {
    Write-ZtpRunLog "ZTP is done: the machines are Provisioned and Arc-connected, with the management address on the management port. $HandoffPath has the Arc machine names and IDs; $ClusterInputsPath has arc_machine_names for the cluster deployment environment file."
    Write-ZtpRunLog 'Next: OS configuration (OEM drivers, the SBE in C:\SBE, DHCP off on the other ports, DNS and time, the deployment admin), then Validate and Deploy. ZTP does none of these. See https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/. Hardware must not be clustered by this repository.'
}
$results.ToArray()
