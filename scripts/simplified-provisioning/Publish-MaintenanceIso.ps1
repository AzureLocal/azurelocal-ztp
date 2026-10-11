#Requires -Version 7.0
<#
.SYNOPSIS
Publishes the maintenance-environment ISO on a read-only SMB share the iDRACs mount as virtual media, or removes it.
.DESCRIPTION
Microsoft's documented route writes the maintenance ISO to a USB stick with usb_prep.exe. The no-USB route used here
mounts the same content as iDRAC virtual media, and Redfish InsertMedia can only read a network path. This script
stages the files for that (an ISO on the iDRAC CD slot failed in testing; use per-node .img files, see below):
  - copies the ISO into a dedicated folder and proves the copy has the source SHA-256;
  - creates or resets a dedicated local account with a new random password that lives only in this process and is
    returned as a PSCredential (never written to disk, a vault or a log; every publish rotates it);
  - shares the folder read-only to that account only (no Everyone, no write) with matching NTFS read rights;
  - opens TCP 445 inbound only from the listed BMC addresses.
The returned object carries the CIFS image path and credential that Mount-ZtpVirtualUsb.ps1 takes. -Remove takes the
share, firewall rule and account away again. Without -Execute only the plan is printed. Run elevated on the host whose
address the iDRACs reach.
Virtual USB (Mount-ZtpVirtualUsb.ps1): pass the per-node .img files and -ReadWrite. The maintenance environment writes the
ownership voucher back into the image, so the account gets change rights on the share and Modify on the folder (still
that one account only, still only from the listed BMC addresses). Files already in -SharePath are published in place
(no copy); their SHA-256 is still returned.
.PARAMETER IsoPath
The maintenance-environment ISO from the Microsoft download (Azure Local > Get started > Try provisioning > View Downloads),
or one or more raw USB images (.img) from New-ZtpVirtualUsbImage.ps1.
.PARAMETER ShareHost
Address of this host as seen from the iDRACs (management address over the VPN).
.PARAMETER AllowedBmcAddress
iDRAC addresses allowed to reach TCP 445 on this host.
.PARAMETER ShareName
SMB share name.
.PARAMETER SharePath
Local folder that backs the share.
.PARAMETER AccountName
Local account the iDRACs use to read the share.
.PARAMETER ReadWrite
Grant the share account change rights (share) and Modify (folder) so the iDRAC can mount a USB image read-write.
.PARAMETER Remove
Remove the share, firewall rule and account instead of publishing.
.PARAMETER Execute
Make the changes; without it only the plan is printed.
.EXAMPLE
./Publish-MaintenanceIso.ps1 -IsoPath D:\Media\roe\provision-os.iso -ShareHost 192.0.2.10 -AllowedBmcAddress 198.51.100.11,198.51.100.12 -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Publish')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Publish')][ValidateCount(1, 64)][string[]]$IsoPath,
    [Parameter(Mandatory, ParameterSetName = 'Publish')][ValidateNotNullOrEmpty()][string]$ShareHost,
    [Parameter(Mandatory, ParameterSetName = 'Publish')][ValidateCount(1, 64)][string[]]$AllowedBmcAddress,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,79}$')][string]$ShareName = 'ztp-maintenance-media',
    [string]$SharePath = (Join-Path $env:SystemDrive 'ZtpMaintenanceMedia'),
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,19}$')][string]$AccountName = 'svc-ztp-media',
    [Parameter(ParameterSetName = 'Publish')][switch]$ReadWrite,
    [Parameter(Mandatory, ParameterSetName = 'Remove')][switch]$Remove,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ruleName = "ZTP maintenance media SMB ($ShareName)"

function New-ZtpMediaPassword {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Generates a value in memory; changes no state.')]
    [CmdletBinding()]
    [OutputType([securestring])]
    param()
    # 32 characters from every class; the account policy needs complexity and the value never leaves this process.
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#%+-=?@^_')
    $all = -join $sets
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($set in $sets) { $chars.Add($set[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($set.Length)]) }
    while ($chars.Count -lt 32) { $chars.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)]) }
    $shuffled = $chars | Sort-Object { [System.Security.Cryptography.RandomNumberGenerator]::GetInt32([int]::MaxValue) }
    $secure = [securestring]::new()
    foreach ($c in $shuffled) { $secure.AppendChar($c) }
    $secure.MakeReadOnly()
    return $secure
}

if ($Remove) {
    if (-not $Execute) {
        "PLAN: remove share $ShareName, firewall rule '$ruleName' and local account $AccountName (folder $SharePath is kept)"
        return
    }
    if ($PSCmdlet.ShouldProcess($ShareName, 'Remove the maintenance media share, firewall rule and account')) {
        if (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue) { Remove-SmbShare -Name $ShareName -Force }
        Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        if (Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue) { Remove-LocalUser -Name $AccountName }
    }
    [pscustomobject]@{ ShareName = $ShareName; Removed = $true }
    return
}

$sources = @(foreach ($path in $IsoPath) { Get-Item -LiteralPath $path })
foreach ($source in $sources) {
    if ($source.Extension -notin '.iso', '.img') { throw "Not an ISO or raw USB image (.img): $($source.FullName)" }
}
if ($ReadWrite -and @($sources | Where-Object Extension -NE '.img').Count -gt 0) { throw '-ReadWrite is for raw USB images (.img) only; an ISO is always shared read-only.' }
if (@($sources.Name | Select-Object -Unique).Count -ne $sources.Count) { throw 'Two images have the same file name.' }
$fullSharePath = [IO.Path]::GetFullPath($SharePath).TrimEnd('\', '/')
$inPlace = { param($Item) [string]::Equals([IO.Path]::GetFullPath($Item.DirectoryName).TrimEnd('\', '/'), $fullSharePath, [StringComparison]::OrdinalIgnoreCase) }
$access = if ($ReadWrite) { 'read-write' } else { 'read-only' }
$imagePaths = @($sources | ForEach-Object { "//$ShareHost/$ShareName/$($_.Name)" })

if (-not $Execute) {
    foreach ($source in $sources) {
        if (& $inPlace $source) { "PLAN: publish $($source.FullName) in place and record its SHA-256" }
        else { "PLAN: copy $($source.FullName) to $SharePath and verify SHA-256" }
    }
    "PLAN: create or reset local account $AccountName with a new in-memory password"
    "PLAN: share $SharePath as $ShareName, $access for $AccountName only"
    "PLAN: allow TCP 445 inbound from $($AllowedBmcAddress -join ', ')"
    foreach ($imagePath in $imagePaths) { "PLAN: iDRAC image path $imagePath" }
    return
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run elevated: creating a share, a local account and a firewall rule needs administrator rights.'
}
if (-not $PSCmdlet.ShouldProcess($ShareName, "Publish $(($sources.Name) -join ', ') $access to $($AllowedBmcAddress -join ', ')")) { return }

$null = New-Item -ItemType Directory -Force -Path $SharePath
$hashes = foreach ($source in $sources) {
    $target = Join-Path $SharePath $source.Name
    $sourceHash = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
    if (-not (& $inPlace $source)) {
        if (-not (Test-Path -LiteralPath $target) -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $sourceHash) {
            Copy-Item -LiteralPath $source.FullName -Destination $target -Force
        }
        $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($targetHash -ne $sourceHash) { throw "The staged image hash $targetHash does not match the source $sourceHash." }
    }
    [pscustomobject]@{ ImagePath = "//$ShareHost/$ShareName/$($source.Name)"; Sha256 = $sourceHash }
}
$hashes = @($hashes)

$password = New-ZtpMediaPassword
$account = Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
if ($account) {
    Set-LocalUser -Name $AccountName -Password $password -PasswordNeverExpires $true
    Enable-LocalUser -Name $AccountName
}
else {
    $null = New-LocalUser -Name $AccountName -Password $password -PasswordNeverExpires -UserMayNotChangePassword -Description 'iDRAC read-only ZTP maintenance ISO'
}
$principal = "$env:COMPUTERNAME\$AccountName"

$acl = Get-Acl -LiteralPath $SharePath
$rights = if ($ReadWrite) { 'Modify' } else { 'ReadAndExecute' }
$rule = [System.Security.AccessControl.FileSystemAccessRule]::new($principal, $rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.SetAccessRule($rule)
Set-Acl -LiteralPath $SharePath -AclObject $acl

$share = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
if ($share -and $share.Path -ne $SharePath) { throw "Share $ShareName already exists for another folder: $($share.Path)" }
if (-not $share) {
    if ($ReadWrite) { $null = New-SmbShare -Name $ShareName -Path $SharePath -ChangeAccess $principal -Description 'ZTP virtual USB images (read-write) for iDRAC virtual media' }
    else { $null = New-SmbShare -Name $ShareName -Path $SharePath -ReadAccess $principal -Description 'ZTP maintenance ISO for iDRAC virtual media' }
}
else {
    $null = Grant-SmbShareAccess -Name $ShareName -AccountName $principal -AccessRight ($ReadWrite ? 'Change' : 'Read') -Force
}
# Only the one account: drop every other share grant (for example Everyone).
foreach ($entry in @(Get-SmbShareAccess -Name $ShareName | Where-Object { $_.AccountName -ne $principal })) {
    $null = Revoke-SmbShareAccess -Name $ShareName -AccountName $entry.AccountName -Force
}

Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
$null = New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -RemoteAddress $AllowedBmcAddress -Profile Any

[pscustomobject]@{
    ShareName   = $ShareName
    ImagePath   = $hashes[0].ImagePath
    Sha256      = $hashes[0].Sha256
    Images      = $hashes
    Access      = $access
    Credential  = [pscredential]::new($principal, $password)
    AllowedBmcs = $AllowedBmcAddress
}
