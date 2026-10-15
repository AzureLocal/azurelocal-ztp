#Requires -Version 7.0
<#
.SYNOPSIS
Zero-touch provisioning of Azure Local machines, end to end: Resolve -> Media -> Boot -> Bootstrap -> Vouchers -> Azure -> Ready -> Handoff.
.DESCRIPTION
One orchestrator over the stage scripts in this folder. Every input is a parameter, or a key of the same name in a JSON
settings file (-ConfigPath; see config/simplified-provisioning/ztp-provisioning.example.json). A parameter wins over the
file; nothing is hardcoded.
  Resolve   Get-ZtpBootstrapIso.ps1 (+ Get-ZtpSbe.ps1): finds, downloads and verifies the newest maintenance ISO into
            -BootstrapCacheDirectory and selects the OEM's newest SBE (descriptor only: the SBE does not go on the media). Runs
            only when -BootstrapCacheDirectory is set; otherwise -SourcePath must name the ISO and the stage is recorded as skipped.
  Media     New-ZtpVirtualUsbImage.ps1 -NodeName: one virtual-USB image per node (<ImageNamePrefix><node>.img in
            -ImageDirectory) from the maintenance ISO (-SourcePath), GPT with one FAT32 partition labelled CDROM.
  Boot      Start-MaintenanceBoot.ps1: shares the images read-write in place (one account, TCP 445 only from the BMCs),
            inserts each node's image on the BMC USB-stick slot with WriteProtected=false, proves the attach, sets a
            one-time USB boot and power-cycles the node. Needs -ConfirmNotClustered: the maintenance environment
            reinstalls the machine.
  Bootstrap Wait-ZtpBootstrapComplete.ps1: one read-only watch over Redfish power, boot and virtual-media state, the BMC log, the
            voucher in the image and the Azure prerequisites; structured events go to -EventLogPath (Mounted, Booting,
            MaintenanceEnvironmentRunning, VoucherWritten, ReadyForPortal). Every node must reach ReadyForPortal.
  Vouchers  Wait-ZtpVoucher.ps1: waits until the maintenance environment wrote \vouchers\<serial>\*.pem into each image,
            ejects the media, writes <serial>.pem into -VoucherDirectory. -VoucherFolder takes vouchers downloaded with
            the Configurator App instead (it only works if the USB export did not happen). Then the share, its firewall
            rule and account are removed (-KeepShare keeps them).
  Azure     Invoke-ZtpAzureProvisioning.ps1 stages Prereqs, Validate, Plan, Execute: site, site configuration and edge
            machines claimed with the vouchers. Refuses to submit when a voucher is missing.
  Ready     Invoke-ZtpAzureProvisioning.ps1 -Stage Watch: waits until every machine is ready to cluster and returns (or,
            with -ArcMachineNameMapPath, writes) each node's Arc machine name; then Test-ProvisionedMachines.ps1.
  Handoff   New-ZtpHandoff.ps1 writes -HandoffPath (ztp-handoff.json: Arc machine names, site, solution, bootstrap and SBE versions,
            timestamps); Convert-ZtpHandoffToClusterInputs.ps1 writes -ClusterInputsPath (the arc_machine_names block for the cluster
            deployment environment file). Nothing is clustered here.
Plan by default: without -Execute the stage table and the command of every stage are printed, and the next stage shows its
own plan (Media, Boot and Azure have a plan mode; Vouchers and Ready are waits). Nothing changes.
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
Resolve: download cache of the maintenance ISO (and the SBE staging folder). Empty = no Resolve; -SourcePath must name the ISO.
.PARAMETER BootstrapVersion
Resolve: latest (default), a train (2610), a build or a Microsoft download URL.
.PARAMETER IncludePreview
Resolve: also consider preview trains.
.PARAMETER MaxBootstrapTrain
Resolve: highest train to consider.
.PARAMETER Oem
OEM definition in config/oem (default Dell): SBE discovery and BMC log signals.
.PARAMETER SbeModel
Resolve: hardware model for the SBE selection (for example AX760). Empty = no SBE selection.
.PARAMETER SbeFamily
Resolve: SBE family instead of a model.
.PARAMETER SbeSolutionVersion
Resolve: solution version the SBE must be validated with (latest = not checked).
.PARAMETER SbePackagePath
Resolve: SBE zip obtained from the OEM; its SHA256 is verified and it is staged.
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
Optional password of the maintenance environment's edgeuser account (only its SHA-512 crypt hash enters the image).
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
Ready: poll interval.
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
    [ValidateSet('Resolve', 'Media', 'Boot', 'Bootstrap', 'Vouchers', 'Azure', 'Ready', 'Handoff', 'All')][string]$Stage = 'All',
    [ValidateSet('Resolve', 'Media', 'Boot', 'Bootstrap', 'Vouchers', 'Azure', 'Ready', 'Handoff')][string]$From,
    [string]$ConfigPath,
    [string]$NodesFile,
    [string[]]$NodeName,
    [string]$SourcePath,
    [string]$BootstrapCacheDirectory,
    [string]$BootstrapVersion = 'latest',
    [switch]$IncludePreview,
    [ValidatePattern('^$|^\d{4}$')][string]$MaxBootstrapTrain,
    [ValidatePattern('^[A-Za-z0-9_-]{1,40}$')][string]$Oem = 'Dell',
    [string]$SbeModel,
    [string]$SbeFamily,
    [string]$SbeSolutionVersion = 'latest',
    [string]$SbePackagePath,
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
    [string]$StatePath = (Join-Path (Get-Location) 'ztp-provisioning.state.json'),
    [switch]$ResetState,
    [string]$StageScriptRoot = $PSScriptRoot,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpVirtualUsb.Common.ps1')
. (Join-Path $PSScriptRoot 'ZtpEvents.Common.ps1')

$order = @('Resolve', 'Media', 'Boot', 'Bootstrap', 'Vouchers', 'Azure', 'Ready', 'Handoff')
function Write-ZtpRunLog {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message, [ValidateSet('Info', 'Warning')][string]$Level = 'Info')
    $line = "[$([datetime]::UtcNow.ToString('HH:mm:ss'))Z] [ztp] $Message"
    if ($Level -eq 'Warning') { Write-Warning $line } else { Write-Information -MessageData $line -InformationAction Continue }
}

# ------------------------------------------------------------------ settings: parameter > -ConfigPath > default
$settable = @('BootstrapCacheDirectory', 'BootstrapVersion', 'IncludePreview', 'MaxBootstrapTrain', 'Oem', 'SbeModel', 'SbeFamily', 'SbeSolutionVersion', 'SbePackagePath',
    'EventLogPath', 'BootstrapTimeoutMinutes', 'BootstrapVoucherTimeoutMinutes', 'SkipAzureCheck', 'Location', 'HandoffPath', 'ClusterInputsPath',
    'NodesFile', 'NodeName', 'SourcePath', 'ImageDirectory', 'ImageNamePrefix', 'ShareHost', 'ShareName', 'VoucherDirectory',
    'VoucherFolder', 'VoucherWaitMinutes', 'RfsWriteAttribute', 'SkipCertificateCheck', 'KeepShare', 'SubscriptionId', 'ResourceGroupName',
    'ParameterFile', 'OsVersion', 'SiteMode', 'DeploymentName', 'ArcMachineNameMapPath', 'ReadyTimeoutMinutes', 'PollIntervalSeconds', 'StatePath')
if ($ConfigPath) {
    $settings = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
    foreach ($key in $settings.Keys) {
        if ($key -eq '$schema') { continue }
        if ($key -notin $settable) { throw "Unknown key '$key' in $ConfigPath. Keys: $($settable -join ', ')." }
        if ($PSBoundParameters.ContainsKey($key)) { continue }
        $value = $settings[$key]
        if ($key -in 'RfsWriteAttribute', 'SkipCertificateCheck', 'KeepShare', 'IncludePreview', 'SkipAzureCheck') { $value = [switch][bool]$value }
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

# ------------------------------------------------------------------ stage calls
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
                if ($Oem -and ($SbeModel -or $SbeFamily)) {
                    $s = [ordered]@{ Oem = $Oem; SolutionVersion = $SbeSolutionVersion; CacheDirectory = $BootstrapCacheDirectory }
                    if ($SbeModel) { $s.Model = $SbeModel }
                    if ($SbeFamily) { $s.Family = $SbeFamily }
                    if ($SbePackagePath) { $s.PackagePath = $SbePackagePath }
                    & $actPlain $s
                    $calls.Add([pscustomobject]@{ Script = 'Get-ZtpSbe.ps1'; Parameters = $s })
                }
            }
        }
        'Bootstrap' {
            $p = [ordered]@{ NodeName = $NodeName; NodesFile = $NodesFile; Oem = $Oem; EventLogPath = $EventLogPath; TimeoutMinutes = $BootstrapTimeoutMinutes; VoucherTimeoutMinutes = $BootstrapVoucherTimeoutMinutes }
            if ($VoucherFolder) { $p.VoucherFolder = $VoucherFolder } else { $p.ImageDirectory = $ImageDirectory; $p.ImageNamePrefix = $ImageNamePrefix }
            if ($BmcCredential -and -not $VoucherFolder) { $p.Credential = $BmcCredential }
            if ($SkipCertificateCheck) { $p.SkipCertificateCheck = $true }
            if ($SkipAzureCheck) { $p.SkipAzureCheck = $true } else { $p.SubscriptionId = $SubscriptionId; $p.Location = $Location }
            & $actPlain $p
            $calls.Add([pscustomobject]@{ Script = 'Wait-ZtpBootstrapComplete.ps1'; Parameters = $p })
        }
        'Handoff' {
            $resolved = if ($state['stages'].Contains('Resolve') -and $state['stages']['Resolve'].Contains('data')) { $state['stages']['Resolve']['data'] } else { @{} }
            $p = [ordered]@{ SubscriptionId = $SubscriptionId; ResourceGroupName = $ResourceGroupName; NodeName = $NodeName; NodesFile = $NodesFile; EventLogPath = $EventLogPath; HandoffPath = $HandoffPath }
            if ($resolved['bootstrapManifest']) { $p.BootstrapManifestPath = $resolved['bootstrapManifest'] }
            if ($resolved['sbeManifest']) { $p.SbeManifestPath = $resolved['sbeManifest'] }
            & $actPlain $p
            $calls.Add([pscustomobject]@{ Script = 'New-ZtpHandoff.ps1'; Parameters = $p })
            $c = [ordered]@{ HandoffPath = $HandoffPath; OutputPath = $ClusterInputsPath; Format = $(if ($ClusterInputsPath -like '*.json') { 'Json' } else { 'Yaml' }) }
            $calls.Add([pscustomobject]@{ Script = 'Convert-ZtpHandoffToClusterInputs.ps1'; Parameters = $c })
        }
        'Media' {
            $p = [ordered]@{ SourcePath = $SourcePath; NodeName = $NodeName; OutputDirectory = $ImageDirectory; ImageNamePrefix = $ImageNamePrefix }
            if ($EdgeUserPassword) { $p.EdgeUserPassword = $EdgeUserPassword }
            if ($RebuildImages) { $p.Force = $true }
            & $act $p
            $calls.Add([pscustomobject]@{ Script = 'New-ZtpVirtualUsbImage.ps1'; Parameters = $p })
        }
        'Boot' {
            $p = [ordered]@{ ImageDirectory = $ImageDirectory; ImageNamePrefix = $ImageNamePrefix; ShareName = $ShareName; ShareHost = $ShareHost; NodeName = $NodeName; NodesFile = $NodesFile; Restart = [bool]$ConfirmNotClustered; ConfirmNotClustered = [bool]$ConfirmNotClustered }
            if ($BmcCredential) { $p.Credential = $BmcCredential }
            if ($RfsWriteAttribute) { $p.RfsWriteAttribute = $true }
            if ($SkipCertificateCheck) { $p.SkipCertificateCheck = $true }
            & $act $p
            $calls.Add([pscustomobject]@{ Script = 'Start-MaintenanceBoot.ps1'; Parameters = $p })
        }
        'Vouchers' {
            $p = [ordered]@{ NodeName = $NodeName; NodesFile = $NodesFile; OutputDirectory = $VoucherDirectory }
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

function Assert-ZtpStageInput {
    param([Parameter(Mandatory)][string]$Name, [switch]$ForExecute)
    $need = [ordered]@{}
    switch ($Name) {
        'Resolve' { if ($BootstrapCacheDirectory) { $need.BootstrapCacheDirectory = $BootstrapCacheDirectory } }
        'Bootstrap' { if ($VoucherFolder) { $need.VoucherFolder = $VoucherFolder } else { $need.ImageDirectory = $ImageDirectory; if ($ForExecute) { $need.BmcCredential = $BmcCredential } }; if (-not $SkipAzureCheck -and $ForExecute) { $need.SubscriptionId = $SubscriptionId } }
        'Handoff' { $need.SubscriptionId = $SubscriptionId; $need.ResourceGroupName = $ResourceGroupName }
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
    if ($next -in 'Resolve', 'Media', 'Boot', 'Azure') {
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
                $data = @{ isoPath = $SourcePath; bootstrapManifest = $iso.ManifestPath; bootstrapVersion = $iso.Version; isoSha256 = $iso.IsoSha256 }
                $evidence = "maintenance ISO $($iso.Version) ($($iso.Channel)), SHA256 $($iso.IsoSha256)"
                if ($calls.Count -gt 1) {
                    $sbe = @(Invoke-ZtpStageScript -Call $calls[1] | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['StagingFolder'] }) | Select-Object -First 1
                    if ($sbe) {
                        $data.sbeManifest = Join-Path $sbe.StagingFolder 'sbe-manifest.json'; $data.sbeVersion = $sbe.Version
                        $evidence += "; $($sbe.Oem) SBE $($sbe.Version) ($($sbe.Status))"
                    }
                }
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
        'Handoff' {
            $null = Invoke-ZtpStageScript -Call $calls[0]
            $null = Invoke-ZtpStageScript -Call $calls[1]
            foreach ($path in $HandoffPath, $ClusterInputsPath) { if (-not (Test-Path -LiteralPath $path)) { throw "Handoff: $path was not written." } }
            $evidence = "handoff $HandoffPath; cluster inputs $ClusterInputsPath"
        }
        'Media' {
            $rows = @(Invoke-ZtpStageScript -Call $calls[0] | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['ImagePath'] })
            foreach ($node in $NodeName) {
                $row = @($rows | Where-Object Node -EQ $node)
                if ($row.Count -ne 1 -or -not (Test-Path -LiteralPath $row[0].ImagePath)) { throw "Media: no image was built for $node." }
            }
            $evidence = "images $(@($rows | ForEach-Object { Split-Path $_.ImagePath -Leaf }) -join ', ')"
        }
        'Boot' {
            $rows = @(Invoke-ZtpStageScript -Call $calls[0] | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Restarted'] })
            foreach ($node in $NodeName) {
                $row = @($rows | Where-Object Node -EQ $node)
                if ($row.Count -ne 1) { throw "Boot: no result for $node." }
                if ([bool]$row[0].WriteProtected) { throw "Boot: the image of $node is attached write-protected; the voucher cannot be written back. Retry with -RfsWriteAttribute." }
                if (-not [bool]$row[0].Restarted) { throw "Boot: $node was not restarted into the maintenance environment." }
            }
            $evidence = "read-write image and one-time boot on $($NodeName -join ', ')"
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
Write-ZtpRunLog "Next: cluster deployment. Paste $ClusterInputsPath (arc_machine_names) into the cluster deployment environment file; $HandoffPath has the rest. Hardware must not be clustered by this repository."
$results.ToArray()
