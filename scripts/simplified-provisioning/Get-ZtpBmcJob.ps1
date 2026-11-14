#Requires -Version 7.0
<#
.SYNOPSIS
Lists the job queue of each node's BMC (read-only), optionally waiting until no job is active.
.DESCRIPTION
For each node of the infrastructure file it reads the manager's job collection (<manager>/Jobs, the iDRAC job queue; else
the standard /redfish/v1/JobService/Jobs) and returns one row per job: Node, Bmc, JobId, Name, JobType, JobState,
PercentComplete, Message, StartTime, EndTime, Active. A job is active until its state is Completed,
CompletedWithErrors, Failed, RebootFailed, RebootCompleted, Cancelled or Exception. Use it to see the BIOS configuration
jobs the Boot and Restore stages (Set-ZtpBios.ps1, Restore-ZtpBios.ps1) or Reset-ZtpBootSequence.ps1 leave on a BMC.
Only GET requests (and the Redfish session) are sent; nothing changes.
Keys read: nodes[].name, nodes[].bmc.ip_address, hardware.bmc.username, .password, .verify_certificate.
Exit codes: 0 read; 1 a BMC could not be read, or -Wait ran out of time; 2 the file, a node or the login is missing or not
usable (nothing was sent to any BMC).
.PARAMETER InfrastructureFile
The master infrastructure.yml (schema 5). Required: there is no default path.
.PARAMETER NodeName
Nodes to read (nodes[].name). Default: every node in the file.
.PARAMETER Credential
The BMC login. Without it the login is the secret references in hardware.bmc, read by the toolkit's resolver. Never asked.
.PARAMETER JobState
Return only jobs in these states (for example Running, Scheduled).
.PARAMETER RecentMinutes
Return only jobs that started in the last N minutes (a job without a start time is kept).
.PARAMETER Wait
Read again every -PollSeconds until no node has an active job, for at most -TimeoutMinutes.
.PARAMETER PollSeconds
Seconds between reads with -Wait (default 30).
.PARAMETER TimeoutMinutes
Longest wait with -Wait (default 60). When it runs out the last rows are returned and the exit code is 1.
.EXAMPLE
./Get-ZtpBmcJob.ps1 -InfrastructureFile D:\ztp\infrastructure.yml -JobState Running, Scheduled
.EXAMPLE
./Get-ZtpBmcJob.ps1 -InfrastructureFile D:\ztp\infrastructure.yml -NodeName iic-node-01 -RecentMinutes 30 -Wait
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string[]]$NodeName,
    [pscredential]$Credential,
    [string[]]$JobState,
    [ValidateRange(0, 10080)][int]$RecentMinutes = 0,
    [switch]$Wait,
    [ValidateRange(5, 3600)][int]$PollSeconds = 30,
    [ValidateRange(1, 1440)][int]$TimeoutMinutes = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpBmcTool.Common.ps1')
if (-not (Get-Command New-ZtpRedfishSession -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ZtpRedfish.Common.ps1') }

$terminal = @('Completed', 'CompletedWithErrors', 'Failed', 'RebootFailed', 'RebootCompleted', 'Cancelled', 'Exception')

function Get-ZtpNodeJob {
    param([pscustomobject]$Node, [pscredential]$Login, [bool]$SkipCertificateCheck, [string[]]$StateFilter, [int]$Minutes)
    $session = Open-ZtpBmcToolSession -Node $Node -Credential $Login -SkipCertificateCheck:$SkipCertificateCheck
    try {
        $manager = Get-ZtpRedfishManager -Session $session
        $path = "$(Get-ZtpRedfishOdataId $manager)/Jobs"
        try { $collection = Invoke-ZtpRedfish -Session $session -Path $path }
        catch { $path = '/redfish/v1/JobService/Jobs'; $collection = Invoke-ZtpRedfish -Session $session -Path $path }
        $cutoff = if ($Minutes -gt 0) { [datetime]::UtcNow.AddMinutes(-$Minutes) } else { $null }
        foreach ($member in @($collection.Members)) {
            $job = Invoke-ZtpRedfish -Session $session -Path (Get-ZtpRedfishOdataId $member)
            $value = { param($name) if ($job.PSObject.Properties[$name]) { $job.$name } else { $null } }
            $state = [string](& $value 'JobState')
            $start = [string](& $value 'StartTime')
            if ($StateFilter -and $state -notin $StateFilter) { continue }
            if ($cutoff -and $start) {
                $parsed = [datetime]::MinValue
                if ([datetime]::TryParse($start, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed) -and $parsed -lt $cutoff) { continue }
            }
            [pscustomobject]@{
                Node            = $Node.Name
                Bmc             = $Node.BmcAddress
                JobId           = [string](& $value 'Id')
                Name            = [string](& $value 'Name')
                JobType         = [string](& $value 'JobType')
                JobState        = $state
                PercentComplete = & $value 'PercentComplete'
                Message         = [string](& $value 'Message')
                StartTime       = $start
                EndTime         = [string](& $value 'EndTime')
                Active          = [bool]($state -and $state -notin $terminal)
            }
        }
    }
    finally { Remove-ZtpRedfishSession -Session $session }
}

try {
    $target = Read-ZtpBmcToolInput -InfrastructureFile $InfrastructureFile -NodeName $NodeName
    $login = Resolve-ZtpBmcToolCredential -Credential $Credential -Infrastructure $target.Infrastructure -InfrastructureFile $target.Path
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit (Get-ZtpBmcToolExitCode $_)
}

$deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
while ($true) {
    $rows = [System.Collections.Generic.List[object]]::new()
    $failed = 0
    foreach ($node in $target.Nodes) {
        try { foreach ($row in @(Get-ZtpNodeJob -Node $node -Login $login -SkipCertificateCheck $target.SkipCertificateCheck -StateFilter $JobState -Minutes $RecentMinutes)) { $rows.Add($row) } }
        catch { $failed++; Write-Error "$($node.Name) ($($node.BmcAddress)): $($_.Exception.Message)" -ErrorAction Continue }
    }
    $active = @($rows | Where-Object Active)
    if (-not $Wait -or ($active.Count -eq 0 -and $failed -eq 0)) { break }
    if ([datetime]::UtcNow -ge $deadline) {
        Write-Warning "After $TimeoutMinutes minutes $($active.Count) job(s) are still active: $(@($active | ForEach-Object { "$($_.Node) $($_.JobId) $($_.JobState)" }) -join '; ')."
        $rows
        exit 1
    }
    Write-Information "$($active.Count) active job(s)$(if ($failed) { ", $failed BMC(s) not read" }); reading again in $PollSeconds seconds." -InformationAction Continue
    Start-Sleep -Seconds $PollSeconds
}
$rows
exit $(if ($failed) { 1 } else { 0 })
