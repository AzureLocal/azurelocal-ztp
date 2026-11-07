#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }, powershell-yaml
# The environment-file layer: ZtpEnvironment.Common.ps1 (parsing, key checks, node selection, SBE folder and SHA-256 check),
# and the plan mode of Invoke-ZtpEnvironment.ps1 and Initialize-ZtpNode.ps1 (no -Execute against Azure or a node). Both scripts
# run from copies in a throw-away repository layout in TestDrive, beside stub stage scripts and stub Az/WinRM commands, so
# nothing touches Azure, a node, a BMC or the real config folders. The environment file is fixtures/environment.example.yml
# (placeholder values only); the SBE is a tiny synthetic zip with a driver INF in it.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Stub commands and scripts report through globals.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Only a synthetic test secret is converted.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signatures mirror the real commands; the bodies read only some parameters.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers and stubs only build files in TestDrive.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Stubs reuse the names of the commands they replace.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Stubs stand in for the WinRM and signature cmdlets so no node is contacted.')]
param()

BeforeAll {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Import-Module powershell-yaml
    $script:repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:scripts = Join-Path $script:repoRoot 'scripts/simplified-provisioning'
    $script:fixture = Join-Path $PSScriptRoot 'fixtures/environment.example.yml'
    . (Join-Path $script:scripts 'ZtpEnvironment.Common.ps1')

    # Stub commands: they shadow the real Az and WinRM cmdlets for the scripts run below and record what was asked of them.
    $global:ztpE_calls = [System.Collections.Generic.List[string]]::new()
    $global:ztpE_runs = [System.Collections.Generic.List[object]]::new()
    $global:ztpE_signature = 'Valid'
    function Connect-AzAccount { [CmdletBinding()] param([switch]$Identity) $global:ztpE_calls.Add('Connect-AzAccount') }
    function Set-AzContext { [CmdletBinding()] param($Tenant, $Subscription, $Scope) $global:ztpE_calls.Add("Set-AzContext $Subscription") }
    function Get-AzADServicePrincipal { [CmdletBinding()] param($ApplicationId) $global:ztpE_calls.Add('Get-AzADServicePrincipal'); [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000009' } }
    function Get-AzResourceGroup { [CmdletBinding()] param($Name) $global:ztpE_calls.Add("Get-AzResourceGroup $Name") }
    function New-AzResourceGroup { [CmdletBinding()] param($Name, $Location, $Tag) $global:ztpE_calls.Add("New-AzResourceGroup $Name") }
    function Get-AzKeyVaultSecret {
        [CmdletBinding()] param($VaultName, $Name, [switch]$AsPlainText)
        $global:ztpE_calls.Add("Get-AzKeyVaultSecret $VaultName/$Name")
        if ($AsPlainText) { return 'bmc-example' }
        [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'Example-Not-A-Secret-1' -AsPlainText -Force) }
    }
    function Get-NetIPAddress { [CmdletBinding()] param($AddressFamily, $InterfaceAlias) [pscustomobject]@{ IPAddress = '192.0.2.77' } }
    function New-PSSession { [CmdletBinding()] param($ComputerName, [pscredential]$Credential, $Authentication) $global:ztpE_calls.Add("New-PSSession $ComputerName"); [pscustomobject]@{ ComputerName = $ComputerName } }
    function Remove-PSSession { [CmdletBinding()] param($Session) }
    function Invoke-Command { [CmdletBinding()] param($Session, $ScriptBlock, $ArgumentList) $global:ztpE_nodeState }
    function Get-AuthenticodeSignature { [CmdletBinding()] param($LiteralPath) [pscustomobject]@{ Status = $global:ztpE_signature } }

    function New-TestSbe {
        # An SBE folder: SBE_<name>.zip with one network driver INF, its <name>.xml and SBE_Discovery_Contoso.xml. -HashInManifest overrides the published hash.
        param([Parameter(Mandatory)][string]$Dir, [string]$Name = 'SBE_Contoso_1.0.0.0', [string]$HashInManifest, [string]$ManifestName = $Name)
        $null = New-Item -ItemType Directory -Force -Path $Dir
        $tree = Join-Path $TestDrive "sbe-tree-$([guid]::NewGuid().ToString('N'))"
        $nic = Join-Path $tree 'Drivers/Network/nicA'
        $null = New-Item -ItemType Directory -Force -Path $nic
        Set-Content -LiteralPath (Join-Path $nic 'nic.inf') -Value "[Version]`nDriverVer = 01/02/2026,1.2.3.4`n[Models]`n%NicA% = Install, PCI\VEN_8086&DEV_1572&SUBSYS_00000000"
        Set-Content -LiteralPath (Join-Path $nic 'nic.cat') -Value 'catalog'
        Set-Content -LiteralPath (Join-Path $tree 'unrelated.txt') -Value 'outside the driver folders'
        $zip = Join-Path $Dir "$Name.zip"
        [IO.Compression.ZipFile]::CreateFromDirectory($tree, $zip)
        $hash = if ($HashInManifest) { $HashInManifest } else { (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash }
        Set-Content -LiteralPath (Join-Path $Dir "$Name.xml") -Value '<package />'
        Set-Content -LiteralPath (Join-Path $Dir 'SBE_Discovery_Contoso.xml') -Value "<SBEUpdatesManifest><ApplicableUpdate Version=`"1.0.0.0`" Type=`"SBE`"><UpdateInfo><UpdateName>$ManifestName</UpdateName><PackageHash>$hash</PackageHash></UpdateInfo></ApplicableUpdate></SBEUpdatesManifest>"
        $Dir
    }

    function New-TestEnvironment {
        # Writes the fixture to TestDrive with the SBE folder filled in; -Edit receives the parsed file to change before it is written.
        param([Parameter(Mandatory)][string]$Name, [string]$Sbe = 'C:\unused', [scriptblock]$Edit)
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        $e.ztp.node_preparation.sbe_bundle = $Sbe
        if ($Edit) { & $Edit $e }
        $path = Join-Path $TestDrive "$Name.yml"
        Set-Content -LiteralPath $path -Value (ConvertTo-Yaml $e)
        $path
    }

    function New-TestRepo {
        # A copy of the script layout (scripts/simplified-provisioning, config/oem) the scripts resolve their default paths against.
        param([Parameter(Mandatory)][string]$Name, [string[]]$Copy, [string]$OemJson = '{ "oem": "Contoso", "sbe": { "driverPaths": [ "Drivers/Network" ] } }')
        $root = Join-Path $TestDrive $Name
        $bin = Join-Path $root 'scripts/simplified-provisioning'
        $null = New-Item -ItemType Directory -Force -Path $bin, (Join-Path $root 'config/oem')
        foreach ($f in $Copy) { Copy-Item -LiteralPath (Join-Path $script:scripts $f) -Destination $bin }
        Set-Content -LiteralPath (Join-Path $root 'config/oem/contoso.json') -Value $OemJson
        $root
    }
    function Get-StepText { param($Records) (@($Records) | ForEach-Object { "$_" }) -join "`n" }
    function Get-RunText {
        # Runs a script with named arguments and returns everything it wrote (all streams) plus the message of what it threw.
        param([string]$Path, [hashtable]$Arguments)
        $out = try { & $Path @Arguments *>&1 } catch { "THROWN: $($_.Exception.Message)" }
        Get-StepText $out
    }

    # Initialize-ZtpNode.ps1 beside a stub Azure layer.
    $script:initRoot = New-TestRepo -Name 'init-repo' -Copy 'Initialize-ZtpNode.ps1', 'ZtpEnvironment.Common.ps1', 'ZtpEvents.Common.ps1'
    $script:init = Join-Path $script:initRoot 'scripts/simplified-provisioning/Initialize-ZtpNode.ps1'
    Set-Content -LiteralPath (Join-Path $script:initRoot 'scripts/simplified-provisioning/ZtpAzure.Common.ps1') -Value @'
function Invoke-ZtpArm { [CmdletBinding()] param($Method, $Path, [switch]$AllowNotFound) $null }
function Get-ZtpEdgeMachineStatus { [CmdletBinding()] param($Name, $Machine, $Job) $global:ztpE_azureStatus }
'@
    $script:readyStatus = [pscustomobject]@{ Lifecycle = 'ReadyToCluster'; JobStatus = 'Succeeded'; Connectivity = 'Connected'; CurrentStage = ''; Ready = $true; Failed = $false; FailureReason = '' }
    $port1 = [pscustomobject]@{ Name = 'Port 1'; Mac = '02-00-00-00-00-11'; Description = 'Example NIC'; Driver = '1.0.0.0'; Status = 'Up'; Id = 'PCI\VEN_8086&DEV_1572'; Addresses = @('192.0.2.200/24 Dhcp'); Gateway = $true; Dhcp = 'Enabled' }
    $port2 = [pscustomobject]@{ Name = 'Port 2'; Mac = '02-00-00-00-00-99'; Description = 'Example NIC'; Driver = '1.0.0.0'; Status = 'Up'; Id = 'PCI\VEN_8086&DEV_1572'; Addresses = @('192.0.2.201/24 Dhcp'); Gateway = $true; Dhcp = 'Enabled' }
    $script:nodeState = [pscustomobject]@{ Host = 'EXAMPLEHOST'; Adapters = @($port1, $port2); Mgmt = $port1; Dns = @(); SbeFiles = @(); SbeHash = ''; Admin = $false; Time = 'Local CMOS Clock'; Booted = '2026-01-01T00:00:00.0000000Z'; RebootPending = $false }
}
AfterAll { Get-Variable -Scope Global -Name 'ztpE_*' -ErrorAction SilentlyContinue | Remove-Variable -Scope Global -Force -ErrorAction SilentlyContinue }

Describe 'Reading the environment file' {
    It 'parses the example file into keys' {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        $e.cluster_nodes.Count | Should -Be 2
        $e.cluster_nodes[0].mac_address | Should -Be '02:00:00:00:00:11'
        $e.network_intents.management.subnet | Should -Be '192.0.2.0/24'
    }
    It 'names the file when it is missing, empty, not YAML or not a mapping' {
        { Read-ZtpEnvironmentFile -Path (Join-Path $TestDrive 'absent.yml') } | Should -Throw "*absent.yml' doesn't exist*"
        $empty = Join-Path $TestDrive 'empty.yml'; Set-Content -LiteralPath $empty -Value "  `n"
        { Read-ZtpEnvironmentFile -Path $empty } | Should -Throw '*is empty*'
        $broken = Join-Path $TestDrive 'broken.yml'; Set-Content -LiteralPath $broken -Value "ztp: [unclosed`n  key: : value"
        { Read-ZtpEnvironmentFile -Path $broken } | Should -Throw "*isn't valid YAML*"
        $list = Join-Path $TestDrive 'list.yml'; Set-Content -LiteralPath $list -Value "- one`n- two"
        { Read-ZtpEnvironmentFile -Path $list } | Should -Throw '*must be a YAML mapping*'
    }
}

Describe 'Checking the environment file' {
    It 'accepts the example file for both scripts' {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        @(Test-ZtpEnvironment -Environment $e -For Provision).Count | Should -Be 0
        @(Test-ZtpEnvironment -Environment $e -For Prepare).Count | Should -Be 0
        { Assert-ZtpEnvironment -Environment $e } | Should -Not -Throw
    }
    It 'reports <Expect> when <Case>' -ForEach @(
        @{ Case = 'the tenant is not a GUID'; Edit = { param($e) $e.azure_identity.azure_tenant_id = 'not-a-guid' }; Expect = 'azure_identity.azure_tenant_id must be a GUID' }
        @{ Case = 'cluster_nodes is missing'; Edit = { param($e) $e.Remove('cluster_nodes') }; Expect = 'cluster_nodes is required' }
        @{ Case = 'cluster_nodes is empty'; Edit = { param($e) $e.cluster_nodes = @() }; Expect = 'cluster_nodes is required' }
        @{ Case = 'a node has no name'; Edit = { param($e) $e.cluster_nodes[1].Remove('name') }; Expect = 'cluster_nodes[1].name is required' }
        @{ Case = 'two nodes share a name'; Edit = { param($e) $e.cluster_nodes[1].name = 'NODE-01' }; Expect = "'NODE-01' is used twice" }
        @{ Case = 'a node address is not IPv4'; Edit = { param($e) $e.cluster_nodes[0].ip_address = '192.0.2.999' }; Expect = 'cluster_nodes[0] (node-01).ip_address must be an IPv4 address' }
        @{ Case = 'a MAC address is malformed'; Edit = { param($e) $e.cluster_nodes[0].mac_address = '0200.0000.0011' }; Expect = 'cluster_nodes[0] (node-01).mac_address must be a MAC address' }
        @{ Case = 'a service tag is missing'; Edit = { param($e) $e.cluster_nodes[1].Remove('service_tag') }; Expect = 'cluster_nodes[1] (node-02).service_tag is required' }
        @{ Case = 'the management subnet has no prefix'; Edit = { param($e) $e.network_intents.management.subnet = '192.0.2.0' }; Expect = 'network_intents.management.subnet must be an IPv4 subnet' }
        @{ Case = 'the gateway is missing'; Edit = { param($e) $e.network_intents.management.Remove('gateway') }; Expect = 'network_intents.management.gateway is required' }
        @{ Case = 'DNS servers are not a list'; Edit = { param($e) $e.network_intents.management.dns_servers = '192.0.2.53' }; Expect = 'dns_servers must be a non-empty list' }
        @{ Case = 'a DNS server is not an address'; Edit = { param($e) $e.network_intents.management.dns_servers = @('dns.example.com') }; Expect = "has 'dns.example.com'" }
        @{ Case = 'the deployment admin is a built-in account'; Edit = { param($e) $e.credentials.local_admin_username = 'Administrator' }; Expect = "can't be the built-in account" }
        @{ Case = 'the deployment secret is not a Key Vault reference'; Edit = { param($e) $e.credentials.local_admin_password_secret = 'plaintext' }; Expect = 'must be keyvault://<vault>/<secret>' }
        @{ Case = 'the subscription is not a GUID'; Edit = { param($e) $e.ztp.subscription_id = 'sub' }; Expect = 'ztp.subscription_id must be a GUID' }
        @{ Case = 'the admin secret has no vault'; Edit = { param($e) $e.ztp.admin_secret.Remove('vault') }; Expect = 'ztp.admin_secret.vault is required' }
        @{ Case = 'the SBE folder is not named'; Edit = { param($e) $e.ztp.Remove('node_preparation') }; Expect = 'ztp.node_preparation.sbe_bundle is required' }
        @{ Case = 'no share host is given'; Edit = { param($e) $e.ztp.Remove('share_host') }; Expect = 'ztp.share_host or ztp.share_host_adapter is required' }
        @{ Case = 'the BMC secret is missing'; Edit = { param($e) $e.ztp.Remove('bmc_secret') }; Expect = 'ztp.bmc_secret.vault is required' }
        @{ Case = 'the resource provider object ID is not a GUID'; Edit = { param($e) $e.ztp.azl_rp_object_id = 'x' }; Expect = 'ztp.azl_rp_object_id must be a GUID' }
        @{ Case = 'tags are a list'; Edit = { param($e) $e.ztp.tags = @('a') }; Expect = 'ztp.tags must be a mapping' }
        @{ Case = 'the location is missing'; Edit = { param($e) $e.Remove('azure_resources') }; Expect = 'azure_resources.location is required' }
        @{ Case = 'the unvalidated-SBE switch is not true or false'; Edit = { param($e) $e.ztp.node_preparation.allow_unvalidated_sbe = 'yes' }; Expect = "allow_unvalidated_sbe must be true or false, not 'yes'" }
        @{ Case = 'the management IP assignment is unknown'; Edit = { param($e) $e.network_intents.management.ip_assignment = 'auto' }; Expect = "ip_assignment must be static, dhcp or preconfigured, not 'auto'" }
        @{ Case = 'the management VLAN is out of range'; Edit = { param($e) $e.network_intents.management.vlan_id = 5000 }; Expect = "vlan_id must be 0-4094, not '5000'" }
        @{ Case = 'an Arc machine name has a space'; Edit = { param($e) $e.cluster_nodes[0].arc_machine_name = 'node 01' }; Expect = "arc_machine_name 'node 01' isn't a valid Arc machine name" }
        @{ Case = 'an Arc machine name ends in a dot'; Edit = { param($e) $e.cluster_nodes[0].arc_machine_name = 'node-01.' }; Expect = "arc_machine_name 'node-01.' isn't a valid Arc machine name" }
    ) {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        & $Edit $e
        $problems = @(Test-ZtpEnvironment -Environment $e -For Provision)
        # Contains, not -BeLike: the node labels hold [ ].
        ($problems -join "`n").Contains($Expect) | Should -BeTrue -Because "the problems were: $($problems -join '; ')"
    }
    It 'accepts a share host adapter instead of a share host, and leaves NTP, tags and the resource provider ID optional' {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        $e.ztp.Remove('share_host'); $e.ztp.share_host_adapter = 'Ethernet 2'
        $e.ztp.Remove('tags'); $e.ztp.Remove('azl_rp_object_id'); $e.onprem.Remove('ntp_servers')
        @(Test-ZtpEnvironment -Environment $e -For Provision).Count | Should -Be 0
    }
    It 'accepts allow_unvalidated_sbe as true or false, and leaves it optional' {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        foreach ($v in $true, $false) {
            $e.ztp.node_preparation.allow_unvalidated_sbe = $v
            @(Test-ZtpEnvironment -Environment $e -For Provision).Count | Should -Be 0
        }
    }
    It 'checks only what Initialize-ZtpNode.ps1 reads for Prepare, so provisioning-only keys can be missing' {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        $e.Remove('azure_resources'); $e.Remove('site'); $e.ztp.Remove('share_name'); $e.ztp.Remove('bmc_secret'); $e.cluster_nodes[0].Remove('service_tag')
        @(Test-ZtpEnvironment -Environment $e -For Prepare).Count | Should -Be 0
        @(Test-ZtpEnvironment -Environment $e -For Provision).Count | Should -BeGreaterThan 3
    }
    It 'names every problem at once, with the count and the file' {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        $e.azure_identity.azure_tenant_id = 'x'; $e.ztp.Remove('resource_group'); $e.cluster_nodes[0].mac_address = 'zz'
        $caught = $null
        try { Assert-ZtpEnvironment -Environment $e -Source 'infra.yml' } catch { $caught = $_.Exception.Message }
        $caught | Should -BeLike 'infra.yml is invalid (3 problems):*'
        $caught | Should -BeLike '*azure_identity.azure_tenant_id must be a GUID*'
        $caught | Should -BeLike '*ztp.resource_group is required*'
        $caught | Should -BeLike '*mac_address must be a MAC address*'
    }
}

Describe 'Management address and Arc name settings' {
    It 'defaults the management IP assignment to static and reads the value given' {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        $e.network_intents.management.Remove('ip_assignment')
        Get-ZtpManagementAssignment -Environment $e | Should -Be 'static'
        foreach ($m in 'static', 'dhcp', 'preconfigured', 'DHCP') {
            $e.network_intents.management.ip_assignment = $m
            Get-ZtpManagementAssignment -Environment $e | Should -Be $m.ToLowerInvariant()
            @(Test-ZtpEnvironment -Environment $e -For Provision).Count | Should -Be 0 -Because "$m is a valid mode"
        }
    }
    It 'accepts an Arc machine name, an adapter name and a VLAN, and leaves them optional' {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        $e.cluster_nodes[0].arc_machine_name = 'node-01'; $e.cluster_nodes[0].adapter_name = 'SLOT 3 Port 1'; $e.network_intents.management.vlan_id = 711
        @(Test-ZtpEnvironment -Environment $e -For Provision).Count | Should -Be 0
    }
    It 'turns a prefix length into a subnet mask' -ForEach @(
        @{ Prefix = 24; Mask = '255.255.255.0' }, @{ Prefix = 22; Mask = '255.255.252.0' }, @{ Prefix = 32; Mask = '255.255.255.255' }, @{ Prefix = 0; Mask = '0.0.0.0' }, @{ Prefix = 1; Mask = '128.0.0.0' }
    ) {
        ConvertTo-ZtpSubnetMask -PrefixLength $Prefix | Should -Be $Mask
    }
}

Describe 'Choosing the nodes' {
    BeforeAll { $script:envData = Read-ZtpEnvironmentFile -Path $script:fixture }
    It 'covers every node in the file by default, in file order' {
        @(Resolve-ZtpNodeSelection -Environment $script:envData) | Should -Be @('node-01', 'node-02')
    }
    It 'covers only the nodes named, once each' {
        @(Resolve-ZtpNodeSelection -Environment $script:envData -Node 'node-02') | Should -Be @('node-02')
        @(Resolve-ZtpNodeSelection -Environment $script:envData -Node 'node-02', 'node-01', 'node-02') | Should -Be @('node-02', 'node-01')
    }
    It 'refuses a node that is not in the file and lists the ones that are' {
        { Resolve-ZtpNodeSelection -Environment $script:envData -Node 'node-09' } | Should -Throw "*Node node-09 isn't in the environment file. Nodes there: node-01, node-02.*"
    }
}

Describe 'The SBE folder and its SHA-256' {
    It 'finds the zip, its XML and the discovery XML' {
        $b = Get-ZtpSbeBundle -Path (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-ok'))
        $b.Name | Should -Be 'SBE_Contoso_1.0.0.0'
        $b.Files.Name | Should -Be @('SBE_Contoso_1.0.0.0.zip', 'SBE_Contoso_1.0.0.0.xml', 'SBE_Discovery_Contoso.xml')
    }
    It 'says what is wrong with the folder' {
        { Get-ZtpSbeBundle -Path (Join-Path $TestDrive 'no-such-folder') } | Should -Throw "*doesn't exist*"
        $none = Join-Path $TestDrive 'sbe-none'; $null = New-Item -ItemType Directory -Path $none
        { Get-ZtpSbeBundle -Path $none } | Should -Throw '*Expected one SBE_*.zip*found 0*'
        $two = New-TestSbe -Dir (Join-Path $TestDrive 'sbe-two'); Copy-Item (Join-Path $two 'SBE_Contoso_1.0.0.0.zip') (Join-Path $two 'SBE_Contoso_2.0.0.0.zip')
        { Get-ZtpSbeBundle -Path $two } | Should -Throw '*found 2*'
        $noXml = New-TestSbe -Dir (Join-Path $TestDrive 'sbe-no-xml'); Remove-Item (Join-Path $noXml 'SBE_Contoso_1.0.0.0.xml')
        { Get-ZtpSbeBundle -Path $noXml } | Should -Throw '*needs SBE_Contoso_1.0.0.0.zip, SBE_Contoso_1.0.0.0.xml and the SBE_Discovery_*.xml*'
        $noDiscovery = New-TestSbe -Dir (Join-Path $TestDrive 'sbe-no-discovery'); Remove-Item (Join-Path $noDiscovery 'SBE_Discovery_Contoso.xml')
        { Get-ZtpSbeBundle -Path $noDiscovery } | Should -Throw '*SBE_Discovery_*.xml*'
    }
    It "passes when the zip matches the package's own discovery XML" {
        $b = Get-ZtpSbeBundle -Path (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-hash-ok'))
        $r = Test-ZtpSbeHash -Bundle $b
        $r.Hash | Should -Be (Get-FileHash -LiteralPath $b.Zip.FullName -Algorithm SHA256).Hash
        $r.Source | Should -Be 'SBE_Discovery_Contoso.xml'
    }
    It 'rejects a zip whose hash differs from the published one, naming both' {
        $b = Get-ZtpSbeBundle -Path (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-hash-bad') -HashInManifest ('AB' * 32))
        { Test-ZtpSbeHash -Bundle $b } | Should -Throw "*SBE_Contoso_1.0.0.0.zip has SHA-256 *; SBE_Discovery_Contoso.xml says $('AB' * 32)*"
    }
    It 'rejects a manifest that does not list the SBE or is not a discovery manifest' {
        $b = Get-ZtpSbeBundle -Path (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-hash-other') -ManifestName 'SBE_Contoso_9.9.9.9')
        { Test-ZtpSbeHash -Bundle $b } | Should -Throw "*SBE_Contoso_1.0.0.0 isn't in SBE_Discovery_Contoso.xml*"
        Set-Content -LiteralPath (Join-Path $b.Files[2].DirectoryName 'SBE_Discovery_Contoso.xml') -Value '<html />'
        { Test-ZtpSbeHash -Bundle $b } | Should -Throw "*isn't an SBE discovery manifest*"
        Set-Content -LiteralPath (Join-Path $b.Files[2].DirectoryName 'SBE_Discovery_Contoso.xml') -Value 'not xml <'
        { Test-ZtpSbeHash -Bundle $b } | Should -Throw "*isn't valid XML*"
    }
    It "reads the OEM's published manifest when given a URL, and falls back to the package's XML when it can't" {
        $b = Get-ZtpSbeBundle -Path (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-hash-url') -HashInManifest ('CD' * 32))
        $good = (Get-FileHash -LiteralPath $b.Zip.FullName -Algorithm SHA256).Hash
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = "<SBEUpdatesManifest><ApplicableUpdate><UpdateInfo><UpdateName>SBE_Contoso_1.0.0.0</UpdateName><PackageHash>$($good.ToLowerInvariant())</PackageHash></UpdateInfo></ApplicableUpdate></SBEUpdatesManifest>" } }
        (Test-ZtpSbeHash -Bundle $b -ManifestUrl 'https://example.invalid/manifest.xml').Source | Should -Be 'https://example.invalid/manifest.xml'
        Mock Invoke-WebRequest { throw 'offline' }
        { Test-ZtpSbeHash -Bundle $b -ManifestUrl 'https://example.invalid/manifest.xml' -WarningAction SilentlyContinue } | Should -Throw "*SBE_Discovery_Contoso.xml says $('CD' * 32)*"
    }
}

Describe 'Initialize-ZtpNode.ps1 plan' {
    BeforeEach {
        $global:ztpE_calls.Clear()
        $global:ztpE_azureStatus = $script:readyStatus
        $global:ztpE_nodeState = $script:nodeState
        $global:ztpE_signature = 'Valid'
        Remove-Item -LiteralPath (Join-Path $script:initRoot '_media') -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'plans the node: verifies the SBE, unpacks only the driver folders under the repo, and changes nothing' {
        $infra = New-TestEnvironment -Name 'init-plan' -Sbe (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-plan'))
        $text = Get-StepText (& $script:init -InfrastructureFile $infra -Node node-01 *>&1)
        $text | Should -BeLike '*SBE SBE_Contoso_1.0.0.0: SHA-256 matches SBE_Discovery_Contoso.xml*'
        $text | Should -BeLike '*SBE network drivers indexed: 1*'
        $text | Should -BeLike '*Port 1 PCI\VEN_8086&DEV_1572 driver 1.0.0.0 -> 1.2.3.4 (nic.inf)*'
        $text | Should -BeLike '*PLAN: drivers nic.inf 1.2.3.4 (signatures valid); SBE to C:\SBE; create deployadmin; static 192.0.2.11/24 gw 192.0.2.1 on Port 1; DHCP and gateway off on Port 2; DNS 192.0.2.53,192.0.2.54; time ntp.example.com.*'
        $text | Should -BeLike '*Plan only. Add -Execute*'
        $staging = Join-Path $script:initRoot '_media/sbe-drivers/SBE_Contoso_1.0.0.0'
        Test-Path (Join-Path $staging '.extracted') | Should -BeTrue
        Test-Path (Join-Path $staging 'Drivers/Network/nicA/nic.inf') | Should -BeTrue
        Test-Path (Join-Path $staging 'unrelated.txt') | Should -BeFalse
        # Only the node asked for was contacted.
        $global:ztpE_calls | Should -Not -Contain 'New-PSSession 192.0.2.12'
    }

    It 'takes the driver staging folder and the OEM folder from parameters' {
        $infra = New-TestEnvironment -Name 'init-params' -Sbe (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-params'))
        $oem = Join-Path $TestDrive 'oem-elsewhere'; $null = New-Item -ItemType Directory -Path $oem
        Set-Content -LiteralPath (Join-Path $oem 'contoso.json') -Value '{ "sbe": { "driverPaths": [ "Drivers/Network/" ] } }'
        $staging = Join-Path $TestDrive 'staging-elsewhere'
        $null = & $script:init -InfrastructureFile $infra -Node node-01 -DriverStagingPath $staging -OemConfigDirectory $oem *>&1
        Test-Path (Join-Path $staging 'SBE_Contoso_1.0.0.0/.extracted') | Should -BeTrue
        Test-Path (Join-Path $script:initRoot '_media') | Should -BeFalse
    }

    It 'covers every node in the file by default and only the named one when told' {
        $infra = New-TestEnvironment -Name 'init-nodes' -Sbe (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-nodes'))
        $all = Get-StepText (& $script:init -InfrastructureFile $infra *>&1)
        $all | Should -BeLike '*== node-01 (192.0.2.11)*'
        $all | Should -BeLike '*== node-02 (192.0.2.12)*'
        $one = Get-StepText (& $script:init -InfrastructureFile $infra -Node node-02 *>&1)
        $one | Should -BeLike '*== node-02 (192.0.2.12)*'
        $one | Should -Not -BeLike '*== node-01*'
        { & $script:init -InfrastructureFile $infra -Node node-09 } | Should -Throw "*Node node-09 isn't in the environment file*"
    }

    It 'stops before any Azure call when the SBE zip does not match the published SHA-256' {
        $infra = New-TestEnvironment -Name 'init-badhash' -Sbe (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-badhash') -HashInManifest ('AB' * 32))
        { & $script:init -InfrastructureFile $infra -Node node-01 } | Should -Throw "*has SHA-256*; SBE_Discovery_Contoso.xml says $('AB' * 32)*"
        $global:ztpE_calls.Count | Should -Be 0
    }

    It 'stops when the SBE folder is missing or the OEM names no driver folders' {
        $infra = New-TestEnvironment -Name 'init-nofolder' -Sbe (Join-Path $TestDrive 'not-there')
        { & $script:init -InfrastructureFile $infra } | Should -Throw "*SBE folder*doesn't exist*"
        $infra2 = New-TestEnvironment -Name 'init-nodrivers' -Sbe (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-nodrivers'))
        $oem = Join-Path $TestDrive 'oem-nodrivers'; $null = New-Item -ItemType Directory -Path $oem
        Set-Content -LiteralPath (Join-Path $oem 'contoso.json') -Value '{ "sbe": { } }'
        { & $script:init -InfrastructureFile $infra2 -OemConfigDirectory $oem } | Should -Throw '*Set sbe.driverPaths in*'
    }

    It 'fails early and names the problem when the environment file is wrong' {
        $infra = New-TestEnvironment -Name 'init-invalid' -Sbe (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-invalid')) -Edit { param($e) $e.network_intents.management.Remove('gateway'); $e.ztp.admin_secret.Remove('vault') }
        { & $script:init -InfrastructureFile $infra } | Should -Throw '*is invalid (2 problems):*network_intents.management.gateway is required*ztp.admin_secret.vault is required*'
        $global:ztpE_calls.Count | Should -Be 0
        $unnamed = New-TestEnvironment -Name 'init-no-sbe-key' -Edit { param($e) $e.ztp.Remove('node_preparation') }
        { & $script:init -InfrastructureFile $unnamed } | Should -Throw '*ztp.node_preparation.sbe_bundle is required*'
    }

    It 'refuses a driver whose catalog signature is not valid' {
        $global:ztpE_signature = 'NotSigned'
        $infra = New-TestEnvironment -Name 'init-unsigned' -Sbe (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-unsigned'))
        $text = Get-RunText $script:init @{ InfrastructureFile = $infra; Node = 'node-01' }
        $text | Should -BeLike '*nic.cat for nic.inf has signature NotSigned*'
        $text | Should -BeLike '*THROWN: Not ready: node-01*'
        $text | Should -Not -BeLike '*PLAN:*'
    }

    It 'reports a node that Azure does not call ready, one that failed, and one that has no adapter with its MAC' {
        $infra = New-TestEnvironment -Name 'init-notready' -Sbe (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-notready'))
        $global:ztpE_azureStatus = [pscustomobject]@{ Lifecycle = 'AwaitingConnection'; JobStatus = 'InProgress'; Connectivity = 'Connecting'; CurrentStage = 'ProvisionOs'; Ready = $false; Failed = $false; FailureReason = '' }
        $text = Get-RunText $script:init @{ InfrastructureFile = $infra; Node = 'node-01' }
        $text | Should -BeLike '*Azure: lifecycle AwaitingConnection, job InProgress, Arc Connecting, at ProvisionOs*'
        $text | Should -BeLike '*Not Ready to cluster yet*'
        $text | Should -BeLike '*THROWN: Not ready: node-01*'
        $global:ztpE_azureStatus = [pscustomobject]@{ Lifecycle = 'Failed'; JobStatus = 'Failed'; Connectivity = ''; CurrentStage = ''; Ready = $false; Failed = $true; FailureReason = 'example failure' }
        (Get-RunText $script:init @{ InfrastructureFile = $infra; Node = 'node-01' }) | Should -BeLike '*Azure reports node-01 failed: example failure*'
        $global:ztpE_azureStatus = $script:readyStatus
        $global:ztpE_nodeState = [pscustomobject]@{ Host = 'EXAMPLEHOST'; Adapters = @(); Mgmt = $null; Dns = @(); SbeFiles = @(); SbeHash = ''; Admin = $false; Time = ''; Booted = ''; RebootPending = $false }
        (Get-RunText $script:init @{ InfrastructureFile = $infra; Node = 'node-01' }) | Should -BeLike '*No adapter on node-01 has the environment file*02-00-00-00-00-11*'
    }
}
Describe 'Initialize-ZtpNode.ps1 with several nodes' {
    It 'prepares every node at the same time, one worker each, and reports each failure' {
        $root = New-TestRepo -Name 'init-parallel' -Copy 'Initialize-ZtpNode.ps1', 'ZtpEnvironment.Common.ps1', 'ZtpEvents.Common.ps1'
        Set-Content -LiteralPath (Join-Path $root 'scripts/simplified-provisioning/ZtpAzure.Common.ps1') -Value '# unused: the workers are stubs'
        $worker = Join-Path $root 'Worker.ps1'
        # The stub worker records when it started and finished and what it was asked, takes 3 seconds, and fails for one node on request.
        Set-Content -LiteralPath $worker -Value @'
param([string]$InfrastructureFile, [string[]]$Node, [int]$ReadyTimeoutMinutes, [int]$ReachTimeoutMinutes, [string]$DriverStagingPath, [string]$OemConfigDirectory, [string]$EventLogPath, [switch]$Execute)
$started = [datetime]::UtcNow.Ticks
Start-Sleep -Seconds 3
[pscustomobject]@{ Node = @($Node); Started = $started; Finished = [datetime]::UtcNow.Ticks; Execute = [bool]$Execute; Staging = $DriverStagingPath; Oem = $OemConfigDirectory; Events = $EventLogPath; Ready = $ReadyTimeoutMinutes; Reach = $ReachTimeoutMinutes } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:ZTP_TEST_WORKER_DIR "$($Node[0]).json")
if ($env:ZTP_TEST_FAIL_NODE -eq $Node[0]) { Write-Output "$($Node[0]): example failure"; exit 1 }
'@
        $records = Join-Path $TestDrive 'worker-records'
        $null = New-Item -ItemType Directory -Path $records
        $infra = New-TestEnvironment -Name 'init-parallel' -Sbe (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-parallel'))
        $staging = Join-Path $TestDrive 'parallel-staging'
        $oem = Join-Path $root 'config/oem'
        $events = Join-Path $TestDrive 'parallel-events/ztp-events.jsonl'
        $run = { & (Join-Path $root 'scripts/simplified-provisioning/Initialize-ZtpNode.ps1') -InfrastructureFile $infra -Node node-01, node-02 -Execute -DriverStagingPath $staging -OemConfigDirectory $oem -WorkerScriptPath $worker -ReadyTimeoutMinutes 7 -ReachTimeoutMinutes 5 -EventLogPath $events *>&1 }

        $env:ZTP_TEST_WORKER_DIR = $records
        $env:ZTP_TEST_FAIL_NODE = ''
        try {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $text = Get-StepText (& $run)
            $clock.Stop()
            $text | Should -BeLike '*Preparing node-01, node-02 at the same time*'
            $text | Should -BeLike '*All ready for Validate: node-01, node-02*'
            $a = Get-Content -LiteralPath (Join-Path $records 'node-01.json') -Raw | ConvertFrom-Json
            $b = Get-Content -LiteralPath (Join-Path $records 'node-02.json') -Raw | ConvertFrom-Json
            # One worker per node, each for its own node alone, with the parameters passed on.
            @($a.Node) | Should -Be @('node-01')
            @($b.Node) | Should -Be @('node-02')
            foreach ($w in $a, $b) { $w.Execute | Should -BeTrue; $w.Staging | Should -Be $staging; $w.Oem | Should -Be $oem; $w.Events | Should -Be $events; $w.Ready | Should -Be 7; $w.Reach | Should -Be 5 }
            # They ran together: each started before the other finished (run one after the other, the second would start after the first ended).
            [math]::Max($a.Started, $b.Started) | Should -BeLessThan ([math]::Min($a.Finished, $b.Finished))
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 12

            $env:ZTP_TEST_FAIL_NODE = 'node-02'
            { $null = & $run } | Should -Throw '*Not ready: node-02*'
        }
        finally { $env:ZTP_TEST_WORKER_DIR = $null; $env:ZTP_TEST_FAIL_NODE = $null }
    }
}

Describe 'Invoke-ZtpEnvironment.ps1 plan' {
    BeforeAll {
        $script:envRoot = New-TestRepo -Name 'env-repo' -Copy 'Invoke-ZtpEnvironment.ps1', 'ZtpEnvironment.Common.ps1'
        $script:envScript = Join-Path $script:envRoot 'scripts/simplified-provisioning/Invoke-ZtpEnvironment.ps1'
        $bin = Join-Path $script:envRoot 'scripts/simplified-provisioning'
        $params = '$ConfigPath, $NodeName, $BmcCredential, $InfrastructureFile, $Node, $DriverStagingPath, $EventLogPath, $From, [switch]$ConfirmNotClustered, [switch]$SkipCertificateCheck, [switch]$RetryProvisionOs, [switch]$RebuildImages, [switch]$Execute'
        foreach ($stub in 'Invoke-ZtpProvisioning.ps1', 'Initialize-ZtpNode.ps1') {
            Set-Content -LiteralPath (Join-Path $bin $stub) -Value @"
[CmdletBinding(SupportsShouldProcess)]
param($params)
`$bound = @{}; foreach (`$k in `$PSBoundParameters.Keys) { `$bound[`$k] = `$PSBoundParameters[`$k] }
`$global:ztpE_runs.Add([pscustomobject]@{ Script = '$stub'; Params = `$bound })
"@
        }
        $script:media = Join-Path $TestDrive 'env-media'
    }
    BeforeEach {
        $global:ztpE_calls.Clear(); $global:ztpE_runs.Clear()
    }

    It 'writes the ZTP inputs from the file, keeps its state under -MediaPath, and runs the stages and Prepare as plans' {
        $sbe = New-TestSbe -Dir (Join-Path $TestDrive 'sbe-env')
        $infra = New-TestEnvironment -Name 'env-plan' -Sbe $sbe
        $null = & $script:envScript -InfrastructureFile $infra -MediaPath $script:media *>&1

        $nodes = Get-Content -LiteralPath (Join-Path $script:envRoot 'config/simplified-provisioning/nodes.json') -Raw | ConvertFrom-Json
        $nodes.nodes.name | Should -Be @('node-01', 'node-02')
        $nodes.nodes[0].bmc_address | Should -Be '198.51.100.11'
        $nodes.nodes[0].service_tag | Should -Be 'EXAMPLE1'
        $nodes.nodes[0].management_ip | Should -Be '192.0.2.11'

        $cfg = Get-Content -LiteralPath (Join-Path $script:envRoot 'config/simplified-provisioning/ztp-provisioning.json') -Raw | ConvertFrom-Json
        $cfg.BootstrapCacheDirectory | Should -Be $script:media
        $cfg.ShareHost | Should -Be '192.0.2.10'
        $cfg.ShareName | Should -Be 'ztp-example'
        $cfg.Oem | Should -Be 'Contoso'
        $cfg.SbeModel | Should -Be 'AX760'
        $cfg.SbePackagePath | Should -Be (Join-Path $sbe 'SBE_Contoso_1.0.0.0.zip')
        $cfg.ResourceGroupName | Should -Be 'rg-example'
        $cfg.StatePath | Should -Be (Join-Path $script:media 'ztp-state/node-01+node-02.ztp-provisioning.state.json')
        $cfg.VoucherDirectory | Should -Be (Join-Path $script:media 'vouchers')
        Test-Path (Join-Path $script:media 'ztp-state') | Should -BeTrue

        $bicep = Get-Content -LiteralPath (Join-Path $script:envRoot 'scripts/simplified-provisioning/bicep/main.parameters.json') -Raw | ConvertFrom-Json
        $bicep.parameters.key_vault_name.value | Should -Be 'kv-example'
        $bicep.parameters.azl_rp_app_object_id.value | Should -Be '00000000-0000-0000-0000-000000000001'
        @($bicep.parameters.nodes.value).Count | Should -Be 2
        $bicep.parameters.tags.value.purpose | Should -Be 'example'
        # The Arc machine is named after the node, and the static management address is keyed by the port's MAC.
        $n1 = $bicep.parameters.nodes.value[0]
        $n1.arc_machine_name | Should -Be 'node-01'
        $n1.management.ip_assignment | Should -Be 'static'
        $n1.management.mac_address | Should -Be '02:00:00:00:00:11'
        $n1.management.ip_address | Should -Be '192.0.2.11'
        $n1.management.subnet_mask | Should -Be '255.255.255.0'
        $n1.management.vlan_id | Should -Be '0'

        $global:ztpE_runs.Script | Should -Be @('Invoke-ZtpProvisioning.ps1', 'Initialize-ZtpNode.ps1')
        $global:ztpE_runs[0].Params['NodeName'] | Should -Be @('node-01', 'node-02')
        $global:ztpE_runs[0].Params.ContainsKey('Execute') | Should -BeFalse
        $global:ztpE_runs[1].Params['DriverStagingPath'] | Should -Be (Join-Path $script:media 'sbe-drivers')
        $global:ztpE_runs[1].Params['EventLogPath'] | Should -Be (Join-Path $script:media 'ztp-state/ztp-events.jsonl') -Because 'Prepare reports its gates to the event file Sonar follows'
        $global:ztpE_runs[1].Params.ContainsKey('Execute') | Should -BeFalse
        # Plan mode creates nothing in Azure and reads no secret.
        ($global:ztpE_calls -join "`n") | Should -Not -BeLike '*New-AzResourceGroup*'
        ($global:ztpE_calls -join "`n") | Should -Not -BeLike '*Get-AzKeyVaultSecret*'
    }

    It 'uses _media at the repository root when -MediaPath is not given' {
        $infra = New-TestEnvironment -Name 'env-default-media' -Sbe (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-env-default'))
        $null = & $script:envScript -InfrastructureFile $infra *>&1
        $cfg = Get-Content -LiteralPath (Join-Path $script:envRoot 'config/simplified-provisioning/ztp-provisioning.json') -Raw | ConvertFrom-Json
        $cfg.BootstrapCacheDirectory | Should -Be (Join-Path $script:envRoot '_media')
    }

    It 'covers the nodes named and keeps a separate state for that set' {
        $infra = New-TestEnvironment -Name 'env-one-node' -Sbe (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-env-one'))
        $null = & $script:envScript -InfrastructureFile $infra -MediaPath $script:media -Node node-02 *>&1
        $cfg = Get-Content -LiteralPath (Join-Path $script:envRoot 'config/simplified-provisioning/ztp-provisioning.json') -Raw | ConvertFrom-Json
        $cfg.StatePath | Should -BeLike '*node-02.ztp-provisioning.state.json'
        $global:ztpE_runs[0].Params['NodeName'] | Should -Be @('node-02')
        { & $script:envScript -InfrastructureFile $infra -MediaPath $script:media -Node node-09 *>&1 } | Should -Throw "*Node node-09 isn't in the environment file*"
    }

    It 'fails on a bad environment file before it writes anything or signs in' {
        $infra = New-TestEnvironment -Name 'env-invalid' -Sbe (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-env-invalid')) -Edit { param($e) $e.ztp.Remove('time_zone'); $e.cluster_nodes[0].idrac_ip = 'bmc.example.com' }
        Remove-Item -LiteralPath (Join-Path $script:envRoot 'config/simplified-provisioning/nodes.json') -ErrorAction SilentlyContinue
        { & $script:envScript -InfrastructureFile $infra -MediaPath $script:media } | Should -Throw '*is invalid (2 problems):*idrac_ip must be an IPv4 address*ztp.time_zone is required*'
        Test-Path (Join-Path $script:envRoot 'config/simplified-provisioning/nodes.json') | Should -BeFalse
        $global:ztpE_calls.Count | Should -Be 0
        { & $script:envScript -InfrastructureFile (Join-Path $TestDrive 'absent.yml') } | Should -Throw "*doesn't exist*"
    }

    It 'fails when the SBE folder named in the file is wrong' {
        $infra = New-TestEnvironment -Name 'env-no-sbe' -Sbe (Join-Path $TestDrive 'not-there')
        { & $script:envScript -InfrastructureFile $infra -MediaPath $script:media } | Should -Throw "*SBE folder*doesn't exist*"
    }

    It 'treats the external validator as optional and parameterized' {
        $infra = New-TestEnvironment -Name 'env-validator' -Sbe (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-env-validator'))
        # None beside the file and none given: runs on the built-in check alone.
        { $null = & $script:envScript -InfrastructureFile $infra -MediaPath $script:media *>&1 } | Should -Not -Throw
        # One given that does not exist: refused, because the operator asked for it.
        { & $script:envScript -InfrastructureFile $infra -MediaPath $script:media -ValidatorPath (Join-Path $TestDrive 'no-validator.ps1') } | Should -Throw "*Validator*doesn't exist*"
        # One given that passes, then one that fails.
        $pass = Join-Path $TestDrive 'validator-pass.ps1'
        Set-Content -LiteralPath $pass -Value 'param($ConfigFile) $global:ztpE_calls.Add("validator $(Split-Path $ConfigFile -Leaf)"); $global:LASTEXITCODE = 0'
        $null = & $script:envScript -InfrastructureFile $infra -MediaPath $script:media -ValidatorPath $pass *>&1
        $global:ztpE_calls | Should -Contain 'validator env-validator.yml'
        $fail = Join-Path $TestDrive 'validator-fail.ps1'
        Set-Content -LiteralPath $fail -Value 'param($ConfigFile) $global:LASTEXITCODE = 1'
        { & $script:envScript -InfrastructureFile $infra -MediaPath $script:media -ValidatorPath $fail } | Should -Throw '*failed validation*'
        # A validator beside the environment file (tools/Validate-Infrastructure.ps1) is found without a parameter.
        $beside = Join-Path $TestDrive 'beside'
        $null = New-Item -ItemType Directory -Path (Join-Path $beside 'tools')
        Copy-Item -LiteralPath $infra -Destination (Join-Path $beside 'infrastructure.yml')
        Copy-Item -LiteralPath $fail -Destination (Join-Path $beside 'tools/Validate-Infrastructure.ps1')
        { & $script:envScript -InfrastructureFile (Join-Path $beside 'infrastructure.yml') -MediaPath $script:media } | Should -Throw '*failed validation*'
        # The built-in check runs before the external one.
        $bad = New-TestEnvironment -Name 'env-bad-first' -Sbe (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-env-bad-first')) -Edit { param($e) $e.ztp.Remove('share_name') }
        { & $script:envScript -InfrastructureFile $bad -MediaPath $script:media -ValidatorPath $fail } | Should -Throw '*ztp.share_name is required*'
    }

    It 'finds the share host from the named adapter, and asks for the resource provider ID only when the file does not give it' {
        $infra = New-TestEnvironment -Name 'env-adapter' -Sbe (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-env-adapter')) -Edit { param($e) $e.ztp.Remove('share_host'); $e.ztp.share_host_adapter = 'Ethernet 2'; $e.ztp.Remove('azl_rp_object_id') }
        $null = & $script:envScript -InfrastructureFile $infra -MediaPath $script:media *>&1
        $cfg = Get-Content -LiteralPath (Join-Path $script:envRoot 'config/simplified-provisioning/ztp-provisioning.json') -Raw | ConvertFrom-Json
        $cfg.ShareHost | Should -Be '192.0.2.77'
        $global:ztpE_calls | Should -Contain 'Get-AzADServicePrincipal'
    }

    It 'with -Execute creates the resource group, runs the stages for the nodes and then Prepare; -From Prepare runs only Prepare' {
        $infra = New-TestEnvironment -Name 'env-execute' -Sbe (New-TestSbe -Dir (Join-Path $TestDrive 'sbe-env-execute'))
        $null = & $script:envScript -InfrastructureFile $infra -MediaPath $script:media -Node node-01 -Execute *>&1
        $global:ztpE_calls | Should -Contain 'New-AzResourceGroup rg-example'
        $global:ztpE_calls | Should -Contain 'Get-AzKeyVaultSecret kv-example/bmc-username'
        $global:ztpE_runs.Script | Should -Be @('Invoke-ZtpProvisioning.ps1', 'Initialize-ZtpNode.ps1')
        $run = $global:ztpE_runs[0].Params
        $run['Execute'] | Should -BeTrue
        $run['RebuildImages'] | Should -BeTrue
        $run['RetryProvisionOs'] | Should -BeTrue
        $run['NodeName'] | Should -Be @('node-01')
        $run['BmcCredential'].UserName | Should -Be 'bmc-example'
        $global:ztpE_runs[1].Params['Execute'] | Should -BeTrue
        $global:ztpE_runs[1].Params['Node'] | Should -Be @('node-01')

        $global:ztpE_calls.Clear(); $global:ztpE_runs.Clear()
        $null = & $script:envScript -InfrastructureFile $infra -MediaPath $script:media -From Prepare -Execute *>&1
        $global:ztpE_runs.Script | Should -Be @('Initialize-ZtpNode.ps1')
        $global:ztpE_calls | Should -Not -Contain 'New-AzResourceGroup rg-example'

        $global:ztpE_calls.Clear(); $global:ztpE_runs.Clear()
        $null = & $script:envScript -InfrastructureFile $infra -MediaPath $script:media -From Azure -Execute *>&1
        $global:ztpE_runs[0].Params['From'] | Should -Be 'Azure'
        $global:ztpE_runs[0].Params.ContainsKey('RebuildImages') | Should -BeFalse
    }
}

Describe 'Ported code stays generic' {
    It 'holds no tenant, subscription or private data in the scripts, config or tests' {
        $roots = 'scripts/simplified-provisioning', 'config', 'tests/simplified-provisioning' | ForEach-Object { Join-Path $script:repoRoot $_ }
        $files = Get-ChildItem -LiteralPath $roots -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.json', '.yml', '.yaml', '.bicep', '.xml', '.md' }
        # Words that would name a customer or lab, built in pieces so this file does not contain them.
        $words = ('tier' + 'point'), ('tp' + 'poc')
        $guid = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
        # Public identifiers only: placeholders, the Azure Local resource provider's published application ID, Azure built-in role definition IDs (the Bicep templates and their tests) and the Windows basic data partition type.
        $allowed = '^(00000000-0000-0000-0000-00000000000[0-9]|11111111-1111-1111-1111-111111111111|1412d89f-b8a8-4111-b4fd-e82905cbd85d|f58310d9-a9f6-439a-9e8d-f62e7b41a168|cd570a14-e51a-42ad-bac8-bafd67325302|f5819b54-e033-4d82-ac66-4fec3cbf3f4c|4633458b-17de-408a-b874-0445c86b69e6|ebd0a0a2-b9e5-4433-87c0-68b6b72699c7)$'
        $hits = foreach ($f in $files) {
            $text = Get-Content -LiteralPath $f.FullName -Raw
            foreach ($w in $words) { if ($text -match "(?i)$w") { "$($f.Name): $w" } }
            foreach ($m in [regex]::Matches($text, $guid)) { if ($m.Value -notmatch $allowed) { "$($f.Name): $($m.Value)" } }
        }
        @($hits) | Should -BeNullOrEmpty
    }
}
