<#
.SYNOPSIS
    Validates server discovery results.

.DESCRIPTION
    Reviews and validates the output from server discovery operations
    to ensure all servers are properly inventoried.

.EXAMPLE
    .\Validate-DiscoveryResults.ps1

    Validates discovery results from CSV and JSON files

.NOTES
    Requires:
    - PowerShell 7.0+
    - Discovery results files (CSV and JSON) in config/dell/discovery/
#>

#Requires -Version 7.0

# Find repository root and config file
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) {
    throw "Could not find repository root (config directory not found)"
}

Write-Host "Validating server discovery results..." -ForegroundColor Cyan

# Check for results files in config/dell/discovery/
$discoveryDir = Join-Path $repoRoot "config\dell\discovery"
$csvFile = Join-Path $discoveryDir "server-discovery-results.csv"
$jsonFile = Join-Path $discoveryDir "server-discovery-results.json"

$filesExist = $true
if (!(Test-Path $csvFile)) {
    Write-Warning "CSV results file not found: $csvFile"
    $filesExist = $false
}

if (!(Test-Path $jsonFile)) {
    Write-Warning "JSON results file not found: $jsonFile"
    $filesExist = $false
}

if (!$filesExist) {
    Write-Host "No discovery results files found in $discoveryDir. Run discovery first." -ForegroundColor Yellow
    exit 1
}

# Import and display results
Write-Host "Importing discovery results..." -ForegroundColor Gray
$results = Import-Csv $csvFile

Write-Host "`nDiscovery Results Summary:" -ForegroundColor Yellow
$results | Format-Table -AutoSize

# Analyze results
$discovered = $results | Where-Object { $_.Status -eq "Discovered" }
$failed = $results | Where-Object { $_.Status -eq "Failed" }

Write-Host "`nAnalysis:" -ForegroundColor Cyan
Write-Host "  Total servers: $($results.Count)" -ForegroundColor White
Write-Host "  Successfully discovered: $($discovered.Count)" -ForegroundColor Green
Write-Host "  Failed discoveries: $($failed.Count)" -ForegroundColor Red

if ($failed.Count -gt 0) {
    Write-Host "`nFailed servers:" -ForegroundColor Red
    $failed | ForEach-Object {
        Write-Host "  - $($_.IPAddress): $($_.Error)" -ForegroundColor Red
    }
}

if ($discovered.Count -gt 0) {
    Write-Host "`nDiscovered servers:" -ForegroundColor Green
    $discovered | ForEach-Object {
        $model = if ($_.Model) { " ($($_.Model))" } else { "" }
        Write-Host "  - $($_.IPAddress)$model" -ForegroundColor Green
    }

    # Check for hardware details
    $withHardware = $discovered | Where-Object { $_.ProcessorCount -or $_.TotalMemoryGB -or $_.DriveCount }
    if ($withHardware) {
        Write-Host "`nServers with hardware inventory:" -ForegroundColor Cyan
        $withHardware | ForEach-Object {
            Write-Host "  - $($_.IPAddress): $($_.ProcessorCount) CPUs, $($_.TotalMemoryGB) GB RAM, $($_.DriveCount) drives" -ForegroundColor Gray
        }
    }
}

Write-Host "`nValidation completed." -ForegroundColor Cyan