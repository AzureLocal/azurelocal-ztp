#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
# The BMC tools: Get-ZtpBmcJob.ps1, Get-ZtpBootSetting.ps1, Reset-ZtpBmc.ps1 and Reset-ZtpBootSequence.ps1. They take the
# infrastructure file (schema 5), never prompt, and take the BMC login from -Credential or from the file's secret
# references through the toolkit's resolver. Every Redfish call and the resolver are in-memory stubs: no BMC, no Azure,
# no toolkit is contacted. Example-company names (iic-*) and documentation addresses only.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Redfish stubs share state with the scripts under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Only a synthetic test credential is converted.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stubs mirror the real function signatures.')]
param()

BeforeAll {
    $script:root = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts/simplified-provisioning'
    $script:jobTool = Join-Path $script:root 'Get-ZtpBmcJob.ps1'
    $script:bootTool = Join-Path $script:root 'Get-ZtpBootSetting.ps1'
    $script:resetBmc = Join-Path $script:root 'Reset-ZtpBmc.ps1'
    $script:resetBoot = Join-Path $script:root 'Reset-ZtpBootSequence.ps1'
    $script:login = [pscredential]::new('iic-bmc-admin', (ConvertTo-SecureString 'Synthetic-Only-7!' -AsPlainText -Force))
    $script:savedToolkitRoot = $env:AZL_TOOLKIT_ROOT
    # No toolkit: the resolver is the stub below, and the reader uses its built-in checks.
    $env:AZL_TOOLKIT_ROOT = Join-Path $TestDrive 'no-toolkit-here'

    $script:writeFile = {
        param([string]$Vendor = 'Dell', [switch]$NoBmcLogin, [switch]$NoBmcAddress, [string]$Verify)
        $lines = @(
            '_metadata:'
            '  schema_version: "5.6.26"'
            'scenario: { os_install: simplified }'
            'key_vaults:'
            '  - { name: "kv-iic-azl", subscription_id: "00000000-0000-0000-0000-000000000000", resource_group: "rg-iic-vault" }'
            'nodes:'
            '  - name: "iic-node-01"'
            '    bmc: { ip_address: "198.51.100.11" }'
            '  - name: "iic-node-02"'
            $(if ($NoBmcAddress) { '    serial_number: "IICSN02"' } else { '    bmc: { ip_address: "198.51.100.12" }' })
            'hardware:'
            "  vendor: `"$Vendor`""
        )
        $bmc = @()
        if (-not $NoBmcLogin) { $bmc += 'username: "keyvault://kv-iic-azl/bmc-username"', 'password: "keyvault://kv-iic-azl/bmc-password"' }
        if ($Verify) { $bmc += "verify_certificate: $Verify" }
        if ($bmc) { $lines += "  bmc: { $($bmc -join ', ') }" }
        $path = Join-Path $TestDrive "iic-infrastructure-$([guid]::NewGuid().ToString('N')).yml"
        Set-Content -LiteralPath $path -Value $lines
        $path
    }
    $script:run = {
        # Runs a tool and splits what it wrote: objects, error messages and the exit code.
        param([string]$Tool, [hashtable]$Arguments)
        $global:LASTEXITCODE = $null
        $all = @(& $Tool @Arguments 2>&1)
        [pscustomobject]@{
            Rows   = @($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] -and $_ -isnot [string] })
            Errors = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.Exception.Message })
            Exit   = $LASTEXITCODE
        }
    }

    # Redfish responses (one iDRAC layout, the same on every BMC).
    $json = @{
        '/redfish/v1/Managers'                                  = '{ "Members": [ { "@odata.id": "/redfish/v1/Managers/iDRAC.Embedded.1" } ] }'
        '/redfish/v1/Managers/iDRAC.Embedded.1'                 = '{ "@odata.id": "/redfish/v1/Managers/iDRAC.Embedded.1", "Id": "iDRAC.Embedded.1", "Actions": { "#Manager.Reset": { "target": "/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Manager.Reset", "ResetType@Redfish.AllowableValues": [ "GracefulRestart" ] } } }'
        '/redfish/v1/Managers/iDRAC.Embedded.1/Jobs'            = '{ "Members": [ { "@odata.id": "/redfish/v1/Managers/iDRAC.Embedded.1/Jobs/JID_100" }, { "@odata.id": "/redfish/v1/Managers/iDRAC.Embedded.1/Jobs/JID_200" } ] }'
        '/redfish/v1/Managers/iDRAC.Embedded.1/Jobs/JID_100'    = '{ "Id": "JID_100", "Name": "Configure: BIOS.Setup.1-1", "JobType": "BIOSConfiguration", "JobState": "Completed", "PercentComplete": 100, "Message": "Job completed successfully.", "StartTime": "2020-01-01T00:00:00Z" }'
        '/redfish/v1/Systems'                                   = '{ "Members": [ { "@odata.id": "/redfish/v1/Systems/System.Embedded.1" } ] }'
        '/redfish/v1/Systems/System.Embedded.1'                 = '{ "@odata.id": "/redfish/v1/Systems/System.Embedded.1", "PowerState": "On", "Boot": { "BootSourceOverrideEnabled": "Once", "BootSourceOverrideTarget": "Usb", "BootSourceOverrideMode": "UEFI", "BootOrder": [ "Boot0001", "Boot0002" ], "BootOptions": { "@odata.id": "/redfish/v1/Systems/System.Embedded.1/BootOptions" } } }'
        '/redfish/v1/Systems/System.Embedded.1/BootOptions'     = '{ "Members": [ { "@odata.id": "/redfish/v1/Systems/System.Embedded.1/BootOptions/Boot0001" }, { "@odata.id": "/redfish/v1/Systems/System.Embedded.1/BootOptions/Boot0002" } ] }'
        '/redfish/v1/Systems/System.Embedded.1/BootOptions/Boot0001' = '{ "Id": "Boot0001", "DisplayName": "Unavailable: Windows Boot Manager", "BootOptionEnabled": true, "BootOptionReference": "Boot0001" }'
        '/redfish/v1/Systems/System.Embedded.1/BootOptions/Boot0002' = '{ "Id": "Boot0002", "DisplayName": "BOSS Card Virtual Disk", "BootOptionEnabled": true, "BootOptionReference": "Boot0002" }'
        '/redfish/v1/Systems/System.Embedded.1/Bios'            = '{ "Attributes": { "SysPrepClean": "None", "BootMode": "Uefi" } }'
    }
    $global:bmcT_responses = @{}
    foreach ($k in $json.Keys) { $global:bmcT_responses[$k] = $json[$k] | ConvertFrom-Json }
    $global:bmcT_calls = [System.Collections.Generic.List[object]]::new()

    function global:New-ZtpRedfishSession {
        param([string]$BmcAddress, [pscredential]$Credential, [switch]$SkipCertificateCheck)
        if ($global:bmcT_sessionFail -eq $BmcAddress) { throw "Cannot reach the Redfish service of $BmcAddress (synthetic)" }
        $global:bmcT_calls.Add([pscustomobject]@{ Bmc = $BmcAddress; Method = 'Session'; Path = $Credential.UserName; Body = [bool]$SkipCertificateCheck })
        [pscustomobject]@{ BmcAddress = $BmcAddress }
    }
    function global:Remove-ZtpRedfishSession { param($Session) $global:bmcT_calls.Add([pscustomobject]@{ Bmc = $Session.BmcAddress; Method = 'Close'; Path = $null; Body = $null }) }
    function global:Invoke-ZtpRedfish {
        param([object]$Session, [string]$Path, [string]$Method = 'Get', [hashtable]$Body, [int]$MaxAttempts = 3)
        $global:bmcT_calls.Add([pscustomobject]@{ Bmc = $Session.BmcAddress; Method = $Method; Path = $Path; Body = $Body })
        if ($global:bmcT_failPath -and $Path -like $global:bmcT_failPath) { throw "Redfish $Method $Path on $($Session.BmcAddress) failed with HTTP 400 (synthetic)" }
        if ($Method -ne 'Get') { return $null }
        if ($Path -eq '/redfish/v1/Managers/iDRAC.Embedded.1/Jobs/JID_200') {
            # Running until $global:bmcT_runningReads reads have passed, then Completed.
            $global:bmcT_jobReads++
            $state = if ($global:bmcT_jobReads -le $global:bmcT_runningReads) { 'Running' } else { 'Completed' }
            return [pscustomobject]@{ Id = 'JID_200'; Name = 'Configure: BIOS.Setup.1-1'; JobType = 'BIOSConfiguration'; JobState = $state; PercentComplete = 50; Message = 'Task successfully scheduled.'; StartTime = [datetime]::UtcNow.ToString('o') }
        }
        if (-not $global:bmcT_responses.ContainsKey($Path)) { throw "Redfish Get $Path on $($Session.BmcAddress) failed with HTTP 404 (synthetic)" }
        return $global:bmcT_responses[$Path]
    }
    # The toolkit's resolver: records the call and returns the login, or fails like a secret that cannot be read.
    function global:Resolve-AzlBmcCredential {
        param([pscredential]$Credential, [System.Collections.IDictionary]$Infrastructure, [System.Collections.IDictionary]$Node)
        $global:bmcT_calls.Add([pscustomobject]@{ Bmc = $null; Method = 'Resolve'; Path = [string]$Infrastructure['hardware']['bmc']['password']; Body = $null })
        if ($global:bmcT_resolverFail) { throw 'No BMC credential: the secret could not be read: keyvault://kv-iic-azl/bmc-password: access denied (synthetic).' }
        [pscredential]::new('iic-bmc-from-vault', (ConvertTo-SecureString 'Synthetic-Only-8!' -AsPlainText -Force))
    }
    # The real collection helpers of ZtpRedfish.Common.ps1, defined globally so they call the stubs above.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:root 'ZtpRedfish.Common.ps1'), [ref]$null, [ref]$null)
    foreach ($f in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        if ($f.Name -in 'Get-ZtpRedfishManager', 'Get-ZtpRedfishSystem', 'Get-ZtpRedfishMember') { Set-Item -Path "Function:global:$($f.Name)" -Value $f.Body.GetScriptBlock() }
    }
    $script:stubs = 'New-ZtpRedfishSession', 'Remove-ZtpRedfishSession', 'Invoke-ZtpRedfish', 'Resolve-AzlBmcCredential', 'Get-ZtpRedfishManager', 'Get-ZtpRedfishSystem', 'Get-ZtpRedfishMember'
    $script:sent = { @($global:bmcT_calls | Where-Object { $_.Method -notin 'Get', 'Session', 'Close', 'Resolve' }) }
    $script:reset = {
        $global:bmcT_calls.Clear()
        $global:bmcT_sessionFail = $null
        $global:bmcT_failPath = $null
        $global:bmcT_resolverFail = $false
        $global:bmcT_jobReads = 0
        $global:bmcT_runningReads = 1000
    }
}

AfterAll {
    foreach ($name in $script:stubs) { Remove-Item "Function:global:$name" -ErrorAction SilentlyContinue }
    Remove-Variable -Scope Global -Name bmcT_responses, bmcT_calls, bmcT_sessionFail, bmcT_failPath, bmcT_resolverFail, bmcT_jobReads, bmcT_runningReads -ErrorAction SilentlyContinue
    $env:AZL_TOOLKIT_ROOT = $script:savedToolkitRoot
}

Describe 'The BMC tools: inputs, never a prompt' {
    BeforeEach { & $script:reset }

    It '<_> has a mandatory -InfrastructureFile, a [pscredential] -Credential, and no Read-Host or Get-Credential' -ForEach 'Get-ZtpBmcJob.ps1', 'Get-ZtpBootSetting.ps1', 'Reset-ZtpBmc.ps1', 'Reset-ZtpBootSequence.ps1' {
        $path = Join-Path $script:root $_
        $command = Get-Command $path
        $file = $command.Parameters['InfrastructureFile']
        @($file.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count | Should -BeGreaterThan 0
        $command.Parameters['Credential'].ParameterType | Should -Be ([pscredential])
        (Get-Content -LiteralPath $path -Raw) | Should -Not -Match 'Read-Host|Get-Credential'
    }

    It 'the changing tools support -WhatIf: <_>' -ForEach 'Reset-ZtpBmc.ps1', 'Reset-ZtpBootSequence.ps1' {
        (Get-Command (Join-Path $script:root $_)).Parameters.ContainsKey('WhatIf') | Should -BeTrue
    }

    It 'stops with exit code 2 when the file doesn''t exist, and sends nothing' {
        $r = & $script:run $script:bootTool @{ InfrastructureFile = (Join-Path $TestDrive 'missing.yml'); Credential = $script:login }
        $r.Exit | Should -Be 2
        $r.Errors | Should -Match "doesn't exist"
        $global:bmcT_calls.Count | Should -Be 0
    }

    It 'stops with exit code 2 on a file that is not schema 5 (the retired environment-file layout), pointing at the toolkit''s example' {
        $old = Join-Path $TestDrive 'old-layout.yml'
        Set-Content -LiteralPath $old -Value @('cluster_nodes:', '  - { name: iic-node-01, idrac_ip: 198.51.100.11 }')
        $r = & $script:run $script:jobTool @{ InfrastructureFile = $old; Credential = $script:login }
        $r.Exit | Should -Be 2
        $r.Errors | Should -Match "isn't an infrastructure file in schema 5"
        $r.Errors | Should -Match 'config/variables/examples/infrastructure\.example\.yml'
        $global:bmcT_calls.Count | Should -Be 0
    }

    It 'stops with exit code 2 for a node that isn''t in the file, or one without a BMC address' {
        $file = & $script:writeFile -NoBmcAddress
        (& $script:run $script:bootTool @{ InfrastructureFile = $file; NodeName = 'iic-node-09'; Credential = $script:login }).Exit | Should -Be 2
        $r = & $script:run $script:bootTool @{ InfrastructureFile = $file; NodeName = 'iic-node-02'; Credential = $script:login }
        $r.Exit | Should -Be 2
        $r.Errors | Should -Match 'nodes\[1\] \(iic-node-02\) has no bmc.ip_address'
        $global:bmcT_calls.Count | Should -Be 0
    }

    It 'stops with exit code 2 and says what to pass when there is neither -Credential nor a login in the file' {
        $file = & $script:writeFile -NoBmcLogin
        $r = & $script:run $script:jobTool @{ InfrastructureFile = $file }
        $r.Exit | Should -Be 2
        $r.Errors | Should -Match 'pass -Credential, or set hardware.bmc.username and hardware.bmc.password'
        $global:bmcT_calls.Count | Should -Be 0
    }

    It 'reads the login from the file''s secret references through the toolkit resolver when -Credential is not given' {
        $file = & $script:writeFile
        $r = & $script:run $script:bootTool @{ InfrastructureFile = $file; NodeName = 'iic-node-01' }
        $r.Exit | Should -Be 0
        ($global:bmcT_calls | Where-Object Method -EQ 'Resolve').Path | Should -Be 'keyvault://kv-iic-azl/bmc-password'
        ($global:bmcT_calls | Where-Object Method -EQ 'Session').Path | Should -Be 'iic-bmc-from-vault'
    }

    It 'uses -Credential and never calls the resolver when it is given' {
        $file = & $script:writeFile
        $null = & $script:run $script:bootTool @{ InfrastructureFile = $file; NodeName = 'iic-node-01'; Credential = $script:login }
        @($global:bmcT_calls | Where-Object Method -EQ 'Resolve').Count | Should -Be 0
        ($global:bmcT_calls | Where-Object Method -EQ 'Session').Path | Should -Be 'iic-bmc-admin'
    }

    It 'stops with exit code 2 when the resolver can''t read the secret, naming the reference and not a value' {
        $global:bmcT_resolverFail = $true
        $file = & $script:writeFile
        $r = & $script:run $script:jobTool @{ InfrastructureFile = $file }
        $r.Exit | Should -Be 2
        $r.Errors | Should -Match 'keyvault://kv-iic-azl/bmc-password'
        @($global:bmcT_calls | Where-Object Method -EQ 'Session').Count | Should -Be 0
    }

    It 'skips the certificate check by default and checks it when hardware.bmc.verify_certificate is true' {
        $null = & $script:run $script:bootTool @{ InfrastructureFile = (& $script:writeFile); NodeName = 'iic-node-01'; Credential = $script:login }
        ($global:bmcT_calls | Where-Object Method -EQ 'Session').Body | Should -BeTrue
        $global:bmcT_calls.Clear()
        $null = & $script:run $script:bootTool @{ InfrastructureFile = (& $script:writeFile -Verify true); NodeName = 'iic-node-01'; Credential = $script:login }
        ($global:bmcT_calls | Where-Object Method -EQ 'Session').Body | Should -BeFalse
    }
}

Describe 'Get-ZtpBmcJob.ps1' {
    BeforeEach { & $script:reset }

    It 'lists every job of every node, read-only, and marks the active ones' {
        $r = & $script:run $script:jobTool @{ InfrastructureFile = (& $script:writeFile); Credential = $script:login }
        $r.Exit | Should -Be 0
        @($r.Rows | ForEach-Object { "$($_.Node) $($_.JobId) $($_.JobState) $($_.Active)" }) | Should -Be @('iic-node-01 JID_100 Completed False', 'iic-node-01 JID_200 Running True', 'iic-node-02 JID_100 Completed False', 'iic-node-02 JID_200 Running True')
        & $script:sent | Should -BeNullOrEmpty
        @($global:bmcT_calls | Where-Object Method -EQ 'Close').Count | Should -Be 2
    }

    It 'filters by state and by start time' {
        $file = & $script:writeFile
        @((& $script:run $script:jobTool @{ InfrastructureFile = $file; NodeName = 'iic-node-01'; Credential = $script:login; JobState = 'Completed' }).Rows.JobId) | Should -Be @('JID_100')
        @((& $script:run $script:jobTool @{ InfrastructureFile = $file; NodeName = 'iic-node-01'; Credential = $script:login; RecentMinutes = 60 }).Rows.JobId) | Should -Be @('JID_200')
    }

    It 'waits with -Wait until no job is active' {
        Mock Start-Sleep {}
        $global:bmcT_runningReads = 2
        $r = & $script:run $script:jobTool @{ InfrastructureFile = (& $script:writeFile); NodeName = 'iic-node-01'; Credential = $script:login; Wait = $true; PollSeconds = 5 }
        $r.Exit | Should -Be 0
        ($r.Rows | Where-Object JobId -EQ 'JID_200').JobState | Should -Be 'Completed'
        $global:bmcT_jobReads | Should -Be 3
    }

    It 'returns exit code 1 when a BMC can''t be read, and still reads the others' {
        $global:bmcT_sessionFail = '198.51.100.12'
        $r = & $script:run $script:jobTool @{ InfrastructureFile = (& $script:writeFile); Credential = $script:login }
        $r.Exit | Should -Be 1
        @($r.Rows.Node | Select-Object -Unique) | Should -Be @('iic-node-01')
        $r.Errors | Should -Match 'iic-node-02 \(198\.51\.100\.12\)'
    }
}

Describe 'Get-ZtpBootSetting.ps1' {
    BeforeEach { & $script:reset }

    It 'reads the override, the boot order and the options, and counts the stale ones' {
        $r = & $script:run $script:bootTool @{ InfrastructureFile = (& $script:writeFile); NodeName = 'iic-node-01'; Credential = $script:login }
        $r.Exit | Should -Be 0
        $row = $r.Rows[0]
        "$($row.Node) $($row.PowerState) $($row.BootMode) $($row.OverrideEnabled) $($row.OverrideTarget)" | Should -Be 'iic-node-01 On UEFI Once Usb'
        $row.BootOrder | Should -Be @('Boot0001', 'Boot0002')
        @($row.Options | ForEach-Object { "$($_.Id) $($_.Stale)" }) | Should -Be @('Boot0001 True', 'Boot0002 False')
        $row.StaleCount | Should -Be 1
        & $script:sent | Should -BeNullOrEmpty
    }

    It 'returns a row with the error and exit code 1 for a BMC that doesn''t answer' {
        $global:bmcT_sessionFail = '198.51.100.11'
        $r = & $script:run $script:bootTool @{ InfrastructureFile = (& $script:writeFile); Credential = $script:login }
        $r.Exit | Should -Be 1
        ($r.Rows | Where-Object Node -EQ 'iic-node-01').Error | Should -Match 'Cannot reach'
        ($r.Rows | Where-Object Node -EQ 'iic-node-02').Error | Should -BeNullOrEmpty
    }
}

Describe 'Reset-ZtpBmc.ps1' {
    BeforeEach { & $script:reset }

    It 'plans with -WhatIf without a credential and without a BMC call' {
        $r = & $script:run $script:resetBmc @{ InfrastructureFile = (& $script:writeFile -NoBmcLogin); WhatIf = $true }
        $r.Exit | Should -Be 0
        @($r.Rows.Status) | Should -Be @('Planned', 'Planned')
        $global:bmcT_calls.Count | Should -Be 0
    }

    It 'posts the manager''s reset action to the selected node only' {
        $r = & $script:run $script:resetBmc @{ InfrastructureFile = (& $script:writeFile); NodeName = 'iic-node-02'; Credential = $script:login; Confirm = $false }
        $r.Exit | Should -Be 0
        $r.Rows[0].Status | Should -Be 'ResetSent'
        $sent = & $script:sent
        $sent.Count | Should -Be 1
        "$($sent[0].Bmc) $($sent[0].Method) $($sent[0].Path) $($sent[0].Body.ResetType)" | Should -Be '198.51.100.12 Post /redfish/v1/Managers/iDRAC.Embedded.1/Actions/Manager.Reset GracefulRestart'
    }

    It 'fails a node, with exit code 1, when the BMC doesn''t offer the reset type, and sends no reset' {
        $r = & $script:run $script:resetBmc @{ InfrastructureFile = (& $script:writeFile); NodeName = 'iic-node-01'; Credential = $script:login; ResetType = 'ForceRestart'; Confirm = $false }
        $r.Exit | Should -Be 1
        $r.Rows[0].Status | Should -Be 'Failed'
        $r.Rows[0].Error | Should -Match "doesn't offer ResetType ForceRestart"
        & $script:sent | Should -BeNullOrEmpty
    }

    It 'stops with exit code 2 before any BMC call when the login can''t be resolved' {
        $r = & $script:run $script:resetBmc @{ InfrastructureFile = (& $script:writeFile -NoBmcLogin); Confirm = $false }
        $r.Exit | Should -Be 2
        @($global:bmcT_calls | Where-Object Method -NE 'Resolve').Count | Should -Be 0
    }
}

Describe 'Reset-ZtpBootSequence.ps1' {
    BeforeEach { & $script:reset }

    It 'plans with -WhatIf without a credential, a confirmation or a BMC call' {
        $r = & $script:run $script:resetBoot @{ InfrastructureFile = (& $script:writeFile -NoBmcLogin); WhatIf = $true }
        $r.Exit | Should -Be 0
        @($r.Rows.Status) | Should -Be @('Planned', 'Planned')
        $global:bmcT_calls.Count | Should -Be 0
    }

    It 'needs -ConfirmNotClustered to change anything (exit code 2)' {
        $r = & $script:run $script:resetBoot @{ InfrastructureFile = (& $script:writeFile); Credential = $script:login; Confirm = $false }
        $r.Exit | Should -Be 2
        $r.Errors | Should -Match 'ConfirmNotClustered'
        $global:bmcT_calls.Count | Should -Be 0
    }

    It 'refuses a vendor other than Dell (exit code 2)' {
        $r = & $script:run $script:resetBoot @{ InfrastructureFile = (& $script:writeFile -Vendor 'HPE'); Credential = $script:login; ConfirmNotClustered = $true; Confirm = $false }
        $r.Exit | Should -Be 2
        $r.Errors | Should -Match 'Dell iDRAC nodes only'
        $global:bmcT_calls.Count | Should -Be 0
    }

    It 'clears the job queue, sets SysPrepClean with its job, clears the override and restarts, in that order' {
        $r = & $script:run $script:resetBoot @{ InfrastructureFile = (& $script:writeFile); NodeName = 'iic-node-01'; Credential = $script:login; ConfirmNotClustered = $true; Confirm = $false }
        $r.Exit | Should -Be 0
        $row = $r.Rows[0]
        "$($row.Status) $($row.JobQueueCleared) $($row.SysPrepCleanSet) $($row.ConfigJobCreated) $($row.OverrideCleared) $($row.Restart)" | Should -Be 'Restarted True True True True GracefulRestart'
        $sent = & $script:sent
        @($sent | ForEach-Object { "$($_.Method) $($_.Path)" }) | Should -Be @(
            'Post /redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellJobService/Actions/DellJobService.DeleteJobQueue'
            'Patch /redfish/v1/Systems/System.Embedded.1/Bios/Settings'
            'Post /redfish/v1/Managers/iDRAC.Embedded.1/Jobs'
            'Patch /redfish/v1/Systems/System.Embedded.1'
            'Post /redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset'
        )
        $sent[0].Body.JobID | Should -Be 'JID_CLEARALL'
        $sent[1].Body.Attributes.SysPrepClean | Should -Be 'Yes'
        $sent[2].Body.TargetSettingsURI | Should -Be '/redfish/v1/Systems/System.Embedded.1/Bios/Settings'
        $sent[3].Body.Boot.BootSourceOverrideEnabled | Should -Be 'Disabled'
        $sent[4].Body.ResetType | Should -Be 'GracefulRestart'
    }

    It 'leaves a Continuous boot override as it is (only a one-time override is cleared)' {
        $system = $global:bmcT_responses['/redfish/v1/Systems/System.Embedded.1']
        $before = $system.Boot.BootSourceOverrideEnabled
        $system.Boot.BootSourceOverrideEnabled = 'Continuous'
        try {
            $r = & $script:run $script:resetBoot @{ InfrastructureFile = (& $script:writeFile); NodeName = 'iic-node-01'; Credential = $script:login; ConfirmNotClustered = $true; Confirm = $false }
            $r.Exit | Should -Be 0
            $r.Rows[0].OverrideCleared | Should -BeFalse
            @(& $script:sent | Where-Object { $_.Method -eq 'Patch' -and $_.Path -eq '/redfish/v1/Systems/System.Embedded.1' }).Count | Should -Be 0
        }
        finally { $system.Boot.BootSourceOverrideEnabled = $before }
    }

    It 'stages it without a restart with -NoRestart' {
        $r = & $script:run $script:resetBoot @{ InfrastructureFile = (& $script:writeFile); NodeName = 'iic-node-01'; Credential = $script:login; ConfirmNotClustered = $true; NoRestart = $true; Confirm = $false }
        $r.Rows[0].Status | Should -Be 'Staged'
        @(& $script:sent | Where-Object Path -Like '*ComputerSystem.Reset').Count | Should -Be 0
    }

    It 'reports the step that failed and returns exit code 1, without going on to restart that node' {
        $global:bmcT_failPath = '*/Bios/Settings'
        $r = & $script:run $script:resetBoot @{ InfrastructureFile = (& $script:writeFile); NodeName = 'iic-node-01'; Credential = $script:login; ConfirmNotClustered = $true; Confirm = $false }
        $r.Exit | Should -Be 1
        $r.Rows[0].Status | Should -Be 'Failed'
        $r.Rows[0].Error | Should -Match '^Could not set SysPrepClean=Yes'
        @(& $script:sent | Where-Object Path -Like '*ComputerSystem.Reset').Count | Should -Be 0
    }
}
