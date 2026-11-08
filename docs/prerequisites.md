# Prerequisites

> Everything that must be in place before a ZTP run, and every value the environment file needs. Each item says whether ZTP checks it, and where, or whether you do it.

ZTP ends at the Handoff: each machine is Provisioned in Azure and Arc-connected, with its management address on the management port. OEM drivers, an SBE (optional, only when a person asks for it), DHCP off on the other ports, DNS and time on the host, and the deployment admin are OS configuration, which comes next ([Phase 03 OS Configuration](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/)). This page lists only what ZTP needs.

**Checked by ZTP** means the run fails, or warns, with a message that names the problem. **You do this** means ZTP doesn't check it, and a gap shows up later as a failed stage.

## Before you run

- [ ] Start the environment file from the [ZTP-only template](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/config/variables/examples/infrastructure.ztp.example.yml) (schema 5.3 or later, `_metadata.scope: ztp`; `New-InfrastructureArtifacts.ps1 -Cut ztp -From <file>` in the toolkit cuts a full file down to what ZTP reads), or from the [full template](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/config/variables/examples/infrastructure.example.yml) if OS configuration and deployment follow. Keep it outside this repository. Fill every value in [Values you need](#values-you-need).
- [ ] The `AzureLocalZTP` feature and the resource providers are registered in the subscription ([Azure](#azure)).
- [ ] Your account has the roles on the resource group and the Key Vault ([Roles](#roles)).
- [ ] The Key Vault uses the Azure RBAC permission model and holds the provisioning admin password and the BMC login ([Key Vault](#key-vault)).
- [ ] The management host has PowerShell 7, the Az modules, `powershell-yaml` and the Azure CLI with Bicep, and you run elevated ([Operator host](#operator-host)).
- [ ] `media_path` and `evidence_path` are outside any git repository, on a disk with room ([Paths](#paths)).
- [ ] DHCP answers on the provisioning network, and the ports in [Network](#network) are open.
- [ ] The BMCs have Redfish and virtual media, and the BIOS settings are in the file ([Hardware](#hardware)).
- [ ] Nothing on the machines needs to be kept: the run **reinstalls** every node you name.

Then run the plan (without `-Execute`). It reads the file, runs every check that doesn't change anything, and prints what it would do.

## Azure

### Subscription and region

| Item | Detail | Who |
| --- | --- | --- |
| A subscription for the site and the edge machines | `azure.subscription_id` (or `provisioning.simplified.subscription_id`). | Checked by ZTP: the key check (`Test-ZtpEnvironment`) requires a GUID. |
| Region | The provisioning resources (site configuration, edge machines) are in **East US** only in the preview. The resource group can be in any region, but if the run creates it, it uses `azure.location`. Set `azure.location: eastus`. ([Learn: Azure prerequisites](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#azure-prerequisites)) | You do this. The Bootstrap stage reads the OS image catalog of `azure.location` and fails when it's empty or unreadable. |
| The resource group | `azure.resource_group`. `Invoke-ZtpEnvironment.ps1` creates it when it's missing. | Checked by ZTP (the Azure stage creates or uses it). |
| No policy that requires tags | Learn: a policy that *requires* tags isn't supported ([troubleshooting](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning#when-you-provision-new-machines-you-receive-an-internal-server-error)). | You do this. |

### Resource providers and features

Register these once per subscription. That needs Owner or Contributor on the subscription; the run itself only reads the registration.

| Feature or provider | Why | Who |
| --- | --- | --- |
| Feature `Microsoft.DeviceOnboarding/AzureLocalZTP` | Simplified machine provisioning (the voucher claim). | Checked by ZTP: the Bootstrap stage (`Get-ZtpAzureReadiness` in `ZtpEvents.Common.ps1`, called by `Wait-ZtpBootstrapComplete.ps1`). A node doesn't reach `ReadyForPortal` until it reads `Registered`. |
| `Microsoft.AzureStackHCI` | `edgeMachines` (the claim), their jobs and network adapters, and the OS image catalog (`locations/<region>/osImages`). | Checked by ZTP: Bootstrap stage, same check. |
| `Microsoft.Edge` | The site (`Microsoft.Edge/sites`), the site configuration (`Microsoft.Edge/configurations` and its network, time, connectivity and security settings) and `configurationReferences` (`bicep/main.bicep`). | Checked by ZTP: Bootstrap stage, same check. |
| `Microsoft.HybridCompute` | The Arc machines the provisioning creates. | Checked by ZTP: Bootstrap stage, same check. |
| `Microsoft.DeviceOnboarding` | The ownership voucher service. | Checked by ZTP: Bootstrap stage, same check. |
| `Microsoft.GuestConfiguration`, `Microsoft.HybridConnectivity`, `Microsoft.KeyVault`, `Microsoft.ManagedIdentity`, `Microsoft.PolicyInsights`, `Microsoft.Storage`, `Microsoft.Insights` | Learn lists them for simplified machine provisioning ([Learn: Azure prerequisites](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#azure-prerequisites)). The template also uses `Microsoft.KeyVault` (the vault) and `Microsoft.Authorization` (role assignments). | You do this. ZTP doesn't check them. |

```powershell
Register-AzProviderFeature -ProviderNamespace Microsoft.DeviceOnboarding -FeatureName AzureLocalZTP
'Microsoft.AzureStackHCI', 'Microsoft.Edge', 'Microsoft.HybridCompute', 'Microsoft.DeviceOnboarding',
'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity', 'Microsoft.KeyVault', 'Microsoft.ManagedIdentity',
'Microsoft.PolicyInsights', 'Microsoft.Storage', 'Microsoft.Insights' | ForEach-Object { Register-AzResourceProvider -ProviderNamespace $_ }

# Check: every line should read Registered.
(Get-AzProviderFeature -ProviderNamespace Microsoft.DeviceOnboarding -FeatureName AzureLocalZTP).RegistrationState
'Microsoft.AzureStackHCI', 'Microsoft.Edge', 'Microsoft.HybridCompute', 'Microsoft.DeviceOnboarding' |
    ForEach-Object { "$_ $((Get-AzResourceProvider -ProviderNamespace $_).RegistrationState | Select-Object -First 1)" }
```

The Azure CLI equivalent of the feature registration is `az feature register --subscription <subscription-id> --namespace Microsoft.DeviceOnboarding --name AzureLocalZTP`.

### Roles

The full cross-tool matrix is in the toolkit's [access-and-connectivity page](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/docs/access-and-connectivity.md).

The account that runs ZTP (you, a service principal, or a pipeline's managed identity) needs these. ZTP doesn't check roles up front: a missing role fails the ARM template validation or the call that needs it, with Azure's message.

| Scope | Role | Why | Source |
| --- | --- | --- | --- |
| The resource group of the site and edge machines | **Owner**, or **Contributor** and **Role Based Access Control Administrator** | The deployment creates the site, the site configuration and the edge machines, and role assignments: the Azure Local resource provider's role and each edge machine's delegation. | `Invoke-ZtpEnvironment.ps1` and `Invoke-ZtpAzureProvisioning.ps1` headers; `bicep/main.bicep`; [Learn](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#azure-prerequisites) |
| The site | None of its own. The `Microsoft.Edge` site and its configuration are in that resource group, so the group's roles cover them. | | `bicep/main.bicep` |
| The subscription | **Reader** | The Bootstrap stage reads the feature and provider registration and the OS image catalog; the Ready stage reads the Arc machines, which are in the site configuration's managed resource group. | `ZtpEvents.Common.ps1` (`Get-ZtpAzureReadiness`), `Test-ProvisionedMachines.ps1` |
| The subscription | **Contributor**, only if the resource group doesn't exist yet. Or create the group first. | `Invoke-ZtpEnvironment.ps1` creates a missing group. | `Invoke-ZtpEnvironment.ps1` (`New-AzResourceGroup`) |
| Every vault a `keyvault://` reference names | **Key Vault Secrets User** | The run reads the BMC login and the `edgeuser` password, and checks that the provisioning admin secret exists. | `Invoke-ZtpEnvironment.ps1`, `Invoke-ZtpAzureProvisioning.ps1` (Plan) |
| The vault that holds the provisioning admin password, and its resource group | **Owner**, or **Contributor** and **Role Based Access Control Administrator**, on that resource group | The template deploys a nested deployment into the vault's resource group (`bicep/modules/key-vault-delegation.bicep`) that assigns each edge machine a role on the vault. If the vault is in the cluster resource group, the group's roles above cover this. | `bicep/main.bicep` (`keyVaultDelegation`), `bicep/modules/key-vault-delegation.bicep` |

The template assigns these itself; you don't create them:

| Principal | Role and scope | Why |
| --- | --- | --- |
| The Azure Local resource provider (`azure.hci_resource_provider_object_id`) | **Azure Connected Machine Resource Manager** on the resource group | What the portal assigns. If your landing zone already holds this assignment under another name, the deployment fails with `RoleAssignmentExists`. |
| Each edge machine's system-assigned identity | **Role Based Access Control Administrator** on the resource group, limited by an ABAC condition to assigning only **Azure Connected Machine Resource Administrator** | The service sets up the target Arc machine's permissions. |
| Each edge machine's system-assigned identity | **Role Based Access Control Administrator** on the vault, limited by an ABAC condition to assigning only **Key Vault Secrets User** | The service lets the target Arc machine read the provisioning admin password during the OS install. |

For a pipeline, see [Running from a pipeline](automation-pipelines.md#identity).

### The Azure Local resource provider object ID

`azure.hci_resource_provider_object_id` is the object ID of the Azure Local resource provider's service principal in your tenant (application ID `1412d89f-b8a8-4111-b4fd-e82905cbd85d`). The template assigns it its role on the resource group.

Optional. Without it, `Invoke-ZtpEnvironment.ps1` looks it up with `Get-AzADServicePrincipal`, which needs directory read rights. A managed identity doesn't have those by default, so set it for pipelines. Look it up once with an account that can read the directory:

```powershell
(Get-AzADServicePrincipal -ApplicationId '1412d89f-b8a8-4111-b4fd-e82905cbd85d').Id
```

Checked by ZTP: the key check requires a GUID when the key is set; the run stops with `Set ztp.azl_rp_object_id` when the lookup finds nothing.

### The site's network setting

ZTP sets the site's network setting from `networking.management.static_method`; you don't set it in the portal.

- `static_method: device` (the default): the site is **Automatic**, and the claim carries no Manual adapter. The Device stage sets each static management address by MAC in the maintenance environment before the claim.
- `static_method: site`: the site is **Manual** over `networking.management.site_ip_range` (default: the lowest to the highest node address), with the gateway, DNS servers, mask and VLAN of the management network, and each claim carries a Manual adapter keyed by MAC. Use it only without the Device stage: the OS install puts the address on the first ready port and ignores the MAC, and the Network stage moves it afterwards.

Checked by ZTP: the key check refuses any other value, and with `site` every static node address must be inside `site_ip_range`. See [The site's network setting](environment-file.md#the-sites-network-setting).

## Key Vault

| Item | Detail | Who |
| --- | --- | --- |
| Azure RBAC permission model | The template delegates **Key Vault Secrets User** on the vault, so the vault must use Azure RBAC, not access policies. | You do this. |
| Public network access during provisioning | Keep it on while machines provision and deploy. Learn says this for deployment ([decision 10](https://learn.microsoft.com/azure/azure-local/plan/cloud-deployment-network-considerations#decision-10-determine-outbound-connectivity)). | You do this. |
| Every vault listed | Each vault a `keyvault://` reference names is in `key_vaults[]`, with its `subscription_id` and `resource_group`. | Checked by ZTP: `Test-ZtpInfrastructureV5`. |
| References only | Every secret in the file is `keyvault://<vault>/<secret>`. The file holds no secret values. | Checked by ZTP for `provisioning.simplified.admin.password`, `hardware.bmc.password` and `maintenance_password`: without a `keyvault://` reference the key check finds no vault and secret name, and fails. `hardware.bmc.username` may be the plain user name, which isn't a secret. |

### The secrets

| Secret | Key | Purpose | Who |
| --- | --- | --- | --- |
| Provisioning admin password | `provisioning.simplified.admin.password` | The local administrator the OS install creates (`admin.username`). The template passes only the secret's resource ID; the machine reads the value through the delegation. Learn asks for at least 12 characters with lowercase, uppercase, a digit and a special character ([provision machines](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#step-3-provision-machines-from-azure)). | You do this: **create it before the run**. The Azure stage's plan checks that it exists, by name, and the run stops if it's missing. |
| BMC user name | `hardware.bmc.username` | The BMC account (or give the name itself instead of a reference). | You do this. Read at the start of `-Execute`; a missing secret fails the run there, before any stage. |
| BMC password | `hardware.bmc.password` | The BMC account's password. | You do this. Checked by ZTP: required (`Test-ZtpInfrastructureV5`); read at the start of `-Execute`. |
| `edgeuser` password | `provisioning.simplified.maintenance_password` | Optional. The maintenance environment's `edgeuser` password: the Media stage writes its hash into each image, and the Device stage signs in with it. Without it the image keeps Learn's default, `Password1`, which works for anyone who reaches TCP 20001 while the maintenance environment runs. | You do this. Read at the start of `-Execute`. |

### Vaults in another subscription

The vault can be in another subscription and resource group than the site: the template reads the secret by its resource ID in `key_vaults[].subscription_id`, and deploys the vault delegation into that subscription's resource group (`bicep/modules/key-vault-delegation.bicep`). ZTP reads all its secrets in **one** subscription, the one of the provisioning admin's vault: the BMC login and the `edgeuser` password must be in vaults of that same subscription. Checked by ZTP: `Test-ZtpInfrastructureV5` names a secret in another subscription.

## Operator host

The management host runs the whole run. It must reach the BMCs, the provisioning network and the internet.

| Item | Detail | Who |
| --- | --- | --- |
| Windows | The share, the local account and the firewall rule are Windows features (`New-SmbShare`, `New-LocalUser`, `New-NetFirewallRule`). | You do this. |
| PowerShell 7 | Every script has `#Requires -Version 7.0`. | Checked by ZTP: PowerShell refuses to start a script on an older version. |
| `powershell-yaml` | `Install-Module powershell-yaml -Scope AllUsers` | Checked by ZTP: `Invoke-ZtpEnvironment.ps1` has `#Requires -Modules powershell-yaml`. |
| Az modules: `Az.Accounts`, `Az.Resources`, `Az.KeyVault`, `Az.ConnectedMachine` | `Install-Module Az.Accounts, Az.Resources, Az.KeyVault, Az.ConnectedMachine -Scope AllUsers`. Used for: sign-in, context and ARM calls (`Connect-AzAccount`, `Set-AzContext`, `Invoke-AzRestMethod`); the resource group, the deployment, its what-if and the resource provider lookup (`New-AzResourceGroup`, `New-AzResourceGroupDeployment`, `Get-AzADServicePrincipal`); the secrets (`Get-AzKeyVaultSecret`); the Arc machines (`Get-AzConnectedMachine`, `Get-AzConnectedMachineExtension`). The code states no minimum versions. | Checked by ZTP for `az`, `Get-AzContext`, `New-AzResourceGroupDeployment` and `Get-AzKeyVaultSecret`: the Azure stage's Prereqs. |
| Azure CLI with Bicep | Install the Azure CLI, then `az bicep install`. `Invoke-ZtpEnvironment.ps1` adds `$HOME\.azure\bin` to `PATH` so Az PowerShell finds that Bicep. | Checked by ZTP: the Azure stage's Prereqs runs `az bicep version`, and Validate builds the template. |
| Pester 5 | Only to run the tests: `Install-Module Pester -MinimumVersion 5.0 -Scope AllUsers`. | You do this. Not needed for a run. |
| An azurelocal-toolkit clone | Optional. Next to this repository (`..\azurelocal-toolkit`), or named by `$env:AZL_TOOLKIT_ROOT`, it lets ZTP run the toolkit's schema 5 validator first. | Optional. Without it, only ZTP's own checks run. |
| Run elevated | The Boot stage creates the SMB share, a local account and a firewall rule (`Publish-MaintenanceIso.ps1`), and the Media stage mounts the ISO with `Mount-DiskImage` (`New-ZtpVirtualUsbImage.ps1`). | You do this. A non-elevated run fails at those calls. |
| The SMB share for the virtual USB | `provisioning.simplified.media_share.name`, and `host` (the host's address as the BMCs reach it) or `host_adapter` (the adapter whose address they reach, for example a VPN adapter). The share is created in place over the images folder, read-write for one generated account, with TCP 445 inbound only from the BMC addresses. It's removed after the Vouchers stage. | Checked by ZTP: the key check requires the name and one of `host` or `host_adapter`. |
| A session that lasts | The run takes hours: two nodes took about 1.5 to 2 hours on live runs. Use a session that won't end or sleep, or a [pipeline](automation-pipelines.md). | You do this. |

## Paths

| Path | What's there | Default |
| --- | --- | --- |
| `provisioning.simplified.media_path` | `bootstrap\<version>\` (the ISO download and the extracted `provision-os.iso`), `ztp-virtual-usb\` (one `ztp-usb-<node>.img` per node, 4 GiB each), `vouchers\` (`<serial>.pem`), `ztp-state\` (the run state) | `%ProgramData%\AzureLocalZtp\<site_name>\media` |
| `provisioning.simplified.evidence_path` | `ztp-events.jsonl` (the event log monitors follow), `bios-changes.jsonl`, `device-changes.jsonl`, `network-changes.jsonl`, and `<run>.<time>.transcript.log` for each `-Execute` run | `%ProgramData%\AzureLocalZtp\<site_name>\evidence` |

- **Outside any git repository.** Checked by ZTP: the key check refuses a path inside a git working tree, and `Resolve-ZtpDataPath` refuses one again (from the file, from `-MediaPath` / `-EvidencePath`, or from the default) before anything is written. Both must be full paths. The run creates the folders.
- **Disk space.** The maintenance ISO archive is about 1.4 GB (train 2610: 1.39 GB) and the ISO inside it about 1.34 GB; the download checks for twice the archive size plus 256 MB free before it starts. Each node's image is 4 GiB (`New-ZtpVirtualUsbImage.ps1`'s default size). Plan for about 3 GB plus 4 GiB per node in `media_path`: about 11 GB for two nodes, about 19 GB for four. Vouchers, state and evidence are small. Checked by ZTP for the download only (`Get-ZtpBootstrapIso.ps1` stops when the volume is short); you check the rest.
- **Restrict `<media_path>\vouchers`.** An ownership voucher claims the machine in Azure. Never commit one. You do this.
- **The state files.** They live in `<media_path>\ztp-state`: `<nodes>.ztp-provisioning.state.json` (the completed stages, each stage's evidence, the Network stage's result and the BIOS originals the Boot stage saved, `biosOriginal`), plus the handoff, the cluster inputs and the Arc-name map. `<nodes>` is the run's node names joined with `+`, for example `node-01+node-02`. A rerun skips the stages the state file records as completed, so **deleting or moving it forces a run from the start**, and it loses the saved BIOS originals: the Restore stage then can't set back a key that `hardware.bios` doesn't name, and stops. Keep the folders where they are for the life of the machines' provisioning.

## Network

### DHCP and addresses

| Item | Detail | Who |
| --- | --- | --- |
| DHCP on the provisioning network | The maintenance environment takes its address by DHCP, on every port that gets a lease, and reaches Azure from there before the machine is claimed (`networking.management.provisioning_network: dhcp`, the default). A reservation is optional: with one, put the address in `nodes[].maintenance_address` (or on the node's `provisioning` port), and the Device stage goes there directly. Without one, the Device stage finds the node by scanning (verified live, DHCP without a reservation). On a machine whose management network has no DHCP (Mode C), give another port, for example a data port, role `provisioning` on a network that has it. See [Management address modes](#management-address-modes). | You do this. Without DHCP the machine never reaches Azure and no voucher is written; the Bootstrap stage then times out. A static management port with `provisioning_network: static` and no provisioning port on DHCP is an error (AZL-024, G23): validation stops before the hardware is touched. |
| `networking.management.provisioning_dhcp_range` | The DHCP pool, `start` and `end`. The Device stage probes every address in it on TCP 20001, in parallel, for each node without a maintenance address, and takes the answer whose adapters list the node's management MAC. It scans again every poll interval until the node answers, for up to 30 minutes. Default: the whole management subnet. Narrow it to the pool. | Checked by ZTP: the key check requires start before end and at most 4096 addresses. |
| The management IP plan | One address per node, inside `networking.management.subnet`, on the management port named by its MAC (`nodes[].network_adapters[]` with role `management`), with the subnet's gateway, DNS servers and VLAN. **Recommended: Mode A**, a DHCP reservation of each node's `ip_address` for its management MAC (`ip_assignment: dhcp_reservation`). With `static` (Mode B or C) keep the addresses out of the DHCP pool; OS configuration sets them after ZTP. See [Management address modes](#management-address-modes). | Checked by ZTP: the key check requires each static address to be in the subnet, one management port per node, and a valid MAC. You keep the addresses free. |
| DNS servers | `networking.management.dns_servers`. Learn: they can't be changed after deployment ([DNS server considerations](https://learn.microsoft.com/azure/azure-local/plan/cloud-deployment-network-considerations#dns-server-considerations)). | Checked by ZTP: a list of IPv4 addresses. |

### Management address modes

The **management port** is the port the infrastructure file gives role `management` with an `ip_assignment` other than `none`, found by its MAC. It can be any port: an onboard LOM (the example in these docs), a PCIe or ConnectX port, or a converged port. Nothing in ZTP or OS configuration keys off a slot, a vendor or a port name: only the role and the MAC.

How the management port gets its address is one of three modes. Set it with the port's `nodes[].network_adapters[].ip_assignment`; whether the management network has DHCP while the machine is provisioned comes from `networking.management.provisioning_network` and whether the management port also has role `provisioning`.

> **Use Mode A.** DHCP on the management network plus a reservation per node for its management MAC is the only mode where ZTP finishes with every management address correct. Modes B and C are supported, but **the static address isn't in place when ZTP finishes**. Microsoft's OS install resets every port to DHCP (the maintenance environment's network settings don't carry into the OS), and Microsoft's post-install per-NIC API (`networkAdapters/<a>/jobs/ApplyConfiguration`) never started in our tests. OS configuration after ZTP is required to set the static address.

| Mode | DHCP on management? | Reservation? | `ip_assignment` | What ZTP does | The management port after ZTP | What OS configuration does |
| --- | --- | --- | --- | --- | --- | --- |
| **A, Reserved** (recommended) | Yes | Yes | `dhcp_reservation` | Nothing to set. The Network stage verifies the reserved address (`ip_address`; without it, any DHCP address, and the validator warns). | Its reserved address, from DHCP | Leaves DHCP on and verifies the address |
| **B, Static with DHCP** | Yes | No | `static` | The Device stage sets the static by MAC in the maintenance environment, before the claim. The Network stage records `Deferred`. | **A DHCP address**: the install reset it | Sets the static by MAC (Arc Run Command), turns DHCP off on it |
| **C, Static without management DHCP** | No | - | `static` | The same as B. Another port with role `provisioning` must have DHCP; without one the validator stops (AZL-024, G23) before anything touches the hardware. | **No address.** The node stays reachable through Arc over the provisioning port. | Sets the static by MAC over Arc, before it turns DHCP off on any other port |
| `dhcp` | Yes | No | `dhcp` | Reports only. The validator warns: the address can change, and Azure Local needs a stable one. | A DHCP address that can change | Leaves it alone |
| `preconfigured` | - | - | `preconfigured` | Reports only: the operator sets it. | What the operator set | Leaves it alone |

**The other ports.** Every port other than the management port that lands on a DHCP network gets a DHCP address and a default gateway from the install, in every mode. OS configuration turns DHCP and the gateway off on each port the file lists with `ip_assignment: none`, whatever the mode, because validation fails with more than one default gateway. A port the file lists as `dhcp` or `dhcp_reservation` is left on DHCP, and OS configuration stops (Blocked) if it holds a second gateway.

**Telling B from C.** Mode B: `provisioning_network: dhcp` and the management port also has role `provisioning`, so a DHCP server answers on the management network. Mode C: the management port isn't a provisioning port (another port, for example a data port, has role `provisioning` and DHCP), or `provisioning_network: static`, which then needs a port with role `provisioning` and `ip_assignment: dhcp` or `dhcp_reservation`.

**Where you see it.** The Network stage names the mode in each node's reason, for example `Mode B (Static with DHCP): the management port Port1 (MAC 00:00:5e:00:53:aa) has DHCP 192.0.2.116 after the install; expected static 192.0.2.11; OS configuration sets it by MAC.` The handoff carries it per node (`managementMode`, `managementAddressVerified`, `managementAddressReason`) with every port as Azure reports it (`networkAdapters[]`), and the run prints a table per node at the end.

### Ports

The full cross-tool matrix is in the toolkit's [access-and-connectivity page](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/docs/access-and-connectivity.md).

| From | To | Port | Why | Stages |
| --- | --- | --- | --- | --- |
| Management host | Each BMC (`nodes[].bmc.ip_address`) | TCP 443 | Redfish: BIOS settings, virtual media, boot override, power, the BMC log | Boot, Bootstrap, Vouchers, Restore |
| Each BMC | Management host (`media_share.host`) | TCP 445 | SMB: the BMC mounts the node's image from the share and the maintenance environment writes the voucher into it. The BMC connects out from its own address. `Publish-MaintenanceIso.ps1` opens the Windows Firewall inbound from the BMC addresses only; open any firewall in between. | Boot to Vouchers |
| Management host | The provisioning network (`maintenance_address`, or every address of `provisioning_dhcp_range`) | TCP 20001 | HTTPS to the maintenance environment's REST service (self-signed certificate): find the node by MAC and set the static address | Device |
| Management host | The internet | TCP 443 | Azure Resource Manager, Microsoft Entra ID and Key Vault; the maintenance ISO download: `aka.ms/aep/installeros/<YYMM>`, which redirects to `download.prss.microsoft.com` or `download.microsoft.com` (ZTP refuses other hosts) | Resolve, Bootstrap, Azure, Ready, Network, Restore, Handoff |
| The machines (maintenance environment, then the installed OS) | Azure | TCP 443 and 80 | Learn's firewall requirements, with no HTTPS inspection ([Learn: firewall requirements](https://learn.microsoft.com/azure/azure-local/concepts/firewall-requirements)) | Bootstrap to Restore |

The Network stage needs no port to the nodes: it reads Azure's per-NIC report. ZTP uses no WinRM.

**Scan only an isolated provisioning network.** The Device stage signs in as `edgeuser` with the maintenance environment's default password (the one Learn documents, `Password1`, or the one you built into the image) over TLS with the certificate check skipped, to every host that answers on TCP 20001 in the scan range. The maintenance environment can't be certificate-pinned, so a device that imitates the service on that network could receive the password. The password is a documented default and not a secret, but keep the scan to an isolated provisioning network, keep `provisioning_dhcp_range` to the DHCP pool, and prefer `maintenance_address` where you know it. The scan needs dotted-quad IPv4 addresses and a contiguous subnet mask; a /31 or /32 management subnet isn't supported for it. See [Appendix B](appendix/configurator-app-api.md#how-ztp-uses-this-service).

## Hardware

| Item | Detail | Who |
| --- | --- | --- |
| BMC with Redfish over HTTPS | Reachable from the management host. Self-signed certificates are accepted (the entry point sets `SkipCertificateCheck`). | You do this. A BMC that doesn't answer stops the Boot stage. |
| Virtual media on the **USB-stick slot** (`RemovableDisk`) | The image is inserted over CIFS on the USB-stick slot, read-write, so the maintenance environment can write the voucher back. The CD slot isn't used: an ISO on the iDRAC CD slot failed in testing. The end-to-end flow is **proven on Dell AX-760 with iDRAC 7.30**. Lenovo, HPE and Supermicro definitions are layout only; their USB-stick slot handling isn't verified. See [Redfish virtual USB](redfish-virtual-usb-vouchers.md). | Checked by ZTP: `Mount-ZtpVirtualUsb.ps1` reads back that the image is attached and stops if it isn't. |
| iDRAC: the RFS write attribute | On iDRAC 7.30, `InsertMedia` rejects `WriteProtected=false` (`IDRAC.2.9.SYS458`), so ZTP sets the manager attribute `RFS.<n>.WriteProtected` to `Read Write` before the insert and back to `Read Only` on eject. The entry point turns this on (`RfsWriteAttribute`). The firmware must expose the attribute. iDRAC 7.30 also boots the USB-stick slot as virtual floppy; ZTP handles that (`vFDD`, `Once/Floppy`). See [iDRAC quirks](troubleshooting.md#idrac-quirks). | Checked by ZTP: the mount stops with `The iDRAC exposes no RFS.<n>.WriteProtected attribute` when it's missing. |
| A BMC account | One login for every node (`hardware.bmc`) that can insert virtual media, change BMC and BIOS attributes, set the boot override and reset the server. Change the factory default password. | Checked by ZTP: a node's own `bmc` login must equal `hardware.bmc` (`Test-ZtpInfrastructureV5`). You give it the rights. |
| Firmware | BIOS, BMC, CPLD and network adapter firmware matched to the OEM's Azure Local support matrix before you start. ZTP doesn't update firmware ([Learn](https://learn.microsoft.com/azure/azure-local/deploy/deployment-install-os#install-drivers-and-firmware)). | You do this. |
| Secure Boot and TPM on; **Boot USB Devices First** off | Learn: [prepare machines](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#step-2-prepare-machines) and [USB boot loop](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning#usb-boot-loop-issue-with-maintenance-environment). You can set these through `hardware.bios` with your BIOS's attribute names. | You do this. |
| BIOS settings: `hardware.bios` | The machine's **final** BIOS state, set by the Boot stage before the maintenance boot (only what differs, applied at a reset). Names are the attributes of the BMC's Redfish Bios resource, case-sensitive; values are quoted strings. | Checked by ZTP: the key check refuses a non-string value or a bad name; the Boot stage stops before any change if the BIOS doesn't have an attribute. |
| BIOS settings: `hardware.bios_during_provisioning` | **Temporary** values for the install only, merged over `hardware.bios`. The Restore stage sets each back after the Network stage. Example, a Fibre Channel HBA in slot 2 whose SAN LUN the maintenance environment would otherwise offer as the install disk: `hardware.bios: { Slot2: "Enabled", EmbNic1Nic2: "Enabled" }` and `hardware.bios_during_provisioning: { Slot2: "Disabled" }`. The card is off for the install and on again before the handoff. See [BIOS settings](environment-file.md#bios-settings). | Checked by ZTP: same checks; the Restore stage waits until the BIOS reports the values and the machine is Connected again. |
| Dell: LOMs disabled in BIOS | A known trap: the embedded LOM ports can ship as `DisabledOs`, so the OS can't see the management ports. Set `EmbNic1Nic2: "Enabled"` in `hardware.bios`. | You do this. ZTP sets what the file says. |
| The serial number | `nodes[].serial_number`, the machine's service tag on Dell (on the machine's label and the iDRAC dashboard). The maintenance environment writes the voucher to `\vouchers\<serial>\` and the voucher holds it; ZTP maps each voucher to its node by it. | Checked by ZTP: required; the Vouchers stage validates that the voucher holds the node's serial. A wrong serial shows as no voucher for that node. |

## Values you need

Every key ZTP reads, in schema 5 paths (`ConvertFrom-ZtpInfrastructureV5`, `Test-ZtpInfrastructureV5` and `Test-ZtpEnvironment` in `ZtpEnvironment.Common.ps1`). Example values only. "File check" is the check the run does before any stage. For the older layout's names, see the [environment file reference](environment-file.md); for the mapping, [Reading the master infrastructure.yml](infrastructure-schema-5.md).

| Key | Required or optional | Example | Where to get the value | Stage that uses it |
| --- | --- | --- | --- | --- |
| `_metadata.schema_version` | Required, 5.x | `"5.3.0"` | The template | File check (format detection) |
| `_metadata.scope` | Optional | `ztp` | The ZTP-only template | Not read by ZTP; accepted. The toolkit's validator uses it. |
| `scenario.os_install` | Required, `simplified` | `simplified` | The template | File check |
| `azure.tenant_id` | Required | `00000000-0000-0000-0000-000000000000` | `(Get-AzContext).Tenant.Id`, or the Microsoft Entra ID overview in the portal | Every Azure call |
| `azure.subscription_id` | Required, unless `provisioning.simplified.subscription_id` is set | `00000000-0000-0000-0000-000000000000` | `(Get-AzContext).Subscription.Id`, or the portal's Subscriptions page | Bootstrap (Azure check), Azure, Ready, Network, Restore, Handoff |
| `azure.resource_group` | Required, unless `provisioning.simplified.resource_group` is set | `rg-example` | You choose it; created when missing | Azure, Ready, Network, Restore, Handoff |
| `azure.location` | Required | `eastus` | East US in the preview | Bootstrap (OS image catalog), Azure (site configuration, edge machines, a new resource group) |
| `azure.hci_resource_provider_object_id` | Optional | `00000000-0000-0000-0000-000000000000` | `(Get-AzADServicePrincipal -ApplicationId '1412d89f-b8a8-4111-b4fd-e82905cbd85d').Id` | Azure (the resource provider's role) |
| `site.name` | Required | `Example site` | You choose it | Azure (the site's display name) |
| `site.time_zone` | Required | `UTC` | The time zone of the site, in the form the templates use (`UTC`, `Central Standard Time`) | Azure (the site's time setting) |
| `key_vaults[].name` | Required for each vault a reference names | `kv-example` | The portal, or `Get-AzKeyVault` | File check; Azure (secret ID, vault delegation); secret reads at the start of `-Execute` |
| `key_vaults[].subscription_id` | Required for each vault | `00000000-0000-0000-0000-000000000000` | The vault's overview page | Same |
| `key_vaults[].resource_group` | Required for each vault | `rg-example-mgmt` | The vault's overview page | Azure (the vault delegation deployment) |
| `provisioning.os_version` | Required | `12.2609.1003.7` (or `latest`) | `./scripts/simplified-provisioning/Get-ZtpOsImage.ps1 -SubscriptionId <id> -Location eastus`. Pin a version. | Azure (the OS the machines install); the handoff records the build installed |
| `provisioning.simplified.subscription_id` | Optional | `00000000-0000-0000-0000-000000000000` | Only when the site goes in another subscription than `azure.subscription_id` | Same as `azure.subscription_id` |
| `provisioning.simplified.resource_group` | Optional | `rg-example` | Only when the site goes in another group than `azure.resource_group` | Same as `azure.resource_group` |
| `provisioning.simplified.site_name` | Required | `site-example` | You choose it: the `Microsoft.Edge` site's resource name | Azure (the site, the deployment `ztp-<site_name>`); the default run folders |
| `provisioning.simplified.maintenance_iso` | Required | `latest` or `2610` | `latest`, a train, a build or a Microsoft download URL. See [Bootstrap media](bootstrap-media.md). | Resolve |
| `provisioning.simplified.admin.username` | Required | `azl-provadmin` | You choose it | Azure (the local administrator the OS install creates) |
| `provisioning.simplified.admin.password` | Required | `keyvault://kv-example/provisioning-admin-password` | A secret you create before the run | Azure (the secret's resource ID), then the OS install |
| `provisioning.simplified.maintenance_password` | Optional | `keyvault://kv-example/maintenance-password` | A secret you create; default `Password1` without it | Media (the hash in each image), Device (sign-in) |
| `provisioning.simplified.media_share.name` | Required | `ztp-virtual-usb` | You choose it: letters, digits and hyphens | Boot |
| `provisioning.simplified.media_share.host` | Required, or `host_adapter` | `198.51.100.5` | The management host's address as the BMCs reach it | Boot |
| `provisioning.simplified.media_share.host_adapter` | Required, or `host` | `VPN` | `Get-NetAdapter`: the adapter whose address the BMCs reach. Wins over `host`. | Boot |
| `provisioning.simplified.media_path` | Optional | `D:\Data\azl-ztp\site-example\media` | A folder outside any git repository | Every stage |
| `provisioning.simplified.evidence_path` | Optional | `D:\Data\azl-ztp\site-example\evidence` | A folder outside any git repository | Every stage |
| `networking.management.subnet` | Required | `192.0.2.0/24` | Your IP plan | Device (mask, default scan range), Azure (`site` method), Network |
| `networking.management.gateway` | Required | `192.0.2.1` | Your IP plan | Device, Azure (`site` method), Network |
| `networking.management.dns_servers` | Required | `[192.0.2.53, 192.0.2.54]` | Your IP plan | Device, Azure (`site` method), Network |
| `networking.management.vlan_id` | Optional, default 0 (or the management port's) | `0` | The VLAN the host tags; 0 for an access port | Device, Azure (`site` method), Network |
| `networking.management.ip_assignment` | Optional, default `static`; used only without `nodes[].network_adapters` | `static` | Your IP plan | Device, Azure, Network |
| `networking.management.static_method` | Optional, default `device` | `device` | `device`, unless you run without the Device stage | Device, Azure (the site's setting and the claim) |
| `networking.management.provisioning_dhcp_range.start`, `.end` | Optional, default the management subnet | `192.0.2.100`, `192.0.2.199` | The DHCP server's pool on the provisioning network | Device (the scan) |
| `networking.management.provisioning_network` | Optional, default `dhcp` | `dhcp` | `dhcp`; `static` only warns | File check (warning) |
| `networking.management.site_ip_range.start`, `.end` | Optional; only with `static_method: site` | `192.0.2.11`, `192.0.2.12` | Your IP plan; default the nodes' range | Azure (the site's Manual range) |
| `hardware.vendor` | Required | `Dell` | The OEM; picks `config/oem/<vendor>.json` | Bootstrap (the BMC log services and signals) |
| `hardware.bmc.username` | Required | `keyvault://kv-example/bmc-username` (or the name itself) | A secret you create | Boot, Bootstrap, Vouchers, Restore |
| `hardware.bmc.password` | Required | `keyvault://kv-example/bmc-password` | A secret you create | Boot, Bootstrap, Vouchers, Restore |
| `hardware.bios` | Optional | `{ EmbNic1Nic2: "Enabled", Slot2: "Enabled" }` | The BMC's Redfish Bios resource (`GET /redfish/v1/Systems/System.Embedded.1/Bios` on an iDRAC) | Boot, Restore |
| `hardware.bios_during_provisioning` | Optional | `{ Slot2: "Disabled" }` | Same | Boot, Restore |
| `nodes[].name` | Required, unique | `node-01` | Your naming plan: the host and edge machine name | Every stage |
| `nodes[].serial_number` | Required | `EXAMPLE1` | The service tag on the machine's label or the BMC dashboard | Bootstrap and Vouchers (voucher mapping), Azure, Handoff |
| `nodes[].bmc.ip_address` | Required | `198.51.100.11` | The BMC's address | Boot (also the share's firewall scope), Bootstrap, Vouchers, Restore |
| `nodes[].bmc.username`, `.password` | Optional; must equal `hardware.bmc` | | | File check |
| `nodes[].network_adapters[]` management port: `name`, `mac_address`, `roles: [management]`, `ip_assignment`, `ip_address` | Required: exactly one port with role `management` and an `ip_assignment` other than `none` | `{ name: "Embedded NIC 1", mac_address: "00:00:5E:00:53:11", roles: [management], ip_assignment: static, ip_address: "192.0.2.11" }` | The MAC from the BMC's network inventory or the NIC label; the address from your IP plan | Device, Azure, Network |
| `nodes[].network_adapters[]` management port: `vlan_mode`, `vlan_id` | Optional | `vlan_mode: access` | Your switch configuration | Device, Azure (`site` method), Network (when `networking.management.vlan_id` isn't set) |
| `nodes[].network_adapters[]` provisioning port: `roles: [provisioning]`, `ip_address` | Optional; the `ip_address` becomes the maintenance address | `{ name: "Slot 3 Port 1", mac_address: "00:00:5E:00:53:13", roles: [provisioning], ip_assignment: dhcp_reservation, ip_address: "192.0.2.111" }` | Your DHCP reservation | Device |
| `nodes[].management.ip_address`, `.mac_address`, `.adapter_name` | Required instead of `network_adapters`, when the node has no `network_adapters` | `{ ip_address: "192.0.2.11", mac_address: "00:00:5E:00:53:11" }` | Same as the management port | Device, Azure, Network |
| `nodes[].arc_machine_name` (or `arc_resource_name`) | Optional, default `nodes[].name` | `node-01` | Your naming plan: 1-54 letters, digits, `-`, `_`, `.` | Azure (`arcMachineResourceId`); the handoff records the name Azure used |
| `nodes[].maintenance_address` | Optional | `192.0.2.111` | A DHCP reservation, or the lease the node's console shows. Without it, the Device stage scans. | Device |
| `nodes[].bios` | Optional | `{ Slot2: "Enabled" }` | Same as `hardware.bios` | Boot, Restore |
| `nodes[].bios_during_provisioning` | Optional | `{ Slot2: "Enabled" }` | Same | Boot, Restore |
| `tags` | Optional | `{ Owner: "platform-team" }` | Your tagging standard | Azure (the site configuration and the edge machines; a new resource group) |

ZTP doesn't read `hardware.sbe`, `hardware.model`, `identity.local_admin`, `networking.ntp_servers`, or the ports without role `management` or `provisioning`. They belong to OS configuration and deployment. See [Not read by ZTP](infrastructure-schema-5.md#not-read-by-ztp).
## How this page maps to Learn 2610

Microsoft Learn, [simplified machine provisioning (preview)](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning), checked against train 2610. What Learn asks of a person with a USB stick, ZTP does over the BMC.

| Learn 2610 | Where it is here |
| --- | --- |
| Hardware: validated SKUs (Lenovo ThinkAgile MX650 V3 and V4, HPE ProLiant DL360 Gen11, Dell AX-750 and AX-650); a USB port; a Windows 11 computer; an 8 GB USB flash drive | [Hardware](#hardware). ZTP needs no USB stick and no Windows 11 laptop: the BMC mounts a virtual USB image from the management host. |
| On-site: the general deployment prerequisites, Active Directory prepared, the maintenance ISO and tools downloaded from the portal | The ISO is downloaded and hash-checked by the Resolve stage ([Bootstrap media](bootstrap-media.md)). Active Directory preparation is outside ZTP. |
| Register the feature: `az feature register --namespace Microsoft.DeviceOnboarding --name AzureLocalZTP` | [Resource providers and features](#resource-providers-and-features). Checked by the Bootstrap stage. |
| Resource providers: HybridCompute, AzureStackHCI, DeviceOnboarding, Edge, GuestConfiguration, HybridConnectivity, KeyVault, ManagedIdentity, PolicyInsights, Storage, Insights (Learn lists HybridCompute twice) | The same eleven in the table and the registration script above. ZTP checks the first four. |
| Permissions: resource group Owner, or Contributor and Role Based Access Control Administrator | [Roles](#roles) |
| Region: only East US supports the provisioning resources; the resource group can be anywhere | [Subscription and region](#subscription-and-region) |
| Secure Boot and TPM on; disable the USB in BIOS after setup | [Hardware](#hardware) (Secure Boot and TPM, USB boot order) |
| Prepare machines: wait for "Maintenance environment setup completed successfully"; the machine reboots twice; up to 30 minutes | The Bootstrap stage watches the BMC log for the same signals ([Monitoring](monitoring.md)). |
| Ownership voucher: a `.pem` file named after the serial number in `\vouchers\<serial-number>\`, or downloaded with the Configurator app | The Vouchers stage reads it from the node's image and checks the serial ([Redfish virtual USB and vouchers](redfish-virtual-usb-vouchers.md)). |
| Configurator app: user `edgeuser`, default password `Password1` | The Device stage uses the same REST service on TCP 20001; set `provisioning.simplified.maintenance_password` to change the password ([Appendix B](appendix/configurator-app-api.md)). |
| Site: time zone and time server; Arc gateway not supported in the preview | [The site's network setting](#the-sites-network-setting); `site.time_zone` in [Values you need](#values-you-need) |
| Provision: vouchers, software version, local administrator (12 or more characters with lower and upper case, a digit and a special character), machine name as the Arc resource name | [The secrets](#the-secrets); `provisioning.os_version`; `nodes[].arc_machine_name` |
| Status "Ready to cluster" in **Azure Arc > Operations > Provisioning (preview)** | The Ready stage waits for it. |
