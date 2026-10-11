# Shared helpers for the ZTP virtual-USB scripts (dot-sourced): New-ZtpVirtualUsbImage.ps1, Read-ZtpVoucherFromImage.ps1,
# Mount-ZtpVirtualUsb.ps1 and Wait-ZtpVoucher.ps1. Pure PowerShell, no external tools:
#   - SHA-512 crypt ($6$) for the maintenance environment's edgeuser password file;
#   - a FAT32-on-GPT image writer (the usb_prep.exe layout: GPT, ONE FAT32 partition labelled CDROM, ISO contents copied);
#   - a read-only FAT32-on-GPT reader (GPT -> partition -> BPB -> FAT -> directory walk with long file names);
#   - ownership-voucher discovery and validation.
# No function here logs or returns a secret value or a voucher's contents.
#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-ZtpSha512CryptHash {
    <#
    .SYNOPSIS
        SHA-512 crypt ($6$) of a SecureString, per Ulrich Drepper's specification (akkadia.org/drepper/SHA-crypt.txt).
    .DESCRIPTION
        The default 5000 rounds produce '$6$<salt>$<86 chars>' without a 'rounds=' field: the form the maintenance
        environment's /usr/sbin/init_roe_custom.sh copies into /etc/shadow for edgeuser. The plain text lives only for
        the duration of the call and the byte copy is cleared.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][securestring]$Password,
        [ValidatePattern('^[./0-9A-Za-z]{1,16}$')][string]$Salt,
        [ValidateRange(1000, 999999999)][int]$Rounds = 5000
    )
    $alphabet = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    if (-not $Salt) {
        $random = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(16)
        $Salt = -join ($random | ForEach-Object { $alphabet[$_ % 64] })
    }
    [byte[]]$p = [System.Text.Encoding]::UTF8.GetBytes([System.Net.NetworkCredential]::new('', $Password).Password)
    try {
        [byte[]]$s = [System.Text.Encoding]::ASCII.GetBytes($Salt)
        [byte[]]$bDigest = [System.Security.Cryptography.SHA512]::HashData([byte[]]($p + $s + $p))
        $a = [System.Collections.Generic.List[byte]]::new()
        $a.AddRange($p); $a.AddRange($s)
        for ($n = $p.Length; $n -gt 64; $n -= 64) { $a.AddRange($bDigest) }
        if ($n -gt 0) { $a.AddRange([byte[]]$bDigest[0..($n - 1)]) }
        for ($n = $p.Length; $n -gt 0; $n = $n -shr 1) {
            if ($n -band 1) { $a.AddRange($bDigest) } else { $a.AddRange($p) }
        }
        [byte[]]$aDigest = [System.Security.Cryptography.SHA512]::HashData($a.ToArray())

        $dp = [System.Collections.Generic.List[byte]]::new()
        for ($i = 0; $i -lt $p.Length; $i++) { $dp.AddRange($p) }
        [byte[]]$dpDigest = [System.Security.Cryptography.SHA512]::HashData($dp.ToArray())
        $pSeq = [byte[]]::new($p.Length)
        for ($i = 0; $i -lt $p.Length; $i++) { $pSeq[$i] = $dpDigest[$i % 64] }

        $ds = [System.Collections.Generic.List[byte]]::new()
        for ($i = 0; $i -lt (16 + $aDigest[0]); $i++) { $ds.AddRange($s) }
        [byte[]]$dsDigest = [System.Security.Cryptography.SHA512]::HashData($ds.ToArray())
        $sSeq = [byte[]]::new($s.Length)
        for ($i = 0; $i -lt $s.Length; $i++) { $sSeq[$i] = $dsDigest[$i % 64] }

        [byte[]]$c = $aDigest
        $buffer = [System.Collections.Generic.List[byte]]::new(256)
        for ($r = 0; $r -lt $Rounds; $r++) {
            $buffer.Clear()
            if ($r -band 1) { $buffer.AddRange($pSeq) } else { $buffer.AddRange($c) }
            if ($r % 3) { $buffer.AddRange($sSeq) }
            if ($r % 7) { $buffer.AddRange($pSeq) }
            if ($r -band 1) { $buffer.AddRange($c) } else { $buffer.AddRange($pSeq) }
            [byte[]]$c = [System.Security.Cryptography.SHA512]::HashData($buffer.ToArray())
        }

        $sb = [System.Text.StringBuilder]::new()
        $order = @(0, 21, 42, 22, 43, 1, 44, 2, 23, 3, 24, 45, 25, 46, 4, 47, 5, 26, 6, 27, 48, 28, 49, 7, 50, 8, 29, 9, 30, 51,
            31, 52, 10, 53, 11, 32, 12, 33, 54, 34, 55, 13, 56, 14, 35, 15, 36, 57, 37, 58, 16, 59, 17, 38, 18, 39, 60,
            40, 61, 19, 62, 20, 41)
        for ($i = 0; $i -le $order.Count; $i += 3) {
            if ($i -lt $order.Count) {
                $w = ([int]$c[$order[$i]] -shl 16) -bor ([int]$c[$order[$i + 1]] -shl 8) -bor [int]$c[$order[$i + 2]]
                $count = 4
            }
            else {
                $w = [int]$c[63]
                $count = 2
            }
            for ($k = 0; $k -lt $count; $k++) { [void]$sb.Append($alphabet[$w -band 0x3f]); $w = $w -shr 6 }
        }
        $prefix = if ($PSBoundParameters.ContainsKey('Rounds')) { "`$6`$rounds=$Rounds`$" } else { '$6$' }
        return "$prefix$Salt`$$($sb.ToString())"
    }
    finally {
        [Array]::Clear($p, 0, $p.Length)
    }
}

function Test-ZtpPasswordHashFormat {
    <#
    .SYNOPSIS
        True when the hash is the '$6$<salt>$<86 chars>' form and passes the maintenance environment's own check
        (^\$[a-zA-Z0-9./]+\$[a-zA-Z0-9./]+\$ in /usr/sbin/init_roe_custom.sh, which exits 1 on a mismatch).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Hash)
    return ($Hash -cmatch '^\$6\$[./0-9A-Za-z]{1,16}\$[./0-9A-Za-z]{86}$') -and ($Hash -cmatch '^\$[a-zA-Z0-9./]+\$[a-zA-Z0-9./]+\$')
}

function Get-ZtpCrc32 {
    <#
    .SYNOPSIS
        CRC-32 (IEEE 802.3, the GPT header and partition-array checksum).
    #>
    [CmdletBinding()]
    [OutputType([uint32])]
    param([Parameter(Mandatory)][byte[]]$Bytes, [int]$Offset = 0, [int]$Count = -1)
    if ($Count -lt 0) { $Count = $Bytes.Length - $Offset }
    $table = [long[]]::new(256)
    for ($n = 0; $n -lt 256; $n++) {
        $v = [long]$n
        for ($k = 0; $k -lt 8; $k++) { $v = if ($v -band 1) { 0xEDB88320L -bxor ($v -shr 1) } else { $v -shr 1 } }
        $table[$n] = $v
    }
    $crc = 0xFFFFFFFFL
    $end = $Offset + $Count
    for ($i = $Offset; $i -lt $end; $i++) { $crc = $table[($crc -bxor $Bytes[$i]) -band 0xFF] -bxor ($crc -shr 8) }
    return [uint32]($crc -bxor 0xFFFFFFFFL)
}

function Write-ZtpLittleEndian {
    <#
    .SYNOPSIS
        Writes an unsigned integer of 1-8 bytes little-endian into a buffer (in memory only).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Buffer, [Parameter(Mandatory)][int]$Offset, [Parameter(Mandatory)][uint64]$Value, [ValidateRange(1, 8)][int]$Size = 4)
    for ($i = 0; $i -lt $Size; $i++) { $Buffer[$Offset + $i] = [byte](($Value -shr (8 * $i)) -band 0xFF) }
}

function ConvertTo-ZtpFatDateTime {
    <#
    .SYNOPSIS
        FAT directory-entry date and time words for a local timestamp (clamped to 1980-2107).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][datetime]$Timestamp)
    $t = $Timestamp
    if ($t.Year -lt 1980) { $t = [datetime]::new(1980, 1, 1) }
    if ($t.Year -gt 2107) { $t = [datetime]::new(2107, 12, 31, 23, 59, 58) }
    [pscustomobject]@{
        Date = [uint16]((($t.Year - 1980) -shl 9) -bor ($t.Month -shl 5) -bor $t.Day)
        Time = [uint16](($t.Hour -shl 11) -bor ($t.Minute -shl 5) -bor [math]::Floor($t.Second / 2))
    }
}

function ConvertFrom-ZtpFatDateTime {
    <#
    .SYNOPSIS
        Timestamp from FAT date and time words; [datetime]::MinValue when the words are not a valid date.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param([uint16]$Date, [uint16]$Time)
    $year = (($Date -shr 9) -band 0x7F) + 1980
    $month = ($Date -shr 5) -band 0x0F
    $day = $Date -band 0x1F
    $hour = ($Time -shr 11) -band 0x1F
    $minute = ($Time -shr 5) -band 0x3F
    $second = ($Time -band 0x1F) * 2
    if ($month -lt 1 -or $month -gt 12 -or $day -lt 1 -or $day -gt [datetime]::DaysInMonth($year, $month) -or $hour -gt 23 -or $minute -gt 59 -or $second -gt 59) {
        return [datetime]::MinValue
    }
    return [datetime]::new($year, $month, $day, $hour, $minute, $second)
}

function Get-ZtpShortName {
    <#
    .SYNOPSIS
        The 11-byte 8.3 directory name for a long name, unique within the directory, and whether a long-name (LFN) chain
        is needed. An exact upper-case 8.3 name is stored as is; anything else gets a NAME~N.EXT alias plus LFN entries.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Taken)
    $valid = '[A-Z0-9!#$%&''()@^_`{}~-]'
    $exact = [regex]::Match($Name, "^($valid{1,8})(?:\.($valid{1,3}))?$")
    if ($exact.Success -and $exact.Value -ceq $Name) {
        $short = $exact.Groups[1].Value.PadRight(8) + $exact.Groups[2].Value.PadRight(3)
        if ($Taken.Add($short)) {
            return [pscustomobject]@{ Short = $short; NeedsLongName = $false }
        }
    }
    $clean = { param([string]$Text) -join ($Text.ToUpperInvariant().ToCharArray() | Where-Object { $_ -ne ' ' -and $_ -ne '.' } | ForEach-Object { if ("$_" -cmatch "^$valid$") { $_ } else { '_' } }) }
    $trimmed = $Name.TrimStart('.')
    $dot = $trimmed.LastIndexOf('.')
    $base = & $clean ($dot -gt 0 ? $trimmed.Substring(0, $dot) : $trimmed)
    $ext = & $clean ($dot -gt 0 ? $trimmed.Substring($dot + 1) : '')
    if ($base.Length -eq 0) { $base = '_' }
    if ($ext.Length -gt 3) { $ext = $ext.Substring(0, 3) }
    for ($n = 1; $n -lt 1000000; $n++) {
        $tail = "~$n"
        $stem = $base.Substring(0, [math]::Min($base.Length, 8 - $tail.Length))
        $short = ($stem + $tail).PadRight(8) + $ext.PadRight(3)
        if ($Taken.Add($short)) { return [pscustomobject]@{ Short = $short; NeedsLongName = $true } }
    }
    throw "No free short name for '$Name'."
}

function Get-ZtpShortNameChecksum {
    <#
    .SYNOPSIS
        The LFN checksum of an 11-byte short name.
    #>
    [CmdletBinding()]
    [OutputType([byte])]
    param([Parameter(Mandatory)][byte[]]$ShortName)
    $sum = 0
    for ($i = 0; $i -lt 11; $i++) { $sum = ((($sum -band 1) -shl 7) + ($sum -shr 1) + $ShortName[$i]) -band 0xFF }
    return [byte]$sum
}

function ConvertTo-ZtpDirectoryBlock {
    <#
    .SYNOPSIS
        Serialises directory entries (with LFN chains) into the bytes of a directory's cluster chain.
    .PARAMETER Entries
        Objects { Short (11 chars), LongName ($null when not needed), Attributes, FirstCluster, Size, Timestamp }.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][object[]]$Entries, [Parameter(Mandatory)][int]$ClusterSize, [Parameter(Mandatory)][int]$ClusterCount)
    $bytes = [byte[]]::new($ClusterSize * $ClusterCount)
    $offset = 0
    foreach ($entry in $Entries) {
        $short = [System.Text.Encoding]::ASCII.GetBytes([string]$entry.Short)
        if ($entry.LongName) {
            $checksum = Get-ZtpShortNameChecksum -ShortName $short
            $chars = $entry.LongName.ToCharArray()
            $parts = [math]::Ceiling($chars.Length / 13)
            for ($ordinal = $parts; $ordinal -ge 1; $ordinal--) {
                $slot = [uint16[]]::new(13)
                for ($k = 0; $k -lt 13; $k++) {
                    $index = ($ordinal - 1) * 13 + $k
                    $slot[$k] = if ($index -lt $chars.Length) { [uint16]$chars[$index] } elseif ($index -eq $chars.Length) { 0 } else { 0xFFFF }
                }
                $bytes[$offset] = [byte]($ordinal -bor ($ordinal -eq $parts ? 0x40 : 0))
                for ($k = 0; $k -lt 5; $k++) { Write-ZtpLittleEndian -Buffer $bytes -Offset ($offset + 1 + 2 * $k) -Value $slot[$k] -Size 2 }
                $bytes[$offset + 11] = 0x0F
                $bytes[$offset + 13] = $checksum
                for ($k = 0; $k -lt 6; $k++) { Write-ZtpLittleEndian -Buffer $bytes -Offset ($offset + 14 + 2 * $k) -Value $slot[5 + $k] -Size 2 }
                for ($k = 0; $k -lt 2; $k++) { Write-ZtpLittleEndian -Buffer $bytes -Offset ($offset + 28 + 2 * $k) -Value $slot[11 + $k] -Size 2 }
                $offset += 32
            }
        }
        [Array]::Copy($short, 0, $bytes, $offset, 11)
        $bytes[$offset + 11] = [byte]$entry.Attributes
        $stamp = ConvertTo-ZtpFatDateTime -Timestamp $entry.Timestamp
        Write-ZtpLittleEndian -Buffer $bytes -Offset ($offset + 14) -Value $stamp.Time -Size 2
        Write-ZtpLittleEndian -Buffer $bytes -Offset ($offset + 16) -Value $stamp.Date -Size 2
        Write-ZtpLittleEndian -Buffer $bytes -Offset ($offset + 18) -Value $stamp.Date -Size 2
        Write-ZtpLittleEndian -Buffer $bytes -Offset ($offset + 20) -Value (([uint64]$entry.FirstCluster -shr 16) -band 0xFFFF) -Size 2
        Write-ZtpLittleEndian -Buffer $bytes -Offset ($offset + 22) -Value $stamp.Time -Size 2
        Write-ZtpLittleEndian -Buffer $bytes -Offset ($offset + 24) -Value $stamp.Date -Size 2
        Write-ZtpLittleEndian -Buffer $bytes -Offset ($offset + 26) -Value ([uint64]$entry.FirstCluster -band 0xFFFF) -Size 2
        Write-ZtpLittleEndian -Buffer $bytes -Offset ($offset + 28) -Value ([uint64]$entry.Size) -Size 4
        $offset += 32
    }
    return , $bytes
}

function Get-ZtpFat32Geometry {
    <#
    .SYNOPSIS
        GPT and FAT32 geometry for an image size and cluster size: one partition from LBA 2048 to the last 1 MiB boundary
        before the backup GPT, 32+ reserved sectors padded so the data region is cluster aligned, two FATs.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][long]$SizeBytes, [Parameter(Mandatory)][int]$ClusterSize)
    if ($SizeBytes % 1MB -ne 0) { throw "The image size must be a whole number of MiB: $SizeBytes" }
    if ($ClusterSize -notin 512, 1024, 2048, 4096, 8192, 16384, 32768) { throw "Unsupported FAT32 cluster size: $ClusterSize" }
    $totalSectors = [long]($SizeBytes / 512)
    $partitionStart = 2048L
    $partitionEnd = [long]([math]::Floor(($totalSectors - 33) / 2048) * 2048) - 1
    $partitionSectors = $partitionEnd - $partitionStart + 1
    if ($partitionSectors -gt [uint32]::MaxValue) { throw 'The partition exceeds the FAT32 limit of 2^32 sectors.' }
    $sectorsPerCluster = [long]($ClusterSize / 512)
    $reserved = 32L
    $fatSectors = [long][math]::Ceiling(((($partitionSectors - $reserved) / $sectorsPerCluster) + 2) * 4 / 512)
    $reserved += ($sectorsPerCluster - (($reserved + 2 * $fatSectors) % $sectorsPerCluster)) % $sectorsPerCluster
    $clusterCount = [long][math]::Floor(($partitionSectors - $reserved - 2 * $fatSectors) / $sectorsPerCluster)
    if ($clusterCount -lt 65525) {
        throw "A $([math]::Round($SizeBytes / 1MB)) MiB image with $ClusterSize-byte clusters has $clusterCount clusters; FAT32 needs at least 65525 (use a bigger image or smaller clusters)."
    }
    if ($clusterCount -gt 0x0FFFFFF4) { throw 'Too many clusters for FAT32; use a bigger cluster size.' }
    [pscustomobject]@{
        TotalSectors      = $totalSectors
        PartitionStart    = $partitionStart
        PartitionEnd      = $partitionEnd
        PartitionSectors  = $partitionSectors
        SectorsPerCluster = $sectorsPerCluster
        ClusterSize       = $ClusterSize
        ReservedSectors   = $reserved
        FatSectors        = $fatSectors
        ClusterCount      = $clusterCount
        PartitionOffset   = $partitionStart * 512
        FatOffset         = ($partitionStart + $reserved) * 512
        DataOffset        = ($partitionStart + $reserved + 2 * $fatSectors) * 512
    }
}

function Add-ZtpTreeChild {
    <#
    .SYNOPSIS
        Adds (or replaces, case-insensitively) a child in an in-memory directory node.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Parent, [Parameter(Mandatory)][pscustomobject]$Child)
    $existing = @($Parent.Children | Where-Object { $_.Name -ieq $Child.Name })
    foreach ($item in $existing) {
        if ($item.IsDirectory -or $Child.IsDirectory) { throw "'$($Child.Name)' would replace a directory or a file with a directory." }
        [void]$Parent.Children.Remove($item)
    }
    $Parent.Children.Add($Child)
}

function New-ZtpTreeNode {
    <#
    .SYNOPSIS
        In-memory node of the image tree (no file is touched).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Name, [bool]$IsDirectory, [string]$SourceFile, [byte[]]$Bytes, [long]$Size, [datetime]$Timestamp)
    [pscustomobject]@{
        Name         = $Name
        IsDirectory  = $IsDirectory
        SourceFile   = $SourceFile
        Bytes        = $Bytes
        Size         = $Size
        Timestamp    = $Timestamp
        Children     = [System.Collections.Generic.List[object]]::new()
        FirstCluster = 0L
        ClusterCount = 0L
        Short        = $null
        LongName     = $null
        ParentCluster = 0L
    }
}

function Build-ZtpFat32Image {
    <#
    .SYNOPSIS
        Writes a raw disk image: protective MBR, GPT with one Basic Data partition, FAT32 with the volume label, and every
        file and folder of SourcePath copied in, plus ExtraFiles. Files are stored contiguously.
    .PARAMETER SourcePath
        Folder whose contents become the volume root (an extracted or mounted maintenance ISO).
    .PARAMETER ExtraFiles
        Hashtable of 'relative/path' = [byte[]] written on top of the source (for example the edgeuser hash file).
    .OUTPUTS
        PSCustomObject { Path, SizeBytes, ClusterSize, ClusterCount, UsedClusters, Files, Directories }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][long]$SizeBytes,
        [int]$ClusterSize = 4096,
        [ValidatePattern('^[A-Z0-9_-]{1,11}$')][string]$VolumeLabel = 'CDROM',
        [hashtable]$ExtraFiles = @{},
        [switch]$Force
    )
    $geometry = Get-ZtpFat32Geometry -SizeBytes $SizeBytes -ClusterSize $ClusterSize
    $sourceRoot = Get-Item -LiteralPath $SourcePath
    if (-not $sourceRoot.PSIsContainer) { throw "The source must be a folder: $SourcePath" }

    # 1. In-memory tree of the source plus the extra files.
    $root = New-ZtpTreeNode -Name '' -IsDirectory $true -Timestamp (Get-Date)
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push(@($root, $sourceRoot.FullName))
    $fileCount = 0
    $directoryCount = 0
    while ($stack.Count -gt 0) {
        $pair = $stack.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $pair[1] -Force | Sort-Object Name)) {
            if ($item.Name.Length -gt 255) { throw "Name longer than 255 characters: $($item.FullName)" }
            if ($item.PSIsContainer) {
                $node = New-ZtpTreeNode -Name $item.Name -IsDirectory $true -Timestamp $item.LastWriteTime
                Add-ZtpTreeChild -Parent $pair[0] -Child $node
                $stack.Push(@($node, $item.FullName))
                $directoryCount++
            }
            else {
                if ($item.Length -gt [uint32]::MaxValue) { throw "File larger than the FAT32 limit of 4 GiB - 1: $($item.FullName)" }
                Add-ZtpTreeChild -Parent $pair[0] -Child (New-ZtpTreeNode -Name $item.Name -IsDirectory $false -SourceFile $item.FullName -Size $item.Length -Timestamp $item.LastWriteTime)
                $fileCount++
            }
        }
    }
    foreach ($key in @($ExtraFiles.Keys | Sort-Object)) {
        $segments = @(([string]$key) -split '[\\/]' | Where-Object { $_ })
        if ($segments.Count -eq 0) { throw "Empty extra-file path." }
        $parent = $root
        for ($i = 0; $i -lt $segments.Count - 1; $i++) {
            $next = @($parent.Children | Where-Object { $_.Name -ieq $segments[$i] }) | Select-Object -First 1
            if ($null -eq $next) {
                $next = New-ZtpTreeNode -Name $segments[$i] -IsDirectory $true -Timestamp (Get-Date)
                Add-ZtpTreeChild -Parent $parent -Child $next
                $directoryCount++
            }
            elseif (-not $next.IsDirectory) { throw "Extra file path '$key' crosses the file '$($next.Name)'." }
            $parent = $next
        }
        [byte[]]$content = $ExtraFiles[$key]
        Add-ZtpTreeChild -Parent $parent -Child (New-ZtpTreeNode -Name $segments[-1] -IsDirectory $false -Bytes $content -Size $content.Length -Timestamp (Get-Date))
        $fileCount++
    }

    # 2. Short names, directory sizes and contiguous cluster allocation (pre-order: directory, its files, its subfolders).
    $objects = [System.Collections.Generic.List[object]]::new()
    $next = 2L
    $queue = [System.Collections.Generic.Stack[object]]::new()
    $queue.Push($root)
    while ($queue.Count -gt 0) {
        $dir = $queue.Pop()
        $taken = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $entryCount = if ($dir -eq $root) { 1 } else { 2 }
        foreach ($child in $dir.Children) {
            $short = Get-ZtpShortName -Name $child.Name -Taken $taken
            $child.Short = $short.Short
            $child.LongName = if ($short.NeedsLongName) { $child.Name } else { $null }
            $entryCount += 1 + ($short.NeedsLongName ? [math]::Ceiling($child.Name.Length / 13) : 0)
        }
        $dir.Size = $entryCount * 32
        $dir.ClusterCount = [long][math]::Max(1, [math]::Ceiling($dir.Size / $ClusterSize))
        $dir.FirstCluster = $next
        $next += $dir.ClusterCount
        $objects.Add($dir)
        foreach ($child in @($dir.Children | Where-Object { -not $_.IsDirectory })) {
            if ($child.Size -gt 0) {
                $child.ClusterCount = [long][math]::Ceiling($child.Size / $ClusterSize)
                $child.FirstCluster = $next
                $next += $child.ClusterCount
                $objects.Add($child)
            }
        }
        $subdirs = @($dir.Children | Where-Object { $_.IsDirectory })
        foreach ($subdir in $subdirs) { $subdir.ParentCluster = ($dir -eq $root ? 0L : [long]$dir.FirstCluster) }
        for ($i = $subdirs.Count - 1; $i -ge 0; $i--) { $queue.Push($subdirs[$i]) }
    }
    $used = $next - 2
    if ($used -gt $geometry.ClusterCount) {
        throw "Image too small: the content needs $used clusters of $ClusterSize bytes; the volume has $($geometry.ClusterCount). Use a bigger -SizeBytes."
    }

    # 3. The FAT (both copies identical).
    $fatEntries = [uint32[]]::new($geometry.FatSectors * 128)
    $fatEntries[0] = 0x0FFFFFF8u
    $fatEntries[1] = 0x0FFFFFFFu
    foreach ($object in $objects) {
        $last = $object.FirstCluster + $object.ClusterCount - 1
        for ($cluster = $object.FirstCluster; $cluster -lt $last; $cluster++) { $fatEntries[$cluster] = [uint32]($cluster + 1) }
        $fatEntries[$last] = 0x0FFFFFFFu
    }
    $fatBytes = [byte[]]::new($fatEntries.Length * 4)
    [Buffer]::BlockCopy($fatEntries, 0, $fatBytes, 0, $fatBytes.Length)

    # 4. Boot region: protective MBR, GPT, FAT32 boot sector, FSInfo and the backup boot sectors.
    $diskGuid = [guid]::NewGuid()
    $partitionGuid = [guid]::NewGuid()
    $volumeId = [BitConverter]::ToUInt32([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(4), 0)
    $mbr = [byte[]]::new(512)
    $mbr[446 + 1] = 0x00; $mbr[446 + 2] = 0x02; $mbr[446 + 3] = 0x00
    $mbr[446 + 4] = 0xEE; $mbr[446 + 5] = 0xFF; $mbr[446 + 6] = 0xFF; $mbr[446 + 7] = 0xFF
    Write-ZtpLittleEndian -Buffer $mbr -Offset (446 + 8) -Value 1 -Size 4
    Write-ZtpLittleEndian -Buffer $mbr -Offset (446 + 12) -Value ([math]::Min($geometry.TotalSectors - 1, [uint32]::MaxValue)) -Size 4
    $mbr[510] = 0x55; $mbr[511] = 0xAA

    $entries = [byte[]]::new(128 * 128)
    [Array]::Copy(([guid]'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7').ToByteArray(), 0, $entries, 0, 16)
    [Array]::Copy($partitionGuid.ToByteArray(), 0, $entries, 16, 16)
    Write-ZtpLittleEndian -Buffer $entries -Offset 32 -Value $geometry.PartitionStart -Size 8
    Write-ZtpLittleEndian -Buffer $entries -Offset 40 -Value $geometry.PartitionEnd -Size 8
    $partName = [System.Text.Encoding]::Unicode.GetBytes('Basic data partition')
    [Array]::Copy($partName, 0, $entries, 56, $partName.Length)
    $entriesCrc = Get-ZtpCrc32 -Bytes $entries
    $newGptHeader = {
        param([long]$MyLba, [long]$AlternateLba, [long]$EntriesLba)
        $h = [byte[]]::new(512)
        [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes('EFI PART'), 0, $h, 0, 8)
        Write-ZtpLittleEndian -Buffer $h -Offset 8 -Value 0x00010000 -Size 4
        Write-ZtpLittleEndian -Buffer $h -Offset 12 -Value 92 -Size 4
        Write-ZtpLittleEndian -Buffer $h -Offset 24 -Value $MyLba -Size 8
        Write-ZtpLittleEndian -Buffer $h -Offset 32 -Value $AlternateLba -Size 8
        Write-ZtpLittleEndian -Buffer $h -Offset 40 -Value 34 -Size 8
        Write-ZtpLittleEndian -Buffer $h -Offset 48 -Value ($geometry.TotalSectors - 34) -Size 8
        [Array]::Copy($diskGuid.ToByteArray(), 0, $h, 56, 16)
        Write-ZtpLittleEndian -Buffer $h -Offset 72 -Value $EntriesLba -Size 8
        Write-ZtpLittleEndian -Buffer $h -Offset 80 -Value 128 -Size 4
        Write-ZtpLittleEndian -Buffer $h -Offset 84 -Value 128 -Size 4
        Write-ZtpLittleEndian -Buffer $h -Offset 88 -Value $entriesCrc -Size 4
        Write-ZtpLittleEndian -Buffer $h -Offset 16 -Value (Get-ZtpCrc32 -Bytes $h -Offset 0 -Count 92) -Size 4
        return , $h
    }
    $primaryHeader = & $newGptHeader 1 ($geometry.TotalSectors - 1) 2
    $backupHeader = & $newGptHeader ($geometry.TotalSectors - 1) 1 ($geometry.TotalSectors - 33)

    $boot = [byte[]]::new(512 * 3)
    $boot[0] = 0xEB; $boot[1] = 0x58; $boot[2] = 0x90
    [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes('MSWIN4.1'), 0, $boot, 3, 8)
    Write-ZtpLittleEndian -Buffer $boot -Offset 11 -Value 512 -Size 2
    $boot[13] = [byte]$geometry.SectorsPerCluster
    Write-ZtpLittleEndian -Buffer $boot -Offset 14 -Value $geometry.ReservedSectors -Size 2
    $boot[16] = 2
    $boot[21] = 0xF8
    Write-ZtpLittleEndian -Buffer $boot -Offset 24 -Value 63 -Size 2
    Write-ZtpLittleEndian -Buffer $boot -Offset 26 -Value 255 -Size 2
    Write-ZtpLittleEndian -Buffer $boot -Offset 28 -Value $geometry.PartitionStart -Size 4
    Write-ZtpLittleEndian -Buffer $boot -Offset 32 -Value $geometry.PartitionSectors -Size 4
    Write-ZtpLittleEndian -Buffer $boot -Offset 36 -Value $geometry.FatSectors -Size 4
    Write-ZtpLittleEndian -Buffer $boot -Offset 44 -Value 2 -Size 4
    Write-ZtpLittleEndian -Buffer $boot -Offset 48 -Value 1 -Size 2
    Write-ZtpLittleEndian -Buffer $boot -Offset 50 -Value 6 -Size 2
    $boot[64] = 0x80
    $boot[66] = 0x29
    Write-ZtpLittleEndian -Buffer $boot -Offset 67 -Value $volumeId -Size 4
    [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes($VolumeLabel.PadRight(11)), 0, $boot, 71, 11)
    [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes('FAT32   '), 0, $boot, 82, 8)
    $boot[90] = 0xCD; $boot[91] = 0x18   # int 18h: this volume is not BIOS-bootable (UEFI reads \EFI\BOOT\BOOTX64.EFI)
    $boot[510] = 0x55; $boot[511] = 0xAA
    # FSInfo (sector 1)
    Write-ZtpLittleEndian -Buffer $boot -Offset 512 -Value 0x41615252 -Size 4
    Write-ZtpLittleEndian -Buffer $boot -Offset (512 + 484) -Value 0x61417272 -Size 4
    Write-ZtpLittleEndian -Buffer $boot -Offset (512 + 488) -Value ($geometry.ClusterCount - $used) -Size 4
    Write-ZtpLittleEndian -Buffer $boot -Offset (512 + 492) -Value $next -Size 4
    Write-ZtpLittleEndian -Buffer $boot -Offset (512 + 508) -Value 0xAA550000L -Size 4
    $boot[1024 + 510] = 0x55; $boot[1024 + 511] = 0xAA

    # 5. Write the image in ascending offset order.
    $mode = if ($Force) { [System.IO.FileMode]::Create } else { [System.IO.FileMode]::CreateNew }
    $stream = [System.IO.FileStream]::new($OutputPath, $mode, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None, 1MB)
    try {
        $stream.SetLength($SizeBytes)
        $put = {
            param([long]$Offset, [byte[]]$Data)
            $null = $stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
            $stream.Write($Data, 0, $Data.Length)
        }
        & $put 0 $mbr
        & $put 512 $primaryHeader
        & $put 1024 $entries
        & $put $geometry.PartitionOffset $boot
        & $put ($geometry.PartitionOffset + 6 * 512) $boot
        & $put $geometry.FatOffset $fatBytes
        & $put ($geometry.FatOffset + $geometry.FatSectors * 512) $fatBytes
        $copyBuffer = [byte[]]::new(1MB)
        foreach ($object in @($objects | Sort-Object FirstCluster)) {
            $offset = $geometry.DataOffset + ($object.FirstCluster - 2) * $ClusterSize
            if ($object.IsDirectory) {
                $dirEntries = [System.Collections.Generic.List[object]]::new()
                if ($object -eq $root) {
                    $dirEntries.Add([pscustomobject]@{ Short = $VolumeLabel.PadRight(11); LongName = $null; Attributes = 0x08; FirstCluster = 0; Size = 0; Timestamp = $object.Timestamp })
                }
                else {
                    $dirEntries.Add([pscustomobject]@{ Short = '.'.PadRight(11); LongName = $null; Attributes = 0x10; FirstCluster = $object.FirstCluster; Size = 0; Timestamp = $object.Timestamp })
                    $dirEntries.Add([pscustomobject]@{ Short = '..'.PadRight(11); LongName = $null; Attributes = 0x10; FirstCluster = $object.ParentCluster; Size = 0; Timestamp = $object.Timestamp })
                }
                foreach ($child in $object.Children) {
                    $dirEntries.Add([pscustomobject]@{
                            Short        = $child.Short
                            LongName     = $child.LongName
                            Attributes   = ($child.IsDirectory ? 0x10 : 0x20)
                            FirstCluster = $child.FirstCluster
                            Size         = ($child.IsDirectory ? 0 : $child.Size)
                            Timestamp    = $child.Timestamp
                        })
                }
                & $put $offset (ConvertTo-ZtpDirectoryBlock -Entries $dirEntries.ToArray() -ClusterSize $ClusterSize -ClusterCount $object.ClusterCount)
            }
            elseif ($null -ne $object.Bytes) {
                & $put $offset $object.Bytes
            }
            else {
                $null = $stream.Seek($offset, [System.IO.SeekOrigin]::Begin)
                $source = [System.IO.File]::OpenRead($object.SourceFile)
                try {
                    $copied = 0L
                    while (($read = $source.Read($copyBuffer, 0, $copyBuffer.Length)) -gt 0) {
                        $stream.Write($copyBuffer, 0, $read)
                        $copied += $read
                    }
                }
                finally { $source.Dispose() }
                if ($copied -ne $object.Size) { throw "Copied $copied of $($object.Size) bytes from $($object.SourceFile); the source changed during the build." }
            }
        }
        & $put (($geometry.TotalSectors - 33) * 512) $entries
        & $put (($geometry.TotalSectors - 1) * 512) $backupHeader
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
    [pscustomobject]@{
        Path         = (Resolve-Path -LiteralPath $OutputPath).ProviderPath
        SizeBytes    = $SizeBytes
        ClusterSize  = $ClusterSize
        ClusterCount = $geometry.ClusterCount
        UsedClusters = $used
        Files        = $fileCount
        Directories  = $directoryCount
    }
}

function Read-ZtpExactly {
    <#
    .SYNOPSIS
        Reads exactly Count bytes at Offset of a stream (throws on a short read).
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][System.IO.Stream]$Stream, [Parameter(Mandatory)][long]$Offset, [Parameter(Mandatory)][int]$Count)
    $buffer = [byte[]]::new($Count)
    $null = $Stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
    $total = 0
    while ($total -lt $Count) {
        $read = $Stream.Read($buffer, $total, $Count - $total)
        if ($read -le 0) { throw "Unexpected end of image at offset $($Offset + $total)." }
        $total += $read
    }
    return , $buffer
}

function Open-ZtpFat32Volume {
    <#
    .SYNOPSIS
        Opens a raw image READ-ONLY and locates its FAT32 volume: GPT (header CRC checked; first partition holding a FAT32
        boot sector), MBR (types 0x0B/0x0C), or a FAT32 boot sector at sector 0.
    .PARAMETER AllowOpen
        Share the file with writers (FileShare.ReadWrite), for example while the iDRAC still holds the image. Without it
        the open fails when another process has the image open for writing, which is the signal to eject first.
    .OUTPUTS
        PSCustomObject volume; close it with Close-ZtpFat32Volume.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path, [switch]$AllowOpen)
    $share = if ($AllowOpen) { [System.IO.FileShare]::ReadWrite } else { [System.IO.FileShare]::Read }
    $stream = [System.IO.FileStream]::new((Resolve-Path -LiteralPath $Path).ProviderPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
        $isFat32 = {
            param([byte[]]$Sector)
            $bps = [BitConverter]::ToUInt16($Sector, 11)
            return ($Sector[510] -eq 0x55 -and $Sector[511] -eq 0xAA -and $bps -in 512, 1024, 2048, 4096 -and
                $Sector[13] -gt 0 -and ($Sector[13] -band ($Sector[13] - 1)) -eq 0 -and $Sector[16] -ge 1 -and
                [BitConverter]::ToUInt16($Sector, 22) -eq 0 -and [BitConverter]::ToUInt32($Sector, 36) -gt 0)
        }
        $candidates = [System.Collections.Generic.List[long]]::new()
        $sector0 = Read-ZtpExactly -Stream $stream -Offset 0 -Count 512
        $header = Read-ZtpExactly -Stream $stream -Offset 512 -Count 512
        if ([System.Text.Encoding]::ASCII.GetString($header, 0, 8) -eq 'EFI PART') {
            $headerSize = [BitConverter]::ToUInt32($header, 12)
            if ($headerSize -lt 92 -or $headerSize -gt 512) { throw 'Invalid GPT header size.' }
            $copy = [byte[]]$header.Clone()
            [Array]::Clear($copy, 16, 4)
            if ((Get-ZtpCrc32 -Bytes $copy -Offset 0 -Count $headerSize) -ne [BitConverter]::ToUInt32($header, 16)) { throw 'The GPT header CRC does not match; the image is damaged.' }
            $entriesLba = [BitConverter]::ToUInt64($header, 72)
            $entryCount = [BitConverter]::ToUInt32($header, 80)
            $entrySize = [BitConverter]::ToUInt32($header, 84)
            if ($entrySize -lt 128 -or $entryCount -gt 1024) { throw 'Invalid GPT partition array.' }
            $array = Read-ZtpExactly -Stream $stream -Offset ([long]$entriesLba * 512) -Count ([int]($entryCount * $entrySize))
            for ($i = 0; $i -lt $entryCount; $i++) {
                $o = $i * $entrySize
                $type = [guid]::new([byte[]]$array[$o..($o + 15)])
                if ($type -ne [guid]::Empty) { $candidates.Add([long][BitConverter]::ToUInt64($array, $o + 32) * 512) }
            }
        }
        elseif ($sector0[510] -eq 0x55 -and $sector0[511] -eq 0xAA -and -not (& $isFat32 $sector0)) {
            for ($i = 0; $i -lt 4; $i++) {
                $o = 446 + 16 * $i
                if ($sector0[$o + 4] -in 0x0B, 0x0C) { $candidates.Add([long][BitConverter]::ToUInt32($sector0, $o + 8) * 512) }
            }
        }
        else {
            $candidates.Add(0L)
        }
        foreach ($offset in $candidates) {
            if ($offset + 512 -gt $stream.Length) { continue }
            $bpb = Read-ZtpExactly -Stream $stream -Offset $offset -Count 512
            if (-not (& $isFat32 $bpb)) { continue }
            $bps = [long][BitConverter]::ToUInt16($bpb, 11)
            $spc = [long]$bpb[13]
            $reserved = [long][BitConverter]::ToUInt16($bpb, 14)
            $fats = [long]$bpb[16]
            $fatSectors = [long][BitConverter]::ToUInt32($bpb, 36)
            $totalSectors = [long][BitConverter]::ToUInt32($bpb, 32)
            $dataSectors = $totalSectors - $reserved - $fats * $fatSectors
            $clusterCount = [long][math]::Floor($dataSectors / $spc)
            $fatOffset = $offset + $reserved * $bps
            $fatLength = [math]::Min($fatSectors * $bps, ($clusterCount + 2) * 4)
            $fatBytes = Read-ZtpExactly -Stream $stream -Offset $fatOffset -Count ([int]$fatLength)
            $fat = [uint32[]]::new([math]::Floor($fatLength / 4))
            [Buffer]::BlockCopy($fatBytes, 0, $fat, 0, $fat.Length * 4)
            return [pscustomobject]@{
                Path            = $Path
                Stream          = $stream
                PartitionOffset = $offset
                BytesPerSector  = $bps
                ClusterSize     = $bps * $spc
                ClusterCount    = $clusterCount
                DataOffset      = $offset + ($reserved + $fats * $fatSectors) * $bps
                RootCluster     = [long][BitConverter]::ToUInt32($bpb, 44)
                Fat             = $fat
                Label           = [System.Text.Encoding]::ASCII.GetString($bpb, 71, 11).TrimEnd()
            }
        }
        throw "No FAT32 volume found in $Path."
    }
    catch {
        $stream.Dispose()
        throw
    }
}

function Close-ZtpFat32Volume {
    <#
    .SYNOPSIS
        Closes the image opened by Open-ZtpFat32Volume.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Volume)
    $Volume.Stream.Dispose()
}

function Get-ZtpFat32ClusterChain {
    <#
    .SYNOPSIS
        The cluster numbers of a chain (loop- and range-checked).
    #>
    [CmdletBinding()]
    [OutputType([long[]])]
    param([Parameter(Mandatory)][pscustomobject]$Volume, [Parameter(Mandatory)][long]$FirstCluster)
    $chain = [System.Collections.Generic.List[long]]::new()
    $cluster = $FirstCluster
    while ($cluster -ge 2 -and $cluster -lt 0x0FFFFFF8) {
        if ($cluster -ge $Volume.ClusterCount + 2 -or $cluster -ge $Volume.Fat.Length) { throw "Cluster $cluster is outside the volume; the FAT is damaged." }
        if ($chain.Count -gt $Volume.ClusterCount) { throw 'Cluster chain loop; the FAT is damaged.' }
        $chain.Add($cluster)
        $cluster = [long]($Volume.Fat[$cluster] -band 0x0FFFFFFF)
    }
    return , $chain.ToArray()
}

function Read-ZtpFat32Chain {
    <#
    .SYNOPSIS
        The bytes of a cluster chain, truncated to Length when given.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][pscustomobject]$Volume, [Parameter(Mandatory)][long]$FirstCluster, [long]$Length = -1)
    $chain = Get-ZtpFat32ClusterChain -Volume $Volume -FirstCluster $FirstCluster
    $total = if ($Length -ge 0) { $Length } else { [long]$chain.Length * $Volume.ClusterSize }
    if ($total -gt [long]$chain.Length * $Volume.ClusterSize) { throw "The cluster chain at $FirstCluster is shorter than the file size $Length." }
    $result = [byte[]]::new($total)
    $done = 0L
    foreach ($cluster in $chain) {
        if ($done -ge $total) { break }
        $take = [int][math]::Min($Volume.ClusterSize, $total - $done)
        $bytes = Read-ZtpExactly -Stream $Volume.Stream -Offset ($Volume.DataOffset + ($cluster - 2) * $Volume.ClusterSize) -Count $take
        [Array]::Copy($bytes, 0, $result, $done, $take)
        $done += $take
    }
    return , $result
}

function Get-ZtpFat32DirectoryEntry {
    <#
    .SYNOPSIS
        Entries of one directory (long names assembled and checksum-checked; '.', '..', deleted and label entries skipped).
    .OUTPUTS
        PSCustomObject { Name, ShortName, IsDirectory, Size, FirstCluster, LastWriteTime }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][pscustomobject]$Volume, [Parameter(Mandatory)][long]$Cluster)
    $data = Read-ZtpFat32Chain -Volume $Volume -FirstCluster $Cluster
    $result = [System.Collections.Generic.List[object]]::new()
    $longParts = @{}
    $longChecksum = -1
    for ($o = 0; $o + 32 -le $data.Length; $o += 32) {
        $first = $data[$o]
        if ($first -eq 0x00) { break }
        $attributes = $data[$o + 11]
        if ($first -eq 0xE5) { $longParts = @{}; continue }
        if (($attributes -band 0x3F) -eq 0x0F) {
            $ordinal = $first -band 0x1F
            if ($first -band 0x40) { $longParts = @{}; $longChecksum = $data[$o + 13] }
            $chars = [System.Text.StringBuilder]::new()
            foreach ($range in @(@(1, 5), @(14, 6), @(28, 2))) {
                for ($k = 0; $k -lt $range[1]; $k++) {
                    $c = [BitConverter]::ToUInt16($data, $o + $range[0] + 2 * $k)
                    if ($c -eq 0 -or $c -eq 0xFFFF) { break }
                    [void]$chars.Append([char]$c)
                }
            }
            $longParts[[int]$ordinal] = $chars.ToString()
            continue
        }
        $shortBytes = [byte[]]$data[$o..($o + 10)]
        if ($first -eq 0x05) { $shortBytes[0] = 0xE5 }
        $ntFlags = $data[$o + 12]
        $base = [System.Text.Encoding]::Latin1.GetString($shortBytes, 0, 8).TrimEnd()
        $ext = [System.Text.Encoding]::Latin1.GetString($shortBytes, 8, 3).TrimEnd()
        if ($ntFlags -band 0x08) { $base = $base.ToLowerInvariant() }
        if ($ntFlags -band 0x10) { $ext = $ext.ToLowerInvariant() }
        $short = if ($ext) { "$base.$ext" } else { $base }
        $name = $short
        if ($longParts.Count -gt 0 -and $longChecksum -eq (Get-ZtpShortNameChecksum -ShortName $shortBytes)) {
            $name = -join (@($longParts.Keys | Sort-Object) | ForEach-Object { $longParts[$_] })
        }
        $longParts = @{}
        $longChecksum = -1
        if ($attributes -band 0x08) { continue }
        if ($short -in '.', '..') { continue }
        $result.Add([pscustomobject]@{
                Name          = $name
                ShortName     = $short
                IsDirectory   = [bool]($attributes -band 0x10)
                Size          = [long][BitConverter]::ToUInt32($data, $o + 28)
                FirstCluster  = ([long][BitConverter]::ToUInt16($data, $o + 20) -shl 16) -bor [long][BitConverter]::ToUInt16($data, $o + 26)
                LastWriteTime = ConvertFrom-ZtpFatDateTime -Date ([BitConverter]::ToUInt16($data, $o + 24)) -Time ([BitConverter]::ToUInt16($data, $o + 22))
            })
    }
    return $result.ToArray()
}

function Get-ZtpFat32Tree {
    <#
    .SYNOPSIS
        Every entry under the root (or StartPath) with its full '/'-separated path, breadth first, depth-limited.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][pscustomobject]$Volume, [ValidateRange(1, 64)][int]$MaxDepth = 16)
    $result = [System.Collections.Generic.List[object]]::new()
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue(@('', $Volume.RootCluster, 0))
    $seen = [System.Collections.Generic.HashSet[long]]::new()
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        if (-not $seen.Add([long]$item[1])) { continue }
        foreach ($entry in (Get-ZtpFat32DirectoryEntry -Volume $Volume -Cluster $item[1])) {
            $path = "$($item[0])/$($entry.Name)"
            $entry | Add-Member -NotePropertyName Path -NotePropertyValue $path
            $result.Add($entry)
            if ($entry.IsDirectory -and $entry.FirstCluster -ge 2 -and $item[2] + 1 -lt $MaxDepth) { $queue.Enqueue(@($path, $entry.FirstCluster, $item[2] + 1)) }
        }
    }
    return $result.ToArray()
}

function Read-ZtpFat32File {
    <#
    .SYNOPSIS
        The bytes of a file entry (refuses files larger than MaxBytes).
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][pscustomobject]$Volume, [Parameter(Mandatory)][pscustomobject]$Entry, [long]$MaxBytes = 1MB)
    if ($Entry.IsDirectory) { throw "$($Entry.Name) is a directory." }
    if ($Entry.Size -gt $MaxBytes) { throw "$($Entry.Name) is $($Entry.Size) bytes; the limit is $MaxBytes." }
    if ($Entry.Size -eq 0) { return , [byte[]]::new(0) }
    return , (Read-ZtpFat32Chain -Volume $Volume -FirstCluster $Entry.FirstCluster -Length $Entry.Size)
}

function Test-ZtpOwnershipVoucher {
    <#
    .SYNOPSIS
        Validates a voucher file's bytes for one serial number without returning its contents.
    .DESCRIPTION
        Checks: one complete PEM block '-----BEGIN OWNERSHIP VOUCHER-----' ... '-----END OWNERSHIP VOUCHER-----', a base64
        body that decodes, a CBOR array of five items (the FDO OwnershipVoucher structure, first byte 0x85), and the
        serial number present in the decoded voucher (the device info the maintenance environment embeds).
    .OUTPUTS
        PSCustomObject { Valid, Problems, SerialInVoucher, Sha256 }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes, [Parameter(Mandatory)][string]$Serial)
    $problems = [System.Collections.Generic.List[string]]::new()
    $serialInVoucher = $false
    $text = [System.Text.Encoding]::UTF8.GetString($Bytes).TrimStart([char]0xFEFF)
    $lines = @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($Bytes.Length -eq 0) { $problems.Add('empty file') }
    elseif ($lines.Count -lt 3 -or $lines[0] -cne '-----BEGIN OWNERSHIP VOUCHER-----' -or $lines[-1] -cne '-----END OWNERSHIP VOUCHER-----') {
        $problems.Add('not one complete OWNERSHIP VOUCHER PEM block')
    }
    else {
        $body = -join $lines[1..($lines.Count - 2)]
        $decoded = $null
        try { $decoded = [Convert]::FromBase64String($body) } catch { $problems.Add('the PEM body is not valid base64') }
        if ($null -ne $decoded) {
            if ($decoded.Length -eq 0 -or $decoded[0] -ne 0x85) { $problems.Add('the decoded voucher is not a CBOR array of five items (FDO OwnershipVoucher)') }
            $serialInVoucher = [System.Text.Encoding]::Latin1.GetString($decoded).Contains($Serial, [StringComparison]::Ordinal)
            if (-not $serialInVoucher) { $problems.Add("the serial number $Serial is not in the voucher") }
        }
    }
    [pscustomobject]@{
        Valid           = ($problems.Count -eq 0)
        Problems        = $problems.ToArray()
        SerialInVoucher = $serialInVoucher
        Sha256          = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Bytes))
    }
}

function Find-ZtpVoucherInImage {
    <#
    .SYNOPSIS
        Lists the ownership-voucher candidates in an image without changing it.
    .DESCRIPTION
        The maintenance environment (ROESetup ContentTransferHelper.ExportContent) stages /var/staging/roesetup/response.json,
        /var/systeminfo and the device-initialization output under /var/staging/export/vouchers/<serial> (vouchers/<guid>
        when the serial is unavailable) and, when exactly one writable USB drive is attached, copies that tree to the USB
        root. So the voucher lands at \vouchers\<serial>\*.pem. Every *.pem in the image is returned; UnderVouchers marks
        the ones in that tree and Folder is the folder name (the serial). Bytes are returned for validation only.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$ImagePath, [switch]$AllowOpen)
    $volume = Open-ZtpFat32Volume -Path $ImagePath -AllowOpen:$AllowOpen
    try {
        $tree = Get-ZtpFat32Tree -Volume $volume
        $pem = foreach ($entry in @($tree | Where-Object { -not $_.IsDirectory -and $_.Name -like '*.pem' })) {
            $segments = $entry.Path.Split('/', [StringSplitOptions]::RemoveEmptyEntries)
            [pscustomobject]@{
                Path          = $entry.Path
                Name          = $entry.Name
                Folder        = ($segments.Count -ge 2 ? $segments[-2] : '')
                UnderVouchers = ($segments.Count -eq 3 -and $segments[0] -ieq 'vouchers')
                Size          = $entry.Size
                LastWriteTime = $entry.LastWriteTime
                Bytes         = $(if ($entry.Size -le 1MB) { Read-ZtpFat32File -Volume $volume -Entry $entry } else { $null })
            }
        }
        [pscustomobject]@{
            ImagePath      = $ImagePath
            Label          = $volume.Label
            VoucherFolders = @($tree | Where-Object { $_.IsDirectory -and $_.Path -match '^/vouchers/[^/]+$' } | ForEach-Object { $_.Name })
            Pem            = @($pem)
        }
    }
    finally {
        Close-ZtpFat32Volume -Volume $volume
    }
}

function Get-ZtpNodeImageName {
    <#
    .SYNOPSIS
        The per-node image file name: <prefix><node name>.img.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$NodeName, [string]$Prefix = 'ztp-usb-')
    if ($NodeName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$') { throw "Node name '$NodeName' is not usable in a file name." }
    if ($Prefix -notmatch '^[A-Za-z0-9._-]{0,40}$') { throw "Image name prefix '$Prefix' is not usable in a file name." }
    return "$Prefix$NodeName.img"
}


function Import-ZtpNodeFile {
    <#
    .SYNOPSIS
        Reads the node list from a JSON file ({ "nodes": [ { name, service_tag, bmc_address } ] } or a bare array) or, when
        the powershell-yaml module is installed, a YAML file with a top-level nodes: list.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Nodes file not found: $Path" }
    $text = Get-Content -LiteralPath $Path -Raw
    $data = if ([IO.Path]::GetExtension($Path) -in '.yml', '.yaml') {
        if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) { Import-Module powershell-yaml -ErrorAction Stop }
        ConvertFrom-Yaml -Yaml $text
    }
    else { $text | ConvertFrom-Json -AsHashtable -Depth 20 -NoEnumerate }
    if ($data -is [System.Collections.IDictionary]) {
        if (-not $data.Contains('nodes')) { throw "The nodes file has no 'nodes' list: $Path" }
        $data = $data['nodes']
    }
    return @($data)
}

function Get-ZtpNodeList {
    <#
    .SYNOPSIS
        Nodes as { Name, Serial, BmcAddress } from -Nodes objects (name; service_tag or serial; bmc_address or bmc_ip) or
        from -NodesFile. No hidden lookups: with neither, the function throws.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([object[]]$Nodes, [string[]]$NodeName, [string]$NodesFile, [switch]$RequireSerial)
    if (-not $Nodes) {
        if (-not $NodesFile) { throw 'Pass -Nodes (objects with name and service_tag) or -NodesFile (see config/simplified-provisioning/nodes.example.json).' }
        $Nodes = Import-ZtpNodeFile -Path $NodesFile
    }
    $field = {
        param($Object, [string]$Key)
        if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Key)) { return [string]$Object[$Key] } return '' }
        $property = $Object.PSObject.Properties[$Key]
        if ($property) { return [string]$property.Value }
        return ''
    }
    $list = foreach ($node in $Nodes) {
        $name = & $field $node 'name'
        $serial = & $field $node 'service_tag'
        if (-not $serial) { $serial = & $field $node 'serial' }
        $bmc = & $field $node 'bmc_address'
        if (-not $bmc) { $bmc = & $field $node 'bmc_ip' }
        [pscustomobject]@{ Name = $name; Serial = $serial; BmcAddress = $bmc }
    }
    $list = @($list)
    if ($NodeName) {
        $missing = @($NodeName | Where-Object { $_ -notin $list.Name })
        if ($missing.Count -gt 0) { throw "Not in the node list: $($missing -join ', ')" }
        $list = @($list | Where-Object { $_.Name -in $NodeName })
    }
    foreach ($node in $list) {
        if ([string]::IsNullOrWhiteSpace($node.Name)) { throw 'A node has no name.' }
        if ($RequireSerial -and [string]::IsNullOrWhiteSpace($node.Serial)) { throw "Node $($node.Name) has no service_tag (serial number)." }
        if ($node.Serial -and $node.Serial -notmatch '^[A-Za-z0-9-]{1,64}$') { throw "Node $($node.Name) has an unusable serial number." }
    }
    return $list
}

function Get-ZtpBmcTarget {
    <#
    .SYNOPSIS
        BMC targets { Node, Address } for the named nodes: the node list's bmc_address, or -BmcAddress for exactly one node.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][string[]]$NodeName, [object[]]$Nodes, [string]$NodesFile, [string]$BmcAddress)
    if ($BmcAddress) {
        if ($NodeName.Count -ne 1) { throw '-BmcAddress targets one BMC: pass exactly one node name.' }
        return @([pscustomobject]@{ Node = $NodeName[0]; Address = $BmcAddress })
    }
    $known = @(Get-ZtpNodeList -Nodes $Nodes -NodesFile $NodesFile -NodeName $NodeName)
    foreach ($node in $known) {
        if ([string]::IsNullOrWhiteSpace($node.BmcAddress)) { throw "Node $($node.Name) has no bmc_address; add it to the node list or pass -BmcAddress." }
    }
    return @($known | ForEach-Object { [pscustomobject]@{ Node = $_.Name; Address = $_.BmcAddress } })
}
