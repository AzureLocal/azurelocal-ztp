#Requires -Version 7.0
<#
.SYNOPSIS
Watches nodes booted from the virtual USB until each one's bootstrap is done and a valid voucher is ready to claim in
Azure. One polling loop, clear states, structured events. Read-only: GET requests and image reads only.
.DESCRIPTION
States per node: NotStarted -> Mounted -> Booting -> MaintenanceEnvironmentRunning -> VoucherWritten -> ReadyForPortal.
Failure states: MediaRejected (image not inserted, another image in the slot, or inserted write-protected), VoucherMissing
(no valid voucher within -VoucherTimeoutMinutes), Failed. Every transition is one JSON line in -EventLogPath:
{ timestamp, node, state, evidence, nextAction, level, stage }.
Signals, all without a credential on the node:
  Redfish (read only)  virtual media inserted and write-protection, power state, the one-time boot override being consumed,
                       power transitions after that, and BMC log entries matching the OEM patterns (config/oem/<oem>.json).
  Image read-back      \vouchers\<serial>\*.pem in the read-write image, validated (the decisive signal).
  Configurator App     -VoucherFolder replaces the BMC and image signals with a folder of downloaded vouchers.
  Azure (read only)    feature Microsoft.DeviceOnboarding/AzureLocalZTP, resource providers and the OS image catalog
                       (-SubscriptionId, -Location). Learn documents no Azure-side signal that a device is waiting to be
                       claimed: a device is unknown to Azure until its voucher is submitted, so ReadyForPortal means
                       "voucher in hand and Azure prerequisites verified", not "Azure saw the device".
The Booting and MaintenanceEnvironmentRunning signals are weak and unverified on hardware; a node is never failed for
missing them (a stall only emits a warning event). Only the voucher deadline fails a node.
Polling starts at -PollSeconds and backs off by 1.5x up to -MaxPollSeconds while nothing changes.
.PARAMETER NodeName
Nodes to watch.
.PARAMETER Nodes
Node objects { name, service_tag, bmc_address }.
.PARAMETER NodesFile
Node list file (see config/simplified-provisioning/nodes.example.json).
.PARAMETER ImageDirectory
Folder of the per-node images (the ones mounted on the BMCs).
.PARAMETER ImageNamePrefix
Image file-name prefix.
.PARAMETER Oem
OEM definition in config/oem (default Dell).
.PARAMETER Credential
BMC account (read-only use here). Not needed with -VoucherFolder.
.PARAMETER VoucherFolder
Configurator App voucher folder (fallback; replaces the BMC and image signals).
.PARAMETER SubscriptionId
Subscription for the Azure prerequisite check.
.PARAMETER Location
Provisioning region for the catalog check (preview: eastus).
.PARAMETER SkipAzureCheck
Do not check Azure; a valid voucher alone reaches ReadyForPortal (the event says so).
.PARAMETER EventLogPath
JSON-lines event file (default ./ztp-events.jsonl).
.PARAMETER TimeoutMinutes
Overall budget.
.PARAMETER VoucherTimeoutMinutes
Budget from the start until a valid voucher appears (Learn: setup takes up to 30 minutes with two reboots).
.PARAMETER StallMinutes
Minutes in Mounted, Booting or MaintenanceEnvironmentRunning without change before a warning event.
.PARAMETER Execute
Run the watch. Without it only the plan is printed.
.EXAMPLE
./Wait-ZtpBootstrapComplete.ps1 -NodeName node-01,node-02 -NodesFile ./nodes.json -ImageDirectory D:\ZtpVirtualUsb -Credential $bmc -SkipCertificateCheck -SubscriptionId 00000000-0000-0000-0000-000000000000 -Location eastus -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateCount(1, 64)][string[]]$NodeName,
    [object[]]$Nodes,
    [string]$NodesFile,
    [string]$ImageDirectory,
    [ValidatePattern('^[A-Za-z0-9._-]{0,40}$')][string]$ImageNamePrefix = 'ztp-usb-',
    [ValidatePattern('^[A-Za-z0-9_-]{1,40}$')][string]$Oem = 'Dell',
    [pscredential]$Credential,
    [string]$VoucherFolder,
    [ValidatePattern('^$|^[0-9a-fA-F-]{36}$')][string]$SubscriptionId,
    [string]$Location = 'eastus',
    [switch]$SkipAzureCheck,
    [switch]$SkipCertificateCheck,
    [string]$EventLogPath = (Join-Path (Get-Location) 'ztp-events.jsonl'),
    [ValidateRange(1, 1440)][int]$TimeoutMinutes = 120,
    [ValidateRange(1, 1440)][int]$VoucherTimeoutMinutes = 90,
    [ValidateRange(1, 240)][int]$StallMinutes = 20,
    [ValidateRange(1, 3600)][int]$PollSeconds = 15,
    [ValidateRange(1, 3600)][int]$MaxPollSeconds = 120,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpVirtualUsb.Common.ps1')
. (Join-Path $PSScriptRoot 'ZtpAzure.Common.ps1')
. (Join-Path $PSScriptRoot 'ZtpSbe.Common.ps1')
if (-not (Get-Command Get-ZtpBmcReading -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ZtpEvents.Common.ps1') }
if (-not (Get-Command New-ZtpRedfishSession -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ZtpRedfish.Common.ps1') }

$folderMode = [bool]$VoucherFolder
if (-not $folderMode -and -not $ImageDirectory) { throw 'Pass -ImageDirectory (image read-back) or -VoucherFolder (Configurator App fallback).' }
if ($Execute -and -not $folderMode -and -not $Credential) { throw '-Credential (the BMC account, read-only use) is required with -Execute unless -VoucherFolder is used.' }
if ($MaxPollSeconds -lt $PollSeconds) { throw '-MaxPollSeconds must not be below -PollSeconds.' }
if (-not $SkipAzureCheck -and $Execute -and -not $SubscriptionId) { throw 'Pass -SubscriptionId for the Azure prerequisite check, or -SkipAzureCheck.' }
$oemConfig = Get-ZtpOemConfig -Oem $Oem
$known = @(Get-ZtpNodeList -Nodes $Nodes -NodesFile $NodesFile -NodeName $NodeName -RequireSerial)
$targets = if ($folderMode) { @() } else { @(Get-ZtpBmcTarget -NodeName $NodeName -Nodes $Nodes -NodesFile $NodesFile) }

if (-not $Execute) {
    foreach ($node in $known) {
        "PLAN: $($node.Name) ($($node.Serial)) watch$(if ($folderMode) { " $VoucherFolder for the Configurator App voucher" } else { " the $($oemConfig.oem) BMC (virtual media, power, boot override, $(@($oemConfig.bmc.logServices).Count) log service(s)) and the voucher in $(Join-Path $ImageDirectory (Get-ZtpNodeImageName -NodeName $node.Name -Prefix $ImageNamePrefix))" })"
    }
    "PLAN: states NotStarted > Mounted > Booting > MaintenanceEnvironmentRunning > VoucherWritten > ReadyForPortal; events to $EventLogPath; poll $PollSeconds s backing off to $MaxPollSeconds s; voucher deadline $VoucherTimeoutMinutes min, overall $TimeoutMinutes min."
    "PLAN: ReadyForPortal also needs the Azure prerequisite check$(if ($SkipAzureCheck) { ' (skipped by -SkipAzureCheck)' } else { " on subscription $SubscriptionId ($Location)" })."
    return
}

$start = Get-ZtpUtcNow
$overallDeadline = $start.AddMinutes($TimeoutMinutes)
$voucherDeadline = $start.AddMinutes($VoucherTimeoutMinutes)
$nextActions = @{
    NotStarted                    = 'Waiting for the first signal: mount the virtual USB and boot the node (Start-MaintenanceBoot.ps1).'
    Mounted                       = 'Waiting for the node to boot from the virtual USB.'
    Booting                       = 'Waiting for the maintenance environment (about 30 minutes, two reboots).'
    MaintenanceEnvironmentRunning = 'Waiting for the ownership voucher to be written into the image.'
    VoucherWritten                = 'Checking that Azure is ready to claim the voucher.'
    ReadyForPortal                = 'Collect the voucher (Wait-ZtpVoucher.ps1), then create the site and edge machine (Invoke-ZtpAzureProvisioning.ps1).'
}
$rows = @{}
foreach ($node in $known) {
    $rows[$node.Name] = [ordered]@{
        Node = $node.Name; Serial = $node.Serial; State = 'NotStarted'; Evidence = ''; Since = $start; Terminal = $false; Warned = $false
        Tracking = (Initialize-ZtpBmcTracking); StaleWarned = $false; Baseline = $null; Session = $null; VoucherSha256 = $null; Image = $(if ($folderMode) { $null } else { Join-Path $ImageDirectory (Get-ZtpNodeImageName -NodeName $node.Name -Prefix $ImageNamePrefix) })
        LastDetail = ''; MediaMissingSince = $null; Bmc = $(if ($folderMode) { $null } else { @($targets | Where-Object Node -EQ $node.Name)[0].Address })
    }
    Write-ZtpEvent -Path $EventLogPath -Node $node.Name -State 'NotStarted' -Evidence 'bootstrap watch started' -NextAction $nextActions['NotStarted']
}
$azure = $null; $azureAt = [datetime]::MinValue
$interval = [double]$PollSeconds
$sessionArgs = @{}
if ($SkipCertificateCheck) { $sessionArgs.SkipCertificateCheck = $true }

try {
    while ($true) {
        $changedAny = $false
        foreach ($row in @($rows.Values | Where-Object { -not $_.Terminal })) {
            $now = Get-ZtpUtcNow
            $signals = @{}
            $detail = @()
            $reject = $null
            # ---- BMC (read only)
            if (-not $folderMode) {
                try {
                    if (-not $row.Session) { $row.Session = New-ZtpRedfishSession -BmcAddress $row.Bmc -Credential $Credential @sessionArgs }
                    $reading = Get-ZtpBmcReading -Session $row.Session -ImageFileName (Get-ZtpNodeImageName -NodeName $row.Node -Prefix $ImageNamePrefix) -Oem $oemConfig -SinceUtc $start
                    $signals = Merge-ZtpBmcTracking -Tracking $row.Tracking -Reading $reading
                    $detail += "BMC power $($reading.PowerState), override $($reading.OverrideEnabled)/$($reading.OverrideTarget), media inserted $($reading.MediaInserted)"
                    if ($reading.MediaInserted -and $reading.WriteProtected -eq $true) {
                        $reject = @{ Evidence = 'the image is attached write-protected, so the voucher cannot be written back'; NextAction = 'Re-mount read-write (Mount-ZtpVirtualUsb.ps1 -RfsWriteAttribute) or use the Configurator App fallback (-VoucherFolder).' }
                    }
                    if (-not $reading.MediaInserted) {
                        if (-not $row.MediaMissingSince) { $row.MediaMissingSince = $now }
                        if ($row.State -eq 'NotStarted' -and ($now - $row.MediaMissingSince).TotalMinutes -ge 3) {
                            $other = if (@($reading.OtherMedia).Count -gt 0) { "the USB-stick slot holds $(@($reading.OtherMedia) -join ', ')" } else { 'nothing is inserted on the USB-stick slot' }
                            $reject = @{ Evidence = "our image is not inserted after 3 minutes: $other"; NextAction = 'Mount the image (Mount-ZtpVirtualUsb.ps1 -Execute) and watch again.' }
                        }
                    }
                    else { $row.MediaMissingSince = $null }
                }
                catch {
                    $detail += "BMC unreadable: $($_.Exception.Message)"
                    if ($row.Session) { Remove-ZtpRedfishSession -Session $row.Session; $row.Session = $null }
                }
            }
            # ---- voucher: image read-back or the Configurator App folder
            $voucherValid = $false
            if ($folderMode) {
                $files = @(Get-ChildItem -LiteralPath $VoucherFolder -Filter '*.pem' -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -ieq $row.Serial -or $_.Directory.Name -ieq $row.Serial })
                if ($files.Count -eq 1 -and $files[0].Length -le 1MB) {
                    $check = Test-ZtpOwnershipVoucher -Bytes ([System.IO.File]::ReadAllBytes($files[0].FullName)) -Serial $row.Serial
                    $voucherValid = [bool]$check.Valid; if ($voucherValid) { $row.VoucherSha256 = $check.Sha256 } else { $detail += "voucher file invalid: $($check.Problems -join '; ')" }
                }
                else { $detail += "expected one voucher for $($row.Serial) in $VoucherFolder; found $($files.Count)" }
                $signals.MediaInserted = $true; $signals.PowerOn = $true; $signals.BootedFromMedia = $true; $signals.ResetCount = 1
            }
            else {
                $v = Get-ZtpImageVoucherSignal -ImagePath $row.Image -Serial $row.Serial
                $voucherValid = [bool]$v.Valid; if ($v.Valid) { $row.VoucherSha256 = $v.Sha256 }
                $detail += "image: $($v.Detail)"
            }
            if ($voucherValid -and $row.State -eq 'NotStarted' -and -not $folderMode -and -not $row.StaleWarned) {
                $row.StaleWarned = $true; $row.Baseline = $row.VoucherSha256
                Write-ZtpEvent -Path $EventLogPath -Node $row.Node -State 'NotStarted' -Evidence 'a valid voucher is already in the image before the node was seen booting from it: an image reused from an earlier run?' -NextAction 'Rebuild the image (Invoke-ZtpProvisioning.ps1 -RebuildImages) unless the reuse is intended; a redeployed OS issues a new voucher.' -Level Warning
            }
            # A voucher that was already in the image before the node was seen booting from it is not accepted as new until the node is seen booting (or the voucher changes).
            if ($voucherValid -and -not $folderMode -and $row.State -in 'NotStarted', 'Mounted' -and $row.Baseline -and $row.VoucherSha256 -eq $row.Baseline) { $voucherValid = $false; $detail += 'voucher unchanged since before the boot; waiting for boot evidence' }
            if ($reject -and -not $voucherValid) {
                $row.Terminal = $true; $row.State = 'MediaRejected'; $row.Evidence = $reject.Evidence
                Write-ZtpEvent -Path $EventLogPath -Node $row.Node -State 'MediaRejected' -Evidence $row.Evidence -NextAction $reject.NextAction -Level Error
                $changedAny = $true; continue
            }
            $signals.VoucherValid = $voucherValid
            # ---- Azure (read only, cached 5 minutes), only once there is a voucher to claim
            $signals.AzureReady = $false
            if ($voucherValid) {
                if ($SkipAzureCheck) { $signals.AzureReady = $true }
                else {
                    if (-not $azure -or ($now - $azureAt).TotalMinutes -ge 5) { $azure = Get-ZtpAzureReadiness -SubscriptionId $SubscriptionId -Location $Location; $azureAt = $now }
                    $signals.AzureReady = [bool]$azure.Ready
                    if (-not $azure.Ready) { $detail += "Azure not ready: $($azure.Detail)" }
                }
            }
            # ---- state machine
            $next = Get-ZtpBootstrapNextState -Current $row.State -Signals $signals
            if ($next.Changed) {
                $evidence = $next.Evidence
                if ($next.State -eq 'ReadyForPortal' -and $SkipAzureCheck) { $evidence += ' (Azure check skipped)' }
                if ($next.State -in 'VoucherWritten', 'ReadyForPortal' -and $row.VoucherSha256) { $evidence += "; voucher SHA256 $($row.VoucherSha256)" }
                if ($next.State -eq 'ReadyForPortal' -and $row.State -ne 'VoucherWritten') {
                    Write-ZtpEvent -Path $EventLogPath -Node $row.Node -State 'VoucherWritten' -Evidence "valid ownership voucher read back from the image; voucher SHA256 $($row.VoucherSha256)" -NextAction $nextActions['VoucherWritten']
                }
                $row.State = $next.State; $row.Evidence = $evidence; $row.Since = $now; $row.Warned = $false
                Write-ZtpEvent -Path $EventLogPath -Node $row.Node -State $next.State -Evidence $evidence -NextAction $nextActions[$next.State]
                $changedAny = $true
                if ($next.State -eq 'ReadyForPortal') { $row.Terminal = $true; continue }
            }
            else {
                $text = $detail -join '; '
                if ($text -and $text -ne $row.LastDetail -and $row.State -eq 'VoucherWritten') {
                    Write-ZtpEvent -Path $EventLogPath -Node $row.Node -State $row.State -Evidence $text -NextAction $nextActions[$row.State] -Level Warning
                }
                $row.LastDetail = $text
                if (-not $row.Warned -and $row.State -in 'NotStarted', 'Mounted', 'Booting', 'MaintenanceEnvironmentRunning' -and ($now - $row.Since).TotalMinutes -ge $StallMinutes) {
                    $row.Warned = $true
                    Write-ZtpEvent -Path $EventLogPath -Node $row.Node -State $row.State -Evidence "no change for $StallMinutes minutes ($text)" -NextAction 'Check the node console (iDRAC virtual console) and the BMC log; the BMC signals are weak, the voucher is decisive.' -Level Warning
                }
            }
            if ($row.State -ne 'ReadyForPortal' -and $now -ge $voucherDeadline -and -not $voucherValid) {
                $row.Terminal = $true; $row.State = 'VoucherMissing'; $row.Evidence = "no valid voucher within $VoucherTimeoutMinutes minutes ($($detail -join '; '))"
                Write-ZtpEvent -Path $EventLogPath -Node $row.Node -State 'VoucherMissing' -Evidence $row.Evidence -NextAction 'Look at the console; fall back to the Configurator App (Wait-ZtpVoucher.ps1 -VoucherFolder, or this script with -VoucherFolder).' -Level Error
                $changedAny = $true
            }
        }
        if (@($rows.Values | Where-Object { -not $_.Terminal }).Count -eq 0) { break }
        if ((Get-ZtpUtcNow) -ge $overallDeadline) {
            foreach ($row in @($rows.Values | Where-Object { -not $_.Terminal })) {
                $row.Terminal = $true; $previous = $row.State
                $row.Evidence = "overall budget of $TimeoutMinutes minutes reached in state $previous"
                $row.State = 'Failed'
                Write-ZtpEvent -Path $EventLogPath -Node $row.Node -State 'Failed' -Evidence $row.Evidence -NextAction 'Investigate the node, then rerun; vouchers already written stay in the image.' -Level Error
            }
            break
        }
        $interval = Get-ZtpNextPollInterval -BaseSeconds $PollSeconds -PreviousSeconds $interval -StateChanged $changedAny -MaxSeconds $MaxPollSeconds
        Wait-ZtpInterval -Seconds $interval
    }
}
finally {
    foreach ($row in $rows.Values) { if ($row.Session) { Remove-ZtpRedfishSession -Session $row.Session } }
}

$elapsed = [math]::Round(((Get-ZtpUtcNow) - $start).TotalMinutes, 1)
$results = foreach ($row in $rows.Values) {
    [pscustomobject]@{ Node = $row.Node; Serial = $row.Serial; State = $row.State; Ready = ($row.State -eq 'ReadyForPortal'); Evidence = $row.Evidence; VoucherSha256 = $row.VoucherSha256; Minutes = $elapsed; EventLogPath = $EventLogPath }
}
$results = @($results | Sort-Object Node)
$bad = @($results | Where-Object { -not $_.Ready })
if ($bad.Count -gt 0) { Write-ZtpLog "Not ready: $(($bad | ForEach-Object { "$($_.Node)=$($_.State)" }) -join ', '). See $EventLogPath." -Level Warning }
return $results
