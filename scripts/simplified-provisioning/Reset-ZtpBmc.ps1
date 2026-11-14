#Requires -Version 7.0
<#
.SYNOPSIS
Restarts the management controller (BMC) of each node through Redfish (Manager.Reset). The host keeps running.
.DESCRIPTION
For a BMC that stops answering, returns stale data, or keeps a virtual-media slot it can't eject during the Boot or
Bootstrap stage. It POSTs the manager's #Manager.Reset action (target from the manager resource) with -ResetType. The BMC
is unreachable for a few minutes (an iDRAC 2 to 3); the host and its operating system keep running, but a ZTP stage that
is reading the BMC at that time sees it fail, so stop the run first and resume it afterwards. A reset type the BMC doesn't
list in ResetType@Redfish.AllowableValues fails that node without a request.
With -WhatIf only the plan is printed: no credential is read and nothing is sent.
Keys read: nodes[].name, nodes[].bmc.ip_address, hardware.bmc.username, .password, .verify_certificate.
Exit codes: 0 done (or planned under -WhatIf); 1 a BMC could not be reset; 2 the file, a node or the login is missing or
not usable (nothing was sent to any BMC).
.PARAMETER InfrastructureFile
The master infrastructure.yml (schema 5). Required: there is no default path.
.PARAMETER NodeName
Nodes whose BMC to reset (nodes[].name). Default: every node in the file.
.PARAMETER Credential
The BMC login. Without it the login is the secret references in hardware.bmc, read by the toolkit's resolver. Never asked.
.PARAMETER ResetType
GracefulRestart (default) or ForceRestart.
.EXAMPLE
./Reset-ZtpBmc.ps1 -InfrastructureFile D:\ztp\infrastructure.yml -NodeName iic-node-02 -WhatIf
.EXAMPLE
./Reset-ZtpBmc.ps1 -InfrastructureFile D:\ztp\infrastructure.yml -NodeName iic-node-02
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string[]]$NodeName,
    [pscredential]$Credential,
    [ValidateSet('GracefulRestart', 'ForceRestart')][string]$ResetType = 'GracefulRestart'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpBmcTool.Common.ps1')
if (-not (Get-Command New-ZtpRedfishSession -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ZtpRedfish.Common.ps1') }

function Reset-ZtpNodeBmc {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The script asks ShouldProcess for each node before it calls this.')]
    [CmdletBinding()]
    param([pscustomobject]$Node, [pscredential]$Login, [bool]$SkipCertificateCheck)
    $session = Open-ZtpBmcToolSession -Node $Node -Credential $Login -SkipCertificateCheck:$SkipCertificateCheck
    try {
        $manager = Get-ZtpRedfishManager -Session $session
        $actions = if ($manager.PSObject.Properties['Actions']) { $manager.Actions } else { $null }
        $action = if ($actions -and $actions.PSObject.Properties['#Manager.Reset']) { $actions.'#Manager.Reset' } else { $null }
        $path = if ($action -and $action.PSObject.Properties['target']) { [string]$action.target } else { "$(Get-ZtpRedfishOdataId $manager)/Actions/Manager.Reset" }
        if ($action -and $action.PSObject.Properties['ResetType@Redfish.AllowableValues']) {
            $allowed = @($action.'ResetType@Redfish.AllowableValues')
            if ($allowed.Count -and $ResetType -notin $allowed) { throw "the BMC doesn't offer ResetType $ResetType (it offers $($allowed -join ', '))." }
        }
        $null = Invoke-ZtpRedfish -Session $session -Path $path -Method Post -Body @{ ResetType = $ResetType }
        return [pscustomobject]@{ Node = $Node.Name; Bmc = $Node.BmcAddress; ResetType = $ResetType; Status = 'ResetSent'; Error = $null }
    }
    finally { Remove-ZtpRedfishSession -Session $session }
}

try { $target = Read-ZtpBmcToolInput -InfrastructureFile $InfrastructureFile -NodeName $NodeName }
catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit (Get-ZtpBmcToolExitCode $_)
}

$login = $null
$failed = 0
foreach ($node in $target.Nodes) {
    if (-not $PSCmdlet.ShouldProcess("$($node.Name) BMC $($node.BmcAddress)", "Manager.Reset $ResetType (the BMC restarts; the host keeps running)")) {
        [pscustomobject]@{ Node = $node.Name; Bmc = $node.BmcAddress; ResetType = $ResetType; Status = 'Planned'; Error = $null }
        continue
    }
    if (-not $login) {
        try { $login = Resolve-ZtpBmcToolCredential -Credential $Credential -Infrastructure $target.Infrastructure -InfrastructureFile $target.Path }
        catch {
            Write-Error $_.Exception.Message -ErrorAction Continue
            exit (Get-ZtpBmcToolExitCode $_)
        }
    }
    try { Reset-ZtpNodeBmc -Node $node -Login $login -SkipCertificateCheck $target.SkipCertificateCheck }
    catch {
        $failed++
        Write-Error "$($node.Name) ($($node.BmcAddress)): $($_.Exception.Message)" -ErrorAction Continue
        [pscustomobject]@{ Node = $node.Name; Bmc = $node.BmcAddress; ResetType = $ResetType; Status = 'Failed'; Error = $_.Exception.Message }
    }
}
exit $(if ($failed) { 1 } else { 0 })
