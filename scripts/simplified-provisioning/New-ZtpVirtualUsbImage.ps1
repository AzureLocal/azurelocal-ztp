#Requires -Version 7.0
<#
.SYNOPSIS
Builds the Azure Local maintenance-environment "USB drive" as a raw disk image (.img) for iDRAC virtual media, one per node.
.DESCRIPTION
Microsoft's usb_prep.exe writes a USB stick as GPT with ONE FAT32 partition labelled CDROM (grub: search --label CDROM;
kernel: root=live:LABEL=CDROM) and copies the maintenance ISO's contents onto it. This script writes the same layout
into a file in pure PowerShell (no usb_prep.exe, no diskpart, no VHD), so the iDRAC can present it on its USB-stick
(RemovableDisk) slot. An ISO on the iDRAC CD slot failed in testing (sr0 medium errors); the USB-stick image boots.

One image per node: the maintenance environment writes the ownership voucher back into the media it booted from
(\vouchers\<serial>\*.pem), so each node needs its own file. With -NodeName the images are named
<ImageNamePrefix><node name>.img; the first is built and the others are byte copies.

With -EdgeUserPassword (a SecureString) the SHA-512 crypt hash is written to
prov_config\download\hash_password.txt (ASCII, no BOM, no newline). The installer copies prov_config/download to
/var/staging/roesetup/download/ and /usr/sbin/init_roe_custom.sh sets it as edgeuser's password; without it edgeuser
stays locked. The password itself is never written.

Without -Execute only the plan is printed. An ISO source is mounted read-only with Mount-DiskImage (run elevated), or
pass a folder that already holds the ISO's contents.
.PARAMETER SourcePath
The maintenance-environment ISO (provision-os.iso from the Microsoft download) or a folder with its extracted contents.
.PARAMETER OutputPath
The .img file to write (single image).
.PARAMETER NodeName
Node names to build one image each for (for example node-01, node-02).
.PARAMETER OutputDirectory
Folder for the per-node images (for example the folder Publish-MaintenanceIso.ps1 -ReadWrite shares).
.PARAMETER ImageNamePrefix
File-name prefix of the per-node images.
.PARAMETER EdgeUserPassword
Password for the maintenance environment's edgeuser account (console and SSH access for troubleshooting).
.PARAMETER SizeBytes
Image size (whole MiB). The maintenance ISO needs about 1 GiB; 4 GiB is the size that booted on Dell 16G servers.
.PARAMETER ClusterSize
FAT32 allocation unit in bytes.
.PARAMETER VolumeLabel
FAT32 volume label; the maintenance boot looks for CDROM.
.PARAMETER Force
Replace existing image files.
.PARAMETER Execute
Build the images; without it only the plan is printed.
.OUTPUTS
PSCustomObject { Node, ImagePath, SizeBytes, Sha256, EdgeUserPasswordSet }
.EXAMPLE
./New-ZtpVirtualUsbImage.ps1 -SourcePath D:\Media\roe\provision-os.iso -NodeName node-01,node-02 -OutputDirectory D:\ZtpVirtualUsb -EdgeUserPassword (Read-Host -AsSecureString 'edgeuser password') -Execute
.EXAMPLE
./New-ZtpVirtualUsbImage.ps1 -SourcePath D:\Media\roe\extracted -OutputPath D:\ZtpVirtualUsb\ztp-usb.img -Execute
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Single')]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory, ParameterSetName = 'Single')][string]$OutputPath,
    [Parameter(Mandatory, ParameterSetName = 'PerNode')][ValidateCount(1, 64)][string[]]$NodeName,
    [Parameter(Mandatory, ParameterSetName = 'PerNode')][string]$OutputDirectory,
    [Parameter(ParameterSetName = 'PerNode')][ValidatePattern('^[A-Za-z0-9._-]{0,40}$')][string]$ImageNamePrefix = 'ztp-usb-',
    [securestring]$EdgeUserPassword,
    [ValidateRange(32MB, 128GB)][long]$SizeBytes = 4GB,
    [ValidateSet(512, 1024, 2048, 4096, 8192, 16384, 32768)][int]$ClusterSize = 4096,
    [ValidatePattern('^[A-Z0-9_-]{1,11}$')][string]$VolumeLabel = 'CDROM',
    [switch]$Force,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpVirtualUsb.Common.ps1')

if ($SizeBytes % 1MB -ne 0) { throw '-SizeBytes must be a whole number of MiB.' }
$null = Get-ZtpFat32Geometry -SizeBytes $SizeBytes -ClusterSize $ClusterSize

$source = Get-Item -LiteralPath $SourcePath
if (-not $source.PSIsContainer -and $source.Extension -ne '.iso') { throw "The source must be the maintenance ISO or a folder with its contents: $SourcePath" }

$targets = if ($PSCmdlet.ParameterSetName -eq 'PerNode') {
    foreach ($name in ($NodeName | Select-Object -Unique)) {
        [pscustomobject]@{ Node = $name; Path = (Join-Path $OutputDirectory (Get-ZtpNodeImageName -NodeName $name -Prefix $ImageNamePrefix)) }
    }
}
else {
    if ([IO.Path]::GetExtension($OutputPath) -ne '.img') { throw "The output must be a raw image with the .img extension: $OutputPath" }
    [pscustomobject]@{ Node = $null; Path = $OutputPath }
}
$targets = @($targets)
$existing = @($targets | Where-Object { Test-Path -LiteralPath $_.Path })
if ($existing.Count -gt 0 -and -not $Force) { throw "Refusing to overwrite (use -Force): $(($existing.Path) -join ', ')" }
$hasPassword = [bool]$EdgeUserPassword

if (-not $Execute) {
    "PLAN: source $($source.FullName) ($(if ($source.PSIsContainer) { 'folder' } else { 'ISO, mounted read-only' }))"
    "PLAN: GPT, one FAT32 partition labelled $VolumeLabel, $([math]::Round($SizeBytes / 1MB)) MiB, $ClusterSize-byte clusters; source contents copied to the root"
    if ($hasPassword) { 'PLAN: prov_config\download\hash_password.txt with the SHA-512 crypt hash of the edgeuser password' }
    else { 'PLAN: no hash_password.txt (edgeuser stays locked)' }
    foreach ($target in $targets) { "PLAN: write $($target.Path)$(if ($target.Node) { " for $($target.Node)" })" }
    return
}
if (-not $PSCmdlet.ShouldProcess(($targets.Path -join ', '), 'Build the maintenance virtual-USB image')) { return }

$extra = @{}
if ($hasPassword) {
    $hash = ConvertTo-ZtpSha512CryptHash -Password $EdgeUserPassword
    if (-not (Test-ZtpPasswordHashFormat -Hash $hash)) { throw 'The edgeuser hash does not have the $6$<salt>$<86 chars> form the maintenance environment accepts.' }
    $extra['prov_config/download/hash_password.txt'] = [System.Text.Encoding]::ASCII.GetBytes($hash)
    $hash = $null
}

$mountedIso = $null
try {
    $root = $source.FullName
    if (-not $source.PSIsContainer) {
        $volume = Mount-DiskImage -ImagePath $source.FullName -Access ReadOnly -StorageType ISO -PassThru | Get-Volume
        $mountedIso = $source.FullName
        if (-not $volume.DriveLetter) { throw "The ISO mounted without a drive letter: $($source.FullName)" }
        $root = "$($volume.DriveLetter):\"
    }
    foreach ($target in $targets) {
        $parent = Split-Path -Parent ([IO.Path]::GetFullPath($target.Path))
        if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
    }
    $first = $targets[0]
    $built = Build-ZtpFat32Image -SourcePath $root -OutputPath $first.Path -SizeBytes $SizeBytes -ClusterSize $ClusterSize -VolumeLabel $VolumeLabel -ExtraFiles $extra -Force:$Force
    Write-Verbose "Built $($built.Path): $($built.Files) files, $($built.Directories) folders, $($built.UsedClusters) of $($built.ClusterCount) clusters"
}
finally {
    if ($mountedIso) { $null = Dismount-DiskImage -ImagePath $mountedIso }
    $extra.Clear()
}

$firstHash = (Get-FileHash -LiteralPath $first.Path -Algorithm SHA256).Hash
foreach ($target in $targets) {
    if ($target -ne $first) {
        Copy-Item -LiteralPath $first.Path -Destination $target.Path -Force
        $copyHash = (Get-FileHash -LiteralPath $target.Path -Algorithm SHA256).Hash
        if ($copyHash -ne $firstHash) { throw "The copy $($target.Path) does not match the built image." }
    }
    [pscustomobject]@{
        Node                = $target.Node
        ImagePath           = (Resolve-Path -LiteralPath $target.Path).ProviderPath
        SizeBytes           = $SizeBytes
        Sha256              = $firstHash
        EdgeUserPasswordSet = $hasPassword
    }
}
