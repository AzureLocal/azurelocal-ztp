#Requires -Version 7.0
<#
.SYNOPSIS
Azure half of simplified machine provisioning: site, site configuration and edge machines from the ownership vouchers,
then waits until every node is ready to cluster. Stages: Prereqs -> Validate -> Plan -> Execute -> Watch.
.DESCRIPTION
Deploys bicep/main.bicep, a template equivalent to the one the Azure portal deploys (site, Microsoft.Edge configuration
with network, time, connectivity and security settings, configurationReference, Azure Local resource provider role, one
edgeMachines per node, the edge machine's constrained role delegations on the resource group and on the Key Vault).
Inputs: a parameters file (-ParameterFile, JSON in the ARM parameters format, see bicep/main.example.parameters.json, or a
.bicepparam compiled with az bicep build-params) plus the script parameters. The run adds only run-time values, in memory:
  ownership_vouchers  node -> base64 of the voucher .pem bytes (secure object; never written, never printed)
  os_version          validated solution recipe version resolved from osImages?solution-type=HCI (-OsVersion)
  create_site / create_configuration  false when the site / configuration already exists (-SiteMode Auto, the default)
  node_filter         nodes whose edge machine does not exist yet (an existing edge machine is never re-PUT)
Stages:
  Prereqs   az with Bicep, Az.Resources, Az.KeyVault.
  Validate  az bicep build of the template and a read of the parameters file.
  Plan      read-only: OS image, existing site/configuration/edge machines, voucher files, provisioning admin secret
            (by name), then ARM what-if. The default run stops here.
  Execute   with -Execute only: writes the provisioning admin secret into the vault when it is missing (from
            -AdminPassword, in memory), submits the deployment, then Watch.
  Watch     Wait-ZtpMachineReady.ps1 until every node is Provisioned and ready to cluster (-RetryProvisionOs with
            -Execute resubmits a failed jobs/ProvisionOs), then Update-ArcMachineNames.ps1 (rows; writes
            -ArcMachineNameMapPath with -Execute). Resumes an interrupted run; never submits the deployment.
Sign in first (Connect-AzAccount); the operator needs Contributor and Role Based Access Control Administrator (or Owner) on
the resource group. The Microsoft.DeviceOnboarding/AzureLocalZTP feature and the resource providers must be registered.
Preview: East US only. Not yet proven end to end live: the scripted submit and the ProvisionOs retry (the portal-equivalent
template is proven).
.PARAMETER Stage
One stage, or All (Prereqs, Validate, Plan; Execute and Watch only with -Execute).
.PARAMETER SubscriptionId
Subscription of the deployment (for example 00000000-0000-0000-0000-000000000000).
.PARAMETER ResourceGroupName
Resource group of the site, configuration and edge machines (for example rg-example).
.PARAMETER ParameterFile
Parameters file, see bicep/main.example.parameters.json.
.PARAMETER VoucherPath
Folder with <serial>.pem or <serial>\*.pem per node (Read-ZtpVoucherFromImage.ps1 -OutputDirectory writes this layout).
.PARAMETER OsVersion
latest, latest-preview, a validated solution recipe version or a composed image version.
.PARAMETER SiteMode
Auto (create only what is missing), Create (always PUT the site and configuration), Reuse (require both to exist).
.PARAMETER Node
Limit the run to these node names.
.PARAMETER DeploymentName
Name of the resource group deployment.
.PARAMETER AdminPassword
Provisioning administrator password; written to the Key Vault secret only when that secret is missing and only with
-Execute. Never written to a file.
.PARAMETER ApiVersion
Microsoft.AzureStackHCI api-version for the GETs and the poller (edgeMachines and jobs: 2025-12-01-preview).
.PARAMETER TimeoutMinutes
Watch budget.
.PARAMETER PollIntervalSeconds
Watch poll interval.
.PARAMETER RetryProvisionOs
Watch: resubmit a failed jobs/ProvisionOs once (needs -Execute).
.PARAMETER ArcMachineNameMapPath
Watch: JSON file that receives the node -> Arc machine name map (with -Execute).
.PARAMETER Execute
Approval to change Azure (secret, deployment, ProvisionOs retry). Without it the run stops after Plan.
.EXAMPLE
./Invoke-ZtpAzureProvisioning.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example -ParameterFile ./bicep/main.parameters.json -VoucherPath D:\ZtpVouchers
.EXAMPLE
./Invoke-ZtpAzureProvisioning.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example -ParameterFile ./bicep/main.parameters.json -VoucherPath D:\ZtpVouchers -AdminPassword $adminPassword -ArcMachineNameMapPath ./arc-machine-names.json -Execute
.EXAMPLE
./Invoke-ZtpAzureProvisioning.ps1 -Stage Watch -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example -ParameterFile ./bicep/main.parameters.json -VoucherPath D:\ZtpVouchers -RetryProvisionOs -Execute
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The parameters are read inside the stage functions and script blocks.')]
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Prereqs', 'Validate', 'Plan', 'Execute', 'Watch', 'All')][string]$Stage = 'All',
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$ParameterFile,
    [Parameter(Mandatory)][string]$VoucherPath,
    [string]$OsVersion = 'latest',
    [ValidateSet('Auto', 'Create', 'Reuse')][string]$SiteMode = 'Auto',
    [string[]]$Node,
    [ValidatePattern('^[A-Za-z0-9._()-]{1,64}$')][string]$DeploymentName = 'ztp-provisioning',
    [securestring]$AdminPassword,
    [string]$ApiVersion = '2025-12-01-preview',
    [ValidateRange(0, 1440)][int]$TimeoutMinutes = 180,
    [ValidateRange(0, 3600)][int]$PollIntervalSeconds = 60,
    [switch]$RetryProvisionOs,
    [string]$ArcMachineNameMapPath,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpAzure.Common.ps1')

if ($Stage -eq 'Execute' -and -not $Execute) { throw 'Stage Execute requires -Execute. Nothing was submitted.' }
if ($Stage -eq 'All' -and -not $Execute) { Write-ZtpLog 'Plan only (default): the run stops after Plan. Add -Execute to claim and provision.' -Level Warning }

$bicepDir = Join-Path $PSScriptRoot 'bicep'
$templateFile = Join-Path $bicepDir 'main.bicep'
$siteApiVersion = '2025-03-01-preview'
$stages = if ($Stage -eq 'All') { @('Prereqs', 'Validate', 'Plan') + $(if ($Execute) { @('Execute', 'Watch') } else { @() }) } else { @($Stage) }
$script:ztpInputs = $null

function Invoke-ZtpNative {
    # Runs a native tool and throws with its stderr on a non-zero exit; stdout is returned.
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @())
    Write-ZtpLog "$FilePath $($ArgumentList -join ' ')" -Level Verbose
    $all = & $FilePath @ArgumentList 2>&1
    $stderr = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) { throw "$FilePath exited with code $LASTEXITCODE`n$($stderr -join "`n")" }
    return @($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
}

function Get-ZtpInput {
    # The parameters file as name -> value (JSON ARM parameters, or a .bicepparam compiled by az).
    if ($script:ztpInputs) { return $script:ztpInputs }
    if (-not (Test-Path -LiteralPath $ParameterFile)) { throw "Parameter file not found: $ParameterFile (copy bicep/main.example.parameters.json and edit it)." }
    $parameters = if ([IO.Path]::GetExtension($ParameterFile) -eq '.bicepparam') {
        $built = (Invoke-ZtpNative -FilePath 'az' -ArgumentList @('bicep', 'build-params', '--file', $ParameterFile, '--stdout')) -join "`n"
        (($built | ConvertFrom-Json -Depth 64).parametersJson | ConvertFrom-Json -AsHashtable -Depth 64).parameters
    }
    else {
        (Get-Content -LiteralPath $ParameterFile -Raw | ConvertFrom-Json -AsHashtable -Depth 64).parameters
    }
    $values = @{}
    foreach ($entry in $parameters.GetEnumerator()) { $values[$entry.Key] = $entry.Value['value'] }
    foreach ($required in 'location', 'nodes', 'azl_rp_app_object_id', 'key_vault_name', 'key_vault_resource_group', 'site_name', 'admin_username', 'admin_secret_name', 'time_zone') {
        if (-not $values.ContainsKey($required) -or -not $values[$required]) { throw "The parameters file has no value for '$required' (see bicep/main.example.parameters.json)." }
    }
    $script:ztpInputs = $values
    return $values
}

function Assert-ZtpAzContext {
    param([Parameter(Mandatory)][string]$SubscriptionId)
    $ctx = Get-AzContext
    if (-not $ctx) { throw 'No Az context. Run Connect-AzAccount (operator sign-in) first.' }
    if ($ctx.Subscription.Id -ne $SubscriptionId) { $null = Set-AzContext -Subscription $SubscriptionId -WhatIf:$false -ErrorAction Stop }
}

function Get-ZtpPlan {
    # Read-only state of everything the deployment touches.
    $in = Get-ZtpInput
    Assert-ZtpAzContext -SubscriptionId $SubscriptionId
    $image = Resolve-ZtpOsImage -Version $OsVersion -Catalog @(Get-ZtpOsImageCatalog -SubscriptionId $SubscriptionId -Location $in.location -ApiVersion $ApiVersion)
    if ($image.IsPreview) { Write-ZtpLog "OS image $($image.VsrVersion) is a preview build." -Level Warning }

    $rgPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers"
    $siteName = [string]$in.site_name
    $configurationName = if ($in.ContainsKey('configuration_name') -and $in.configuration_name) { [string]$in.configuration_name } else { 'default' }
    $site = Invoke-ZtpArm -Method GET -Path "$rgPath/Microsoft.Edge/sites/$siteName" -ApiVersion $siteApiVersion -AllowNotFound
    $configuration = Invoke-ZtpArm -Method GET -Path "$rgPath/Microsoft.Edge/configurations/$configurationName" -ApiVersion '2025-12-01-preview' -AllowNotFound
    switch ($SiteMode) {
        'Reuse' {
            if (-not $site -or -not $configuration) { throw "SiteMode Reuse: site '$siteName' exists=$([bool]$site), configuration '$configurationName' exists=$([bool]$configuration)." }
            $createSite = $false; $createConfiguration = $false
        }
        'Create' { $createSite = $true; $createConfiguration = $true }
        default { $createSite = -not $site; $createConfiguration = -not $configuration }
    }

    if ($Node) {
        $unknown = @($Node | Where-Object { $_ -notin @($in.nodes | ForEach-Object { $_.name }) })
        if ($unknown.Count -gt 0) { throw "Unknown node(s): $($unknown -join ', ')." }
    }
    $nodes = @($in.nodes | Where-Object { -not $Node -or $_.name -in $Node })
    $existing = @{}
    foreach ($n in $nodes) {
        $machine = Invoke-ZtpArm -Method GET -Path "$rgPath/Microsoft.AzureStackHCI/edgeMachines/$($n.name)" -ApiVersion $ApiVersion -AllowNotFound
        if ($machine) { $existing[$n.name] = Get-ZtpEdgeMachineStatus -Name $n.name -Machine $machine -Job $null }
    }
    $toClaim = @($nodes | Where-Object { -not $existing.ContainsKey($_.name) })
    $vouchers = if ($toClaim.Count -gt 0) { Find-ZtpVoucherFile -VoucherPath $VoucherPath -Nodes $toClaim } else { @{ Files = @{}; Missing = @() } }

    $secretName = [string]$in.admin_secret_name
    $secretPresent = [bool](@(Get-AzKeyVaultSecret -VaultName $in.key_vault_name -ErrorAction Stop) | Where-Object { $_.Name -eq $secretName })
    return [pscustomobject]@{
        SubscriptionId        = $SubscriptionId
        ResourceGroup         = $ResourceGroupName
        DeploymentName        = $DeploymentName
        Image                 = $image
        SiteName              = $siteName
        CreateSite            = $createSite
        CreateConfiguration   = $createConfiguration
        Nodes                 = $nodes
        Existing              = $existing
        ToClaim               = $toClaim
        VoucherFiles          = $vouchers.Files
        VoucherProblems       = @($vouchers.Missing)
        KeyVaultName          = [string]$in.key_vault_name
        SecretName            = $secretName
        SecretPresent         = $secretPresent
        AdminSecretResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$($in.key_vault_resource_group)/providers/Microsoft.KeyVault/vaults/$($in.key_vault_name)/secrets/$secretName"
    }
}

function Get-ZtpTemplateParameter {
    # Parameters file values + run-time values for New-AzResourceGroupDeployment (vouchers only in memory).
    param([Parameter(Mandatory)][object]$Plan, [hashtable]$Voucher = @{})
    $p = @{}
    foreach ($entry in (Get-ZtpInput).GetEnumerator()) { $p[$entry.Key] = $entry.Value }
    $claim = $Plan.ToClaim.Count -gt 0 -and $Voucher.Count -eq $Plan.ToClaim.Count
    $p.os_version = [string]$Plan.Image.VsrVersion
    $p.create_site = [bool]$Plan.CreateSite
    $p.create_configuration = [bool]$Plan.CreateConfiguration
    $p.claim_machines = $claim
    $p.node_filter = @($Plan.ToClaim | ForEach-Object { [string]$_.name })
    $p.ownership_vouchers = $Voucher
    return $p
}

function Read-ZtpVoucher {
    param([Parameter(Mandatory)][object]$Plan)
    $values = @{}
    foreach ($n in $Plan.ToClaim) {
        if ($Plan.VoucherFiles.ContainsKey($n.name)) { $values[$n.name] = ConvertTo-ZtpVoucherValue -Path $Plan.VoucherFiles[$n.name] }
    }
    return $values
}

function Write-ZtpPlan {
    param([Parameter(Mandatory)][object]$Plan)
    Write-ZtpLog "OS image: $($Plan.Image.VsrVersion) (composed image $($Plan.Image.ComposedImageVersion))."
    Write-ZtpLog "Site '$($Plan.SiteName)': $(if ($Plan.CreateSite) { 'create' } else { 'reuse' }); configuration: $(if ($Plan.CreateConfiguration) { 'create' } else { 'reuse' })."
    Write-ZtpLog "Provisioning admin secret '$($Plan.SecretName)' in '$($Plan.KeyVaultName)': $(if ($Plan.SecretPresent) { 'present' } else { 'missing (Execute writes it from -AdminPassword)' })."
    foreach ($n in $Plan.Nodes) {
        if ($Plan.Existing.ContainsKey($n.name)) {
            $s = $Plan.Existing[$n.name]
            Write-ZtpLog "Node $($n.name): edge machine exists (lifecycle $($s.Lifecycle)); not re-PUT. Watch follows it; a failed one is retried with -Stage Watch -RetryProvisionOs -Execute."
        }
        else {
            $voucher = if ($Plan.VoucherFiles.ContainsKey($n.name)) { Split-Path $Plan.VoucherFiles[$n.name] -Leaf } else { 'NO VOUCHER' }
            Write-ZtpLog "Node $($n.name): claim with voucher $voucher."
        }
    }
    foreach ($problem in $Plan.VoucherProblems) { Write-ZtpLog $problem -Level Warning }
}

$started = Get-Date
foreach ($current in $stages) {
    Write-ZtpLog "=== Stage: $current ==="
    switch ($current) {
        'Prereqs' {
            foreach ($cmd in 'az', 'Get-AzContext', 'New-AzResourceGroupDeployment', 'Get-AzKeyVaultSecret') {
                if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw "'$cmd' is not available (az CLI with Bicep, Az.Resources, Az.KeyVault)." }
            }
            $null = Invoke-ZtpNative -FilePath 'az' -ArgumentList @('bicep', 'version')
            Write-ZtpLog 'Gate: maintenance environment running on every node (vouchers collected), Microsoft.DeviceOnboarding/AzureLocalZTP feature and providers registered, operator Contributor + RBAC Administrator on the resource group.'
        }
        'Validate' {
            foreach ($file in @($templateFile) + @(Get-ChildItem -Path (Join-Path $bicepDir 'modules') -Filter '*.bicep' -ErrorAction SilentlyContinue | ForEach-Object FullName)) {
                $null = Invoke-ZtpNative -FilePath 'az' -ArgumentList @('bicep', 'build', '--file', $file, '--stdout')
            }
            $null = Get-ZtpInput
            Write-ZtpLog 'Template builds and the parameters file is complete.'
        }
        'Plan' {
            $plan = Get-ZtpPlan
            Write-ZtpPlan -Plan $plan
            $voucher = if ($plan.VoucherProblems.Count -eq 0) { Read-ZtpVoucher -Plan $plan } else { @{} }
            if ($plan.ToClaim.Count -gt 0 -and $voucher.Count -ne $plan.ToClaim.Count) { Write-ZtpLog 'What-if covers the site and its configuration only: not every node to claim has a voucher yet.' -Level Warning }
            $whatIf = Get-AzResourceGroupDeploymentWhatIfResult -ResourceGroupName $plan.ResourceGroup -TemplateFile $templateFile `
                -TemplateParameterObject (Get-ZtpTemplateParameter -Plan $plan -Voucher $voucher) -ResultFormat ResourceIdOnly
            $voucher = $null
            foreach ($change in @($whatIf.Changes)) {
                Write-ZtpLog ("what-if {0,-8} {1}" -f $change.ChangeType, ($change.FullyQualifiedResourceId -replace '^/subscriptions/[^/]+', ''))
            }
            $plan
        }
        'Execute' {
            if (-not $Execute) { throw 'Execute requires -Execute.' }
            # Fresh state guard (a standalone -Stage Execute cannot skip it).
            $plan = Get-ZtpPlan
            Write-ZtpPlan -Plan $plan
            if ($plan.ToClaim.Count -eq 0 -and -not $plan.CreateSite -and -not $plan.CreateConfiguration) {
                Write-ZtpLog 'Nothing to claim: every edge machine exists and the site is in place. Continuing with Watch.'
                break
            }
            if ($plan.VoucherProblems.Count -gt 0) { throw "Refusing to submit: $($plan.VoucherProblems -join ' ')" }
            if (-not $plan.SecretPresent -and -not $AdminPassword) {
                throw "Secret '$($plan.SecretName)' is missing in '$($plan.KeyVaultName)': pass -AdminPassword (a SecureString) or create the secret first. Nothing was submitted."
            }
            if (-not $PSCmdlet.ShouldProcess("$($plan.ResourceGroup): site $($plan.SiteName), $(@($plan.ToClaim).Count) edge machine(s) on $($plan.Image.VsrVersion)", 'Claim and provision Azure Local machines')) { break }
            if (-not $plan.SecretPresent) {
                # Same shape as the portal's secret: the password as the value, no content type, no expiry, no tags.
                $null = Set-AzKeyVaultSecret -VaultName $plan.KeyVaultName -Name $plan.SecretName -SecretValue $AdminPassword -Confirm:$false
                Write-ZtpLog "Wrote secret '$($plan.SecretName)' to '$($plan.KeyVaultName)' (value not shown)."
            }
            $voucher = Read-ZtpVoucher -Plan $plan
            $parameters = Get-ZtpTemplateParameter -Plan $plan -Voucher $voucher
            $submitAt = [datetime]::UtcNow
            $job = New-AzResourceGroupDeployment -Name $plan.DeploymentName -ResourceGroupName $plan.ResourceGroup -TemplateFile $templateFile `
                -TemplateParameterObject $parameters -Mode Incremental -AsJob -Confirm:$false
            $voucher = $null; $parameters = $null
            # The edge machine PUTs run until the machines provision; wait only until ARM has accepted the deployment.
            $accepted = $false
            $acceptDeadline = $submitAt.AddMinutes(10)
            while (-not $accepted -and [datetime]::UtcNow -lt $acceptDeadline) {
                if ($job.State -eq 'Failed') { throw "The deployment was not accepted: $((Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErrors 2>&1 | Out-String).Trim()) $($jobErrors -join ' ')" }
                $record = Get-AzResourceGroupDeployment -ResourceGroupName $plan.ResourceGroup -Name $plan.DeploymentName -ErrorAction SilentlyContinue
                if ($record -and $record.Timestamp.ToUniversalTime() -ge $submitAt.AddMinutes(-2)) {
                    if ($record.ProvisioningState -eq 'Failed') { throw "Deployment '$($plan.DeploymentName)' failed. Inspect the resource group's Deployments blade." }
                    $accepted = $true
                    Write-ZtpLog "Deployment '$($plan.DeploymentName)' accepted ($($record.ProvisioningState))."
                }
                else { Start-Sleep -Seconds ([Math]::Min(15, [Math]::Max(1, $PollIntervalSeconds))) }
            }
            if (-not $accepted) { throw "Deployment '$($plan.DeploymentName)' did not appear within 10 minutes; check the Deployments blade, then resume with -Stage Watch." }
        }
        'Watch' {
            $in = Get-ZtpInput
            Assert-ZtpAzContext -SubscriptionId $SubscriptionId
            $names = @($in.nodes | Where-Object { -not $Node -or $_.name -in $Node } | ForEach-Object { [string]$_.name })
            $wait = @{
                SubscriptionId        = $SubscriptionId
                ResourceGroupName     = $ResourceGroupName
                EdgeMachineName       = $names
                ApiVersion            = $ApiVersion
                TimeoutMinutes        = $TimeoutMinutes
                PollIntervalSeconds   = $PollIntervalSeconds
                RetryProvisionOs      = $RetryProvisionOs
                AdminSecretResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$($in.key_vault_resource_group)/providers/Microsoft.KeyVault/vaults/$($in.key_vault_name)/secrets/$($in.admin_secret_name)"
                Execute               = $Execute
            }
            if ($Execute) { $wait.Confirm = $false }
            $ready = & (Join-Path $PSScriptRoot 'Wait-ZtpMachineReady.ps1') @wait
            $ready | Format-Table Node, Lifecycle, JobStatus, Connectivity, ArcMachineName -AutoSize | Out-String | Write-Information -InformationAction Continue
            $arc = @{ SubscriptionId = $SubscriptionId; ResourceGroupName = $ResourceGroupName; NodeName = $names; ApiVersion = $ApiVersion }
            if ($ArcMachineNameMapPath) {
                $arc.MapPath = $ArcMachineNameMapPath
                $arc.Execute = [bool]$Execute
                if ($Execute) { $arc.Confirm = $false }
            }
            & (Join-Path $PSScriptRoot 'Update-ArcMachineNames.ps1') @arc
            Write-ZtpLog "Next: Test-ProvisionedMachines.ps1 -ExpectedMachineName $(@($ready | ForEach-Object ArcMachineName) -join ','), then cluster deployment with each edge machine's arcMachineResourceId."
        }
    }
}
Write-ZtpLog "Run took $([int]((Get-Date) - $started).TotalMinutes) min."
