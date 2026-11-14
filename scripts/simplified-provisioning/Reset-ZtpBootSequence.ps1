#Requires -Version 7.0
<#
.SYNOPSIS
Resets the UEFI boot entries of each Dell node to the ones its hardware gives (BIOS attribute SysPrepClean), through the
iDRAC's Redfish service.
.DESCRIPTION
For a node whose boot list is cluttered with entries of an earlier install ('Unavailable: ...', old Windows Boot Manager
entries) before a ZTP run. Per node:
1. Clears the iDRAC job queue (DellJobService.DeleteJobQueue, JID_CLEARALL): the iDRAC refuses a BIOS change while
   another configuration job is pending.
2. Sets the BIOS attribute SysPrepClean (or BootSettings.SysPrepClean) to Yes on the Bios Settings resource.
3. Creates the BIOS configuration job that applies it at the next restart (POST <manager>/Jobs with TargetSettingsURI).
4. Clears a one-time boot override that is still set (BootSourceOverrideEnabled Once becomes Disabled; a Continuous
   override is left as it is).
5. Restarts the node (GracefulRestart when on, On when off), unless -NoRestart. During POST the BIOS removes every UEFI
   boot variable and builds the entries again from the hardware; SysPrepClean goes back to None by itself.
Nothing else changes: not the boot mode, other BIOS settings, storage, network or iDRAC settings. The node's operating
system loses its boot entry, so -ConfirmNotClustered is required: run it only on nodes ZTP will reinstall.
Dell iDRAC only (hardware.vendor Dell): SysPrepClean and the job queue are Dell's. Check the result with
Get-ZtpBootSetting.ps1 and the job with Get-ZtpBmcJob.ps1 a few minutes after the restart.
With -WhatIf only the plan is printed: no credential is read and nothing is sent.
Keys read: nodes[].name, nodes[].bmc.ip_address, hardware.vendor, hardware.bmc.username, .password, .verify_certificate.
Exit codes: 0 done (or planned under -WhatIf); 1 a node could not be reset (its row says which step); 2 the file, a node,
the vendor, the confirmation or the login is missing or not usable (nothing was sent to any BMC).
.PARAMETER InfrastructureFile
The master infrastructure.yml (schema 5). Required: there is no default path.
.PARAMETER NodeName
Nodes to reset (nodes[].name). Default: every node in the file.
.PARAMETER Credential
The iDRAC login. Without it the login is the secret references in hardware.bmc, read by the toolkit's resolver. Never asked.
.PARAMETER NoRestart
Stage SysPrepClean and its job but don't restart: the BIOS applies it at the next restart.
.PARAMETER ConfirmNotClustered
Confirms the nodes carry no cluster or operating system to keep. Required unless -WhatIf.
.EXAMPLE
./Reset-ZtpBootSequence.ps1 -InfrastructureFile D:\ztp\infrastructure.yml -NodeName iic-node-01 -WhatIf
.EXAMPLE
./Reset-ZtpBootSequence.ps1 -InfrastructureFile D:\ztp\infrastructure.yml -NodeName iic-node-01 -ConfirmNotClustered
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string[]]$NodeName,
    [pscredential]$Credential,
    [switch]$NoRestart,
    [switch]$ConfirmNotClustered
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpBmcTool.Common.ps1')
if (-not (Get-Command New-ZtpRedfishSession -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ZtpRedfish.Common.ps1') }

function Reset-ZtpNodeBootSequence {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The script asks ShouldProcess for each node before it calls this.')]
    [CmdletBinding()]
    param([pscustomobject]$Node, [pscredential]$Login, [bool]$SkipCertificateCheck)
    $row = [ordered]@{ Node = $Node.Name; Bmc = $Node.BmcAddress; JobQueueCleared = $false; SysPrepCleanSet = $false; ConfigJobCreated = $false; OverrideCleared = $false; Restart = $null; Status = 'Failed'; Error = $null }
    $step = 'open the Redfish session'
    $session = Open-ZtpBmcToolSession -Node $Node -Credential $Login -SkipCertificateCheck:$SkipCertificateCheck
    try {
        $step = 'read the manager and the system'
        $manager = Get-ZtpRedfishManager -Session $session
        $system = Get-ZtpRedfishSystem -Session $session
        $systemPath = Get-ZtpRedfishOdataId $system
        $managerPath = Get-ZtpRedfishOdataId $manager

        $step = 'read the BIOS attributes'
        $bios = Invoke-ZtpRedfish -Session $session -Path "$systemPath/Bios"
        $attributes = if ($bios.PSObject.Properties['Attributes']) { $bios.Attributes } else { $null }
        $name = @('SysPrepClean', 'BootSettings.SysPrepClean' | Where-Object { $attributes -and $attributes.PSObject.Properties[$_] }) | Select-Object -First 1
        if (-not $name) { throw 'the BIOS has no SysPrepClean attribute (Dell PowerEdge BIOS only).' }

        $step = 'clear the iDRAC job queue'
        $null = Invoke-ZtpRedfish -Session $session -Path "/redfish/v1/Dell/Managers/$($manager.Id)/DellJobService/Actions/DellJobService.DeleteJobQueue" -Method Post -Body @{ JobID = 'JID_CLEARALL' }
        $row.JobQueueCleared = $true

        $step = "set $name=Yes"
        $settings = "$systemPath/Bios/Settings"
        $null = Invoke-ZtpRedfish -Session $session -Path $settings -Method Patch -Body @{ Attributes = @{ $name = 'Yes' } }
        $row.SysPrepCleanSet = $true

        $step = 'create the BIOS configuration job'
        $null = Invoke-ZtpRedfish -Session $session -Path "$managerPath/Jobs" -Method Post -Body @{ TargetSettingsURI = $settings }
        $row.ConfigJobCreated = $true

        $boot = if ($system.PSObject.Properties['Boot']) { $system.Boot } else { $null }
        $override = if ($boot -and $boot.PSObject.Properties['BootSourceOverrideEnabled']) { [string]$boot.BootSourceOverrideEnabled } else { '' }
        if ($override -eq 'Once') {
            # Only a one-time override is cleared; a Continuous override is an operator's setting and stays.
            $step = 'clear the one-time boot override'
            $null = Invoke-ZtpRedfish -Session $session -Path $systemPath -Method Patch -Body @{ Boot = @{ BootSourceOverrideEnabled = 'Disabled' } }
            $row.OverrideCleared = $true
        }

        if (-not $NoRestart) {
            $step = 'restart the node'
            $power = if ($system.PSObject.Properties['PowerState']) { [string]$system.PowerState } else { '' }
            $type = if ($power -eq 'On') { 'GracefulRestart' } else { 'On' }
            $null = Invoke-ZtpRedfish -Session $session -Path "$systemPath/Actions/ComputerSystem.Reset" -Method Post -Body @{ ResetType = $type }
            $row.Restart = $type
        }
        # The BIOS job runs during the restart; this script does not wait for it. 'Restarted' means the job is queued and
        # the restart was requested; Get-ZtpBmcJob.ps1 -Wait shows whether the job completed.
        $row.Status = if ($NoRestart) { 'Staged' } else { 'Restarted' }
    }
    catch {
        $row.Error = "Could not $($step): $($_.Exception.Message)"
    }
    finally { Remove-ZtpRedfishSession -Session $session }
    return [pscustomobject]$row
}

try {
    $target = Read-ZtpBmcToolInput -InfrastructureFile $InfrastructureFile -NodeName $NodeName
    if ($target.Vendor -ne 'Dell') { throw (New-ZtpBmcToolInputError "hardware.vendor is '$($target.Vendor)'. SysPrepClean and the iDRAC job queue are Dell's: this tool resets Dell iDRAC nodes only.") }
    if (-not $WhatIfPreference -and -not $ConfirmNotClustered) { throw (New-ZtpBmcToolInputError 'The nodes lose the boot entry of their operating system. Pass -ConfirmNotClustered to confirm they carry no cluster or operating system to keep, or -WhatIf to see the plan.') }
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit (Get-ZtpBmcToolExitCode $_)
}

$what = "clear the iDRAC job queue, set SysPrepClean=Yes with a BIOS configuration job, clear a one-time boot override$(if ($NoRestart) { '; no restart (applies at the next one)' } else { ', restart' })"
$login = $null
$failed = 0
foreach ($node in $target.Nodes) {
    if (-not $PSCmdlet.ShouldProcess("$($node.Name) (iDRAC $($node.BmcAddress))", $what)) {
        [pscustomobject]@{ Node = $node.Name; Bmc = $node.BmcAddress; JobQueueCleared = $false; SysPrepCleanSet = $false; ConfigJobCreated = $false; OverrideCleared = $false; Restart = $null; Status = 'Planned'; Error = $null }
        continue
    }
    if (-not $login) {
        try { $login = Resolve-ZtpBmcToolCredential -Credential $Credential -Infrastructure $target.Infrastructure -InfrastructureFile $target.Path }
        catch {
            Write-Error $_.Exception.Message -ErrorAction Continue
            exit (Get-ZtpBmcToolExitCode $_)
        }
    }
    try { $row = Reset-ZtpNodeBootSequence -Node $node -Login $login -SkipCertificateCheck $target.SkipCertificateCheck }
    catch { $row = [pscustomobject]@{ Node = $node.Name; Bmc = $node.BmcAddress; JobQueueCleared = $false; SysPrepCleanSet = $false; ConfigJobCreated = $false; OverrideCleared = $false; Restart = $null; Status = 'Failed'; Error = "Could not open the Redfish session: $($_.Exception.Message)" } }
    if ($row.Status -eq 'Failed') { $failed++; Write-Error "$($node.Name) ($($node.BmcAddress)): $($row.Error)" -ErrorAction Continue }
    $row
}
exit $(if ($failed) { 1 } else { 0 })
