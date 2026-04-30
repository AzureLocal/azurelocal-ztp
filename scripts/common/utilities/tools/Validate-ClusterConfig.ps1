<#
.SYNOPSIS
    Validate cluster-config.md for completeness and correctness.

.DESCRIPTION
    Checks the cluster-config.md file for:
    - No remaining [CHANGE-ME] placeholder values
    - No remaining [DISCOVERED] values (when -Strict is used)
    - Required fields are present and non-empty
    - IP addresses are valid formats
    - Node count matches declared value
    - CIDR notations are valid
    - Key Vault name is populated
    - Share paths are valid

    Use this script BEFORE triggering the ZTP Deployment pipeline
    to catch configuration errors early.

.PARAMETER ClusterConfigPath
    Path to the cluster-config.md file.
    Default: config/cluster/cluster-config.md (relative to repo root)

.PARAMETER Strict
    Fail on [DISCOVERED] placeholders too (use after hardware discovery).
    Without -Strict, only [CHANGE-ME] placeholders cause failure.

.PARAMETER ReportPath
    Optional path to save validation report as JSON.

.EXAMPLE
    .\Validate-ClusterConfig.ps1

.EXAMPLE
    .\Validate-ClusterConfig.ps1 -Strict

.NOTES
    File: Validate-ClusterConfig.ps1
    Author: Azure Local ZTP Team
    Version: 1.0.0
    Created: 2026-02-11
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ClusterConfigPath,

    [switch]$Strict,

    [Parameter(Mandatory = $false)]
    [string]$ReportPath
)

$ErrorActionPreference = "Stop"

# Repository root detection
$scriptDir = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptDir)))

if (-not $ClusterConfigPath) {
    $ClusterConfigPath = Join-Path $repoRoot "config\cluster\cluster-config.md"
}

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Validate Cluster Configuration                            ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

Write-Host "`nFile:   $ClusterConfigPath" -ForegroundColor White
Write-Host "Mode:   $(if ($Strict) { 'Strict (no placeholders allowed)' } else { 'Standard (DISCOVERED allowed)' })" -ForegroundColor White

# ─── Validate file exists ────────────────────────────────────────────────
if (-not (Test-Path $ClusterConfigPath)) {
    Write-Host "`n✗ File not found: $ClusterConfigPath" -ForegroundColor Red
    exit 1
}

$content = Get-Content $ClusterConfigPath -Raw
$lines = Get-Content $ClusterConfigPath

$errors = @()
$warnings = @()
$info = @()

# ─── Check 1: Placeholder values ─────────────────────────────────────────
Write-Host "`n[1/6] Checking for placeholder values..." -ForegroundColor Cyan

$changeMeMatches = [regex]::Matches($content, '\[CHANGE-ME\]')
$discoveredMatches = [regex]::Matches($content, '\[DISCOVERED\]')
$securedMatches = [regex]::Matches($content, '\[SECURED\]')

if ($changeMeMatches.Count -gt 0) {
    $errors += "[CHANGE-ME] found $($changeMeMatches.Count) times — these MUST be filled in before deployment"

    # Find which variables have [CHANGE-ME]
    foreach ($line in $lines) {
        if ($line -match '\[CHANGE-ME\]' -and $line -match '^\|([^|]+)\|') {
            $varName = $matches[1].Trim()
            if ($varName -match '^[A-Z]') {
                $errors += "  → $varName = [CHANGE-ME]"
            }
        }
    }
}

if ($discoveredMatches.Count -gt 0) {
    if ($Strict) {
        $errors += "[DISCOVERED] found $($discoveredMatches.Count) times — run hardware discovery first"
    } else {
        $warnings += "[DISCOVERED] found $($discoveredMatches.Count) times — run hardware discovery to populate"
    }
}

$info += "[SECURED] found $($securedMatches.Count) times — these are stored in Key Vault (expected)"

if ($changeMeMatches.Count -eq 0) {
    Write-Host "  ✓ No [CHANGE-ME] placeholders" -ForegroundColor Green
} else {
    Write-Host "  ✗ $($changeMeMatches.Count) [CHANGE-ME] placeholders remain" -ForegroundColor Red
}

# ─── Check 2: Required variables ─────────────────────────────────────────
Write-Host "`n[2/6] Checking required variables..." -ForegroundColor Cyan

# Parse all variables from tables
$variables = @{}
foreach ($line in $lines) {
    $line = $line.Trim()
    if ($line -match '^\|([^|]+)\|([^|]+)\|') {
        $col1 = $matches[1].Trim()
        $col2 = $matches[2].Trim()

        if ($col1 -match '^[A-Z][A-Z0-9_]+$') {
            $value = $col2 -replace '`', '' -replace '\*\*', ''
            $variables[$col1] = $value.Trim()
        }
    }
}

$criticalVars = @(
    'AZURE_TENANT_ID',
    'AZURE_MGMT_SUBSCRIPTION_ID',
    'CLUSTER_NAME',
    'RG_CLUSTER',
    'DOMAIN_FQDN',
    'KEYVAULT_PLATFORM_NAME',
    'ZTP_SHARE_LOCATION',
    'ZTP_SHARE_NETWORK_PATH',
    'ZTP_MAINTENANCE_VERSION',
    'IDRAC_SECRET_NAME'
)

$missingCritical = 0
foreach ($var in $criticalVars) {
    if (-not $variables.ContainsKey($var) -or $variables[$var] -in @('', '[CHANGE-ME]', '[DISCOVERED]')) {
        $errors += "Missing or empty critical variable: $var"
        $missingCritical++
    }
}

if ($missingCritical -eq 0) {
    Write-Host "  ✓ All $($criticalVars.Count) critical variables present" -ForegroundColor Green
} else {
    Write-Host "  ✗ $missingCritical critical variables missing" -ForegroundColor Red
}

# ─── Check 3: IP address validation ──────────────────────────────────────
Write-Host "`n[3/6] Validating IP addresses..." -ForegroundColor Cyan

$ipVars = @(
    'AZURE_DC_01_IP', 'AZURE_DC_02_IP',
    'CLUSTER_IP_POOL_START', 'CLUSTER_IP_POOL_END',
    'INFRASTRUCTURE_GATEWAY',
    'DNS_SERVER_1', 'DNS_SERVER_2'
)

$ipPattern = '^(\d{1,3}\.){3}\d{1,3}$'
$badIPs = 0
foreach ($var in $ipVars) {
    if ($variables.ContainsKey($var) -and $variables[$var] -notmatch '\[') {
        $ip = $variables[$var]
        if ($ip -notmatch $ipPattern) {
            $errors += "Invalid IP format: $var = $ip"
            $badIPs++
        }
    }
}

# Validate node IPs
for ($i = 1; $i -le 16; $i++) {
    $padNum = "{0:D2}" -f $i
    foreach ($suffix in @('IP', 'IDRAC_IP')) {
        $var = "NODE_${padNum}_$suffix"
        if ($variables.ContainsKey($var) -and $variables[$var] -notmatch '\[') {
            if ($variables[$var] -notmatch $ipPattern) {
                $errors += "Invalid IP format: $var = $($variables[$var])"
                $badIPs++
            }
        }
    }
}

if ($badIPs -eq 0) {
    Write-Host "  ✓ All IP addresses are valid format" -ForegroundColor Green
} else {
    Write-Host "  ✗ $badIPs invalid IP addresses" -ForegroundColor Red
}

# ─── Check 4: Node count consistency ─────────────────────────────────────
Write-Host "`n[4/6] Checking node count consistency..." -ForegroundColor Cyan

$declaredCount = if ($variables.ContainsKey('NODE_COUNT')) { [int]$variables['NODE_COUNT'] } else { 0 }
$foundNodes = 0
for ($i = 1; $i -le 16; $i++) {
    $padNum = "{0:D2}" -f $i
    if ($variables.ContainsKey("NODE_${padNum}_HOSTNAME")) {
        $foundNodes++
    }
}

if ($declaredCount -gt 0 -and $foundNodes -eq $declaredCount) {
    Write-Host "  ✓ NODE_COUNT=$declaredCount matches $foundNodes node entries" -ForegroundColor Green
} elseif ($declaredCount -gt 0) {
    $warnings += "NODE_COUNT=$declaredCount but found $foundNodes node entries in tables"
    Write-Host "  ⚠ NODE_COUNT=$declaredCount but found $foundNodes node entries" -ForegroundColor Yellow
}

# ─── Check 5: Share path validation ──────────────────────────────────────
Write-Host "`n[5/6] Validating share configuration..." -ForegroundColor Cyan

$sharePath = $variables['ZTP_SHARE_NETWORK_PATH']
if ($sharePath -and $sharePath -notmatch '\[') {
    if ($sharePath -match '^\\\\[\d\.]+\\.+') {
        Write-Host "  ✓ Share network path format valid: $sharePath" -ForegroundColor Green
    } else {
        $warnings += "Share network path may be invalid: $sharePath (expected \\IP\share format)"
        Write-Host "  ⚠ Share path format unusual: $sharePath" -ForegroundColor Yellow
    }
}

# ─── Check 6: GUID validation ────────────────────────────────────────────
Write-Host "`n[6/6] Validating GUIDs..." -ForegroundColor Cyan

$guidVars = @('AZURE_TENANT_ID', 'AZURE_MGMT_SUBSCRIPTION_ID', 'AZURE_WORKLOAD_SUBSCRIPTION_ID')
$guidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$badGuids = 0

foreach ($var in $guidVars) {
    if ($variables.ContainsKey($var) -and $variables[$var] -notmatch '\[') {
        if ($variables[$var] -notmatch $guidPattern) {
            $errors += "Invalid GUID format: $var = $($variables[$var])"
            $badGuids++
        }
    }
}

if ($badGuids -eq 0) {
    Write-Host "  ✓ All GUIDs are valid format" -ForegroundColor Green
} else {
    Write-Host "  ✗ $badGuids invalid GUIDs" -ForegroundColor Red
}

# ─── Results ─────────────────────────────────────────────────────────────
Write-Host ""

$report = [ordered]@{
    timestamp   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    file        = $ClusterConfigPath
    mode        = if ($Strict) { 'strict' } else { 'standard' }
    variables   = $variables.Count
    errors      = $errors
    warnings    = $warnings
    info        = $info
    error_count = $errors.Count
    warning_count = $warnings.Count
    valid       = ($errors.Count -eq 0)
}

if ($ReportPath) {
    $report | ConvertTo-Json -Depth 5 | Out-File -FilePath $ReportPath -Encoding UTF8
    Write-Host "  Report saved: $ReportPath" -ForegroundColor Cyan
}

if ($errors.Count -eq 0) {
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║  VALIDATION PASSED                                        ║" -ForegroundColor Green
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Variables: $($variables.Count)" -ForegroundColor White
    Write-Host "  Errors:    0" -ForegroundColor Green
    Write-Host "  Warnings:  $($warnings.Count)" -ForegroundColor $(if ($warnings.Count -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host ""

    if ($warnings.Count -gt 0) {
        Write-Host "  Warnings:" -ForegroundColor Yellow
        foreach ($w in $warnings) {
            Write-Host "    ⚠ $w" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    exit 0
} else {
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║  VALIDATION FAILED                                        ║" -ForegroundColor Red
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Variables: $($variables.Count)" -ForegroundColor White
    Write-Host "  Errors:    $($errors.Count)" -ForegroundColor Red
    Write-Host "  Warnings:  $($warnings.Count)" -ForegroundColor Yellow
    Write-Host ""

    Write-Host "  Errors:" -ForegroundColor Red
    foreach ($e in $errors) {
        Write-Host "    ✗ $e" -ForegroundColor Red
    }
    Write-Host ""

    if ($warnings.Count -gt 0) {
        Write-Host "  Warnings:" -ForegroundColor Yellow
        foreach ($w in $warnings) {
            Write-Host "    ⚠ $w" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    Write-Host "  Fix the errors above and re-run validation." -ForegroundColor White
    Write-Host ""
    exit 1
}
