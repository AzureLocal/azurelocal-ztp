# Operator guide

> What you need, and how to run zero-touch provisioning from a management host, from bare machines to provisioned, Arc-connected nodes that are ready for OS configuration.

Read [Design and architecture](architecture.md) first for the stages and gates. To run the same thing from CI/CD, see [Running from a pipeline](automation-pipelines.md).

**Warning:** The execute run **reinstalls** every node you name. Don't point it at a machine that holds anything you want to keep.

## What ZTP gives you

When the run ends, each machine is **Provisioned** in Azure and **Arc-connected**, with its management IP on the management NIC, found by its MAC, as the infrastructure file says. The handoff holds each machine's Arc machine name and resource ID.

That isn't ready for Validate. OS configuration comes next; see [What's next: OS configuration](#whats-next-os-configuration).

## The run at a glance

1. Meet the [prerequisites](#prerequisites).
2. Write the [environment file](#step-1-write-the-environment-file).
3. Sign in to Azure and run the [plan](#step-2-run-the-plan).
4. Run [execute](#step-3-run-execute) and [watch it](#watch-the-run).
5. Take the [handoff](#what-to-hand-to-the-cluster-deployment) to [OS configuration](#whats-next-os-configuration).

The stages run in this order: Resolve, Media, Boot, Bootstrap, Vouchers, Device, Azure, Ready, Network, Restore, Handoff.

On live runs, two nodes took about 1.5 to 2 hours from the start to Ready to cluster. A node that registers late can add up to about 45 minutes. That figure was **proven on Dell AX-760 / iDRAC 7.30**. With `bios_during_provisioning` set, the Restore stage adds a BIOS restart, a 5-minute settle and the wait until Arc reports each machine Connected again.

## Prerequisites

The [Prerequisites](prerequisites.md) page lists everything to have in place before the first run. The tables below are the same requirements, with the commands.

### Azure

| Requirement | How | Source |
| --- | --- | --- |
| Feature registered in the subscription | `az feature register --subscription <subscription-id> --namespace Microsoft.DeviceOnboarding --name AzureLocalZTP` | [Learn: Azure prerequisites](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#azure-prerequisites) |
| Resource providers registered | `Microsoft.HybridCompute`, `Microsoft.AzureStackHCI`, `Microsoft.DeviceOnboarding`, `Microsoft.Edge`, `Microsoft.GuestConfiguration`, `Microsoft.HybridConnectivity`, `Microsoft.KeyVault`, `Microsoft.ManagedIdentity`, `Microsoft.PolicyInsights`, `Microsoft.Storage`, `Microsoft.Insights` | Same |
| Region | Provisioning resources in **East US**. The resource group can be in any region. | Same |
| Rights on the cluster resource group | **Owner**, or **Contributor** and **Role Based Access Control Administrator** | Same |
| Rights to create the resource group | Only if the group doesn't exist yet: Contributor on the subscription. Or create the group first. | `Invoke-ZtpEnvironment.ps1` creates a missing group. |
| Rights on the Key Vault | Read secrets (**Key Vault Secrets User**) on every vault the environment file names. On the vault that holds the provisioning administrator secret, rights to assign roles and to deploy into its resource group (**Owner**, or **Contributor** and **Role Based Access Control Administrator** on that group). The template assigns each edge machine a constrained role on that vault. If the vault is in the cluster resource group, the group roles above cover this. | `bicep/modules/key-vault-delegation.bicep` |
| Read on the subscription | **Reader**. The run reads the feature and provider registration, the OS image catalog, and the Arc machines in the managed resource group that the site configuration creates. | `ZtpEvents.Common.ps1`, `Test-ProvisionedMachines.ps1` |
| Key Vault secrets | The BMC user name (or put the name itself in the file), the BMC password and the provisioning administrator password. Optionally the maintenance environment's `edgeuser` password. The provisioning administrator secret must exist before the run. | [Environment file reference](environment-file.md#secrets-in-key-vault) |
| Key Vault reachable | Keep public network access on the vault during provisioning and deployment. Learn says this for deployment. | [Learn: decision 10](https://learn.microsoft.com/azure/azure-local/plan/cloud-deployment-network-considerations#decision-10-determine-outbound-connectivity) |

Register the feature and providers once per subscription. That needs a subscription Owner or Contributor; the run itself only reads the registration.

```powershell
Register-AzProviderFeature -ProviderNamespace Microsoft.DeviceOnboarding -FeatureName AzureLocalZTP
'Microsoft.HybridCompute', 'Microsoft.AzureStackHCI', 'Microsoft.DeviceOnboarding', 'Microsoft.Edge',
'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity', 'Microsoft.KeyVault', 'Microsoft.ManagedIdentity',
'Microsoft.PolicyInsights', 'Microsoft.Storage', 'Microsoft.Insights' | ForEach-Object { Register-AzResourceProvider -ProviderNamespace $_ }
```

The template gives each edge machine's identity the right to assign **Key Vault Secrets User** on the vault, so the vault must use the Azure RBAC permission model.

### Hardware and firmware

| Requirement | Source |
| --- | --- |
| A model on Learn's validated list, or one you accept running unsupported. The flow was **proven on Dell AX-760 / iDRAC 7.30**, which isn't on the list. | [Learn: hardware prerequisites](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#hardware-prerequisites) |
| Secure Boot and TPM on. | [Learn: prepare machines](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#step-2-prepare-machines) |
| BIOS setting **Boot USB Devices First** off. When it's on, the machine keeps booting the USB and reinstalling the maintenance environment. | [Learn: USB boot loop](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning#usb-boot-loop-issue-with-maintenance-environment) |
| BIOS, BMC (iDRAC), CPLD and network adapter firmware matched to the OEM's Azure Local support matrix for your solution version, before you start. The run doesn't update firmware. Learn says to install drivers and firmware before deployment, that is before Validate and Deploy; the drivers are installed in [OS configuration](#whats-next-os-configuration), not by ZTP. | [Learn: install drivers and firmware](https://learn.microsoft.com/azure/azure-local/deploy/deployment-install-os#install-drivers-and-firmware) |
| Nothing on the machines that you want to keep. | |

### BMC settings

| Requirement | Notes |
| --- | --- |
| Redfish over HTTPS on, reachable from the management host. | Self-signed certificates are accepted. |
| Virtual media on, with the USB-stick (`RemovableDisk`) slot. | The CD slot isn't used. An ISO on the iDRAC CD slot failed in testing. |
| A BMC account that can insert virtual media, change BMC and BIOS attributes, set the boot override and reset the server. | Store the user name and password in Key Vault. |
| The BMC can reach the management host on TCP 445 (SMB). | The iDRAC's SMB client connects out from its management IP. No inbound SMB port is needed on the BMC. |
| On iDRAC: the manager attribute `RFS.<n>.WriteProtected` is exposed. | The run sets it to `Read Write` with a Redfish PATCH on `/redfish/v1/Managers/iDRAC.Embedded.1/Attributes` before the insert, and back to `Read Only` on eject. On iDRAC 7.30, `InsertMedia` rejects a `WriteProtected=false` field (`IDRAC.2.9.SYS458`), so the attribute is the only way to get a writable slot. **Proven on Dell AX-760 / iDRAC 7.30.** |
| The factory default BMC password is changed. | |

### Network

| Path | Port | Notes |
| --- | --- | --- |
| Management host to each BMC | TCP 443 | Redfish |
| Each BMC to the management host | TCP 445 | SMB, opened by the BMC from its management IP. The host needs it inbound from the BMC addresses only. `Publish-MaintenanceIso.ps1` creates that Windows Firewall rule, scoped to the BMC addresses. Open it on any firewall in between. |
| Management host to each node's maintenance environment | TCP 20001 | HTTPS to the maintenance environment's REST service, for the Device stage (self-signed certificate). That's the node's `maintenance_address` when the file gives one. Otherwise the Device stage scans every address of `provisioning_dhcp_range` (default: the management subnet), so the host must reach that whole range on TCP 20001. |
| Management host to the internet | TCP 443 | Azure Resource Manager, Microsoft Entra ID, Key Vault, and the maintenance ISO download (`aka.ms/aep/installeros/<YYMM>`) |
| Nodes to Azure | TCP 443 and 80 | Learn's firewall requirements. No HTTPS inspection. See [Learn: firewall requirements](https://learn.microsoft.com/azure/azure-local/concepts/firewall-requirements). |
| DHCP for the maintenance environment | | The maintenance environment takes a DHCP lease on its ports and reaches Azure through one of them before the claim (`provisioning_network: dhcp`). A reservation isn't needed: without a `maintenance_address`, the Device stage finds each node by its management MAC. Recommended: Mode A, `ip_assignment: dhcp_reservation` with a reservation of each node's `ip_address` for its management MAC, the only mode where ZTP ends with every management address right ([Management address modes](prerequisites.md#management-address-modes)). Learn recommends reservations ([decision 8](https://learn.microsoft.com/azure/azure-local/plan/cloud-deployment-network-considerations#decision-8-determine-management-ips-and-infrastructure-network)). |

ZTP needs no WinRM to the nodes. It reaches them only through the BMC, the maintenance environment's REST service and Azure.

### Management host

| Requirement | How |
| --- | --- |
| Windows, with an elevated PowerShell 7 session | The Boot stage creates an SMB share, a local account and a firewall rule; `Mount-DiskImage` needs elevation too. |
| Az PowerShell modules | `Install-Module Az.Accounts, Az.Resources, Az.KeyVault, Az.ConnectedMachine -Scope AllUsers` |
| Azure CLI with Bicep | Install the Azure CLI, then `az bicep install`. The entry point adds `$HOME\.azure\bin` to `PATH` so Az PowerShell finds Bicep. |
| `powershell-yaml` | `Install-Module powershell-yaml -Scope AllUsers` |
| Pester 5 | Only to run the tests: `Install-Module Pester -MinimumVersion 5.0 -Scope AllUsers` |
| Disk space | About 3 GB for the maintenance download and ISO, plus 4 GiB per node for the images, in the media folder (`media_path`, default `%ProgramData%\AzureLocalZtp\<site>\media`), outside any git repository. |
| A session that lasts | The run takes hours. Use a session that won't end or sleep, or run it from a [pipeline](automation-pipelines.md). |

### Security

| Do this | Why |
| --- | --- |
| Change the BMC factory password, and keep the BMC credential only in Key Vault. | The run reads it from Key Vault into memory and never writes it. |
| Set the maintenance environment's `edgeuser` password (`provisioning.simplified.maintenance_password`; older layout `ztp.maintenance_password_secret`). | Without it the image keeps the published default, `Password1`, and anyone who reaches TCP 20001 while the maintenance environment runs can sign in. |
| Restrict the folder that holds the vouchers (`<media_path>\vouchers`), and never commit vouchers. | An ownership voucher is a secret: it's what claims the machine in Azure. |
| Treat the read-write share as a tampering risk while it's up. Consider requiring SMB signing on the host, and test that your BMC still connects. | The machine boots from the image on that share. The run limits the share to the BMC addresses and one dedicated account with a random password, and removes the share, the account and the firewall rule after the Vouchers stage. |
| Keep the generated files and the handoff out of source control. | They hold your subscription, addresses and resource IDs. |

## Step 1: Write the environment file

Clone the repository onto the management host, and open an elevated PowerShell 7 session at its root. Every command on this page runs from there.

```powershell
git clone https://github.com/AzureLocal/azurelocal-ztp.git D:\git\azurelocal-ztp
Set-Location D:\git\azurelocal-ztp
```

### Pick the template

ZTP reads the master `infrastructure.yml` (schema 5), the file every Azure Local tool reads. Start from one of the toolkit's templates, keep your copy outside this repository, and fill in your values:

| You use | Start from |
| --- | --- |
| ZTP only, with nothing automated after it | The toolkit's ZTP-only template, [`infrastructure.ztp.example.yml`](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/config/infrastructure/infrastructure.ztp.example.yml) (`_metadata.scope: ztp`) |
| ZTP, then OS configuration and cluster deployment with the toolkit | The full template, [`infrastructure.example.yml`](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/config/infrastructure/infrastructure.example.yml) |

Both work with ZTP. ZTP ignores the keys it doesn't read, so the full template's OS configuration and deployment settings do no harm. [Reading the master infrastructure.yml](infrastructure-schema-5.md) says where each key goes. The older ZTP layout ([`examples/infrastructure.example.yml`](https://github.com/AzureLocal/azurelocal-ztp/blob/main/examples/infrastructure.example.yml), described in the [Environment file reference](environment-file.md)) still works and is deprecated.

The run keeps its working files in the media folder: downloads, images, vouchers and state. Its evidence (the event log, change logs and transcripts) goes to the evidence folder. Set both in the environment file (`provisioning.simplified.media_path` and `evidence_path`; older layout `ztp.media_path`, `ztp.evidence_path`); without them they are `%ProgramData%\AzureLocalZtp\<site name>\media` and `\evidence`. The run refuses a folder inside a git working tree, and creates the folders when missing. Keep them where they last, because resuming a run depends on them. See [Run data](environment-file.md#run-data-media-and-evidence).

### Secrets

The file holds no passwords. Each credential is a Key Vault reference (`keyvault://<vault>/<secret>`):

- The BMC login: `hardware.bmc.username` (a reference, or the name itself) and `hardware.bmc.password`. Older layout: `ztp.bmc_secret`.
- The provisioning administrator: `provisioning.simplified.admin.username` and `admin.password`. Older layout: `ztp.admin_secret`.
- Optional, the maintenance environment's `edgeuser` password: `provisioning.simplified.maintenance_password`. Older layout: `ztp.maintenance_password_secret`.

ZTP doesn't create the deployment admin, so it doesn't read that secret. OS configuration does.

Create the secrets before you run:

```powershell
Set-AzKeyVaultSecret -VaultName kv-example -Name bmc-username -SecretValue (Read-Host -AsSecureString 'BMC user')
Set-AzKeyVaultSecret -VaultName kv-example -Name bmc-password -SecretValue (Read-Host -AsSecureString 'BMC password')
Set-AzKeyVaultSecret -VaultName kv-example -Name provisioning-admin-password -SecretValue (Read-Host -AsSecureString 'Provisioning admin password')
Set-AzKeyVaultSecret -VaultName kv-example -Name maintenance-password -SecretValue (Read-Host -AsSecureString 'Maintenance environment edgeuser password')
```

### Pin the OS version

`provisioning.os_version` (older layout `ztp.os_version`) decides which Azure Local build the machines install. **Pin an exact version** so every run installs the same build, and a run fails instead of silently taking a newer one.

1. List the builds your subscription can install. The list comes from the subscription's own provisioning catalog, so a preview build your subscription is entitled to appears here too:

   ```powershell
   Connect-AzAccount -Tenant <tenant-id>
   ./scripts/simplified-provisioning/Get-ZtpOsImage.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -Location eastus
   ```

   Each entry shows `VsrVersion`, the solution version to pin (for example `12.2610.1004.50`), and `IsPreview`.

2. Set it in the environment file:

   ```yaml
   provisioning:
     os_version: "12.2610.1004.50"
   ```

   | Value | Installs |
   | --- | --- |
   | An exact `VsrVersion` | That build, or the run fails. Recommended |
   | `latest` | The newest general-availability build in the catalog at the time of the run |
   | `latest-preview` | The newest build including preview builds |

3. Run the [plan](#step-2-run-the-plan). It shows the pinned version in the Azure stage (`-OsVersion`) before anything changes.

ZTP doesn't check the build against an OEM SBE. OS configuration stages the SBE, and Validate and Deploy need one the OEM validated with the installed build, so pin a build your OEM supports. The handoff's `solution.vsrVersion` records the build actually installed.

To change the build of machines that are already provisioned, provision them again from `Boot`: delete their provisioned machines first, because a voucher can claim a machine only once. See [Resume a stopped run](#resume-a-stopped-run).

### How the management address gets set

`networking.management.static_method` (older layout `network_intents.management.static_method`) decides who puts a static management address on the node.

| Value | What happens |
| --- | --- |
| `device` (default) | The Device stage sets the static address on the port with the node's management MAC, in the maintenance environment, before the claim. The site's network setting is **Automatic**, and the claim carries no `Manual` adapter, so that address is the only static the node gets. |
| `site` | The earlier path, for environments without the Device stage: the site's network setting is `Manual` over `site_ip_range`, and the claim carries a `Manual` adapter by MAC. Microsoft's OS install then puts the address on the first ready port and ignores the MAC (seen live on a Dell AX-760: a ConnectX storage port). |

Either way, Microsoft's OS install then resets every port to DHCP, so after ZTP the management port has a DHCP address (Mode B) or none (Mode C). The Network stage only verifies, through Azure's per-NIC report, and records the node as left to OS configuration, which sets the static by MAC. Mode A (a DHCP reservation per management MAC) avoids all of this and is the recommended setup; see [Management address modes](prerequisites.md#management-address-modes).

The Device stage reaches the maintenance environment's REST service on TCP 20001. It finds each node like this:

1. The node's `maintenance_address`, when the file gives one (schema 5 `nodes[].maintenance_address`, else the `ip_address` of the node's port with role `provisioning`).
2. Otherwise it scans `networking.management.provisioning_dhcp_range` (`start`, `end`; older layout `network_intents.management.provisioning_dhcp_range`; at most 4096 addresses; default: the management subnet). It probes every address on TCP 20001 in parallel, asks each one that answers for its network adapters, and takes the one that lists the node's management MAC. It scans again every 60 seconds until each node answers, for up to 30 minutes, because the node may still be booting.

Set `provisioning_dhcp_range` to the DHCP pool the maintenance environment takes its lease from, to keep the scan short:

```yaml
networking:
  management:
    subnet: 192.0.2.0/24
    gateway: 192.0.2.1
    dns_servers: [192.0.2.53, 192.0.2.54]
    static_method: device                                      # optional; the default
    provisioning_dhcp_range: { start: 192.0.2.100, end: 192.0.2.250 }
```

The scan was **verified live** on a Dell AX-760 with DHCP and no reservation. It signs in as `edgeuser` with the maintenance password, or `Password1` without one. See [The Device stage](environment-file.md#the-device-stage) and [The Network stage](environment-file.md#the-network-stage).

### BIOS values for the install only

`hardware.bios` is the BIOS state the machine ends with. `hardware.bios_during_provisioning` (and a node's own `nodes[].bios_during_provisioning`; older layout `cluster_nodes[].bios_during_provisioning`) holds temporary values for the install only.

- The Boot stage applies `hardware.bios` with `bios_during_provisioning` merged over it, so the temporary values win. It saves each attribute's original value once, in the state file and in `<evidence_path>\bios-changes.jsonl`.
- The Restore stage, after Network and before Handoff, sets every temporary key back to its `hardware.bios` value, or to the saved original when `hardware.bios` doesn't name it. It restarts the node through Redfish, waits until the BIOS reports the values, waits 5 minutes, and then waits until each machine is Connected and ready to cluster again.
- Without `bios_during_provisioning`, Restore changes nothing and says `nothing to restore: no bios_during_provisioning`.

Example: an Emulex Fibre Channel HBA in slot 2 offers its SAN LUN as the install disk. This keeps the card off for the install and turns it back on before the handoff:

```yaml
hardware:
  bios:
    Slot2: "Enabled"
    EmbNic1Nic2: "Enabled"
  bios_during_provisioning:
    Slot2: "Disabled"
```

See [BIOS settings](environment-file.md#bios-settings).

### SBE settings in an older file

ZTP has no SBE settings. A file that still carries them works; the run ignores them and prints one note:

| The file has | The run prints |
| --- | --- |
| `hardware.sbe` (schema 5) | `Note: hardware.sbe ignored: SBE belongs to OS configuration.` |
| `ztp.node_preparation` (older layout) | `Note: ztp.node_preparation ignored: SBE belongs to OS configuration.` |
| `SbeModel`, `SbeFamily`, `SbeSolutionVersion` or `SbePackagePath` in an orchestrator settings file | `<key> in <file> ignored: SBE belongs to OS configuration.` |

The deployment admin (`identity.local_admin`, older layout `credentials.local_admin_*`), the time servers (`networking.ntp_servers`, older layout `onprem.ntp_servers`), the other ports in `network_adapters` and `hardware.model` are also not read. OS configuration reads them.

## Step 2: Run the plan

Sign in, then run the entry point without `-Execute`:

```powershell
Connect-AzAccount -Tenant <tenant-id>
./scripts/simplified-provisioning/Invoke-ZtpEnvironment.ps1 -InfrastructureFile D:\ztp\infrastructure.yml
```

The plan changes nothing in Azure, on the BMCs or on the nodes. It does write the generated inputs (the node list, the Bicep parameters and the orchestrator settings). It shows:

- the media and evidence folders, and the share host address it will give the BMCs;
- any `Note:` line for a setting it ignores;
- the BIOS values Boot will set, and the ones Restore will set back;
- how the static management addresses are set (`static_method`), and the range the Device stage will scan for nodes without a maintenance address;
- the site's network setting (`Automatic` with `static_method: device`) and each node's Arc machine name;
- the stage table, with each stage `pending` or `completed`;
- the exact command each stage would run, with credentials shown as `<in memory>`;
- the plan of the next stage from its own script. For a first run, that's Resolve: which maintenance ISO it would download.

Fix anything the plan reports before you go on. Run the plan for some nodes only with `-Node node-01`.

## Step 3: Run execute

```powershell
./scripts/simplified-provisioning/Invoke-ZtpEnvironment.ps1 -InfrastructureFile D:\ztp\infrastructure.yml -Execute
```

Add `-Node node-01, node-02` to limit the run to some nodes. With `-Execute`, the entry point:

1. Reads the BMC login, and the maintenance password if set, from Key Vault.
2. Creates the resource group if it's missing.
3. Runs the eleven stages with `-ConfirmNotClustered`: Resolve, Media, Boot, Bootstrap, Vouchers, Device, Azure, Ready, Network, Restore and Handoff. That flag tells Boot and Restore the machines may be restarted and reinstalled.

| Stage | What it does |
| --- | --- |
| Resolve | Finds, downloads and checks the maintenance ISO. Its version, URL and SHA256 go to the stage evidence. |
| Media | Builds one virtual USB image per node. |
| Boot | Sets the BIOS values, shares the images, and boots every node from its image over the BMC. |
| Bootstrap | Watches each node until the maintenance environment writes its voucher. |
| Vouchers | Reads each voucher back, ejects the media and removes the share. |
| Device | Sets each static management address on the port with the management MAC, in the maintenance environment, before the claim. |
| Azure | Claims the machines with the Bicep template. |
| Ready | Waits for Ready to cluster, and resubmits a failed OS install once. |
| Network | Checks each management address on the port with the management MAC through Azure, and moves it there if needed. |
| Restore | Sets the `bios_during_provisioning` values back, restarts the nodes, and waits until they're Connected and ready again. |
| Handoff | Writes the handoff and the cluster inputs. |

It ends with:

```text
ZTP is done: the machines are Provisioned and Arc-connected, with the management address on the management port. ...
Next: OS configuration (OEM drivers, the SBE in C:\SBE, DHCP off on the other ports, DNS and time, the deployment admin), then Validate and Deploy. ZTP does none of these. ...
```

Or it throws with the reason. A failure gives a non-zero exit code.

## Watch the run

The run checks every stage itself and stops with the reason when a check fails. You watch it to see where it is. [Monitoring a run](monitoring.md) has what each stage checks, the event file format, Sonar step by step, and how to read what you see.

| Where | What you see |
| --- | --- |
| The console | `[HH:mm:ssZ] [ztp] ...` lines: the stage table at the start and each stage's evidence at the end. During Ready, each change of lifecycle, stage and job step is printed once. |
| The event file | `ztp-events.jsonl` in the evidence folder, one JSON object per line. Follow it with `Get-Content -Wait -Tail 20 <evidence_path>\ztp-events.jsonl`. The Device stage writes `MaintenanceEnvironmentFound` when its scan finds a node; the Restore stage writes `BiosRestoreStarted`, `BiosRestored` or `BiosRestoreFailed`. |
| AzureLocal Sonar | `Start-ZtpMonitor.ps1` writes a Sonar config for the event file and the edge machines, and starts [azurelocal-sonar](https://github.com/AzureLocal/azurelocal-sonar) from its `main` branch. Sonar only reads. |
| The Azure portal | **Azure Arc** > **Operations** > **Provisioning (preview)** > **Provisioned machines**. Wait for **Ready to cluster** ([Learn: verify Arc connectivity](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#step-5-verify-azure-arc-connectivity)). |

Start Sonar in a second window, from the clone root:

```powershell
Connect-AzAccount -Tenant <tenant-id>
./scripts/simplified-provisioning/Start-ZtpMonitor.ps1 -SonarPath D:\git\azurelocal-sonar `
    -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example `
    -NodesFile ./config/simplified-provisioning/nodes.json `
    -EventLogPath <evidence_path>\ztp-events.jsonl -ClusterName <cluster-name> -Execute
```

Two things are normal on Dell AX-760 / iDRAC 7.30: a first OS install can fail with 5901, and the run resubmits it once; and a node can wait up to about 45 minutes at `AwaitingConnection` after the claim. See [Reading what you see](monitoring.md#reading-what-you-see), and [Troubleshooting](troubleshooting.md) for the causes.

## Resume a stopped run

Run the **same command with the same `-Node` list** again. Completed stages aren't repeated; the run starts at the first stage that didn't complete.

```powershell
./scripts/simplified-provisioning/Invoke-ZtpEnvironment.ps1 -InfrastructureFile D:\ztp\infrastructure.yml -Execute
```

To run a stage and every later one again, add `-From`. It takes Resolve, Media, Boot, Bootstrap, Vouchers, Device, Azure, Ready, Network, Restore or Handoff.

| Where it stopped | Command |
| --- | --- |
| Ready timed out, or a node failed twice at `ProvisionOs` | `-From Ready`. Ready resubmits a failed job once more per run. |
| Device (the scan found no node with the management MAC, the maintenance environment didn't answer, or the status reported a failure) | `-From Device`. A port that's already right is left alone. Before the claim only: once Azure has claimed the node, use `-From Network`. |
| Network (no adapter with the management MAC, or a network adapter job failed or timed out) | `-From Network`. A port that's already right is left alone. |
| Restore (the BIOS didn't report the values, or a node didn't come back Connected) | `-From Restore`. A value that's already set back isn't sent again and needs no restart. |
| Handoff | `-From Handoff` |
| Before Azure (Boot, Bootstrap, Vouchers) | Rerun without `-From`, or `-From Boot` to boot again. Boot reinstalls the machine. |

Things to know:

- **The state file is per set of nodes.** A run with `-Node node-01` doesn't see the state of a run with both nodes. Resume with the same list.
- **Vouchers are one-time use.** After a claim, the voucher is spent. The Azure stage never re-PUTs an edge machine that exists. To provision a claimed node again from `Boot`, first delete its edge machine: **Azure Arc** > **Operations** > **Machine provisioning (preview)** > **Provisioned machines**, select it, **Delete**. Learn's recovery for a failed claim does the same and waits 15 minutes before provisioning again ([Learn](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning#when-you-provision-new-machines-arm-template-validation-fails)).
- **The BIOS originals are saved once.** A second Boot reads the values the first one already changed, so the state file keeps the first values it saw. Restore sets back to those.
- **To forget the state** of a set of nodes, delete `<media_path>\ztp-state\<run>.ztp-provisioning.state.json`. The entry point has no reset switch.
- **If a run failed during Boot,** check each node before you retry: the virtual media is ejected and the one-time boot override is cleared. `./scripts/simplified-provisioning/Mount-ZtpVirtualUsb.ps1 -NodeName node-01 -NodesFile ./config/simplified-provisioning/nodes.json -Credential $bmc -Action Status -SkipCertificateCheck -Execute` shows the slot, power state and boot override (read-only). `-Action Eject` ejects it.
- A stopped Boot or Vouchers stage can leave the share in place. The next Boot replaces it, and the Vouchers stage removes it. To remove it by hand: `./scripts/simplified-provisioning/Publish-MaintenanceIso.ps1 -Remove -ShareName <share-name> -SharePath <image folder> -Execute`.

## What the run checked

Before it writes the handoff, the run has checked each node:

| Check | Where it's checked |
| --- | --- |
| Edge machine lifecycle `Provisioned`; `ProvisionOs` job reports `DeploymentSuccess` | Ready, again after Restore, and Handoff |
| Arc machine `Connected`, with an `arcMachineResourceId` | Ready, and again after Restore |
| Arc extensions `AzureEdgeDeviceManagement`, `AzureEdgeLifecycleManager`, `AzureEdgeRemoteSupport` and `AzureEdgeTelemetryAndDiagnostics` all `Succeeded` | Ready and after Restore (`Test-ProvisionedMachines.ps1`) |
| Static address `ip_address/prefix`, gateway, DNS and VLAN on the adapter with the management MAC, and on no other adapter | Device (in the maintenance environment, Modes B and C). Network verifies it after the install, as Azure reports the adapter; in Modes B and C the install has reset it, so it is recorded as left to OS configuration. The handoff records it as `managementAddressVerified`, with the mode and every port. |
| The reserved address on the adapter with the management MAC | Network (Mode A). The handoff records it as `managementAddressVerified`. |
| The `bios_during_provisioning` values set back | Restore. The handoff records them as `biosRestored`. |

That's ZTP's result. It doesn't check drivers, the SBE, DHCP on the other ports, DNS or time on the host, or the deployment admin; those belong to [OS configuration](#whats-next-os-configuration).

## What to hand to the cluster deployment

The handoff is in `<media_path>\ztp-state\`:

| File | Contents |
| --- | --- |
| `<run>.ztp-handoff.json` | Handoff schema 2: only what Azure generated during ZTP. See below. |
| `<run>.ztp-cluster-inputs.yaml` | `arc_machine_names` (host name to Arc machine name) and `release.azure_local_version` (the build installed), ready to paste into a cluster deployment environment file |
| `<run>.arc-machine-names.json` | Host name to Arc machine name |

The handoff holds what Azure generated during ZTP, and what Azure reports for each port after the install (`networkAdapters[]`, matched by MAC to the file):

```json
{
  "schemaVersion": 2,
  "generatedUtc": "2026-11-07T12:00:00.0000000Z",
  "tool": "azurelocal-ztp",
  "subscriptionId": "00000000-0000-0000-0000-000000000000",
  "resourceGroup": "rg-example",
  "site": { "resourceId": "/subscriptions/.../providers/Microsoft.Edge/sites/site-example", "name": "site-example" },
  "solution": { "vsrVersion": "12.2609.1003.7" },
  "nodes": [ {
    "name": "node-01", "serial": "EXAMPLE1",
    "edgeMachineName": "node-01", "edgeMachineId": "/subscriptions/.../edgeMachines/node-01",
    "arcMachineName": "node-01", "arcMachineResourceId": "/subscriptions/.../Microsoft.HybridCompute/machines/node-01",
    "arcMachineResourceGroup": "rg-example", "ready": true,
    "managementAddressVerified": false,
    "managementAddressReason": "Mode B (Static with DHCP): the management port Port1 (MAC 00:00:5e:00:53:aa, Example LOM) has DHCP 192.0.2.116 after the install; expected static 192.0.2.11; OS configuration sets it by MAC.",
    "biosRestored": { "Slot2": "Enabled" },
    "managementMode": { "mode": "B", "name": "Static with DHCP", "ipAssignment": "static" },
    "networkAdapters": [
      { "name": "Port1", "macAddress": "00:00:5e:00:53:aa", "description": "Example LOM", "roles": ["management"], "fileName": "Embedded NIC 1",
        "isManagement": true, "ipAssignment": "Dhcp", "ipAddress": "192.0.2.116", "prefix": 24, "subnetMask": "255.255.255.0", "gateway": "192.0.2.1",
        "expected": { "ipAssignment": "static", "ipAddress": "192.0.2.11" } },
      { "name": "Port3", "macAddress": "00:00:5e:00:53:bb", "description": "Example ConnectX-6 Dx", "roles": ["storage"], "fileName": "Slot 3 Port 2",
        "isManagement": false, "ipAssignment": "Dhcp", "ipAddress": null, "prefix": null, "subnetMask": null, "gateway": null,
        "expected": { "ipAssignment": "none", "ipAddress": null } }
    ]
  } ]
}
```

The run also prints a table per node at the end, `>` marking the management port:

```text
node-01: Mode B (Static with DHCP, static); management address not verified: Mode B (Static with DHCP): the management port Port1 ...
     port             MAC               roles (name in the file)   now                      expected
  >  Port1            00:00:5e:00:53:aa management (Embedded NIC 1) Dhcp 192.0.2.116/24 gw 192.0.2.1 static 192.0.2.11
     Port3            00:00:5e:00:53:bb storage (Slot 3 Port 2)    Dhcp, no address         none
```

| Key | Meaning |
| --- | --- |
| `solution.vsrVersion` | The build actually installed. The file may say `latest`. |
| `managementAddressVerified`, `managementAddressReason` | From the Network stage: `true` when the management port (the port with the management MAC) carries the file's address. Otherwise `false` with a plain-language reason naming the mode, the port, its MAC, what it has now and what the file expects (see the example above), or `no Network stage result for this node`. In Modes B and C that is the normal result: OS configuration sets the static before Validate. |
| `managementMode` | `mode` (`A`, `B`, `C`, or `null` for `dhcp` and `preconfigured`), `name` and the management port's `ipAssignment`. `null` when the run had no node list. |
| `networkAdapters[]` | Every port as Azure reports it after the install (`edgeMachines/<node>/networkAdapters`, `reportedProperties`): `name` (the OS name), `macAddress`, `description`, `roles` and `fileName` (the file's port with that MAC; empty when the file doesn't list it), `isManagement`, `ipAssignment` (`Dhcp`, `Static` or `none`), `ipAddress`, `prefix`, `subnetMask`, `gateway`, and `expected` (`ipAssignment` and `ipAddress` from the file). Additive: schema 2 readers that don't know it ignore it. |
| `biosRestored` | What Restore set back, attribute to value. `{}` when nothing. |

Schema 2 no longer carries `sbe`, `bootstrap`, `timestamps`, `connectivity` or a top-level `arcMachineResourceGroup`. The maintenance ISO's version, URL and SHA256 are in the Resolve stage's evidence: the state file (`stages.Resolve.data`) and its `StageCompleted` event, for example `maintenance ISO 10.2610.0.3061 (GA), SHA256 ..., from <url>`. The timestamps are the `StageStarted` and `StageCompleted` events, and `stages.<name>.completed` in the state file. `Convert-ZtpHandoffToClusterInputs.ps1` reads schema 2 and schema 1, and no longer writes an `sbe` block or `release.sbe_version`; the SBE values for deployment come from OS configuration.

**Use each node's `arcMachineResourceId` from the handoff**, not the host name. The service names the Arc machine `<device-id>-1`, not after the host, and replaces the `arcMachineResourceId` set at claim time. The handoff reads `arcMachineResourceId` from the edge machine after Ready, so it names that service-created machine. This was **proven on Dell AX-760 / iDRAC 7.30**.

```powershell
(Get-Content <media_path>\ztp-state\node-01+node-02.ztp-handoff.json -Raw | ConvertFrom-Json).nodes |
    Select-Object name, arcMachineResourceId, managementAddressVerified
```

The handoff files hold Azure resource IDs of your subscription. Keep them out of source control.

**Before Deploy on build `12.2690`:** an earlier Deploy on that build failed at "Deploy Arc infrastructure components" with `ParentResourceNotFound`, because the Arc machine names are device IDs. Check this before you deploy. See [Troubleshooting](troubleshooting.md#deploy-fails-with-parentresourcenotfound-on-build-2690).

<a id="whats-next-os-configuration"></a>

## What's next: OS configuration

ZTP ends at the handoff. The nodes are provisioned and Arc-connected, and they are **not yet ready for Validate**. OS configuration comes next, before Validate and Deploy: [azurelocal-toolkit Phase 03: OS Configuration](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/).

ZTP doesn't do any of these. OS configuration does:

| Not done by ZTP | Where |
| --- | --- |
| Set the static management address by MAC (Modes B and C) | [Task 03: Static IP](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-03-configure-static-ip-address) |
| Install the OEM drivers | [Phase 03](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/) |
| Stage the SBE in `C:\SBE` | [Phase 03](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/) |
| Turn DHCP off on the other NICs, and disable the unused ones | [Task 04: Disable DHCP on all adapters](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-04-disable-dhcp-on-management-adapter), [Task 09: Disable unused adapters](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-09-disable-unused-network-adapters) |
| Set DNS on the host | [Task 05: DNS](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-05-configure-dns-servers) |
| Set time on the host | [Task 07: NTP](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-07-configure-time-synchronization-ntp) |
| Create the deployment admin | [Phase 03](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/) |

**The management address after ZTP.** Mode A: the reserved address, verified. Modes B and C: **not the static address**. Microsoft's OS install resets every port, so the management port has a DHCP address (B) or none (C, with Arc reaching the node over the provisioning port), and Microsoft's post-install per-NIC API didn't run in our tests. OS configuration sets it: the toolkit's `Set-AzureLocalNodeConfiguration.ps1` (Network step) sets the static on the port with the management MAC over Arc Run Command, before it turns DHCP and the gateway off on the ports the file lists as `none`. [Task 03: Static IP](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-03-configure-static-ip-address) covers it; the handoff's `managementAddressVerified: false` and its reason say which nodes need it. [Task 15](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-15-complete-combined-script-all-steps) runs all the steps in one script, and [Task 16](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-16-phase03-verification) verifies the phase.

**Find NICs by MAC.** ZTP-built nodes run Microsoft's provisioned OS, which names the NICs `Port0` to `Port6`. Scripts that look a NIC up by an OEM or manual-install name won't find it, so OS configuration scripts must find each NIC by its MAC.

After OS configuration, cluster deployment continues with [Phase 05: Cluster Deployment](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-05-cluster-deployment/). The whole sequence is in [Part 4: Cluster Deployment](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/). Active Directory preparation is outside ZTP too.
