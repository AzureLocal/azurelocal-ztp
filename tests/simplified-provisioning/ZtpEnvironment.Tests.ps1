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
        @{ Case = 'two nodes share a static management address'; Edit = { param($e) $e.cluster_nodes[1].ip_address = $e.cluster_nodes[0].ip_address }; Expect = 'cluster_nodes[1] (node-02).ip_address 192.0.2.11 is also the address of cluster_nodes[0] (node-01)' }
        @{ Case = 'a static node address is inside the provisioning DHCP range'; Edit = { param($e) $e.network_intents.management['provisioning_dhcp_range'] = [ordered]@{ start = '192.0.2.1'; end = '192.0.2.50' } }; Expect = 'cluster_nodes[0] (node-01).ip_address 192.0.2.11 is inside network_intents.management.provisioning_dhcp_range 192.0.2.1-192.0.2.50' }
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

Describe 'BIOS actions derived from the inventory (schema 5.4)' {
    BeforeAll {
        # Built-in checks only: the scripts would otherwise look for a toolkit clone next to the repository.
        $script:savedToolkitRoot54 = $env:AZL_TOOLKIT_ROOT
        $env:AZL_TOOLKIT_ROOT = Join-Path $TestDrive 'no-toolkit-here'
        $script:oemRoot = Join-Path $script:repoRoot 'config/oem'
        # A schema 5 file for a Dell server: two nodes, each with the two embedded LOMs (management), a PCIe NIC in Slot 3 and one in
        # Slot 6 (a second adapter type), and a Fibre Channel HBA in Slot 2. -Edit changes the parsed file first.
        function New-DerivedFile {
            param([string]$Name = [guid]::NewGuid().ToString('N'), [scriptblock]$Edit, [string]$Vendor = 'Dell', [switch]$NoHba)
            $script:derivedEdit = $Edit; $script:derivedVendor = $Vendor; $script:derivedNoHba = [bool]$NoHba
            New-TestInfrastructureV5 -Name "derived-$Name" -Edit {
                param($d)
                $d.hardware.vendor = $script:derivedVendor
                if (-not $script:derivedNoHba) { foreach ($n in $d.nodes) { $n['san'] = [ordered]@{ hbas = @([ordered]@{ slot = 'Slot 2'; type = 'fibre_channel'; model = 'Example 32G FC HBA' }) } } }
                if ($script:derivedEdit) { & $script:derivedEdit $d }
            }
        }
        function Read-Derived { param([string]$File) Read-ZtpInfrastructure -Path $File }
        function Get-AssertText { param([string]$Path) try { Assert-ZtpEnvironment -Environment (Read-ZtpInfrastructure -Path $Path) -Source 'infra.yml' -InformationAction SilentlyContinue; '' } catch { $_.Exception.Message } }
        function Format-Bios { param($Bios) @($Bios.Keys | ForEach-Object { "$_=$($Bios[$_])" }) -join ',' }
    }
    AfterAll { $env:AZL_TOOLKIT_ROOT = $script:savedToolkitRoot54 }

    It 'turns the SAN adapter slot off for the install and back on afterwards, and enables the embedded NICs: the same values a raw Dell map gives' {
        $e = Read-Derived (New-DerivedFile -Name 'derived-maps')
        @(Test-ZtpEnvironment -Environment $e) | Should -BeNullOrEmpty
        $n = $e.cluster_nodes[0]
        Format-Bios (Get-ZtpEnvironmentBios -Environment $e -Node $n -Kind provisioning) | Should -Be 'Slot2=Disabled'
        # Restore puts the slot back to the value Boot found, so the derived final state holds only the embedded NICs.
        Format-Bios (Get-ZtpEnvironmentBios -Environment $e -Node $n -Kind final) | Should -Be 'EmbNic1Nic2=Enabled'
        Format-Bios (Get-ZtpEnvironmentBios -Environment $e -Node $n -Kind boot) | Should -Be 'EmbNic1Nic2=Enabled,Slot2=Disabled'
        # The same file with raw maps instead of the listed HBA and no HBA listed gives the identical result.
        $raw = Read-Derived (New-DerivedFile -Name 'raw-maps' -NoHba -Edit { param($d)
                $d.hardware['bios'] = [ordered]@{ Slot2 = 'Enabled'; EmbNic1Nic2 = 'Enabled' }
                $d.hardware['bios_during_provisioning'] = [ordered]@{ Slot2 = 'Disabled' }
            })
        foreach ($kind in 'provisioning', 'boot') {
            $a = Get-ZtpEnvironmentBios -Environment $e -Node $e.cluster_nodes[1] -Kind $kind
            $b = Get-ZtpEnvironmentBios -Environment $raw -Node $raw.cluster_nodes[1] -Kind $kind
            ((Format-Bios $a) -split ',' | Sort-Object) -join ',' | Should -Be (((Format-Bios $b) -split ',' | Sort-Object) -join ',') -Because "the $kind map must be what the raw maps give"
        }
    }

    It 'prints the derived plan with the reason for each decision' {
        $e = Read-Derived (New-DerivedFile -Name 'plan')
        $plan = @(Get-ZtpDerivedBiosPlan -Environment $e)
        $plan | Should -Contain 'PLAN: node-01 BIOS Slot2 Disabled for the install because nodes[0].san.hbas[0] is in Slot 2 (the Restore stage sets it back to its original value, or Enabled if it was already Disabled)'
        $plan | Should -Contain 'PLAN: node-02 BIOS Slot2 Disabled for the install because nodes[1].san.hbas[0] is in Slot 2 (the Restore stage sets it back to its original value, or Enabled if it was already Disabled)'
        @($plan | Where-Object { $_ -like 'PLAN: node-01 BIOS EmbNic1Nic2 Enabled because the management port ''Embedded NIC 1'' of nodes[[]0] is in slot Embedded*' }).Count | Should -Be 1
        @(Get-ZtpDerivedBiosPlan -Environment $e -Node 'node-02').Count | Should -Be 2 -Because 'only the named node''s decisions'
    }

    It 'touches nothing but the HBA slot and the embedded NICs on a server with two adapter types (an onboard LOM and PCIe NICs)' {
        $e = Read-Derived (New-DerivedFile -Name 'two-types' -Edit { param($d)
                $d.nodes[0].network_adapters += [ordered]@{ name = 'Slot 5 Port 1'; mac_address = '02:00:00:00:00:71'; slot = 'Slot 5'; model = 'Another vendor 25G'; roles = @('compute'); ip_assignment = 'none' }
            })
        $derived = Get-ZtpDerivedBios -Environment $e -Node $e.cluster_nodes[0]
        @($derived.Problems) | Should -BeNullOrEmpty
        (@($derived.Final.Keys) + @($derived.During.Keys) | Sort-Object -Unique) -join ',' | Should -Be 'EmbNic1Nic2,Slot2' -Because 'Slot 3, Slot 5 and Slot 6 carry network ports and are never touched'
    }

    It 'follows the slot the HBA is in: Slot5 gives Slot5, and a second HBA gives a second key' {
        $e = Read-Derived (New-DerivedFile -Name 'slots' -Edit { param($d) $d.nodes[0].san.hbas[0].slot = 'Slot5'; $d.nodes[0].san.hbas += [ordered]@{ slot = 'slot-7'; type = 'iscsi_offload' } })
        $derived = Get-ZtpDerivedBios -Environment $e -Node $e.cluster_nodes[0]
        Format-Bios $derived.During | Should -Be 'Slot5=Disabled,Slot7=Disabled'
        Format-Bios $derived.Final | Should -Be 'EmbNic1Nic2=Enabled'
        (Get-ZtpDerivedBios -Environment $e -Node $e.cluster_nodes[1]).During.Keys | Should -Be @('Slot2') -Because 'each node follows its own inventory'
    }

    It 'does no BIOS isolation on a server with no SAN, and still enables the embedded NICs' {
        $e = Read-Derived (New-DerivedFile -Name 'no-san' -NoHba)
        $derived = Get-ZtpDerivedBios -Environment $e -Node $e.cluster_nodes[0]
        $derived.During.Count | Should -Be 0
        Format-Bios $derived.Final | Should -Be 'EmbNic1Nic2=Enabled'
        Format-Bios (Get-ZtpEnvironmentBios -Environment $e -Node $e.cluster_nodes[0] -Kind provisioning) | Should -BeNullOrEmpty
        # And no bios_restore: nothing was changed for the install only.
        @(Get-ZtpDerivedBiosPlan -Environment $e).Count | Should -Be 2 -Because 'one line per node, for the embedded NICs'
    }

    It 'derives nothing for a server whose management port is a PCIe NIC and that has no SAN' {
        $e = Read-Derived (New-DerivedFile -Name 'pcie-only' -NoHba -Edit { param($d)
                foreach ($n in $d.nodes) { foreach ($p in $n.network_adapters) { if ($p.slot -eq 'Embedded') { $p.slot = 'Slot 1' } } }
            })
        foreach ($n in $e.cluster_nodes) {
            $derived = Get-ZtpDerivedBios -Environment $e -Node $n
            $derived.Final.Count | Should -Be 0; $derived.During.Count | Should -Be 0; @($derived.Plan).Count | Should -Be 0
        }
    }

    It 'lets explicit keys win: a raw bios_during_provisioning value, a raw final value, and a raw embedded-NIC value' {
        $e = Read-Derived (New-DerivedFile -Name 'explicit' -Edit { param($d)
                $d.hardware['bios'] = [ordered]@{ Slot2 = 'BootDriverDisabled'; EmbNic1Nic2 = 'DisabledOs' }
                $d.nodes[1]['bios_during_provisioning'] = [ordered]@{ Slot2 = 'BootDriverDisabled' }
            })
        # node-01: the install uses the derived Disabled (the explicit final is the end state), Restore sets BootDriverDisabled back.
        Format-Bios (Get-ZtpEnvironmentBios -Environment $e -Node $e.cluster_nodes[0] -Kind provisioning) | Should -Be 'Slot2=Disabled'
        Format-Bios (Get-ZtpEnvironmentBios -Environment $e -Node $e.cluster_nodes[0] -Kind final) | Should -Be 'Slot2=BootDriverDisabled,EmbNic1Nic2=DisabledOs'
        # node-02: its own explicit during value replaces the derived one.
        Format-Bios (Get-ZtpEnvironmentBios -Environment $e -Node $e.cluster_nodes[1] -Kind provisioning) | Should -Be 'Slot2=BootDriverDisabled'
        $plan = @(Get-ZtpDerivedBiosPlan -Environment $e)
        $plan | Should -Contain 'PLAN: node-01 BIOS Slot2 Disabled for the install because nodes[0].san.hbas[0] is in Slot 2 (the Restore stage sets it back to BootDriverDisabled from hardware.bios)'
        @($plan | Where-Object { $_ -like 'PLAN: node-02 BIOS Slot2 BootDriverDisabled for the install, from hardware.bios_during_provisioning (explicit*' }).Count | Should -Be 1
        @($plan | Where-Object { $_ -like 'PLAN: node-01 BIOS EmbNic1Nic2 DisabledOs, as hardware.bios says*' }).Count | Should -Be 1
    }

    It 'honours the switches: isolate_san_adapters false and enable_embedded_nics false turn the derivation off' {
        $e = Read-Derived (New-DerivedFile -Name 'switches-off' -Edit { param($d) $d.provisioning.simplified['isolate_san_adapters'] = $false; $d.provisioning.simplified['enable_embedded_nics'] = $false })
        $derived = Get-ZtpDerivedBios -Environment $e -Node $e.cluster_nodes[0]
        $derived.Final.Count | Should -Be 0; $derived.During.Count | Should -Be 0
        # An odd slot label is no problem while isolation is off.
        $odd = Read-Derived (New-DerivedFile -Name 'switch-odd' -Edit { param($d) $d.provisioning.simplified['isolate_san_adapters'] = $false; $d.nodes[0].san.hbas[0].slot = 'OCP 1' })
        @(Test-ZtpEnvironment -Environment $odd) | Should -BeNullOrEmpty
        # True without any HBA listed does nothing and fails nothing.
        $none = Read-Derived (New-DerivedFile -Name 'switch-true' -NoHba -Edit { param($d) $d.provisioning.simplified['isolate_san_adapters'] = $true })
        @(Test-ZtpEnvironment -Environment $none) | Should -BeNullOrEmpty
        (Get-ZtpDerivedBios -Environment $none -Node $none.cluster_nodes[0]).During.Count | Should -Be 0
    }

    It 'fails before anything changes on a slot label it can not read, naming the node, the HBA and the label' {
        $file = New-DerivedFile -Name 'odd-label' -Edit { param($d) $d.nodes[1].san.hbas[0].slot = 'OCP 1' }
        $message = Get-AssertText $file
        $message | Should -BeLike '*nodes[[]1] (node-02).san.hbas[[]0].slot ''OCP 1'' isn''t a PCIe slot label such as ''Slot 2''*'
        $message | Should -BeLike '*provisioning.simplified.isolate_san_adapters*hardware.bios_during_provisioning*'
        $message | Should -Not -BeLike '*node-01*san.hbas*'
    }

    It 'refuses to turn off a slot that also carries a network port' {
        $file = New-DerivedFile -Name 'shared-slot' -Edit { param($d) $d.nodes[0].san.hbas[0].slot = 'Slot 3' }
        $message = Get-AssertText $file
        $message | Should -BeLike '*nodes[[]0] (node-01).san.hbas[[]0] is in Slot 3, which also holds the network port ''Slot 3 Port 1''*'
    }

    It 'says so, and does not guess, for a vendor without a slot mapping' {
        # The HBA is listed, the vendor has no bios section, and the file gives no raw map: stop, naming the vendor and the way out.
        $file = New-DerivedFile -Name 'no-mapping' -Vendor 'Contoso'
        $message = Get-AssertText $file
        $message | Should -BeLike '*nodes[[]0] (node-01).san.hbas[[]0] is in Slot 2*no BIOS slot mapping for vendor ''Contoso''*won''t guess*bios_attribute*isolate_san_adapters*'
        # An unrelated explicit key no longer excuses the missing mapping: the safety stop stays.
        $other = Get-AssertText (New-DerivedFile -Name 'no-mapping-unrelated' -Vendor 'Contoso' -Edit { param($d) $d.hardware['bios_during_provisioning'] = [ordered]@{ SriovGlobalEnable = 'Disabled' } })
        $other | Should -BeLike '*no BIOS slot mapping for vendor ''Contoso''*'
        # The HBA's own bios_attribute is what works without a mapping.
        $fine = Read-Derived (New-DerivedFile -Name 'no-mapping-own' -Vendor 'Contoso' -Edit { param($d) foreach ($n in $d.nodes) { $n.san.hbas[0]['bios_attribute'] = 'PciSlot2'; $n.san.hbas[0]['bios_disabled_value'] = 'Off'; $n.san.hbas[0]['bios_enabled_value'] = 'On' } })
        @(Test-ZtpEnvironment -Environment $fine) | Should -BeNullOrEmpty
        Format-Bios (Get-ZtpEnvironmentBios -Environment $fine -Node $fine.cluster_nodes[0] -Kind provisioning) | Should -Be 'PciSlot2=Off'
        (Get-ZtpDerivedBios -Environment $fine -Node $fine.cluster_nodes[0]).Fallback['PciSlot2'].restore | Should -Be 'On'
        @(Get-ZtpDerivedBiosPlan -Environment $fine -Node 'node-01')[0] | Should -BeLike 'PLAN: node-01 BIOS PciSlot2 Off for the install because nodes[[]0].san.hbas[[]0] is in Slot 2 (the Restore stage sets it back to its original value, or On if it was already Off)'
    }

    It 'leaves the embedded NICs alone for an unmapped vendor unless the switch asks for them' {
        $e = Read-Derived (New-DerivedFile -Name 'unmapped-embedded' -Vendor 'Contoso' -NoHba)
        @(Test-ZtpEnvironment -Environment $e) | Should -BeNullOrEmpty
        (Get-ZtpDerivedBios -Environment $e -Node $e.cluster_nodes[0]).Final.Count | Should -Be 0
        @(Get-ZtpDerivedBiosPlan -Environment $e)[0] | Should -BeLike '*no embedded-NIC attribute for vendor ''Contoso''*leaves the embedded NICs as they are*'
        $asked = New-DerivedFile -Name 'unmapped-asked' -Vendor 'Contoso' -NoHba -Edit { param($d) $d.provisioning.simplified['enable_embedded_nics'] = $true }
        (Get-AssertText $asked) | Should -BeLike '*enable_embedded_nics is true, but ZTP has no embedded-NIC BIOS attribute for vendor ''Contoso''*'
    }

    It 'keeps today''s behaviour for a file that lists no HBAs and no embedded ports: nothing derived, nothing to say' {
        $e = Read-Derived (New-TestInfrastructureV5 -Name 'derived-untouched')
        foreach ($n in $e.cluster_nodes) { (Get-ZtpDerivedBios -Environment $e -Node $n).Plan.Count | Should -Be 1 -Because 'only the Contoso note about the embedded NICs' }
        $legacy = Read-ZtpEnvironmentFile -Path $script:fixture
        (Get-ZtpDerivedBios -Environment $legacy -Node $legacy.cluster_nodes[0]).Plan.Count | Should -Be 0
        Format-Bios (Get-ZtpEnvironmentBios -Environment $legacy -Node $legacy.cluster_nodes[0]) | Should -Be (Format-Bios (Get-ZtpEnvironmentBios -Environment $legacy -Node $legacy.cluster_nodes[0] -ExplicitOnly))
    }

    It 'runs Invoke-ZtpEnvironment.ps1: the plan lines, the node list with bios, bios_restore and the reasons, and a bad slot stops it first' {
        $root = New-TestRepo -Name 'derived-repo' -Copy 'Invoke-ZtpEnvironment.ps1', 'ZtpEnvironment.Common.ps1'
        Copy-Item -LiteralPath (Join-Path $script:oemRoot 'dell.json') -Destination (Join-Path $root 'config/oem/dell.json')
        $bin = Join-Path $root 'scripts/simplified-provisioning'
        Set-Content -LiteralPath (Join-Path $bin 'Invoke-ZtpProvisioning.ps1') -Value '[CmdletBinding(SupportsShouldProcess)] param($ConfigPath, $NodeName, $BmcCredential, $EdgeUserPassword, $InfrastructureFile, $Node, $EventLogPath, $From, [switch]$ConfirmNotClustered, [switch]$SkipCertificateCheck, [switch]$RetryProvisionOs, [switch]$RebuildImages, [switch]$Execute)'
        $nodesFile = Join-Path $root 'config/simplified-provisioning/nodes.json'

        $bad = New-DerivedFile -Name 'run-bad' -Edit { param($d) $d.nodes[0].san.hbas[0].slot = 'OCP 1' }
        $threw = try { & (Join-Path $bin 'Invoke-ZtpEnvironment.ps1') -InfrastructureFile $bad *>&1 | Out-Null; '' } catch { $_.Exception.Message }
        $threw | Should -BeLike '*isn''t a PCIe slot label*'
        Test-Path -LiteralPath $nodesFile | Should -BeFalse -Because 'the run stopped before it wrote anything'

        $good = New-DerivedFile -Name 'run-good'
        $text = Get-StepText (& (Join-Path $bin 'Invoke-ZtpEnvironment.ps1') -InfrastructureFile $good *>&1)
        $text | Should -BeLike '*PLAN: node-01 BIOS Slot2 Disabled for the install because nodes[[]0].san.hbas[[]0] is in Slot 2 (the Restore stage sets it back to its original value, or Enabled if it was already Disabled)*'
        $text | Should -BeLike '*BIOS set by the Boot stage before the maintenance boot: node-01 EmbNic1Nic2=Enabled, Slot2=Disabled*'
        $text | Should -BeLike '*BIOS set back by the Restore stage after Network: node-01 Slot2=<value before Boot>*'
        $nodes = (Get-Content -LiteralPath $nodesFile -Raw | ConvertFrom-Json).nodes
        "$($nodes[0].bios.Slot2) $($nodes[0].bios.EmbNic1Nic2) $($nodes[0].bios_restore.Slot2)" | Should -Be 'Disabled Enabled '
        "$($nodes[0].bios_restore_fallback.Slot2.when_found) $($nodes[0].bios_restore_fallback.Slot2.restore)" | Should -Be 'Disabled Enabled' -Because 'a slot Boot finds already disabled goes back to Enabled'
        $nodes[0].bios_restore.PSObject.Properties.Name | Should -Be @('Slot2') -Because 'the embedded NICs stay enabled'
        $nodes[0].bios_reason.Slot2 | Should -BeLike 'derived: nodes[[]0].san.hbas[[]0] is in Slot 2*'
        $nodes[0].bios_reason.EmbNic1Nic2 | Should -BeLike 'derived: the management port ''Embedded NIC 1'' is in slot Embedded*'
    }
}

# The toolkit clone these tests compare against: $env:AZL_TOOLKIT_ROOT, else azurelocal-toolkit next to this repository. Without it they are skipped.
$ztpToolkitRoot = if ($env:AZL_TOOLKIT_ROOT) { $env:AZL_TOOLKIT_ROOT } else { Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) '..\azurelocal-toolkit' }
# The toolkit is present when its folder is there. A toolkit without the schema or the templates where these tests look
# (config/variables, the one place for them) fails below; it does not skip.
$ztpHaveToolkit = Test-Path -LiteralPath (Join-Path $ztpToolkitRoot 'config') -PathType Container
Describe 'Every ZTP setting is a key of the master schema (schema 5.4)' {
    It 'finds the toolkit''s <_> under config/variables' -Skip:(-not $ztpHaveToolkit) -ForEach 'schema\infrastructure.schema.json', 'examples\infrastructure.ztp.example.yml', 'examples\infrastructure.example.yml' {
        Join-Path $script:toolkitRoot "config\variables\$_" | Should -Exist
    }

    BeforeAll {
        $script:savedToolkitRoot54b = $env:AZL_TOOLKIT_ROOT
        $env:AZL_TOOLKIT_ROOT = Join-Path $TestDrive 'no-toolkit-here'
        $script:toolkitRoot = if ($script:savedToolkitRoot54b) { $script:savedToolkitRoot54b } else { Join-Path $script:repoRoot '..\azurelocal-toolkit' }
        $script:toolkitSchema = Join-Path $script:toolkitRoot 'config\variables\schema\infrastructure.schema.json'
        function Format-Bios { param($Bios) @($Bios.Keys | ForEach-Object { "$_=$($Bios[$_])" }) -join ',' }
        function Get-AssertText { param([string]$Path) try { Assert-ZtpEnvironment -Environment (Read-ZtpInfrastructure -Path $Path) -Source 'infra.yml' -InformationAction SilentlyContinue; '' } catch { $_.Exception.Message } }
        $script:newKeys = @(
            'isolate_san_adapters', 'enable_embedded_nics', 'create_resource_group', 'configuration_name', 'managed_resource_group_name', 'apply_site_settings', 'use_key_vault_configuration',
            'assign_provisioning_roles', 'assign_hci_rp_role', 'network_kind', 'ntp', 'site_mode', 'deployment_name', 'skip_azure_check', 'include_preview', 'max_train',
            'retry_provision_os', 'usb_image', 'maintenance_environment', 'timeouts')
    }

    It 'has a schema key (toolkit 5.4) for every setting the reader copies' -Skip:(-not $ztpHaveToolkit) {
        $schema = Get-Content -LiteralPath $script:toolkitSchema -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        $simplified = $schema.properties.provisioning.properties.simplified.properties
        foreach ($k in $script:newKeys) { $simplified.Keys | Should -Contain $k -Because "provisioning.simplified.$k is read by ConvertFrom-ZtpInfrastructureV5" }
        foreach ($k in 'account_name', 'keep') { $simplified.media_share.properties.Keys | Should -Contain $k }
        $schema.'$defs'.bmc_credentials.properties.Keys | Should -Contain 'rfs_write_attribute'
        $schema.'$defs'.bmc_credentials.properties.Keys | Should -Contain 'verify_certificate'
        $schema.'$defs'.node_san.properties.hbas.items.properties.Keys | Should -Contain 'slot'
        $schema.'$defs'.node_san.properties.hbas.items.properties.Keys | Should -Contain 'type'
        # The schema's own timeouts are the ones the reader maps.
        foreach ($k in 'bootstrap_minutes', 'bootstrap_voucher_minutes', 'bootstrap_stall_minutes', 'voucher_wait_minutes', 'device_minutes', 'ready_minutes', 'network_minutes', 'restore_settle_minutes', 'bios_minutes', 'poll_interval_seconds') {
            $simplified.timeouts.properties.Keys | Should -Contain $k
        }
    }

    It 'reads the toolkit''s own ZTP and full templates with no problems and carries their new settings through' -Skip:(-not $ztpHaveToolkit) {
        $env:AZL_TOOLKIT_ROOT = $script:toolkitRoot   # validate with the toolkit's own module, as a real run does
        foreach ($template in 'infrastructure.ztp.example.yml', 'infrastructure.example.yml') {
            $path = Join-Path $script:toolkitRoot "config\variables\examples\$template"
            $copy = Join-Path $TestDrive "tk-$template"
            $data = ConvertFrom-Yaml (Get-Content -LiteralPath $path -Raw) -Ordered
            $data.provisioning.simplified['media_path'] = Join-Path $TestDrive "tk-data-$template/media"
            $data.provisioning.simplified['evidence_path'] = Join-Path $TestDrive "tk-data-$template/evidence"
            Set-Content -LiteralPath $copy -Value (ConvertTo-Yaml $data)
            $e = Read-ZtpInfrastructure -Path $copy
            @($e._source.problems) | Should -BeNullOrEmpty -Because "the toolkit's $template validates (validator: $($e._source.validator))"
            @(Test-ZtpEnvironment -Environment $e) | Should -BeNullOrEmpty
            $e._source.validator | Should -BeLike 'azurelocal-toolkit*'
        }
        $e = Read-ZtpInfrastructure -Path (Join-Path $TestDrive 'tk-infrastructure.example.yml')
        $env:AZL_TOOLKIT_ROOT = Join-Path $TestDrive 'no-toolkit-here'
        $e.ztp.usb_image.size_gb | Should -Be 4
        $e.ztp.maintenance_environment.port | Should -Be 20001
        $e.ztp.timeouts.bootstrap_minutes | Should -Be 120
        $e.ztp.configuration_name | Should -Be 'default'
        $e.ztp.share_account_name | Should -Be 'svc-ztp-media'
        $e.ztp.keep_share | Should -BeFalse
        $e.ztp.rfs_write_attribute | Should -BeTrue
        $e.ztp.verify_bmc_certificate | Should -BeFalse
        $z = Read-ZtpInfrastructure -Path (Join-Path $TestDrive 'tk-infrastructure.ztp.example.yml')
        $z.cluster_nodes[0].san.hbas[0].slot | Should -Be 'Slot 2'
        ($z.cluster_nodes[0].network_adapters | Where-Object name -EQ 'Embedded NIC 1').slot | Should -Be 'Embedded'
        Format-Bios (Get-ZtpEnvironmentBios -Environment $z -Node $z.cluster_nodes[0] -Kind boot) | Should -Be 'EmbNic1Nic2=Enabled,Slot2=Disabled' -Because 'the ZTP template writes no raw attribute at all'
    }

    AfterAll { $env:AZL_TOOLKIT_ROOT = $script:savedToolkitRoot54b }

    It 'checks the new values and names the schema 5 key: a zero Bootstrap budget, a port out of range, a network kind that is not LAN or WLAN, a Manual time setting without a server' {
        $file = New-TestInfrastructureV5 -Name 'v54-bad' -Edit { param($d)
            $s = $d.provisioning.simplified
            $s['timeouts'] = [ordered]@{ bootstrap_minutes = 0; ready_minutes = 5000 }
            $s['maintenance_environment'] = [ordered]@{ port = 70000 }
            $s['network_kind'] = 'WAN'
            $s['ntp'] = [ordered]@{ configuration = 'Manual' }
            $s['usb_image'] = [ordered]@{ size_gb = 1; name_prefix = 'bad prefix' }
            $s['retry_provision_os'] = 'yes'
            $s['configuration_name'] = '-bad'
        }
        $message = Get-AssertText $file
        foreach ($expected in 'provisioning.simplified.timeouts.bootstrap_minutes must be a whole number from 1 to 1440', 'provisioning.simplified.timeouts.ready_minutes must be a whole number from 0 to 1440',
            'provisioning.simplified.maintenance_environment.port must be a whole number from 1 to 65535', 'provisioning.simplified.network_kind must be LAN, WLAN', 'provisioning.simplified.ntp.server is required when provisioning.simplified.ntp.configuration is Manual',
            'provisioning.simplified.usb_image.size_gb must be a whole number from 2 to 128', 'provisioning.simplified.usb_image.name_prefix ''bad prefix'' isn''t valid', 'provisioning.simplified.retry_provision_os must be true or false', 'provisioning.simplified.configuration_name ''-bad'' isn''t valid') {
            $message | Should -BeLike "*$expected*"
        }
        $message | Should -Not -BeLike '*ztp.timeouts*' -Because 'messages use the schema 5 paths the operator wrote'
    }

    It 'accepts the defaults written out and gives the same settings as a file that leaves them out' {
        $plain = & $script:read (New-TestInfrastructureV5 -Name 'v54-plain')
        $full = & $script:read (New-TestInfrastructureV5 -Name 'v54-defaults' -Edit { param($d)
                $d._metadata['schema_version'] = '5.4.0'
                $d.provisioning.simplified['timeouts'] = [ordered]@{ bootstrap_minutes = 120; ready_minutes = 180; poll_interval_seconds = 60 }
                $d.provisioning.simplified['network_kind'] = 'LAN'; $d.provisioning.simplified['retry_provision_os'] = $true
                $d.provisioning.simplified['usb_image'] = [ordered]@{ size_gb = 4; name_prefix = 'ztp-usb-' }
            })
        @(Test-ZtpEnvironment -Environment $plain) | Should -BeNullOrEmpty
        @(Test-ZtpEnvironment -Environment $full) | Should -BeNullOrEmpty
        foreach ($k in 'timeouts.bootstrap_minutes', 'timeouts.ready_minutes', 'timeouts.poll_interval_seconds', 'usb_image.size_gb', 'usb_image.name_prefix', 'network_kind', 'retry_provision_os') {
            $default = switch ($k) { 'timeouts.bootstrap_minutes' { 120 } 'timeouts.ready_minutes' { 180 } 'timeouts.poll_interval_seconds' { 60 } 'usb_image.size_gb' { 4 } 'usb_image.name_prefix' { 'ztp-usb-' } 'network_kind' { 'LAN' } 'retry_provision_os' { $true } }
            (Get-ZtpSetting -Environment $plain -Path "ztp.$k" -Default $default) | Should -Be (Get-ZtpSetting -Environment $full -Path "ztp.$k" -Default $default) -Because $k
        }
    }
}

Describe 'Invoke-ZtpEnvironment.ps1 settings (schema 5.4)' {
    BeforeAll {
        $script:savedToolkitRoot54c = $env:AZL_TOOLKIT_ROOT
        $env:AZL_TOOLKIT_ROOT = Join-Path $TestDrive 'no-toolkit-here'
        function script:Invoke-Settings {
            param([string]$Name, [scriptblock]$Edit, [string]$OemJson)
            $root = if ($OemJson) { New-TestRepo -Name "set-$Name" -Copy 'Invoke-ZtpEnvironment.ps1', 'ZtpEnvironment.Common.ps1' -OemJson $OemJson } else { New-TestRepo -Name "set-$Name" -Copy 'Invoke-ZtpEnvironment.ps1', 'ZtpEnvironment.Common.ps1' }
            $bin = Join-Path $root 'scripts/simplified-provisioning'
            Set-Content -LiteralPath (Join-Path $bin 'Invoke-ZtpProvisioning.ps1') -Value '[CmdletBinding(SupportsShouldProcess)] param($ConfigPath, $NodeName, $BmcCredential, $EdgeUserPassword, $InfrastructureFile, $Node, $EventLogPath, $From, [switch]$ConfirmNotClustered, [switch]$SkipCertificateCheck, [switch]$RetryProvisionOs, [switch]$RebuildImages, [switch]$Execute)'
            $infra = New-TestInfrastructureV5 -Name "set-$Name" -Edit $Edit
            $null = & (Join-Path $bin 'Invoke-ZtpEnvironment.ps1') -InfrastructureFile $infra *>&1
            [pscustomobject]@{
                Config = Get-Content -LiteralPath (Join-Path $root 'config/simplified-provisioning/ztp-provisioning.json') -Raw | ConvertFrom-Json
                Bicep  = (Get-Content -LiteralPath (Join-Path $bin 'bicep/main.parameters.json') -Raw | ConvertFrom-Json).parameters
            }
        }
    }
    AfterAll { $env:AZL_TOOLKIT_ROOT = $script:savedToolkitRoot54c }

    It 'writes the values ZTP always used when the file sets none of the new keys' {
        $r = Invoke-Settings -Name 'defaults'
        $c = $r.Config
        "$($c.VoucherWaitMinutes) $($c.BootstrapTimeoutMinutes) $($c.BootstrapVoucherTimeoutMinutes) $($c.BootstrapStallMinutes) $($c.ReadyTimeoutMinutes) $($c.PollIntervalSeconds) $($c.DeviceTimeoutMinutes) $($c.NetworkTimeoutMinutes) $($c.RestoreSettleMinutes) $($c.BiosTimeoutMinutes)" | Should -Be '120 120 90 20 180 60 30 60 5 30'
        "$($c.ImageNamePrefix) $($c.ImageSizeGB) $($c.ShareAccountName) $($c.KeepShare) $($c.MaintenancePort) $($c.MaintenanceUser) $($c.IncludePreview) $($c.SkipAzureCheck) $($c.SiteMode)" | Should -Be 'ztp-usb- 4 svc-ztp-media False 20001 edgeuser False False Auto'
        $c.DeploymentName | Should -Be 'ztp-example-site'
        $c.SkipCertificateCheck | Should -BeTrue -Because 'BMCs ship self-signed certificates'
        $c.RfsWriteAttribute | Should -BeTrue -Because 'an OEM definition with no rfsWriteAttribute keeps what ZTP always did'
        $c.PSObject.Properties.Name | Should -Not -Contain 'MaxBootstrapTrain'
        $b = $r.Bicep
        "$($b.configuration_name.value) $($b.apply_site_settings.value) $($b.use_key_vault_configuration.value) $($b.assign_provisioning_roles.value) $($b.assign_hci_rp_role.value) '$($b.managed_resource_group_name.value)' $($b.network_kind.value) $($b.ntp_configuration_choice.value) '$($b.ntp_server.value)' '$($b.alternate_ntp_server.value)' $($b.connectivity_type.value)" | Should -Be "default True True True True '' LAN Automatic '' '' Public"
    }

    It 'carries every new setting from the file to the settings file and the Bicep parameters' {
        $r = Invoke-Settings -Name 'custom' -Edit { param($d)
            $s = $d.provisioning.simplified
            $s['timeouts'] = [ordered]@{ bootstrap_minutes = 200; bootstrap_voucher_minutes = 100; bootstrap_stall_minutes = 40; voucher_wait_minutes = 150; device_minutes = 45; ready_minutes = 240; network_minutes = 90; restore_settle_minutes = 10; bios_minutes = 55; poll_interval_seconds = 30 }
            $s['usb_image'] = [ordered]@{ size_gb = 8; name_prefix = 'lab-usb-' }
            $s['maintenance_environment'] = [ordered]@{ port = 20011; username = 'lab-user' }
            $s['media_share']['account_name'] = 'svc-lab'; $s['media_share']['keep'] = $true
            $s['include_preview'] = $true; $s['max_train'] = '2609'; $s['skip_azure_check'] = $true; $s['site_mode'] = 'Reuse'; $s['deployment_name'] = 'ztp-lab'
            $s['configuration_name'] = 'lab-config'; $s['managed_resource_group_name'] = 'rg-lab-managed'; $s['apply_site_settings'] = $false; $s['use_key_vault_configuration'] = $false
            $s['assign_provisioning_roles'] = $false; $s['assign_hci_rp_role'] = $false; $s['network_kind'] = 'WLAN'
            $s['ntp'] = [ordered]@{ configuration = 'Manual'; server = '192.0.2.30'; alternate_server = '192.0.2.31' }
            $d.hardware.bmc['verify_certificate'] = $true; $d.hardware.bmc['rfs_write_attribute'] = $false
        }
        $c = $r.Config
        "$($c.VoucherWaitMinutes) $($c.BootstrapTimeoutMinutes) $($c.BootstrapVoucherTimeoutMinutes) $($c.BootstrapStallMinutes) $($c.ReadyTimeoutMinutes) $($c.PollIntervalSeconds) $($c.DeviceTimeoutMinutes) $($c.NetworkTimeoutMinutes) $($c.RestoreSettleMinutes) $($c.BiosTimeoutMinutes)" | Should -Be '150 200 100 40 240 30 45 90 10 55'
        "$($c.ImageNamePrefix) $($c.ImageSizeGB) $($c.ShareAccountName) $($c.KeepShare) $($c.MaintenancePort) $($c.MaintenanceUser) $($c.IncludePreview) $($c.MaxBootstrapTrain) $($c.SkipAzureCheck) $($c.SiteMode) $($c.DeploymentName)" | Should -Be 'lab-usb- 8 svc-lab True 20011 lab-user True 2609 True Reuse ztp-lab'
        "$($c.SkipCertificateCheck) $($c.RfsWriteAttribute)" | Should -Be 'False False'
        $b = $r.Bicep
        "$($b.configuration_name.value) $($b.apply_site_settings.value) $($b.use_key_vault_configuration.value) $($b.assign_provisioning_roles.value) $($b.assign_hci_rp_role.value) $($b.managed_resource_group_name.value) $($b.network_kind.value) $($b.ntp_configuration_choice.value) $($b.ntp_server.value) $($b.alternate_ntp_server.value)" | Should -Be 'lab-config False False False False rg-lab-managed WLAN Manual 192.0.2.30 192.0.2.31'
    }

    It 'takes the Remote File Share attribute from the vendor definition unless the file says so' {
        $dell = Get-Content -LiteralPath (Join-Path $script:oemRoot 'dell.json') -Raw
        $hpe = Get-Content -LiteralPath (Join-Path $script:oemRoot 'hpe.json') -Raw
        (Invoke-Settings -Name 'rfs-dell' -OemJson $dell -Edit { param($d) $d.hardware.vendor = 'Contoso' }).Config.RfsWriteAttribute | Should -BeTrue -Because 'the test repository''s Contoso file is the Dell one here'
        (Invoke-Settings -Name 'rfs-hpe' -OemJson $hpe -Edit { param($d) $d.hardware.vendor = 'Contoso' }).Config.RfsWriteAttribute | Should -BeFalse -Because 'an iLO has no RFS.<n>.WriteProtected attribute'
        (Invoke-Settings -Name 'rfs-hpe-own' -OemJson $hpe -Edit { param($d) $d.hardware.vendor = 'Contoso'; $d.hardware.bmc['rfs_write_attribute'] = $true }).Config.RfsWriteAttribute | Should -BeTrue
    }

    It 'has a Dell bios mapping and no guessed mapping for the other vendors' {
        $dell = Get-Content -LiteralPath (Join-Path $script:oemRoot 'dell.json') -Raw | ConvertFrom-Json -AsHashtable
        $dell.bios.slot_attribute | Should -Be 'Slot{n}'
        "$($dell.bios.disabled) $($dell.bios.enabled) $($dell.bios.embedded_nic_attribute) $($dell.bios.embedded_enabled)" | Should -Be 'Disabled Enabled EmbNic1Nic2 Enabled'
        foreach ($vendor in 'hpe', 'lenovo', 'supermicro') {
            $json = Get-Content -LiteralPath (Join-Path $script:oemRoot "$vendor.json") -Raw | ConvertFrom-Json -AsHashtable
            $json.Contains('bios') | Should -BeFalse -Because "$vendor has no verified slot mapping"
            $json.bmc.rfsWriteAttribute | Should -BeFalse
        }
        (Read-ZtpOemFile -Vendor 'Dell').bios.embedded_nic_attribute | Should -Be 'EmbNic1Nic2'
        Read-ZtpOemFile -Vendor 'NoSuchVendor' | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-ZtpEnvironment.ps1 -Execute honours the Azure and BMC settings (schema 5.4)' {
    BeforeAll {
        $script:savedToolkitRoot54d = $env:AZL_TOOLKIT_ROOT
        $env:AZL_TOOLKIT_ROOT = Join-Path $TestDrive 'no-toolkit-here'
        function script:Invoke-ExecuteCase {
            param([string]$Name, [scriptblock]$Edit)
            $root = New-TestRepo -Name "exec-$Name" -Copy 'Invoke-ZtpEnvironment.ps1', 'ZtpEnvironment.Common.ps1'
            $bin = Join-Path $root 'scripts/simplified-provisioning'
            Set-Content -LiteralPath (Join-Path $bin 'Invoke-ZtpProvisioning.ps1') -Value @'
[CmdletBinding(SupportsShouldProcess)]
param($ConfigPath, $NodeName, $BmcCredential, $EdgeUserPassword, $InfrastructureFile, $Node, $EventLogPath, $From, [switch]$ConfirmNotClustered, [switch]$SkipCertificateCheck, [switch]$RetryProvisionOs, [switch]$RebuildImages, [switch]$Execute)
$bound = @{}; foreach ($k in $PSBoundParameters.Keys) { $bound[$k] = $PSBoundParameters[$k] }
$global:ztpE_runs.Add([pscustomobject]@{ Script = 'Invoke-ZtpProvisioning.ps1'; Params = $bound })
'@
            $global:ztpE_calls.Clear(); $global:ztpE_runs.Clear()
            $infra = New-TestInfrastructureV5 -Name "exec-$Name" -Edit $Edit
            $thrown = try { $null = & (Join-Path $bin 'Invoke-ZtpEnvironment.ps1') -InfrastructureFile $infra -Node node-01 -Execute *>&1; '' } catch { $_.Exception.Message }
            $thrown
        }
    }
    AfterAll { $env:AZL_TOOLKIT_ROOT = $script:savedToolkitRoot54d }

    It 'creates the resource group by default' {
        Invoke-ExecuteCase -Name 'rg-default' | Should -Be ''
        $global:ztpE_calls | Should -Contain 'New-AzResourceGroup rg-example'
    }

    It 'stops, creating nothing, when create_resource_group is false and the group is missing' {
        $thrown = Invoke-ExecuteCase -Name 'rg-off' -Edit { param($d) $d.provisioning.simplified['create_resource_group'] = $false }
        $thrown | Should -BeLike '*Resource group rg-example doesn''t exist, and provisioning.simplified.create_resource_group is false*'
        $global:ztpE_calls | Should -Not -Contain 'New-AzResourceGroup rg-example'
        $global:ztpE_runs.Count | Should -Be 0
    }

    It 'passes the certificate check and the retry choice to the stages: self-signed accepted and one retry by default, as always' {
        Invoke-ExecuteCase -Name 'flags-default' | Should -Be ''
        $run = $global:ztpE_runs[0].Params
        $run['SkipCertificateCheck'] | Should -BeTrue
        $run['RetryProvisionOs'] | Should -BeTrue
        Invoke-ExecuteCase -Name 'flags-own' -Edit { param($d) $d.hardware.bmc['verify_certificate'] = $true; $d.provisioning.simplified['retry_provision_os'] = $false } | Should -Be ''
        $run = $global:ztpE_runs[0].Params
        $run['SkipCertificateCheck'] | Should -BeFalse
        $run['RetryProvisionOs'] | Should -BeFalse
    }
}

Describe 'Derived BIOS: hardware-safety rules (restore target, shared slots, per-HBA attribute, switches, conflicts)' {
    BeforeAll {
        $script:savedToolkitRoot54e = $env:AZL_TOOLKIT_ROOT
        $env:AZL_TOOLKIT_ROOT = Join-Path $TestDrive 'no-toolkit-here'
        $script:oemRoot2 = Join-Path $script:repoRoot 'config/oem'
        function New-SafeFile {
            param([string]$Name = [guid]::NewGuid().ToString('N'), [scriptblock]$Edit, [string]$Vendor = 'Dell', [switch]$NoHba)
            $script:safeEdit = $Edit; $script:safeVendor = $Vendor; $script:safeNoHba = [bool]$NoHba
            New-TestInfrastructureV5 -Name "safe-$Name" -Edit {
                param($d)
                $d.hardware.vendor = $script:safeVendor
                if (-not $script:safeNoHba) { foreach ($n in $d.nodes) { $n['san'] = [ordered]@{ hbas = @([ordered]@{ slot = 'Slot 2'; type = 'fibre_channel' }) } } }
                if ($script:safeEdit) { & $script:safeEdit $d }
            }
        }
        function Read-Safe { param([string]$File) Read-ZtpInfrastructure -Path $File }
        function Get-SafeText { param([string]$Path) try { Assert-ZtpEnvironment -Environment (Read-ZtpInfrastructure -Path $Path) -Source 'infra.yml' -InformationAction SilentlyContinue; '' } catch { $_.Exception.Message } }
        function Format-Safe { param($Bios) @($Bios.Keys | ForEach-Object { "$_=$($Bios[$_])" }) -join ',' }
    }
    AfterAll { $env:AZL_TOOLKIT_ROOT = $script:savedToolkitRoot54e }

    It 'leaves the derived slot out of the final state, so Restore puts back what Boot found, with the exception recorded' {
        $e = Read-Safe (New-SafeFile -Name 'restore-target')
        $derived = Get-ZtpDerivedBios -Environment $e -Node $e.cluster_nodes[0]
        $derived.Final.Contains('Slot2') | Should -BeFalse
        $derived.During['Slot2'] | Should -Be 'Disabled'
        "$($derived.Fallback['Slot2'].when_found) $($derived.Fallback['Slot2'].restore)" | Should -Be 'Disabled Enabled'
        # An explicit final value for the slot wins and needs no exception.
        $own = Read-Safe (New-SafeFile -Name 'restore-explicit' -Edit { param($d) $d.hardware['bios'] = [ordered]@{ Slot2 = 'BootDriverDisabled' } })
        $x = Get-ZtpDerivedBios -Environment $own -Node $own.cluster_nodes[0]
        $x.Fallback.Count | Should -Be 0
        Format-Safe (Get-ZtpEnvironmentBios -Environment $own -Node $own.cluster_nodes[0] -Kind final) | Should -Be 'EmbNic1Nic2=Enabled,Slot2=BootDriverDisabled'
    }

    It 'stops when a network port only CONTAINS the HBA''s slot number: <Label>' -ForEach @(
        @{ Label = 'Slot 2 Port 1' }, @{ Label = 'PCIe Slot 2' }, @{ Label = 'Riser 1 Slot 2' }, @{ Label = 'slot_2' }, @{ Label = 'SLOT-2 (rear)' }
    ) {
        $script:looseLabel = $Label
        $file = New-SafeFile -Name 'loose' -Edit { param($d) $d.nodes[0].network_adapters += [ordered]@{ name = 'Extra Port'; mac_address = '02:00:00:00:00:99'; slot = $script:looseLabel; roles = @('compute'); ip_assignment = 'none' } }
        (Get-SafeText $file) | Should -BeLike "*nodes[[]0] (node-01).san.hbas[[]0] is in Slot 2, which also holds the network port 'Extra Port'*"
    }

    It 'lets a NIC in another slot through, including one whose number only starts like the HBA''s (Slot 22)' {
        $script:looseLabel = 'Slot 22 Port 1'
        $e = Read-Safe (New-SafeFile -Name 'other-slot' -Edit { param($d) $d.nodes[0].network_adapters += [ordered]@{ name = 'Extra Port'; mac_address = '02:00:00:00:00:98'; slot = $script:looseLabel; roles = @('compute'); ip_assignment = 'none' } })
        @(Test-ZtpEnvironment -Environment $e) | Should -BeNullOrEmpty
        $script:looseLabel = 'Slot 3 Port 2'
        $e = Read-Safe (New-SafeFile -Name 'slot-3' -Edit { param($d) $d.nodes[0].network_adapters += [ordered]@{ name = 'Extra Port 3'; mac_address = '02:00:00:00:00:97'; slot = $script:looseLabel; roles = @('compute'); ip_assignment = 'none' } })
        @(Test-ZtpEnvironment -Environment $e) | Should -BeNullOrEmpty
    }

    It 'warns, without stopping, about a port in an OCP or riser position that has no slot number' {
        $script:looseLabel = 'OCP 1'
        $e = Read-Safe (New-SafeFile -Name 'ocp' -Edit { param($d) $d.nodes[0].network_adapters += [ordered]@{ name = 'OCP Port'; mac_address = '02:00:00:00:00:96'; slot = $script:looseLabel; roles = @('compute'); ip_assignment = 'none' } })
        @(Test-ZtpEnvironment -Environment $e) | Should -BeNullOrEmpty
        @(Get-ZtpDerivedBiosPlan -Environment $e -Node 'node-01' | Where-Object { $_ -like "*BIOS warning: the network port 'OCP Port' is in 'OCP 1', which has no slot number*" }).Count | Should -Be 1
    }

    It 'with no vendor mapping, isolates only an HBA that names its own attribute, and an unrelated explicit key no longer excuses the rest' {
        $both = Read-Safe (New-SafeFile -Name 'one-own' -Vendor 'Contoso' -Edit { param($d)
                $d.nodes[0].san.hbas += [ordered]@{ slot = 'Slot 4'; bios_attribute = 'PciSlot4'; bios_disabled_value = 'Off' }
                $d.hardware['bios_during_provisioning'] = [ordered]@{ SriovGlobalEnable = 'Disabled' }
            })
        $derived = Get-ZtpDerivedBios -Environment $both -Node $both.cluster_nodes[0]
        Format-Safe $derived.During | Should -Be 'PciSlot4=Off'
        @($derived.Problems).Count | Should -Be 1 -Because 'the Slot 2 HBA has neither a mapping nor its own attribute'
        $derived.Problems[0] | Should -BeLike '*san.hbas[[]0] is in Slot 2*no BIOS slot mapping*bios_attribute*'
        $derived.Fallback['PciSlot4'].restore | Should -Be 'Enabled' -Because 'the default enabled value when neither the HBA nor a mapping gives one'
    }

    It 'lets an HBA''s own attribute and values override the vendor mapping' {
        $e = Read-Safe (New-SafeFile -Name 'own-over-mapping' -Edit { param($d) $d.nodes[0].san.hbas[0]['bios_attribute'] = 'SlotX'; $d.nodes[0].san.hbas[0]['bios_enabled_value'] = 'On'; $d.nodes[0].san.hbas[0]['bios_disabled_value'] = 'Off' })
        $derived = Get-ZtpDerivedBios -Environment $e -Node $e.cluster_nodes[0]
        Format-Safe $derived.During | Should -Be 'SlotX=Off'
        $derived.Fallback['SlotX'].restore | Should -Be 'On'
        # An explicit bios_during_provisioning key for the same attribute still wins.
        $win = Read-Safe (New-SafeFile -Name 'own-explicit' -Edit { param($d) $d.nodes[0].san.hbas[0]['bios_attribute'] = 'SlotX'; $d.nodes[0]['bios_during_provisioning'] = [ordered]@{ SlotX = 'Hidden' } })
        Format-Safe (Get-ZtpEnvironmentBios -Environment $win -Node $win.cluster_nodes[0] -Kind provisioning) | Should -Be 'SlotX=Hidden'
    }

    It 'accepts an HBA label that is not a slot when the HBA names its attribute' {
        $e = Read-Safe (New-SafeFile -Name 'ocp-hba' -Vendor 'Contoso' -Edit { param($d) $d.nodes[0].san.hbas[0].slot = 'OCP 2'; $d.nodes[0].san.hbas[0]['bios_attribute'] = 'OcpSlot'; $d.nodes[1].san.hbas[0]['bios_attribute'] = 'PciSlot2' })
        @(Test-ZtpEnvironment -Environment $e) | Should -BeNullOrEmpty
        Format-Safe (Get-ZtpDerivedBios -Environment $e -Node $e.cluster_nodes[0]).During | Should -Be 'OcpSlot=Disabled'
    }

    It 'decides per node: a node without HBAs gets none, whatever the other nodes list, and a node with them is isolated whatever the environment lists' {
        $e = Read-Safe (New-SafeFile -Name 'per-node' -Edit { param($d) $d.nodes[1].Remove('san') })
        (Get-ZtpDerivedBios -Environment $e -Node $e.cluster_nodes[0]).During.Count | Should -Be 1
        (Get-ZtpDerivedBios -Environment $e -Node $e.cluster_nodes[1]).During.Count | Should -Be 0
        $alone = [ordered]@{ hardware = $e.hardware; ztp = [ordered]@{}; cluster_nodes = @() }
        Format-Safe (Get-ZtpDerivedBios -Environment $alone -Node $e.cluster_nodes[0]).During | Should -Be 'Slot2=Disabled'
    }

    It 'reads the switches strictly: true and false in any case are booleans, 0 and yes are problems' {
        ConvertTo-ZtpBoolean $true | Should -BeTrue
        ConvertTo-ZtpBoolean 'true' | Should -BeTrue; ConvertTo-ZtpBoolean 'TRUE' | Should -BeTrue
        ConvertTo-ZtpBoolean 'false' | Should -BeFalse; ConvertTo-ZtpBoolean 'False' | Should -BeFalse; ConvertTo-ZtpBoolean ' FALSE ' | Should -BeFalse
        foreach ($bad in '0', '1', 'yes', 'no', '', 2, @('x')) { { ConvertTo-ZtpBoolean $bad 'some.key' } | Should -Throw "some.key must be true or false*" }
    }

    It 'treats the string ''false'' as false for isolate_san_adapters and enable_embedded_nics, never as true' {
        foreach ($text in 'false', 'False', 'FALSE') {
            $script:switchText = $text
            $e = Read-Safe (New-SafeFile -Name 'str-false' -Edit { param($d) $d.provisioning.simplified['isolate_san_adapters'] = $script:switchText; $d.provisioning.simplified['enable_embedded_nics'] = $script:switchText })
            @(Test-ZtpEnvironment -Environment $e) | Should -BeNullOrEmpty
            $derived = Get-ZtpDerivedBios -Environment $e -Node $e.cluster_nodes[0]
            $derived.During.Count | Should -Be 0; $derived.Final.Count | Should -Be 0
        }
    }

    It 'names the key when a switch is not a boolean: <Value>' -ForEach @(@{ Value = '0' }, @{ Value = 'yes' }, @{ Value = 'off' }) {
        $script:switchText = $Value
        foreach ($key in 'isolate_san_adapters', 'enable_embedded_nics', 'create_resource_group', 'apply_site_settings', 'retry_provision_os', 'skip_azure_check', 'include_preview') {
            $script:switchKey = $key
            $text = Get-SafeText (New-SafeFile -Name 'bad-switch' -Edit { param($d) $d.provisioning.simplified[$script:switchKey] = $script:switchText })
            $text | Should -BeLike "*provisioning.simplified.$key must be true or false, not '$Value'*" -Because $key
        }
        $text = Get-SafeText (New-SafeFile -Name 'bad-bmc' -Edit { param($d) $d.hardware.bmc['verify_certificate'] = $script:switchText })
        $text | Should -BeLike "*hardware.bmc.verify_certificate must be true or false, not '$Value'*"
    }

    It 'rejects two derivations that target one attribute with different values' {
        $dir = Join-Path $TestDrive 'oem-conflict'; $null = New-Item -ItemType Directory -Force -Path $dir
        Set-Content -LiteralPath (Join-Path $dir 'dell.json') -Value '{ "oem": "Dell", "bios": { "slot_attribute": "EmbNic{n}Nic2", "disabled": "Disabled", "enabled": "Enabled", "embedded_nic_attribute": "EmbNic1Nic2", "embedded_enabled": "Enabled" } }'
        $e = Read-Safe (New-SafeFile -Name 'conflict' -Edit { param($d) $d.nodes[0].san.hbas[0].slot = 'Slot 1' })
        $derived = Get-ZtpDerivedBios -Environment $e -Node $e.cluster_nodes[0] -ConfigRoot $dir
        @($derived.Problems).Count | Should -Be 1
        $derived.Problems[0] | Should -BeLike '*one BIOS attribute, EmbNic1Nic2, both to the slot of a SAN adapter (value Disabled for the install) and to the embedded NICs (value Enabled)*'
    }

    It 'ignores a duplicate HBA row for the same slot with a warning, and rejects two rows that disagree' {
        $dup = Read-Safe (New-SafeFile -Name 'dup' -Edit { param($d) $d.nodes[0].san.hbas += [ordered]@{ slot = 'slot2'; model = 'Same card twice' } })
        $derived = Get-ZtpDerivedBios -Environment $dup -Node $dup.cluster_nodes[0]
        @($derived.Problems).Count | Should -Be 0
        Format-Safe $derived.During | Should -Be 'Slot2=Disabled'
        @($derived.Plan | Where-Object { $_ -like '*BIOS warning: nodes[[]0].san.hbas[[]1] (slot2) targets Slot2, which an earlier adapter already isolates; the duplicate row is ignored.' }).Count | Should -Be 1
        $clash = Read-Safe (New-SafeFile -Name 'clash' -Edit { param($d) $d.nodes[0].san.hbas[0]['bios_attribute'] = 'SlotX'; $d.nodes[0].san.hbas += [ordered]@{ slot = 'Slot 4'; bios_attribute = 'SlotX'; bios_disabled_value = 'Off' } })
        (Get-ZtpDerivedBios -Environment $clash -Node $clash.cluster_nodes[0]).Problems[0] | Should -BeLike '*both target the BIOS attribute SlotX, with different values*'
    }

    It 'warns, and does not block, when the model is not one the Dell mapping was verified on' {
        $ok = Read-Safe (New-SafeFile -Name 'model-ok')
        @((Get-ZtpDerivedBios -Environment $ok -Node $ok.cluster_nodes[0]).Plan | Where-Object { $_ -like '*slot mapping verified on*' }).Count | Should -Be 0
        $other = Read-Safe (New-SafeFile -Name 'model-other' -Edit { param($d) $d.hardware.model = 'AX-650' })
        $derived = Get-ZtpDerivedBios -Environment $other -Node $other.cluster_nodes[0]
        @($derived.Problems).Count | Should -Be 0
        $derived.During['Slot2'] | Should -Be 'Disabled'
        @($derived.Plan | Where-Object { $_ -like 'PLAN: node-01 BIOS warning: slot mapping verified on: AX-760; for AX-650 confirm that attribute Slot2, EmbNic1Nic2 controls the adapter''s slot before running.' }).Count | Should -Be 1
        $none = Read-Safe (New-SafeFile -Name 'model-none' -Edit { param($d) $d.hardware.Remove('model') })
        @((Get-ZtpDerivedBios -Environment $none -Node $none.cluster_nodes[0]).Plan | Where-Object { $_ -like '*for an unspecified model (hardware.model)*' }).Count | Should -Be 1
    }

    It 'handles an embedded port that only has the role provisioning, and names the management port when there is one' {
        $e = Read-Safe (New-SafeFile -Name 'embedded-prov' -NoHba -Edit { param($d)
                foreach ($p in $d.nodes[0].network_adapters) { if ($p.slot -eq 'Embedded') { $p.slot = 'Slot 1' } }
                $d.nodes[0].network_adapters += [ordered]@{ name = 'LOM 3'; mac_address = '02:00:00:00:00:95'; slot = 'Embedded'; roles = @('provisioning'); ip_assignment = 'none' }
            })
        $derived = Get-ZtpDerivedBios -Environment $e -Node $e.cluster_nodes[0]
        @($derived.Problems).Count | Should -Be 0
        Format-Safe $derived.Final | Should -Be 'EmbNic1Nic2=Enabled'
        $derived.Plan | Should -Contain "PLAN: node-01 BIOS EmbNic1Nic2 Enabled because the provisioning port 'LOM 3' of nodes[0] is in slot Embedded (the OS can't see disabled embedded NICs)"
        $both = Read-Safe (New-SafeFile -Name 'embedded-both' -NoHba -Edit { param($d) $d.nodes[0].network_adapters += [ordered]@{ name = 'LOM 3'; mac_address = '02:00:00:00:00:94'; slot = 'Embedded'; roles = @('provisioning'); ip_assignment = 'none' } })
        (Get-ZtpDerivedBios -Environment $both -Node $both.cluster_nodes[0]).Plan[0] | Should -BeLike "*the management port 'Embedded NIC 1' of nodes[[]0]*"
    }
}
