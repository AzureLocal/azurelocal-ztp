#Requires -Version 7.0
<#
.SYNOPSIS
The one HTTP seam of the bootstrap and SBE scripts (dot-sourced only when Invoke-ZtpHttp is not already defined, so tests supply their own).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-ZtpHttp {
    <#
    .SYNOPSIS
    One HTTP request (HEAD or GET, optional Range, redirects off unless -FollowRedirect). The transport seam of the
    bootstrap and SBE scripts. Returns StatusCode, FinalUri (after any redirects), Headers (case-insensitive, string values), Location, and Stream
    (-AsStream) or Text (GET without -AsStream).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [ValidateSet('Head', 'Get')][string]$Method = 'Head',
        [long]$RangeFrom = -1,
        [long]$RangeTo = -1,
        [string]$IfRange,
        [switch]$FollowRedirect,
        [switch]$AsStream,
        [ValidateRange(5, 3600)][int]$TimeoutSeconds = 60
    )
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = [bool]$FollowRedirect
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [timespan]::FromSeconds($TimeoutSeconds)
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method.ToUpperInvariant()), $Uri)
        if ($RangeFrom -ge 0) {
            $request.Headers.Range = if ($RangeTo -ge 0) { [System.Net.Http.Headers.RangeHeaderValue]::new($RangeFrom, $RangeTo) } else { [System.Net.Http.Headers.RangeHeaderValue]::new($RangeFrom, $null) }
        }
        if ($IfRange) { $null = $request.Headers.TryAddWithoutValidation('If-Range', $IfRange) }
        $completion = if ($AsStream) { [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead } else { [System.Net.Http.HttpCompletionOption]::ResponseContentRead }
        $response = $client.SendAsync($request, $completion).GetAwaiter().GetResult()
        $headers = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($h in $response.Headers) { $headers[$h.Key] = ($h.Value -join ', ') }
        foreach ($h in $response.Content.Headers) { $headers[$h.Key] = ($h.Value -join ', ') }
        $location = if ($response.Headers.Location) { $response.Headers.Location.ToString() } else { $null }
        $finalUri = if ($response.RequestMessage -and $response.RequestMessage.RequestUri) { $response.RequestMessage.RequestUri.ToString() } else { [string]$Uri }
        $result = [pscustomobject]@{ StatusCode = [int]$response.StatusCode; FinalUri = $finalUri; Headers = $headers; Location = $location; Stream = $null; Text = $null; Disposable = $null }
        if ($Method -eq 'Get' -and $AsStream -and $response.IsSuccessStatusCode) {
            $result.Stream = $response.Content.ReadAsStream()
            # The caller disposes the stream; the client lives as long as the response does.
            $result.Disposable = [pscustomobject]@{ Client = $client; Response = $response }
            $client = $null
        }
        elseif ($Method -eq 'Get' -and -not $AsStream -and $response.IsSuccessStatusCode) {
            $result.Text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
        return $result
    }
    finally {
        if ($client) { $client.Dispose() }
    }
}
