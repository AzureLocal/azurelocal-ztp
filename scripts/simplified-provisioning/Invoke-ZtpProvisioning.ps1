#Requires -Version 7.0
<#
.SYNOPSIS
Zero-touch provisioning of Azure Local machines, end to end: Media -> Boot -> Vouchers -> Azure -> Ready.
.DESCRIPTION
One orchestrator over the stage scripts in this folder. Every input is a parameter, or a key of the same name in a JSON
settings file (-ConfigPath; see config/simplified-provisioning/ztp-provisioning.example.json). A parameter wins over the
file; nothing is hardcoded.
  Media     New-ZtpVirtualUsbImage.ps1 -NodeName: one virtual-USB image per node (<ImageNamePrefix><node>.img in
            -ImageDirectory) from the maintenance ISO (-SourcePath), GPT with one FAT32 partition labelled CDROM.
  Boot      Start-MaintenanceBoot.ps1: shares the images read-write in place (one account, TCP 445 only from the BMCs),
            inserts each node's image on the BMC USB-stick slot with WriteProtected=false, proves the attach, sets a
            one-time USB boot and power-cycles the node. Needs -ConfirmNotClustered: the maintenance environment
            reinstalls the machine.
  Vouchers  Wait-ZtpVoucher.ps1: waits until the maintenance environment wrote \vouchers\<serial>\*.pem into each image,
            ejects the media, writes <serial>.pem into -VoucherDirectory. -VoucherFolder takes vouchers downloaded with
            the Configurator App instead (it only works if the USB export did not happen). Then the share, its firewall
            rule and account are removed (-KeepShare keeps them).
  Azure     Invoke-ZtpAzureProvisioning.ps1 stages Prereqs, Validate, Plan, Execute: site, site configuration and edge
            machines claimed with the vouchers. Refuses to submit when a voucher is missing.
  Ready     Invoke-ZtpAzureProvisioning.ps1 -Stage Watch: waits until every machine is ready to cluster and returns (or,
            with -ArcMachineNameMapPath, writes) each node's Arc machine name; then Test-ProvisionedMachines.ps1.
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
    [ValidateSet('Media', 'Boot', 'Vouchers', 'Azure', 'Ready', 'All')][string]$Stage = 'All',
    [ValidateSet('Media', 'Boot', 'Vouchers', 'Azure', 'Ready')][string]$From,
    [string]$ConfigPath,
    [string]$NodesFile,
    [string[]]$NodeName,
    [string]$SourcePath,
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

$order = @('Media', 'Boot', 'Vouchers', 'Azure', 'Ready')
function Write-ZtpRunLog {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message, [ValidateSet('Info', 'Warning')][string]$Level = 'Info')
    $line = "[$([datetime]::UtcNow.ToString('HH:mm:ss'))Z] [ztp] $Message"
    if ($Level -eq 'Warning') { Write-Warning $line } else { Write-Information -MessageData $line -InformationAction Continue }
}

# ------------------------------------------------------------------ settings: parameter > -ConfigPath > default
$settable = @('NodesFile', 'NodeName', 'SourcePath', 'ImageDirectory', 'ImageNamePrefix', 'ShareHost', 'ShareName', 'VoucherDirectory',
    'VoucherFolder', 'VoucherWaitMinutes', 'RfsWriteAttribute', 'SkipCertificateCheck', 'KeepShare', 'SubscriptionId', 'ResourceGroupName',
    'ParameterFile', 'OsVersion', 'SiteMode', 'DeploymentName', 'ArcMachineNameMapPath', 'ReadyTimeoutMinutes', 'PollIntervalSeconds', 'StatePath')
if ($ConfigPath) {
    $settings = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
    foreach ($key in $settings.Keys) {
        if ($key -notin $settable) { throw "Unknown key '$key' in $ConfigPath. Keys: $($settable -join ', ')." }
        if ($PSBoundParameters.ContainsKey($key)) { continue }
        $value = $settings[$key]
        if ($key -in 'RfsWriteAttribute', 'SkipCertificateCheck', 'KeepShare') { $value = [switch][bool]$value }
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
    switch ($Name) {
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
        'Media' { $need.SourcePath = $SourcePath; $need.ImageDirectory = $ImageDirectory }
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
    foreach ($name in $run) { foreach ($call in (Get-ZtpStageCall -Name $name -ForExecute)) { Write-ZtpRunLog "$name would run: $(Format-ZtpCall -Call $call)" } }
    $next = $run[0]
    if ($next -in 'Media', 'Boot', 'Azure') {
        Write-ZtpRunLog "Plan of the next stage ($next), from its own script:"
        try { foreach ($call in (Get-ZtpStageCall -Name $next)) { Invoke-ZtpStageScript -Call $call } }
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
    switch ($name) {
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
    $state['stages'][$name] = [ordered]@{ completed = [datetime]::UtcNow.ToString('o'); evidence = $evidence }
    Save-ZtpRunState
    $minutes = [int]((Get-Date) - $stageStart).TotalMinutes
    Write-ZtpRunLog "Stage $name completed in $minutes min: $evidence"
    $results.Add([pscustomobject]@{ Stage = $name; Result = 'Completed'; Minutes = $minutes; Evidence = $evidence })
}
Write-ZtpRunLog 'Next: OEM driver and node preparation, then cluster deployment with each edge machine''s arcMachineResourceId (outside this repository).'
$results.ToArray()
