<#
.SYNOPSIS
    Mounts Azure Local ISO as virtual media on Dell servers via iDRAC Redfish API.

.DESCRIPTION
    Uses Redfish API to mount an ISO as virtual CD on Dell PowerEdge servers via iDRAC,
    then sets one-time boot to CD. Uses CIFS share credentials from environment.yaml config.

    The qualified username (SERVER\user) is built at runtime by extracting the server name
    from ztp.share_network_path, so the config stays portable across environments.

.PARAMETER ServerIPs
    Array of iDRAC IP addresses. Defaults to config values.

.PARAMETER Credential
    PSCredential for iDRAC authentication.

.PARAMETER IsoUrl
    Override: HTTP/HTTPS URL to ISO. Bypasses CIFS and share credentials entirely.

.PARAMETER DelayBetweenServers
    Delay in seconds between servers (default: 10)

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    $cred = Get-Credential
    .\Mount-AzureLocalISO.ps1 -Credential $cred -Force

.EXAMPLE
    .\Mount-AzureLocalISO.ps1 -Credential $cred -IsoUrl "http://10.250.1.38:8080/provision-os.iso" -Force

.NOTES
    Requires: PowerShell 7.0+, AzureLocalConfig.psm1

    Config keys used:
      keyvault.platform_name - Key Vault name for iDRAC credentials
      ztp.idrac_secret_name  - Secret name in Key Vault (format: username:password)
      ztp.share_location     - local path to ISO directory (e.g. C:\share\ztp)
      ztp.share_network_path - UNC path to share (e.g. \\util-eus-01\share\ztp)
      ztp.share_username     - local account name (e.g. svc_idrac_share)
      ztp.share_password     - account password
#>
param(
    [Parameter(Mandatory=$false)]
    [string[]]$ServerIPs,

    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory=$false)]
    [string]$IsoUrl,

    [Parameter(Mandatory=$false)]
    [int]$DelayBetweenServers = 10,

    [Parameter(Mandatory=$false)]
    [switch]$Force
)

#Requires -Version 7.0

# Validate parameters
if ($ServerIPs) {
    foreach ($ip in $ServerIPs) {
        if ($ip -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
            throw "Invalid IP address provided: $ip"
        }
    }
}

if ($Credential -and $Credential.GetType().Name -ne 'PSCredential') {
    throw "Credential parameter must be a PSCredential object"
}

# ── Load Config ──────────────────────────────────────────────────────────────
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $scriptDir
while ($repoRoot -and !(Test-Path (Join-Path $repoRoot "config"))) {
    $repoRoot = Split-Path -Parent $repoRoot
}
if (!$repoRoot) { throw "Could not find repository root (config directory not found)" }

$configModulePath = Join-Path $repoRoot "scripts\common\AzureLocalConfig.psm1"
if (!(Test-Path $configModulePath)) { throw "Config module not found at $configModulePath" }
Import-Module $configModulePath -Force
$config = Get-AzureLocalConfig

# ── Resolve Server IPs ──────────────────────────────────────────────────────
if (-not $ServerIPs) { $ServerIPs = $config.GetIdracIPs() }
if (-not $ServerIPs -or $ServerIPs.Count -eq 0) { throw "No server IPs provided and none found in config" }
Write-Host "Using ServerIPs: $($ServerIPs -join ', ')" -ForegroundColor Cyan

# ── Build InsertMedia Payload ────────────────────────────────────────────────
if ($IsoUrl -and $IsoUrl -match '^https?://') {
    # HTTP override - no share credentials needed
    Write-Host "Using HTTP: $IsoUrl" -ForegroundColor Cyan
    $insertBodyTemplate = @{
        Image          = $IsoUrl
        Inserted       = $true
        WriteProtected = $true
    }
} else {
    # CIFS from config
    $shareLocation   = $config.GetValue('ztp.share_location')
    $shareNetworkPath = $config.GetValue('ztp.share_network_path')
    $shareUsername   = $config.GetValue('ztp.share_username')
    $sharePassword   = $config.GetValue('ztp.share_password')

    # Auto-detect ISO
    $isoFile = Get-ChildItem -Path $shareLocation -Filter "*.iso" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $isoFile) { throw "No ISO file found in: $shareLocation" }
    Write-Host "Auto-detected ISO: $($isoFile.Name)" -ForegroundColor Green

    # Build CIFS path with forward slashes
    $cifsPath = "$shareNetworkPath\$($isoFile.Name)".Replace('\', '/')
    Write-Host "CIFS path: $cifsPath" -ForegroundColor Cyan

    # Build qualified username: extract server name from \\server\share\path
    # share_network_path = \\util-eus-01\share\ztp  →  server = util-eus-01
    $shareServer = ($shareNetworkPath -replace '^\\\\', '') -split '\\' | Select-Object -First 1
    $qualifiedUsername = "$shareServer\$shareUsername"
    Write-Host "Share account: $qualifiedUsername" -ForegroundColor Gray

    $insertBodyTemplate = @{
        Image    = $cifsPath
        UserName = $qualifiedUsername
        Password = $sharePassword
    }
}

# ── Resolve iDRAC Credentials ───────────────────────────────────────────────
if (!$Credential) {
    $keyVaultName = $config.GetValue('keyvault.platform_name')
    $secretName = $config.GetValue('ztp.idrac_secret_name')
    if ($keyVaultName -and $secretName) {
        Write-Host "Retrieving iDRAC credentials from Key Vault '$keyVaultName'..." -ForegroundColor Cyan
        $secret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName
        if (!$secret) { throw "Failed to retrieve secret '$secretName' from Key Vault '$keyVaultName'" }
        $credString = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
        if ($credString -notmatch ':') { throw "Invalid Key Vault secret format. Expected: 'username:password'" }
        $username, $password = $credString -split ':', 2
        $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
        $Credential = New-Object PSCredential ($username, $securePassword)
        Write-Host "✓ iDRAC credentials retrieved" -ForegroundColor Green
    } else {
        $Credential = Get-Credential -Message "Enter iDRAC credentials"
    }
}

# ── Confirm ──────────────────────────────────────────────────────────────────
if (-not $Force) {
    $serverList = $ServerIPs -join ", "
    $confirm = Read-Host "Mount '$($insertBodyTemplate.Image)' on servers: $serverList. Continue? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') { Write-Host "Cancelled." ; exit 0 }
}

# ── Mount ISO on Each Server ─────────────────────────────────────────────────
$results = @()
foreach ($ip in $ServerIPs) {
    Write-Host "`n── Server $ip ──" -ForegroundColor Cyan
    $baseUrl = "https://$ip"

    try {
        # 1. Test connectivity
        Write-Host "  Connecting..." -ForegroundColor Gray
        $redfishRoot = Invoke-RestMethod -Uri "$baseUrl/redfish/v1" `
            -Credential $Credential -SkipCertificateCheck -TimeoutSec 30 -ErrorAction Stop
        Write-Host "  ✓ Connected - Redfish $($redfishRoot.RedfishVersion)" -ForegroundColor Green

        # 2. Eject existing media
        Write-Host "  Ejecting existing media..." -ForegroundColor Gray
        try {
            Invoke-RestMethod -Uri "$baseUrl/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD/Actions/VirtualMedia.EjectMedia" `
                -Method Post -Credential $Credential -SkipCertificateCheck `
                -ContentType 'application/json' -Body '{}' -TimeoutSec 30 -ErrorAction Stop
            Write-Host "  ✓ Ejected" -ForegroundColor Green
        } catch {
            Write-Host "  - No media to eject" -ForegroundColor Gray
        }

        Start-Sleep -Seconds 2

        # 3. Insert ISO
        $insertJson = $insertBodyTemplate | ConvertTo-Json
        Write-Host "  Mounting: $($insertBodyTemplate.Image)" -ForegroundColor Gray

        Invoke-RestMethod -Uri "$baseUrl/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD/Actions/VirtualMedia.InsertMedia" `
            -Method Post -Credential $Credential -SkipCertificateCheck `
            -ContentType 'application/json' -Body $insertJson -TimeoutSec 60 -ErrorAction Stop
        Write-Host "  ✓ ISO mounted" -ForegroundColor Green

        # 4. Verify
        $vmStatus = Invoke-RestMethod -Uri "$baseUrl/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD" `
            -Credential $Credential -SkipCertificateCheck -TimeoutSec 30 -ErrorAction Stop
        if ($vmStatus.Inserted -eq $true) {
            Write-Host "  ✓ Verified: $($vmStatus.Image)" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ Inserted=false - check iDRAC GUI" -ForegroundColor Yellow
        }

        # 5. Set one-time boot to CD
        $bootBody = @{ Boot = @{ BootSourceOverrideEnabled = "Once"; BootSourceOverrideTarget = "Cd" } } | ConvertTo-Json -Depth 5
        Invoke-RestMethod -Uri "$baseUrl/redfish/v1/Systems/System.Embedded.1" `
            -Method Patch -Credential $Credential -SkipCertificateCheck `
            -ContentType 'application/json' -Body $bootBody -TimeoutSec 30 -ErrorAction Stop
        Write-Host "  ✓ Boot set to CD (one-time)" -ForegroundColor Green

        $results += @{ server = $ip; success = $true; message = "OK" }
    }
    catch {
        Write-Host "  ✗ FAILED: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            Write-Host "  Response: $($_.ErrorDetails.Message)" -ForegroundColor Red
        }
        $results += @{ server = $ip; success = $false; message = $_.Exception.Message }
    }

    if ($ip -ne $ServerIPs[-1]) { Start-Sleep -Seconds $DelayBetweenServers }
}

# ── Summary ──────────────────────────────────────────────────────────────────
$ok = ($results | Where-Object { $_.success }).Count
$fail = ($results | Where-Object { -not $_.success }).Count
Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "  Total: $($results.Count)  |  OK: $ok  |  Failed: $fail" -ForegroundColor $(if ($fail -gt 0) { "Red" } else { "Green" })
if ($fail -gt 0) {
    $results | Where-Object { -not $_.success } | ForEach-Object {
        Write-Host "  ✗ $($_.server): $($_.message)" -ForegroundColor Red
    }
}
Write-Host "========================================" -ForegroundColor Yellow
