#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
# Azure half of simplified machine provisioning: OS image catalog, edge machine status, the readiness poller, the Arc
# name map writer, the orchestrator and the ready-to-cluster check. ARM responses are the shapes a live run returned
# (fixtures/, neutral IDs and names). No Azure call, no node, no real secret.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Only a synthetic test password is converted.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stubs mirror the real cmdlet signatures.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Stubs mirror the real cmdlet signatures.')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:scripts = Join-Path $script:repoRoot 'scripts/simplified-provisioning'
    $global:ztpFixtures = Join-Path $PSScriptRoot 'fixtures'
    $global:ztpZeroSub = '00000000-0000-0000-0000-000000000000'
    . (Join-Path $script:scripts 'ZtpAzure.Common.ps1')

    # Stubs with the parameters the scripts use, so the tests neither need nor load the Az modules.
    $global:ztpStubs = @('Invoke-AzRestMethod', 'Get-AzContext', 'Set-AzContext', 'Get-AzKeyVaultSecret', 'Set-AzKeyVaultSecret',
        'New-AzResourceGroupDeployment', 'Get-AzResourceGroupDeployment', 'Get-AzResourceGroupDeploymentWhatIfResult',
        'Get-AzConnectedMachine', 'Get-AzConnectedMachineExtension')
    function global:Invoke-AzRestMethod { [CmdletBinding()] param([string]$Path, [string]$Method, [string]$Payload) }
    function global:Get-AzContext { [CmdletBinding()] param() }
    function global:Set-AzContext { [CmdletBinding(SupportsShouldProcess)] param([string]$Subscription, [string]$SubscriptionId) }
    function global:Get-AzKeyVaultSecret { [CmdletBinding()] param([string]$VaultName, [string]$Name) }
    function global:Set-AzKeyVaultSecret { [CmdletBinding(SupportsShouldProcess)] param([string]$VaultName, [string]$Name, [securestring]$SecretValue) }
    function global:New-AzResourceGroupDeployment { [CmdletBinding(SupportsShouldProcess)] param([string]$Name, [string]$ResourceGroupName, [string]$TemplateFile, [hashtable]$TemplateParameterObject, [string]$Mode, [switch]$AsJob) }
    function global:Get-AzResourceGroupDeployment { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function global:Get-AzResourceGroupDeploymentWhatIfResult { [CmdletBinding()] param([string]$ResourceGroupName, [string]$TemplateFile, [hashtable]$TemplateParameterObject, [string]$ResultFormat) }
    function global:Get-AzConnectedMachine { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId) }
    function global:Get-AzConnectedMachineExtension { [CmdletBinding()] param([string]$MachineName, [string]$ResourceGroupName, [string]$SubscriptionId) }

    function global:New-ZtpTestResponse {
        param([int]$Status, [object]$Body)
        $content = if ($Body -is [string]) { $Body } elseif ($null -ne $Body) { $Body | ConvertTo-Json -Depth 60 } else { '' }
        [pscustomobject]@{ StatusCode = $Status; Content = $content }
    }
    function global:Get-ZtpTestFixture {
        param([string]$Name, [string]$Node = 'node-01')
        (Get-Content -LiteralPath (Join-Path $global:ztpFixtures $Name) -Raw) -replace 'node-01', $Node
    }
    # The live-run machine/job pairs, keyed by state.
    $global:ztpStateFiles = @{
        provisioned = @('edge-machine-provisioned.json', 'job-provisionos-succeeded.json')
        installing  = @('edge-machine-installing-os.json', 'job-provisionos-in-progress.json')
    }
    # Default ARM handler: the catalog, the site and configuration (exist unless switched off), edge machines by state.
    $global:ztpArmHandler = {
        param($Path, $Method, $Payload)
        $global:ztpCalls.Add([pscustomobject]@{ Path = $Path; Method = $Method; Payload = $Payload })
        if ($Path -like '*/osImages?*') { return New-ZtpTestResponse 200 (Get-Content (Join-Path $global:ztpFixtures 'os-images.json') -Raw) }
        if ($Path -like '*/Microsoft.Edge/sites/*') { if ($global:ztpSiteExists) { return New-ZtpTestResponse 200 @{ name = 'site-example' } } return New-ZtpTestResponse 404 @{ error = @{ code = 'ResourceNotFound' } } }
        if ($Path -like '*/Microsoft.Edge/configurations/*') { if ($global:ztpSiteExists) { return New-ZtpTestResponse 200 @{ name = 'default' } } return New-ZtpTestResponse 404 $null }
        if ($Path -match '/edgeMachines/([^/?]+)/jobs/ProvisionOs\?') {
            if ($Method -eq 'PUT') { return New-ZtpTestResponse 200 @{ name = 'ProvisionOs' } }
            $state = $global:ztpMachines[$Matches[1]]
            if ($state -is [scriptblock]) { $state = & $state }
            if ($state -and $global:ztpStateFiles.ContainsKey($state)) { return New-ZtpTestResponse 200 (Get-ZtpTestFixture $global:ztpStateFiles[$state][1] $Matches[1]) }
            if ($state -eq 'failed') {
                $job = Get-ZtpTestFixture 'job-provisionos-in-progress.json' $Matches[1] | ConvertFrom-Json -Depth 60
                $job.properties.status = 'DeploymentFailed'
                $job.properties.reportedProperties.deploymentStatus.steps[12].status = 'Failed'
                return New-ZtpTestResponse 200 $job
            }
            return New-ZtpTestResponse 404 $null
        }
        if ($Path -match '/edgeMachines/([^/?]+)\?') {
            $state = $global:ztpMachines[$Matches[1]]
            if ($state -is [scriptblock]) { $state = & $state }
            if ($state -eq 'failed') { return New-ZtpTestResponse 200 (Get-ZtpTestFixture 'edge-machine-installing-os.json' $Matches[1]) }
            if ($state) { return New-ZtpTestResponse 200 (Get-ZtpTestFixture $global:ztpStateFiles[$state][0] $Matches[1]) }
            return New-ZtpTestResponse 404 $null
        }
        New-ZtpTestResponse 404 $null
    }
}

AfterAll {
    foreach ($name in @($global:ztpStubs) + @('New-ZtpTestResponse', 'Get-ZtpTestFixture')) { Remove-Item "Function:global:$name" -ErrorAction SilentlyContinue }
    Remove-Variable ztpFixtures, ztpZeroSub, ztpStubs, ztpStateFiles, ztpArmHandler, ztpCalls, ztpMachines, ztpSiteExists -Scope Global -ErrorAction SilentlyContinue
}

Describe 'ZTP Azure half' {
    BeforeEach {
        $global:ztpCalls = [System.Collections.Generic.List[object]]::new()
        $global:ztpMachines = @{}
        $global:ztpSiteExists = $true
        Mock Invoke-AzRestMethod { & $global:ztpArmHandler $Path $Method $Payload }
        Mock Start-Sleep {}
    }

    Describe 'Bicep template' {
        It 'reproduces the portal resources at the portal api-versions' {
            $text = Get-Content (Join-Path $script:scripts 'bicep/main.bicep') -Raw
            foreach ($type in "Microsoft.Edge/sites@2025-06-01", "Microsoft.Edge/configurations@2025-12-01-preview",
                "Microsoft.Edge/configurations/networkConfigurations@2025-12-01-preview", "Microsoft.Edge/configurations/timeServerConfigurations@2025-12-01-preview",
                "Microsoft.Edge/configurations/connectivityConfigurations@2025-12-01-preview", "Microsoft.Edge/configurations/securityConfigurations@2025-12-01-preview",
                "Microsoft.Edge/configurationReferences@2025-12-01-preview", "Microsoft.AzureStackHCI/edgeMachines@2026-10-01") {
                $text | Should -Match ([regex]::Escape("'$type'"))
            }
            $text | Should -Match "guid\(azl_rp_app_object_id, 'Management', resourceGroup\(\)\.name, subscription\(\)\.id\)"
            $text | Should -Match '@secure\(\)\s+@description\(.*\)\s+param ownership_vouchers object'
            $text | Should -Not -Match '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?<!f5819b54-e033-4d82-ac66-4fec3cbf3f4c|f58310d9-a9f6-439a-9e8d-f62e7b41a168|cd570a14-e51a-42ad-bac8-bafd67325302)' -Because 'only built-in role definition IDs may be literal'
        }

        It 'builds' -Skip:(-not (Get-Command az -ErrorAction SilentlyContinue)) {
            $null = az bicep build --file (Join-Path $script:scripts 'bicep/main.bicep') --stdout 2>&1
            $LASTEXITCODE | Should -Be 0
        }
    }

    Describe 'Parameters example' {
        It 'is complete for the template and holds only neutral values' {
            $path = Join-Path $script:scripts 'bicep/main.example.parameters.json'
            $example = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable).parameters
            $template = Get-Content (Join-Path $script:scripts 'bicep/main.bicep') -Raw
            foreach ($required in 'location', 'azl_rp_app_object_id', 'key_vault_name', 'key_vault_resource_group', 'site_name', 'admin_username', 'admin_secret_name', 'time_zone', 'nodes') {
                $example.ContainsKey($required) | Should -BeTrue -Because $required
            }
            foreach ($name in $example.Keys) { $template | Should -Match ([regex]::Escape("param $name ")) -Because "the example sets $name" }
            foreach ($runtime in 'ownership_vouchers', 'os_version', 'create_site', 'create_configuration', 'node_filter', 'claim_machines') { $example.ContainsKey($runtime) | Should -BeFalse -Because "$runtime is a run-time value" }
            (Get-Content -LiteralPath $path -Raw) | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-(?!000000000000)[0-9a-fA-F]{12}'
        }
    }

    Describe 'OS image catalog (Get-ZtpOsImage.ps1)' {
        It 'lists newest first and marks the 12.2699 build as preview' {
            $rows = @(& (Join-Path $script:scripts 'Get-ZtpOsImage.ps1') -SubscriptionId $global:ztpZeroSub -Location eastus)
            $rows.VsrVersion | Should -Be @('12.2699.1000.1', '12.2609.1003.7', '12.2608.1003.9', '12.2607.1003.73')
            $rows[0].IsPreview | Should -BeTrue
            $rows[1].IsPreview | Should -BeFalse
            $global:ztpCalls[0].Path | Should -Match "^/subscriptions/$global:ztpZeroSub/providers/Microsoft\.AzureStackHCI/locations/eastus/osImages\?api-version=2025-12-01-preview&solution-type=HCI$"
            $global:ztpCalls[0].Method | Should -Be 'GET'
        }

        It 'resolves <Version> to <Expected>' -TestCases @(
            @{ Version = 'latest'; Expected = '12.2609.1003.7' }
            @{ Version = 'latest-preview'; Expected = '12.2699.1000.1' }
            @{ Version = '12.2608.1003.9'; Expected = '12.2608.1003.9' }
            @{ Version = '12.2609.0.3009'; Expected = '12.2609.1003.7' }
        ) {
            (& (Join-Path $script:scripts 'Get-ZtpOsImage.ps1') -SubscriptionId $global:ztpZeroSub -Location eastus -Version $Version).VsrVersion | Should -Be $Expected
        }

        It 'names the offered versions when the requested one is missing' {
            { & (Join-Path $script:scripts 'Get-ZtpOsImage.ps1') -SubscriptionId $global:ztpZeroSub -Location eastus -Version 12.2999.1.1 } | Should -Throw '*not in the HCI catalog*12.2609.1003.7*'
        }
    }

    Describe 'Edge machine status from the live shapes' {
        It 'reads a provisioned machine with its succeeded job as ready to cluster' {
            $machine = Get-ZtpTestFixture 'edge-machine-provisioned.json' | ConvertFrom-Json -Depth 60
            $job = Get-ZtpTestFixture 'job-provisionos-succeeded.json' | ConvertFrom-Json -Depth 60
            $s = Get-ZtpEdgeMachineStatus -Name node-01 -Machine $machine -Job $job
            $s.Ready | Should -BeTrue
            $s.Failed | Should -BeFalse
            $s.Lifecycle | Should -Be 'Provisioned'
            $s.JobStatus | Should -Be 'DeploymentSuccess'
            $s.ArcMachineName | Should -Be '00000000-0000-0000-0000-000000000000-1'
            @($s.MissingExtensions).Count | Should -Be 0
        }

        It 'reads a machine in InstallOs as running, not ready and not failed' {
            $machine = Get-ZtpTestFixture 'edge-machine-installing-os.json' node-02 | ConvertFrom-Json -Depth 60
            $job = Get-ZtpTestFixture 'job-provisionos-in-progress.json' node-02 | ConvertFrom-Json -Depth 60
            $s = Get-ZtpEdgeMachineStatus -Name node-02 -Machine $machine -Job $job
            $s.Ready | Should -BeFalse
            $s.Failed | Should -BeFalse
            $s.Lifecycle | Should -Be 'InstallingOs'
            $s.CurrentStage | Should -Match '^InstallOs/'
            $s.ArcMachineName | Should -BeLike 'ROE1-*'
            $s.MissingExtensions | Should -Contain 'AzureEdgeLifecycleManager'
        }

        It 'is not ready while a mandatory extension is still Creating' {
            $machine = Get-ZtpTestFixture 'edge-machine-provisioned.json' | ConvertFrom-Json -Depth 60
            $machine.properties.reportedProperties.extensionProfile.extensions[0].state = 'Creating'
            $job = Get-ZtpTestFixture 'job-provisionos-succeeded.json' | ConvertFrom-Json -Depth 60
            $s = Get-ZtpEdgeMachineStatus -Name node-01 -Machine $machine -Job $job
            $s.Ready | Should -BeFalse
            $s.MissingExtensions | Should -Be @('AzureEdgeLifecycleManager')
        }

        It 'reports a failed job step as terminal with its name' {
            $machine = Get-ZtpTestFixture 'edge-machine-installing-os.json' | ConvertFrom-Json -Depth 60
            $job = Get-ZtpTestFixture 'job-provisionos-in-progress.json' | ConvertFrom-Json -Depth 60
            $job.properties.reportedProperties.deploymentStatus.steps[12].status = 'Failed'
            $s = Get-ZtpEdgeMachineStatus -Name node-01 -Machine $machine -Job $job
            $s.Failed | Should -BeTrue
            $s.FailureReason | Should -Match 'step BootIntoTargetOS Failed'
        }

        It 'flattens every lifecycle stage and job step with timestamps' {
            $machine = Get-ZtpTestFixture 'edge-machine-provisioned.json' | ConvertFrom-Json -Depth 60
            $job = Get-ZtpTestFixture 'job-provisionos-succeeded.json' | ConvertFrom-Json -Depth 60
            $items = @(Get-ZtpProgressItem -Name node-01 -Machine $machine -Job $job)
            @($items.Key | Select-Object -Unique).Count | Should -Be $items.Count
            ($items | Where-Object Key -EQ 'node-01|stage|InstallOs/RebootOs').Text | Should -Be 'stage InstallOs/RebootOs Completed (start 17:47:15, end 18:04:43)'
            ($items | Where-Object Key -EQ 'node-01|step|DownloadOSArtifacts').Text | Should -Match '^step DownloadOSArtifacts Success \(start 17:43:44, end 17:45:05\)'
        }

        It 'builds the Learn retry body from the edge machine' {
            $machine = Get-ZtpTestFixture 'edge-machine-provisioned.json' | ConvertFrom-Json -Depth 60
            $body = Get-ZtpProvisionOsRetryBody -Machine $machine
            $body.properties.jobType | Should -Be 'ProvisionOs'
            $body.properties.provisioningRequest.target | Should -Be 'HCI'
            $body.properties.provisioningRequest.osProfile.vsrVersion | Should -Be '12.2609.1003.7'
            $body.properties.provisioningRequest.userDetails[0].secretLocation | Should -Match '/secrets/provisioning-admin$'
        }

        It 'fills a missing secretLocation only from -AdminSecretResourceId' {
            $machine = Get-ZtpTestFixture 'edge-machine-provisioned.json' | ConvertFrom-Json -Depth 60
            $machine.properties.provisioningDetails.userDetails[0].PSObject.Properties.Remove('secretLocation')
            { Get-ZtpProvisionOsRetryBody -Machine $machine } | Should -Throw '*AdminSecretResourceId*'
            $id = "/subscriptions/$global:ztpZeroSub/resourceGroups/rg-example-sec/providers/Microsoft.KeyVault/vaults/kv-example/secrets/other"
            (Get-ZtpProvisionOsRetryBody -Machine $machine -AdminSecretResourceId $id).properties.provisioningRequest.userDetails[0].secretLocation | Should -Be $id
        }
    }

    Describe 'Readiness poller (Wait-ZtpMachineReady.ps1)' {
        BeforeAll {
            $script:wait = Join-Path $script:scripts 'Wait-ZtpMachineReady.ps1'
            $script:waitArgs = @{ SubscriptionId = $global:ztpZeroSub; ResourceGroupName = 'rg-example'; EdgeMachineName = @('node-01', 'node-02'); PollIntervalSeconds = 0 }
        }

        It 'returns the rows when every node is ready to cluster' {
            $global:ztpMachines = @{ 'node-01' = 'provisioned'; 'node-02' = 'provisioned' }
            $rows = @(& $script:wait @script:waitArgs)
            $rows.Count | Should -Be 2
            @($rows | Where-Object Ready).Count | Should -Be 2
            @($global:ztpCalls | Where-Object Method -EQ 'PUT').Count | Should -Be 0
            $global:ztpCalls[0].Path | Should -Match '/edgeMachines/node-01\?api-version=2025-12-01-preview$'
        }

        It 'keeps polling through InstallOs and prints each step change once' {
            $global:ztpPoll = 0
            $global:ztpMachines = @{ 'node-01' = 'provisioned'; 'node-02' = { if ($global:ztpPoll -lt 2) { 'installing' } else { 'provisioned' } } }
            Mock Start-Sleep { $global:ztpPoll++ }
            $rows = @(& $script:wait @script:waitArgs -InformationVariable info)
            @($rows | Where-Object Ready).Count | Should -Be 2
            $text = @($info | ForEach-Object { $_.MessageData }) -join "`n"
            $text | Should -Match 'node-02 lifecycle InstallingOs - Installing OS in progress'
            $text | Should -Match 'node-02 lifecycle Provisioned - Machine has been successfully provisioned'
            $text | Should -Match 'node-02 step BootIntoTargetOS Success'
            ([regex]::Matches($text, 'node-01 lifecycle Provisioned')).Count | Should -Be 1
            Remove-Variable ztpPoll -Scope Global
        }

        It 'stops on a terminal failure without sending anything' {
            $global:ztpMachines = @{ 'node-01' = 'provisioned'; 'node-02' = 'failed' }
            { & $script:wait @script:waitArgs } | Should -Throw '*Provisioning failed: node-02*BootIntoTargetOS Failed*'
            @($global:ztpCalls | Where-Object Method -EQ 'PUT').Count | Should -Be 0
        }

        It 'only prints the ProvisionOs retry without -Execute' {
            $global:ztpMachines = @{ 'node-01' = 'provisioned'; 'node-02' = 'failed' }
            { & $script:wait @script:waitArgs -RetryProvisionOs } | Should -Throw '*Provisioning failed*'
            @($global:ztpCalls | Where-Object Method -EQ 'PUT').Count | Should -Be 0
        }

        It 'resubmits jobs/ProvisionOs once with -RetryProvisionOs -Execute and then waits for Provisioned' {
            $global:ztpRetried = $false
            $global:ztpMachines = @{ 'node-01' = 'provisioned'; 'node-02' = { if ($global:ztpRetried) { 'provisioned' } else { 'failed' } } }
            $handler = $global:ztpArmHandler
            Mock Invoke-AzRestMethod { if ($Method -eq 'PUT') { $global:ztpRetried = $true }; & $handler $Path $Method $Payload }
            $rows = @(& $script:wait @script:waitArgs -RetryProvisionOs -Execute -Confirm:$false)
            @($rows | Where-Object Ready).Count | Should -Be 2
            $put = @($global:ztpCalls | Where-Object Method -EQ 'PUT')
            $put.Count | Should -Be 1
            $put[0].Path | Should -Match '/edgeMachines/node-02/jobs/ProvisionOs\?api-version=2025-12-01-preview$'
            $body = $put[0].Payload | ConvertFrom-Json
            $body.properties.jobType | Should -Be 'ProvisionOs'
            $body.properties.provisioningRequest.target | Should -Be 'HCI'
            $body.properties.provisioningRequest.osProfile.osType | Should -Be 'HCI'
            Remove-Variable ztpRetried -Scope Global
        }

        It 'throws on timeout and names the pending node, its stage and missing extensions' {
            $global:ztpMachines = @{ 'node-01' = 'provisioned'; 'node-02' = 'installing' }
            { & $script:wait @script:waitArgs -TimeoutMinutes 0 } | Should -Throw '*Not ready to cluster within 0 min: node-02 (lifecycle InstallingOs, InstallOs/*AzureEdgeDeviceManagement*'
        }

        It 'treats a missing edge machine as pending, not ready' {
            $global:ztpMachines = @{ 'node-01' = 'provisioned' }
            { & $script:wait @script:waitArgs -TimeoutMinutes 0 } | Should -Throw '*node-02 (lifecycle Missing*'
        }
    }

    Describe 'Arc machine name map (Update-ArcMachineNames.ps1)' {
        BeforeAll { $script:update = Join-Path $script:scripts 'Update-ArcMachineNames.ps1' }
        BeforeEach {
            $script:map = Join-Path $TestDrive "arc-$([guid]::NewGuid().ToString('N')).json"
            $global:ztpMachines = @{ 'node-01' = 'provisioned'; 'node-02' = 'provisioned' }
            $script:arcArgs = @{ SubscriptionId = $global:ztpZeroSub; ResourceGroupName = 'rg-example'; NodeName = @('node-01', 'node-02') }
        }

        It 'returns the rows without a map path and writes nothing' {
            $rows = @(& $script:update @script:arcArgs)
            $rows.Count | Should -Be 2
            ($rows | Where-Object Node -EQ 'node-01').ArcMachineName | Should -Be '00000000-0000-0000-0000-000000000000-1'
            ($rows | Where-Object Node -EQ 'node-01').ArcMachineResourceId | Should -Match '/providers/Microsoft\.HybridCompute/machines/00000000-0000-0000-0000-000000000000-1$'
            Test-Path $script:map | Should -BeFalse
        }

        It 'plans a map file without writing it' {
            Set-Content -LiteralPath $script:map -Value '{ "node-01": "old-name-1" }' -NoNewline
            $rows = @(& $script:update @script:arcArgs -MapPath $script:map)
            ($rows | Where-Object Node -EQ 'node-01').Change | Should -Be 'Update'
            ($rows | Where-Object Node -EQ 'node-02').Change | Should -Be 'Add'
            Get-Content -LiteralPath $script:map -Raw | Should -BeExactly '{ "node-01": "old-name-1" }'
        }

        It 'writes the map with -Execute, keeps other nodes'' entries and reads back' {
            Set-Content -LiteralPath $script:map -Value '{ "node-09": "keep-me-1" }' -NoNewline
            $null = & $script:update @script:arcArgs -MapPath $script:map -Execute -Confirm:$false
            $written = Get-Content -LiteralPath $script:map -Raw | ConvertFrom-Json -AsHashtable
            $written['node-01'] | Should -Be '00000000-0000-0000-0000-000000000000-1'
            $written['node-02'] | Should -Be '00000000-0000-0000-0000-000000000000-1'
            $written['node-09'] | Should -Be 'keep-me-1'
            $rerun = @(& $script:update @script:arcArgs -MapPath $script:map)
            @($rerun | Where-Object Change -NE 'Unchanged').Count | Should -Be 0
        }

        It 'refuses -Execute without a map path' {
            { & $script:update @script:arcArgs -Execute -Confirm:$false } | Should -Throw '*-MapPath*'
        }

        It 'refuses a node that is not Provisioned yet (its Arc machine is still the maintenance one)' {
            $global:ztpMachines['node-02'] = 'installing'
            { & $script:update @script:arcArgs -MapPath $script:map -Execute -Confirm:$false } | Should -Throw "*node-02: lifecycle is 'InstallingOs'*"
            Test-Path $script:map | Should -BeFalse
        }

        It 'accepts a node that is not Provisioned with -AllowNotReady' {
            $global:ztpMachines['node-02'] = 'installing'
            $rows = @(& $script:update @script:arcArgs -AllowNotReady)
            ($rows | Where-Object Node -EQ 'node-02').ArcMachineName | Should -BeLike 'ROE1-*'
        }
    }

    Describe 'Orchestrator (Invoke-ZtpAzureProvisioning.ps1)' {
        BeforeAll { $script:orchestrator = Join-Path $script:scripts 'Invoke-ZtpAzureProvisioning.ps1' }
        BeforeEach {
            $vouchers = Join-Path $TestDrive 'vouchers'
            New-Item -ItemType Directory -Path (Join-Path $vouchers 'SERIAL02') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $vouchers 'SERIAL01.pem') -Value "-----BEGIN OWNERSHIP VOUCHER-----`nAAAA`n-----END OWNERSHIP VOUCHER-----" -NoNewline
            Set-Content -LiteralPath (Join-Path $vouchers 'SERIAL02\SERIAL02.pem') -Value "-----BEGIN OWNERSHIP VOUCHER-----`nBBBB`n-----END OWNERSHIP VOUCHER-----" -NoNewline
            $script:voucher2 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $vouchers 'SERIAL02\SERIAL02.pem')))
            $script:voucherPath = $vouchers
            $script:paramFile = Join-Path $TestDrive 'main.parameters.json'
            $values = [ordered]@{
                location                 = 'eastus'
                tags                     = @{ workload = 'example' }
                azl_rp_app_object_id     = $global:ztpZeroSub
                key_vault_name           = 'kv-example'
                key_vault_resource_group = 'rg-example-sec'
                site_name                = 'site-example'
                admin_username           = 'azladmin'
                admin_secret_name        = 'provisioning-admin'
                time_zone                = 'UTC'
                nodes                    = @(@{ name = 'node-01'; service_tag = 'SERIAL01' }, @{ name = 'node-02'; service_tag = 'SERIAL02' })
            }
            $parameters = [ordered]@{}
            foreach ($entry in $values.GetEnumerator()) { $parameters[$entry.Key] = @{ value = $entry.Value } }
            @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:paramFile
            Mock Get-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $global:ztpZeroSub } } }
            Mock Get-AzKeyVaultSecret { @([pscustomobject]@{ Name = 'provisioning-admin' }) }
            Mock Set-AzKeyVaultSecret {}
            Mock Get-AzResourceGroupDeploymentWhatIfResult { [pscustomobject]@{ Changes = @([pscustomobject]@{ ChangeType = 'Create'; FullyQualifiedResourceId = "/subscriptions/$global:ztpZeroSub/resourceGroups/rg-example/providers/Microsoft.AzureStackHCI/edgeMachines/node-02" }) } }
            Mock New-AzResourceGroupDeployment { [pscustomobject]@{ State = 'Running' } }
            Mock Get-AzResourceGroupDeployment { [pscustomobject]@{ Timestamp = [datetime]::UtcNow; ProvisioningState = 'Running' } }
            $script:runArgs = @{ SubscriptionId = $global:ztpZeroSub; ResourceGroupName = 'rg-example'; ParameterFile = $script:paramFile; VoucherPath = $script:voucherPath; OsVersion = 'latest' }
            $script:adminPassword = ConvertTo-SecureString 'Synthetic-Passw0rd!' -AsPlainText -Force
        }

        It 'plans by default: reuses the existing site, resolves the OS image, what-ifs with every voucher, changes nothing' {
            $plan = @(& $script:orchestrator @script:runArgs -Stage Plan -InformationVariable info)[-1]
            $plan.CreateSite | Should -BeFalse
            $plan.CreateConfiguration | Should -BeFalse
            $plan.Image.VsrVersion | Should -Be '12.2609.1003.7'
            $plan.AdminSecretResourceId | Should -Be "/subscriptions/$global:ztpZeroSub/resourceGroups/rg-example-sec/providers/Microsoft.KeyVault/vaults/kv-example/secrets/provisioning-admin"
            Should -Invoke Get-AzResourceGroupDeploymentWhatIfResult -Times 1 -Exactly -ParameterFilter {
                $TemplateParameterObject.os_version -eq '12.2609.1003.7' -and -not $TemplateParameterObject.create_site -and $TemplateParameterObject.claim_machines -and
                (@($TemplateParameterObject.node_filter) -join ',') -eq 'node-01,node-02' -and $TemplateParameterObject.ownership_vouchers['node-02'] -eq $script:voucher2 -and
                $TemplateParameterObject.site_name -eq 'site-example' -and $ResourceGroupName -eq 'rg-example'
            }
            Should -Invoke New-AzResourceGroupDeployment -Times 0 -Exactly
            Should -Invoke Set-AzKeyVaultSecret -Times 0 -Exactly
            @($global:ztpCalls | Where-Object Method -NE 'GET').Count | Should -Be 0
            (@($info | ForEach-Object { $_.MessageData }) -join "`n") | Should -Not -Match ([regex]::Escape($script:voucher2))
        }

        It 'creates the site and configuration when they do not exist' {
            $global:ztpSiteExists = $false
            $plan = @(& $script:orchestrator @script:runArgs -Stage Plan)[-1]
            $plan.CreateSite | Should -BeTrue
            $plan.CreateConfiguration | Should -BeTrue
        }

        It 'what-ifs the site only when a voucher is missing' {
            Remove-Item -LiteralPath (Join-Path $TestDrive 'vouchers\SERIAL01.pem')
            $null = & $script:orchestrator @script:runArgs -Stage Plan -WarningVariable warn 3>$null
            Should -Invoke Get-AzResourceGroupDeploymentWhatIfResult -Times 1 -Exactly -ParameterFilter { -not $TemplateParameterObject.claim_machines -and $TemplateParameterObject.ownership_vouchers.Count -eq 0 }
            ($warn -join "`n") | Should -Match 'node-01: expected exactly one voucher for serial SERIAL01'
        }

        It 'resolves -OsVersion <Version> to <Expected>' -TestCases @(
            @{ Version = 'latest'; Expected = '12.2609.1003.7' }
            @{ Version = 'latest-preview'; Expected = '12.2699.1000.1' }
        ) {
            $runArgs = $script:runArgs.Clone()
            $runArgs.OsVersion = $Version
            $plan = @(& $script:orchestrator @runArgs -Stage Plan 3>$null)[-1]
            $plan.Image.VsrVersion | Should -Be $Expected
        }

        It 'refuses SiteMode Reuse when the site does not exist' {
            $global:ztpSiteExists = $false
            { & $script:orchestrator @script:runArgs -Stage Plan -SiteMode Reuse } | Should -Throw '*SiteMode Reuse*'
        }

        It 'refuses an incomplete parameters file' {
            $incomplete = Join-Path $TestDrive 'incomplete.json'
            Set-Content -LiteralPath $incomplete -Value '{ "parameters": { "location": { "value": "eastus" } } }'
            $runArgs = $script:runArgs.Clone()
            $runArgs.ParameterFile = $incomplete
            { & $script:orchestrator @runArgs -Stage Plan } | Should -Throw "*no value for 'nodes'*"
        }

        It 'refuses the Execute stage without -Execute' {
            { & $script:orchestrator @script:runArgs -Stage Execute } | Should -Throw '*requires -Execute*'
            Should -Invoke New-AzResourceGroupDeployment -Times 0 -Exactly
        }

        It 'claims only the nodes without an edge machine and writes the missing admin secret first' {
            $global:ztpMachines = @{ 'node-01' = 'provisioned' }
            Mock Get-AzKeyVaultSecret { @() }
            $null = & $script:orchestrator @script:runArgs -Stage Execute -Execute -Confirm:$false -AdminPassword $script:adminPassword -DeploymentName dep-example
            Should -Invoke Set-AzKeyVaultSecret -Times 1 -Exactly -ParameterFilter { $VaultName -eq 'kv-example' -and $Name -eq 'provisioning-admin' -and $SecretValue -is [securestring] }
            Should -Invoke New-AzResourceGroupDeployment -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'dep-example' -and $ResourceGroupName -eq 'rg-example' -and $AsJob -and $Mode -eq 'Incremental' -and
                (@($TemplateParameterObject.node_filter) -join ',') -eq 'node-02' -and $TemplateParameterObject.claim_machines -and
                @($TemplateParameterObject.ownership_vouchers.Keys) -join ',' -eq 'node-02' -and $TemplateParameterObject.ownership_vouchers['node-02'] -eq $script:voucher2
            }
        }

        It 'submits nothing when the admin secret is missing and no -AdminPassword is given' {
            Mock Get-AzKeyVaultSecret { @() }
            { & $script:orchestrator @script:runArgs -Stage Execute -Execute -Confirm:$false } | Should -Throw '*-AdminPassword*'
            Should -Invoke New-AzResourceGroupDeployment -Times 0 -Exactly
            Should -Invoke Set-AzKeyVaultSecret -Times 0 -Exactly
        }

        It 'does not touch an existing admin secret even when -AdminPassword is given' {
            $null = & $script:orchestrator @script:runArgs -Stage Execute -Execute -Confirm:$false -AdminPassword $script:adminPassword
            Should -Invoke Set-AzKeyVaultSecret -Times 0 -Exactly
            Should -Invoke New-AzResourceGroupDeployment -Times 1 -Exactly
        }

        It 'submits nothing when a voucher is missing' {
            Remove-Item -LiteralPath (Join-Path $TestDrive 'vouchers\SERIAL02\SERIAL02.pem')
            { & $script:orchestrator @script:runArgs -Stage Execute -Execute -Confirm:$false 3>$null } | Should -Throw '*Refusing to submit*SERIAL02*'
            Should -Invoke New-AzResourceGroupDeployment -Times 0 -Exactly
            Should -Invoke Set-AzKeyVaultSecret -Times 0 -Exactly
        }

        It 'skips the deployment when every edge machine already exists' {
            $global:ztpMachines = @{ 'node-01' = 'provisioned'; 'node-02' = 'installing' }
            $null = & $script:orchestrator @script:runArgs -Stage Execute -Execute -Confirm:$false
            Should -Invoke New-AzResourceGroupDeployment -Times 0 -Exactly
        }

        It 'watches to ready and plans the Arc name map without writing it' {
            $global:ztpMachines = @{ 'node-01' = 'provisioned'; 'node-02' = 'provisioned' }
            $map = Join-Path $TestDrive 'arc.json'
            Set-Content -LiteralPath $map -Value '{ "node-01": "old-1" }' -NoNewline
            $rows = @(& $script:orchestrator @script:runArgs -Stage Watch -PollIntervalSeconds 0 -ArcMachineNameMapPath $map)
            ($rows | Where-Object { $_.PSObject.Properties['Change'] -and $_.Node -eq 'node-01' }).Change | Should -Be 'Update'
            (Get-Content -LiteralPath $map -Raw) | Should -Be '{ "node-01": "old-1" }'
        }

        It 'writes the Arc name map when Watch runs with -Execute' {
            $global:ztpMachines = @{ 'node-01' = 'provisioned'; 'node-02' = 'provisioned' }
            $map = Join-Path $TestDrive 'arc-written.json'
            $null = & $script:orchestrator @script:runArgs -Stage Watch -PollIntervalSeconds 0 -ArcMachineNameMapPath $map -Execute -Confirm:$false
            (Get-Content -LiteralPath $map -Raw | ConvertFrom-Json -AsHashtable)['node-02'] | Should -Be '00000000-0000-0000-0000-000000000000-1'
        }
    }

    Describe 'Ready to cluster (Test-ProvisionedMachines.ps1)' {
        BeforeAll { $script:machines = Join-Path $script:scripts 'Test-ProvisionedMachines.ps1' }
        BeforeEach {
            Mock Set-AzContext {}
            Mock Get-AzConnectedMachine {
                if ($Name) { return [pscustomobject]@{ Name = $Name; Status = 'Connected'; OSName = 'Azure Local' } }
                [pscustomobject]@{ Name = 'node'; Status = 'Connected'; OSName = 'Azure Local' }
            }
            Mock Get-AzConnectedMachineExtension {
                foreach ($n in 'AzureEdgeDeviceManagement', 'AzureEdgeLifecycleManager', 'AzureEdgeRemoteSupport', 'AzureEdgeTelemetryAndDiagnostics') { [pscustomobject]@{ Name = $n; ProvisioningState = 'Succeeded' } }
            }
        }

        It 'returns a ready row when Connected with every mandatory extension Succeeded' {
            $rows = @(& $script:machines -SubscriptionId test -ResourceGroupName test -ExpectedMachineName node -PassThru)
            $rows[0].Connected | Should -BeTrue
            $rows[0].ExtensionsReady | Should -BeTrue
            $rows[0].Detail | Should -BeLike 'Ready to cluster*'
            { & $script:machines -SubscriptionId test -ResourceGroupName test -ExpectedMachineName node } | Should -Not -Throw
        }

        It 'fails while a mandatory extension is not Succeeded' {
            Mock Get-AzConnectedMachineExtension {
                [pscustomobject]@{ Name = 'AzureEdgeDeviceManagement'; ProvisioningState = 'Succeeded' }
                [pscustomobject]@{ Name = 'AzureEdgeLifecycleManager'; ProvisioningState = 'Creating' }
            }
            $rows = @(& $script:machines -SubscriptionId test -ResourceGroupName test -ExpectedMachineName node -PassThru)
            $rows[0].ExtensionsReady | Should -BeFalse
            $rows[0].MissingExtensions | Should -Be @('AzureEdgeLifecycleManager', 'AzureEdgeRemoteSupport', 'AzureEdgeTelemetryAndDiagnostics')
            { & $script:machines -SubscriptionId test -ResourceGroupName test -ExpectedMachineName node } | Should -Throw
        }

        It 'reports an unexpected machine with PassThru and throws without it' {
            Mock Get-AzConnectedMachine {
                if ($Name) { return [pscustomobject]@{ Name = $Name; Status = 'Connected'; OSName = 'Azure Local' } }
                @([pscustomobject]@{ Name = 'node'; Status = 'Connected'; OSName = 'Azure Local' }, [pscustomobject]@{ Name = 'extra'; Status = 'Connected'; OSName = 'Azure Local' })
            }
            $rows = @(& $script:machines -SubscriptionId test -ResourceGroupName test -ExpectedMachineName node -PassThru)
            @($rows | Where-Object Detail -EQ 'unexpected machine').Count | Should -Be 1
            { & $script:machines -SubscriptionId test -ResourceGroupName test -ExpectedMachineName node } | Should -Throw
        }

        It 'reports a missing machine' {
            Mock Get-AzConnectedMachine { if ($Name) { $null } else { @() } }
            $rows = @(& $script:machines -SubscriptionId test -ResourceGroupName test -ExpectedMachineName node -PassThru)
            $rows[0].Exists | Should -BeFalse
            $rows[0].Detail | Should -Be 'Missing'
        }
    }
}
