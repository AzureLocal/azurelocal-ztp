#Requires -Version 7.0
<#
.SYNOPSIS
Sets a node's BIOS attributes through its BMC's Redfish service before the maintenance boot, idempotently.
.DESCRIPTION
1. Reads the Bios resource of the computer system and compares every attribute in -Attributes with its current value.
   An attribute the BIOS doesn't have stops the run before anything changes. Nothing to change: done.
2. PATCHes only the attributes that differ to the Bios Settings resource (the @Redfish.Settings object, normally
   .../Bios/Settings) with @Redfish.SettingsApplyTime ApplyTime OnReset. Values the BIOS already holds as pending are not
   sent again.
3. Applies them: powers the node on (On) when it is off, otherwise restarts it (ForceRestart). A BIOS change only takes
   effect at a reset, and the Boot stage reinstalls the machine anyway, so -ConfirmNotClustered is required.
4. Waits until the Bios resource reports every value, then reads it once more.
Every change is appended to -ChangeLogPath (JSON lines: time, node, BMC, attribute, before, after, phase original (the
value found, before the first change), requested and applied). The result's Original holds every requested attribute's
value as found, which the orchestrator keeps in its run state for the Restore stage. Without -Execute it prints the plan: with -Credential, the current values and what would change; without it,
the values it would set. Dell examples: Slot2 Disabled (turns off the card in PCIe slot 2), EmbNic1Nic2 Enabled (the
embedded LOM ports when they show as DisabledOs).
.PARAMETER NodeName
The node, for messages and the change log.
.PARAMETER BmcAddress
Its BMC.
.PARAMETER Attributes
Attribute name -> value (strings), for example @{ Slot2 = 'Disabled'; EmbNic1Nic2 = 'Enabled' }.
.PARAMETER Reason
Attribute name -> why ZTP chose it, for the attributes it derived from the inventory (a slot label and the vendor). Only used
in the message when the BIOS has no such attribute.
.PARAMETER Credential
BMC account (required with -Execute).
.PARAMETER ChangeLogPath
JSON-lines file every change is appended to. Optional.
.PARAMETER TimeoutMinutes
How long to wait for the BIOS to report the new values after the reset. 0 checks once.
.PARAMETER PollSeconds
How often to read the BIOS while waiting.
.PARAMETER ConfirmNotClustered
Confirms the node carries no cluster to keep: applying the settings restarts it.
.PARAMETER SkipCertificateCheck
Accept the BMC's self-signed certificate.
.PARAMETER Execute
Make the changes; without it only the plan is printed.
.EXAMPLE
./Set-ZtpBios.ps1 -NodeName node-01 -BmcAddress 198.51.100.11 -Attributes @{ Slot2 = 'Disabled' } -Credential $bmc -SkipCertificateCheck
.EXAMPLE
./Set-ZtpBios.ps1 -NodeName node-01 -BmcAddress 198.51.100.11 -Attributes @{ Slot2 = 'Disabled' } -Credential $bmc -ConfirmNotClustered -SkipCertificateCheck -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$NodeName,
    [Parameter(Mandatory)][string]$BmcAddress,
    [Parameter(Mandatory)][System.Collections.IDictionary]$Attributes,
    [System.Collections.IDictionary]$Reason,
    [pscredential]$Credential,
    [string]$ChangeLogPath,
    [ValidateRange(0, 240)][int]$TimeoutMinutes = 30,
    [ValidateRange(1, 600)][int]$PollSeconds = 30,
    [switch]$ConfirmNotClustered,
    [switch]$SkipCertificateCheck,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpBios.Common.ps1')
if (-not (Get-Command New-ZtpRedfishSession -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ZtpRedfish.Common.ps1') }

$want = [ordered]@{}
foreach ($k in $Attributes.Keys) { $want[[string]$k] = [string]$Attributes[$k] }
# Original: every requested attribute's value as the BIOS reported it before this run changed anything (the Restore
# stage sets temporary values back to it).
$original = [ordered]@{}
$row = { param([string]$Status, [object[]]$Changes) [pscustomobject]@{ Node = $NodeName; Bmc = $BmcAddress; Status = $Status; Changes = @($Changes | ForEach-Object { "$($_.Attribute): $($_.Current) -> $($_.Desired)" }); Original = $original } }
if ($want.Count -eq 0) { return (& $row 'None' @()) }
$text = ($want.Keys | ForEach-Object { "$_=$($want[$_])" }) -join ', '
if ($Execute -and -not $Credential) { throw '-Credential (the BMC account) is required with -Execute.' }
if ($Execute -and -not $ConfirmNotClustered) { throw "Refusing to change the BIOS of ${NodeName}: applying it restarts the node. Pass -ConfirmNotClustered." }

function Write-BiosLog([string]$Phase, [object[]]$Changes) {
    if (-not $ChangeLogPath) { return }
    $dir = Split-Path -Parent $ChangeLogPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    foreach ($c in $Changes) {
        $line = [ordered]@{ timestamp = [datetime]::UtcNow.ToString('o'); node = $NodeName; bmc = $BmcAddress; attribute = $c.Attribute; before = $c.Current; after = $c.Desired; phase = $Phase } | ConvertTo-Json -Compress
        Add-Content -LiteralPath $ChangeLogPath -Value $line
    }
}

if (-not $Execute -and -not $Credential) {
    "PLAN: $NodeName BIOS $text (reads the current values first and changes only those that differ; then powers the node on or restarts it to apply them, and waits for the BIOS to report them)"
    return
}

$sessionParameters = @{ BmcAddress = $BmcAddress; Credential = $Credential }
if ($SkipCertificateCheck) { $sessionParameters.SkipCertificateCheck = $true }
$session = New-ZtpRedfishSession @sessionParameters
try {
    $system = Get-ZtpRedfishSystem -Session $session
    $biosPath = if ($system.PSObject.Properties['Bios'] -and $system.Bios.PSObject.Properties['@odata.id']) { [string]$system.Bios.'@odata.id' } else { "$($system.'@odata.id')/Bios" }
    $bios = Invoke-ZtpRedfish -Session $session -Path $biosPath
    $changes = @(Get-ZtpBiosChange -Current $bios.Attributes -Desired $want -Reason $Reason)
    # Before any change (also in the read-only pass the Boot stage runs on every node first): a value the BMC doesn't allow.
    if ($changes.Count) {
        $refused = @(Get-ZtpBiosDisallowedValue -Change $changes -Allowed (Get-ZtpBiosAllowedValue -Session $session -Bios $bios -NodeName $NodeName) -NodeName $NodeName -BmcAddress $BmcAddress)
        if ($refused.Count) { throw "Nothing was changed. $($refused -join ' ')" }
    }
    foreach ($k in $want.Keys) { $v = $bios.Attributes.$k; $original[$k] = $(if ($v -is [bool]) { $v.ToString().ToLowerInvariant() } else { [string]$v }) }
    if ($changes.Count -eq 0) {
        Write-Information -MessageData "$NodeName BIOS: already $text." -InformationAction Continue
        return (& $row 'AlreadySet' @())
    }
    if (-not $Execute) {
        foreach ($c in $changes) { "PLAN: $NodeName BIOS $($c.Attribute) $($c.Current) -> $($c.Desired)" }
        "PLAN: $NodeName apply at a reset (power on, or restart), then wait for the BIOS to report the new values"
        return
    }
    if (-not $PSCmdlet.ShouldProcess("$NodeName ($BmcAddress)", "Set BIOS $(@($changes | ForEach-Object { "$($_.Attribute)=$($_.Desired)" }) -join ', ') and restart to apply")) { return }
    # Before the first change: each attribute's value as found, so it can be set back.
    Write-BiosLog 'original' @($changes | ForEach-Object { [pscustomobject]@{ Attribute = $_.Attribute; Current = $_.Current; Desired = $_.Current } })

    $settingsPath = if ($bios.PSObject.Properties['@Redfish.Settings'] -and $bios.'@Redfish.Settings'.SettingsObject.'@odata.id') { [string]$bios.'@Redfish.Settings'.SettingsObject.'@odata.id' } else { "$biosPath/Settings" }
    # A value already pending (an earlier run stopped before the reset) isn't sent again: the BMC refuses a second job.
    $pending = Invoke-ZtpRedfish -Session $session -Path $settingsPath
    $pendingAttributes = if ($pending -and $pending.PSObject.Properties['Attributes']) { $pending.Attributes } else { $null }
    $send = @($changes | Where-Object { -not ($pendingAttributes -and $pendingAttributes.PSObject.Properties[$_.Attribute] -and [string]$pendingAttributes.($_.Attribute) -ceq $_.Desired) })
    if ($send.Count -gt 0) {
        $patch = [ordered]@{}
        foreach ($c in $send) { $patch[$c.Attribute] = $c.Value }
        $null = Invoke-ZtpRedfish -Session $session -Path $settingsPath -Method Patch -Body @{ Attributes = $patch; '@Redfish.SettingsApplyTime' = @{ ApplyTime = 'OnReset' } }
    }
    Write-BiosLog 'requested' $changes
    Write-Information -MessageData "$NodeName BIOS: requested $(@($changes | ForEach-Object { "$($_.Attribute) $($_.Current) -> $($_.Desired)" }) -join ', ') (OnReset)." -InformationAction Continue

    $power = Invoke-ZtpRedfish -Session $session -Path $system.'@odata.id'
    $resetType = if ($power -and $power.PSObject.Properties['PowerState'] -and [string]$power.PowerState -eq 'Off') { 'On' } else { 'ForceRestart' }
    $null = Invoke-ZtpRedfish -Session $session -Path "$($system.'@odata.id')/Actions/ComputerSystem.Reset" -Method Post -Body @{ ResetType = $resetType }
    Write-Information -MessageData "$NodeName BIOS: $resetType to apply; waiting up to $TimeoutMinutes minutes for the BIOS to report the new values." -InformationAction Continue

    $deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
    while ($true) {
        Start-Sleep -Seconds $PollSeconds
        $left = @()
        try {
            $now = Invoke-ZtpRedfish -Session $session -Path $biosPath
            $left = @(Get-ZtpBiosChange -Current $now.Attributes -Desired $want)
        }
        catch { $left = @($changes); Write-Verbose "$NodeName BIOS not readable yet: $($_.Exception.Message)" }
        if ($left.Count -eq 0) { break }
        if ([datetime]::UtcNow -gt $deadline) { throw "$NodeName BIOS still reports $(@($left | ForEach-Object { "$($_.Attribute)=$($_.Current)" }) -join ', ') $TimeoutMinutes minutes after the $resetType. Check the BIOS job in the BMC's job queue." }
    }
    Write-BiosLog 'applied' $changes
    Write-Information -MessageData "$NodeName BIOS: $text applied." -InformationAction Continue
    return (& $row 'Changed' $changes)
}
finally {
    Remove-ZtpRedfishSession -Session $session
}
