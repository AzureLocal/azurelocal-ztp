#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
# The self-contained Redfish helper: session, request, retry and the manager/system/member lookups. Invoke-RestMethod is
# mocked; no BMC is contacted and the synthetic password never leaves the test.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Only a synthetic test password is converted.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Mocks share call records with the assertions.')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:scripts = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts/simplified-provisioning'
    . (Join-Path $script:scripts 'ZtpRedfish.Common.ps1')
    $script:credential = [pscredential]::new('bmc-admin', (ConvertTo-SecureString 'Synthetic-Only-3!' -AsPlainText -Force))
    $global:rfCalls = [System.Collections.Generic.List[object]]::new()
}

AfterAll { Remove-Variable rfCalls -Scope Global -ErrorAction SilentlyContinue }

Describe 'ZtpRedfish.Common.ps1' {
    BeforeEach {
        $global:rfCalls.Clear()
        Mock Start-Sleep {}
    }

    Describe 'New-ZtpRedfishSession' {
        It 'falls back to HTTP Basic when the BMC refuses session creation, and checks the service root' {
            Mock Invoke-RestMethod {
                $global:rfCalls.Add([pscustomobject]@{ Uri = $Uri; Method = $Method; Headers = $Headers })
                if ($Uri -like '*/SessionService/Sessions') { throw 'refused' }
                [pscustomobject]@{ RedfishVersion = '1.0.0' }
            }
            $session = New-ZtpRedfishSession -BmcAddress 198.51.100.11 -Credential $script:credential -SkipCertificateCheck
            $session.BaseUrl | Should -Be 'https://198.51.100.11'
            $session.SkipCertificateCheck | Should -BeTrue
            $session.SessionUri | Should -BeNullOrEmpty
            $session.Headers['Authorization'] | Should -Match '^Basic '
            [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($session.Headers['Authorization'] -replace '^Basic '))) | Should -Be 'bmc-admin:Synthetic-Only-3!'
            @($global:rfCalls | Where-Object Uri -Like '*/redfish/v1').Count | Should -Be 1
            Should -Invoke Invoke-RestMethod -ParameterFilter { $SkipCertificateCheck }
        }

        It 'rejects an address that is not a host name or IP' {
            { New-ZtpRedfishSession -BmcAddress '198.51.100.11/../x' -Credential $script:credential } | Should -Throw '*Not a usable BMC address*'
        }

        It 'reports an unreachable Redfish service without the password' {
            Mock Invoke-RestMethod { throw 'connection refused' }
            $failure = { New-ZtpRedfishSession -BmcAddress 198.51.100.11 -Credential $script:credential } | Should -Throw '*Cannot reach the Redfish service of 198.51.100.11*' -PassThru
            $failure.Exception.Message | Should -Not -Match 'Synthetic-Only'
        }
    }

    Describe 'Invoke-ZtpRedfish' {
        BeforeEach {
            $script:session = [pscustomobject]@{ BmcAddress = '198.51.100.11'; BaseUrl = 'https://198.51.100.11'; Headers = @{ Accept = 'application/json' }; SessionUri = $null; SkipCertificateCheck = $true }
        }

        It 'sends a JSON body for Patch and returns the parsed response' {
            Mock Invoke-RestMethod { $global:rfCalls.Add([pscustomobject]@{ Uri = $Uri; Method = $Method; Body = $Body; ContentType = $ContentType }); [pscustomobject]@{ ok = $true } }
            $result = Invoke-ZtpRedfish -Session $script:session -Path /redfish/v1/Systems/1 -Method Patch -Body @{ Boot = @{ BootSourceOverrideTarget = 'Usb' } }
            $result.ok | Should -BeTrue
            $global:rfCalls[0].Uri | Should -Be 'https://198.51.100.11/redfish/v1/Systems/1'
            $global:rfCalls[0].Method | Should -Be 'Patch'
            $global:rfCalls[0].ContentType | Should -Be 'application/json'
            ($global:rfCalls[0].Body | ConvertFrom-Json).Boot.BootSourceOverrideTarget | Should -Be 'Usb'
        }

        It 'sends no body for a GET' {
            Mock Invoke-RestMethod { $global:rfCalls.Add([pscustomobject]@{ Body = $Body }); [pscustomobject]@{} }
            $null = Invoke-ZtpRedfish -Session $script:session -Path /redfish/v1
            $global:rfCalls[0].Body | Should -BeNullOrEmpty
        }

        It 'retries a transient failure and then succeeds' {
            $global:rfAttempt = 0
            Mock Invoke-RestMethod {
                $global:rfAttempt++
                if ($global:rfAttempt -lt 2) {
                    $exception = [System.Net.Http.HttpRequestException]::new('service unavailable')
                    throw $exception
                }
                [pscustomobject]@{ ok = $true }
            }
            (Invoke-ZtpRedfish -Session $script:session -Path /redfish/v1 -MaxAttempts 3).ok | Should -BeTrue
            $global:rfAttempt | Should -Be 2
            Remove-Variable rfAttempt -Scope Global
        }

        It 'throws with the method, path and BMC but never the request body' {
            Mock Invoke-RestMethod { throw 'boom' }
            $failure = { Invoke-ZtpRedfish -Session $script:session -Path /redfish/v1/Systems/1 -Method Post -Body @{ Password = 'Synthetic-Only-Body' } -MaxAttempts 1 } | Should -Throw '*Redfish Post /redfish/v1/Systems/1 on 198.51.100.11 failed*' -PassThru
            $failure.Exception.Message | Should -Not -Match 'Synthetic-Only-Body'
        }

        It 'requires an absolute path' {
            { Invoke-ZtpRedfish -Session $script:session -Path 'redfish/v1' } | Should -Throw
        }
    }

    Describe 'Manager, system and member lookups' {
        BeforeEach {
            $script:session = [pscustomobject]@{ BmcAddress = '198.51.100.11'; BaseUrl = 'https://198.51.100.11'; Headers = @{}; SessionUri = $null; SkipCertificateCheck = $true }
            Mock Invoke-RestMethod {
                $path = ([uri]$Uri).AbsolutePath
                switch ($path) {
                    '/redfish/v1/Managers' { [pscustomobject]@{ Members = @([pscustomobject]@{ '@odata.id' = '/redfish/v1/Managers/BMC.1' }, [pscustomobject]@{ '@odata.id' = '/redfish/v1/Managers/BMC.2' }) } }
                    '/redfish/v1/Systems' { [pscustomobject]@{ Members = @([pscustomobject]@{ '@odata.id' = '/redfish/v1/Systems/System.Embedded.1' }) } }
                    '/redfish/v1/Managers/BMC.1/VirtualMedia' { [pscustomobject]@{ Members = @([pscustomobject]@{ '@odata.id' = '/redfish/v1/Managers/BMC.1/VirtualMedia/CD' }, [pscustomobject]@{ '@odata.id' = '/redfish/v1/Managers/BMC.1/VirtualMedia/RemovableDisk' }) } }
                    default { [pscustomobject]@{ '@odata.id' = $path; Id = ($path -split '/')[-1] } }
                }
            }
        }

        It 'returns the first manager, or the one named by -ManagerId' {
            (Get-ZtpRedfishManager -Session $script:session).Id | Should -Be 'BMC.1'
            (Get-ZtpRedfishManager -Session $script:session -ManagerId BMC.2).Id | Should -Be 'BMC.2'
            { Get-ZtpRedfishManager -Session $script:session -ManagerId BMC.9 } | Should -Throw "*No manager 'BMC.9'*"
        }

        It 'returns the computer system' {
            (Get-ZtpRedfishSystem -Session $script:session).Id | Should -Be 'System.Embedded.1'
        }

        It 'returns every member of a collection, or the one with -Id' {
            @(Get-ZtpRedfishMember -Session $script:session -CollectionPath /redfish/v1/Managers/BMC.1/VirtualMedia).Id | Should -Be @('CD', 'RemovableDisk')
            @(Get-ZtpRedfishMember -Session $script:session -CollectionPath /redfish/v1/Managers/BMC.1/VirtualMedia -Id RemovableDisk).Id | Should -Be @('RemovableDisk')
        }
    }

    Describe 'Remove-ZtpRedfishSession' {
        It 'deletes the session resource and never throws' {
            Mock Invoke-RestMethod { $global:rfCalls.Add([pscustomobject]@{ Uri = $Uri; Method = $Method }); throw 'gone' }
            $session = [pscustomobject]@{ BmcAddress = '198.51.100.11'; BaseUrl = 'https://198.51.100.11'; Headers = @{}; SessionUri = '/redfish/v1/SessionService/Sessions/1'; SkipCertificateCheck = $false }
            { Remove-ZtpRedfishSession -Session $session } | Should -Not -Throw
            $global:rfCalls[0].Method | Should -Be 'Delete'
            $global:rfCalls[0].Uri | Should -Be 'https://198.51.100.11/redfish/v1/SessionService/Sessions/1'
        }

        It 'does nothing for a Basic-auth session' {
            Mock Invoke-RestMethod {}
            Remove-ZtpRedfishSession -Session ([pscustomobject]@{ SessionUri = $null })
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }
    }
}
