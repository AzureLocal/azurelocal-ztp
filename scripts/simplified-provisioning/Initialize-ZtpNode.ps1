#Requires -Version 7.0
#Requires -Modules powershell-yaml
<#
.SYNOPSIS
    Readies ZTP-provisioned nodes for cluster Validate. The operator supplies the environment file and the SBE folder;
    everything else is found or checked here.
.DESCRIPTION
    ZTP leaves a node on Microsoft's inbox network drivers, with DHCP and a default gateway on more than one port, and
    nothing in C:\SBE. The OEM requires its drivers before deployment (Dell, for one, says the SBE can't install drivers or firmware
    during it. Learn's validation fails with more than one physical adapter having a default gateway.

    Each step runs only when its gate passes, and waits for it with -Execute:
    Gate 1  Azure reports the node Ready to cluster: Provisioned, ProvisionOs succeeded, Arc Connected, extensions done.
    Gate 2  The node accepts a sign-in with the administrator secret ZTP set.
    Then    The SBE zip is checked against the SHA-256 in the OEM's published manifest (the SBE's own discovery XML if
            the manifest can't be reached). The network drivers are chosen from the SBE by each adapter's PCI hardware
            ID, and their catalog signatures checked. The three SBE files go to C:\SBE, and the deployment admin is
            created. Drivers, a static address on the adapter with the node's management MAC, DHCP off and the gateway
            removed on every other adapter holding a routable address, DNS and time run on the node as SYSTEM in a
            scheduled task, so the session dropping doesn't stop them. If the static address fails, DHCP comes back on.
    Gate 3  The node answers again and reports success. If a driver asked for a restart or Windows has one pending, the
            node is restarted once, and the run waits for it to come back with a new boot time.
    With -Execute and more than one node, the nodes are prepared at the same time, one worker process each.
    Gate 4  Checked on the node: static address, one default gateway, every adapter on the SBE's driver, C:\SBE
            complete, deployment admin present. Then Azure reports the node Ready again, so Arc survived the change.

    Without -Execute every gate is read once and the changes are listed. Safe to rerun: done steps are skipped.
.PARAMETER InfrastructureFile
    The environment file. Reads cluster_nodes, network_intents.management, onprem.ntp_servers, credentials,
    hardware.vendor and ztp (subscription, resource group, admin_secret, node_preparation.sbe_bundle).
.PARAMETER Node
    Nodes to prepare. Defaults to every node in the environment file.
.PARAMETER ReadyTimeoutMinutes
    How long gate 1 waits for Azure to report Ready to cluster.
.PARAMETER ReachTimeoutMinutes
    How long gates 2 and 3 wait for the node to accept a sign-in.
.PARAMETER DriverStagingPath
    Where the SBE's network drivers are unpacked on this server, one folder per SBE. Defaults to sbe-drivers in the media
    folder: ztp.media_path, else %ProgramData%\AzureLocalZtp\<ztp.site_name>\media. Refused inside a git working tree.
.PARAMETER OemConfigDirectory
    The folder of OEM definitions (<vendor>.json, which names the SBE folders that hold network drivers). Defaults to
    config/oem at the repository root.
.PARAMETER WorkerScriptPath
    The script run once per node when several nodes are prepared together with -Execute. Defaults to this script; a test
    substitutes a stub.
.PARAMETER Execute
    Wait at each gate and make the changes. Without it this is a plan.
.EXAMPLE
    ./Initialize-ZtpNode.ps1 -InfrastructureFile ./infrastructure.yml -Node node-01
.EXAMPLE
    ./Initialize-ZtpNode.ps1 -InfrastructureFile ./infrastructure.yml -Node node-01 -Execute
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'The remote script blocks declare their own param() and receive their values through -ArgumentList.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string[]]$Node,
    [int]$ReadyTimeoutMinutes = 240,
    [int]$ReachTimeoutMinutes = 30,
    [string]$DriverStagingPath,
    [string]$OemConfigDirectory = ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../config/oem'))),
    [string]$WorkerScriptPath = $PSCommandPath,
    [string]$EventLogPath,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module powershell-yaml
Add-Type -AssemblyName System.IO.Compression.FileSystem
. (Join-Path $PSScriptRoot 'ZtpAzure.Common.ps1')
. (Join-Path $PSScriptRoot 'ZtpEnvironment.Common.ps1')
. (Join-Path $PSScriptRoot 'ZtpEvents.Common.ps1')

# Progress for monitors (Sonar follows this file): one event per gate, stage 'Prepare'. Only with -Execute and a path.
function Send-PrepareEvent([string]$Node, [string]$State, [string]$Evidence, [string]$Level = 'Info', [string]$NextAction = '') {
    if (-not $Execute -or -not $EventLogPath) { return }
    try { Write-ZtpEvent -Path $EventLogPath -Node $Node -State $State -Evidence $Evidence -NextAction $NextAction -Level $Level -Stage 'Prepare' }
    catch { Write-Warning "Couldn't write the Prepare event to ${EventLogPath}: $($_.Exception.Message)" }
}

# Progress goes to the information stream, so functions that return objects stay clean. Capture it with *>&1.
function Write-Step([string]$Text) { Write-Information -MessageData "$((Get-Date).ToUniversalTime().ToString('HH:mm:ss'))Z $Text" -InformationAction Continue }

# The environment file must hold every key this script reads before anything runs.
$env_ = Read-ZtpEnvironmentFile -Path $InfrastructureFile
Assert-ZtpEnvironment -Environment $env_ -For Prepare -Source $InfrastructureFile
$ztp = $env_.ztp
$tenant = [string]$env_.azure_identity.azure_tenant_id
$clusterSub = [string]$ztp.subscription_id
$rgPath = "/subscriptions/$clusterSub/resourceGroups/$([string]$ztp.resource_group)/providers/Microsoft.AzureStackHCI/edgeMachines"
$mgmtNet = $env_.network_intents.management
$prefix = [int](([string]$mgmtNet.subnet) -split '/')[1]
$gateway = [string]$mgmtNet.gateway
$dns = @($mgmtNet.dns_servers | ForEach-Object { [string]$_ })
$ntp = @($env_.onprem.ntp_servers | ForEach-Object { [string]$_ })
$deployAdmin = [string]$env_.credentials.local_admin_username
# static: set ip_address on the management port (the provisioning service may already have); dhcp: leave it on DHCP
# (reserve ip_address); preconfigured: leave the port as it is. Other ports lose DHCP and gateways in every mode.
$mgmtMode = Get-ZtpManagementAssignment -Environment $env_

$envNodes = @($env_.cluster_nodes)
$Node = @(Resolve-ZtpNodeSelection -Environment $env_ -Node $Node)
if (-not $DriverStagingPath) { $DriverStagingPath = Join-Path (Resolve-ZtpDataPath -Environment $env_ -Kind media) 'sbe-drivers' }
elseif (Find-ZtpGitWorkTree -Path $DriverStagingPath) { throw "-DriverStagingPath $DriverStagingPath is inside the git working tree $(Find-ZtpGitWorkTree -Path $DriverStagingPath); unpacked drivers don't belong in a repository." }

# ------------------------------------------------------------------ the SBE: verify, then index its network drivers
$sbe = Get-ZtpSbeBundle -Path ([string]$ztp.node_preparation.sbe_bundle)
$zip = $sbe.Zip
$sbeName = $sbe.Name
$sbeFiles = $sbe.Files

$oemFile = Join-Path $OemConfigDirectory "$(([string]$env_.hardware.vendor).ToLowerInvariant()).json"
$oemConfig = if (Test-Path -LiteralPath $oemFile) { Get-Content -LiteralPath $oemFile -Raw | ConvertFrom-Json } else { $null }
$manifestUrl = if ($oemConfig -and $oemConfig.sbe.PSObject.Properties['discoveryManifestUrl']) { [string]$oemConfig.sbe.discoveryManifestUrl } else { '' }
$driverPaths = @(if ($oemConfig -and $oemConfig.sbe.PSObject.Properties['driverPaths']) { $oemConfig.sbe.driverPaths | ForEach-Object { ([string]$_).Trim('/') } })
if (-not $driverPaths) { throw "Set sbe.driverPaths in ${oemFile}: the folders inside the OEM's SBE zip that hold network drivers." }
$hashCheck = Test-ZtpSbeHash -Bundle $sbe -ManifestUrl $manifestUrl
$zipHash = $hashCheck.Hash
Write-Step "SBE $sbeName`: SHA-256 matches $($hashCheck.Source)."

$staging = [IO.Path]::GetFullPath((Join-Path $DriverStagingPath $sbeName))
if (-not (Test-Path (Join-Path $staging '.extracted'))) {
    $archive = [IO.Compression.ZipFile]::OpenRead($zip.FullName)
    try {
        # Some OEM zips use backslashes in entry names.
        foreach ($e in @($archive.Entries | Where-Object { $entry = $_.FullName -replace '\\', '/'; $_.Name -and @($driverPaths | Where-Object { $entry -like "$_/*" }).Count })) {
            $out = [IO.Path]::GetFullPath((Join-Path $staging ($e.FullName -replace '/', '\')))
            if (-not $out.StartsWith($staging + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "$($zip.Name) has an entry that unpacks outside the staging folder: $($e.FullName)" }
            New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
        }
    }
    finally { $archive.Dispose() }
    Set-Content (Join-Path $staging '.extracted') (Get-Date).ToUniversalTime().ToString('o')
}
$infIndex = foreach ($inf in @($driverPaths | ForEach-Object { Join-Path $staging ($_ -replace '/', '\') } | Where-Object { Test-Path $_ } | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -Filter '*.inf' })) {
    $text = Get-Content -LiteralPath $inf.FullName -Raw
    $ver = [regex]::Match($text, '(?im)^\s*DriverVer\s*=\s*[^,]+,\s*([\d.]+)').Groups[1].Value
    $ids = @([regex]::Matches($text.ToUpperInvariant(), 'PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}') | ForEach-Object Value | Select-Object -Unique)
    [pscustomobject]@{ Inf = $inf.Name; Version = $ver; Ids = $ids; Local = $inf.DirectoryName; Folder = ($inf.DirectoryName.Substring($staging.Length).Trim('\') -replace '\\', '_') }
}
Write-Step "SBE network drivers indexed: $(@($infIndex).Count)."

# ------------------------------------------------------------------ several nodes: all at once
# Each node gets its own worker process running this script for that node alone, so their Azure contexts and sessions
# stay apart. The SBE is verified and unpacked above, once, before they start. Every worker's lines carry its node name.
if ($Execute -and @($Node).Count -gt 1) {
    $self = $WorkerScriptPath
    $envPath = (Resolve-Path -LiteralPath $InfrastructureFile).Path
    Write-Step "Preparing $($Node -join ', ') at the same time"
    $outcome = @($Node | ForEach-Object -ThrottleLimit @($Node).Count -Parallel {
            $n = $_
            $workerArgs = @('-NoProfile', '-File', $using:self, '-InfrastructureFile', $using:envPath, '-Node', $n,
                '-ReadyTimeoutMinutes', $using:ReadyTimeoutMinutes, '-ReachTimeoutMinutes', $using:ReachTimeoutMinutes,
                '-DriverStagingPath', $using:DriverStagingPath, '-OemConfigDirectory', $using:OemConfigDirectory, '-Execute')
            if ($using:EventLogPath) { $workerArgs += @('-EventLogPath', $using:EventLogPath) }
            & pwsh @workerArgs 2>&1 | ForEach-Object { Write-Information -MessageData "[$n] $_" -InformationAction Continue }
            [pscustomobject]@{ Node = $n; ExitCode = $LASTEXITCODE }
        })
    $notReady = @($outcome | Where-Object { $_.ExitCode -ne 0 } | ForEach-Object Node)
    if ($notReady) { throw "Not ready: $($notReady -join ', ')" }
    Write-Step "All ready for Validate: $($Node -join ', ')"
    return
}
# ------------------------------------------------------------------ credentials
Set-AzContext -Tenant $tenant -Subscription ([string]$ztp.admin_secret.subscription_id) -Scope Process -WarningAction SilentlyContinue | Out-Null
$adminPassword = (Get-AzKeyVaultSecret -VaultName ([string]$ztp.admin_secret.vault) -Name ([string]$ztp.admin_secret.name)).SecretValue
$deployRef = [string]$env_.credentials.local_admin_password_secret
if ($deployRef -notmatch '^keyvault://([^/]+)/(.+)$') { throw 'credentials.local_admin_password_secret must be keyvault://<vault>/<secret>.' }
$deployPassword = (Get-AzKeyVaultSecret -VaultName $Matches[1] -Name $Matches[2]).SecretValue
Set-AzContext -Tenant $tenant -Subscription $clusterSub -Scope Process -WarningAction SilentlyContinue | Out-Null

# ------------------------------------------------------------------ gates
function Get-AzureReady([string]$Name) {
    $machine = Invoke-ZtpArm -Method GET -Path "$rgPath/$Name" -AllowNotFound
    $job = if ($machine) { Invoke-ZtpArm -Method GET -Path "$rgPath/$Name/jobs/ProvisionOs" -AllowNotFound } else { $null }
    Get-ZtpEdgeMachineStatus -Name $Name -Machine $machine -Job $job
}
function Wait-AzureReady([string]$Name, [int]$Minutes) {
    $deadline = (Get-Date).AddMinutes($Minutes); $last = ''
    while ($true) {
        $st = Get-AzureReady $Name
        $line = "lifecycle $($st.Lifecycle), job $($st.JobStatus), Arc $($st.Connectivity)$(if ($st.CurrentStage) { ", at $($st.CurrentStage)" })"
        if ($line -ne $last) { Write-Step "  Azure: $line"; $last = $line }
        if ($st.Ready) { return $st }
        if ($st.Failed) { throw "Azure reports $Name failed: $($st.FailureReason)" }
        if (-not $Execute) { return $st }
        if ((Get-Date) -gt $deadline) { throw "$Name wasn't Ready to cluster within $Minutes minutes." }
        Start-Sleep 60
    }
}
function Test-WinRmPort([string]$Ip) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try { return ($client.ConnectAsync($Ip, 5985).Wait(3000) -and $client.Connected) } catch { return $false } finally { $client.Dispose() }
}
# Where to sign in first. The provisioned OS takes its management address from DHCP, so without a DHCP reservation the
# node isn't on the environment file's address yet: then use the address its Arc machine reports for the management MAC.
# The static address is set during preparation, and every later step signs in on it.
function Resolve-ConnectAddress([string]$Name, [string]$Ip, [string]$Mac) {
    if (-not $Execute -or (Test-WinRmPort $Ip)) { return $Ip }
    try { return (Find-DhcpAddress $Name $Ip $Mac) }
    catch { Write-Warning "  Couldn't read $Name's address from its Arc machine: $($_.Exception.Message)"; return $Ip }
}
function Find-DhcpAddress([string]$Name, [string]$Ip, [string]$Mac) {
    $job = Invoke-ZtpArm -Method GET -Path "$rgPath/$Name/jobs/ProvisionOs" -AllowNotFound
    $arcId = [string](Get-ZtpPathValue $job 'properties.provisioningRequest.onboardingConfiguration.resourceId')
    if (-not $arcId) { return $Ip }
    $arc = Invoke-ZtpArm -Method GET -Path $arcId -ApiVersion '2024-07-10' -AllowNotFound
    foreach ($candidate in @(if ($arc) { Get-ZtpArcMachineAddress -Machine $arc -MacAddress $Mac })) {
        if (Test-WinRmPort $candidate) {
            Write-Step "  $Name doesn't answer on $Ip yet; its Arc machine reports $candidate (DHCP) for $Mac. Signing in there; preparation sets $Ip."
            $trusted = [string](Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue).Value
            if ($trusted -ne '*' -and ($trusted -split ',' | ForEach-Object Trim) -notcontains $candidate) {
                Write-Warning "  $candidate isn't in this server's WinRM TrustedHosts, so a sign-in by address fails (0x8009030e). Add it, then rerun."
            }
            return $candidate
        }
    }
    return $Ip
}
function Wait-Session([string]$Ip, [pscredential]$Cred, [int]$Minutes) {
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ($true) {
        try { return New-PSSession -ComputerName $Ip -Credential $Cred -Authentication Negotiate -ErrorAction Stop }
        catch {
            if (-not $Execute -or (Get-Date) -gt $deadline) { throw "No sign-in to $Ip with the ZTP administrator secret: $($_.Exception.Message)" }
            Start-Sleep 20
        }
    }
}

$readState = {
    param([string]$Mac, [string]$ZipName, [string]$Admin)
    Set-StrictMode -Off
    $adapters = @(Get-NetAdapter -Physical | ForEach-Object {
            $a = $_
            [pscustomobject]@{
                Name = $a.Name; Mac = $a.MacAddress; Description = $a.InterfaceDescription; Driver = $a.DriverVersionString; Status = [string]$a.Status
                Id = if ($a.PnPDeviceID -match '^(PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4})') { $Matches[1].ToUpperInvariant() } else { '' }
                Addresses = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength) $($_.PrefixOrigin)" })
                Gateway = [bool](Get-NetRoute -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
                Dhcp = [string](Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
            } })
    $mgmt = $adapters | Where-Object Mac -eq $Mac | Select-Object -First 1
    $zip = Join-Path C:\SBE $ZipName
    [pscustomobject]@{
        Host     = $env:COMPUTERNAME
        Adapters = $adapters
        Mgmt     = $mgmt
        Dns      = if ($mgmt) { @((Get-DnsClientServerAddress -InterfaceAlias $mgmt.Name -AddressFamily IPv4).ServerAddresses) } else { @() }
        SbeFiles = @(Get-ChildItem C:\SBE -File -ErrorAction SilentlyContinue | ForEach-Object Name)
        SbeHash  = if (Test-Path $zip) { (Get-FileHash $zip -Algorithm SHA256).Hash } else { '' }
        Admin    = [bool](Get-LocalUser -Name $Admin -ErrorAction SilentlyContinue)
        Time     = (& w32tm.exe /query /source 2>$null | Select-Object -First 1)
        Booted   = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        RebootPending = [bool]((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
            (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
            (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue) -or
            ((Test-Path 'C:\ProgramData\AzureLocalZtp\restart-required') -and (Get-Item 'C:\ProgramData\AzureLocalZtp\restart-required').LastWriteTimeUtc -gt (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()))
    }
}

function Get-DriverPlan($State) {
    foreach ($a in @($State.Adapters | Where-Object Id)) {
        $match = @($infIndex | Where-Object { $_.Ids -contains $a.Id }) | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
        [pscustomobject]@{ Adapter = $a.Name; Id = $a.Id; Have = $a.Driver; Want = if ($match) { $match.Version } else { '' }; Driver = $match }
    }
}
function Get-ExtraGateway($State) {
    # Every adapter but the management one that holds a routable address or a default route.
    @($State.Adapters | Where-Object { $_.Mac -ne $State.Mgmt.Mac -and ($_.Gateway -or @($_.Addresses | Where-Object { $_ -notlike '169.254.*' }).Count) } | ForEach-Object Name)
}
function Show-State($State, $Plan) {
    $m = $State.Mgmt
    Write-Step "  $($State.Host): management $($m.Name) $($m.Addresses -join ', '). Default gateway on: $(@($State.Adapters | Where-Object Gateway | ForEach-Object Name) -join ', '). DNS $($State.Dns -join ', '). Time $($State.Time)"
    foreach ($d in $Plan) { Write-Step "  $($d.Adapter) $($d.Id) driver $($d.Have)$(if (-not $d.Want) { ' (no driver for it in the SBE)' } elseif ($d.Have -ne $d.Want) { " -> $($d.Want) ($($d.Driver.Inf))" } else { ' (SBE version)' })" }
    Write-Step "  C:\SBE: $(if ($State.SbeFiles) { $State.SbeFiles -join ', ' } else { 'empty' }). $deployAdmin exists: $($State.Admin). Restart pending: $($State.RebootPending). Booted $($State.Booted)"
}

# ------------------------------------------------------------------ runs on the node as SYSTEM; no secrets in it
$nodeScript = @'
$ErrorActionPreference = 'Stop'
$dir = 'C:\ProgramData\AzureLocalZtp'
$p = Get-Content (Join-Path $dir 'params.json') -Raw | ConvertFrom-Json
$log = [System.Collections.Generic.List[string]]::new()
$status = 'Succeeded'
$reboot = $false
function Get-Id($a) { if ($a.PnPDeviceID -match '^(PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4})') { $Matches[1].ToUpperInvariant() } }
try {
    foreach ($d in $p.Drivers) {
        $stale = @(Get-NetAdapter -Physical | Where-Object { $d.Ids -contains (Get-Id $_) -and $_.DriverVersionString -ne $d.Version })
        if (-not $stale) { $log.Add("driver $($d.Inf): already $($d.Version)"); continue }
        $out = & pnputil.exe /add-driver (Join-Path $dir "drivers\$($d.Folder)\$($d.Inf)") /install 2>&1
        $log.Add("driver $($d.Inf) $($d.Version): pnputil exit $LASTEXITCODE")
        if ($LASTEXITCODE -notin 0, 259, 3010) { throw "pnputil $($d.Inf) exit $LASTEXITCODE`: $($out -join ' ')" }
        if ($LASTEXITCODE -eq 3010) { $reboot = $true; Set-Content (Join-Path $dir 'restart-required') (Get-Date).ToUniversalTime().ToString('o') }
    }
    $deadline = (Get-Date).AddMinutes(5)
    do { Start-Sleep 5; $down = @(Get-NetAdapter -Physical | Where-Object { (Get-Id $_) -and $_.Status -ne 'Up' }) } while ($down -and (Get-Date) -lt $deadline)
    if ($down) { $log.Add("not Up after drivers: $($down.Name -join ',')") }

    $nic = Get-NetAdapter -Physical | Where-Object { $_.MacAddress -eq $p.MgmtMac } | Select-Object -First 1
    if (-not $nic) { throw "No adapter with MAC $($p.MgmtMac)" }
    foreach ($o in @(Get-NetAdapter -Physical | Where-Object { $_.ifIndex -ne $nic.ifIndex })) {
        $routable = @(Get-NetIPAddress -InterfaceIndex $o.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' })
        $route = Get-NetRoute -InterfaceIndex $o.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
        # Same model as the management adapter (its team partner, for example) gets DHCP off even with no lease yet: a driver
        # install resets the link, and DHCP would otherwise hand it an address and a second gateway after the restart.
        $sibling = (Get-Id $o) -and (Get-Id $o) -eq (Get-Id $nic) -and ((Get-NetIPInterface -InterfaceIndex $o.ifIndex -AddressFamily IPv4).Dhcp -eq 'Enabled')
        if (-not $routable -and -not $route -and -not $sibling) { continue }
        Set-NetIPInterface -InterfaceIndex $o.ifIndex -AddressFamily IPv4 -Dhcp Disabled
        $routable | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        $route | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        $log.Add("$($o.Name): DHCP off, address and gateway removed")
    }
    $static = Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $p.Ip -and $_.PrefixOrigin -eq 'Manual' }
    if ($p.Mode -ne 'static') { $log.Add("$($nic.Name): management address left as it is ($($p.Mode))") }
    elseif ($static) { $log.Add("$($nic.Name): already static $($p.Ip)") }
    else {
        try {
            Set-NetIPInterface -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -Dhcp Disabled
            Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            Get-NetRoute -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $p.Ip -PrefixLength $p.Prefix -DefaultGateway $p.Gateway | Out-Null
            $log.Add("$($nic.Name): static $($p.Ip)/$($p.Prefix) gateway $($p.Gateway)")
        }
        catch {
            Set-NetIPInterface -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -Dhcp Enabled
            throw "Static address failed, DHCP turned back on: $($_.Exception.Message)"
        }
    }
    if ($p.Mode -eq 'static') {
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $p.Dns
        $log.Add("$($nic.Name): DNS $($p.Dns -join ',')")
    }
    if ($p.Ntp) {
        & w32tm.exe /config /manualpeerlist:"$($p.Ntp -join ' ')" /syncfromflags:manual /update | Out-Null
        Restart-Service w32time
        # Wait until the node actually syncs from one of them, not just has them configured.
        $deadline = (Get-Date).AddMinutes(3)
        do { Start-Sleep 10; & w32tm.exe /resync /force | Out-Null; $src = [string](& w32tm.exe /query /source | Select-Object -First 1) } while (@($p.Ntp | Where-Object { $src -like "$_*" }).Count -eq 0 -and (Get-Date) -lt $deadline)
        $log.Add("time: $($p.Ntp -join ','), syncing from $($src.Trim())")
    }
}
catch { $status = 'Failed'; $log.Add("ERROR: $($_.Exception.Message)") }
[ordered]@{ status = $status; rebootRequired = $reboot; finished = (Get-Date).ToUniversalTime().ToString('o'); log = $log } | ConvertTo-Json | Set-Content (Join-Path $dir 'result.json')
'@

# ------------------------------------------------------------------ per node
$failed = @()
foreach ($n in $Node) {
    $cfg = $envNodes | Where-Object { [string]$_.name -eq $n }
    $ip = [string]$cfg.ip_address
    $mac = ([string]$cfg.mac_address).Replace(':', '-').ToUpperInvariant()
    $cred = [pscredential]::new("$n\$([string]$ztp.admin_secret.username)", $adminPassword)
    $s = $null
    Write-Step "== $n ($ip)"
    try {
        Write-Step "  Gate 1: Azure reports Ready to cluster"
        $az = Wait-AzureReady $n $ReadyTimeoutMinutes
        if (-not $az.Ready) { throw "Not Ready to cluster yet. With -Execute this waits up to $ReadyTimeoutMinutes minutes." }
        Send-PrepareEvent $n 'PrepareStarted' 'Azure reports Ready to cluster; signing in to install the OEM network drivers and set the network'
        Write-Step "  Gate 2: sign-in with the ZTP administrator secret"
        $s = Wait-Session (Resolve-ConnectAddress $n $ip $mac) $cred $ReachTimeoutMinutes
        $before = Invoke-Command -Session $s -ScriptBlock $readState -ArgumentList $mac, $zip.Name, $deployAdmin
        if (-not $before.Mgmt) { throw "No adapter on $n has the environment file's MAC $mac." }
        $plan = @(Get-DriverPlan $before)
        Show-State $before $plan
        $missing = @($plan | Where-Object { -not $_.Want })
        if ($missing) { Write-Warning "  No SBE driver for $(($missing | ForEach-Object { "$($_.Adapter) $($_.Id)" }) -join ', '); Validate may reject them." }
        $drivers = @($plan | Where-Object { $_.Driver } | ForEach-Object Driver | Sort-Object Folder -Unique)
        foreach ($d in $drivers) {
            foreach ($cat in Get-ChildItem -LiteralPath $d.Local -Filter '*.cat') {
                $sig = Get-AuthenticodeSignature -LiteralPath $cat.FullName
                if ($sig.Status -ne 'Valid') { throw "$($cat.Name) for $($d.Inf) has signature $($sig.Status)." }
            }
        }
        $extra = Get-ExtraGateway $before
        if (-not $Execute) {
            $addressPlan = if ($mgmtMode -eq 'static') { "static $ip/$prefix gw $gateway on $($before.Mgmt.Name)" } else { "$($before.Mgmt.Name) left as it is ($mgmtMode; expect $ip)" }
            Write-Step "  PLAN: drivers $(($drivers | ForEach-Object { "$($_.Inf) $($_.Version)" }) -join ', ') (signatures valid); SBE to C:\SBE; create $deployAdmin; $addressPlan; DHCP and gateway off on $(if ($extra) { $extra -join ', ' } else { 'none' }); DNS $($dns -join ','); time $($ntp -join ',')."
            continue
        }

        if ($before.SbeHash -ne $zipHash -or @($sbeFiles.Name | Where-Object { @($before.SbeFiles) -notcontains $_ })) {
            Invoke-Command -Session $s -ScriptBlock { New-Item -ItemType Directory -Force C:\SBE | Out-Null }
            foreach ($f in $sbeFiles) { Copy-Item -LiteralPath $f.FullName -Destination 'C:\SBE\' -ToSession $s -Force }
            Write-Step "  C:\SBE: SBE files copied"
        }
        else { Write-Step "  C:\SBE: already holds the SBE" }

        Invoke-Command -Session $s -ScriptBlock {
            param([string[]]$Folders)
            Remove-Item 'C:\ProgramData\AzureLocalZtp\result.json' -ErrorAction SilentlyContinue
            foreach ($f in $Folders) { New-Item -ItemType Directory -Force "C:\ProgramData\AzureLocalZtp\drivers\$f" | Out-Null }
        } -ArgumentList (, @($drivers | ForEach-Object Folder))
        foreach ($d in $drivers) { Copy-Item -Path (Join-Path $d.Local '*') -Destination "C:\ProgramData\AzureLocalZtp\drivers\$($d.Folder)\" -ToSession $s -Recurse -Force }

        Invoke-Command -Session $s -ScriptBlock {
            param([string]$User, [securestring]$Password)
            if ($User -in 'Administrator', 'Guest') { throw "Refusing built-in account $User as the deployment admin." }
            if (Get-LocalUser -Name $User -ErrorAction SilentlyContinue) { Set-LocalUser -Name $User -Password $Password -PasswordNeverExpires $true; Enable-LocalUser -Name $User }
            else { New-LocalUser -Name $User -Password $Password -PasswordNeverExpires -Description 'Azure Local deployment admin' | Out-Null }
            if (-not (Get-LocalGroupMember -Group Administrators | Where-Object Name -like "*\$User")) { Add-LocalGroupMember -Group Administrators -Member $User }
        } -ArgumentList $deployAdmin, $deployPassword
        Write-Step "  $deployAdmin is in local Administrators"

        $params = @{ Mode = $mgmtMode; MgmtMac = $mac; Ip = $ip; Prefix = $prefix; Gateway = $gateway; Dns = $dns; Ntp = $ntp
            Drivers = @($drivers | ForEach-Object { @{ Inf = $_.Inf; Version = $_.Version; Ids = $_.Ids; Folder = $_.Folder } }) } | ConvertTo-Json -Depth 6
        Invoke-Command -Session $s -ScriptBlock {
            param([string]$Script, [string]$Params)
            Set-Content 'C:\ProgramData\AzureLocalZtp\prepare.ps1' $Script
            Set-Content 'C:\ProgramData\AzureLocalZtp\params.json' $Params
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\AzureLocalZtp\prepare.ps1'
            Register-ScheduledTask -TaskName 'AzureLocalZtpNodePrepare' -Action $action -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
            Start-ScheduledTask -TaskName 'AzureLocalZtpNodePrepare'
        } -ArgumentList $nodeScript, $params
        Write-Step "  Drivers and network changing on the node; the session may drop"
        Remove-PSSession $s; $s = $null

        Write-Step "  Gate 3: node answers and reports a result"
        $result = $null; $deadline = (Get-Date).AddMinutes($ReachTimeoutMinutes)
        while (-not $result) {
            if ((Get-Date) -gt $deadline) { throw "$n reported no result within $ReachTimeoutMinutes minutes. Check it from the iDRAC console." }
            Start-Sleep 20
            try {
                $s = New-PSSession -ComputerName $ip -Credential $cred -Authentication Negotiate -ErrorAction Stop
                $result = Invoke-Command -Session $s -ScriptBlock { if (Test-Path 'C:\ProgramData\AzureLocalZtp\result.json') { Get-Content 'C:\ProgramData\AzureLocalZtp\result.json' -Raw | ConvertFrom-Json } }
                if (-not $result) { Remove-PSSession $s; $s = $null }
            }
            catch { $s = $null }
        }
        $result.log | ForEach-Object { Write-Step "  node: $_" }
        Invoke-Command -Session $s -ScriptBlock { Unregister-ScheduledTask -TaskName 'AzureLocalZtpNodePrepare' -Confirm:$false -ErrorAction SilentlyContinue }
        if ($result.status -ne 'Succeeded') { throw "Preparation failed on $n." }
        Send-PrepareEvent $n 'PrepareDriversInstalled' (@($result.log) -join '; ')

        $mid = Invoke-Command -Session $s -ScriptBlock $readState -ArgumentList $mac, $zip.Name, $deployAdmin
        if ($result.rebootRequired -or $mid.RebootPending) {
            Send-PrepareEvent $n 'PrepareRestarting' $(if ($result.rebootRequired) { 'a driver asked for a restart' } else { 'Windows has a restart pending' })
            Write-Step "  Gate 3b: restart, because $(if ($result.rebootRequired) { 'a driver asked for one' } else { 'Windows has a restart pending' })"
            # Restarting inside the call kills the session before it returns, which reads as a failure. Schedule it a few
            # seconds out so the call returns first; a drop while it returns is expected.
            try { Invoke-Command -Session $s -ScriptBlock { & shutdown.exe /r /t 10 /d p:2:4 /c 'Azure Local ZTP node preparation: driver restart' } }
            catch { Write-Step "  session dropped while the restart was scheduled ($($_.Exception.Message)); continuing" }
            Remove-PSSession $s -ErrorAction SilentlyContinue; $s = $null
            # Wait for a new boot time. Windows can keep WinRM answering for a minute or more after the restart is
            # scheduled, so a session opened in that window dies mid-call (seen live). Any failure while probing means
            # "not back yet"; only a new boot time, or the time limit, ends the wait.
            $backWithin = $ReachTimeoutMinutes + 10
            $backBy = (Get-Date).AddMinutes($backWithin)
            $booted = $mid.Booted
            while ($booted -eq $mid.Booted) {
                if ((Get-Date) -gt $backBy) { throw "$n didn't come back with a new boot time within $backWithin minutes (still $booted)." }
                Start-Sleep 20
                try {
                    $probe = New-PSSession -ComputerName $ip -Credential $cred -Authentication Negotiate -ErrorAction Stop
                    try { $booted = (Invoke-Command -Session $probe -ScriptBlock $readState -ArgumentList $mac, $zip.Name, $deployAdmin -ErrorAction Stop).Booted }
                    finally { Remove-PSSession $probe -ErrorAction SilentlyContinue }
                }
                catch { Write-Verbose "  $n not back yet: $($_.Exception.Message)" }
            }
            $s = Wait-Session $ip $cred $ReachTimeoutMinutes
            Write-Step "  $n restarted at $booted"
            Send-PrepareEvent $n 'PrepareRestarted' "new boot time $booted"
        }

        Write-Step "  Gate 4: checks on the node, then Azure"
        # Time takes a moment to resync after a restart: resync and wait for it before checking.
        if ($ntp) {
            $timeDeadline = (Get-Date).AddMinutes(5)
            do {
                $src = Invoke-Command -Session $s -ScriptBlock { & w32tm.exe /resync /force | Out-Null; Start-Sleep 10; [string](& w32tm.exe /query /source | Select-Object -First 1) }
            } while (-not @($ntp | Where-Object { $src.Trim() -like "$_*" }) -and (Get-Date) -lt $timeDeadline)
        }
        $after = Invoke-Command -Session $s -ScriptBlock $readState -ArgumentList $mac, $zip.Name, $deployAdmin
        $afterPlan = @(Get-DriverPlan $after)
        Show-State $after $afterPlan
        $problems = @()
        if ($mgmtMode -eq 'static' -and @($after.Mgmt.Addresses) -notcontains "$ip/$prefix Manual") { $problems += "management address isn't static $ip" }
        if ($mgmtMode -ne 'static' -and -not @($after.Mgmt.Addresses | Where-Object { $_ -like "$ip/$prefix *" })) { $problems += "management address isn't $ip ($mgmtMode)" }
        $gw = @($after.Adapters | Where-Object Gateway | ForEach-Object Name)
        $dhcpSiblings = @($after.Adapters | Where-Object { $_.Mac -ne $after.Mgmt.Mac -and $_.Id -and $_.Id -eq $after.Mgmt.Id -and $_.Dhcp -eq 'Enabled' } | ForEach-Object Name)
        if ($dhcpSiblings) { $problems += "DHCP still on for $($dhcpSiblings -join ',')" }
        if ($gw.Count -ne 1 -or $gw[0] -ne $after.Mgmt.Name) { $problems += "default gateway on $($gw -join ',')" }
        if (@($afterPlan | Where-Object { $_.Want -and $_.Have -ne $_.Want })) { $problems += 'an adapter is not on its SBE driver' }
        if ($after.SbeHash -ne $zipHash -or @($sbeFiles.Name | Where-Object { @($after.SbeFiles) -notcontains $_ })) { $problems += 'C:\SBE is incomplete' }
        if (-not $after.Admin) { $problems += "$deployAdmin is missing" }
        if ($ntp -and -not @($ntp | Where-Object { ([string]$after.Time).Trim() -like "$_*" })) { $problems += "time source is $($after.Time), not $($ntp -join ' or ')" }
        if ($after.RebootPending) { Write-Warning "  $n still shows a restart pending after one restart; not restarting again." }
        if ($problems) { throw "$n check failed: $($problems -join '; ')" }
        $null = Wait-AzureReady $n 15
        Write-Step "  $n is ready for Validate"
        Send-PrepareEvent $n 'ReadyForValidate' 'SBE network drivers on every port, static management address, one default gateway, DNS and time, C:\SBE complete, deployment admin present; Azure reports Ready to cluster'
    }
    catch { Write-Warning "  $n`: $($_.Exception.Message)"; $failed += $n; Send-PrepareEvent $n 'PrepareFailed' $_.Exception.Message 'Error' 'Fix the cause and rerun with -From Prepare; finished steps are skipped.' }
    finally { if ($s) { Remove-PSSession $s } }
}
if (-not $Execute) { Write-Step 'Plan only. Add -Execute to wait at each gate and make the changes.' }
if ($failed) { throw "Not ready: $($failed -join ', ')" }
