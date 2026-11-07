#Requires -Version 7.0
<#
.SYNOPSIS
Shared helpers of the bootstrap completion monitor: the JSON-lines event writer, the pure state machine, the backoff,
and the three credential-free signal readers (BMC Redfish, voucher read-back from the image, Azure prerequisites).
.DESCRIPTION
States of one node, in order: NotStarted -> Mounted -> Booting -> MaintenanceEnvironmentRunning -> VoucherWritten ->
ReadyForPortal. Failure states: MediaRejected, BootStalled, EnvironmentStalled, VoucherMissing, Failed.
Evidence is only what can be read without a credential on the node: Redfish power, boot override and virtual media (read
only), the BMC log services, the voucher in the read-write image, and Azure ARM (read only). Which of these signals is proven
on hardware is stated in docs/bootstrap-media.md; the log patterns come from config/oem/<oem>.json and are
labelled unverified there. No secret is read or written; vouchers are validated and only their SHA256 is reported.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ZtpBootstrapState { [CmdletBinding()][OutputType([string[]])] param() return @('NotStarted', 'Mounted', 'Booting', 'MaintenanceEnvironmentRunning', 'VoucherWritten', 'ReadyForPortal') }
function Get-ZtpBootstrapFailureState { [CmdletBinding()][OutputType([string[]])] param() return @('MediaRejected', 'BootStalled', 'EnvironmentStalled', 'VoucherMissing', 'Failed') }

function Get-ZtpUtcNow { [CmdletBinding()][OutputType([datetime])] param() return [datetime]::UtcNow }

function Wait-ZtpInterval {
    # Sleep seam (the tests mock it).
    [CmdletBinding()]
    param([Parameter(Mandatory)][double]$Seconds)
    Start-Sleep -Seconds $Seconds
}

function Write-ZtpEvent {
    <#
    .SYNOPSIS
    Appends one structured event, one JSON object per line, to the event file the monitor follows:
    { timestamp, node, state, evidence, nextAction } (plus optional level and stage). The file is opened for append with
    read sharing so a reader (Sonar, Get-Content -Wait) can follow it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Evidence,
        [AllowEmptyString()][string]$NextAction = '',
        [ValidateSet('Info', 'Warning', 'Error')][string]$Level = 'Info',
        [string]$Stage = 'Bootstrap'
    )
    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
    $line = ([ordered]@{
            timestamp  = (Get-ZtpUtcNow).ToString('o')
            node       = $Node
            state      = $State
            evidence   = $Evidence
            nextAction = $NextAction
            level      = $Level
            stage      = $Stage
        } | ConvertTo-Json -Compress -Depth 4) + "`n"
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($line)
    for ($attempt = 1; ; $attempt++) {
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            return
        }
        catch [System.IO.IOException] {
            if ($attempt -ge 5) { throw }
            Start-Sleep -Milliseconds (50 * $attempt)
        }
    }
}

function Get-ZtpBootstrapNextState {
    <#
    .SYNOPSIS
    The state a node has reached given the signals read so far (pure). Never moves backwards from -Current and never skips
    past the evidence: a state is reached only when its own rule is satisfied.
    .DESCRIPTION
    Signals (all optional): MediaInserted, PowerOn, BootedFromMedia, ResetCount (int), CompletionLogSeen, VoucherValid,
    AzureReady.
      Mounted                       MediaInserted
      Booting                       Mounted and PowerOn and BootedFromMedia
      MaintenanceEnvironmentRunning Booting and (ResetCount >= 1 or CompletionLogSeen)
      VoucherWritten                VoucherValid (a valid voucher proves the environment ran, so it does not need the earlier signals)
      ReadyForPortal                VoucherValid and AzureReady
    Returns { State, Changed, Evidence } where Evidence lists the signals behind the new state.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('NotStarted', 'Mounted', 'Booting', 'MaintenanceEnvironmentRunning', 'VoucherWritten', 'ReadyForPortal')][string]$Current, [Parameter(Mandatory)][hashtable]$Signals)
    $flag = { param([string]$Name) $Signals.ContainsKey($Name) -and [bool]$Signals[$Name] }
    $resets = if ($Signals.ContainsKey('ResetCount')) { [int]$Signals['ResetCount'] } else { 0 }
    $inserted = & $flag 'MediaInserted'
    $booting = $inserted -and (& $flag 'PowerOn') -and (& $flag 'BootedFromMedia')
    $running = $booting -and ($resets -ge 1 -or (& $flag 'CompletionLogSeen'))
    $voucher = & $flag 'VoucherValid'
    $ready = $voucher -and (& $flag 'AzureReady')
    $computed = 'NotStarted'; $evidence = 'no signal yet'
    if ($inserted) { $computed = 'Mounted'; $evidence = 'virtual media inserted' }
    if ($booting) { $computed = 'Booting'; $evidence = 'power on, one-time boot override consumed or boot log seen' }
    if ($running) { $computed = 'MaintenanceEnvironmentRunning'; $evidence = if (& $flag 'CompletionLogSeen') { 'completion message in the BMC log' } else { "$resets reset(s) after the media boot" } }
    if ($voucher) { $computed = 'VoucherWritten'; $evidence = 'valid ownership voucher read back from the image' }
    if ($ready) { $computed = 'ReadyForPortal'; $evidence = 'valid voucher in hand and Azure prerequisites verified' }
    $order = Get-ZtpBootstrapState
    if ([array]::IndexOf($order, $computed) -le [array]::IndexOf($order, $Current)) {
        return [pscustomobject]@{ State = $Current; Changed = $false; Evidence = $evidence }
    }
    return [pscustomobject]@{ State = $computed; Changed = $true; Evidence = $evidence }
}

function Get-ZtpNextPollInterval {
    <#
    .SYNOPSIS
    Backoff (pure): the base interval while the state keeps changing; otherwise the previous interval times -Factor up to
    -MaxSeconds.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory)][double]$BaseSeconds, [Parameter(Mandatory)][double]$PreviousSeconds, [Parameter(Mandatory)][bool]$StateChanged, [double]$Factor = 1.5, [Parameter(Mandatory)][double]$MaxSeconds)
    if ($StateChanged) { return $BaseSeconds }
    return [math]::Min($MaxSeconds, [math]::Max($BaseSeconds, $PreviousSeconds * $Factor))
}

function Merge-ZtpBmcTracking {
    <#
    .SYNOPSIS
    Folds one BMC reading into the node's tracking record (pure) and returns the signals it justifies.
    .DESCRIPTION
    OverrideArmed: a reading showed the one-time boot override Once/Usb. BootedFromMedia: armed earlier and now the override
    is no longer enabled while the power is on (the BMC consumes a one-time override at the boot) or a log entry matched the
    boot pattern. ResetCount: On -> Off or Off -> On transitions seen after the override was consumed, plus log entries
    matching the reset pattern. Weak and unverified on iDRAC for this media; see the docs.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Tracking, [Parameter(Mandatory)][object]$Reading)
    if ($Reading.OverrideEnabled -eq 'Once' -and $Reading.OverrideTarget -match 'Usb') { $Tracking.OverrideArmed = $true }
    $powerOn = ($Reading.PowerState -eq 'On')
    if ($Tracking.OverrideArmed -and $Reading.OverrideEnabled -ne 'Once' -and $powerOn) { $Tracking.OverrideConsumed = $true }
    if ($Tracking.OverrideConsumed -and $null -ne $Tracking.LastPower -and $Tracking.LastPower -ne $Reading.PowerState) { $Tracking.PowerTransitions++ }
    $Tracking.LastPower = $Reading.PowerState
    foreach ($m in @($Reading.LogMatches)) {
        if ($Tracking.SeenLogIds.Contains([string]$m.Id)) { continue }
        $null = $Tracking.SeenLogIds.Add([string]$m.Id)
        switch ($m.Kind) { 'bootedFromMedia' { $Tracking.LogBoot = $true } 'completion' { $Tracking.LogCompletion = $true } 'reset' { $Tracking.LogResets++ } }
    }
    return @{
        MediaInserted     = [bool]$Reading.MediaInserted
        PowerOn           = $powerOn
        BootedFromMedia   = [bool]($Tracking.OverrideConsumed -or $Tracking.LogBoot)
        ResetCount        = [int]($Tracking.PowerTransitions + $Tracking.LogResets)
        CompletionLogSeen = [bool]$Tracking.LogCompletion
    }
}

function Initialize-ZtpBmcTracking {
    [CmdletBinding()]
    param()
    return @{ OverrideArmed = $false; OverrideConsumed = $false; LastPower = $null; PowerTransitions = 0; LogResets = 0; LogBoot = $false; LogCompletion = $false; SeenLogIds = [System.Collections.Generic.HashSet[string]]::new() }
}

function Get-ZtpBmcReading {
    <#
    .SYNOPSIS
    One read-only look at a BMC: power state, one-time boot override, the USB-stick virtual-media slot and the OEM log
    entries newer than -SinceUtc that match the OEM signal patterns. GET requests only.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Session, [Parameter(Mandatory)][string]$ImageFileName, [Parameter(Mandatory)][object]$Oem, [datetime]$SinceUtc = [datetime]::MinValue)
    # A [datetime] cast from "...Z" arrives as local time; comparing its ticks with UTC log times keeps old entries east or west of UTC.
    $since = if ($SinceUtc.Kind -eq [DateTimeKind]::Local) { $SinceUtc.ToUniversalTime() } else { [datetime]::SpecifyKind($SinceUtc, [DateTimeKind]::Utc) }
    $manager = Get-ZtpRedfishManager -Session $Session
    $system = Get-ZtpRedfishSystem -Session $Session
    $slots = @(Get-ZtpRedfishMember -Session $Session -CollectionPath "$($manager.'@odata.id')/VirtualMedia" | Where-Object { @($_.MediaTypes) -contains 'USBStick' })
    $ours = @($slots | Where-Object { [bool]$_.Inserted -and [string]$_.Image -like "*$ImageFileName" }) | Select-Object -First 1
    $anyInserted = @($slots | Where-Object { [bool]$_.Inserted } | ForEach-Object { [string]$_.Image })
    $boot = if ($system.PSObject.Properties['Boot']) { $system.Boot } else { $null }
    $patterns = @{ bootedFromMedia = @(); completion = @(); reset = @() }
    $signals = if ($Oem.bmc.PSObject.Properties['signals']) { $Oem.bmc.signals } else { $null }
    foreach ($k in 'bootedFromMedia', 'completion', 'reset') { if ($signals -and $signals.PSObject.Properties[$k]) { $patterns[$k] = @($signals.$k) } }
    $hits = [System.Collections.Generic.List[object]]::new()
    foreach ($service in @($Oem.bmc.logServices)) {
        try {
            $entries = Invoke-ZtpRedfish -Session $Session -Path ([string]$service.path)
        }
        catch { Write-Verbose "Log service $($service.id) unreadable: $($_.Exception.Message)"; continue }
        foreach ($e in @($entries.Members)) {
            $created = if ($e.PSObject.Properties['Created'] -and $e.Created) { [datetime]::Parse([string]$e.Created, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal) } else { [datetime]::MinValue }
            if ($created -lt $since) { continue }
            $text = if ($e.PSObject.Properties['Message']) { [string]$e.Message } else { '' }
            foreach ($kind in $patterns.Keys) {
                foreach ($pattern in $patterns[$kind]) {
                    if ($text -match $pattern) { $hits.Add([pscustomobject]@{ Id = "$($service.id):$($e.Id)"; Kind = $kind; Created = $created; Message = $text }); break }
                }
            }
        }
    }
    return [pscustomobject]@{
        PowerState     = [string]$system.PowerState
        OverrideEnabled = if ($boot -and $boot.PSObject.Properties['BootSourceOverrideEnabled']) { [string]$boot.BootSourceOverrideEnabled } else { $null }
        OverrideTarget = if ($boot -and $boot.PSObject.Properties['BootSourceOverrideTarget']) { [string]$boot.BootSourceOverrideTarget } else { $null }
        MediaInserted  = [bool]$ours
        WriteProtected = if ($ours -and $ours.PSObject.Properties['WriteProtected']) { $ours.WriteProtected } else { $null }
        OtherMedia     = @($anyInserted | Where-Object { $_ -notlike "*$ImageFileName" })
        LogMatches     = @($hits)
    }
}

function Get-ZtpImageVoucherSignal {
    <#
    .SYNOPSIS
    Read-only look into the node's read-write image: is there a complete, valid voucher for the node's serial under
    \vouchers\<serial>\? Returns { Present, Valid, Sha256, Detail, ImageLastWriteUtc }; the voucher text is never returned
    or logged. ImageLastWriteUtc is the image file's last write time (null when the file is missing): the nearest thing to
    a write time for the voucher that the host can read without trusting the node's clock.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ImagePath, [Parameter(Mandatory)][string]$Serial)
    if (-not (Test-Path -LiteralPath $ImagePath)) { return [pscustomobject]@{ Present = $false; Valid = $false; Sha256 = $null; Detail = "image not found: $ImagePath"; ImageLastWriteUtc = $null } }
    $written = $null
    try { $written = (Get-Item -LiteralPath $ImagePath).LastWriteTimeUtc } catch { $written = $null }
    try { $probe = Find-ZtpVoucherInImage -ImagePath $ImagePath -AllowOpen }
    catch { return [pscustomobject]@{ Present = $false; Valid = $false; Sha256 = $null; Detail = "image not readable yet: $($_.Exception.Message)"; ImageLastWriteUtc = $written } }
    $candidates = @($probe.Pem | Where-Object { $_.UnderVouchers -and $_.Folder -ieq $Serial -and $null -ne $_.Bytes })
    if ($candidates.Count -eq 0) {
        $detail = if (@($probe.VoucherFolders).Count -gt 0) { "voucher folder(s) $(@($probe.VoucherFolders) -join ', ') without a complete voucher for $Serial yet" } else { 'no \vouchers\ folder yet' }
        return [pscustomobject]@{ Present = $false; Valid = $false; Sha256 = $null; Detail = $detail; ImageLastWriteUtc = $written }
    }
    $check = Test-ZtpOwnershipVoucher -Bytes $candidates[0].Bytes -Serial $Serial
    return [pscustomobject]@{ Present = $true; Valid = [bool]$check.Valid; Sha256 = $check.Sha256; Detail = $(if ($check.Valid) { 'valid' } else { ($check.Problems -join '; ') }); ImageLastWriteUtc = $written }
}

function ConvertTo-ZtpUtcDateTime {
    <#
    .SYNOPSIS
    A time from the run state or a stage result as a UTC [datetime], or $null when there is none or it does not parse. The
    state file stores ISO 8601 strings, which ConvertFrom-Json may hand back already as [datetime].
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $text = [string]$Value
    if (-not $text.Trim()) { return $null }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($text, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { return $parsed.ToUniversalTime() }
    return $null
}

function Get-ZtpVoucherProvenance {
    <#
    .SYNOPSIS
    Does a valid voucher found in a node's image belong to this run? (pure)
    .DESCRIPTION
    The Media stage builds the image without a voucher, and the Boot stage resets the node onto it. A valid voucher in that
    image can therefore only have been written by the node's maintenance environment after the build: a fast node does it
    while Boot is still watching the BMC, before the Bootstrap stage has started. So the baseline is what this run
    recorded, not what the image held when the watch started.
      ImageBuiltAt         when the Media stage built this node's image in this run (state: stages.Media.data.images.<node>.builtAt)
      ResetAt              when the Boot stage reset this node onto that image (state: stages.Boot.data.resetAt.<node>)
      ImageLastWriteUtc    the image file's last write time, when known
    This run's voucher: both times are recorded, the reset is not before the build, and the image was not last written
    before the build. The voucher's own write time is not needed (the node's clock is not trusted); when the image's last
    write time is unknown the reset time is enough. Anything else is not provable as this run's: no record that Media built
    this image and Boot reset the node in this run (an image reused from an earlier run, or Bootstrap run on its own), a
    reset recorded before the build, or an image file older than the recorded build (replaced since).
    Returns { ThisRun, Reason }.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$ImageBuiltAt, [AllowNull()][object]$ResetAt, [AllowNull()][object]$ImageLastWriteUtc)
    $built = ConvertTo-ZtpUtcDateTime $ImageBuiltAt
    $reset = ConvertTo-ZtpUtcDateTime $ResetAt
    $written = ConvertTo-ZtpUtcDateTime $ImageLastWriteUtc
    if ($null -eq $built) { return [pscustomobject]@{ ThisRun = $false; Reason = 'this run has no record that its Media stage built the image' } }
    if ($null -eq $reset) { return [pscustomobject]@{ ThisRun = $false; Reason = 'this run has no record that its Boot stage reset the node onto the image' } }
    if ($reset -lt $built) { return [pscustomobject]@{ ThisRun = $false; Reason = "the recorded reset ($($reset.ToString('o'))) is before the recorded image build ($($built.ToString('o')))" } }
    if ($null -ne $written -and $written -lt $built) { return [pscustomobject]@{ ThisRun = $false; Reason = "the image was last written ($($written.ToString('o'))) before the image build this run recorded ($($built.ToString('o')))" } }
    return [pscustomobject]@{ ThisRun = $true; Reason = "image built $($built.ToString('o')) and node reset onto it $($reset.ToString('o')) in this run, so a voucher in the image was written by this run's maintenance environment" }
}

function Get-ZtpAzureReadiness {
    <#
    .SYNOPSIS
    Read-only ARM check that the subscription can claim a voucher now: the Microsoft.DeviceOnboarding AzureLocalZTP feature is
    Registered, the resource providers Microsoft.AzureStackHCI, Microsoft.Edge, Microsoft.HybridCompute and
    Microsoft.DeviceOnboarding are Registered, and the OS image catalog is readable. Learn documents no Azure-side signal
    for "this device is waiting to be claimed": a device is unknown to Azure until its voucher is submitted. This check
    therefore proves the Azure side is ready, not that the device was seen.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$Location, [string]$ApiVersion = '2026-10-01')
    $problems = [System.Collections.Generic.List[string]]::new()
    $feature = Invoke-ZtpArm -Method GET -ApiVersion '2021-07-01' -AllowNotFound -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Features/featureProviders/Microsoft.DeviceOnboarding/subscriptionFeatureRegistrations/AzureLocalZTP"
    $featureState = [string](Get-ZtpPathValue $feature 'properties.state' '')
    if ($featureState -ne 'Registered') { $problems.Add("feature Microsoft.DeviceOnboarding/AzureLocalZTP is '$(if ($featureState) { $featureState } else { 'not found' })' (az feature register --namespace Microsoft.DeviceOnboarding --name AzureLocalZTP)") }
    foreach ($ns in 'Microsoft.AzureStackHCI', 'Microsoft.Edge', 'Microsoft.HybridCompute', 'Microsoft.DeviceOnboarding') {
        $provider = Invoke-ZtpArm -Method GET -ApiVersion '2021-04-01' -AllowNotFound -Path "/subscriptions/$SubscriptionId/providers/$ns"
        $state = [string](Get-ZtpPathValue $provider 'registrationState' '')
        if ($state -ne 'Registered') { $problems.Add("resource provider $ns is '$(if ($state) { $state } else { 'not found' })'") }
    }
    try { $catalog = @(Get-ZtpOsImageCatalog -SubscriptionId $SubscriptionId -Location $Location -ApiVersion $ApiVersion); if ($catalog.Count -eq 0) { $problems.Add("the OS image catalog of $Location is empty") } }
    catch { $problems.Add("the OS image catalog of $Location is unreadable: $($_.Exception.Message)") }
    return [pscustomobject]@{ Ready = ($problems.Count -eq 0); Problems = @($problems); Detail = $(if ($problems.Count -eq 0) { 'feature, providers and OS image catalog verified' } else { $problems -join '; ' }) }
}
