#Requires -Version 7.0
<#
.SYNOPSIS
Reads each node's boot settings through its BMC (read-only): power state, boot mode, one-time boot override, boot order
and boot options.
.DESCRIPTION
Use it when a node didn't boot from its virtual USB image, before and after Reset-ZtpBootSequence.ps1, or to see an
override a stopped run left. Mount-ZtpVirtualUsb.ps1 -Action Status shows the image and the override only; this shows the
whole boot configuration. One row per node: Node, Bmc, PowerState, BootMode, OverrideEnabled, OverrideTarget, BootOrder,
Options (Id, DisplayName, Enabled, Reference, Stale), StaleCount, Error. An option is stale when the firmware shows it as
'Unavailable: ...' (a device that is gone). Only GET requests (and the Redfish session) are sent; nothing changes.
Keys read: nodes[].name, nodes[].bmc.ip_address, hardware.bmc.username, .password, .verify_certificate.
Exit codes: 0 read; 1 a BMC could not be read (its row carries the error); 2 the file, a node or the login is missing or
not usable (nothing was sent to any BMC).
.PARAMETER InfrastructureFile
The master infrastructure.yml (schema 5). Required: there is no default path.
.PARAMETER NodeName
Nodes to read (nodes[].name). Default: every node in the file.
.PARAMETER Credential
The BMC login. Without it the login is the secret references in hardware.bmc, read by the toolkit's resolver. Never asked.
.EXAMPLE
./Get-ZtpBootSetting.ps1 -InfrastructureFile D:\ztp\infrastructure.yml | Format-List
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string[]]$NodeName,
    [pscredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpBmcTool.Common.ps1')
if (-not (Get-Command New-ZtpRedfishSession -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ZtpRedfish.Common.ps1') }

function Get-ZtpProperty([object]$Object, [string]$Name) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $null
}

function Get-ZtpNodeBootSetting {
    param([pscustomobject]$Node, [pscredential]$Login, [bool]$SkipCertificateCheck)
    $session = Open-ZtpBmcToolSession -Node $Node -Credential $Login -SkipCertificateCheck:$SkipCertificateCheck
    try {
        $system = Get-ZtpRedfishSystem -Session $session
        $boot = Get-ZtpProperty $system 'Boot'
        $optionsPath = Get-ZtpRedfishOdataId $boot 'BootOptions'
        if (-not $optionsPath) { $optionsPath = "$(Get-ZtpRedfishOdataId $system)/BootOptions" }
        $options = @(
            try {
                foreach ($o in @(Get-ZtpRedfishMember -Session $session -CollectionPath $optionsPath)) {
                    $display = [string](Get-ZtpProperty $o 'DisplayName')
                    [pscustomobject]@{
                        Id          = [string](Get-ZtpProperty $o 'Id')
                        DisplayName = $display
                        Enabled     = Get-ZtpProperty $o 'BootOptionEnabled'
                        Reference   = [string](Get-ZtpProperty $o 'BootOptionReference')
                        Stale       = $display -match '^Unavailable:'
                    }
                }
            }
            catch { Write-Verbose "$($Node.Name): no boot options collection ($($_.Exception.Message))." }
        )
        return [pscustomobject]@{
            Node            = $Node.Name
            Bmc             = $Node.BmcAddress
            PowerState      = [string](Get-ZtpProperty $system 'PowerState')
            BootMode        = [string](Get-ZtpProperty $boot 'BootSourceOverrideMode')
            OverrideEnabled = [string](Get-ZtpProperty $boot 'BootSourceOverrideEnabled')
            OverrideTarget  = [string](Get-ZtpProperty $boot 'BootSourceOverrideTarget')
            BootOrder       = @(Get-ZtpProperty $boot 'BootOrder' | Where-Object { $null -ne $_ })
            Options         = $options
            StaleCount      = @($options | Where-Object Stale).Count
            Error           = $null
        }
    }
    finally { Remove-ZtpRedfishSession -Session $session }
}

try {
    $target = Read-ZtpBmcToolInput -InfrastructureFile $InfrastructureFile -NodeName $NodeName
    $login = Resolve-ZtpBmcToolCredential -Credential $Credential -Infrastructure $target.Infrastructure -InfrastructureFile $target.Path
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit (Get-ZtpBmcToolExitCode $_)
}

$failed = 0
foreach ($node in $target.Nodes) {
    try { Get-ZtpNodeBootSetting -Node $node -Login $login -SkipCertificateCheck $target.SkipCertificateCheck }
    catch {
        $failed++
        Write-Error "$($node.Name) ($($node.BmcAddress)): $($_.Exception.Message)" -ErrorAction Continue
        [pscustomobject]@{ Node = $node.Name; Bmc = $node.BmcAddress; PowerState = $null; BootMode = $null; OverrideEnabled = $null; OverrideTarget = $null; BootOrder = @(); Options = @(); StaleCount = 0; Error = $_.Exception.Message }
    }
}
exit $(if ($failed) { 1 } else { 0 })
