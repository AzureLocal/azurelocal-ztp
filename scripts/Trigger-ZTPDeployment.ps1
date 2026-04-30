# Trigger-ZTPDeployment.ps1
# PowerShell script to manually trigger the Azure Local ZTP Deployment workflow

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$GitHubToken,

    [Parameter(Mandatory = $true)]
    [string]$RepositoryOwner,

    [Parameter(Mandatory = $true)]
    [string]$RepositoryName,

    [Parameter(Mandatory = $false)]
    [string]$WorkflowFile = "ztp-deployment.yml",

    [Parameter(Mandatory = $false)]
    [switch]$SkipDiscovery,

    [Parameter(Mandatory = $false)]
    [ValidateSet("auto", "environment.yaml", "environment.json")]
    [string]$TargetEnvironment = "auto",

    [Parameter(Mandatory = $false)]
    [string]$IdracUsername,

    [Parameter(Mandatory = $false)]
    [string]$IdracPassword,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [string]$Ref = "main",

    [Parameter(Mandatory = $false)]
    [switch]$WaitForCompletion,

    [Parameter(Mandatory = $false)]
    [int]$PollIntervalSeconds = 30,

    [Parameter(Mandatory = $false)]
    [string]$MaintenanceVersion,

# GitHub API configuration
$baseUrl = "https://api.github.com"
$headers = @{
    "Authorization" = "Bearer $GitHubToken"
    "Accept" = "application/vnd.github.v3+json"
    "User-Agent" = "PowerShell-ZTP-Trigger/1.0"
}

# Load configuration for defaults
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configModulePath = Join-Path $scriptDir "common\AzureLocalConfig.psm1"
if (Test-Path $configModulePath) {
    Import-Module $configModulePath
    $config = Get-AzureLocalConfig
    if (-not $MaintenanceVersion) {
        $MaintenanceVersion = $config.GetValue('ztp.maintenance_version')
    }
} else {
    if (-not $MaintenanceVersion) {
        $MaintenanceVersion = "2512"  # Fallback if config not found
    }
}

Write-Host "=== Azure Local ZTP Deployment Trigger ===" -ForegroundColor Cyan
Write-Host "Repository: $RepositoryOwner/$RepositoryName" -ForegroundColor Gray
Write-Host "Workflow: $WorkflowFile" -ForegroundColor Gray
Write-Host "Ref: $Ref" -ForegroundColor Gray
Write-Host ""

# Prepare workflow inputs
$inputs = @{
    skip_discovery = $SkipDiscovery.IsPresent.ToString().ToLower()
    target_environment = $TargetEnvironment
    dry_run = $DryRun.IsPresent.ToString().ToLower()
    maintenance_version = $MaintenanceVersion
}

if ($IdracUsername) {
    $inputs.idrac_username = $IdracUsername
}

if ($IdracPassword) {
    $inputs.idrac_password = $IdracPassword
}

Write-Host "Workflow Inputs:" -ForegroundColor Yellow
$inputs.GetEnumerator() | ForEach-Object {
    $displayValue = if ($_.Key -like "*password*") { "***" } else { $_.Value }
    Write-Host "  $($_.Key): $displayValue" -ForegroundColor Gray
}
Write-Host ""

# Trigger the workflow
$triggerUrl = "$baseUrl/repos/$RepositoryOwner/$RepositoryName/actions/workflows/$WorkflowFile/dispatches"

$body = @{
    ref = $Ref
    inputs = $inputs
} | ConvertTo-Json

Write-Host "Triggering workflow..." -ForegroundColor Green

try {
    $response = Invoke-RestMethod -Uri $triggerUrl -Method Post -Headers $headers -Body $body -ContentType "application/json"

    if ($response -eq $null) {
        Write-Host "✅ Workflow triggered successfully (no response body expected)" -ForegroundColor Green
    } else {
        Write-Host "✅ Workflow triggered successfully" -ForegroundColor Green
        Write-Host "Response: $($response | ConvertTo-Json -Depth 3)" -ForegroundColor Gray
    }

} catch {
    Write-Host "❌ Failed to trigger workflow: $($_.Exception.Message)" -ForegroundColor Red

    if ($_.Exception.Response) {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $statusDescription = $_.Exception.Response.StatusDescription

        Write-Host "HTTP Status: $statusCode $statusDescription" -ForegroundColor Red

        try {
            $errorContent = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($errorContent)
            $errorResponse = $reader.ReadToEnd()
            $errorJson = $errorResponse | ConvertFrom-Json
            Write-Host "Error Details: $($errorJson.message)" -ForegroundColor Red
        } catch {
            Write-Host "Could not read error response details" -ForegroundColor Red
        }
    }

    exit 1
}

# Wait for workflow completion if requested
if ($WaitForCompletion) {
    Write-Host "" -ForegroundColor Gray
    Write-Host "Waiting for workflow completion..." -ForegroundColor Yellow
    Write-Host "Polling interval: $PollIntervalSeconds seconds" -ForegroundColor Gray
    Write-Host "Maximum wait time: $MaxWaitMinutes minutes" -ForegroundColor Gray
    Write-Host ""

    $startTime = Get-Date
    $maxWaitTime = $startTime.AddMinutes($MaxWaitMinutes)
    $workflowRun = $null

    # Wait a bit for the workflow to start
    Start-Sleep -Seconds 10

    while ((Get-Date) -lt $maxWaitTime) {
        try {
            # Get recent workflow runs
            $runsUrl = "$baseUrl/repos/$RepositoryOwner/$RepositoryName/actions/workflows/$WorkflowFile/runs?per_page=5"
            $runsResponse = Invoke-RestMethod -Uri $runsUrl -Method Get -Headers $headers

            # Find the most recent run that started after we triggered it
            $recentRuns = $runsResponse.workflow_runs | Where-Object {
                $_.created_at -gt $startTime.AddMinutes(-5) -and
                $_.status -ne "queued"  # Skip queued runs that might be older
            } | Sort-Object created_at -Descending

            if ($recentRuns.Count -gt 0) {
                $workflowRun = $recentRuns[0]
                break
            }

        } catch {
            Write-Host "Warning: Could not check workflow status: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        Write-Host "Waiting for workflow to start... ($( [math]::Round(((Get-Date) - $startTime).TotalSeconds) )s elapsed)" -ForegroundColor Gray
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    if (-not $workflowRun) {
        Write-Host "❌ Could not find triggered workflow run" -ForegroundColor Red
        exit 1
    }

    Write-Host "Found workflow run: $($workflowRun.html_url)" -ForegroundColor Green
    Write-Host "Run ID: $($workflowRun.id)" -ForegroundColor Gray
    Write-Host "Status: $($workflowRun.status)" -ForegroundColor Gray
    Write-Host ""

    # Monitor the workflow run
    while ((Get-Date) -lt $maxWaitTime) {
        try {
            $runUrl = "$baseUrl/repos/$RepositoryOwner/$RepositoryName/actions/runs/$($workflowRun.id)"
            $runResponse = Invoke-RestMethod -Uri $runUrl -Method Get -Headers $headers

            $status = $runResponse.status
            $conclusion = $runResponse.conclusion

            $elapsed = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
            Write-Host "Status: $status | Conclusion: $conclusion | Elapsed: ${elapsed}min" -ForegroundColor Gray

            if ($status -eq "completed") {
                Write-Host "" -ForegroundColor Gray

                if ($conclusion -eq "success") {
                    Write-Host "✅ Workflow completed successfully!" -ForegroundColor Green
                } else {
                    Write-Host "❌ Workflow completed with status: $conclusion" -ForegroundColor Red
                }

                Write-Host "View details: $($runResponse.html_url)" -ForegroundColor Cyan
                break
            }

        } catch {
            Write-Host "Warning: Could not check run status: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }

    if ((Get-Date) -ge $maxWaitTime) {
        Write-Host "" -ForegroundColor Gray
        Write-Host "⏰ Maximum wait time exceeded. Workflow may still be running." -ForegroundColor Yellow
        Write-Host "Check status manually: $($workflowRun.html_url)" -ForegroundColor Cyan
    }
}

Write-Host "" -ForegroundColor Gray
Write-Host "=== Trigger Summary ===" -ForegroundColor Cyan
Write-Host "Repository: $RepositoryOwner/$RepositoryName" -ForegroundColor Gray
Write-Host "Workflow: $WorkflowFile" -ForegroundColor Gray
Write-Host "Inputs provided: $($inputs.Count)" -ForegroundColor Gray
Write-Host "Dry run: $($DryRun.IsPresent)" -ForegroundColor Gray
Write-Host "Skip discovery: $($SkipDiscovery.IsPresent)" -ForegroundColor Gray

if ($WaitForCompletion) {
    Write-Host "Waited for completion: Yes" -ForegroundColor Gray
} else {
    Write-Host "Waited for completion: No" -ForegroundColor Gray
    Write-Host "" -ForegroundColor Yellow
    Write-Host "💡 To monitor progress:" -ForegroundColor Yellow
    Write-Host "   1. Go to: https://github.com/$RepositoryOwner/$RepositoryName/actions" -ForegroundColor Gray
    Write-Host "   2. Find the 'Azure Local ZTP Deployment' workflow" -ForegroundColor Gray
    Write-Host "   3. Click on the running workflow to see live logs" -ForegroundColor Gray
}

Write-Host "" -ForegroundColor Green
Write-Host "🎯 ZTP Deployment trigger completed!" -ForegroundColor Green

<#
.SYNOPSIS
    Triggers the Azure Local ZTP Deployment workflow via GitHub API

.DESCRIPTION
    This script allows you to manually trigger the ZTP deployment pipeline
    from PowerShell, providing an alternative to the GitHub UI.

.PARAMETER GitHubToken
    GitHub Personal Access Token with workflow dispatch permissions

.PARAMETER RepositoryOwner
    GitHub repository owner (organization or username)

.PARAMETER RepositoryName
    GitHub repository name

.PARAMETER WorkflowFile
    Workflow filename (default: ztp-deployment.yml)

.PARAMETER SkipDiscovery
    Skip hardware discovery step

.PARAMETER TargetEnvironment
    Configuration file to use (auto, environment.yaml, or environment.json)

.PARAMETER IdracUsername
    iDRAC username (optional, will use Key Vault if not provided)

.PARAMETER IdracPassword
    iDRAC password (optional, will use Key Vault if not provided)

.PARAMETER DryRun
    Enable dry-run mode (no actual hardware changes)

.PARAMETER MaintenanceVersion
    Azure Local maintenance environment version (default: 2512)

.PARAMETER Ref
    Git branch or tag to run against (default: main)

.PARAMETER WaitForCompletion
    Wait for the workflow to complete and show final status

.PARAMETER PollIntervalSeconds
    How often to check workflow status when waiting (default: 30)

.PARAMETER MaxWaitMinutes
    Maximum time to wait for completion (default: 60)

.EXAMPLE
    # Basic trigger with minimal parameters
    .\Trigger-ZTPDeployment.ps1 -GitHubToken "ghp_xxx" -RepositoryOwner "myorg" -RepositoryName "ztp-repo"

.EXAMPLE
    # Full configuration with credentials and monitoring
    .\Trigger-ZTPDeployment.ps1 `
        -GitHubToken "ghp_xxx" `
        -RepositoryOwner "AzureLocal" `
        -RepositoryName "azurelocal-ztp" `
        -SkipDiscovery `
        -IdracUsername "idrac_azl_admin" `
        -IdracPassword "secretpass" `
        -WaitForCompletion

.EXAMPLE
    # Dry run to test configuration
    .\Trigger-ZTPDeployment.ps1 `
        -GitHubToken "ghp_xxx" `
        -RepositoryOwner "AzureLocal" `
        -RepositoryName "azurelocal-ztp" `
        -DryRun `
        -WaitForCompletion

.NOTES
    Requires a GitHub Personal Access Token with the following permissions:
    - repo (Full control of private repositories)
    - workflow (Update GitHub Action workflows)

    The token can be created at: https://github.com/settings/tokens
#>