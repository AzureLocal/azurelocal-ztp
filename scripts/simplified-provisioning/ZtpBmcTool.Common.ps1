#Requires -Version 7.0
<#
.SYNOPSIS
Shared input handling of the BMC tools (dot-sourced by Get-ZtpBmcJob.ps1, Get-ZtpBootSetting.ps1, Reset-ZtpBmc.ps1 and
Reset-ZtpBootSequence.ps1).
.DESCRIPTION
The tools read the master infrastructure.yml (schema 5) through the reader every simplified-provisioning script uses
(Read-ZtpInfrastructure in ZtpEnvironment.Common.ps1), and only these keys of it:
    nodes[].name, nodes[].bmc.ip_address      the nodes and their BMCs
    hardware.bmc.username, .password          the BMC login, as secret references (keyvault://, env://, file://, command://)
    hardware.bmc.verify_certificate           check the BMC's TLS certificate (default false: BMCs ship a self-signed one)
    hardware.vendor                           Reset-ZtpBootSequence.ps1 only (Dell)
The BMC login is -Credential, else the file's secret references read by the toolkit's resolver (Resolve-AzlBmcCredential
in azurelocal-toolkit scripts/common/redfish/AzlRedfishCore.psm1, which uses scripts/common/secrets/AzlSecret.psm1). The
toolkit is found under $env:AZL_TOOLKIT_ROOT, else in an azurelocal-toolkit clone next to this repository. Nothing here
prompts. A missing or unusable input is an exception whose Data['ZtpExit'] is 2; the tools turn it into exit code 2.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Read-ZtpInfrastructure -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ZtpEnvironment.Common.ps1') }

function New-ZtpBmcToolInputError {
    # An input problem (exit code 2): the message says what to pass or fix.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an exception object only.')]
    [CmdletBinding()]
    [OutputType([System.ArgumentException])]
    param([Parameter(Mandatory)][string]$Message)
    return (New-ZtpInputError -Message $Message)
}

function Get-ZtpBmcToolExitCode {
    # 2 for an input problem (ZtpExit or the toolkit resolver's AzlExit 2), else 1.
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    $data = $ErrorRecord.Exception.Data
    foreach ($key in 'ZtpExit', 'AzlExit') { if ($data.Contains($key)) { return [int]$data[$key] } }
    return 1
}

function Find-ZtpToolkitRedfishModule {
    <#
    .SYNOPSIS
    The toolkit's AzlRedfishCore.psm1 (it holds Resolve-AzlBmcCredential and loads the toolkit's secret resolver):
    under $env:AZL_TOOLKIT_ROOT when that is set (only there), else in an azurelocal-toolkit clone next to this repository
    (Get-ZtpToolkitRoot). $null when there is none.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Find-ZtpToolkitFile -Relative 'scripts\common\redfish\AzlRedfishCore.psm1')
}

function Read-ZtpBmcToolInput {
    <#
    .SYNOPSIS
    Reads the infrastructure file and returns the selected nodes with their BMC addresses, the TLS choice and the vendor.
    Throws an input error (exit code 2) for a missing file, a file that isn't schema 5, an unknown node or a node without a
    BMC address. Doesn't read a secret.
    .PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5).
    .PARAMETER NodeName
    Nodes to cover (nodes[].name); default every node in the file.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$InfrastructureFile,
        [string[]]$NodeName
    )
    if (-not (Test-Path -LiteralPath $InfrastructureFile -PathType Leaf)) { throw (New-ZtpBmcToolInputError "The infrastructure file '$InfrastructureFile' doesn't exist. Pass -InfrastructureFile with the path of your infrastructure.yml (schema 5).") }
    try {
        # The same reader the provisioning run uses: anything but a schema 5 file is an input error. Only the keys above
        # matter here, so the toolkit's whole-file validation is skipped, as the toolkit's own BMC scripts do.
        $environment = Read-ZtpInfrastructure -Path $InfrastructureFile -ToolkitModulePath none
        $raw = $environment['_source']['infrastructure']
    }
    catch {
        if ($_.Exception.Data.Contains('ZtpExit')) { throw }
        throw (New-ZtpBmcToolInputError "Cannot read the infrastructure file: $($_.Exception.Message)")
    }
    try { $selected = @(Resolve-ZtpNodeSelection -Environment $environment -Node $NodeName) }
    catch { throw (New-ZtpBmcToolInputError $_.Exception.Message) }
    if ($selected.Count -eq 0) { throw (New-ZtpBmcToolInputError "'$InfrastructureFile' lists no nodes (nodes[]).") }
    $all = @($environment['cluster_nodes'])
    $nodes = foreach ($name in $selected) {
        $index = 0
        foreach ($n in $all) { if ([string]$n['name'] -eq $name) { break }; $index++ }
        $address = [string]$all[$index]['idrac_ip']
        if (-not $address) { throw (New-ZtpBmcToolInputError "nodes[$index] ($name) has no bmc.ip_address in '$InfrastructureFile'.") }
        [pscustomobject]@{ Name = $name; BmcAddress = $address }
    }
    $verify = Get-ZtpEnvValue -Environment $environment -Path 'ztp.verify_bmc_certificate'
    try { $verifyCertificate = if ($null -eq $verify -or "$verify" -eq '') { $false } else { ConvertTo-ZtpBoolean $verify 'hardware.bmc.verify_certificate' } }
    catch { throw (New-ZtpBmcToolInputError $_.Exception.Message) }
    return [pscustomobject]@{
        Path                 = (Resolve-Path -LiteralPath $InfrastructureFile).Path
        Infrastructure       = $raw
        Nodes                = @($nodes)
        SkipCertificateCheck = -not $verifyCertificate
        Vendor               = [string](Get-ZtpEnvValue -Environment $environment -Path 'hardware.vendor')
    }
}

function Resolve-ZtpBmcToolCredential {
    <#
    .SYNOPSIS
    The BMC login: -Credential, else hardware.bmc.username and .password of the file read by the toolkit's resolver. It never
    asks. With neither, or when the resolver can't read the secret, it throws an input error (exit code 2) that says what
    to pass.
    .PARAMETER Infrastructure
    The parsed infrastructure file (Read-ZtpBmcToolInput's Infrastructure): it holds key_vaults and the secrets section the
    resolver reads.
    #>
    [CmdletBinding()]
    [OutputType([pscredential])]
    param(
        [pscredential]$Credential,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure,
        [Parameter(Mandatory)][string]$InfrastructureFile
    )
    if ($Credential) { return $Credential }
    $bmc = Get-ZtpEnvValue -Environment $Infrastructure -Path 'hardware.bmc'
    if ($bmc -isnot [System.Collections.IDictionary] -or -not $bmc['username'] -or -not $bmc['password']) {
        throw (New-ZtpBmcToolInputError "No BMC login: pass -Credential, or set hardware.bmc.username and hardware.bmc.password (secret references such as keyvault://<vault>/<secret>) in '$InfrastructureFile'.")
    }
    if (-not (Get-Command Resolve-AzlBmcCredential -ErrorAction SilentlyContinue)) {
        $module = Find-ZtpToolkitRedfishModule
        if (-not $module) {
            throw (New-ZtpBmcToolInputError "hardware.bmc holds secret references, and the toolkit's secret resolver (azurelocal-toolkit scripts/common/redfish/AzlRedfishCore.psm1) isn't found. Clone azurelocal-toolkit next to this repository or set AZL_TOOLKIT_ROOT, or pass -Credential.")
        }
        Import-Module $module -ErrorAction Stop
    }
    try { return (Resolve-AzlBmcCredential -Infrastructure $Infrastructure) }
    catch { throw (New-ZtpBmcToolInputError $_.Exception.Message) }
}

function Open-ZtpBmcToolSession {
    # A Redfish session on one node's BMC (ZtpRedfish.Common.ps1), with the file's TLS choice.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Opens a transport only; callers guard every change with ShouldProcess.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Node, [Parameter(Mandatory)][pscredential]$Credential, [switch]$SkipCertificateCheck)
    return (New-ZtpRedfishSession -BmcAddress $Node.BmcAddress -Credential $Credential -SkipCertificateCheck:$SkipCertificateCheck)
}

function Get-ZtpRedfishOdataId {
    # The @odata.id of a Redfish resource, or of a property that links to one; $null when there is none.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Resource, [string]$Property)
    $target = $Resource
    if ($Property) {
        if ($null -eq $Resource -or -not $Resource.PSObject.Properties[$Property]) { return $null }
        $target = $Resource.$Property
    }
    if ($null -eq $target -or -not $target.PSObject.Properties['@odata.id']) { return $null }
    return [string]$target.'@odata.id'
}
