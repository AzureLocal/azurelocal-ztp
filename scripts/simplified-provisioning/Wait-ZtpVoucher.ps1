#Requires -Version 7.0
<#
.SYNOPSIS
Waits until the maintenance environment has written each node's ownership voucher into its virtual-USB image, then
ejects the media and extracts the vouchers as <serial>.pem; or takes vouchers obtained manually with the Configurator App.
.DESCRIPTION
Image mode: polls the share-side image of every node (<ImageDirectory>\<ImageNamePrefix><node>.img) read-only, shared
with the iDRAC's open handle, until \vouchers\<service tag>\*.pem holds a complete, valid ownership voucher, or until
-TimeoutMinutes. For each node that is ready it ejects the virtual media (Mount-ZtpVirtualUsb.ps1 -Action Eject, with
-Execute) so the iDRAC closes the file, then reads the image exclusively with Read-ZtpVoucherFromImage.ps1 and writes
<OutputDirectory>\<serial>.pem. Without -Execute nothing is ejected (the plan line is printed) and the final read shares
the image with the iDRAC.

Folder mode (-VoucherFolder): the fallback when read-back fails. Accepts the vouchers downloaded with the Configurator
App (<serial>.pem or <serial>\*.pem per node), validates them the same way and copies them to <OutputDirectory>\<serial>.pem,
so the chain continues with the same files.
.PARAMETER NodeName
Node names.
.PARAMETER ImageDirectory
Local folder that holds the per-node images (the folder behind the read-write share).
.PARAMETER VoucherFolder
Folder with vouchers obtained manually (fallback; no polling).
.PARAMETER OutputDirectory
Where <serial>.pem is written.
.PARAMETER ImageNamePrefix
File-name prefix of the per-node images.
.PARAMETER TimeoutMinutes
Upper bound for the wait (0 = one poll). The maintenance environment installs itself in about 20 to 30 minutes.
.PARAMETER PollSeconds
Interval between polls.
.PARAMETER Nodes
Node objects { name, service_tag, bmc_address }.
.PARAMETER NodesFile
JSON (or YAML) node list instead of -Nodes, see config/simplified-provisioning/nodes.example.json.
.PARAMETER Credential
BMC account, passed to Mount-ZtpVirtualUsb.ps1 for the eject (required with -Execute in image mode).
.PARAMETER SkipCertificateCheck
Passed to Mount-ZtpVirtualUsb.ps1 for the eject.
.PARAMETER Force
Replace an existing, different <serial>.pem.
.PARAMETER Execute
Eject the virtual media of each ready node before the final read; without it only the plan line is printed.
.OUTPUTS
PSCustomObject rows from Read-ZtpVoucherFromImage.ps1, or { Node, Serial, Source, OutputFile, Sha256, Valid, Problem } in folder mode.
.EXAMPLE
./Wait-ZtpVoucher.ps1 -NodeName node-01,node-02 -ImageDirectory D:\ZtpVirtualUsb -NodesFile ./nodes.json -Credential $bmcCredential -OutputDirectory D:\ZtpVouchers -SkipCertificateCheck -Execute
.EXAMPLE
./Wait-ZtpVoucher.ps1 -NodeName node-01,node-02 -VoucherFolder D:\Downloads\vouchers -OutputDirectory D:\ZtpVouchers
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Image')]
param(
    [Parameter(Mandatory)][ValidateCount(1, 64)][string[]]$NodeName,
    [Parameter(Mandatory, ParameterSetName = 'Image')][string]$ImageDirectory,
    [Parameter(Mandatory, ParameterSetName = 'Folder')][string]$VoucherFolder,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(ParameterSetName = 'Image')][ValidatePattern('^[A-Za-z0-9._-]{0,40}$')][string]$ImageNamePrefix = 'ztp-usb-',
    [Parameter(ParameterSetName = 'Image')][ValidateRange(0, 1440)][int]$TimeoutMinutes = 120,
    [Parameter(ParameterSetName = 'Image')][ValidateRange(5, 3600)][int]$PollSeconds = 60,
    [object[]]$Nodes,
    [string]$NodesFile,
    [pscredential]$Credential,
    [Parameter(ParameterSetName = 'Image')][switch]$SkipCertificateCheck,
    [switch]$Force,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpVirtualUsb.Common.ps1')

$nodeArgs = @{ NodeName = $NodeName; RequireSerial = $true }
if ($Nodes) { $nodeArgs.Nodes = $Nodes }
if ($NodesFile) { $nodeArgs.NodesFile = $NodesFile }
$known = @(Get-ZtpNodeList @nodeArgs)

if ($PSCmdlet.ParameterSetName -eq 'Folder') {
    $files = @(Get-ChildItem -LiteralPath $VoucherFolder -Filter '*.pem' -File -Recurse)
    $rows = foreach ($node in $known) {
        $candidates = @($files | Where-Object { $_.BaseName -ieq $node.Serial -or $_.Directory.Name -ieq $node.Serial })
        $problem = $null
        $check = $null
        if ($candidates.Count -ne 1) { $problem = "expected exactly one voucher for $($node.Serial) in $VoucherFolder; found $($candidates.Count)" }
        elseif ($candidates[0].Length -gt 1MB) { $problem = 'the .pem is larger than 1 MiB' }
        else {
            $check = Test-ZtpOwnershipVoucher -Bytes ([System.IO.File]::ReadAllBytes($candidates[0].FullName)) -Serial $node.Serial
            if (-not $check.Valid) { $problem = $check.Problems -join '; ' }
        }
        [pscustomobject]@{
            Node = $node.Name; Serial = $node.Serial; Source = ($candidates.Count -eq 1 ? $candidates[0].FullName : $null)
            OutputFile = $null; Sha256 = ($check ? $check.Sha256 : $null); Valid = ($null -eq $problem); Problem = $problem
        }
    }
    $rows = @($rows)
    $bad = @($rows | Where-Object { -not $_.Valid })
    if ($bad.Count -gt 0) { throw (($bad | ForEach-Object { "$($_.Node): $($_.Problem)" }) -join [Environment]::NewLine) }
    if (-not (Test-Path -LiteralPath $OutputDirectory)) { $null = New-Item -ItemType Directory -Path $OutputDirectory }
    foreach ($row in $rows) {
        $target = Join-Path $OutputDirectory "$($row.Serial).pem"
        if ((Test-Path -LiteralPath $target) -and -not $Force -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $row.Sha256) {
            throw "$target already exists with different content; use -Force to replace it. Nothing was written."
        }
    }
    foreach ($row in $rows) {
        $target = Join-Path $OutputDirectory "$($row.Serial).pem"
        if ([IO.Path]::GetFullPath($row.Source) -ne [IO.Path]::GetFullPath($target)) { Copy-Item -LiteralPath $row.Source -Destination $target -Force }
        $row.OutputFile = (Resolve-Path -LiteralPath $target).ProviderPath
    }
    return $rows
}

# Image mode: poll each node's image until a complete, valid voucher is in \vouchers\<serial>\.
if ($Execute -and -not $Credential) { throw '-Credential (the BMC account) is required with -Execute to eject the virtual media.' }

$readScript = Join-Path $PSScriptRoot 'Read-ZtpVoucherFromImage.ps1'
$mountScript = Join-Path $PSScriptRoot 'Mount-ZtpVirtualUsb.ps1'
$deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
$pending = [System.Collections.Generic.List[object]]::new()
foreach ($node in $known) { $pending.Add($node) }
$status = @{}
$results = [System.Collections.Generic.List[object]]::new()
while ($true) {
    foreach ($node in @($pending)) {
        $image = Join-Path $ImageDirectory (Get-ZtpNodeImageName -NodeName $node.Name -Prefix $ImageNamePrefix)
        if (-not (Test-Path -LiteralPath $image)) { $status[$node.Name] = "image not found: $image"; continue }
        try {
            $probe = Find-ZtpVoucherInImage -ImagePath $image -AllowOpen
        }
        catch {
            $status[$node.Name] = "image not readable yet: $($_.Exception.Message)"
            continue
        }
        $ready = @($probe.Pem | Where-Object { $_.UnderVouchers -and $_.Folder -ieq $node.Serial -and $null -ne $_.Bytes -and (Test-ZtpOwnershipVoucher -Bytes $_.Bytes -Serial $node.Serial).Valid })
        if ($ready.Count -eq 0) {
            $status[$node.Name] = if (@($probe.VoucherFolders).Count -gt 0) { "voucher folder(s) $(@($probe.VoucherFolders) -join ', ') without a complete voucher yet" } else { 'no \vouchers\ folder yet' }
            continue
        }
        Write-Verbose "$($node.Name): voucher $($ready[0].Path) is complete."
        if ($Execute) {
            if ($PSCmdlet.ShouldProcess($node.Name, 'Eject the virtual USB before reading the voucher')) {
                $ejectArgs = @{ NodeName = $node.Name; Action = 'Eject'; ImageNamePrefix = $ImageNamePrefix; Credential = $Credential; Execute = $true; Confirm = $false }
                if ($NodesFile) { $ejectArgs.NodesFile = $NodesFile } else { $ejectArgs.Nodes = @($known | ForEach-Object { [pscustomobject]@{ name = $_.Name; service_tag = $_.Serial; bmc_address = $_.BmcAddress } }) }
                if ($SkipCertificateCheck) { $ejectArgs.SkipCertificateCheck = $true }
                $null = & $mountScript @ejectArgs
            }
        }
        else {
            "PLAN: eject the virtual USB of $($node.Name) (Mount-ZtpVirtualUsb.ps1 -Action Eject -Execute) before the final read"
        }
        $readArgs = @{ ImagePath = $image; Nodes = @([pscustomobject]@{ name = $node.Name; service_tag = $node.Serial }); ImageNamePrefix = $ImageNamePrefix; OutputDirectory = $OutputDirectory; AllowOpenImage = (-not $Execute) }
        if ($Force) { $readArgs.Force = $true }
        foreach ($row in @(& $readScript @readArgs)) { $results.Add($row) }
        [void]$pending.Remove($node)
    }
    if ($pending.Count -eq 0) { break }
    if ([DateTime]::UtcNow -ge $deadline) {
        $detail = ($pending | ForEach-Object { "$($_.Name) ($($_.Serial)): $($status[$_.Name])" }) -join [Environment]::NewLine
        throw "No voucher within $TimeoutMinutes minute(s) for:$([Environment]::NewLine)$detail$([Environment]::NewLine)Fallback: download the vouchers with the Configurator App and rerun with -VoucherFolder."
    }
    Write-Verbose "Waiting $PollSeconds s for $(@($pending.Name) -join ', ')"
    Start-Sleep -Seconds $PollSeconds
}
$results.ToArray()
