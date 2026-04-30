<#
.SYNOPSIS
    Reset Dell BOSS virtual disks across all cluster nodes in parallel via Redfish API.

.DESCRIPTION
    Deletes existing virtual disks on Dell BOSS (Boot Optimized Storage Solution) controllers,
    then recreates a clean RAID-1 virtual disk on each node. All operations run in parallel
    across all nodes simultaneously — no waiting for one server to finish before starting the next.

    This resolves the common boot loop issue where servers repeatedly attempt to boot from a
    stale "WindowsServer" boot entry after a previous Azure Local or Windows Server installation.

    The script performs these phases on ALL servers at the same time:
      Phase 1: Connect, auto-detect BOSS controller, delete virtual disks, reboot
      Phase 2: Reconnect, verify deletion, recreate RAID-1, reboot
      Phase 3: Reconnect, verify new virtual disk is ready

    Credentials are retrieved from the platform Azure Key Vault by default. Use the -Credential
    parameter to provide credentials interactively instead.

.PARAMETER Credential
    PSCredential object for BMC/iDRAC authentication. If not provided, credentials are
    retrieved from the platform Key Vault (keyvault.platform_name / ztp.idrac_secret_name).

.PARAMETER BOSSControllerFQDD
    Override the BOSS controller FQDD if known (e.g., "AHCI.Slot.4-1"). If not specified,
    the script auto-detects the BOSS controller by searching for controllers with "BOSS" in
    the name or model.

.PARAMETER VolumeName
    Name for the new RAID-1 virtual disk. Default: "BOSS_RAID1"

.PARAMETER RebootWaitSeconds
    Seconds to wait after each reboot for servers to come back online. Default: 300 (5 minutes)

.PARAMETER JobTimeoutMinutes
    Maximum minutes to wait for a RAID configuration job to complete. Default: 15

.PARAMETER SkipRecreate
    Only delete existing virtual disks — do not recreate. Useful for debugging.

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    .\Reset-BOSSVirtualDisk.ps1

    Resets BOSS virtual disks on all servers using Key Vault credentials. Auto-detects BOSS controller.

.EXAMPLE
    .\Reset-BOSSVirtualDisk.ps1 -Force

    Same as above but skips the confirmation prompt.

.EXAMPLE
    $cred = Get-Credential -UserName root -Message "Enter iDRAC password"
    .\Reset-BOSSVirtualDisk.ps1 -Credential $cred -BOSSControllerFQDD "AHCI.Slot.4-1"

    Uses provided credentials and a known BOSS controller FQDD.

.EXAMPLE
    .\Reset-BOSSVirtualDisk.ps1 -SkipRecreate -Force

    Only deletes existing BOSS virtual disks without recreating. Useful for cleanup.

.NOTES
    Requires:
    - PowerShell 7.0+ (for ForEach-Object -Parallel and -SkipCertificateCheck)
    - Network access to all BMC/iDRAC management interfaces
    - Valid iDRAC credentials with administrator privileges
    - AzureLocalConfig.psm1 module for configuration loading
    - Az.KeyVault module (if using Key Vault for credentials)
    - environment.yaml configured with keyvault.platform_name and ztp.idrac_secret_name

    Dell BOSS Card Generations:
    - BOSS-N1: 16th gen (AX-760, R760) — typically AHCI.Slot.4-1
    - BOSS-S2: 15th gen (AX-750, R750) — typically AHCI.Slot.4-1 or AHCI.Slot.3-1
    - BOSS-S1: 14th gen (AX-740, R740) — varies by configuration

    WARNING: This script permanently destroys all data on the BOSS card M.2 drives.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$BOSSControllerFQDD,

    [Parameter(Mandatory = $false)]
    [string]$VolumeName = "BOSS_RAID1",

    [Parameter(Mandatory = $false)]
    [int]$RebootWaitSeconds = 300,

    [Parameter(Mandatory = $false)]
    [int]$JobTimeoutMinutes = 15,

    [Parameter(Mandatory = $false)]
    [switch]$SkipRecreate,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

#Requires -Version 7.0

# ============================================================================
# Script initialization
# ============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Write-Host "`nDell BOSS Virtual Disk Reset via Redfish API" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# Find repo root and load configuration
# ============================================================================
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) {
    throw "Could not find repository root (config directory not found)"
}

$modulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
Import-Module $modulePath -Force

$config = Get-AzureLocalConfig
$serverIPs = $config.GetIdracIPs()

Write-Host "Cluster nodes: $($serverIPs.Count)" -ForegroundColor White
$serverIPs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
Write-Host ""

# ============================================================================
# Credential resolution — Key Vault or interactive
# ============================================================================
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
Write-Host ""

# ============================================================================
# Confirmation
# ============================================================================
if (!$Force) {
    Write-Host "WARNING: This will PERMANENTLY DESTROY all data on the BOSS card M.2 drives" -ForegroundColor Red
    Write-Host "on ALL $($serverIPs.Count) servers simultaneously." -ForegroundColor Red
    Write-Host ""
    $confirmation = Read-Host "Type 'y' to continue"
    if ($confirmation -notin @('y', 'yes')) {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""
}

# ============================================================================
# Shared helper: Redfish request (used inside parallel blocks)
# ============================================================================
# We serialize the credential for use inside parallel scriptblocks
$credUser = $Credential.UserName
$credPass = $Credential.GetNetworkCredential().Password

# ============================================================================
# PHASE 1: Delete virtual disks on all servers (parallel)
# ============================================================================
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "PHASE 1: Delete existing BOSS virtual disks (all servers in parallel)" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host ""

$phase1Results = $serverIPs | ForEach-Object -Parallel {
    $ip = $_
    $user = $using:credUser
    $pass = $using:credPass
    $bossOverride = $using:BOSSControllerFQDD
    $jobTimeout = $using:JobTimeoutMinutes

    # Build credential inside runspace
    $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
    $cred = New-Object PSCredential ($user, $secPass)

    $result = [PSCustomObject]@{
        IPAddress            = $ip
        Phase                = "Delete"
        BOSSControllerFound  = $false
        BOSSControllerFQDD   = ""
        BOSSControllerName   = ""
        VirtualDisksFound    = 0
        VirtualDisksDeleted  = 0
        RebootInitiated      = $false
        JobCompleted         = $false
        Status               = "Unknown"
        Details              = ""
        PhysicalDiskFQDDs    = @()
        Timestamp            = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }

    # Helper function for Redfish GET
    function Invoke-RedfishGet {
        param([string]$Uri, [PSCredential]$Credential)
        Invoke-RestMethod -Uri $Uri -Credential $Credential -Method Get `
            -SkipCertificateCheck -TimeoutSec 30 -ErrorAction Stop
    }

    try {
        # --- Test connectivity ---
        $null = Invoke-RedfishGet -Uri "https://$ip/redfish/v1" -Credential $cred

        # --- Find BOSS controller ---
        $storageUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Storage"
        $storageResponse = Invoke-RedfishGet -Uri $storageUri -Credential $cred

        $bossController = $null
        $bossCtrlFQDD = $null

        foreach ($member in $storageResponse.Members) {
            $ctrlId = $member.'@odata.id'.Split('/')[-1]

            # If user provided a specific FQDD, use it directly
            if ($bossOverride -and $ctrlId -eq $bossOverride) {
                $ctrlUri = "https://$ip$($member.'@odata.id')"
                $bossController = Invoke-RedfishGet -Uri $ctrlUri -Credential $cred
                $bossCtrlFQDD = $ctrlId
                break
            }

            # Auto-detect: check for "BOSS" in name or model
            if (!$bossOverride) {
                $ctrlUri = "https://$ip$($member.'@odata.id')"
                $ctrlData = Invoke-RedfishGet -Uri $ctrlUri -Credential $cred

                $isBOSS = $false
                if ($ctrlData.Name -match "BOSS") { $isBOSS = $true }
                elseif ($ctrlData.StorageControllers) {
                    foreach ($sc in $ctrlData.StorageControllers) {
                        if ($sc.Model -match "BOSS" -or $sc.Name -match "BOSS") {
                            $isBOSS = $true; break
                        }
                    }
                }

                if ($isBOSS) {
                    $bossController = $ctrlData
                    $bossCtrlFQDD = $ctrlId
                    break
                }
            }
        }

        if (!$bossController) {
            if ($bossOverride) {
                # User specified FQDD — use it even if not auto-detected as BOSS
                $ctrlUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Storage/$bossOverride"
                $bossController = Invoke-RedfishGet -Uri $ctrlUri -Credential $cred
                $bossCtrlFQDD = $bossOverride
            }
            else {
                $result.Status = "No BOSS Controller"
                $result.Details = "No BOSS controller auto-detected. Use -BOSSControllerFQDD to specify."
                return $result
            }
        }

        $result.BOSSControllerFound = $true
        $result.BOSSControllerFQDD = $bossCtrlFQDD
        $result.BOSSControllerName = $bossController.Name

        # --- Collect physical disk FQDDs for Phase 2 recreation ---
        if ($bossController.Drives) {
            $result.PhysicalDiskFQDDs = @($bossController.Drives | ForEach-Object { $_.'@odata.id' })
        }

        # --- Query virtual disks ---
        $volumesUri = $null
        if ($bossController.Volumes -and $bossController.Volumes.'@odata.id') {
            $volumesUri = "https://$ip$($bossController.Volumes.'@odata.id')"
        }
        else {
            $volumesUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Storage/$bossCtrlFQDD/Volumes"
        }

        $volumesResponse = Invoke-RedfishGet -Uri $volumesUri -Credential $cred
        $virtualDisks = @()
        if ($volumesResponse.Members -and $volumesResponse.Members.Count -gt 0) {
            $virtualDisks = $volumesResponse.Members
        }
        $result.VirtualDisksFound = $virtualDisks.Count

        if ($virtualDisks.Count -eq 0) {
            $result.Status = "Already Clean"
            $result.Details = "No virtual disks found on BOSS controller — already clean"
            return $result
        }

        # --- Check for existing scheduled RAID jobs ---
        $jobsUri = "https://$ip/redfish/v1/Managers/iDRAC.Embedded.1/Jobs"
        $jobsResponse = Invoke-RedfishGet -Uri $jobsUri -Credential $cred
        $existingJob = $null

        foreach ($jobRef in $jobsResponse.Members) {
            try {
                $jobUri = "https://$ip$($jobRef.'@odata.id')"
                $job = Invoke-RedfishGet -Uri $jobUri -Credential $cred
                if ($job.JobType -eq "RAIDConfiguration" -and $job.JobState -eq "Scheduled") {
                    $existingJob = $job
                    break
                }
            }
            catch { continue }
        }

        # --- Delete virtual disks ---
        if (!$existingJob) {
            foreach ($vd in $virtualDisks) {
                $vdUri = "https://$ip$($vd.'@odata.id')"
                try {
                    Invoke-RestMethod -Uri $vdUri -Credential $cred -Method Delete `
                        -SkipCertificateCheck -TimeoutSec 30 -ErrorAction Stop | Out-Null
                    $result.VirtualDisksDeleted++
                }
                catch {
                    # Some iDRAC versions return 202 which Invoke-RestMethod may not handle cleanly
                    # Try with Invoke-WebRequest for proper status code handling
                    try {
                        $delResponse = Invoke-WebRequest -Uri $vdUri -Credential $cred -Method Delete `
                            -SkipCertificateCheck -TimeoutSec 30 -ErrorAction Stop
                        if ($delResponse.StatusCode -in @(200, 202, 204)) {
                            $result.VirtualDisksDeleted++
                        }
                    }
                    catch {
                        $result.Details += "Delete failed for $($vd.'@odata.id'): $($_.Exception.Message); "
                    }
                }
            }

            if ($result.VirtualDisksDeleted -eq 0) {
                $result.Status = "Failed"
                $result.Details = "No virtual disks were successfully deleted"
                return $result
            }

            # Wait briefly for iDRAC to create the job
            Start-Sleep -Seconds 3
        }

        # --- Reboot to apply the deletion ---
        $resetUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"
        $systemUri = "https://$ip/redfish/v1/Systems/System.Embedded.1"
        $systemInfo = Invoke-RedfishGet -Uri $systemUri -Credential $cred

        $resetType = if ($systemInfo.PowerState -eq "Off") { "On" } else { "ForceRestart" }
        $resetBody = @{ ResetType = $resetType } | ConvertTo-Json

        Invoke-RestMethod -Uri $resetUri -Credential $cred -Method Post -Body $resetBody `
            -ContentType "application/json" -SkipCertificateCheck -TimeoutSec 30 | Out-Null

        $result.RebootInitiated = $true

        # BOSS delete is a staged job — it applies during the reboot POST cycle.
        # iDRAC is unreachable during reboot so there's no point monitoring the job here.
        # Phase 2 will verify the delete actually worked before recreating.
        $result.JobCompleted = $true
        $result.Status = "Delete OK"
    }
    catch {
        $result.Status = "Failed"
        $result.Details = $_.Exception.Message
    }

    return $result
} -ThrottleLimit $serverIPs.Count

# Display Phase 1 results
Write-Host ""
foreach ($r in $phase1Results) {
    $color = switch ($r.Status) {
        "Delete OK"          { "Green" }
        "Already Clean"      { "Green" }
        "No BOSS Controller" { "Yellow" }
        "Delete Timeout"     { "Yellow" }
        default              { "Red" }
    }
    Write-Host "  [$($r.IPAddress)] $($r.Status) — $($r.BOSSControllerName) | VDs: $($r.VirtualDisksFound) found, $($r.VirtualDisksDeleted) deleted" -ForegroundColor $color
    if ($r.Details) { Write-Host "    Details: $($r.Details)" -ForegroundColor Gray }
}

# Check if any servers need Phase 2
$serversNeedingRecreate = $phase1Results | Where-Object {
    $_.Status -in @("Delete OK", "Already Clean") -and !$SkipRecreate
}

if ($serversNeedingRecreate.Count -eq 0 -or $SkipRecreate) {
    if ($SkipRecreate) {
        Write-Host "`n-SkipRecreate specified — skipping RAID-1 recreation." -ForegroundColor Yellow
    }
    else {
        Write-Host "`nNo servers require virtual disk recreation." -ForegroundColor Yellow
    }
}
else {
    # ==========================================================================
    # Wait for all servers to finish rebooting from Phase 1
    # ==========================================================================
    $needsRebootWait = $phase1Results | Where-Object { $_.RebootInitiated }
    if ($needsRebootWait.Count -gt 0) {
        Write-Host "`nWaiting $RebootWaitSeconds seconds for servers to finish rebooting..." -ForegroundColor Gray
        $waitEnd = (Get-Date).AddSeconds($RebootWaitSeconds)
        while ((Get-Date) -lt $waitEnd) {
            $remaining = [math]::Ceiling(($waitEnd - (Get-Date)).TotalSeconds)
            Write-Host "`r  Time remaining: $remaining seconds   " -NoNewline -ForegroundColor Gray
            Start-Sleep -Seconds 10
        }
        Write-Host "`r  Reboot wait complete.                    " -ForegroundColor Green
    }
    Write-Host ""

    # ======================================================================
    # PHASE 2: Recreate RAID-1 virtual disks (parallel)
    # ======================================================================
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host "PHASE 2: Recreate BOSS RAID-1 virtual disks (all servers in parallel)" -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host ""

    $phase2Inputs = $serversNeedingRecreate | ForEach-Object {
        [PSCustomObject]@{
            IPAddress         = $_.IPAddress
            BOSSControllerFQDD = $_.BOSSControllerFQDD
            PhysicalDiskFQDDs = $_.PhysicalDiskFQDDs
        }
    }

    $phase2Results = $phase2Inputs | ForEach-Object -Parallel {
        $ip = $_.IPAddress
        $bossFQDD = $_.BOSSControllerFQDD
        $physDisks = $_.PhysicalDiskFQDDs
        $user = $using:credUser
        $pass = $using:credPass
        $volName = $using:VolumeName
        $jobTimeout = $using:JobTimeoutMinutes

        $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
        $cred = New-Object PSCredential ($user, $secPass)

        $result = [PSCustomObject]@{
            IPAddress           = $ip
            Phase               = "Recreate"
            DeletionVerified    = $false
            VolumeCreated       = $false
            RebootInitiated     = $false
            JobCompleted        = $false
            Status              = "Unknown"
            Details             = ""
            Timestamp           = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }

        function Invoke-RedfishGet {
            param([string]$Uri, [PSCredential]$Credential)
            Invoke-RestMethod -Uri $Uri -Credential $Credential -Method Get `
                -SkipCertificateCheck -TimeoutSec 30 -ErrorAction Stop
        }

        try {
            # --- Wait for iDRAC to be reachable ---
            $retries = 0
            $maxRetries = 12  # 2 more minutes of retries
            while ($retries -lt $maxRetries) {
                try {
                    $null = Invoke-RedfishGet -Uri "https://$ip/redfish/v1" -Credential $cred
                    break
                }
                catch {
                    $retries++
                    if ($retries -ge $maxRetries) { throw "iDRAC not reachable after $maxRetries retries" }
                    Start-Sleep -Seconds 10
                }
            }

            # --- Verify deletion ---
            $volumesUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Storage/$bossFQDD/Volumes"
            $volumes = Invoke-RedfishGet -Uri $volumesUri -Credential $cred

            if ($volumes.Members -and $volumes.Members.Count -gt 0) {
                $result.Details = "Virtual disk still present after deletion — check iDRAC job queue"
                $result.Status = "Delete Not Verified"
                return $result
            }

            $result.DeletionVerified = $true

            # --- Get physical disk FQDDs (refresh from controller if needed) ---
            if (!$physDisks -or $physDisks.Count -lt 2) {
                $ctrlUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Storage/$bossFQDD"
                $ctrlData = Invoke-RedfishGet -Uri $ctrlUri -Credential $cred
                $physDisks = @($ctrlData.Drives | ForEach-Object { $_.'@odata.id' })
            }

            if ($physDisks.Count -lt 2) {
                $result.Status = "Failed"
                $result.Details = "Insufficient physical drives for RAID-1 (found $($physDisks.Count), need 2)"
                return $result
            }

            # --- Build drive references ---
            $driveRefs = @()
            for ($i = 0; $i -lt 2; $i++) {
                $driveRefs += @{ "@odata.id" = $physDisks[$i] }
            }

            # --- Create RAID-1 virtual disk ---
            $createBody = @{
                VolumeType = "Mirrored"
                Drives     = $driveRefs
                Name       = $volName
                Oem        = @{
                    Dell = @{
                        DellVirtualDisk = @{
                            BusProtocol = "SATA"
                        }
                    }
                }
            } | ConvertTo-Json -Depth 10

            try {
                Invoke-RestMethod -Uri $volumesUri -Credential $cred -Method Post `
                    -Body $createBody -ContentType "application/json" `
                    -SkipCertificateCheck -TimeoutSec 30 | Out-Null
                $result.VolumeCreated = $true
            }
            catch {
                # Try Invoke-WebRequest for 202 handling
                $createResponse = Invoke-WebRequest -Uri $volumesUri -Credential $cred -Method Post `
                    -Body $createBody -ContentType "application/json" `
                    -SkipCertificateCheck -TimeoutSec 30 -ErrorAction Stop
                if ($createResponse.StatusCode -in @(200, 201, 202)) {
                    $result.VolumeCreated = $true
                }
                else {
                    throw "Create returned HTTP $($createResponse.StatusCode)"
                }
            }

            if (!$result.VolumeCreated) {
                $result.Status = "Failed"
                $result.Details = "Virtual disk creation request was not accepted"
                return $result
            }

            # --- Find the scheduled RAID job ---
            Start-Sleep -Seconds 3
            $jobsUri = "https://$ip/redfish/v1/Managers/iDRAC.Embedded.1/Jobs"
            $jobsResponse = Invoke-RedfishGet -Uri $jobsUri -Credential $cred
            $scheduledJob = $null

            foreach ($jobRef in $jobsResponse.Members) {
                try {
                    $jobUri = "https://$ip$($jobRef.'@odata.id')"
                    $job = Invoke-RedfishGet -Uri $jobUri -Credential $cred
                    if ($job.JobType -eq "RAIDConfiguration" -and $job.JobState -eq "Scheduled") {
                        $scheduledJob = $job; break
                    }
                }
                catch { continue }
            }

            # --- Reboot to apply RAID creation ---
            $resetUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"
            $systemInfo = Invoke-RedfishGet -Uri "https://$ip/redfish/v1/Systems/System.Embedded.1" -Credential $cred

            $resetType = if ($systemInfo.PowerState -eq "Off") { "On" } else { "ForceRestart" }
            $resetBody = @{ ResetType = $resetType } | ConvertTo-Json

            Invoke-RestMethod -Uri $resetUri -Credential $cred -Method Post -Body $resetBody `
                -ContentType "application/json" -SkipCertificateCheck -TimeoutSec 30 | Out-Null

            $result.RebootInitiated = $true

            # --- Monitor RAID creation job ---
            if ($scheduledJob) {
                Start-Sleep -Seconds 30
                $elapsed = 0
                $maxWait = $jobTimeout * 60
                while ($elapsed -lt $maxWait) {
                    Start-Sleep -Seconds 15
                    $elapsed += 15
                    try {
                        $jobUri = "https://$ip/redfish/v1/Managers/iDRAC.Embedded.1/Jobs/$($scheduledJob.Id)"
                        $currentJob = Invoke-RedfishGet -Uri $jobUri -Credential $cred
                        if ($currentJob.JobState -eq "Completed") {
                            $result.JobCompleted = $true; break
                        }
                        elseif ($currentJob.JobState -in @("Failed", "CompletedWithErrors")) {
                            $result.Details = "Create job failed: $($currentJob.Message)"
                            break
                        }
                    }
                    catch {
                        # iDRAC unreachable during reboot — expected
                    }
                }
            }
            else {
                $result.JobCompleted = $true
            }

            $result.Status = if ($result.JobCompleted) { "Success" } else { "Create Timeout" }
            if ($result.JobCompleted) {
                $result.Details = "RAID-1 virtual disk created and applied successfully"
            }
        }
        catch {
            $result.Status = "Failed"
            $result.Details = $_.Exception.Message
        }

        return $result
    } -ThrottleLimit $phase2Inputs.Count

    # Display Phase 2 results
    Write-Host ""
    foreach ($r in $phase2Results) {
        $color = switch ($r.Status) {
            "Success"        { "Green" }
            "Create Timeout" { "Yellow" }
            default          { "Red" }
        }
        Write-Host "  [$($r.IPAddress)] $($r.Status) — Verified: $($r.DeletionVerified) | Created: $($r.VolumeCreated) | Rebooted: $($r.RebootInitiated) | Job Done: $($r.JobCompleted)" -ForegroundColor $color
        if ($r.Details) { Write-Host "    Details: $($r.Details)" -ForegroundColor Gray }
    }
}

# ============================================================================
# PHASE 3: Final verification (parallel)
# ============================================================================
if (!$SkipRecreate -and $serversNeedingRecreate.Count -gt 0) {
    # Wait for Phase 2 reboots to complete
    $phase2Rebooted = if ($phase2Results) { $phase2Results | Where-Object { $_.RebootInitiated } } else { @() }
    if ($phase2Rebooted.Count -gt 0) {
        Write-Host "`nWaiting $RebootWaitSeconds seconds for Phase 2 reboots to complete..." -ForegroundColor Gray
        $waitEnd = (Get-Date).AddSeconds($RebootWaitSeconds)
        while ((Get-Date) -lt $waitEnd) {
            $remaining = [math]::Ceiling(($waitEnd - (Get-Date)).TotalSeconds)
            Write-Host "`r  Time remaining: $remaining seconds   " -NoNewline -ForegroundColor Gray
            Start-Sleep -Seconds 10
        }
        Write-Host "`r  Reboot wait complete.                    " -ForegroundColor Green
    }
    Write-Host ""

    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host "PHASE 3: Final verification (all servers in parallel)" -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host ""

    $verifyInputs = $serversNeedingRecreate | ForEach-Object {
        [PSCustomObject]@{
            IPAddress          = $_.IPAddress
            BOSSControllerFQDD = $_.BOSSControllerFQDD
        }
    }

    $phase3Results = $verifyInputs | ForEach-Object -Parallel {
        $ip = $_.IPAddress
        $bossFQDD = $_.BOSSControllerFQDD
        $user = $using:credUser
        $pass = $using:credPass

        $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
        $cred = New-Object PSCredential ($user, $secPass)

        $result = [PSCustomObject]@{
            IPAddress  = $ip
            Phase      = "Verify"
            Volumes    = @()
            Status     = "Unknown"
            Details    = ""
            Timestamp  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }

        try {
            # Retry loop for iDRAC to come back up
            $retries = 0
            while ($retries -lt 12) {
                try {
                    $null = Invoke-RestMethod -Uri "https://$ip/redfish/v1" -Credential $cred `
                        -Method Get -SkipCertificateCheck -TimeoutSec 30 -ErrorAction Stop
                    break
                }
                catch { $retries++; Start-Sleep -Seconds 10 }
            }

            $volumesUri = "https://$ip/redfish/v1/Systems/System.Embedded.1/Storage/$bossFQDD/Volumes"
            $volumes = Invoke-RestMethod -Uri $volumesUri -Credential $cred -Method Get `
                -SkipCertificateCheck -TimeoutSec 30

            if ($volumes.Members -and $volumes.Members.Count -gt 0) {
                foreach ($vol in $volumes.Members) {
                    try {
                        $volUri = "https://$ip$($vol.'@odata.id')"
                        $volDetail = Invoke-RestMethod -Uri $volUri -Credential $cred -Method Get `
                            -SkipCertificateCheck -TimeoutSec 30
                        $result.Volumes += [PSCustomObject]@{
                            Id       = $volDetail.Id
                            Name     = $volDetail.Name
                            SizeGB   = [math]::Round($volDetail.CapacityBytes / 1GB, 2)
                            RAIDType = if ($volDetail.RAIDType) { $volDetail.RAIDType } else { $volDetail.VolumeType }
                            Status   = $volDetail.Status.Health
                        }
                    }
                    catch { continue }
                }
                $result.Status = "Verified"
                $result.Details = "BOSS RAID-1 ready — $($result.Volumes.Count) volume(s) present"
            }
            else {
                $result.Status = "Warning"
                $result.Details = "No volumes found after recreation — check iDRAC job queue"
            }
        }
        catch {
            $result.Status = "Unreachable"
            $result.Details = $_.Exception.Message
        }

        return $result
    } -ThrottleLimit $verifyInputs.Count

    Write-Host ""
    foreach ($r in $phase3Results) {
        $color = switch ($r.Status) {
            "Verified"    { "Green" }
            "Warning"     { "Yellow" }
            "Unreachable" { "Yellow" }
            default       { "Red" }
        }
        Write-Host "  [$($r.IPAddress)] $($r.Status)" -ForegroundColor $color
        foreach ($v in $r.Volumes) {
            Write-Host "    Volume: $($v.Name) | $($v.SizeGB) GB | $($v.RAIDType) | Health: $($v.Status)" -ForegroundColor Gray
        }
        if ($r.Details) { Write-Host "    $($r.Details)" -ForegroundColor Gray }
    }
}

# ============================================================================
# Summary
# ============================================================================
Write-Host ""
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "BOSS Virtual Disk Reset — Summary" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host ""

# Combine all results for the summary table
$allResults = @()

foreach ($r in $phase1Results) {
    $finalStatus = $r.Status
    if ($phase2Results) {
        $p2 = $phase2Results | Where-Object { $_.IPAddress -eq $r.IPAddress }
        if ($p2) { $finalStatus = $p2.Status }
    }
    if ($phase3Results) {
        $p3 = $phase3Results | Where-Object { $_.IPAddress -eq $r.IPAddress }
        if ($p3 -and $p3.Status -eq "Verified") { $finalStatus = "Success" }
    }

    $allResults += [PSCustomObject]@{
        IPAddress      = $r.IPAddress
        BOSSController = $r.BOSSControllerName
        FQDD           = $r.BOSSControllerFQDD
        VDsDeleted     = $r.VirtualDisksDeleted
        FinalStatus    = $finalStatus
    }
}

$allResults | Format-Table -AutoSize

$successCount = ($allResults | Where-Object { $_.FinalStatus -in @("Success", "Already Clean") }).Count
$failCount = ($allResults | Where-Object { $_.FinalStatus -in @("Failed") }).Count
$otherCount = $allResults.Count - $successCount - $failCount

Write-Host "Total: $($allResults.Count) | Success: $successCount | Failed: $failCount | Other: $otherCount" -ForegroundColor White

# Export results
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outputDir = Join-Path $repoRoot "logs"
if (!(Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
$outputPath = Join-Path $outputDir "boss-reset-results-$timestamp.json"

try {
    @{
        Phase1 = $phase1Results
        Phase2 = if ($phase2Results) { $phase2Results } else { @() }
        Phase3 = if ($phase3Results) { $phase3Results } else { @() }
        Summary = $allResults
    } | ConvertTo-Json -Depth 10 | Out-File $outputPath -Encoding UTF8
    Write-Host "`nResults exported to: $outputPath" -ForegroundColor Green
}
catch {
    Write-Host "Failed to export results: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Exit code
if ($failCount -gt 0) {
    Write-Host "`nCompleted with failures — manual intervention required for $failCount server(s)" -ForegroundColor Yellow
    exit 1
}
else {
    Write-Host "`nAll servers ready for ZTP provisioning" -ForegroundColor Green
    exit 0
}
