#Requires -Version 7.0
<#
.SYNOPSIS
Small self-contained Redfish client for the simplified-provisioning scripts (dot-sourced).
.DESCRIPTION
Session, GET, POST and PATCH against a BMC (iDRAC, XCC, iLO) with Invoke-RestMethod. Used by Mount-ZtpVirtualUsb.ps1.
The scripts dot-source this file only when New-ZtpRedfishSession is not already defined, so tests (or another transport)
can supply their own functions with the same names. The BMC password is held in memory for the request only, is never
logged and never appears in an error message. Request bodies are never printed.
Functions: New-ZtpRedfishSession, Remove-ZtpRedfishSession, Invoke-ZtpRedfish, Get-ZtpRedfishManager,
Get-ZtpRedfishSystem, Get-ZtpRedfishMember.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-ZtpRedfishSession {
    <#
    .SYNOPSIS
    Opens a Redfish session on one BMC (X-Auth-Token); falls back to HTTP Basic when the BMC refuses session creation.
    .PARAMETER BmcAddress
    BMC host name or IP address (for example 198.51.100.11).
    .PARAMETER Credential
    BMC account.
    .PARAMETER SkipCertificateCheck
    Accept the BMC's self-signed certificate.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Opens a read/write transport only; callers guard every change with ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$BmcAddress,
        [Parameter(Mandatory)][pscredential]$Credential,
        [switch]$SkipCertificateCheck
    )
    if ($BmcAddress -notmatch '^[A-Za-z0-9.:\[\]-]{1,253}$') { throw "Not a usable BMC address: '$BmcAddress'" }
    $base = "https://$BmcAddress"
    $common = @{ TimeoutSec = 60; ErrorAction = 'Stop' }
    if ($SkipCertificateCheck) { $common.SkipCertificateCheck = $true }
    $headers = @{ Accept = 'application/json' }
    $sessionUri = $null
    try {
        $body = @{ UserName = $Credential.UserName; Password = $Credential.GetNetworkCredential().Password } | ConvertTo-Json -Compress
        $null = Invoke-RestMethod @common -Uri "$base/redfish/v1/SessionService/Sessions" -Method Post -Body $body -ContentType 'application/json' -Headers $headers -ResponseHeadersVariable responseHeaders
        $body = $null
        $token = @($responseHeaders['X-Auth-Token'])[0]
        if ($token) {
            $headers['X-Auth-Token'] = [string]$token
            $location = @($responseHeaders['Location'])[0]
            if ($location) { $sessionUri = ([uri]$location).IsAbsoluteUri ? ([uri]$location).AbsolutePath : [string]$location }
        }
    }
    catch {
        Write-Verbose "Session creation on $BmcAddress was refused; using HTTP Basic."
    }
    if (-not $headers.ContainsKey('X-Auth-Token')) {
        $pair = "$($Credential.UserName):$($Credential.GetNetworkCredential().Password)"
        $headers['Authorization'] = 'Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pair))
        $pair = $null
    }
    try {
        $null = Invoke-RestMethod @common -Uri "$base/redfish/v1" -Method Get -Headers $headers
    }
    catch {
        throw "Cannot reach the Redfish service of $BmcAddress ($($_.Exception.Message))"
    }
    return [pscustomobject]@{
        BmcAddress           = $BmcAddress
        BaseUrl              = $base
        Headers              = $headers
        SessionUri           = $sessionUri
        SkipCertificateCheck = [bool]$SkipCertificateCheck
    }
}

function Remove-ZtpRedfishSession {
    <#
    .SYNOPSIS
    Closes the session opened by New-ZtpRedfishSession (best effort; never throws).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Closes the caller''s own session transport.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$Session)
    if ($null -eq $Session -or -not $Session.SessionUri) { return }
    try {
        $params = @{ Uri = "$($Session.BaseUrl)$($Session.SessionUri)"; Method = 'Delete'; Headers = $Session.Headers; TimeoutSec = 30; ErrorAction = 'Stop' }
        if ($Session.SkipCertificateCheck) { $params.SkipCertificateCheck = $true }
        $null = Invoke-RestMethod @params
    }
    catch { Write-Verbose "Session close on $($Session.BmcAddress) failed: $($_.Exception.Message)" }
}

function Invoke-ZtpRedfish {
    <#
    .SYNOPSIS
    One Redfish request. Returns the parsed body ($null for an empty body). Errors name the method, path and status only.
    .PARAMETER Session
    The object New-ZtpRedfishSession returned.
    .PARAMETER Path
    Absolute Redfish path such as /redfish/v1/Managers.
    .PARAMETER Method
    Get, Post, Patch or Delete.
    .PARAMETER Body
    Hashtable sent as JSON (never printed).
    .PARAMETER MaxAttempts
    Attempts for transient failures (HTTP 429, 502, 503, 504, timeouts).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][ValidatePattern('^/')][string]$Path,
        [ValidateSet('Get', 'Post', 'Patch', 'Delete')][string]$Method = 'Get',
        [hashtable]$Body,
        [ValidateRange(1, 5)][int]$MaxAttempts = 3
    )
    $params = @{ Uri = "$($Session.BaseUrl)$Path"; Method = $Method; Headers = $Session.Headers; TimeoutSec = 60; ErrorAction = 'Stop' }
    if ($Session.SkipCertificateCheck) { $params.SkipCertificateCheck = $true }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $params.Body = $Body | ConvertTo-Json -Depth 20 -Compress
        $params.ContentType = 'application/json'
    }
    for ($attempt = 1; ; $attempt++) {
        try {
            return (Invoke-RestMethod @params)
        }
        catch {
            $status = if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            $transient = $status -in 429, 502, 503, 504 -or ($status -eq 0 -and $_.Exception -is [System.Net.Http.HttpRequestException])
            if ($transient -and $attempt -lt $MaxAttempts) { Start-Sleep -Seconds (2 * $attempt); continue }
            throw "Redfish $Method $Path on $($Session.BmcAddress) failed$(if ($status) { " with HTTP $status" }): $($_.Exception.Message)"
        }
    }
}

function Get-ZtpRedfishManager {
    <#
    .SYNOPSIS
    The BMC's manager resource (the first member of /redfish/v1/Managers, or the one named by -ManagerId).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Session, [string]$ManagerId)
    $collection = Invoke-ZtpRedfish -Session $Session -Path '/redfish/v1/Managers'
    $member = @($collection.Members | Where-Object { -not $ManagerId -or $_.'@odata.id' -like "*/$ManagerId" }) | Select-Object -First 1
    if (-not $member) { throw "No manager$(if ($ManagerId) { " '$ManagerId'" }) on $($Session.BmcAddress)." }
    return (Invoke-ZtpRedfish -Session $Session -Path $member.'@odata.id')
}

function Get-ZtpRedfishSystem {
    <#
    .SYNOPSIS
    The computer system (the first member of /redfish/v1/Systems, or the one named by -SystemId).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Session, [string]$SystemId)
    $collection = Invoke-ZtpRedfish -Session $Session -Path '/redfish/v1/Systems'
    $member = @($collection.Members | Where-Object { -not $SystemId -or $_.'@odata.id' -like "*/$SystemId" }) | Select-Object -First 1
    if (-not $member) { throw "No computer system$(if ($SystemId) { " '$SystemId'" }) on $($Session.BmcAddress)." }
    return (Invoke-ZtpRedfish -Session $Session -Path $member.'@odata.id')
}

function Get-ZtpRedfishMember {
    <#
    .SYNOPSIS
    Every member resource of a collection (one GET per member), or the one whose id is -Id.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Session, [Parameter(Mandatory)][string]$CollectionPath, [string]$Id)
    $collection = Invoke-ZtpRedfish -Session $Session -Path $CollectionPath
    foreach ($member in @($collection.Members)) {
        if ($Id -and $member.'@odata.id' -notlike "*/$Id") { continue }
        Invoke-ZtpRedfish -Session $Session -Path $member.'@odata.id'
    }
}
