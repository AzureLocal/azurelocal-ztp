<#
.SYNOPSIS
    Resets UEFI boot sequence to Dell factory defaults via Redfish API.

.DESCRIPTION
    Restores the UEFI boot configuration to a clean factory state on Dell PowerEdge
    AX-series servers using the Dell OEM BIOS attribute SysPrepClean. This is a
    firmware-level purge that wipes all stale UEFI boot variables from NVRAM and
    forces BIOS to rebuild boot entries from hardware detection on the next POST.

    The script performs these operations on each server:

    1. CLEAR pending iDRAC configuration jobs — Dell iDRAC blocks new BIOS changes
       if pending config jobs exist (IDRAC.2.9.SYS011). Cleared automatically via
       DellJobService.DeleteJobQueue.

    2. SET SysPrepClean=Yes — PATCHes the Dell OEM BIOS attribute
       BootSettings.SysPrepClean to "Yes" via Bios/Settings. This tells the BIOS
       firmware to purge all stale UEFI boot variables from NVRAM during the next
       POST cycle. The attribute auto-resets to "None" after execution.

    3. CREATE configuration job — Creates a BIOS configuration job to apply the
       pending SysPrepClean change on next reboot.

    4. CLEAR one-time boot overrides — resets BootSourceOverrideEnabled to
       "Disabled" if stuck on "Once" or "Continuous".

    5. REBOOT servers — triggers a GracefulRestart (or powers on if the server is
       off) so that BIOS POST executes the SysPrepClean, purges stale entries,
       re-enumerates hardware, and recreates fresh default boot entries.
       Use -NoReboot to skip the reboot step.

    After reboot, BIOS POST will:
    - Execute SysPrepClean (purge all stale UEFI boot variables from NVRAM)
    - Re-enumerate hardware and create fresh default boot entries
    - SysPrepClean auto-resets to "None"

    Dell AX-760 factory default boot order (rebuilt by BIOS):
      1. PXE Device 1 — Embedded NIC 1 Port 1 Partition 1
      2. PXE Device 2 — Embedded NIC 1 Port 2 Partition 1
      3. BOSS Card Virtual Disk (RAID 1 M.2 SSD)
      4. Virtual Optical Drive (iDRAC virtual media)

    This script does NOT touch: BootMode, BIOS settings (CPU, memory, PCIe),
    RAID/storage config, network settings, or iDRAC settings.

.PARAMETER Credential
    PSCredential for iDRAC authentication. If not provided, retrieves from Key Vault.

.PARAMETER IdracIP
    One or more iDRAC IP addresses. Defaults to all servers from environment.yaml.

.PARAMETER Force
    Skip confirmation prompts.

.PARAMETER DryRun
    Show current boot state without making any changes.

.PARAMETER NoReboot
    Skip the automatic server reboot after applying SysPrepClean. The BIOS attribute
    will be staged as pending and applied on the next manual reboot.

.EXAMPLE
    .\Reset-BootSequence.ps1 -DryRun

    Show current boot options and SysPrepClean status without making changes.

.EXAMPLE
    .\Reset-BootSequence.ps1 -Force

    Reset all servers using Key Vault credentials, skip confirmation.

.EXAMPLE
    .\Reset-BootSequence.ps1 -IdracIP "192.168.214.11" -DryRun

    Preview current boot state for a single server.

.EXAMPLE
    $cred = Get-Credential -UserName root -Message "Enter iDRAC password"
    .\Reset-BootSequence.ps1 -Credential $cred -IdracIP "192.168.214.11","192.168.214.12"

    Reset specific servers using provided credentials.

.NOTES
    Requires:
    - PowerShell 7.0+ (for ForEach-Object -Parallel and -SkipCertificateCheck)
    - Network access to iDRAC management interfaces
    - Valid iDRAC credentials with administrator permissions
    - AzureLocalConfig.psm1 module for configuration loading
    - Az.KeyVault module (if using Key Vault for credentials)
    - Dell PowerEdge iDRAC with BIOS attribute BootSettings.SysPrepClean support

    What this script changes:
    - Sets BIOS attribute BootSettings.SysPrepClean = Yes (firmware purges stale
      UEFI boot variables on next POST, then auto-resets to None)
    - Creates BIOS configuration job to apply the pending change
    - Clears BootSourceOverrideEnabled (set to Disabled)
    - Reboots servers to trigger BIOS POST (unless -NoReboot)

    What this script does NOT change:
    - BootMode (remains Uefi — no change)
    - BIOS settings (CPU, memory, PCIe, etc.)
    - RAID / Storage configurations
    - Network settings
    - iDRAC settings

    After reboot, BIOS POST executes SysPrepClean, re-enumerates hardware, and
    creates fresh default boot entries from detected devices.

    Output file: config/dell/discovery/boot-reset-<timestamp>.json
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string[]]$IdracIP,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$NoReboot
)

#Requires -Version 7.0

$ErrorActionPreference = "Continue"

# ── Find repository root ──
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) {
    throw "Could not find repository root (config directory not found)"
}

# ── Load configuration ──
$modulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
Import-Module $modulePath -Force

$config = Get-AzureLocalConfig
if ($IdracIP) {
    $serverIPs = $IdracIP
} else {
    $serverIPs = $config.GetIdracIPs()
}

# Filter out empty/null entries and non-IP values
$serverIPs = @($serverIPs | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' })
if ($serverIPs.Count -eq 0) {
    throw "No valid iDRAC IP addresses found. Check environment.yaml or provide -IdracIP."
}

# ── Credential resolution ──
if (!$Credential) {
    $keyVaultName = $config.GetValue('keyvault.platform_name')
    $secretName = $config.GetValue('ztp.idrac_secret_name')

    if ($keyVaultName -and $secretName) {
        try {
            Write-Host "Retrieving iDRAC credentials from Key Vault '$keyVaultName'..." -ForegroundColor Cyan
            $secret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName
            if (!$secret) {
                throw "Secret '$secretName' not found in Key Vault '$keyVaultName'"
            }
            $credString = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
            if ($credString -notmatch ':') {
                throw "Secret value must be in format 'username:password'"
            }
            $username, $password = $credString -split ':', 2
            $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
            $Credential = New-Object PSCredential ($username, $securePassword)
            Write-Host "  Credentials retrieved successfully" -ForegroundColor Green
        }
        catch {
            Write-Host "  Key Vault access failed: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  Falling back to interactive credential entry..." -ForegroundColor Yellow
            $Credential = Get-Credential -Message "Enter iDRAC credentials (e.g., root)"
        }
    }
    else {
        Write-Host "Key Vault not configured. Please provide credentials interactively." -ForegroundColor Yellow
        $Credential = Get-Credential -Message "Enter iDRAC credentials (e.g., root)"
    }
}

# ── Confirm operation ──
$modeLabel = if ($DryRun) { "DRY RUN — no changes will be made" } else { "LIVE — SysPrepClean will purge stale boot entries and BIOS rebuilds from hardware" }
if (!$Force) {
    Write-Host "Mode: $modeLabel" -ForegroundColor $(if ($DryRun) { "Yellow" } else { "Red" })
    Write-Host "Will reset boot sequence on $($serverIPs.Count) server(s):" -ForegroundColor Cyan
    $serverIPs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "This will:" -ForegroundColor Cyan
    Write-Host "  1. CLEAR pending iDRAC configuration jobs" -ForegroundColor Yellow
    Write-Host "  2. SET SysPrepClean=Yes (BIOS purges all stale UEFI boot variables on next POST)" -ForegroundColor Yellow
    Write-Host "  3. CREATE BIOS configuration job to apply the change" -ForegroundColor Yellow
    Write-Host "  4. CLEAR any one-time boot overrides" -ForegroundColor Yellow
    Write-Host "  5. REBOOT servers (BIOS POST executes SysPrepClean and rebuilds boot entries)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "No other BIOS settings, RAID, network, or iDRAC settings are affected." -ForegroundColor Cyan
    $confirmation = Read-Host "Continue? (yes/N)"
    if ($confirmation -ne 'yes') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
} elseif ($DryRun) {
    Write-Host "Mode: DRY RUN — no changes will be made`n" -ForegroundColor Yellow
}

Write-Host "`nProcessing $($serverIPs.Count) server(s)...`n" -ForegroundColor Cyan

# ── Serialize credentials for parallel execution ──
$credUser = $Credential.UserName
$credPass = $Credential.GetNetworkCredential().Password
$dryRunFlag = $DryRun.IsPresent
$noRebootFlag = $NoReboot.IsPresent

# ── Process all servers in parallel ──
$results = $serverIPs | ForEach-Object -Parallel {
    $ip = $_
    $user = $using:credUser
    $pass = $using:credPass
    $isDryRun = $using:dryRunFlag
    $isNoReboot = $using:noRebootFlag

    $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
    $cred = New-Object PSCredential ($user, $secPass)

    $entry = [ordered]@{
        IPAddress            = $ip
        Timestamp            = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        Status               = "Unknown"
        DryRun               = $isDryRun
        PendingJobsCleared   = $false
        SysPrepCleanSet      = $false
        SysPrepCleanError    = $null
        SysPrepCleanPrevious = $null
        ConfigJobCreated     = $false
        ConfigJobId          = $null
        ConfigJobError       = $null
        OverrideCleared      = $false
        OverrideClearError   = $null
        OriginalOverride     = $null
        Rebooted             = $false
        RebootError          = $null
        CurrentBootOptions   = @()
        StaleCount           = 0
        ValidCount           = 0
        Error                = $null
    }

    try {
        # ── Test Redfish connectivity ──
        $svcUri = "https://$ip/redfish/v1"
        $null = Invoke-RestMethod -Uri $svcUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30

        # ── Get current system and boot state ──
        $sysUri = "https://$ip/redfish/v1/Systems/System.Embedded.1"
        $system = Invoke-RestMethod -Uri $sysUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30
        $entry.OriginalOverride = "$($system.Boot.BootSourceOverrideEnabled) / $($system.Boot.BootSourceOverrideTarget)"

        # ── Read current BIOS attributes to check SysPrepClean state ──
        $biosUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Bios"
        $biosData = Invoke-RestMethod -Uri $biosUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30
        $entry.SysPrepCleanPrevious = $biosData.Attributes.'SysPrepClean'
        if (!$entry.SysPrepCleanPrevious) {
            # Try alternate attribute name format
            $entry.SysPrepCleanPrevious = $biosData.Attributes.'BootSettings.SysPrepClean'
        }

        # ── Get current boot options for reporting ──
        $optionsUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/BootOptions"
        $optionsList = Invoke-RestMethod -Uri $optionsUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30

        foreach ($member in $optionsList.Members) {
            try {
                $optUri = "https://$ip$($member.'@odata.id')"
                $opt = Invoke-RestMethod -Uri $optUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 15
                $isStale = ($opt.DisplayName -match '^Unavailable:' -or
                            $opt.DisplayName -match 'Windows Boot Manager' -or
                            $opt.DisplayName -match '^WindowsServer$')
                $entry.CurrentBootOptions += [ordered]@{
                    Id          = $opt.Id
                    DisplayName = $opt.DisplayName
                    Enabled     = $opt.BootOptionEnabled
                    Reference   = $opt.BootOptionReference
                    Stale       = $isStale
                }
                if ($isStale) { $entry.StaleCount++ } else { $entry.ValidCount++ }
            } catch {
                # Skip inaccessible
            }
        }

        if (!$isDryRun) {
            # ── Step 1: Clear pending iDRAC configuration jobs ──
            try {
                $jobQueueUri = "https://$ip/redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellJobService/Actions/DellJobService.DeleteJobQueue"
                $clearBody = @{ JobID = "JID_CLEARALL" } | ConvertTo-Json
                Invoke-RestMethod -Uri $jobQueueUri -Method Post -Credential $cred `
                    -SkipCertificateCheck -ContentType "application/json" `
                    -Body $clearBody -TimeoutSec 30
                $entry.PendingJobsCleared = $true
                Start-Sleep -Seconds 3
            } catch {
                $entry.PendingJobsCleared = "skipped"
            }

            # ── Step 2: Set SysPrepClean=Yes (BIOS purges stale UEFI boot NVRAM on next POST) ──
            try {
                $biosSettingsUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Bios/Settings"
                $sysPrepBody = @{
                    Attributes = @{
                        "SysPrepClean" = "Yes"
                    }
                } | ConvertTo-Json -Depth 3

                $response = Invoke-RestMethod -Uri $biosSettingsUri -Method Patch -Credential $cred `
                    -SkipCertificateCheck -ContentType "application/json" `
                    -Body $sysPrepBody -TimeoutSec 30
                $entry.SysPrepCleanSet = $true
            } catch {
                # Try alternate attribute name format
                $errDetail = $_.ErrorDetails.Message
                try {
                    $sysPrepBody2 = @{
                        Attributes = @{
                            "BootSettings.SysPrepClean" = "Yes"
                        }
                    } | ConvertTo-Json -Depth 3

                    $response = Invoke-RestMethod -Uri $biosSettingsUri -Method Patch -Credential $cred `
                        -SkipCertificateCheck -ContentType "application/json" `
                        -Body $sysPrepBody2 -TimeoutSec 30
                    $entry.SysPrepCleanSet = $true
                } catch {
                    $errDetail2 = $_.ErrorDetails.Message
                    if (!$errDetail2) { $errDetail2 = $_.Exception.Message }
                    $entry.SysPrepCleanError = "SysPrepClean PATCH failed: $errDetail2 (also tried: $errDetail)"
                }
            }

            # ── Step 3: Create BIOS configuration job to apply the pending change ──
            if ($entry.SysPrepCleanSet) {
                try {
                    # Standard Redfish Jobs collection — works on iDRAC 9 firmware 7.x+
                    $jobsUri = "https://$ip/redfish/v1/Managers/iDRAC.Embedded.1/Jobs"
                    $jobBody = @{
                        TargetSettingsURI = "/redfish/v1/Systems/System.Embedded.1/Bios/Settings"
                    } | ConvertTo-Json

                    $jobResponse = Invoke-WebRequest -Uri $jobsUri -Method Post -Credential $cred `
                        -SkipCertificateCheck -ContentType "application/json" `
                        -Body $jobBody -TimeoutSec 30

                    $entry.ConfigJobCreated = $true
                    # Extract job ID from Location header
                    $locationHeader = $jobResponse.Headers['Location']
                    if ($locationHeader) {
                        $entry.ConfigJobId = ("$locationHeader" -split '/')[-1]
                    }
                    Start-Sleep -Seconds 3
                } catch {
                    $errDetail = $_.ErrorDetails.Message
                    if (!$errDetail) { $errDetail = $_.Exception.Message }
                    $entry.ConfigJobError = "Config job creation failed: $errDetail"
                }
            }

            # ── Step 4: Clear boot source override if not already Disabled ──
            try {
                if ($system.Boot.BootSourceOverrideEnabled -ne 'Disabled') {
                    $overrideBody = @{
                        Boot = @{
                            BootSourceOverrideEnabled = "Disabled"
                        }
                    } | ConvertTo-Json -Depth 3

                    Invoke-RestMethod -Uri $sysUri -Method Patch -Credential $cred `
                        -SkipCertificateCheck -ContentType "application/json" `
                        -Body $overrideBody -TimeoutSec 30

                    $entry.OverrideCleared = $true
                }
            } catch {
                $errDetail = $_.ErrorDetails.Message
                if (!$errDetail) { $errDetail = $_.Exception.Message }
                $entry.OverrideClearError = "Override clear failed: $errDetail"
            }

            # ── Step 5: Reboot the server ──
            if (!$isNoReboot) {
                try {
                    $sysCheck = Invoke-RestMethod -Uri $sysUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30
                    $resetUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"

                    if ($sysCheck.PowerState -eq 'On') {
                        $resetBody = @{ ResetType = "GracefulRestart" } | ConvertTo-Json
                    } else {
                        $resetBody = @{ ResetType = "On" } | ConvertTo-Json
                    }

                    Invoke-RestMethod -Uri $resetUri -Method Post -Credential $cred `
                        -SkipCertificateCheck -ContentType "application/json" `
                        -Body $resetBody -TimeoutSec 30

                    $entry.Rebooted = $true
                } catch {
                    $errDetail = $_.ErrorDetails.Message
                    if (!$errDetail) { $errDetail = $_.Exception.Message }
                    $entry.RebootError = "Reboot failed: $errDetail"
                }
            }

            # Determine overall status
            if ($entry.SysPrepCleanSet -and $entry.ConfigJobCreated) {
                $entry.Status = "Applied"
            } elseif ($entry.SysPrepCleanSet -and !$entry.ConfigJobCreated) {
                $entry.Status = "PartialFailure"
                $entry.Error = $entry.ConfigJobError
            } else {
                $entry.Status = "PartialFailure"
                $entry.Error = $entry.SysPrepCleanError
            }
        } else {
            $entry.Status = "DryRun"
        }
    }
    catch {
        $entry.Status = "Failed"
        $errDetail = $_.ErrorDetails.Message
        if (!$errDetail) { $errDetail = $_.Exception.Message }
        $entry.Error = $errDetail
    }

    return [PSCustomObject]$entry
} -ThrottleLimit $serverIPs.Count

# ── Display results ──
Write-Host ""
foreach ($srv in $results) {
    $statusColor = switch ($srv.Status) {
        "Applied"        { "Green" }
        "PartialFailure" { "DarkYellow" }
        "DryRun"         { "Yellow" }
        "Failed"         { "Red" }
        default          { "Gray" }
    }

    Write-Host "[$($srv.IPAddress)] Status: $($srv.Status)" -ForegroundColor $statusColor

    if ($srv.Status -ne "Failed") {
        # Show job queue status
        if ($srv.PendingJobsCleared -eq $true) {
            Write-Host "  Cleared pending iDRAC configuration jobs" -ForegroundColor DarkGray
        }

        # Show current boot options
        if ($srv.CurrentBootOptions.Count -gt 0) {
            Write-Host "  Current boot entries ($($srv.ValidCount) valid, $($srv.StaleCount) stale):" -ForegroundColor Cyan
            foreach ($opt in $srv.CurrentBootOptions) {
                $mark = if ($opt.Stale) { "✕" } else { "✓" }
                $enabledStr = if ($opt.Enabled) { "Enabled" } else { "Disabled" }
                $color = if ($opt.Stale) { "DarkGray" } else { "White" }
                Write-Host "    $mark $($opt.Id): $($opt.DisplayName) [$enabledStr]" -ForegroundColor $color
            }
        }

        # Show SysPrepClean status
        if ($srv.SysPrepCleanSet) {
            Write-Host "  SysPrepClean: Set to Yes (was: $($srv.SysPrepCleanPrevious)) — BIOS will purge stale entries on POST" -ForegroundColor Green
        } elseif ($srv.SysPrepCleanError) {
            Write-Host "  SysPrepClean: FAILED — $($srv.SysPrepCleanError)" -ForegroundColor Red
        } elseif ($srv.DryRun) {
            Write-Host "  SysPrepClean: Would set to Yes (current: $($srv.SysPrepCleanPrevious))" -ForegroundColor Yellow
        }

        # Show config job status
        if ($srv.ConfigJobCreated) {
            Write-Host "  Config Job: Created ($($srv.ConfigJobId)) — scheduled to apply on reboot" -ForegroundColor Green
        } elseif ($srv.ConfigJobError) {
            Write-Host "  Config Job: FAILED — $($srv.ConfigJobError)" -ForegroundColor Red
        }

        # Show override status
        if ($srv.OverrideCleared) {
            $verb = if ($srv.DryRun) { "Would clear" } else { "Cleared" }
            Write-Host "  Boot override: $verb (was: $($srv.OriginalOverride))" -ForegroundColor Yellow
        }
        if ($srv.OverrideClearError) {
            Write-Host "  Override clear: FAILED — $($srv.OverrideClearError)" -ForegroundColor Red
        }

        # Show reboot status
        if ($srv.Rebooted) {
            Write-Host "  Reboot: Initiated (GracefulRestart) — BIOS POST will execute SysPrepClean" -ForegroundColor Cyan
        } elseif ($srv.RebootError) {
            Write-Host "  Reboot: FAILED — $($srv.RebootError)" -ForegroundColor Red
        } elseif ($NoReboot -and !$srv.DryRun) {
            Write-Host "  Reboot: Skipped (-NoReboot) — SysPrepClean staged, will execute on next reboot" -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  Error: $($srv.Error)" -ForegroundColor Red
    }
    Write-Host ""
}

# ── Save results ──
$outputDir = Join-Path $repoRoot "config\dell\discovery"
if (!(Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile = Join-Path $outputDir "boot-reset-$timestamp.json"

$output = [ordered]@{
    GeneratedAt     = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    DryRun          = $DryRun.IsPresent
    ServerCount     = $results.Count
    Applied         = ($results | Where-Object { $_.Status -eq 'Applied' }).Count
    PartialFailure  = ($results | Where-Object { $_.Status -eq 'PartialFailure' }).Count
    Previewed       = ($results | Where-Object { $_.Status -eq 'DryRun' }).Count
    Failed          = ($results | Where-Object { $_.Status -eq 'Failed' }).Count
    SysPrepCleanSet = ($results | Where-Object { $_.SysPrepCleanSet -eq $true }).Count
    ConfigJobCreated = ($results | Where-Object { $_.ConfigJobCreated -eq $true }).Count
    Rebooted        = ($results | Where-Object { $_.Rebooted -eq $true }).Count
    RebootFailed    = ($results | Where-Object { $_.RebootError }).Count
    TotalStale      = ($results | Measure-Object -Property StaleCount -Sum).Sum
    TotalValid      = ($results | Measure-Object -Property ValidCount -Sum).Sum
    Servers         = $results
}

$output | ConvertTo-Json -Depth 6 | Set-Content -Path $outFile -Encoding UTF8

Write-Host "════════════════════════════════════════" -ForegroundColor Yellow
Write-Host "  Boot Sequence Reset Report" -ForegroundColor Yellow
Write-Host "  Mode: $(if ($DryRun) { 'DRY RUN' } else { 'LIVE' })" -ForegroundColor $(if ($DryRun) { "Yellow" } else { "Green" })
Write-Host "  Servers processed: $($results.Count)" -ForegroundColor Yellow
if (!$DryRun) {
    Write-Host "  Applied: $(($results | Where-Object { $_.Status -eq 'Applied' }).Count)" -ForegroundColor Green
    $partialCount = ($results | Where-Object { $_.Status -eq 'PartialFailure' }).Count
    if ($partialCount -gt 0) {
        Write-Host "  Partial: $partialCount (check per-server details above)" -ForegroundColor DarkYellow
    }
    Write-Host "  SysPrepClean staged: $(($results | Where-Object { $_.SysPrepCleanSet -eq $true }).Count)" -ForegroundColor Green
    Write-Host "  Config jobs created: $(($results | Where-Object { $_.ConfigJobCreated -eq $true }).Count)" -ForegroundColor Green
    Write-Host "  Stale entries found: $(($results | Measure-Object -Property StaleCount -Sum).Sum) (will be purged by BIOS POST)" -ForegroundColor Red
    $rebootCount = ($results | Where-Object { $_.Rebooted -eq $true }).Count
    $rebootFailCount = ($results | Where-Object { $_.RebootError }).Count
    if ($rebootCount -gt 0) {
        Write-Host "  Rebooted: $rebootCount" -ForegroundColor Cyan
    }
    if ($rebootFailCount -gt 0) {
        Write-Host "  Reboot failed: $rebootFailCount" -ForegroundColor Red
    }
} else {
    Write-Host "  Stale entries found: $(($results | Measure-Object -Property StaleCount -Sum).Sum)" -ForegroundColor Yellow
    Write-Host "  Valid entries found: $(($results | Measure-Object -Property ValidCount -Sum).Sum)" -ForegroundColor Yellow
}
Write-Host "  Failed:  $(($results | Where-Object { $_.Status -eq 'Failed' }).Count)" -ForegroundColor Red
Write-Host "  Results: $outFile" -ForegroundColor Yellow
Write-Host "════════════════════════════════════════" -ForegroundColor Yellow

if (!$DryRun -and ($results | Where-Object { $_.Status -in @('Applied','PartialFailure') })) {
    Write-Host ""
    $rebootedServers = ($results | Where-Object { $_.Rebooted -eq $true }).Count
    if ($rebootedServers -gt 0) {
        Write-Host "SERVERS ARE REBOOTING — SysPrepClean will execute during BIOS POST." -ForegroundColor Cyan
        Write-Host "  - BIOS will purge all stale UEFI boot variables from NVRAM" -ForegroundColor Cyan
        Write-Host "  - BIOS will re-enumerate hardware and create fresh default boot entries" -ForegroundColor Cyan
        Write-Host "  - SysPrepClean auto-resets to None after execution" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Wait ~5 minutes, then run Get-BootSettings.ps1 to verify the clean state." -ForegroundColor Yellow
    } elseif ($NoReboot) {
        Write-Host "NEXT STEP: Reboot the servers for SysPrepClean to execute (-NoReboot was specified)." -ForegroundColor DarkYellow
        Write-Host "  - SysPrepClean is staged as pending BIOS configuration" -ForegroundColor DarkYellow
        Write-Host "  - On next reboot, BIOS POST will purge stale entries and rebuild from hardware" -ForegroundColor DarkYellow
        Write-Host ""
        Write-Host "  Run Get-BootSettings.ps1 after reboot to verify the clean state." -ForegroundColor Yellow
    } else {
        Write-Host "WARNING: Reboot failed on all servers. Reboot them manually for SysPrepClean to execute." -ForegroundColor Red
        Write-Host "  Run Get-BootSettings.ps1 after reboot to verify the clean state." -ForegroundColor Yellow
    }
}
