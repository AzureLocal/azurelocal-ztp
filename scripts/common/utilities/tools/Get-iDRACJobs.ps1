<#
.SYNOPSIS
    Queries and monitors iDRAC jobs across all servers via Redfish API.

.DESCRIPTION
    Authenticates via Key Vault (or interactive credentials), queries each server's
    iDRAC Job Queue via the Dell Redfish API, and displays job status information.
    Results for all servers are saved to a single JSON file.

    This is a generic monitoring tool — it works with ANY iDRAC job, including:
    - BIOS configuration jobs (e.g. SysPrepClean from Reset-BootSequence.ps1)
    - Firmware update jobs
    - RAID configuration jobs
    - iDRAC configuration jobs
    - Reboot jobs (RID_*)
    - Scheduled jobs

    The Dell iDRAC Redfish Jobs API endpoint is:
      GET /redfish/v1/Managers/iDRAC.Embedded.1/Jobs
      GET /redfish/v1/Managers/iDRAC.Embedded.1/Jobs/{JobId}

    Job states returned by iDRAC:
      New, Scheduled, Running, Completed, CompletedWithErrors,
      Failed, Downloading, Downloaded, Waiting, Paused,
      RebootPending, RebootFailed, RebootCompleted

    Use -Wait to continuously poll servers until all active jobs complete.
    Use -JobState to filter results to specific job states only.
    Use -Recent to show only jobs created within the last N minutes.

    This script does NOT modify any settings — it is read-only.

.PARAMETER Credential
    PSCredential for iDRAC authentication. If not provided, retrieves from Key Vault.

.PARAMETER IdracIP
    One or more iDRAC IP addresses. Defaults to all servers from environment.yaml.

.PARAMETER Force
    Skip confirmation prompts.

.PARAMETER JobState
    Filter jobs by state. Accepts one or more states:
    New, Scheduled, Running, Completed, CompletedWithErrors, Failed,
    Downloading, Downloaded, Waiting, Paused, RebootPending,
    RebootFailed, RebootCompleted.
    If not specified, all jobs are returned.

.PARAMETER Wait
    Continuously poll servers until all active (non-terminal) jobs reach a
    terminal state (Completed, CompletedWithErrors, Failed, RebootFailed,
    RebootCompleted). The script polls at -PollInterval seconds.

.PARAMETER PollInterval
    Seconds between polls when using -Wait. Default: 30.

.PARAMETER Recent
    Show only jobs created within the last N minutes. Useful for filtering
    out old historical jobs after running Reset-BootSequence.ps1.

.EXAMPLE
    .\Get-iDRACJobs.ps1

    Queries all jobs on all servers from config using Key Vault credentials.

.EXAMPLE
    .\Get-iDRACJobs.ps1 -JobState Running,Scheduled

    Shows only running or scheduled jobs across all servers.

.EXAMPLE
    .\Get-iDRACJobs.ps1 -Wait -PollInterval 15

    Polls every 15 seconds until all active jobs on all servers complete.

.EXAMPLE
    .\Get-iDRACJobs.ps1 -IdracIP "192.168.214.11" -Recent 10

    Shows only jobs created in the last 10 minutes on a specific server.

.EXAMPLE
    $cred = Get-Credential -UserName root -Message "Enter iDRAC password"
    .\Get-iDRACJobs.ps1 -Credential $cred -Wait

    Uses provided credentials and waits for all jobs to complete.

.NOTES
    Requires:
    - PowerShell 7.0+ (for ForEach-Object -Parallel and -SkipCertificateCheck)
    - Network access to iDRAC management interfaces
    - Valid iDRAC credentials with read permissions
    - AzureLocalConfig.psm1 module for configuration loading
    - Az.KeyVault module (if using Key Vault for credentials)

    Output file: config/dell/discovery/idrac-jobs-<timestamp>.json
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
    [ValidateSet("New", "Scheduled", "Running", "Completed", "CompletedWithErrors",
                 "Failed", "Downloading", "Downloaded", "Waiting", "Paused",
                 "RebootPending", "RebootFailed", "RebootCompleted")]
    [string[]]$JobState,

    [Parameter(Mandatory = $false)]
    [switch]$Wait,

    [Parameter(Mandatory = $false)]
    [int]$PollInterval = 30,

    [Parameter(Mandatory = $false)]
    [int]$Recent
)

#Requires -Version 7.0

$ErrorActionPreference = "Continue"

# ── Terminal job states (jobs that are done and will not change) ──
$terminalStates = @("Completed", "CompletedWithErrors", "Failed", "RebootFailed", "RebootCompleted")

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
if (!$Force) {
    Write-Host "Will query iDRAC jobs on $($serverIPs.Count) server(s):" -ForegroundColor Cyan
    $serverIPs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    if ($Wait) {
        Write-Host "  Mode: WAIT (poll every ${PollInterval}s until all active jobs complete)" -ForegroundColor Magenta
    }
    if ($JobState) {
        Write-Host "  Filter: $($JobState -join ', ')" -ForegroundColor Magenta
    }
    if ($Recent) {
        Write-Host "  Recent: last $Recent minutes only" -ForegroundColor Magenta
    }
    $confirmation = Read-Host "Continue? (yes/N)"
    if ($confirmation -ne 'yes') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# ── Serialize credentials for parallel execution ──
$credUser = $Credential.UserName
$credPass = $Credential.GetNetworkCredential().Password

# ═══════════════════════════════════════════════════════════════
# Function: Query jobs from a single server (used in parallel)
# ═══════════════════════════════════════════════════════════════
function Get-ServerJobs {
    param(
        [string[]]$ServerIPs,
        [string]$User,
        [string]$Pass,
        [string[]]$FilterStates,
        [int]$RecentMinutes
    )

    $results = $ServerIPs | ForEach-Object -Parallel {
        $ip = $_
        $user = $using:User
        $pass = $using:Pass
        $filterStates = $using:FilterStates
        $recentMin = $using:RecentMinutes

        $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
        $cred = New-Object PSCredential ($user, $secPass)

        $entry = [ordered]@{
            IPAddress   = $ip
            Timestamp   = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
            Status      = "Unknown"
            TotalJobs   = 0
            ActiveJobs  = 0
            Jobs        = @()
            Error       = $null
        }

        try {
            # Test Redfish connectivity
            $svcUri = "https://$ip/redfish/v1"
            $null = Invoke-RestMethod -Uri $svcUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30

            # Get job collection
            $jobsUri = "https://$ip/redfish/v1/Managers/iDRAC.Embedded.1/Jobs"
            $jobList = Invoke-RestMethod -Uri $jobsUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 30

            $entry.TotalJobs = $jobList.'Members@odata.count'

            # Get details for each job
            foreach ($member in $jobList.Members) {
                try {
                    $jobUri = "https://$ip$($member.'@odata.id')"
                    $job = Invoke-RestMethod -Uri $jobUri -Method Get -Credential $cred -SkipCertificateCheck -TimeoutSec 15

                    $jobEntry = [ordered]@{
                        JobId           = $job.Id
                        Name            = $job.Name
                        JobType         = $job.JobType
                        JobState        = $job.JobState
                        Message         = $job.Message
                        MessageId       = $job.MessageId
                        PercentComplete = $job.PercentComplete
                        StartTime       = $job.StartTime
                        EndTime         = $job.EndTime
                        ActualRunningStartTime = $job.ActualRunningStartTime
                        ActualRunningEndTime   = $job.ActualRunningEndTime
                        TargetSettingsURI      = $job.TargetSettingsURI
                    }

                    # Apply -Recent filter (skip jobs older than N minutes)
                    if ($recentMin -gt 0 -and $job.StartTime) {
                        try {
                            $jobStart = [DateTime]::Parse($job.StartTime)
                            $cutoff = (Get-Date).AddMinutes(-$recentMin)
                            if ($jobStart -lt $cutoff) { continue }
                        } catch {
                            # If date parsing fails, include the job anyway
                        }
                    }

                    # Apply -JobState filter
                    if ($filterStates -and $filterStates.Count -gt 0) {
                        if ($job.JobState -notin $filterStates) { continue }
                    }

                    $entry.Jobs += $jobEntry
                } catch {
                    $entry.Jobs += [ordered]@{
                        JobId = $member.'@odata.id'
                        Error = $_.Exception.Message
                    }
                }
            }

            # Count active (non-terminal) jobs
            $termStates = @("Completed", "CompletedWithErrors", "Failed", "RebootFailed", "RebootCompleted")
            $entry.ActiveJobs = ($entry.Jobs | Where-Object {
                $_.JobState -and $_.JobState -notin $termStates
            }).Count

            $entry.Status = "Success"
        }
        catch {
            $entry.Status = "Failed"
            $entry.Error = $_.Exception.Message
        }

        return [PSCustomObject]$entry
    } -ThrottleLimit $ServerIPs.Count

    return $results
}

# ═══════════════════════════════════════════════════════════════
# Function: Display job results to console
# ═══════════════════════════════════════════════════════════════
function Show-JobResults {
    param($Results, [switch]$Compact)

    Write-Host ""
    foreach ($srv in $Results) {
        if ($srv.Status -eq "Success") {
            $activeColor = if ($srv.ActiveJobs -gt 0) { "Yellow" } else { "Green" }
            Write-Host "[$($srv.IPAddress)] Total Jobs: $($srv.TotalJobs) | Filtered: $($srv.Jobs.Count) | Active: $($srv.ActiveJobs)" -ForegroundColor $activeColor

            if ($srv.Jobs.Count -eq 0) {
                Write-Host "  (no jobs match current filter)" -ForegroundColor DarkGray
                continue
            }

            foreach ($job in $srv.Jobs) {
                if ($job.Error) {
                    Write-Host "  $($job.JobId): ERROR - $($job.Error)" -ForegroundColor Red
                    continue
                }

                # Color-code by state
                $stateColor = switch ($job.JobState) {
                    "Completed"              { "Green" }
                    "CompletedWithErrors"    { "Yellow" }
                    "Running"                { "Cyan" }
                    "Scheduled"              { "Magenta" }
                    "New"                    { "White" }
                    "Downloading"            { "Cyan" }
                    "Downloaded"             { "Cyan" }
                    "Waiting"                { "Yellow" }
                    "Paused"                 { "Yellow" }
                    "RebootPending"          { "Magenta" }
                    "RebootCompleted"        { "Green" }
                    "Failed"                 { "Red" }
                    "RebootFailed"           { "Red" }
                    default                  { "Gray" }
                }

                $pct = if ($job.PercentComplete -ne $null) { "$($job.PercentComplete)%" } else { "N/A" }

                if ($Compact) {
                    Write-Host "  $($job.JobId): [$($job.JobState)] $pct - $($job.Name)" -ForegroundColor $stateColor
                } else {
                    Write-Host "  ┌─ $($job.JobId) [$($job.JobState)] $pct" -ForegroundColor $stateColor
                    Write-Host "  │  Name:    $($job.Name)" -ForegroundColor White
                    Write-Host "  │  Type:    $($job.JobType)" -ForegroundColor White
                    Write-Host "  │  Message: $($job.Message)" -ForegroundColor White
                    if ($job.StartTime) {
                        Write-Host "  │  Start:   $($job.StartTime)" -ForegroundColor DarkGray
                    }
                    if ($job.EndTime -and $job.EndTime -ne "TIME_NA") {
                        Write-Host "  │  End:     $($job.EndTime)" -ForegroundColor DarkGray
                    }
                    if ($job.TargetSettingsURI) {
                        Write-Host "  │  Target:  $($job.TargetSettingsURI)" -ForegroundColor DarkGray
                    }
                    Write-Host "  └──────────────────────────────────────" -ForegroundColor DarkGray
                }
            }
        } else {
            Write-Host "[$($srv.IPAddress)] FAILED: $($srv.Error)" -ForegroundColor Red
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# Main execution
# ═══════════════════════════════════════════════════════════════

if ($Wait) {
    # ── Polling mode: loop until all active jobs reach terminal state ──
    Write-Host "`niDRAC Job Monitor — WAIT mode (poll every ${PollInterval}s)" -ForegroundColor Cyan
    Write-Host "Press Ctrl+C to stop monitoring`n" -ForegroundColor DarkGray

    $iteration = 0
    $allDone = $false

    while (-not $allDone) {
        $iteration++
        $timestamp = Get-Date -Format "HH:mm:ss"

        if ($iteration -gt 1) {
            Write-Host "`n── Poll #$iteration at $timestamp ──" -ForegroundColor DarkCyan
        } else {
            Write-Host "── Initial poll at $timestamp ──" -ForegroundColor DarkCyan
        }

        $results = Get-ServerJobs -ServerIPs $serverIPs -User $credUser -Pass $credPass `
                                  -FilterStates $JobState -RecentMinutes $Recent

        Show-JobResults -Results $results -Compact:($iteration -gt 1)

        # Check if any server still has active (non-terminal) jobs
        $totalActive = ($results | Where-Object { $_.Status -eq "Success" } |
                        ForEach-Object { $_.ActiveJobs } |
                        Measure-Object -Sum).Sum

        if ($totalActive -eq 0) {
            $allDone = $true
            Write-Host "`n════════════════════════════════════════" -ForegroundColor Green
            Write-Host "  All jobs have reached terminal state" -ForegroundColor Green
            Write-Host "════════════════════════════════════════" -ForegroundColor Green
        } else {
            Write-Host "`n  $totalActive active job(s) remaining — next poll in ${PollInterval}s..." -ForegroundColor Yellow
            Start-Sleep -Seconds $PollInterval
        }
    }
} else {
    # ── Single query mode ──
    Write-Host "`nQuerying iDRAC jobs on $($serverIPs.Count) server(s)...`n" -ForegroundColor Cyan

    $results = Get-ServerJobs -ServerIPs $serverIPs -User $credUser -Pass $credPass `
                              -FilterStates $JobState -RecentMinutes $Recent

    Show-JobResults -Results $results
}

# ── Save results ──
$outputDir = Join-Path $repoRoot "config\dell\discovery"
if (!(Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile = Join-Path $outputDir "idrac-jobs-$timestamp.json"

$totalActive = ($results | Where-Object { $_.Status -eq "Success" } |
                ForEach-Object { $_.ActiveJobs } |
                Measure-Object -Sum).Sum
$totalJobs = ($results | Where-Object { $_.Status -eq "Success" } |
              ForEach-Object { $_.Jobs.Count } |
              Measure-Object -Sum).Sum

$output = [ordered]@{
    GeneratedAt  = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    ServerCount  = $results.Count
    Succeeded    = ($results | Where-Object { $_.Status -eq 'Success' }).Count
    Failed       = ($results | Where-Object { $_.Status -eq 'Failed' }).Count
    TotalJobs    = $totalJobs
    ActiveJobs   = $totalActive
    FilterApplied = [ordered]@{
        JobState = if ($JobState) { $JobState } else { "All" }
        Recent   = if ($Recent) { "$Recent minutes" } else { "All" }
    }
    Servers      = $results
}

$output | ConvertTo-Json -Depth 6 | Set-Content -Path $outFile -Encoding UTF8

Write-Host "`n════════════════════════════════════════" -ForegroundColor Yellow
Write-Host "  iDRAC Jobs Report" -ForegroundColor Yellow
Write-Host "  Servers queried: $($results.Count)" -ForegroundColor Yellow
Write-Host "  Success: $(($results | Where-Object { $_.Status -eq 'Success' }).Count)" -ForegroundColor Green
Write-Host "  Failed:  $(($results | Where-Object { $_.Status -eq 'Failed' }).Count)" -ForegroundColor Red
Write-Host "  Total jobs (filtered): $totalJobs" -ForegroundColor Yellow
Write-Host "  Active jobs: $totalActive" -ForegroundColor $(if ($totalActive -gt 0) { "Yellow" } else { "Green" })
Write-Host "  Results: $outFile" -ForegroundColor Yellow
Write-Host "════════════════════════════════════════" -ForegroundColor Yellow
