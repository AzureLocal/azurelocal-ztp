#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Redfish stubs share state with the scripts under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Only public test vectors and synthetic passwords are converted.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stubs mirror the real function signatures.')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# No hardware, no Azure: images are built in TestDrive and every Redfish call goes to in-memory stubs.
BeforeAll {
    $script:root = Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) 'scripts/simplified-provisioning'
    . (Join-Path $script:root 'ZtpVirtualUsb.Common.ps1')
    $script:newImage = Join-Path $script:root 'New-ZtpVirtualUsbImage.ps1'
    $script:readVoucher = Join-Path $script:root 'Read-ZtpVoucherFromImage.ps1'
    $script:mountUsb = Join-Path $script:root 'Mount-ZtpVirtualUsb.ps1'
    $script:waitVoucher = Join-Path $script:root 'Wait-ZtpVoucher.ps1'
    $script:publish = Join-Path $script:root 'Publish-MaintenanceIso.ps1'
    $script:start = Join-Path $script:root 'Start-MaintenanceBoot.ps1'
    $script:nodes = @(
        [pscustomobject]@{ name = 'node-01'; service_tag = 'SERIAL1'; bmc_address = '198.51.100.11' }
        [pscustomobject]@{ name = 'node-02'; service_tag = 'SERIAL2'; bmc_address = '198.51.100.12' }
    )
    $script:bmcCredential = [pscredential]::new('bmc-admin', (ConvertTo-SecureString 'Synthetic-Only-2!' -AsPlainText -Force))

    # A synthetic voucher: PEM around a CBOR array(5) marker plus the serial (the structure the validator checks).
    function New-TestVoucher {
        param([string]$Serial, [byte]$First = 0x85)
        $body = [byte[]](@($First) + [System.Text.Encoding]::ASCII.GetBytes("device-info:$Serial") + [byte[]](1..48))
        $b64 = [Convert]::ToBase64String($body)
        $lines = @('-----BEGIN OWNERSHIP VOUCHER-----') + @(for ($i = 0; $i -lt $b64.Length; $i += 64) { $b64.Substring($i, [math]::Min(64, $b64.Length - $i)) }) + @('-----END OWNERSHIP VOUCHER-----')
        return [System.Text.Encoding]::ASCII.GetBytes(($lines -join "`n") + "`n")
    }
    # A minimal maintenance-media tree (the layout the ISO has; content is synthetic).
    function New-TestMedia {
        param([string]$Path)
        foreach ($dir in 'efi/boot', 'boot/grub2', 'liveos', 'images', 'prov_config/download', 'prov_config/pxe') { $null = New-Item -ItemType Directory -Force -Path (Join-Path $Path $dir) }
        Set-Content -LiteralPath (Join-Path $Path 'efi/boot/bootx64.efi') -Value ('M' * 3000) -NoNewline
        Set-Content -LiteralPath (Join-Path $Path 'boot/grub2/grub.cfg') -Value 'search --no-floppy --label CDROM --set root' -NoNewline
        [System.IO.File]::WriteAllBytes((Join-Path $Path 'liveos/rootfs.img'), [byte[]](1..70000 | ForEach-Object { $_ % 253 }))
        Set-Content -LiteralPath (Join-Path $Path 'prov_config/download/download.txt') -Value 'download' -NoNewline
        Set-Content -LiteralPath (Join-Path $Path 'prov_config/pxe/roesetup.json') -Value '{}' -NoNewline
        Set-Content -LiteralPath (Join-Path $Path 'boot.catalog') -Value 'c' -NoNewline
        return $Path
    }
    # Builds a 40 MiB image (512-byte clusters keep it FAT32-sized) with optional extra files such as vouchers.
    function New-TestImage {
        param([string]$Path, [hashtable]$Extra = @{})
        $media = New-TestMedia -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString()))
        $null = Build-ZtpFat32Image -SourcePath $media -OutputPath $Path -SizeBytes 40MB -ClusterSize 512 -ExtraFiles $Extra
        return $Path
    }
    $script:media = New-TestMedia -Path (Join-Path $TestDrive 'media')

    # Redfish stubs (the signatures of ZtpRedfish.Common.ps1; the scripts dot-source the real file only when these are absent).
    $global:usbCalls = [System.Collections.Generic.List[object]]::new()
    $global:usbSlot = $null
    $global:usbPower = 'On'
    $global:usbReportProtection = $true
    $global:usbForceProtected = $false
    $global:usbAddresses = [System.Collections.Generic.List[string]]::new()
    function global:New-ZtpRedfishSession { param([string]$BmcAddress, [pscredential]$Credential, [switch]$SkipCertificateCheck) $global:usbCalls.Add('session'); $global:usbAddresses.Add($BmcAddress); 'test-session' }
    function global:Remove-ZtpRedfishSession { param($Session) $global:usbCalls.Add('removed') }
    function global:Get-ZtpRedfishManager { param($Session, [string]$ManagerId) [pscustomobject]@{ '@odata.id' = '/manager' } }
    function global:Get-ZtpRedfishSystem { param($Session, [string]$SystemId) [pscustomobject]@{ '@odata.id' = '/system' } }
    function global:Get-ZtpRedfishMember {
        param($Session, [string]$CollectionPath, [string]$Id)
        @([pscustomobject]@{ '@odata.id' = '/vm/CD'; MediaTypes = @('CD', 'DVD'); Inserted = $false; Image = $null; WriteProtected = $null }, (Get-TestUsbSlot))
    }
    function global:Get-TestUsbSlot {
        $slot = [ordered]@{ '@odata.id' = '/vm/RemovableDisk'; MediaTypes = @('USBStick'); Inserted = [bool]$global:usbSlot; Image = $global:usbSlot }
        if ($global:usbReportProtection) { $slot.WriteProtected = if ($global:usbSlot) { $global:usbProtected } else { $null } }
        [pscustomobject]$slot
    }
    function global:Invoke-ZtpRedfish {
        param($Session, [string]$Path, [string]$Method = 'Get', [hashtable]$Body, [int]$MaxAttempts)
        $record = $Body   # the same hashtable: proves the script strips the password after the call
        $global:usbCalls.Add([pscustomobject]@{ Path = $Path; Method = $Method; Body = $record })
        if ($Path -like '*InsertMedia') { $global:usbSlot = $Body.Image; $global:usbProtected = ($global:usbForceProtected ? $true : [bool]$Body.WriteProtected) }
        if ($Path -like '*EjectMedia') { $global:usbSlot = $null }
        if ($Method -eq 'Get' -and $Path -eq '/vm/RemovableDisk') { return (Get-TestUsbSlot) }
        if ($Method -eq 'Get' -and $Path -eq '/system') { return [pscustomobject]@{ PowerState = $global:usbPower; Boot = [pscustomobject]@{ BootSourceOverrideEnabled = 'Once'; BootSourceOverrideTarget = 'Usb' } } }
        if ($Method -eq 'Get' -and $Path -eq '/manager/Attributes') { return [pscustomobject]@{ Attributes = [pscustomobject]@{ 'RFS.1.WriteProtected' = 'Read Only'; 'RFS.2.WriteProtected' = 'Read Only'; 'RFS.1.Enable' = 'Enabled' } } }
    }
}

AfterAll {
    Remove-Variable usbCalls, usbAddresses, usbSlot, usbPower, usbReportProtection, usbForceProtected, usbProtected -Scope Global -ErrorAction SilentlyContinue
    foreach ($name in @('New-ZtpRedfishSession', 'Remove-ZtpRedfishSession', 'Get-ZtpRedfishManager', 'Get-ZtpRedfishSystem', 'Get-ZtpRedfishMember', 'Get-TestUsbSlot', 'Invoke-ZtpRedfish')) {
        Remove-Item "Function:global:$name" -ErrorAction SilentlyContinue
    }
}

Describe 'edgeuser password hash (SHA-512 crypt)' {
    It 'matches the public test vector <Salt>' -TestCases @(
        @{ Phrase = 'Hello world!'; Salt = 'saltstring'; Rounds = 0; Expected = '$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1' }
        @{ Phrase = 'Hello world!'; Salt = 'saltstringsaltst'; Rounds = 10000; Expected = '$6$rounds=10000$saltstringsaltst$OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sbHbbMCVNSnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v.' }
        @{ Phrase = 'This is just a test'; Salt = 'toolongsaltstrin'; Rounds = 5000; Expected = '$6$rounds=5000$toolongsaltstrin$lQ8jolhgVRVhY4b5pZKaysCLi0QBxGoNeKQzQ3glMhwllF7oGDZxUhx1yxdYcz/e1JSbq3y6JMxxl8audkUEm0' }
    ) {
        param($Phrase, $Salt, $Rounds, $Expected)
        $secure = ConvertTo-SecureString $Phrase -AsPlainText -Force
        $hash = if ($Rounds) { ConvertTo-ZtpSha512CryptHash -Password $secure -Salt $Salt -Rounds $Rounds } else { ConvertTo-ZtpSha512CryptHash -Password $secure -Salt $Salt }
        $hash | Should -BeExactly $Expected
    }

    It 'uses the default-rounds form the maintenance environment accepts and a random salt' {
        $secure = ConvertTo-SecureString 'Synthetic-Only-Passw0rd!' -AsPlainText -Force
        $a = ConvertTo-ZtpSha512CryptHash -Password $secure
        $b = ConvertTo-ZtpSha512CryptHash -Password $secure
        Test-ZtpPasswordHashFormat -Hash $a | Should -BeTrue
        $a | Should -Not -Be $b
        $a | Should -Not -Match 'rounds='
        Test-ZtpPasswordHashFormat -Hash '$6$rounds=5000$abc$def' | Should -BeFalse
    }
}

Describe 'Image primitives' {
    It 'computes the IEEE CRC-32 check value' {
        Get-ZtpCrc32 -Bytes ([System.Text.Encoding]::ASCII.GetBytes('123456789')) | Should -Be 0xCBF43926u
    }

    It 'keeps an upper-case 8.3 name and aliases a long or lower-case name' {
        $taken = [System.Collections.Generic.HashSet[string]]::new()
        (Get-ZtpShortName -Name 'SERIAL1' -Taken $taken).NeedsLongName | Should -BeFalse
        $long = Get-ZtpShortName -Name 'grub.cfg' -Taken $taken
        $long.NeedsLongName | Should -BeTrue
        $long.Short | Should -Be 'GRUB~1  CFG'
        (Get-ZtpShortName -Name 'Grub.cfg' -Taken $taken).Short | Should -Be 'GRUB~2  CFG'
    }

    It 'refuses a size that cannot hold a FAT32 volume' {
        { Get-ZtpFat32Geometry -SizeBytes 32MB -ClusterSize 4096 } | Should -Throw '*at least 65525*'
        { Get-ZtpFat32Geometry -SizeBytes (40MB + 1) -ClusterSize 512 } | Should -Throw '*whole number of MiB*'
    }

    It 'writes GPT with one Basic Data partition at 1 MiB and a FAT32 volume labelled CDROM' {
        $path = New-TestImage -Path (Join-Path $TestDrive 'layout.img')
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[450] | Should -Be 0xEE
        [System.Text.Encoding]::ASCII.GetString($bytes, 512, 8) | Should -Be 'EFI PART'
        $header = [byte[]]$bytes[512..(512 + 91)]
        $stored = [BitConverter]::ToUInt32($header, 16)
        [Array]::Clear($header, 16, 4)
        Get-ZtpCrc32 -Bytes $header | Should -Be $stored
        [guid]::new([byte[]]$bytes[1024..1039]) | Should -Be ([guid]'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7')
        [BitConverter]::ToUInt64($bytes, 1024 + 32) | Should -Be 2048
        [guid]::new([byte[]]$bytes[(1024 + 128)..(1024 + 143)]) | Should -Be ([guid]::Empty)
        [System.Text.Encoding]::ASCII.GetString($bytes, 2048 * 512 + 82, 8) | Should -Be 'FAT32   '
        [System.Text.Encoding]::ASCII.GetString($bytes, $bytes.Length - 512, 8) | Should -Be 'EFI PART'
        $volume = Open-ZtpFat32Volume -Path $path
        try { $volume.Label | Should -Be 'CDROM' } finally { Close-ZtpFat32Volume -Volume $volume }
    }

    It 'round-trips names, folders and file contents through the reader' {
        $path = New-TestImage -Path (Join-Path $TestDrive 'roundtrip.img') -Extra @{ 'vouchers/SERIAL1/A Long Voucher Name.pem' = (New-TestVoucher -Serial 'SERIAL1') }
        $volume = Open-ZtpFat32Volume -Path $path
        try {
            $tree = Get-ZtpFat32Tree -Volume $volume
            @($tree.Path) | Should -Contain '/efi/boot/bootx64.efi'
            @($tree.Path) | Should -Contain '/prov_config/pxe/roesetup.json'
            @($tree.Path) | Should -Contain '/vouchers/SERIAL1/A Long Voucher Name.pem'
            $rootfs = $tree | Where-Object Path -EQ '/liveos/rootfs.img'
            $read = Read-ZtpFat32File -Volume $volume -Entry $rootfs -MaxBytes 1MB
            [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($read)) | Should -Be (Get-FileHash (Join-Path $script:media 'liveos/rootfs.img')).Hash
        }
        finally { Close-ZtpFat32Volume -Volume $volume }
    }

    It 'fails clearly when the content does not fit' {
        $big = Join-Path $TestDrive 'big'
        $null = New-Item -ItemType Directory -Path $big
        $stream = [System.IO.File]::Create((Join-Path $big 'large.bin'))
        $stream.SetLength(45MB)
        $stream.Dispose()
        { Build-ZtpFat32Image -SourcePath $big -OutputPath (Join-Path $TestDrive 'toosmall.img') -SizeBytes 40MB -ClusterSize 512 } | Should -Throw '*Image too small*'
    }
}

Describe 'New-ZtpVirtualUsbImage.ps1' {
    It 'prints a plan and writes nothing without Execute' {
        $out = Join-Path $TestDrive 'plan.img'
        $plan = @(& $script:newImage -SourcePath $script:media -OutputPath $out -SizeBytes 40MB -ClusterSize 512)
        ($plan -join "`n") | Should -Match 'one FAT32 partition labelled CDROM'
        ($plan -join "`n") | Should -Match 'edgeuser stays locked'
        Test-Path $out | Should -BeFalse
    }

    It 'builds one image with the edgeuser hash file and returns its SHA-256' {
        $out = Join-Path $TestDrive 'single.img'
        $secure = ConvertTo-SecureString 'Synthetic-Only-Passw0rd!' -AsPlainText -Force
        $result = & $script:newImage -SourcePath $script:media -OutputPath $out -SizeBytes 40MB -ClusterSize 512 -EdgeUserPassword $secure -Execute -Confirm:$false
        $result.Sha256 | Should -Be (Get-FileHash $out).Hash
        $result.EdgeUserPasswordSet | Should -BeTrue
        $volume = Open-ZtpFat32Volume -Path $out
        try {
            $entry = Get-ZtpFat32Tree -Volume $volume | Where-Object Path -EQ '/prov_config/download/hash_password.txt'
            $text = [System.Text.Encoding]::ASCII.GetString((Read-ZtpFat32File -Volume $volume -Entry $entry))
            Test-ZtpPasswordHashFormat -Hash $text | Should -BeTrue
            $text | Should -Not -Match "[`r`n]"
            $text | Should -Not -Match 'Synthetic'
            @((Get-ZtpFat32Tree -Volume $volume).Path) | Should -Contain '/prov_config/download/download.txt'
        }
        finally { Close-ZtpFat32Volume -Volume $volume }
    }

    It 'builds one identical image per node, named from the node names' {
        $dir = Join-Path $TestDrive 'pernode'
        $rows = @(& $script:newImage -SourcePath $script:media -NodeName node-01, node-02 -OutputDirectory $dir -SizeBytes 40MB -ClusterSize 512 -Execute -Confirm:$false)
        $rows.Count | Should -Be 2
        $rows[0].ImagePath | Should -BeLike '*ztp-usb-node-01.img'
        $rows[1].ImagePath | Should -BeLike '*ztp-usb-node-02.img'
        (Get-FileHash $rows[1].ImagePath).Hash | Should -Be $rows[0].Sha256
        $rows[0].EdgeUserPasswordSet | Should -BeFalse
    }

    It 'refuses to overwrite without Force and replaces with Force' {
        $out = Join-Path $TestDrive 'exists.img'
        Set-Content -LiteralPath $out -Value 'x'
        { & $script:newImage -SourcePath $script:media -OutputPath $out -SizeBytes 40MB -ClusterSize 512 -Execute -Confirm:$false } | Should -Throw '*Refusing to overwrite*'
        $null = & $script:newImage -SourcePath $script:media -OutputPath $out -SizeBytes 40MB -ClusterSize 512 -Force -Execute -Confirm:$false
        (Get-Item $out).Length | Should -Be 40MB
    }

    It 'rejects a node name that is unusable in a file name and a source that is neither ISO nor folder' {
        { & $script:newImage -SourcePath $script:media -NodeName 'bad name' -OutputDirectory $TestDrive } | Should -Throw '*not usable in a file name*'
        $file = Join-Path $TestDrive 'media.vhdx'
        Set-Content -LiteralPath $file -Value 'x'
        { & $script:newImage -SourcePath $file -OutputPath (Join-Path $TestDrive 'x.img') } | Should -Throw '*maintenance ISO or a folder*'
    }
}

Describe 'Read-ZtpVoucherFromImage.ps1' {
    BeforeAll {
        $script:imageDir = Join-Path $TestDrive 'images'
        $null = New-Item -ItemType Directory -Path $script:imageDir
        # The export layout of the maintenance environment: the voucher next to response.json and systeminfo.
        $null = New-TestImage -Path (Join-Path $script:imageDir 'ztp-usb-node-01.img') -Extra @{
            'vouchers/SERIAL1/SERIAL1.pem'   = (New-TestVoucher -Serial 'SERIAL1')
            'vouchers/SERIAL1/response.json' = [System.Text.Encoding]::ASCII.GetBytes('{}')
            'vouchers/SERIAL1/systeminfo'    = [byte[]](1, 2)
        }
        $null = New-TestImage -Path (Join-Path $script:imageDir 'ztp-usb-node-02.img') -Extra @{ 'vouchers/SERIAL2/device.pem' = (New-TestVoucher -Serial 'SERIAL2') }
    }

    It 'extracts each node''s voucher as SERIAL.pem and leaves the images unchanged' {
        $before = (Get-FileHash (Join-Path $script:imageDir 'ztp-usb-node-01.img')).Hash
        $out = Join-Path $TestDrive 'vouchers-out'
        $rows = @(& $script:readVoucher -NodeName node-01, node-02 -Nodes $script:nodes -ImageDirectory $script:imageDir -OutputDirectory $out)
        @($rows | Where-Object Valid).Count | Should -Be 2
        ($rows | Where-Object Node -EQ 'node-01').SourcePath | Should -Be '/vouchers/SERIAL1/SERIAL1.pem'
        ($rows | Where-Object Node -EQ 'node-02').SourcePath | Should -Be '/vouchers/SERIAL2/device.pem'
        (Get-FileHash (Join-Path $out 'SERIAL2.pem')).Hash | Should -Be ([Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData((New-TestVoucher -Serial 'SERIAL2'))))
        Test-Path (Join-Path $out 'SERIAL1.pem') | Should -BeTrue
        (Get-FileHash (Join-Path $script:imageDir 'ztp-usb-node-01.img')).Hash | Should -Be $before
        ($rows | Out-String) | Should -Not -Match 'BEGIN OWNERSHIP'
    }

    It 'lists without writing when no output folder is given, and refuses to replace a different file' {
        $rows = @(& $script:readVoucher -ImagePath (Join-Path $script:imageDir 'ztp-usb-node-02.img') -Nodes $script:nodes)
        $rows[0].OutputFile | Should -BeNullOrEmpty
        $out = Join-Path $TestDrive 'conflict'
        $null = New-Item -ItemType Directory -Path $out
        Set-Content -LiteralPath (Join-Path $out 'SERIAL2.pem') -Value 'other'
        { & $script:readVoucher -ImagePath (Join-Path $script:imageDir 'ztp-usb-node-02.img') -Nodes $script:nodes -OutputDirectory $out } | Should -Throw '*different content*'
    }

    It 'throws when an expected node has no voucher yet' {
        $empty = Join-Path $TestDrive 'empty'
        $null = New-Item -ItemType Directory -Path $empty
        $null = New-TestImage -Path (Join-Path $empty 'ztp-usb-node-01.img')
        { & $script:readVoucher -NodeName node-01 -Nodes $script:nodes -ImageDirectory $empty } | Should -Throw '*node-01: no valid voucher*'
    }

    It 'rejects a voucher that does not carry the node''s serial or is not an FDO voucher' {
        $dir = Join-Path $TestDrive 'invalid'
        $null = New-Item -ItemType Directory -Path $dir
        $null = New-TestImage -Path (Join-Path $dir 'ztp-usb-node-01.img') -Extra @{ 'vouchers/SERIAL1/SERIAL1.pem' = (New-TestVoucher -Serial 'SERIAL9') }
        { & $script:readVoucher -NodeName node-01 -Nodes $script:nodes -ImageDirectory $dir } | Should -Throw '*serial number SERIAL1 is not in the voucher*'
        (Test-ZtpOwnershipVoucher -Bytes (New-TestVoucher -Serial 'SERIAL1' -First 0xA1) -Serial 'SERIAL1').Problems | Should -Match 'CBOR array'
        (Test-ZtpOwnershipVoucher -Bytes ([System.Text.Encoding]::ASCII.GetBytes("-----BEGIN CERTIFICATE-----`nAA==`n-----END CERTIFICATE-----")) -Serial 'SERIAL1').Valid | Should -BeFalse
    }

    It 'flags an image that holds another node''s voucher' {
        $dir = Join-Path $TestDrive 'swapped'
        $null = New-Item -ItemType Directory -Path $dir
        $null = New-TestImage -Path (Join-Path $dir 'ztp-usb-node-01.img') -Extra @{ 'vouchers/SERIAL2/SERIAL2.pem' = (New-TestVoucher -Serial 'SERIAL2') }
        { & $script:readVoucher -NodeName node-01 -Nodes $script:nodes -ImageDirectory $dir } | Should -Throw '*built for node-01 holds the voucher of node-02*'
    }

    It 'maps a vouchers GUID folder by the serial inside the voucher and reports a .pem outside the vouchers folder' {
        $path = New-TestImage -Path (Join-Path $TestDrive 'guid.img') -Extra @{
            'vouchers/00000000-0000-0000-0000-000000000000/x.pem' = (New-TestVoucher -Serial 'SERIAL2')
            'certs/other.pem' = (New-TestVoucher -Serial 'SERIAL1')
        }
        $rows = @(& $script:readVoucher -ImagePath $path -Nodes $script:nodes -ReportOnly -WarningAction SilentlyContinue)
        ($rows | Where-Object Valid).Node | Should -Be 'node-02'
        ($rows | Where-Object { $_.SourcePath -eq '/certs/other.pem' }).Problem | Should -Match 'outside'
    }

    It 'refuses to read an image another process holds open for writing, unless AllowOpenImage' {
        $path = Join-Path $script:imageDir 'ztp-usb-node-02.img'
        $writer = [System.IO.File]::Open($path, 'Open', 'ReadWrite', 'ReadWrite')
        try {
            { & $script:readVoucher -ImagePath $path -Nodes $script:nodes } | Should -Throw '*eject the virtual media first*'
            @(& $script:readVoucher -ImagePath $path -Nodes $script:nodes -AllowOpenImage)[0].Valid | Should -BeTrue
        }
        finally { $writer.Dispose() }
    }
}

Describe 'Mount-ZtpVirtualUsb.ps1' {
    BeforeEach {
        $global:usbCalls.Clear()
        $global:usbSlot = $null
        $global:usbPower = 'On'
        $global:usbReportProtection = $true
        $global:usbForceProtected = $false
        Mock Start-Sleep {}
        $script:shareCredential = [pscredential]::new('HOST\svc-ztp-media', (ConvertTo-SecureString 'Synthetic-Only-1!' -AsPlainText -Force))
    }

    It 'opens no session without Execute and plans a read-write insert per node' {
        $plan = @(& $script:mountUsb -Nodes $script:nodes -Credential $script:bmcCredential -NodeName node-01, node-02 -ShareHost 192.0.2.10)
        $global:usbCalls.Count | Should -Be 0
        ($plan -join "`n") | Should -Match ([regex]::Escape('//192.0.2.10/ztp-virtual-usb/ztp-usb-node-02.img'))
        ($plan -join "`n") | Should -Match 'WriteProtected=False'
    }

    It 'inserts the node''s image read-write over CIFS, proves it, boots once from USB and keeps no password' {
        $row = & $script:mountUsb -Nodes $script:nodes -Credential $script:bmcCredential -NodeName node-01 -ShareHost 192.0.2.10 -ShareCredential $script:shareCredential -Execute -Confirm:$false
        $writes = @($global:usbCalls | Where-Object { $_ -isnot [string] -and $_.Method -ne 'Get' })
        $writes[0].Path | Should -Be '/vm/RemovableDisk/Actions/VirtualMedia.InsertMedia'
        $writes[0].Body.Image | Should -Be '//192.0.2.10/ztp-virtual-usb/ztp-usb-node-01.img'
        $writes[0].Body.WriteProtected | Should -BeFalse
        $writes[0].Body.TransferProtocolType | Should -Be 'CIFS'
        $writes[0].Body.UserName | Should -Be 'HOST\svc-ztp-media'
        $writes[1].Method | Should -Be 'Patch'
        $writes[1].Body.Boot.BootSourceOverrideTarget | Should -Be 'Usb'
        $row.WriteProtected | Should -BeFalse
        $global:usbCalls | Should -Contain 'removed'
        ($global:usbCalls | Where-Object { $_ -isnot [string] -and $_.Body } | ForEach-Object { $_.Body | ConvertTo-Json -Depth 5 }) -join "`n" | Should -Not -Match 'Synthetic-Only'
    }

    It 'fails when the iDRAC attaches the image write-protected, and still removes the session' {
        $global:usbForceProtected = $true
        { & $script:mountUsb -Nodes $script:nodes -Credential $script:bmcCredential -NodeName node-01 -ShareHost 192.0.2.10 -Execute -Confirm:$false } | Should -Throw '*WriteProtected=True*RfsWriteAttribute*'
        $global:usbCalls | Should -Contain 'removed'
        @($global:usbCalls | Where-Object { $_ -isnot [string] -and $_.Method -eq 'Patch' }).Count | Should -Be 0
    }

    It 'sets the RFS write attributes before the insert with RfsWriteAttribute' {
        $null = & $script:mountUsb -Nodes $script:nodes -Credential $script:bmcCredential -NodeName node-01 -ShareHost 192.0.2.10 -RfsWriteAttribute -Execute -Confirm:$false
        $writes = @($global:usbCalls | Where-Object { $_ -isnot [string] -and $_.Method -ne 'Get' })
        $writes[0].Path | Should -Be '/manager/Attributes'
        $writes[0].Body.Attributes['RFS.1.WriteProtected'] | Should -Be 'Read Write'
        $writes[0].Body.Attributes['RFS.2.WriteProtected'] | Should -Be 'Read Write'
        $writes[0].Body.Attributes.ContainsKey('RFS.1.Enable') | Should -BeFalse
        $writes[1].Path | Should -BeLike '*InsertMedia'
    }

    It 'power-cycles with ForceRestart when on and powers on when off, only with confirmation' {
        { & $script:mountUsb -Nodes $script:nodes -Credential $script:bmcCredential -NodeName node-01 -ShareHost 192.0.2.10 -Restart -Execute } | Should -Throw '*ConfirmNotClustered*'
        $global:usbCalls.Count | Should -Be 0
        $null = & $script:mountUsb -Nodes $script:nodes -Credential $script:bmcCredential -NodeName node-01 -ShareHost 192.0.2.10 -Restart -ConfirmNotClustered -Execute -Confirm:$false
        ($global:usbCalls | Where-Object { $_ -isnot [string] -and $_.Path -like '*ComputerSystem.Reset' }).Body.ResetType | Should -Be 'ForceRestart'
        $global:usbCalls.Clear()
        $global:usbSlot = $null
        $global:usbPower = 'Off'
        $null = & $script:mountUsb -Nodes $script:nodes -Credential $script:bmcCredential -NodeName node-01 -ShareHost 192.0.2.10 -Restart -ConfirmNotClustered -Execute -Confirm:$false
        ($global:usbCalls | Where-Object { $_ -isnot [string] -and $_.Path -like '*ComputerSystem.Reset' }).Body.ResetType | Should -Be 'On'
    }

    It 'leaves its own image inserted on a rerun and replaces another image' {
        $global:usbSlot = '//192.0.2.10/ztp-virtual-usb/ztp-usb-node-01.img'
        $global:usbProtected = $false
        $null = & $script:mountUsb -Nodes $script:nodes -Credential $script:bmcCredential -NodeName node-01 -ShareHost 192.0.2.10 -Execute -Confirm:$false
        @($global:usbCalls | Where-Object { $_ -isnot [string] -and $_.Path -like '*Media' }).Count | Should -Be 0
        $global:usbCalls.Clear()
        $global:usbSlot = '//192.0.2.99/other/else.img'
        $null = & $script:mountUsb -Nodes $script:nodes -Credential $script:bmcCredential -NodeName node-01 -ShareHost 192.0.2.10 -Execute -Confirm:$false
        $media = @($global:usbCalls | Where-Object { $_ -isnot [string] -and $_.Path -like '*Media' })
        $media[0].Path | Should -BeLike '*EjectMedia'
        $media[1].Path | Should -BeLike '*InsertMedia'
    }

    It 'ejects only the node''s own image unless Force' {
        $global:usbSlot = '//192.0.2.99/other/else.img'
        $row = & $script:mountUsb -Nodes $script:nodes -Credential $script:bmcCredential -NodeName node-01 -Action Eject -Execute -Confirm:$false -WarningAction SilentlyContinue
        $row.Action | Should -Be 'NotInserted'
        @($global:usbCalls | Where-Object { $_ -isnot [string] -and $_.Path -like '*EjectMedia' }).Count | Should -Be 0
        $global:usbSlot = '//192.0.2.10/ztp-virtual-usb/ztp-usb-node-01.img'
        $global:usbProtected = $false
        $row = & $script:mountUsb -Nodes $script:nodes -Credential $script:bmcCredential -NodeName node-01 -Action Eject -RfsWriteAttribute -Execute -Confirm:$false
        $row.Action | Should -Be 'Ejected'
        ($global:usbCalls | Where-Object { $_ -isnot [string] -and $_.Path -eq '/manager/Attributes' -and $_.Method -eq 'Patch' }).Body.Attributes['RFS.1.WriteProtected'] | Should -Be 'Read Only'
    }

    It 'requires the share host to mount' {
        { & $script:mountUsb -Nodes $script:nodes -Credential $script:bmcCredential -NodeName node-01 } | Should -Throw '*ShareHost*'
    }
}

Describe 'Wait-ZtpVoucher.ps1' {
    BeforeAll {
        $script:waitDir = Join-Path $TestDrive 'wait'
        $null = New-Item -ItemType Directory -Path $script:waitDir
        $null = New-TestImage -Path (Join-Path $script:waitDir 'ztp-usb-node-01.img') -Extra @{ 'vouchers/SERIAL1/SERIAL1.pem' = (New-TestVoucher -Serial 'SERIAL1') }
        $null = New-TestImage -Path (Join-Path $script:waitDir 'ztp-usb-node-02.img')
    }
    BeforeEach {
        $global:usbCalls.Clear()
        $global:usbSlot = '//192.0.2.10/ztp-virtual-usb/ztp-usb-node-01.img'
        $global:usbProtected = $false
        Mock Start-Sleep {}
    }

    It 'ejects the ready node''s media with Execute and extracts its voucher' {
        $out = Join-Path $TestDrive 'wait-out'
        $rows = @(& $script:waitVoucher -NodeName node-01 -Nodes $script:nodes -ImageDirectory $script:waitDir -OutputDirectory $out -Credential $script:bmcCredential -Execute -Confirm:$false)
        $rows[0].Valid | Should -BeTrue
        $rows[0].OutputFile | Should -BeLike '*SERIAL1.pem'
        @($global:usbCalls | Where-Object { $_ -isnot [string] -and $_.Path -like '*EjectMedia' }).Count | Should -Be 1
    }

    It 'only plans the eject without Execute' {
        $out = Join-Path $TestDrive 'wait-plan'
        $output = @(& $script:waitVoucher -NodeName node-01 -Nodes $script:nodes -ImageDirectory $script:waitDir -OutputDirectory $out)
        ($output | Where-Object { $_ -is [string] }) | Should -Match 'PLAN: eject'
        $global:usbCalls.Count | Should -Be 0
        Test-Path (Join-Path $out 'SERIAL1.pem') | Should -BeTrue
    }

    It 'times out with the pending node and points to the Configurator App fallback' {
        { & $script:waitVoucher -NodeName node-01, node-02 -Nodes $script:nodes -ImageDirectory $script:waitDir -OutputDirectory (Join-Path $TestDrive 'wait-timeout') -TimeoutMinutes 0 } | Should -Throw '*node-02 (SERIAL2): no \vouchers\ folder yet*VoucherFolder*'
    }

    It 'accepts vouchers downloaded with the Configurator App in folder mode' {
        $manual = Join-Path $TestDrive 'manual'
        $null = New-Item -ItemType Directory -Path (Join-Path $manual 'SERIAL2')
        [System.IO.File]::WriteAllBytes((Join-Path $manual 'SERIAL1.pem'), (New-TestVoucher -Serial 'SERIAL1'))
        [System.IO.File]::WriteAllBytes((Join-Path $manual 'SERIAL2/SERIAL2.pem'), (New-TestVoucher -Serial 'SERIAL2'))
        $out = Join-Path $TestDrive 'manual-out'
        $rows = @(& $script:waitVoucher -NodeName node-01, node-02 -Nodes $script:nodes -VoucherFolder $manual -OutputDirectory $out)
        @($rows | Where-Object Valid).Count | Should -Be 2
        Test-Path (Join-Path $out 'SERIAL2.pem') | Should -BeTrue
    }

    It 'rejects a manual voucher for the wrong serial and writes nothing' {
        $manual = Join-Path $TestDrive 'manual-bad'
        $null = New-Item -ItemType Directory -Path $manual
        [System.IO.File]::WriteAllBytes((Join-Path $manual 'SERIAL1.pem'), (New-TestVoucher -Serial 'SERIAL7'))
        $out = Join-Path $TestDrive 'manual-bad-out'
        { & $script:waitVoucher -NodeName node-01 -Nodes $script:nodes -VoucherFolder $manual -OutputDirectory $out } | Should -Throw '*SERIAL1 is not in the voucher*'
        Test-Path $out | Should -BeFalse
    }
}

Describe 'Read-write share and the virtual-USB boot plan' {
    It 'plans a read-write share that publishes per-node images in place' {
        $dir = Join-Path $TestDrive 'share'
        $null = New-Item -ItemType Directory -Path $dir
        $images = foreach ($n in 'node-01', 'node-02') { $p = Join-Path $dir "ztp-usb-$n.img"; Set-Content -LiteralPath $p -Value 'x'; $p }
        $plan = (& $script:publish -IsoPath $images -SharePath $dir -ShareName ztp-virtual-usb -ShareHost 192.0.2.10 -AllowedBmcAddress 198.51.100.11 -ReadWrite) -join "`n"
        $plan | Should -Match 'in place'
        $plan | Should -Match 'read-write for svc-ztp-media only'
        $plan | Should -Match ([regex]::Escape('//192.0.2.10/ztp-virtual-usb/ztp-usb-node-02.img'))
    }

    It 'never shares an ISO read-write' {
        $iso = Join-Path $TestDrive 'media.iso'
        Set-Content -LiteralPath $iso -Value 'x'
        { & $script:publish -IsoPath $iso -ShareHost 192.0.2.10 -AllowedBmcAddress 198.51.100.11 -ReadWrite } | Should -Throw '*raw USB images*'
    }

    It 'plans the share and the read-write mount for every node from one call' {
        $dir = Join-Path $TestDrive 'boot'
        $null = New-Item -ItemType Directory -Path $dir
        foreach ($n in 'node-01', 'node-02') { Set-Content -LiteralPath (Join-Path $dir "ztp-usb-$n.img") -Value 'x' }
        $global:usbCalls.Clear()
        $plan = (& $script:start -ImageDirectory $dir -ShareHost 192.0.2.10 -NodeName node-01, node-02 -Nodes $script:nodes -Restart -ConfirmNotClustered) -join "`n"
        $plan | Should -Match 'read-write'
        $plan | Should -Match '198\.51\.100\.11, 198\.51\.100\.12'
        $plan | Should -Match 'node-02 insert //192\.0\.2\.10/ztp-virtual-usb/ztp-usb-node-02\.img'
        $global:usbCalls.Count | Should -Be 0
        { & $script:start -ImageDirectory (Join-Path $TestDrive 'nothing') -ShareHost 192.0.2.10 -NodeName node-01 -Nodes $script:nodes } | Should -Throw '*Build the images first*'
    }

    It 'refuses a restart without ConfirmNotClustered and an execute without the BMC credential' {
        $dir = Join-Path $TestDrive 'boot-guard'
        $null = New-Item -ItemType Directory -Path $dir
        Set-Content -LiteralPath (Join-Path $dir 'ztp-usb-node-01.img') -Value 'x'
        { & $script:start -ImageDirectory $dir -ShareHost 192.0.2.10 -NodeName node-01 -Nodes $script:nodes -Restart } | Should -Throw '*ConfirmNotClustered*'
        { & $script:start -ImageDirectory $dir -ShareHost 192.0.2.10 -NodeName node-01 -Nodes $script:nodes -Execute -Confirm:$false } | Should -Throw '*-Credential*'
    }
}

Describe 'Node list and BMC targets' {
    It 'reads a JSON nodes file with the nodes key or a bare array' {
        $wrapped = Join-Path $TestDrive 'nodes-wrapped.json'
        Set-Content -LiteralPath $wrapped -Value '{ "nodes": [ { "name": "node-01", "service_tag": "EXAMPLE1", "bmc_address": "198.51.100.11" } ] }'
        $bare = Join-Path $TestDrive 'nodes-bare.json'
        Set-Content -LiteralPath $bare -Value '[ { "name": "node-02", "serial": "EXAMPLE2", "bmc_ip": "198.51.100.12" } ]'
        $one = @(Get-ZtpNodeList -NodesFile $wrapped -RequireSerial)
        $one[0].Name | Should -Be 'node-01'
        $one[0].Serial | Should -Be 'EXAMPLE1'
        $one[0].BmcAddress | Should -Be '198.51.100.11'
        $two = @(Get-ZtpNodeList -NodesFile $bare)
        $two[0].Serial | Should -Be 'EXAMPLE2'
        $two[0].BmcAddress | Should -Be '198.51.100.12'
    }

    It 'ships a nodes example that loads' {
        $example = Join-Path (Split-Path $script:root -Parent | Split-Path -Parent) 'config/simplified-provisioning/nodes.example.json'
        @(Get-ZtpNodeList -NodesFile $example -RequireSerial).Count | Should -Be 2
    }

    It 'has no hidden lookup: without -Nodes or -NodesFile it throws' {
        { Get-ZtpNodeList -NodeName node-01 } | Should -Throw '*-Nodes*-NodesFile*'
    }

    It 'requires a service tag only when asked and rejects an unusable one' {
        $noTag = @([pscustomobject]@{ name = 'node-01' })
        { Get-ZtpNodeList -Nodes $noTag } | Should -Not -Throw
        { Get-ZtpNodeList -Nodes $noTag -RequireSerial } | Should -Throw '*no service_tag*'
        { Get-ZtpNodeList -Nodes @([pscustomobject]@{ name = 'node-01'; service_tag = 'bad tag!' }) } | Should -Throw '*unusable serial*'
    }

    It 'resolves BMC targets from the node list or from -BmcAddress for one node' {
        (Get-ZtpBmcTarget -NodeName node-02 -Nodes $script:nodes).Address | Should -Be '198.51.100.12'
        (Get-ZtpBmcTarget -NodeName node-01 -BmcAddress 192.0.2.50).Address | Should -Be '192.0.2.50'
        { Get-ZtpBmcTarget -NodeName node-01, node-02 -BmcAddress 192.0.2.50 } | Should -Throw '*exactly one*'
        { Get-ZtpBmcTarget -NodeName node-01 -Nodes @([pscustomobject]@{ name = 'node-01' }) } | Should -Throw '*no bmc_address*'
    }
}

Describe 'BMC account guard' {
    It 'refuses to open a session without -Credential' {
        { & $script:mountUsb -NodeName node-01 -Nodes $script:nodes -ShareHost 192.0.2.10 -Execute -Confirm:$false } | Should -Throw '*-Credential*'
    }

    It 'uses -BmcAddress for exactly one node and the node list address otherwise' {
        $global:usbAddresses.Clear()
        $null = & $script:mountUsb -NodeName node-01 -BmcAddress 192.0.2.50 -Credential $script:bmcCredential -Action Status -Execute -Confirm:$false
        $null = & $script:mountUsb -NodeName node-02 -Nodes $script:nodes -Credential $script:bmcCredential -Action Status -Execute -Confirm:$false
        @($global:usbAddresses) | Should -Be @('192.0.2.50', '198.51.100.12')
    }
}
