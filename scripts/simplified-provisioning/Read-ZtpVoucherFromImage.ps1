#Requires -Version 7.0
<#
.SYNOPSIS
Reads the ownership vouchers the maintenance environment wrote back into the per-node virtual-USB images.
.DESCRIPTION
The maintenance environment's setup service (ROESetup) stages its export under /var/staging/export/vouchers/<serial>
(vouchers/<guid> when the serial is unavailable) and, when exactly one writable USB drive is attached, copies that tree
to the root of the drive's first writable partition (mount -o rw,sync, then sync and umount). The voucher therefore
lands at \vouchers\<serial>\*.pem in the image, next to response.json and systeminfo.

This script opens each image READ-ONLY (pure PowerShell: GPT -> partition -> FAT32 boot sector -> FAT -> directory walk
with long file names), lists every *.pem it holds, maps each voucher to a node by its folder name (or, for a
vouchers\<guid> folder, by the serial inside the voucher), and validates it: one OWNERSHIP VOUCHER PEM block, base64
that decodes to a CBOR array of five items (FDO OwnershipVoucher), and the node's service tag present in the voucher.
When a folder holds several *.pem the newest is used (as the Configurator App does).

With -OutputDirectory each valid voucher is written as <serial>.pem (never over a different file unless -Force), the layout Invoke-ZtpAzureProvisioning.ps1 reads. The image is never modified; by default the open
fails while another process (the iDRAC's share session) holds the image, so eject the virtual media first
(Mount-ZtpVirtualUsb.ps1 -Action Eject). Voucher contents are never printed.
.PARAMETER ImagePath
Image files to read.
.PARAMETER NodeName
Node names whose per-node images (<ImageNamePrefix><node>.img in -ImageDirectory) are read.
.PARAMETER ImageDirectory
Folder that holds the per-node images (the share folder).
.PARAMETER ImageNamePrefix
File-name prefix of the per-node images.
.PARAMETER Nodes
Node objects { name, service_tag } (the serial number / service tag maps a voucher to its node).
.PARAMETER NodesFile
JSON (or YAML) node list instead of -Nodes, see config/simplified-provisioning/nodes.example.json.
.PARAMETER OutputDirectory
Folder to write <serial>.pem into; without it the vouchers are only listed and validated.
.PARAMETER AllowOpenImage
Read even while another process holds the image open (a probe; the content may be mid-write).
.PARAMETER ReportOnly
Return every row (including problems) instead of throwing when an expected voucher is missing or invalid.
.PARAMETER Force
Replace an existing <serial>.pem that differs.
.OUTPUTS
PSCustomObject { Node, Serial, ImagePath, SourcePath, LastWriteTime, Sha256, OutputFile, Valid, Problem }
.EXAMPLE
./Read-ZtpVoucherFromImage.ps1 -NodeName node-01,node-02 -NodesFile ./nodes.json -ImageDirectory D:\ZtpVirtualUsb -OutputDirectory D:\ZtpVouchers
.EXAMPLE
./Read-ZtpVoucherFromImage.ps1 -ImagePath D:\ZtpVirtualUsb\ztp-usb-node-01.img -NodesFile ./nodes.json -ReportOnly
#>
[CmdletBinding(DefaultParameterSetName = 'Path')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Path')][string[]]$ImagePath,
    [Parameter(Mandatory, ParameterSetName = 'Node')][string[]]$NodeName,
    [Parameter(Mandatory, ParameterSetName = 'Node')][string]$ImageDirectory,
    [ValidatePattern('^[A-Za-z0-9._-]{0,40}$')][string]$ImageNamePrefix = 'ztp-usb-',
    [object[]]$Nodes,
    [string]$NodesFile,
    [string]$OutputDirectory,
    [switch]$AllowOpenImage,
    [switch]$ReportOnly,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpVirtualUsb.Common.ps1')

$nodeArgs = @{ RequireSerial = $true }
if ($Nodes) { $nodeArgs.Nodes = $Nodes }
if ($NodesFile) { $nodeArgs.NodesFile = $NodesFile }

# Every node is a mapping candidate (an image can hold another node's voucher); -NodeName selects the expected images.
$known = @(Get-ZtpNodeList @nodeArgs)
if ($PSCmdlet.ParameterSetName -eq 'Node') { $null = Get-ZtpNodeList @nodeArgs -NodeName $NodeName }

# Image -> the node it was built for (from the per-node file name), or $null when the name does not say.
$images = if ($PSCmdlet.ParameterSetName -eq 'Node') {
    foreach ($node in @($known | Where-Object Name -In $NodeName)) { [pscustomobject]@{ Path = (Join-Path $ImageDirectory (Get-ZtpNodeImageName -NodeName $node.Name -Prefix $ImageNamePrefix)); Expected = $node } }
}
else {
    foreach ($path in $ImagePath) {
        $leaf = Split-Path -Leaf $path
        $match = @($known | Where-Object { $leaf -ieq (Get-ZtpNodeImageName -NodeName $_.Name -Prefix $ImageNamePrefix) }) | Select-Object -First 1
        [pscustomobject]@{ Path = $path; Expected = $match }
    }
}
$images = @($images)

$rows = [System.Collections.Generic.List[object]]::new()
$chosen = [System.Collections.Generic.List[object]]::new()
foreach ($image in $images) {
    $row = { param($Node, $Serial, $Source, $Time, $Sha, $Valid, $Problem)
        [pscustomobject]@{ Node = $Node; Serial = $Serial; ImagePath = $image.Path; SourcePath = $Source; LastWriteTime = $Time; Sha256 = $Sha; OutputFile = $null; Valid = $Valid; Problem = $Problem }
    }
    if (-not (Test-Path -LiteralPath $image.Path)) {
        $rows.Add((& $row $image.Expected.Name $image.Expected.Serial $null $null $null $false 'image not found'))
        continue
    }
    try {
        $found = Find-ZtpVoucherInImage -ImagePath $image.Path -AllowOpen:$AllowOpenImage
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException -and $inner -isnot [System.IO.IOException]) { $inner = $inner.InnerException }
        $reason = if ($inner -is [System.IO.IOException] -and $inner -isnot [System.IO.FileNotFoundException]) {
            "the image is open in another process (eject the virtual media first): $($inner.Message)"
        }
        else { "the image cannot be read: $($_.Exception.Message)" }
        $rows.Add((& $row ($image.Expected ? $image.Expected.Name : $null) ($image.Expected ? $image.Expected.Serial : $null) $null $null $null $false $reason))
        continue
    }
    if ($found.Label -ne 'CDROM') { Write-Warning "$($image.Path): volume label is '$($found.Label)', not CDROM." }

    $candidates = foreach ($pem in $found.Pem) {
        if (-not $pem.UnderVouchers) {
            $rows.Add((& $row $null $pem.Folder $pem.Path $pem.LastWriteTime $null $false 'a .pem outside \vouchers\<serial>\ (not written by the maintenance environment; ignored)'))
            continue
        }
        $node = @($known | Where-Object { $_.Serial -ieq $pem.Folder }) | Select-Object -First 1
        if (-not $node -and $null -ne $pem.Bytes) {
            # vouchers\<guid>: the maintenance environment could not read the serial; match by the serial inside the voucher.
            $byContent = @($known | Where-Object { (Test-ZtpOwnershipVoucher -Bytes $pem.Bytes -Serial $_.Serial).SerialInVoucher })
            if ($byContent.Count -eq 1) { $node = $byContent[0] }
        }
        if (-not $node) {
            $rows.Add((& $row $null $pem.Folder $pem.Path $pem.LastWriteTime $null $false "voucher folder '$($pem.Folder)' matches no node's service_tag"))
            continue
        }
        [pscustomobject]@{ Node = $node; Pem = $pem }
    }
    foreach ($group in @(@($candidates) | Group-Object { $_.Node.Name })) {
        $pick = @($group.Group | Sort-Object { $_.Pem.LastWriteTime } -Descending)[0]
        $node = $pick.Node
        $pem = $pick.Pem
        $problems = [System.Collections.Generic.List[string]]::new()
        if ($group.Count -gt 1) { Write-Verbose "$($image.Path): $($group.Count) vouchers for $($node.Name); using the newest $($pem.Path)" }
        $check = $null
        if ($null -eq $pem.Bytes) { $problems.Add('the .pem is larger than 1 MiB') }
        else {
            $check = Test-ZtpOwnershipVoucher -Bytes $pem.Bytes -Serial $node.Serial
            foreach ($p in $check.Problems) { $problems.Add($p) }
        }
        if ($pem.Folder -ine $node.Serial) { Write-Warning "$($image.Path): voucher of $($node.Name) is in vouchers\$($pem.Folder) (serial unavailable to the maintenance environment)." }
        if ($image.Expected -and $image.Expected.Name -ne $node.Name) {
            $problems.Add("the image built for $($image.Expected.Name) holds the voucher of $($node.Name) ($($node.Serial)): check which node mounted which image")
        }
        $entry = [pscustomobject]@{
            Node = $node.Name; Serial = $node.Serial; ImagePath = $image.Path; SourcePath = $pem.Path; LastWriteTime = $pem.LastWriteTime
            Sha256 = ($check ? $check.Sha256 : $null); OutputFile = $null; Valid = ($problems.Count -eq 0); Problem = ($problems -join '; ')
        }
        $rows.Add($entry)
        if ($entry.Valid) { $chosen.Add([pscustomobject]@{ Row = $entry; Bytes = $pem.Bytes }) }
    }
}

# Every node that is expected (per-node images) must end with exactly one valid voucher.
$problemsAll = [System.Collections.Generic.List[string]]::new()
$expectedNodes = @($images | Where-Object { $_.Expected } | ForEach-Object { $_.Expected.Name } | Select-Object -Unique)
foreach ($name in $expectedNodes) {
    $valid = @($chosen | Where-Object { $_.Row.Node -eq $name })
    if ($valid.Count -eq 0) {
        $reason = @($rows | Where-Object { $_.Node -eq $name -and -not $_.Valid } | ForEach-Object Problem)
        $problemsAll.Add("$($name): no valid voucher$(if ($reason) { " ($($reason -join '; '))" } else { ' (no \vouchers\<serial>\*.pem in the image yet)' })")
    }
}
foreach ($dup in @($chosen | Group-Object { $_.Row.Node } | Where-Object Count -GT 1)) {
    $problemsAll.Add("$($dup.Name): valid vouchers in more than one image ($(@($dup.Group.Row.ImagePath) -join ', '))")
}
foreach ($bad in @($rows | Where-Object { -not $_.Valid -and $_.Node -and $_.Node -notin $expectedNodes })) {
    $problemsAll.Add("$($bad.Node): $($bad.Problem)")
}
if ($expectedNodes.Count -eq 0 -and $chosen.Count -eq 0) { $problemsAll.Add('no valid voucher in any image') }
if ($problemsAll.Count -gt 0 -and -not $ReportOnly) { throw ($problemsAll -join [Environment]::NewLine) }

if ($OutputDirectory) {
    if (-not (Test-Path -LiteralPath $OutputDirectory)) { $null = New-Item -ItemType Directory -Path $OutputDirectory }
    foreach ($item in $chosen) {
        $target = Join-Path $OutputDirectory "$($item.Row.Serial).pem"
        if ((Test-Path -LiteralPath $target) -and -not $Force -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $item.Row.Sha256) {
            throw "$target already exists with different content; use -Force to replace it. Nothing was written."
        }
    }
    foreach ($item in $chosen) {
        $target = Join-Path $OutputDirectory "$($item.Row.Serial).pem"
        [System.IO.File]::WriteAllBytes($target, $item.Bytes)
        $item.Row.OutputFile = (Resolve-Path -LiteralPath $target).ProviderPath
    }
}
$rows.ToArray()
