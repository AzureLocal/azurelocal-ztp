#Requires -Version 7.0
<#
.SYNOPSIS
Waits until every edge machine is Provisioned and ready to cluster; prints each lifecycle stage and ProvisionOs job step.
.DESCRIPTION
Polls Microsoft.AzureStackHCI/edgeMachines/<node> and edgeMachines/<node>/jobs/ProvisionOs (read-only GETs) for every
node. Each change of the lifecycle status, of a lifecycle stage or sub-stage (ProvisionMachine: RegisterMachine,
ArcEnableMaintenanceEnvironment, InstallExtensions; InstallOs: Initialize, DownloadOs, PrepareOs, RebootOs,
InstallExtensions, Finalize) and of a job step is printed once with its start and end time. Lifecycle seen on a live
run: Creating -> AwaitingConnection -> Provisioning -> ReadyForOs -> InstallingOs -> Provisioned.

A node is ready to cluster when its lifecycle is Provisioned, the ProvisionOs job reports DeploymentSuccess, the edge
machine is Connected with an arcMachineResourceId, and the mandatory Arc extensions AzureEdgeDeviceManagement,
AzureEdgeLifecycleManager, AzureEdgeRemoteSupport and AzureEdgeTelemetryAndDiagnostics are Succeeded.

A failed lifecycle, stage, job or step is terminal. With -RetryProvisionOs the job is resubmitted the way Microsoft's
troubleshooting article does it (re-PUT of jobs/ProvisionOs with the edge machine's osProfile and userDetails, target
HCI), at most -MaxRetryCount times per node and only with -Execute; without -Execute the retry is printed, not sent.
The script returns the status rows only when every node is ready; otherwise it throws (non-zero exit), also on timeout.
.PARAMETER SubscriptionId
Subscription of the edge machines.
.PARAMETER ResourceGroupName
Resource group of the edge machines.
.PARAMETER EdgeMachineName
Edge machine names (the node names).
.PARAMETER ApiVersion
edgeMachines api-version (2025-12-01-preview is the first that has edgeMachines and jobs).
.PARAMETER TimeoutMinutes
Overall polling budget (the live run took about 60 minutes per node from claim to Provisioned).
.PARAMETER PollIntervalSeconds
Seconds between polls.
.PARAMETER RetryProvisionOs
Resubmit jobs/ProvisionOs once a node fails (needs -Execute to send).
.PARAMETER MaxRetryCount
Resubmissions per node.
.PARAMETER AdminSecretResourceId
Key Vault secret ARM ID for the retry body when the edge machine does not return userDetails.secretLocation.
.PARAMETER Execute
Allow the ProvisionOs re-PUT. Polling itself is read-only.
.EXAMPLE
./Wait-ZtpMachineReady.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example -EdgeMachineName node-01, node-02
.EXAMPLE
./Wait-ZtpMachineReady.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example -EdgeMachineName node-01 -RetryProvisionOs -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroupName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$EdgeMachineName,
    [string]$ApiVersion = '2025-12-01-preview',
    [ValidateRange(0, 1440)][int]$TimeoutMinutes = 180,
    [ValidateRange(0, 3600)][int]$PollIntervalSeconds = 60,
    [switch]$RetryProvisionOs,
    [ValidateRange(1, 5)][int]$MaxRetryCount = 1,
    [ValidatePattern('^$|^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.KeyVault/vaults/[A-Za-z0-9-]+/secrets/[A-Za-z0-9-]+$')]
    [string]$AdminSecretResourceId = '',
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpAzure.Common.ps1')

$rgPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.AzureStackHCI/edgeMachines"
$deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
$seen = @{}
$retries = @{}
$retryGraceMinutes = 10
$started = [datetime]::UtcNow
Write-ZtpLog "Waiting for $($EdgeMachineName -join ', ') to be ready to cluster (timeout $TimeoutMinutes min, poll $PollIntervalSeconds s)."

while ($true) {
    $rows = [System.Collections.Generic.List[object]]::new()
    $failed = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $EdgeMachineName) {
        $machinePath = "$rgPath/$name"
        $machine = Invoke-ZtpArm -Method GET -Path $machinePath -ApiVersion $ApiVersion -AllowNotFound
        $job = if ($machine) { Invoke-ZtpArm -Method GET -Path "$machinePath/jobs/ProvisionOs" -ApiVersion $ApiVersion -AllowNotFound } else { $null }
        foreach ($item in @(Get-ZtpProgressItem -Name $name -Machine $machine -Job $job)) {
            if ($seen[$item.Key] -ne $item.Text) {
                # A step that has not started is printed only once it moves (keeps the first poll readable).
                $quiet = (-not $seen.ContainsKey($item.Key)) -and $item.PSObject.Properties['Status'] -and $item.Status -eq 'NotStarted'
                if (-not $quiet) { Write-ZtpLog "$name $($item.Text)" }
                $seen[$item.Key] = $item.Text
            }
        }
        $status = Get-ZtpEdgeMachineStatus -Name $name -Machine $machine -Job $job
        if (-not $status.Exists -and -not $seen.ContainsKey("$name|missing")) { Write-ZtpLog "$name edge machine not found (yet)."; $seen["$name|missing"] = 1 }
        if ($status.Failed) {
            $jobStart = [string](Get-ZtpPathValue $job 'properties.startTimeUtc' '')
            $state = $retries[$name]
            if ($state -and $state.JobStart -eq $jobStart -and ([datetime]::UtcNow - $state.At).TotalMinutes -lt $retryGraceMinutes) {
                $status.Failed = $false
                $status.FailureReason = "retry $($state.Count) submitted; waiting for the service to restart the job"
            }
            elseif ($RetryProvisionOs -and (-not $state -or $state.Count -lt $MaxRetryCount)) {
                $count = if ($state) { $state.Count + 1 } else { 1 }
                $body = Get-ZtpProvisionOsRetryBody -Machine $machine -AdminSecretResourceId $AdminSecretResourceId
                if ($Execute -and $PSCmdlet.ShouldProcess("$name jobs/ProvisionOs", "Resubmit OS provisioning (retry $count of $MaxRetryCount)")) {
                    Write-ZtpLog "$name failed ($($status.FailureReason)); resubmitting jobs/ProvisionOs (retry $count of $MaxRetryCount)." -Level Warning
                    $null = Invoke-ZtpArm -Method PUT -Path "$machinePath/jobs/ProvisionOs" -ApiVersion $ApiVersion -Body $body
                    $retries[$name] = @{ Count = $count; At = [datetime]::UtcNow; JobStart = $jobStart }
                    $status.Failed = $false
                    $status.FailureReason = "retry $count submitted"
                }
                else {
                    Write-ZtpLog "$name failed ($($status.FailureReason)). Plan: re-PUT jobs/ProvisionOs (osProfile $($body.properties.provisioningRequest.osProfile | ConvertTo-Json -Compress), target HCI); add -Execute to send it." -Level Warning
                }
            }
        }
        if ($status.Failed) { $failed.Add("$name ($($status.FailureReason))") }
        $rows.Add($status)
    }

    if ($failed.Count -gt 0) {
        $rows | Format-Table Node, Lifecycle, CurrentStage, JobStatus, Connectivity, ArcMachineName -AutoSize | Out-String | Write-Information -InformationAction Continue
        throw "Provisioning failed: $($failed -join '; '). Resubmit with -RetryProvisionOs -Execute (Learn: troubleshoot simplified machine provisioning) after fixing the cause."
    }
    if (@($rows | Where-Object { -not $_.Ready }).Count -eq 0) {
        Write-ZtpLog "All $($rows.Count) node(s) are ready to cluster after $([int]([datetime]::UtcNow - $started).TotalMinutes) min."
        return $rows.ToArray()
    }
    if ([datetime]::UtcNow -ge $deadline) {
        $pending = @($rows | Where-Object { -not $_.Ready } | ForEach-Object { "$($_.Node) (lifecycle $($_.Lifecycle), $($_.CurrentStage), job $($_.JobStatus), missing extensions $($_.MissingExtensions -join '/'))" })
        throw "Not ready to cluster within $TimeoutMinutes min: $($pending -join '; '). It may still be running: run this script again (it never resubmits without -RetryProvisionOs -Execute)."
    }
    Start-Sleep -Seconds $PollIntervalSeconds
}
