#Requires -Version 7.0
<#
.SYNOPSIS
Lists the Azure Local OS images simplified machine provisioning offers, or resolves one version (read-only).
.DESCRIPTION
Reads Microsoft.AzureStackHCI/locations/<location>/osImages?solution-type=HCI (the portal's "software version" list) under
the current Az context. Without -Version every image is returned, newest first. With -Version one row is returned:
  latest          newest release build (12.YYMM with a calendar month; a preview build has a non-calendar month,
                  for example 12.26NN with NN above 12, and is skipped)
  latest-preview  newest of all, preview builds included
  <version>       an exact validated solution recipe version (12.2609.1003.7, the edge machine osProfile.vsrVersion)
                  or composed image version (12.2609.0.3009)
The edge machine takes VsrVersion. Nothing is changed.
.PARAMETER SubscriptionId
Subscription the catalog is read in (the provisioning subscription).
.PARAMETER Location
Provisioning region (preview: eastus).
.PARAMETER Version
latest, latest-preview or an exact version; omit to list.
.PARAMETER ApiVersion
Microsoft.AzureStackHCI api-version (edgeMachines and osImages: 2025-12-01-preview or later).
.EXAMPLE
./Get-ZtpOsImage.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -Location eastus
.EXAMPLE
(./Get-ZtpOsImage.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -Location eastus -Version latest).VsrVersion
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Location,
    [string]$Version,
    [string]$ApiVersion = '2025-12-01-preview'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZtpAzure.Common.ps1')

$catalog = @(Get-ZtpOsImageCatalog -SubscriptionId $SubscriptionId -Location $Location -ApiVersion $ApiVersion)
if (-not $Version) { return $catalog }
Resolve-ZtpOsImage -Catalog $catalog -Version $Version
