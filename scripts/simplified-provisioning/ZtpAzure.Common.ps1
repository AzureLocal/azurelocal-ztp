#Requires -Version 7.0
<#
.SYNOPSIS
Shared helpers of the Azure half of simplified machine provisioning (dot-sourced by Invoke-ZtpAzureProvisioning.ps1,
Get-ZtpOsImage.ps1, Wait-ZtpMachineReady.ps1 and Update-ArcMachineNames.ps1).
.DESCRIPTION
ARM transport (Invoke-AzRestMethod under the operator's Az context; no token ever leaves memory), the HCI OS image
catalog, ownership voucher files, edge machine and ProvisionOs job status, and the Learn ProvisionOs retry body. Response shapes are the ones a live run returned (edgeMachines and
edgeMachines/jobs, api-version 2025-12-01-preview; fixtures in tests/simplified-provisioning/fixtures). Nothing here prints a voucher or a secret.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Mandatory Arc extensions of a provisioned machine (extension resource names on the Arc machine).
$script:ZtpRequiredExtensions = @('AzureEdgeDeviceManagement', 'AzureEdgeLifecycleManager', 'AzureEdgeRemoteSupport', 'AzureEdgeTelemetryAndDiagnostics')
$script:ZtpDefaultApiVersion = '2025-12-01-preview'

function Write-ZtpLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Warning', 'Verbose')][string]$Level = 'Info'
    )
    $line = "[$([datetime]::UtcNow.ToString('HH:mm:ss'))Z] $Message"
    switch ($Level) {
        'Warning' { Write-Warning $line }
        'Verbose' { Write-Verbose $line }
        default { Write-Information -MessageData $line -InformationAction Continue }
    }
}

function Get-ZtpPropertyValue {
    # StrictMode-safe property read on a deserialized JSON object (missing property -> $Default).
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Name, [object]$Default = $null)
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function Get-ZtpPathValue {
    # Get-ZtpPathValue $obj 'properties.lifecycleDetails.lifecycleStatus.status'
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Path, [object]$Default = $null)
    $current = $InputObject
    foreach ($part in $Path.Split('.')) {
        $current = Get-ZtpPropertyValue -InputObject $current -Name $part
        if ($null -eq $current) { return $Default }
    }
    return $current
}

function Invoke-ZtpArm {
    <#
    .SYNOPSIS
    One ARM call through Invoke-AzRestMethod (transport seam; the tests mock it). Returns the parsed body, or $null for a
    404 with -AllowNotFound. Errors carry the status and the ARM error code and message, never the request body.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'PUT')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [string]$ApiVersion = $script:ZtpDefaultApiVersion,
        [hashtable]$Query = @{},
        [object]$Body,
        [switch]$AllowNotFound
    )
    $pairs = @("api-version=$ApiVersion") + @($Query.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString([string]$_.Value))" })
    $request = @{ Method = $Method; Path = "$Path`?$($pairs -join '&')" }
    if ($null -ne $Body) { $request.Payload = ($Body | ConvertTo-Json -Depth 40 -Compress) }
    $response = Invoke-AzRestMethod @request
    $status = [int]$response.StatusCode
    if ($status -eq 404 -and $AllowNotFound) { return $null }
    if ($status -ge 400) {
        $code = ''; $message = ''
        try {
            $parsed = $response.Content | ConvertFrom-Json -Depth 20
            $code = [string](Get-ZtpPathValue $parsed 'error.code' '')
            $message = [string](Get-ZtpPathValue $parsed 'error.message' '')
        }
        catch { $code = 'unparsed' }
        throw "ARM $Method $Path returned $status $code $message".Trim()
    }
    if ([string]::IsNullOrWhiteSpace([string]$response.Content)) { return $null }
    return ($response.Content | ConvertFrom-Json -Depth 64)
}

# ------------------------------------------------------------------ OS image catalog
function Test-ZtpPreviewOsVersion {
    <#
    .SYNOPSIS
    True when the release part of a 12.YYMM.x.y version is not a calendar month (a preview build: a non-calendar month in
    12.YYMM, for example 12.26NN with NN above 12).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Version)
    $parts = $Version.Split('.')
    if ($parts.Count -lt 2 -or $parts[1] -notmatch '^\d{4}$') { return $false }
    $month = [int]$parts[1].Substring(2, 2)
    return ($month -lt 1 -or $month -gt 12)
}

function Get-ZtpOsImageCatalog {
    <#
    .SYNOPSIS
    Reads locations/<location>/osImages?solution-type=HCI (read-only) and returns one row per image, newest first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [string]$ApiVersion = $script:ZtpDefaultApiVersion
    )
    $catalog = Invoke-ZtpArm -Method GET -ApiVersion $ApiVersion -Query @{ 'solution-type' = 'HCI' } `
        -Path "/subscriptions/$SubscriptionId/providers/Microsoft.AzureStackHCI/locations/$Location/osImages"
    $rows = foreach ($item in @(Get-ZtpPropertyValue $catalog 'value' @())) {
        $p = Get-ZtpPropertyValue $item 'properties'
        $vsr = [string](Get-ZtpPropertyValue $p 'validatedSolutionRecipeVersion' '')
        if (-not $vsr) { continue }
        [pscustomobject]@{
            VsrVersion           = $vsr
            ComposedImageVersion = [string](Get-ZtpPropertyValue $p 'composedImageVersion' '')
            IsoUrl               = [string](Get-ZtpPropertyValue $p 'composedImageIsoUrl' '')
            IsoHash              = [string](Get-ZtpPropertyValue $p 'composedImageIsoHash' '')
            IsPreview            = Test-ZtpPreviewOsVersion -Version $vsr
        }
    }
    return @($rows | Sort-Object -Property @{ Expression = { [version]$_.VsrVersion } } -Descending)
}

function Resolve-ZtpOsImage {
    <#
    .SYNOPSIS
    Picks one catalog row: 'latest' = newest release build (calendar-month YYMM), 'latest-preview' = newest of all,
    otherwise an exact validated solution recipe version (12.2609.1003.7) or composed image version (12.2609.0.3009).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Catalog,
        [Parameter(Mandatory)][string]$Version
    )
    $offered = ($Catalog | ForEach-Object { $_.VsrVersion }) -join ', '
    $pick = switch ($Version) {
        'latest' { $Catalog | Where-Object { -not $_.IsPreview } | Select-Object -First 1 }
        'latest-preview' { $Catalog | Select-Object -First 1 }
        default { $Catalog | Where-Object { $_.VsrVersion -eq $Version -or $_.ComposedImageVersion -eq $Version } | Select-Object -First 1 }
    }
    if (-not $pick) { throw "OS image '$Version' is not in the HCI catalog. Offered: $offered" }
    return $pick
}

# ------------------------------------------------------------------ ownership vouchers
function Find-ZtpVoucherFile {
    <#
    .SYNOPSIS
    Maps each node to exactly one voucher file by serial (<serial>.pem or <serial>\*.pem, the maintenance-environment
    layout \vouchers\<serial>\*.pem). Returns @{ Files = @{ node = path }; Missing = @(problem text) }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$VoucherPath,
        [Parameter(Mandatory)][object[]]$Nodes
    )
    $files = @{}
    $missing = [System.Collections.Generic.List[string]]::new()
    $all = @()
    if ($VoucherPath -and (Test-Path -LiteralPath $VoucherPath -PathType Container)) {
        $all = @(Get-ChildItem -LiteralPath $VoucherPath -Filter '*.pem' -File -Recurse)
    }
    elseif ($VoucherPath) { $missing.Add("Voucher folder '$VoucherPath' does not exist.") }
    else { $missing.Add('No voucher folder (provisioning.voucher_directory or -VoucherPath).') }
    foreach ($node in $Nodes) {
        $name = [string](Get-ZtpPropertyValue $node 'name')
        $serial = [string](Get-ZtpPropertyValue $node 'service_tag' (Get-ZtpPropertyValue $node 'serial' ''))
        if (-not $serial) { $missing.Add("Node ${name}: no service_tag (serial) to find its voucher."); continue }
        $match = @($all | Where-Object { $_.BaseName -eq $serial -or $_.Directory.Name -eq $serial })
        if ($match.Count -eq 1) { $files[$name] = $match[0].FullName }
        elseif ($all.Count -gt 0 -or $VoucherPath) { $missing.Add("Node ${name}: expected exactly one voucher for serial $serial; found $($match.Count).") }
    }
    return @{ Files = $files; Missing = @($missing) }
}

function ConvertTo-ZtpVoucherValue {
    <#
    .SYNOPSIS
    Reads a voucher .pem and returns base64 of its bytes (the portal's format; API: "Ownership voucher in base64 encoded
    format"). Validates the PEM armour; the content is never printed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = [System.Text.Encoding]::ASCII.GetString($bytes).Trim([char]0xFEFF, ' ', "`r", "`n", "`t")
    if ($bytes.Length -eq 0 -or $text -notmatch '^-----BEGIN [A-Z ]+-----' -or $text -notmatch '-----END [A-Z ]+-----$') {
        throw "Voucher '$([System.IO.Path]::GetFileName($Path))' is empty or not a complete PEM block."
    }
    return [Convert]::ToBase64String($bytes)
}

# ------------------------------------------------------------------ edge machine and ProvisionOs job status
function Get-ZtpEdgeMachineStatus {
    <#
    .SYNOPSIS
    Summarises one edge machine (and its jobs/ProvisionOs, when submitted) into a status row: lifecycle, current stage,
    job state, Arc machine, mandatory extensions, Ready (ready to cluster) and Failed (terminal) with the reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Machine,
        [AllowNull()][object]$Job,
        [string[]]$RequiredExtension = $script:ZtpRequiredExtensions
    )
    if ($null -eq $Machine) {
        return [pscustomobject]@{
            Node = $Name; Exists = $false; Lifecycle = 'Missing'; Message = ''; ProvisioningState = ''; MachineState = ''
            Connectivity = ''; CurrentStage = ''; JobStatus = ''; JobDeploymentStatus = ''; ArcMachineResourceId = ''
            ArcMachineName = ''; MissingExtensions = @($RequiredExtension); Ready = $false; Failed = $false; FailureReason = ''
        }
    }
    $p = Get-ZtpPropertyValue $Machine 'properties'
    $lifecycle = [string](Get-ZtpPathValue $p 'lifecycleDetails.lifecycleStatus.status' '')
    $message = [string](Get-ZtpPathValue $p 'lifecycleDetails.lifecycleStatus.message' '')
    $provisioningState = [string](Get-ZtpPropertyValue $p 'provisioningState' '')
    $stages = @(Get-ZtpPathValue $p 'lifecycleDetails.lifecycleStages' @())
    $current = ''
    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($stage in $stages) {
        $stageName = [string](Get-ZtpPropertyValue $stage 'name' '')
        $stageStatus = [string](Get-ZtpPropertyValue $stage 'status' '')
        if ($stageStatus -match 'Fail') { $failures.Add("stage $stageName $stageStatus") }
        foreach ($sub in @(Get-ZtpPropertyValue $stage 'subStages' @())) {
            $subName = [string](Get-ZtpPropertyValue $sub 'name' '')
            $subStatus = [string](Get-ZtpPropertyValue $sub 'status' '')
            if ($subStatus -match 'Fail') { $failures.Add("stage $stageName/$subName $subStatus") }
            if (-not $current -and $subStatus -and $subStatus -notin @('Completed', 'NotStarted', 'Skipped')) { $current = "$stageName/$subName=$subStatus" }
        }
    }
    if ($lifecycle -match 'Fail') { $failures.Insert(0, "lifecycle $lifecycle") }
    if ($provisioningState -eq 'Failed') { $failures.Add('edge machine provisioningState Failed') }

    $jobStatus = ''; $jobDeployment = ''
    if ($null -ne $Job) {
        $jp = Get-ZtpPropertyValue $Job 'properties'
        $jobStatus = [string](Get-ZtpPropertyValue $jp 'status' '')
        $jobDeployment = [string](Get-ZtpPathValue $jp 'reportedProperties.deploymentStatus.status' '')
        $jobProvisioning = [string](Get-ZtpPropertyValue $jp 'provisioningState' '')
        if ($jobStatus -match 'Fail') { $failures.Add("job $jobStatus") }
        if ($jobProvisioning -eq 'Failed') { $failures.Add('job provisioningState Failed') }
        if ($jobDeployment -match 'Fail') { $failures.Add("job deployment $jobDeployment") }
        foreach ($step in @(Get-ZtpPathValue $jp 'reportedProperties.deploymentStatus.steps' @())) {
            $stepStatus = [string](Get-ZtpPropertyValue $step 'status' '')
            if ($stepStatus -match 'Fail|Error') { $failures.Add("step $([string](Get-ZtpPropertyValue $step 'name' '')) $stepStatus") }
        }
    }
    else {
        # Before the job is readable, operationDetails still carries its state.
        $op = @(Get-ZtpPropertyValue $p 'operationDetails' @()) | Where-Object { [string](Get-ZtpPropertyValue $_ 'name' '') -eq 'ProvisionOs' } | Select-Object -First 1
        if ($op) {
            $opStatus = [string](Get-ZtpPropertyValue $op 'status' '')
            $jobStatus = if ($opStatus -eq 'Succeeded') { 'DeploymentSuccess' } else { "operation:$opStatus" }
            if ($opStatus -match 'Fail') { $failures.Add("operation ProvisionOs $opStatus") }
        }
    }

    $arcId = [string](Get-ZtpPropertyValue $p 'arcMachineResourceId' '')
    $extensions = @{}
    foreach ($ext in @(Get-ZtpPathValue $p 'reportedProperties.extensionProfile.extensions' @())) {
        $leaf = ([string](Get-ZtpPropertyValue $ext 'extensionResourceId' '')).Split('/')[-1]
        if ($leaf) { $extensions[$leaf] = [string](Get-ZtpPropertyValue $ext 'state' '') }
    }
    $missingExtensions = @($RequiredExtension | Where-Object { -not $extensions.ContainsKey($_) -or $extensions[$_] -ne 'Succeeded' })
    $connectivity = [string](Get-ZtpPropertyValue $p 'connectivityStatus' '')
    $checks = @(
        ($lifecycle -eq 'Provisioned'), ($jobStatus -eq 'DeploymentSuccess'), ($connectivity -eq 'Connected'),
        [bool]$arcId, ($missingExtensions.Count -eq 0), ($failures.Count -eq 0)
    )
    $ready = $checks -notcontains $false
    return [pscustomobject]@{
        Node                 = $Name
        Exists               = $true
        Lifecycle            = $lifecycle
        Message              = $message
        ProvisioningState    = $provisioningState
        MachineState         = [string](Get-ZtpPropertyValue $p 'machineState' '')
        Connectivity         = $connectivity
        CurrentStage         = $current
        JobStatus            = $jobStatus
        JobDeploymentStatus  = $jobDeployment
        ArcMachineResourceId = $arcId
        ArcMachineName       = if ($arcId) { $arcId.Split('/')[-1] } else { '' }
        MissingExtensions    = $missingExtensions
        Ready                = $ready
        Failed               = ($failures.Count -gt 0)
        FailureReason        = ($failures -join '; ')
    }
}

function Format-ZtpTime {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Value)
    $text = [string]$Value
    if (-not $text -or $text -like '0001-01-01*' -or $text -like '1/1/0001*') { return '' }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($text, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return $parsed.ToString('HH:mm:ss')
    }
    return $text
}

function Get-ZtpProgressItem {
    <#
    .SYNOPSIS
    Flattens one poll into keyed progress items (lifecycle, every stage/sub-stage, every job step) with their timestamps,
    so the waiter prints each change once.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Machine,
        [AllowNull()][object]$Job
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $p = Get-ZtpPropertyValue $Machine 'properties'
    if ($p) {
        $status = Get-ZtpPathValue $p 'lifecycleDetails.lifecycleStatus'
        $text = "lifecycle $([string](Get-ZtpPropertyValue $status 'status' '?'))"
        $msg = [string](Get-ZtpPropertyValue $status 'message' '')
        if ($msg) { $text += " - $msg" }
        $items.Add([pscustomobject]@{ Key = "$Name|lifecycle"; Text = $text })
        foreach ($stage in @(Get-ZtpPathValue $p 'lifecycleDetails.lifecycleStages' @())) {
            $stageName = [string](Get-ZtpPropertyValue $stage 'name' '')
            foreach ($entry in @($stage) + @(Get-ZtpPropertyValue $stage 'subStages' @())) {
                $entryName = [string](Get-ZtpPropertyValue $entry 'name' '')
                $label = if ($entry -eq $stage) { $stageName } else { "$stageName/$entryName" }
                $entryStatus = [string](Get-ZtpPropertyValue $entry 'status' '')
                $items.Add([pscustomobject]@{
                        Key  = "$Name|stage|$label"
                        Text = "stage $label $entryStatus (start $(Format-ZtpTime (Get-ZtpPropertyValue $entry 'startTimeUtc')), end $(Format-ZtpTime (Get-ZtpPropertyValue $entry 'endTimeUtc')))"
                        Status = $entryStatus
                    })
            }
        }
    }
    $jp = Get-ZtpPropertyValue $Job 'properties'
    if ($jp) {
        $items.Add([pscustomobject]@{ Key = "$Name|job"; Text = "job ProvisionOs $([string](Get-ZtpPropertyValue $jp 'status' '')) ($([string](Get-ZtpPropertyValue $jp 'provisioningState' '')))" })
        $seen = @{}
        foreach ($step in @(Get-ZtpPathValue $jp 'reportedProperties.deploymentStatus.steps' @())) {
            $stepName = [string](Get-ZtpPropertyValue $step 'name' '')
            $seen[$stepName] = 1 + [int]($seen[$stepName] ?? 0)
            $key = if ($seen[$stepName] -gt 1) { "$stepName#$($seen[$stepName])" } else { $stepName }
            $stepStatus = [string](Get-ZtpPropertyValue $step 'status' '')
            $items.Add([pscustomobject]@{
                    Key  = "$Name|step|$key"
                    Text = "step $stepName $stepStatus (start $(Format-ZtpTime (Get-ZtpPropertyValue $step 'startTimeUtc')), end $(Format-ZtpTime (Get-ZtpPropertyValue $step 'endTimeUtc'))) $([string](Get-ZtpPropertyValue $step 'description' ''))".TrimEnd()
                    Status = $stepStatus
                })
        }
    }
    return $items.ToArray()
}

function Get-ZtpProvisionOsRetryBody {
    <#
    .SYNOPSIS
    The jobs/ProvisionOs re-PUT body of Microsoft's troubleshooting article: osProfile and userDetails from the edge
    machine, target HCI, jobType ProvisionOs. A userDetails entry without secretLocation takes -AdminSecretResourceId.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Machine,
        [string]$AdminSecretResourceId
    )
    $details = Get-ZtpPathValue $Machine 'properties.provisioningDetails'
    $osProfile = Get-ZtpPropertyValue $details 'osProfile'
    $userDetails = @(Get-ZtpPropertyValue $details 'userDetails' @())
    if ($null -eq $osProfile -or $userDetails.Count -eq 0) {
        throw "Edge machine $([string](Get-ZtpPropertyValue $Machine 'name' '')) has no provisioningDetails.osProfile/userDetails to resubmit."
    }
    $users = foreach ($user in $userDetails) {
        $entry = [ordered]@{}
        foreach ($prop in $user.PSObject.Properties) { $entry[$prop.Name] = $prop.Value }
        if ([string]($entry['secretType']) -eq 'KeyVault' -and -not $entry['secretLocation']) {
            if (-not $AdminSecretResourceId) { throw 'The edge machine does not return userDetails.secretLocation; pass -AdminSecretResourceId (the Key Vault secret ARM ID).' }
            $entry['secretLocation'] = $AdminSecretResourceId
        }
        $entry
    }
    return @{
        properties = @{
            jobType             = 'ProvisionOs'
            provisioningRequest = @{ osProfile = $osProfile; userDetails = @($users); target = 'HCI' }
        }
    }
}
