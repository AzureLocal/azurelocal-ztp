#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
# OEM definitions (config/oem): the BMC layer the Bootstrap watch reads. ZTP carries no SBE, so the definitions hold none.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Paths are shared through globals.')]
param()

BeforeAll {
    $global:ztpO_scripts = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts/simplified-provisioning'
    $global:ztpO_root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    . (Join-Path $global:ztpO_scripts 'ZtpOem.Common.ps1')
}
AfterAll { Get-Variable -Scope Global -Name 'ztpO_*' -ErrorAction SilentlyContinue | Remove-Variable -Scope Global -Force -ErrorAction SilentlyContinue }

Describe 'OEM definitions (config/oem)' {
    It 'ships Dell, Lenovo, HPE and Supermicro, each loadable and complete' {
        foreach ($oem in 'dell', 'lenovo', 'hpe', 'supermicro') {
            $c = Get-ZtpOemConfig -Oem $oem
            $c.oem | Should -Not -BeNullOrEmpty; $c.bmc.kind | Should -Not -BeNullOrEmpty
        }
        (Get-ZtpOemConfig -Oem Dell).bmc.kind | Should -Be 'idrac'
        @((Get-ZtpOemConfig -Oem Dell).bmc.logServices.id) | Should -Be @('Lclog', 'Sel')
    }
    It 'holds no SBE settings: the SBE belongs to OS configuration' {
        foreach ($f in Get-ChildItem (Join-Path $global:ztpO_root 'config/oem') -Filter *.json) {
            (Get-Content $f.FullName -Raw | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'sbe' -Because $f.Name
        }
        Test-Path (Join-Path $global:ztpO_scripts 'Get-ZtpSbe.ps1') | Should -BeFalse
        Test-Path (Join-Path $global:ztpO_scripts 'ZtpSbe.Common.ps1') | Should -BeFalse
    }
    It 'names the known OEMs when one is missing and rejects a definition without the required fields' {
        { Get-ZtpOemConfig -Oem acme } | Should -Throw '*Known OEMs: dell*'
        $root = Join-Path $TestDrive 'oem'; $null = New-Item -ItemType Directory $root
        Set-Content (Join-Path $root 'broken.json') '{ "oem": "Broken" }'
        { Get-ZtpOemConfig -Oem broken -ConfigRoot $root } | Should -Throw "*lacks 'publisher'*"
        Set-Content (Join-Path $root 'nobmc.json') '{ "oem": "P", "publisher": "P", "bmc": { "kind": "x" } }'
        { Get-ZtpOemConfig -Oem nobmc -ConfigRoot $root } | Should -Throw '*lacks bmc.logServices*'
        Set-Content (Join-Path $root 'old.json') '{ "oem": "P", "publisher": "P", "sbe": { "discoveryManifestUrl": "http://ignored" }, "bmc": { "kind": "x", "logServices": [] } }'
        (Get-ZtpOemConfig -Oem old -ConfigRoot $root).bmc.kind | Should -Be 'x' -Because 'an older definition with an sbe block still loads; the block is ignored'
    }
    It 'contains no tenant, subscription or private address data' {
        foreach ($f in Get-ChildItem (Join-Path $global:ztpO_root 'config/oem') -Filter *.json) {
            (Get-Content $f.FullName -Raw) | Should -Not -Match '(?i)\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-(?!000000000000)[0-9a-f]{12}'
        }
    }
}
