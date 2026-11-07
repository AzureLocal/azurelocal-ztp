#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }, powershell-yaml
# The environment-file layer: ZtpEnvironment.Common.ps1 (parsing, key checks, node selection, schema 5 mapping),
# and the plan mode of Invoke-ZtpEnvironment.ps1 (no -Execute against Azure or a node). The script
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

    function New-TestEnvironment {
        # Writes the fixture to TestDrive with the SBE folder filled in; -Edit receives the parsed file to change before it is written.
        param([Parameter(Mandatory)][string]$Name, [scriptblock]$Edit)
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        # Run data in TestDrive, one folder per case: never in the repository, never in the real ProgramData.
        $e.ztp.media_path = Join-Path $TestDrive "data-$Name/media"
        $e.ztp.evidence_path = Join-Path $TestDrive "data-$Name/evidence"
        if ($Edit) { & $Edit $e }
        $path = Join-Path $TestDrive "$Name.yml"
        Set-Content -LiteralPath $path -Value (ConvertTo-Yaml $e)
        $path
    }

    $script:fixtureV5 = Join-Path $PSScriptRoot 'fixtures/infrastructure.v5.example.yml'
    function New-TestInfrastructureV5 {
        # Writes the schema 5 fixture to TestDrive with the SBE folder and run-data folders filled in; -Edit changes it first.
        param([Parameter(Mandatory)][string]$Name, [scriptblock]$Edit)
        $d = ConvertFrom-Yaml (Get-Content -LiteralPath $script:fixtureV5 -Raw) -Ordered
        $d.provisioning.simplified['media_path'] = Join-Path $TestDrive "data-$Name/media"
        $d.provisioning.simplified['evidence_path'] = Join-Path $TestDrive "data-$Name/evidence"
        if ($Edit) { & $Edit $d }
        $path = Join-Path $TestDrive "$Name.yml"
        Set-Content -LiteralPath $path -Value (ConvertTo-Yaml $d)
        $path
    }

    function New-TestRepo {
        # A copy of the script layout (scripts/simplified-provisioning, config/oem) the scripts resolve their default paths against.
        param([Parameter(Mandatory)][string]$Name, [string[]]$Copy, [string]$OemJson = '{ "oem": "Contoso", "publisher": "Contoso", "bmc": { "kind": "example", "logServices": [] } }')
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
    It 'accepts the example file' {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        @(Test-ZtpEnvironment -Environment $e).Count | Should -Be 0
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
        @{ Case = 'the subscription is not a GUID'; Edit = { param($e) $e.ztp.subscription_id = 'sub' }; Expect = 'ztp.subscription_id must be a GUID' }
        @{ Case = 'the admin secret has no vault'; Edit = { param($e) $e.ztp.admin_secret.Remove('vault') }; Expect = 'ztp.admin_secret.vault is required' }
        @{ Case = 'no share host is given'; Edit = { param($e) $e.ztp.Remove('share_host') }; Expect = 'ztp.share_host or ztp.share_host_adapter is required' }
        @{ Case = 'the BMC secret is missing'; Edit = { param($e) $e.ztp.Remove('bmc_secret') }; Expect = 'ztp.bmc_secret.vault is required' }
        @{ Case = 'the resource provider object ID is not a GUID'; Edit = { param($e) $e.ztp.azl_rp_object_id = 'x' }; Expect = 'ztp.azl_rp_object_id must be a GUID' }
        @{ Case = 'tags are a list'; Edit = { param($e) $e.ztp.tags = @('a') }; Expect = 'ztp.tags must be a mapping' }
        @{ Case = 'the location is missing'; Edit = { param($e) $e.Remove('azure_resources') }; Expect = 'azure_resources.location is required' }
        @{ Case = 'the static method is unknown'; Edit = { param($e) $e.network_intents.management['static_method'] = 'azure' }; Expect = "network_intents.management.static_method must be device or site, not 'azure'" }
        @{ Case = 'the provisioning DHCP range starts after its end'; Edit = { param($e) $e.network_intents.management['provisioning_dhcp_range'] = [ordered]@{ start = '192.0.2.250'; end = '192.0.2.100' } }; Expect = 'network_intents.management.provisioning_dhcp_range starts at 192.0.2.250, after its end 192.0.2.100' }
        @{ Case = 'the provisioning DHCP range is too big'; Edit = { param($e) $e.network_intents.management['provisioning_dhcp_range'] = [ordered]@{ start = '10.0.0.1'; end = '10.1.0.1' } }; Expect = 'has more than 4096 addresses' }
        @{ Case = 'the provisioning DHCP range has no end'; Edit = { param($e) $e.network_intents.management['provisioning_dhcp_range'] = [ordered]@{ start = '192.0.2.100' } }; Expect = 'network_intents.management.provisioning_dhcp_range.end is required' }
        @{ Case = 'a provisioning-only BIOS value is not a string'; Edit = { param($e) $e.hardware['bios_during_provisioning'] = [ordered]@{ Slot2 = $false } }; Expect = "hardware.bios_during_provisioning.Slot2 must be a string" }
        @{ Case = 'a node''s provisioning-only BIOS is a list'; Edit = { param($e) $e.cluster_nodes[0]['bios_during_provisioning'] = @('Slot2') }; Expect = 'cluster_nodes[0] (node-01).bios_during_provisioning must be a mapping' }
        @{ Case = 'the management IP assignment is unknown'; Edit = { param($e) $e.network_intents.management.ip_assignment = 'auto' }; Expect = "ip_assignment must be static, dhcp_reservation, dhcp or preconfigured, not 'auto'" }
        @{ Case = 'the management VLAN is out of range'; Edit = { param($e) $e.network_intents.management.vlan_id = 5000 }; Expect = "vlan_id must be 0-4094, not '5000'" }
        @{ Case = 'an Arc machine name has a space'; Edit = { param($e) $e.cluster_nodes[0].arc_machine_name = 'node 01' }; Expect = "arc_machine_name 'node 01' isn't a valid Arc machine name" }
        @{ Case = 'an Arc machine name ends in a dot'; Edit = { param($e) $e.cluster_nodes[0].arc_machine_name = 'node-01.' }; Expect = "arc_machine_name 'node-01.' isn't a valid Arc machine name" }
        @{ Case = 'the media path is relative'; Edit = { param($e) $e.ztp.media_path = '_media' }; Expect = "ztp.media_path must be a full path such as D:\Data\azl-ztp\site\media, not '_media'" }
        @{ Case = 'the evidence path is a list'; Edit = { param($e) $e.ztp.evidence_path = @('a') }; Expect = 'ztp.evidence_path must be a single value' }
        @{ Case = 'the site range starts after its end'; Edit = { param($e) $e.network_intents.management['site_ip_range'] = [ordered]@{ start = '192.0.2.20'; end = '192.0.2.10' } }; Expect = 'network_intents.management.site_ip_range starts at 192.0.2.20, after its end 192.0.2.10' }
        @{ Case = 'the site range leaves the subnet'; Edit = { param($e) $e.network_intents.management['site_ip_range'] = [ordered]@{ start = '192.0.2.10'; end = '192.0.3.10' } }; Expect = "network_intents.management.site_ip_range 192.0.2.10-192.0.3.10 isn't inside network_intents.management.subnet 192.0.2.0/24" }
        @{ Case = 'the site range has no end'; Edit = { param($e) $e.network_intents.management['site_ip_range'] = [ordered]@{ start = '192.0.2.10' } }; Expect = 'network_intents.management.site_ip_range.end is required' }
        @{ Case = 'a static node address is outside the site range'; Edit = { param($e) $e.network_intents.management['static_method'] = 'site'; $e.network_intents.management['site_ip_range'] = [ordered]@{ start = '192.0.2.11'; end = '192.0.2.11' } }; Expect = 'cluster_nodes[1] (node-02).ip_address 192.0.2.12 is outside network_intents.management.site_ip_range 192.0.2.11-192.0.2.11' }
        @{ Case = 'a static node address is outside the subnet'; Edit = { param($e) $e.cluster_nodes[1].ip_address = '198.51.100.12' }; Expect = "cluster_nodes[1] (node-02).ip_address 198.51.100.12 isn't in network_intents.management.subnet 192.0.2.0/24" }
        @{ Case = 'the provisioning network is unknown'; Edit = { param($e) $e.network_intents.management['provisioning_network'] = 'wifi' }; Expect = "provisioning_network must be dhcp or static, not 'wifi'" }
        @{ Case = 'a BIOS value is not a string'; Edit = { param($e) $e.hardware['bios'] = [ordered]@{ Slot2 = $true } }; Expect = "hardware.bios.Slot2 must be a string; quote it ('True')" }
        @{ Case = 'hardware.bios is a list'; Edit = { param($e) $e.hardware['bios'] = @('Slot2=Disabled') }; Expect = 'hardware.bios must be a mapping of BIOS attribute names to values' }
        @{ Case = 'a node''s BIOS attribute name has a space'; Edit = { param($e) $e.cluster_nodes[1]['bios'] = [ordered]@{ 'Slot 2' = 'Disabled' } }; Expect = "cluster_nodes[1] (node-02).bios has 'Slot 2', which isn't a BIOS attribute name" }
    ) {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        & $Edit $e
        $problems = @(Test-ZtpEnvironment -Environment $e)
        # Contains, not -BeLike: the node labels hold [ ].
        ($problems -join "`n").Contains($Expect) | Should -BeTrue -Because "the problems were: $($problems -join '; ')"
    }
    It 'accepts a share host adapter instead of a share host, and leaves tags and the resource provider ID optional' {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        $e.ztp.Remove('share_host'); $e.ztp.share_host_adapter = 'Ethernet 2'
        $e.ztp.Remove('tags'); $e.ztp.Remove('azl_rp_object_id')
        @(Test-ZtpEnvironment -Environment $e).Count | Should -Be 0
    }
    It 'accepts a file without the SBE, and ignores one that carries it with a one-line note' {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        $e.ztp.node_preparation['allow_unvalidated_sbe'] = 'not a boolean'
        @(Test-ZtpEnvironment -Environment $e).Count | Should -Be 0
        @(Get-ZtpEnvironmentNote -Environment $e) | Should -Be @('ztp.node_preparation ignored: SBE belongs to OS configuration.')
        $info = $null
        Assert-ZtpEnvironment -Environment $e -InformationVariable info -InformationAction SilentlyContinue
        @($info | ForEach-Object { [string]$_.MessageData }) | Should -Contain 'Note: ztp.node_preparation ignored: SBE belongs to OS configuration.'
        $e.ztp.Remove('node_preparation')
        @(Test-ZtpEnvironment -Environment $e).Count | Should -Be 0
        @(Get-ZtpEnvironmentNote -Environment $e).Count | Should -Be 0
    }
    It 'needs none of the OS configuration settings: the deployment admin, NTP, the other ports or the hardware model' {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        $e.Remove('credentials'); $e.Remove('onprem'); $e.hardware.Remove('model'); $e.ztp.Remove('node_preparation')
        @(Test-ZtpEnvironment -Environment $e).Count | Should -Be 0
        # A file can still carry them, with any value: ZTP doesn't read them.
        $e['credentials'] = [ordered]@{ local_admin_username = 'Administrator'; local_admin_password_secret = 'plaintext' }
        $e.cluster_nodes[0]['network_adapters'] = 'not a list'
        @(Test-ZtpEnvironment -Environment $e).Count | Should -Be 0
    }
    It 'accepts static_method device or site and the provisioning DHCP range, and leaves both optional' {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        Get-ZtpStaticMethod -Environment $e | Should -Be 'device'
        foreach ($m in 'device', 'site', 'SITE') {
            $e.network_intents.management['static_method'] = $m
            Get-ZtpStaticMethod -Environment $e | Should -Be $m.ToLowerInvariant()
            @(Test-ZtpEnvironment -Environment $e).Count | Should -Be 0 -Because "$m is valid"
        }
        $e.network_intents.management['provisioning_dhcp_range'] = [ordered]@{ start = '192.0.2.100'; end = '192.0.2.250' }
        @(Test-ZtpEnvironment -Environment $e).Count | Should -Be 0
    }
    It 'merges the provisioning-only BIOS values over the final ones for Boot, and keeps them apart' {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        $e.hardware['bios'] = [ordered]@{ Slot2 = 'Enabled'; EmbNic1Nic2 = 'Enabled' }
        $e.hardware['bios_during_provisioning'] = [ordered]@{ Slot2 = 'Disabled' }
        $e.cluster_nodes[1]['bios_during_provisioning'] = [ordered]@{ Slot3 = 'Disabled' }
        @(Test-ZtpEnvironment -Environment $e).Count | Should -Be 0
        $n2 = $e.cluster_nodes[1]
        $boot = Get-ZtpEnvironmentBios -Environment $e -Node $n2 -Kind boot
        @($boot.Keys | ForEach-Object { "$_=$($boot[$_])" }) | Should -Be @('Slot2=Disabled', 'EmbNic1Nic2=Enabled', 'Slot3=Disabled')
        $final = Get-ZtpEnvironmentBios -Environment $e -Node $n2
        @($final.Keys | ForEach-Object { "$_=$($final[$_])" }) | Should -Be @('Slot2=Enabled', 'EmbNic1Nic2=Enabled')
        $during = Get-ZtpEnvironmentBios -Environment $e -Node $n2 -Kind provisioning
        @($during.Keys | ForEach-Object { "$_=$($during[$_])" }) | Should -Be @('Slot2=Disabled', 'Slot3=Disabled')
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
            @(Test-ZtpEnvironment -Environment $e).Count | Should -Be 0 -Because "$m is a valid mode"
        }
    }
    It 'accepts an Arc machine name, an adapter name and a VLAN, and leaves them optional' {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        $e.cluster_nodes[0].arc_machine_name = 'node-01'; $e.cluster_nodes[0].adapter_name = 'SLOT 3 Port 1'; $e.network_intents.management.vlan_id = 711
        @(Test-ZtpEnvironment -Environment $e).Count | Should -Be 0
    }
    It 'sets the site network to Automatic for static addresses by default: the Device stage sets them, by MAC' {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        $site = Get-ZtpSiteNetwork -Environment $e
        $site.IpAssignmentType | Should -Be 'Automatic'
        @($site.Ipv4.Keys).Count | Should -Be 0
        $site.Range | Should -Be ''
    }
    It 'sets the site network to Manual for static addresses with static_method site, over the nodes'' range by default' {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        $e.network_intents.management['static_method'] = 'site'
        # Out of order in the file: the range still runs from the lowest to the highest.
        $e.cluster_nodes[0].ip_address = '192.0.2.40'; $e.network_intents.management['vlan_id'] = 711
        $site = Get-ZtpSiteNetwork -Environment $e
        $site.IpAssignmentType | Should -Be 'Manual'
        $site.Ipv4.addressRange.startIp | Should -Be '192.0.2.12'
        $site.Ipv4.addressRange.endIp | Should -Be '192.0.2.40'
        $site.Ipv4.defaultGateway | Should -Be '192.0.2.1'
        $site.Ipv4.subnetMask | Should -Be '255.255.255.0'
        @($site.Ipv4.dnsServers) | Should -Be @('192.0.2.53', '192.0.2.54')
        $site.Ipv4.vLanId | Should -Be 711
        $site.Ipv4.vLanId | Should -BeOfType [int]
    }
    It 'uses site_ip_range when the file gives it, and VLAN 0 when it gives none' {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        $e.network_intents.management['static_method'] = 'site'
        $e.network_intents.management['site_ip_range'] = [ordered]@{ start = '192.0.2.10'; end = '192.0.2.19' }
        $site = Get-ZtpSiteNetwork -Environment $e
        $site.Range | Should -Be '192.0.2.10-192.0.2.19'
        $site.Ipv4.vLanId | Should -Be 0
        @(Test-ZtpEnvironment -Environment $e).Count | Should -Be 0
    }
    It 'sets the site network to Automatic, with no ipv4, for <_>' -ForEach @('dhcp', 'preconfigured') {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        $e.network_intents.management['ip_assignment'] = $_
        $site = Get-ZtpSiteNetwork -Environment $e
        $site.IpAssignmentType | Should -Be 'Automatic'
        @($site.Ipv4.Keys).Count | Should -Be 0
        # With DHCP the range isn't checked: the addresses come from the DHCP server.
        $e.network_intents.management['site_ip_range'] = [ordered]@{ start = '192.0.2.11'; end = '192.0.2.11' }
        @(Test-ZtpEnvironment -Environment $e).Count | Should -Be 0
    }
    It 'accepts provisioning_network dhcp quietly and warns about static, which ZTP cannot set' {
        $e = Read-ZtpEnvironmentFile -Path $script:fixture
        $e.network_intents.management['provisioning_network'] = 'dhcp'
        @(Get-ZtpEnvironmentWarning -Environment $e).Count | Should -Be 0
        $e.network_intents.management['provisioning_network'] = 'static'
        @(Test-ZtpEnvironment -Environment $e).Count | Should -Be 0
        (Get-ZtpEnvironmentWarning -Environment $e) | Should -BeLike '*provisioning_network is static*Configurator app*open research item*'
        $warnings = $null
        Assert-ZtpEnvironment -Environment $e -WarningVariable warnings -WarningAction SilentlyContinue
        @($warnings).Count | Should -Be 1
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

Describe 'Invoke-ZtpEnvironment.ps1 plan' {
    BeforeAll {
        $script:envRoot = New-TestRepo -Name 'env-repo' -Copy 'Invoke-ZtpEnvironment.ps1', 'ZtpEnvironment.Common.ps1'
        $script:envScript = Join-Path $script:envRoot 'scripts/simplified-provisioning/Invoke-ZtpEnvironment.ps1'
        $bin = Join-Path $script:envRoot 'scripts/simplified-provisioning'
        $params = '$ConfigPath, $NodeName, $BmcCredential, $EdgeUserPassword, $InfrastructureFile, $Node, $DriverStagingPath, $EventLogPath, $From, [switch]$ConfirmNotClustered, [switch]$SkipCertificateCheck, [switch]$RetryProvisionOs, [switch]$RebuildImages, [switch]$Execute'
        foreach ($stub in 'Invoke-ZtpProvisioning.ps1') {
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

    It 'writes the ZTP inputs from the file, keeps its state under -MediaPath, and runs the stages as a plan' {
        $infra = New-TestEnvironment -Name 'env-plan'
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
        foreach ($k in 'SbeModel', 'SbeSolutionVersion', 'SbePackagePath') { $cfg.PSObject.Properties.Name | Should -Not -Contain $k -Because 'ZTP selects no SBE' }
        $cfg.ResourceGroupName | Should -Be 'rg-example'
        $cfg.StatePath | Should -Be (Join-Path $script:media 'ztp-state/node-01+node-02.ztp-provisioning.state.json')
        $cfg.VoucherDirectory | Should -Be (Join-Path $script:media 'vouchers')
        $cfg.NetworkTimeoutMinutes | Should -Be 60 -Because 'the Network stage waits for each adapter job'
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
        # static_method device (the default): the Device stage sets the static by MAC; the site is Automatic and the claim
        # carries no Manual adapter (the template sends one only for site).
        $n1.management.static_method | Should -Be 'device'
        $bicep.parameters.ip_assignment_type.value | Should -Be 'Automatic'
        @($bicep.parameters.ipv4.value.PSObject.Properties).Count | Should -Be 0

        $global:ztpE_runs.Script | Should -Be @('Invoke-ZtpProvisioning.ps1') -Because 'ZTP ends after Handoff; Prepare is OS configuration'
        $global:ztpE_runs[0].Params['NodeName'] | Should -Be @('node-01', 'node-02')
        $global:ztpE_runs[0].Params.ContainsKey('Execute') | Should -BeFalse
        $cfg.EventLogPath | Should -Be ([IO.Path]::GetFullPath((Join-Path $TestDrive 'data-env-plan/evidence/ztp-events.jsonl')))
        # Plan mode creates nothing in Azure and reads no secret.
        ($global:ztpE_calls -join "`n") | Should -Not -BeLike '*New-AzResourceGroup*'
        ($global:ztpE_calls -join "`n") | Should -Not -BeLike '*Get-AzKeyVaultSecret*'
    }

    It 'keeps run data in ztp.media_path and ztp.evidence_path when -MediaPath and -EvidencePath are not given, and creates them' {
        $infra = New-TestEnvironment -Name 'env-file-paths'
        $null = & $script:envScript -InfrastructureFile $infra *>&1
        $cfg = Get-Content -LiteralPath (Join-Path $script:envRoot 'config/simplified-provisioning/ztp-provisioning.json') -Raw | ConvertFrom-Json
        $media = [IO.Path]::GetFullPath((Join-Path $TestDrive 'data-env-file-paths/media'))
        $evidence = [IO.Path]::GetFullPath((Join-Path $TestDrive 'data-env-file-paths/evidence'))
        $cfg.BootstrapCacheDirectory | Should -Be $media
        $cfg.StatePath | Should -BeLike "$media*ztp-state*"
        $cfg.EventLogPath | Should -Be (Join-Path $evidence 'ztp-events.jsonl')
        Test-Path -LiteralPath $evidence -PathType Container | Should -BeTrue
        Test-Path (Join-Path $script:envRoot '_media') | Should -BeFalse
        # The parameters win over the file.
        $null = & $script:envScript -InfrastructureFile $infra -MediaPath (Join-Path $TestDrive 'param-media') -EvidencePath (Join-Path $TestDrive 'param-evidence') *>&1
        $cfg = Get-Content -LiteralPath (Join-Path $script:envRoot 'config/simplified-provisioning/ztp-provisioning.json') -Raw | ConvertFrom-Json
        $cfg.BootstrapCacheDirectory | Should -Be ([IO.Path]::GetFullPath((Join-Path $TestDrive 'param-media')))
        $cfg.EventLogPath | Should -Be ([IO.Path]::GetFullPath((Join-Path $TestDrive 'param-evidence/ztp-events.jsonl')))
    }

    It 'without the keys or the parameters, uses the site folder under ProgramData\AzureLocalZtp' {
        $infra = New-TestEnvironment -Name 'env-default-paths' -Edit { param($e) $e.ztp.Remove('media_path'); $e.ztp.Remove('evidence_path') }
        $saved = $env:ProgramData
        $env:ProgramData = Join-Path $TestDrive 'programdata'
        try { $null = & $script:envScript -InfrastructureFile $infra *>&1 }
        finally { $env:ProgramData = $saved }
        $cfg = Get-Content -LiteralPath (Join-Path $script:envRoot 'config/simplified-provisioning/ztp-provisioning.json') -Raw | ConvertFrom-Json
        $cfg.BootstrapCacheDirectory | Should -Be ([IO.Path]::GetFullPath((Join-Path $TestDrive 'programdata/AzureLocalZtp/example-site/media')))
        $cfg.EventLogPath | Should -Be ([IO.Path]::GetFullPath((Join-Path $TestDrive 'programdata/AzureLocalZtp/example-site/evidence/ztp-events.jsonl')))
    }

    It 'refuses a media or evidence folder inside a git working tree, from the file or from the parameters' {
        $repo = Join-Path $TestDrive 'a-clone'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $repo '.git')
        $inFile = New-TestEnvironment -Name 'env-in-repo' -Edit { param($e) $e.ztp.media_path = Join-Path $repo '_media' }
        { & $script:envScript -InfrastructureFile $inFile } | Should -Throw "*ztp.media_path*is inside the git working tree*a-clone*"
        $clean = New-TestEnvironment -Name 'env-param-in-repo'
        { & $script:envScript -InfrastructureFile $clean -MediaPath (Join-Path $repo 'media') } | Should -Throw '*media folder*(from -MediaPath) is inside the git working tree*'
        { & $script:envScript -InfrastructureFile $clean -EvidencePath (Join-Path $repo 'deep/evidence') } | Should -Throw '*evidence folder*(from -EvidencePath) is inside the git working tree*'
        Test-Path (Join-Path $repo 'media') | Should -BeFalse
    }

    It 'writes an Automatic site network with no address range when the management addresses are DHCP' {
        $infra = New-TestEnvironment -Name 'env-dhcp-site' -Edit { param($e) $e.network_intents.management['ip_assignment'] = 'dhcp' }
        $text = Get-StepText (& $script:envScript -InfrastructureFile $infra *>&1)
        $text | Should -BeLike '*Site network: Automatic. Maintenance environment to Azure: dhcp.*'
        $bicep = Get-Content -LiteralPath (Join-Path $script:envRoot 'scripts/simplified-provisioning/bicep/main.parameters.json') -Raw | ConvertFrom-Json
        $bicep.parameters.ip_assignment_type.value | Should -Be 'Automatic'
        @($bicep.parameters.ipv4.value.PSObject.Properties).Count | Should -Be 0
        $bicep.parameters.nodes.value[0].management.ip_assignment | Should -Be 'dhcp'
    }

    It 'writes each node''s BIOS settings to the node list: hardware.bios with the node''s own merged over it' {
        $infra = New-TestEnvironment -Name 'env-bios' -Edit {
            param($e)
            $e.hardware['bios'] = [ordered]@{ Slot2 = 'Disabled'; EmbNic1Nic2 = 'Enabled' }
            $e.cluster_nodes[1]['bios'] = [ordered]@{ Slot2 = 'Enabled'; SriovGlobalEnable = 'Enabled' }
        }
        $text = Get-StepText (& $script:envScript -InfrastructureFile $infra *>&1)
        $text | Should -BeLike '*BIOS set by the Boot stage before the maintenance boot: node-01 Slot2=Disabled, EmbNic1Nic2=Enabled; node-02 Slot2=Enabled, EmbNic1Nic2=Enabled, SriovGlobalEnable=Enabled.*'
        $nodes = Get-Content -LiteralPath (Join-Path $script:envRoot 'config/simplified-provisioning/nodes.json') -Raw | ConvertFrom-Json
        $nodes.nodes[0].bios.Slot2 | Should -Be 'Disabled'
        $nodes.nodes[1].bios.Slot2 | Should -Be 'Enabled'
        $nodes.nodes[1].bios.EmbNic1Nic2 | Should -Be 'Enabled'
        $nodes.nodes[1].bios.SriovGlobalEnable | Should -Be 'Enabled'
        # Without bios, the node list has no bios key.
        $plain = New-TestEnvironment -Name 'env-no-bios'
        $null = & $script:envScript -InfrastructureFile $plain *>&1
        $nodes = Get-Content -LiteralPath (Join-Path $script:envRoot 'config/simplified-provisioning/nodes.json') -Raw | ConvertFrom-Json
        $nodes.nodes[0].PSObject.Properties.Name | Should -Not -Contain 'bios'
    }

    It 'with -Execute writes the run transcript to the evidence folder' {
        $infra = New-TestEnvironment -Name 'env-transcript'
        $null = & $script:envScript -InfrastructureFile $infra -Node node-01 -Execute *>&1
        @(Get-ChildItem -LiteralPath (Join-Path $TestDrive 'data-env-transcript/evidence') -Filter 'node-01.*.transcript.log').Count | Should -Be 1
    }

    It 'covers the nodes named and keeps a separate state for that set' {
        $infra = New-TestEnvironment -Name 'env-one-node'
        $null = & $script:envScript -InfrastructureFile $infra -MediaPath $script:media -Node node-02 *>&1
        $cfg = Get-Content -LiteralPath (Join-Path $script:envRoot 'config/simplified-provisioning/ztp-provisioning.json') -Raw | ConvertFrom-Json
        $cfg.StatePath | Should -BeLike '*node-02.ztp-provisioning.state.json'
        $global:ztpE_runs[0].Params['NodeName'] | Should -Be @('node-02')
        { & $script:envScript -InfrastructureFile $infra -MediaPath $script:media -Node node-09 *>&1 } | Should -Throw "*Node node-09 isn't in the environment file*"
    }

    It 'fails on a bad environment file before it writes anything or signs in' {
        $infra = New-TestEnvironment -Name 'env-invalid' -Edit { param($e) $e.ztp.Remove('time_zone'); $e.cluster_nodes[0].idrac_ip = 'bmc.example.com' }
        Remove-Item -LiteralPath (Join-Path $script:envRoot 'config/simplified-provisioning/nodes.json') -ErrorAction SilentlyContinue
        { & $script:envScript -InfrastructureFile $infra -MediaPath $script:media } | Should -Throw '*is invalid (2 problems):*idrac_ip must be an IPv4 address*ztp.time_zone is required*'
        Test-Path (Join-Path $script:envRoot 'config/simplified-provisioning/nodes.json') | Should -BeFalse
        $global:ztpE_calls.Count | Should -Be 0
        { & $script:envScript -InfrastructureFile (Join-Path $TestDrive 'absent.yml') } | Should -Throw "*doesn't exist*"
    }

    It 'accepts a file whose SBE folder is missing, notes that it ignores it, and runs no Prepare' {
        $infra = New-TestEnvironment -Name 'env-no-sbe'
        $text = Get-StepText (& $script:envScript -InfrastructureFile $infra -MediaPath $script:media *>&1)
        $text | Should -BeLike '*Note: ztp.node_preparation ignored: SBE belongs to OS configuration.*'
        $global:ztpE_runs.Script | Should -Be @('Invoke-ZtpProvisioning.ps1')
    }

    It 'writes Manual site settings and the claim''s static_method site only when the file asks for it' {
        $infra = New-TestEnvironment -Name 'env-site-static' -Edit { param($e) $e.network_intents.management['static_method'] = 'site' }
        $text = Get-StepText (& $script:envScript -InfrastructureFile $infra -MediaPath $script:media *>&1)
        $text | Should -BeLike '*Site network: Manual 192.0.2.11-192.0.2.12*'
        $text | Should -BeLike '*Static management addresses set by: the OS install, from the site''s Manual setting*'
        $bicep = Get-Content -LiteralPath (Join-Path $script:envRoot 'scripts/simplified-provisioning/bicep/main.parameters.json') -Raw | ConvertFrom-Json
        $bicep.parameters.ip_assignment_type.value | Should -Be 'Manual'
        $bicep.parameters.ipv4.value.addressRange.startIp | Should -Be '192.0.2.11'
        $bicep.parameters.nodes.value[0].management.static_method | Should -Be 'site'
    }

    It 'gives the Device stage the scan range for a node without a maintenance address' {
        $infra = New-TestEnvironment -Name 'env-scan' -Edit { param($e) $e.network_intents.management['provisioning_dhcp_range'] = [ordered]@{ start = '192.0.2.100'; end = '192.0.2.250' }; $e.cluster_nodes[0]['maintenance_address'] = '192.0.2.111' }
        $text = Get-StepText (& $script:envScript -InfrastructureFile $infra -MediaPath $script:media *>&1)
        $nodes = Get-Content -LiteralPath (Join-Path $script:envRoot 'config/simplified-provisioning/nodes.json') -Raw | ConvertFrom-Json
        $nodes.nodes[0].maintenance_address | Should -Be '192.0.2.111'
        $nodes.nodes[0].PSObject.Properties.Name | Should -Not -Contain 'maintenance_scan_range'
        $nodes.nodes[1].maintenance_scan_range | Should -Be '192.0.2.100-192.0.2.250'
        $text | Should -BeLike '*no maintenance address for node-02; it scans 192.0.2.100-192.0.2.250 for TCP 20001 and finds each node by its management MAC*'
    }

    It 'writes the BIOS Boot applies (provisioning-only values over the final ones) and what Restore sets back' {
        $infra = New-TestEnvironment -Name 'env-bios-restore' -Edit {
            param($e)
            $e.hardware['bios'] = [ordered]@{ Slot2 = 'Enabled'; EmbNic1Nic2 = 'Enabled' }
            $e.hardware['bios_during_provisioning'] = [ordered]@{ Slot2 = 'Disabled'; Slot3 = 'Disabled' }
        }
        $text = Get-StepText (& $script:envScript -InfrastructureFile $infra -MediaPath $script:media *>&1)
        $nodes = Get-Content -LiteralPath (Join-Path $script:envRoot 'config/simplified-provisioning/nodes.json') -Raw | ConvertFrom-Json
        "$($nodes.nodes[0].bios.Slot2) $($nodes.nodes[0].bios.EmbNic1Nic2) $($nodes.nodes[0].bios.Slot3)" | Should -Be 'Disabled Enabled Disabled'
        $nodes.nodes[0].bios_restore.Slot2 | Should -Be 'Enabled' -Because 'hardware.bios gives the final value'
        $nodes.nodes[0].bios_restore.Slot3 | Should -Be '' -Because 'no final value: Restore uses the value saved before Boot'
        $nodes.nodes[0].bios_restore.PSObject.Properties.Name | Should -Not -Contain 'EmbNic1Nic2'
        $text | Should -BeLike '*BIOS set back by the Restore stage after Network: node-01 Slot2=Enabled, Slot3=<value before Boot>*'
    }

    It 'treats the external validator as optional and parameterized' {
        $infra = New-TestEnvironment -Name 'env-validator'
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
        $bad = New-TestEnvironment -Name 'env-bad-first' -Edit { param($e) $e.ztp.Remove('share_name') }
        { & $script:envScript -InfrastructureFile $bad -MediaPath $script:media -ValidatorPath $fail } | Should -Throw '*ztp.share_name is required*'
    }

    It 'finds the share host from the named adapter, and asks for the resource provider ID only when the file does not give it' {
        $infra = New-TestEnvironment -Name 'env-adapter' -Edit { param($e) $e.ztp.Remove('share_host'); $e.ztp.share_host_adapter = 'Ethernet 2'; $e.ztp.Remove('azl_rp_object_id') }
        $null = & $script:envScript -InfrastructureFile $infra -MediaPath $script:media *>&1
        $cfg = Get-Content -LiteralPath (Join-Path $script:envRoot 'config/simplified-provisioning/ztp-provisioning.json') -Raw | ConvertFrom-Json
        $cfg.ShareHost | Should -Be '192.0.2.77'
        $global:ztpE_calls | Should -Contain 'Get-AzADServicePrincipal'
    }

    It 'with -Execute creates the resource group and runs the stages for the nodes; nothing runs after Handoff' {
        $infra = New-TestEnvironment -Name 'env-execute'
        $null = & $script:envScript -InfrastructureFile $infra -MediaPath $script:media -Node node-01 -Execute *>&1
        $global:ztpE_calls | Should -Contain 'New-AzResourceGroup rg-example'
        $global:ztpE_calls | Should -Contain 'Get-AzKeyVaultSecret kv-example/bmc-username'
        $global:ztpE_runs.Script | Should -Be @('Invoke-ZtpProvisioning.ps1')
        $run = $global:ztpE_runs[0].Params
        $run['Execute'] | Should -BeTrue
        $run['RebuildImages'] | Should -BeTrue
        $run['RetryProvisionOs'] | Should -BeTrue
        $run['NodeName'] | Should -Be @('node-01')
        $run['BmcCredential'].UserName | Should -Be 'bmc-example'

        $global:ztpE_calls.Clear(); $global:ztpE_runs.Clear()
        $null = & $script:envScript -InfrastructureFile $infra -MediaPath $script:media -From Azure -Execute *>&1
        $global:ztpE_runs[0].Params['From'] | Should -Be 'Azure'
        $global:ztpE_runs[0].Params.ContainsKey('RebuildImages') | Should -BeFalse
        $global:ztpE_runs[0].Params.ContainsKey('EdgeUserPassword') | Should -BeFalse -Because 'without ztp.maintenance_password_secret the image keeps its default'
    }

    It 'reads the edgeuser password from Key Vault for the images and the Device stage, and lists each maintenance address' {
        $infra = New-TestEnvironment -Name 'env-device' -Edit {
            param($e) $e.ztp['maintenance_password_secret'] = 'keyvault://kv-example/edgeuser-password'; $e.cluster_nodes[0]['maintenance_address'] = '192.0.2.111'
        }
        $text = Get-StepText (& $script:envScript -InfrastructureFile $infra -MediaPath $script:media -Execute *>&1)
        $global:ztpE_calls | Should -Contain 'Get-AzKeyVaultSecret kv-example/edgeuser-password'
        $global:ztpE_runs[0].Params['EdgeUserPassword'] | Should -BeOfType [securestring]
        $nodes = Get-Content -LiteralPath (Join-Path $script:envRoot 'config/simplified-provisioning/nodes.json') -Raw | ConvertFrom-Json
        $nodes.nodes[0].maintenance_address | Should -Be '192.0.2.111'
        $nodes.nodes[1].PSObject.Properties['maintenance_address'] | Should -BeNullOrEmpty
        $text | Should -BeLike '*Device stage (static address in the maintenance environment): no maintenance address for node-02; it scans the management subnet 192.0.2.0/24*'
        $cfg = Get-Content -LiteralPath (Join-Path $script:envRoot 'config/simplified-provisioning/ztp-provisioning.json') -Raw | ConvertFrom-Json
        $cfg.DeviceTimeoutMinutes | Should -Be 30
        $bad = New-TestEnvironment -Name 'env-device-bad' -Edit { param($e) $e.ztp['maintenance_password_secret'] = 'Password1'; $e.cluster_nodes[0]['maintenance_address'] = 'console' }
        $problems = @(Test-ZtpEnvironment -Environment (Read-ZtpEnvironmentFile -Path $bad))
        $problems | Should -Contain 'ztp.maintenance_password_secret must be keyvault://<vault>/<secret>.'
        $problems | Should -Contain "cluster_nodes[0] (node-01).maintenance_address must be an IPv4 address, not 'console'."
    }
}

Describe 'Schema 5 infrastructure.yml' {
    BeforeAll {
        # Built-in checks only, unless a test names a toolkit: the scripts would otherwise look for a clone next to the repo.
        $script:savedToolkitRoot = $env:AZL_TOOLKIT_ROOT
        $env:AZL_TOOLKIT_ROOT = Join-Path $TestDrive 'no-toolkit-here'
        $script:read = { param([string]$Path) Read-ZtpInfrastructure -Path $Path }
        $script:assertText = {
            param([string]$Path)
            try { Assert-ZtpEnvironment -Environment (Read-ZtpInfrastructure -Path $Path) -Source 'infra.yml' -InformationAction SilentlyContinue; '' } catch { $_.Exception.Message }
        }
    }
    AfterAll { $env:AZL_TOOLKIT_ROOT = $script:savedToolkitRoot }

    It 'tells the formats apart: _metadata.schema_version is schema 5, the environment-file layout is legacy' {
        Get-ZtpEnvironmentFormat -Data (Read-ZtpEnvironmentFile -Path $script:fixtureV5) | Should -Be 'schema5'
        Get-ZtpEnvironmentFormat -Data (Read-ZtpEnvironmentFile -Path $script:fixture) | Should -Be 'legacy'
        Get-ZtpEnvironmentFormat -Data ([ordered]@{ schema_version = '5.2.0' }) | Should -Be 'schema5'
        # A legacy file comes back exactly as read.
        (& $script:read $script:fixture).Contains('_source') | Should -BeFalse
    }

    It 'maps the schema 5 file onto the keys the scripts read, with no problems' {
        $e = & $script:read (New-TestInfrastructureV5 -Name 'v5-map')
        @(Test-ZtpEnvironment -Environment $e).Count | Should -Be 0
        $e._source.format | Should -Be 'schema5'; $e._source.validator | Should -Be 'built-in'
        $n = $e.cluster_nodes[0]
        "$($n.name) $($n.ip_address) $($n.mac_address) $($n.adapter_name) $($n.ip_assignment) $($n.service_tag) $($n.idrac_ip)" | Should -Be 'node-01 192.0.2.11 02:00:00:00:00:11 Embedded NIC 1 static EXAMPLE1 198.51.100.11'
        @($n['network_adapters'] | ForEach-Object { $_['name'] }).Count | Should -BeGreaterThan 1 -Because 'the ports go to the node list for the handoff (ZTP still leaves them to OS configuration)'
        @($n['network_adapters'] | Where-Object { 'management' -in $_['roles'] -and $_['ip_assignment'] -ne 'none' }).Count | Should -Be 1
        $m = $e.network_intents.management
        "$($m.subnet) $($m.gateway) $(@($m.dns_servers) -join ',') $($m.ip_assignment) $($m.vlan_id) $($m.provisioning_network)" | Should -Be '192.0.2.0/24 192.0.2.1 192.0.2.53,192.0.2.54 static 0 dhcp'
        $e.azure_identity.azure_tenant_id | Should -Be '00000000-0000-0000-0000-000000000000'
        $e.azure_resources.location | Should -Be 'eastus'
        $e.site.name | Should -Be 'Example Site'
        foreach ($k in 'credentials', 'onprem') { $e.Contains($k) | Should -BeFalse -Because "$k is OS configuration" }
        $e.ztp.Contains('node_preparation') | Should -BeFalse -Because 'hardware.sbe belongs to OS configuration and deployment'
        $z = $e.ztp
        "$($z.subscription_id) $($z.resource_group) $($z.site_name) $($z.time_zone) $($z.provisioning_iso) $($z.os_version) $($z.share_name) $($z.share_host) $($z.azl_rp_object_id)" | Should -Be '00000000-0000-0000-0000-000000000000 rg-example example-site UTC latest latest ztp-example 192.0.2.10 00000000-0000-0000-0000-000000000001'
        "$($z.admin_secret.username) $($z.admin_secret.vault) $($z.admin_secret.name) $($z.admin_secret.subscription_id) $($z.admin_secret.resource_group)" | Should -Be 'ztpadmin kv-example ztp-admin-password 00000000-0000-0000-0000-000000000000 rg-example-vault'
        "$($z.bmc_secret.vault) $($z.bmc_secret.username_name) $($z.bmc_secret.password_name)" | Should -Be 'kv-example bmc-username bmc-password'
        $z.tags.purpose | Should -Be 'example'
        $z.media_path | Should -BeLike '*data-v5-map*media'
        (Get-ZtpSiteNetwork -Environment $e).IpAssignmentType | Should -Be 'Automatic' -Because 'static_method device is the default'
    }

    It 'maps <Case>' -ForEach @(
        @{ Case = 'a DHCP reservation to ZTP''s dhcp_reservation (Mode A), and the site network to Automatic'; Edit = { param($d) foreach ($n in $d.nodes) { $n.network_adapters[0].ip_assignment = 'dhcp_reservation' } }; Check = { param($e) $e.cluster_nodes[0].ip_assignment | Should -Be 'dhcp_reservation'; $e.network_intents.management.ip_assignment | Should -Be 'dhcp_reservation'; (Get-ZtpSiteNetwork -Environment $e).IpAssignmentType | Should -Be 'Automatic' } }
        @{ Case = 'Mode C: a management port without role provisioning takes no DHCP while provisioned'; Edit = { param($d) }; Check = { param($e) Get-ZtpManagementDhcp -Environment $e -Node $e.cluster_nodes[0] | Should -BeFalse; @($e.cluster_nodes[0].network_adapters).Count | Should -Be 6 } }
        @{ Case = 'Mode B: a management port that also carries role provisioning takes DHCP'; Edit = { param($d) foreach ($n in $d.nodes) { $n.network_adapters[0].roles = @('management', 'provisioning') } }; Check = { param($e) Get-ZtpManagementDhcp -Environment $e -Node $e.cluster_nodes[0] | Should -BeTrue } }
        @{ Case = 'Mode C with provisioning_network static and a DHCP provisioning port: no problem and no warning'; Edit = { param($d) $d.networking.management['provisioning_network'] = 'static'; foreach ($n in $d.nodes) { $n.network_adapters[2].ip_assignment = 'dhcp' } }; Check = { param($e) @(Test-ZtpEnvironment -Environment $e).Count | Should -Be 0; @(Get-ZtpEnvironmentWarning -Environment $e).Count | Should -Be 0; Get-ZtpManagementDhcp -Environment $e -Node $e.cluster_nodes[0] | Should -BeFalse } }
        @{ Case = 'Mode A without ip_address: allowed, nothing to compare'; Edit = { param($d) foreach ($n in $d.nodes) { $n.network_adapters[0].ip_assignment = 'dhcp_reservation'; $n.network_adapters[0].Remove('ip_address') } }; Check = { param($e) @(Test-ZtpEnvironment -Environment $e).Count | Should -Be 0; $e.cluster_nodes[0].ip_assignment | Should -Be 'dhcp_reservation' } }
        @{ Case = 'mixed modes per node, the site network Manual over the static node only'; Edit = { param($d) $d.networking.management['static_method'] = 'site'; $d.nodes[1].network_adapters[0].ip_assignment = 'dhcp_reservation' }; Check = { param($e) $e.cluster_nodes[1].ip_assignment | Should -Be 'dhcp_reservation'; (Get-ZtpSiteNetwork -Environment $e).Range | Should -Be '192.0.2.11-192.0.2.11' } }
        @{ Case = 'a tagged management port to its VLAN'; Edit = { param($d) $d.networking.management.Remove('vlan_id'); foreach ($n in $d.nodes) { $n.network_adapters[0].vlan_mode = 'tagged' } }; Check = { param($e) $e.network_intents.management.vlan_id | Should -Be 711 } }
        @{ Case = 'a 5.0 node with management only'; Edit = { param($d) foreach ($n in $d.nodes) { $mac = $n.network_adapters[0].mac_address; $ip = $n.network_adapters[0].ip_address; $n.Remove('network_adapters'); $n['management'] = [ordered]@{ ip_address = $ip; mac_address = $mac; adapter_name = 'Port1' } } }; Check = { param($e) $e.cluster_nodes[0].adapter_name | Should -Be 'Port1'; $e.cluster_nodes[0].Contains('network_adapters') | Should -BeFalse; $e.cluster_nodes[0].ip_assignment | Should -Be 'static' } }
        @{ Case = 'a BMC user name that is not a secret, and BIOS settings'; Edit = { param($d) $d.hardware.bmc.username = 'root'; $d.hardware['bios'] = [ordered]@{ Slot2 = 'Disabled' }; $d.nodes[1]['bios'] = [ordered]@{ Slot2 = 'Enabled' } }; Check = { param($e) $e.ztp.bmc_secret.username | Should -Be 'root'; $e.ztp.bmc_secret.Contains('username_name') | Should -BeFalse; (Get-ZtpEnvironmentBios -Environment $e -Node $e.cluster_nodes[1])['Slot2'] | Should -Be 'Enabled'; (Get-ZtpEnvironmentBios -Environment $e -Node $e.cluster_nodes[0])['Slot2'] | Should -Be 'Disabled' } }
        @{ Case = 'the BMC user name secret in its own vault'; Edit = { param($d) $d.key_vaults.Add([ordered]@{ name = 'kv-example-bmc'; subscription_id = '00000000-0000-0000-0000-000000000000'; resource_group = 'rg-example-vault' }); $d.hardware.bmc.username = 'keyvault://kv-example-bmc/bmc-user' }; Check = { param($e) $e.ztp.bmc_secret.username_vault | Should -Be 'kv-example-bmc'; $e.ztp.bmc_secret.username_name | Should -Be 'bmc-user'; @(Test-ZtpEnvironment -Environment $e).Count | Should -Be 0 } }
        @{ Case = 'the maintenance address from the provisioning port, and the edgeuser password secret'; Edit = { param($d) $d.nodes[0].network_adapters.Add([ordered]@{ name = 'Port 3'; mac_address = '02:00:00:00:00:33'; roles = @('provisioning'); ip_assignment = 'dhcp_reservation'; ip_address = '192.0.2.111' }); $d.provisioning.simplified['maintenance_password'] = 'keyvault://kv-example/edgeuser-password' }; Check = { param($e) $e.cluster_nodes[0].maintenance_address | Should -Be '192.0.2.111'; $e.cluster_nodes[1].Contains('maintenance_address') | Should -BeFalse; $e.ztp.maintenance_password_secret | Should -Be 'keyvault://kv-example/edgeuser-password'; @(Test-ZtpEnvironment -Environment $e).Count | Should -Be 0 } }
        @{ Case = 'the site range, the run folders and a provisioning subscription'; Edit = { param($d) $d.networking.management['static_method'] = 'site'; $d.networking.management['site_ip_range'] = [ordered]@{ start = '192.0.2.10'; end = '192.0.2.19' }; $d.provisioning.simplified['subscription_id'] = '00000000-0000-0000-0000-000000000002'; $d.provisioning.simplified['resource_group'] = 'rg-example-ztp' }; Check = { param($e) (Get-ZtpSiteNetwork -Environment $e).Range | Should -Be '192.0.2.10-192.0.2.19'; $e.ztp.subscription_id | Should -Be '00000000-0000-0000-0000-000000000002'; $e.ztp.resource_group | Should -Be 'rg-example-ztp' } }
    ) {
        $e = & $script:read (New-TestInfrastructureV5 -Name "v5-case-$([guid]::NewGuid().ToString('N'))" -Edit $Edit)
        & $Check $e
    }

    It 'reports what ZTP needs in schema 5 paths: <Case>' -ForEach @(
        @{ Case = 'a missing time zone'; Edit = { param($d) $d.site.Remove('time_zone') }; Expect = 'site.time_zone is required' }
        @{ Case = 'a missing serial number'; Edit = { param($d) $d.nodes[1].Remove('serial_number') }; Expect = 'nodes[1] (node-02).serial_number is required' }
        @{ Case = 'no management port'; Edit = { param($d) $d.nodes[0].network_adapters[0].ip_assignment = 'none' }; Expect = 'nodes[0] (node-01): 0 ports own the management address' }
        @{ Case = 'a management port without its MAC'; Edit = { param($d) $d.nodes[0].network_adapters[0].Remove('mac_address') }; Expect = 'nodes[0] (node-01) management port mac_address is required' }
        @{ Case = 'an ISO install'; Edit = { param($d) $d.scenario.os_install = 'iso' }; Expect = "scenario.os_install is 'iso'; ZTP provisions with simplified machine provisioning" }
        @{ Case = 'Mode C with no DHCP anywhere (G23)'; Edit = { param($d) $d.networking.management['provisioning_network'] = 'static' }; Expect = "nodes[0] (node-01): Mode C (Static without management DHCP): the maintenance environment can't reach Azure: no DHCP anywhere (G23); give a provisioning port with DHCP" }
        @{ Case = 'another schema major'; Edit = { param($d) $d._metadata.schema_version = '4.0.0' }; Expect = "_metadata.schema_version is '4.0.0'; ZTP reads schema 5.x" }
        @{ Case = 'an unlisted admin vault'; Edit = { param($d) $d.provisioning.simplified.admin.password = 'keyvault://kv-other/ztp-admin-password' }; Expect = "names vault 'kv-other', which isn't in key_vaults" }
        @{ Case = 'a node with its own BMC login'; Edit = { param($d) $d.nodes[1].bmc['username'] = 'other'; $d.nodes[1].bmc['password'] = 'keyvault://kv-example/other-bmc' }; Expect = 'nodes[1] (node-02).bmc has its own login; ZTP uses one BMC login' }
        @{ Case = 'secrets in another subscription'; Edit = { param($d) $d.key_vaults.Add([ordered]@{ name = 'kv-example-two'; subscription_id = '00000000-0000-0000-0000-000000000003'; resource_group = 'rg-x' }); $d.provisioning.simplified['maintenance_password'] = 'keyvault://kv-example-two/edgeuser-password' }; Expect = 'provisioning.simplified.maintenance_password is in vault ''kv-example-two'', in another subscription' }
        @{ Case = 'an unknown static method'; Edit = { param($d) $d.networking.management['static_method'] = 'azure' }; Expect = "networking.management.static_method must be device or site, not 'azure'" }
        @{ Case = 'a provisioning DHCP range backwards'; Edit = { param($d) $d.networking.management['provisioning_dhcp_range'] = [ordered]@{ start = '192.0.2.250'; end = '192.0.2.100' } }; Expect = 'networking.management.provisioning_dhcp_range starts at 192.0.2.250' }
        @{ Case = 'a node''s maintenance address that is no address'; Edit = { param($d) $d.nodes[0]['maintenance_address'] = 'console' }; Expect = "nodes[0] (node-01) provisioning port ip_address must be an IPv4 address, not 'console'" }
        @{ Case = 'a BIOS value that is not a string'; Edit = { param($d) $d.hardware['bios'] = [ordered]@{ Slot2 = 0 } }; Expect = 'hardware.bios.Slot2 must be a string' }
    ) {
        $text = & $script:assertText (New-TestInfrastructureV5 -Name "v5-bad-$([guid]::NewGuid().ToString('N'))" -Edit $Edit)
        $text.Contains($Expect) | Should -BeTrue -Because "the message was: $text"
        $text | Should -BeLike 'infra.yml (schema *, checked by built-in) is invalid*'
    }

    It 'validates with the toolkit''s module when one is found, and reports its findings with their rule IDs' {
        $tk = Join-Path $TestDrive 'stub-toolkit'
        $mod = Join-Path $tk 'scripts/common/infrastructure'
        $null = New-Item -ItemType Directory -Force -Path $mod
        Set-Content -LiteralPath (Join-Path $mod 'AzlInfrastructure.psm1') -Value @'
function Test-AzlInfrastructure { param([string]$Path)
    [pscustomobject]@{ Id = 'AZL-099'; Severity = 'error'; Path = 'nodes'; Message = 'stub error'; LearnUrl = '' }
    [pscustomobject]@{ Id = 'AZL-098'; Severity = 'warning'; Path = 'nodes'; Message = 'stub warning'; LearnUrl = '' } }
Export-ModuleMember -Function Test-AzlInfrastructure
'@
        $file = New-TestInfrastructureV5 -Name 'v5-stub-toolkit'
        $env:AZL_TOOLKIT_ROOT = $tk
        try {
            Find-ZtpToolkitModule | Should -Be ([IO.Path]::GetFullPath((Join-Path $mod 'AzlInfrastructure.psm1')))
            $text = & $script:assertText $file
            $text | Should -BeLike '*checked by azurelocal-toolkit*is invalid (1 problem)*AZL-099 nodes: stub error*'
            (& $script:read $file)._source.warnings | Should -Be @('AZL-098 nodes: stub warning')
            # 'none' skips the toolkit.
            (Read-ZtpInfrastructure -Path $file -ToolkitModulePath none)._source.validator | Should -Be 'built-in'
        }
        finally { $env:AZL_TOOLKIT_ROOT = Join-Path $TestDrive 'no-toolkit-here'; Remove-Module AzlInfrastructure -ErrorAction SilentlyContinue }
    }

    It 'passes the real toolkit''s schema 5.2 check, when an azurelocal-toolkit clone is next to this repository' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..\..\..\azurelocal-toolkit\scripts\common\infrastructure\AzlInfrastructure.psm1'))) {
        $module = [IO.Path]::GetFullPath((Join-Path $script:repoRoot '..\azurelocal-toolkit\scripts\common\infrastructure\AzlInfrastructure.psm1'))
        try {
            $e = Read-ZtpInfrastructure -Path (New-TestInfrastructureV5 -Name 'v5-real-toolkit') -ToolkitModulePath $module
            @($e._source.problems) | Should -BeNullOrEmpty
            $e._source.validator | Should -BeLike 'azurelocal-toolkit*'
        }
        finally { Remove-Module AzlInfrastructure -ErrorAction SilentlyContinue }
    }

    It 'runs Invoke-ZtpEnvironment.ps1 from a schema 5 file: the node list, the Bicep parameters and the settings' {
        $root = New-TestRepo -Name 'env-v5-repo' -Copy 'Invoke-ZtpEnvironment.ps1', 'ZtpEnvironment.Common.ps1'
        $bin = Join-Path $root 'scripts/simplified-provisioning'
        foreach ($stub in 'Invoke-ZtpProvisioning.ps1') { Set-Content -LiteralPath (Join-Path $bin $stub) -Value '[CmdletBinding(SupportsShouldProcess)] param($ConfigPath, $NodeName, $BmcCredential, $InfrastructureFile, $Node, $DriverStagingPath, $EventLogPath, $From, [switch]$ConfirmNotClustered, [switch]$SkipCertificateCheck, [switch]$RetryProvisionOs, [switch]$RebuildImages, [switch]$Execute)' }
        $infra = New-TestInfrastructureV5 -Name 'v5-invoke' -Edit { param($d) $d.hardware['bios'] = [ordered]@{ EmbNic1Nic2 = 'Enabled' } }
        $text = Get-StepText (& (Join-Path $bin 'Invoke-ZtpEnvironment.ps1') -InfrastructureFile $infra *>&1)
        $text | Should -BeLike '*Site network: Automatic.*'
        $text | Should -BeLike '*Note: hardware.sbe ignored: SBE belongs to OS configuration.*'
        $nodes = Get-Content -LiteralPath (Join-Path $root 'config/simplified-provisioning/nodes.json') -Raw | ConvertFrom-Json
        "$($nodes.nodes[1].name) $($nodes.nodes[1].service_tag) $($nodes.nodes[1].bmc_address) $($nodes.nodes[1].management_ip) $($nodes.nodes[1].bios.EmbNic1Nic2)" | Should -Be 'node-02 EXAMPLE2 198.51.100.12 192.0.2.12 Enabled'
        # For the handoff: the management port's MAC and mode, and every port of the file. The fixture's management port has
        # no role provisioning (the 100G ports carry it), so it takes no DHCP while provisioned: Mode C.
        "$($nodes.nodes[1].management_mac) $($nodes.nodes[1].management_ip_assignment) $($nodes.nodes[1].management_dhcp)" | Should -Be '02:00:00:00:00:12 static False'
        @($nodes.nodes[1].network_adapters).Count | Should -Be 6
        ($nodes.nodes[1].network_adapters | Where-Object name -EQ 'Slot 3 Port 1').roles | Should -Be @('compute', 'provisioning')
        $bicep = Get-Content -LiteralPath (Join-Path $bin 'bicep/main.parameters.json') -Raw | ConvertFrom-Json
        $bicep.parameters.nodes.value[0].management.management_dhcp | Should -BeFalse
        $m = $bicep.parameters.nodes.value[0].management
        "$($m.ip_assignment) $($m.mac_address) $($m.adapter_name) $($m.ip_address) $($m.subnet_mask) $($m.vlan_id)" | Should -Be 'static 02:00:00:00:00:11 Embedded NIC 1 192.0.2.11 255.255.255.0 0'
        $bicep.parameters.ip_assignment_type.value | Should -Be 'Automatic'
        $bicep.parameters.nodes.value[0].management.static_method | Should -Be 'device'
        $bicep.parameters.key_vault_resource_group.value | Should -Be 'rg-example-vault'
        $bicep.parameters.admin_secret_name.value | Should -Be 'ztp-admin-password'
        $cfg = Get-Content -LiteralPath (Join-Path $root 'config/simplified-provisioning/ztp-provisioning.json') -Raw | ConvertFrom-Json
        "$($cfg.Oem) $($cfg.ShareHost) $($cfg.ShareName) $($cfg.ResourceGroupName) $($cfg.Location)" | Should -Be 'Contoso 192.0.2.10 ztp-example rg-example eastus'
        $cfg.PSObject.Properties.Name | Should -Not -Contain 'SbeModel'
        $cfg.BootstrapCacheDirectory | Should -BeLike '*data-v5-invoke*media'
    }

    It 'maps every schema 5.3 key ZTP reads: static_method, provisioning_dhcp_range, bios_during_provisioning, maintenance_address and the maintenance password; accepts _metadata.scope and ignores hardware.sbe' {
        $file = New-TestInfrastructureV5 -Name 'v5-53' -Edit {
            param($d)
            $d._metadata['schema_version'] = '5.3.0'; $d._metadata['scope'] = 'ztp'
            $d.networking.management['static_method'] = 'site'
            $d.networking.management['provisioning_dhcp_range'] = [ordered]@{ start = '192.0.2.100'; end = '192.0.2.250' }
            $d.hardware['bios'] = [ordered]@{ Slot2 = 'Enabled'; EmbNic1Nic2 = 'Enabled' }
            $d.hardware['bios_during_provisioning'] = [ordered]@{ Slot2 = 'Disabled' }
            $d.nodes[1]['bios_during_provisioning'] = [ordered]@{ Slot3 = 'Disabled' }
            $d.nodes[0]['maintenance_address'] = '192.0.2.120'
            $d.provisioning.simplified['maintenance_password'] = 'keyvault://kv-example/edgeuser-password'
        }
        $e = & $script:read $file
        @(Test-ZtpEnvironment -Environment $e).Count | Should -Be 0
        & $script:assertText $file | Should -Be ''
        $m = $e.network_intents.management
        $m.static_method | Should -Be 'site'
        "$($m.provisioning_dhcp_range.start)-$($m.provisioning_dhcp_range.end)" | Should -Be '192.0.2.100-192.0.2.250'
        $e.hardware.bios_during_provisioning.Slot2 | Should -Be 'Disabled'
        $e.cluster_nodes[1].bios_during_provisioning.Slot3 | Should -Be 'Disabled'
        $e.cluster_nodes[0].maintenance_address | Should -Be '192.0.2.120'
        $e.ztp.maintenance_password_secret | Should -Be 'keyvault://kv-example/edgeuser-password'
        (Split-ZtpKeyVaultReference $e.ztp.maintenance_password_secret).Secret | Should -Be 'edgeuser-password'
        (Get-ZtpSiteNetwork -Environment $e).IpAssignmentType | Should -Be 'Manual'
        $boot = Get-ZtpEnvironmentBios -Environment $e -Node $e.cluster_nodes[1] -Kind boot
        "$($boot.Slot2) $($boot.EmbNic1Nic2) $($boot.Slot3)" | Should -Be 'Disabled Enabled Disabled'
        @(Get-ZtpEnvironmentNote -Environment $e) | Should -Be @('hardware.sbe ignored: SBE belongs to OS configuration.')
        # Without hardware.sbe the file is just as valid.
        $nosbe = New-TestInfrastructureV5 -Name 'v5-53-nosbe' -Edit { param($d) $d.hardware.Remove('sbe') }
        & $script:assertText $nosbe | Should -Be ''
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
