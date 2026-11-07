# Operator guide

> What you need, and how to run zero-touch provisioning from a management host, from bare machines to nodes that are ready for cluster Validate.

Read [Design and architecture](architecture.md) first for the stages and gates. To run the same thing from CI/CD, see [Running from a pipeline](automation-pipelines.md).

**Warning:** The execute run **reinstalls** every node you name. Don't point it at a machine that holds anything you want to keep.

## The run at a glance

1. Meet the [prerequisites](#prerequisites).
2. Write the [environment file](#step-1-write-the-environment-file).
3. [Download the OEM SBE](#step-2-download-the-oem-sbe) and point the environment file at it.
4. Sign in to Azure and run the [plan](#step-3-run-the-plan).
5. Run [execute](#step-4-run-execute) and [watch it](#watch-the-run).
6. Take the [handoff](#what-to-hand-to-the-cluster-deployment) to cluster deployment.

On live runs, two nodes took about 1.5 to 2 hours from the start to "ready for Validate". A node that registers late can add up to about 45 minutes. That figure was **proven on Dell AX-760 / iDRAC 7.30**.

## Prerequisites

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
| Key Vault secrets | Four secrets: BMC user name, BMC password, provisioning administrator password, deployment admin password. The provisioning administrator secret must exist before the run. | [Environment file reference](environment-file.md#secrets-in-key-vault) |
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
| BIOS, BMC (iDRAC), CPLD and network adapter firmware matched to the OEM's Azure Local support matrix for your solution version, before you start. The run doesn't update firmware. Learn says to install drivers and firmware before deployment, that is before Validate and Deploy; Prepare installs the drivers. | [Learn: install drivers and firmware](https://learn.microsoft.com/azure/azure-local/deploy/deployment-install-os#install-drivers-and-firmware) |
| Nothing on the machines that you want to keep. | |

### BMC settings

| Requirement | Notes |
| --- | --- |
| Redfish over HTTPS on, reachable from the management host. | Self-signed certificates are accepted. |
| Virtual media on, with the USB-stick (`RemovableDisk`) slot. | The CD slot isn't used. An ISO on the iDRAC CD slot failed in testing. |
| A BMC account that can insert virtual media, change BMC attributes, set the boot override and reset the server. | Store the user name and password as two Key Vault secrets. |
| The BMC can reach the management host on TCP 445 (SMB). | The iDRAC's SMB client connects out from its management IP. No inbound SMB port is needed on the BMC. |
| On iDRAC: the manager attribute `RFS.<n>.WriteProtected` is exposed. | The run sets it to `Read Write` with a Redfish PATCH on `/redfish/v1/Managers/iDRAC.Embedded.1/Attributes` before the insert, and back to `Read Only` on eject. On iDRAC 7.30, `InsertMedia` rejects a `WriteProtected=false` field (`IDRAC.2.9.SYS458`), so the attribute is the only way to get a writable slot. **Proven on Dell AX-760 / iDRAC 7.30.** |
| The factory default BMC password is changed. | |

### Network

| Path | Port | Notes |
| --- | --- | --- |
| Management host to each BMC | TCP 443 | Redfish |
| Each BMC to the management host | TCP 445 | SMB, opened by the BMC from its management IP. The host needs it inbound from the BMC addresses only. `Publish-MaintenanceIso.ps1` creates that Windows Firewall rule, scoped to the BMC addresses. Open it on any firewall in between. |
| Management host to each node's `maintenance_address` | TCP 20001 | HTTPS to the maintenance environment's REST service, for the Device stage (self-signed certificate) |
| Management host to each node's `ip_address` | TCP 5985 | WinRM over HTTP, for Prepare |
| Management host to the internet | TCP 443 | Azure Resource Manager, Microsoft Entra ID, Key Vault, the maintenance ISO download (`aka.ms/aep/installeros/<YYMM>`), the OEM's SBE manifest |
| Nodes to Azure | TCP 443 and 80 | Learn's firewall requirements. No HTTPS inspection. See [Learn: firewall requirements](https://learn.microsoft.com/azure/azure-local/concepts/firewall-requirements). |
| DHCP on the management network | | The site configuration uses automatic IP assignment, so the maintenance environment and the new OS get their address from DHCP. Give each node's management MAC a reservation for its `ip_address`, because Prepare signs in on that address before it makes it static. Learn also recommends reservations ([decision 8](https://learn.microsoft.com/azure/azure-local/plan/cloud-deployment-network-considerations#decision-8-determine-management-ips-and-infrastructure-network)). |

### Management host

| Requirement | How |
| --- | --- |
| Windows, with an elevated PowerShell 7 session | The Boot stage creates an SMB share, a local account and a firewall rule; `Mount-DiskImage` needs elevation too. |
| Az PowerShell modules | `Install-Module Az.Accounts, Az.Resources, Az.KeyVault, Az.ConnectedMachine -Scope AllUsers` |
| Azure CLI with Bicep | Install the Azure CLI, then `az bicep install`. The entry point adds `$HOME\.azure\bin` to `PATH` so Az PowerShell finds Bicep. |
| `powershell-yaml` | `Install-Module powershell-yaml -Scope AllUsers` |
| Pester 5 | Only to run the tests: `Install-Module Pester -MinimumVersion 5.0 -Scope AllUsers` |
| WinRM trusted hosts | Prepare connects to each node by IP with a local account (NTLM). Add the node addresses to the client's TrustedHosts list: `Set-Item WSMan:\localhost\Client\TrustedHosts -Value '192.0.2.11,192.0.2.12' -Concatenate`. See [Learn: about_Remote_Troubleshooting](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_remote_troubleshooting#how-to-use-an-ip-address-in-a-remote-command). |
| Disk space | About 3 GB for the maintenance download and ISO, plus 4 GiB per node for the images, in the media folder (`ztp.media_path`, default `%ProgramData%\AzureLocalZtp\<site>\media`), outside any git repository. |
| A session that lasts | The run takes hours. Use a session that won't end or sleep, or run it from a [pipeline](automation-pipelines.md). |

### Security

| Do this | Why |
| --- | --- |
| Change the BMC factory password, and keep the BMC credential only in Key Vault. | The run reads it from Key Vault into memory and never writes it. |
| Restrict the folder that holds the vouchers (`<media_path>\vouchers`), and never commit vouchers. | An ownership voucher is a secret: it's what claims the machine in Azure. |
| Treat the read-write share as a tampering risk while it's up. Consider requiring SMB signing on the host, and test that your BMC still connects. | The machine boots from the image on that share. The run limits the share to the BMC addresses and one dedicated account with a random password, and removes the share, the account and the firewall rule after the Vouchers stage. |
| Keep the generated files and the handoff out of source control. | They hold your subscription, addresses and resource IDs. |

## Step 1: Write the environment file

Clone the repository onto the management host, and open an elevated PowerShell 7 session at its root. Every command on this page runs from there.

```powershell
git clone https://github.com/AzureLocal/azurelocal-ztp.git D:\git\azurelocal-ztp
Set-Location D:\git\azurelocal-ztp
```

The run keeps its working files in the media folder: downloads, images, vouchers and state. Its evidence (the event log, change logs and transcripts) goes to the evidence folder. Set both in the environment file (`ztp.media_path`, `ztp.evidence_path`); without them they are `%ProgramData%\AzureLocalZtp\<ztp.site_name>\media` and `\evidence`. The run refuses a folder inside a git working tree, and creates the folders when missing. Keep them where they last, because resuming a run depends on them. See [Run data](environment-file.md#run-data-media-and-evidence).

Copy [`examples/infrastructure.example.yml`](https://github.com/AzureLocal/azurelocal-ztp/blob/main/examples/infrastructure.example.yml), keep it outside this repository, and fill in your values. Every key is described in the [Environment file reference](environment-file.md).

The file holds no passwords. Each credential is a Key Vault reference:

- `ztp.bmc_secret`: the vault and the two secret names of the BMC login.
- `ztp.admin_secret`: the vault, its subscription and resource group, the secret name, and the user name of the provisioning administrator.
- `credentials.local_admin_password_secret`: `keyvault://<vault>/<secret>` for the deployment admin.

Create the secrets before you run:

```powershell
Set-AzKeyVaultSecret -VaultName <vault-name> -Name <bmc-username-secret-name> -SecretValue (Read-Host -AsSecureString 'BMC user')
Set-AzKeyVaultSecret -VaultName <vault-name> -Name <bmc-password-secret-name> -SecretValue (Read-Host -AsSecureString 'BMC password')
Set-AzKeyVaultSecret -VaultName <vault-name> -Name <provisioning-admin-secret-name> -SecretValue (Read-Host -AsSecureString 'Provisioning admin password')
Set-AzKeyVaultSecret -VaultName <vault-name> -Name <deployment-admin-secret-name> -SecretValue (Read-Host -AsSecureString 'Deployment admin password')
```

### Pin the OS version

`ztp.os_version` decides which Azure Local build the machines install. **Pin an exact version** so every run installs the same build, and a run fails instead of silently taking a newer one.

1. List the builds your subscription can install. The list comes from the subscription's own provisioning catalog, so a preview build your subscription is entitled to appears here too:

   ```powershell
   Connect-AzAccount -Tenant <tenant-id>
   ./scripts/simplified-provisioning/Get-ZtpOsImage.ps1 -SubscriptionId <subscription-id> -Location eastus
   ```

   Each entry shows `VsrVersion`, the solution version to pin (for example `12.2610.1004.50`), and `IsPreview`.

2. Set it in the environment file:

   ```yaml
   ztp:
     os_version: "12.2610.1004.50"
   ```

   | Value | Installs |
   |-------|----------|
   | An exact `VsrVersion` | That build, or the run fails. Recommended |
   | `latest` | The newest general-availability build in the catalog at the time of the run |
   | `latest-preview` | The newest build including preview builds |

3. Pick the SBE for that version in [Step 2](#step-2-download-the-oem-sbe). The run checks that the OEM's manifest lists your SBE as validated with the pinned version, and stops at the Resolve stage if it doesn't:

   ```text
   No Dell SBE for model AX760 is validated with solution 12.2610.1004.50 in https://aka.ms/AzureStackSBEUpdate/DellEMC.
   ```

   That means the OEM hasn't published an SBE for that build yet. Pin a version the OEM supports, or wait for the OEM.

4. Run the [plan](#step-3-run-the-plan). It shows the pinned version in the Azure stage (`-OsVersion`) and the SBE check in Resolve, before anything changes.

**Testing a build before the OEM supports it.** To test a new build with an SBE the OEM hasn't validated for it, set `ztp.node_preparation.allow_unvalidated_sbe: true`. The run still uses the SBE in `sbe_bundle` and still checks its hash; it only skips the OEM's compatibility check, warns, and records `compatibilityChecked: false` in the handoff. The OEM doesn't support that combination, and cluster Validate or Deploy may refuse it. Use it for tests only. See the [environment file reference](environment-file.md#media-and-share).

To change the build of machines that are already provisioned, provision them again from `Boot`: delete their provisioned machines first, because a voucher can claim a machine only once. See [Resume a stopped run](#resume-a-stopped-run).

## Step 2: Download the OEM SBE

Prepare installs the network drivers from the OEM's Solution Builder Extension (SBE) and copies the SBE to `C:\SBE` on each node. The OEM's discovery manifest publishes the package's hash but no download address, so you download the package yourself. For Dell, that needs a Dell support account.

1. Pick an SBE validated with the OS version you pinned in `ztp.os_version`. This prints the newest one for your model:

   ```powershell
   ./scripts/simplified-provisioning/Get-ZtpSbe.ps1 -Oem Dell -Model AX760 -SolutionVersion <solution-version>
   ```

2. Download its three files from the OEM into one folder:

   | File | Example name pattern |
   |------|----------------------|
   | The package | `SBE_<OEM>_<family>_<version>.zip` |
   | Its metadata | `SBE_<OEM>_<family>_<version>.xml` |
   | The OEM discovery manifest | `SBE_Discovery_<OEM>.xml` |

   Learn's [import update step](https://learn.microsoft.com/azure/azure-local/update/update-via-powershell-23h2#step-3-import-and-rediscover-updates) uses the same three-file pattern. Put exactly one `SBE_*.zip` in the folder.

3. Set `ztp.node_preparation.sbe_bundle` to that folder.

The run checks the zip's SHA-256 against the OEM's published discovery manifest. If the manifest can't be reached, it uses the `SBE_Discovery_*.xml` in your folder.

## Step 3: Run the plan

Sign in, then run the entry point without `-Execute`:

```powershell
Connect-AzAccount -Tenant <tenant-id>
./scripts/simplified-provisioning/Invoke-ZtpEnvironment.ps1 -InfrastructureFile D:\ztp\infrastructure.yml
```

The plan changes nothing in Azure, on the BMCs or on the nodes. It does write the generated inputs, and it unpacks the SBE's network drivers into the cache. It shows:

- the share host address it will give the BMCs;
- the stage table, with each stage `pending` or `completed`;
- the exact command each stage would run, with credentials shown as `<in memory>`;
- the plan of the next stage from its own script. For a first run, that's Resolve: which maintenance ISO it would download;
- the Prepare plan: the SBE hash check, the number of network drivers indexed, and for each node "Not Ready to cluster yet". That warning is expected before provisioning.

Fix anything the plan reports before you go on. Run the plan for some nodes only with `-Node node-01`.

## Step 4: Run execute

```powershell
./scripts/simplified-provisioning/Invoke-ZtpEnvironment.ps1 -InfrastructureFile D:\ztp\infrastructure.yml -Execute
```

Add `-Node node-01, node-02` to limit the run to some nodes. With `-Execute`, the entry point:

1. Reads the BMC login from Key Vault.
2. Creates the resource group if it's missing.
3. Runs the ten provisioning stages with `-ConfirmNotClustered`: Resolve, Media, Boot, Bootstrap, Vouchers, Device, Azure, Ready, Network and Handoff. That flag tells the Boot stage the machines may be reinstalled. Device puts each static management address on the port with the node's management MAC in the maintenance environment, before the claim ([The Device stage](environment-file.md#the-device-stage)); Network checks it through Azure after the OS install ([The Network stage](environment-file.md#the-network-stage)).
4. Runs Prepare on all named nodes in parallel.

It ends with `<node> is ready for Validate` for each node, or throws with the reason. A failure gives a non-zero exit code.

## Watch the run

The run checks every stage itself and stops with the reason when a check fails. You watch it to see where it is. [Monitoring a run](monitoring.md) has what each stage checks, the event file format, Sonar step by step, and how to read what you see.

| Where | What you see |
| --- | --- |
| The console | `[HH:mm:ssZ] [ztp] ...` lines: the stage table at the start and each stage's evidence at the end. During Ready, each change of lifecycle, stage and job step is printed once. Prepare runs all nodes at once, and its lines start with `[<node>]`. |
| The event file | `ztp-events.jsonl` in the evidence folder (`ztp.evidence_path`), one JSON object per line. Follow it with `Get-Content -Wait -Tail 20 <evidence_path>\ztp-events.jsonl`. |
| AzureLocal Sonar | `Start-ZtpMonitor.ps1` writes a Sonar config for the event file and the edge machines, and starts [azurelocal-sonar](https://github.com/AzureLocal/azurelocal-sonar) from its `main` branch. Sonar only reads. |
| The Azure portal | **Azure Arc** > **Operations** > **Provisioning (preview)** > **Provisioned machines**. Wait for **Ready to cluster** ([Learn: verify Arc connectivity](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#step-5-verify-azure-arc-connectivity)). |

Start Sonar in a second window, from the clone root:

```powershell
Connect-AzAccount -Tenant <tenant-id>
./scripts/simplified-provisioning/Start-ZtpMonitor.ps1 -SonarPath D:\git\azurelocal-sonar `
    -SubscriptionId <subscription-id> -ResourceGroupName <resource-group> `
    -NodesFile ./config/simplified-provisioning/nodes.json `
    -EventLogPath <evidence_path>\ztp-events.jsonl -ClusterName <cluster-name> -Execute
```

Two things are normal on Dell AX-760 / iDRAC 7.30: a first OS install can fail with 5901, and the run resubmits it once; and a node can wait up to about 45 minutes at `AwaitingConnection` after the claim. See [Reading what you see](monitoring.md#reading-what-you-see), and [Troubleshooting](troubleshooting.md) for the causes.

## Resume a stopped run

Run the **same command with the same `-Node` list** again. Completed stages aren't repeated; the run starts at the first stage that didn't complete, then runs Prepare.

```powershell
./scripts/simplified-provisioning/Invoke-ZtpEnvironment.ps1 -InfrastructureFile D:\ztp\infrastructure.yml -Execute
```

To run a stage and every later one again, add `-From`:

| Where it stopped | Command |
| --- | --- |
| Ready timed out, or a node failed twice at `ProvisionOs` | `-From Ready`. Ready resubmits a failed job once more per run. |
| Device (the maintenance environment didn't answer, no adapter with the management MAC, or the status reported a failure) | `-From Device`. A port that's already right is left alone. Before the claim only: once Azure has claimed the node, use `-From Network`. |
| Network (no adapter with the management MAC, or a network adapter job failed or timed out) | `-From Network`. A port that's already right is left alone. |
| Handoff | `-From Handoff` |
| Prepare (a gate failed, or the node didn't come back) | `-From Prepare`. Prepare skips what's done. |
| Before Azure (Boot, Bootstrap, Vouchers) | Rerun without `-From`, or `-From Boot` to boot again. Boot reinstalls the machine. |

Things to know:

- **The state file is per set of nodes.** A run with `-Node node-01` doesn't see the state of a run with both nodes. Resume with the same list.
- **Vouchers are one-time use.** After a claim, the voucher is spent. The Azure stage never re-PUTs an edge machine that exists. To provision a claimed node again from `Boot`, first delete its edge machine: **Azure Arc** > **Operations** > **Machine provisioning (preview)** > **Provisioned machines**, select it, **Delete**. Learn's recovery for a failed claim does the same and waits 15 minutes before provisioning again ([Learn](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning#when-you-provision-new-machines-arm-template-validation-fails)).
- **To forget the state** of a set of nodes, delete `<media_path>\ztp-state\<run>.ztp-provisioning.state.json`. The entry point has no reset switch.
- **If a run failed during Boot,** check each node before you retry: the virtual media is ejected and the one-time boot override is cleared. `./scripts/simplified-provisioning/Mount-ZtpVirtualUsb.ps1 -NodeName node-01 -NodesFile ./config/simplified-provisioning/nodes.json -Credential $bmc -Action Status -SkipCertificateCheck -Execute` shows the slot, power state and boot override (read-only). `-Action Eject` ejects it.
- A stopped Boot or Vouchers stage can leave the share in place. The next Boot replaces it, and the Vouchers stage removes it. To remove it by hand: `./scripts/simplified-provisioning/Publish-MaintenanceIso.ps1 -Remove -ShareName <share-name> -SharePath <image folder> -Execute`.

## What "ready for Validate" means

A node is ready for Validate when every check below passed. The run checks all of them before it prints `<node> is ready for Validate`.

| Check | Where it's checked |
| --- | --- |
| Edge machine lifecycle `Provisioned`; `ProvisionOs` job reports `DeploymentSuccess` | Ready, Prepare gates 1 and 4 |
| Arc machine `Connected`, with an `arcMachineResourceId` | Ready |
| Arc extensions `AzureEdgeDeviceManagement`, `AzureEdgeLifecycleManager`, `AzureEdgeRemoteSupport` and `AzureEdgeTelemetryAndDiagnostics` all `Succeeded` | Ready (`Test-ProvisionedMachines.ps1`) |
| Static address `ip_address/prefix` on the adapter with the management MAC | Network (as Azure reports the adapter), Prepare gate 4 (in the OS) |
| Exactly one default gateway, on the management adapter. No DHCP on adapters of the same model. | Prepare gate 4 |
| Every adapter that has a driver in the SBE runs that driver version | Prepare gate 4 |
| `C:\SBE` holds the three SBE files, and the zip's hash matches | Prepare gate 4 |
| The deployment admin exists in local Administrators | Prepare gate 4 |
| Time syncs from one of `onprem.ntp_servers` | Prepare gate 4 |

It doesn't mean the cluster will deploy. Active Directory preparation, Validate and Deploy come next and are outside this solution.

## What to hand to the cluster deployment

The handoff is in `<media_path>\ztp-state\`:

| File | Contents |
| --- | --- |
| `<run>.ztp-handoff.json` | One entry per node: `name`, `serial`, `edgeMachineId`, `arcMachineName`, `arcMachineResourceId`, `arcMachineResourceGroup`. Also the site, `solution.vsrVersion`, the maintenance ISO version and hash, the SBE values, and timestamps. |
| `<run>.ztp-cluster-inputs.yaml` | `arc_machine_names` (host name to Arc machine name), `sbe` and `release` blocks, ready to paste into a cluster deployment environment file |
| `<run>.arc-machine-names.json` | Host name to Arc machine name |

**Use each node's `arcMachineResourceId` from the handoff**, not the host name. The service names the Arc machine `<device-id>-1`, not after the host, and replaces the `arcMachineResourceId` set at claim time. The handoff reads `arcMachineResourceId` from the edge machine after Ready, so it names that service-created machine. This was **proven on Dell AX-760 / iDRAC 7.30**.

```powershell
(Get-Content <media_path>\ztp-state\node-01+node-02.ztp-handoff.json -Raw | ConvertFrom-Json).nodes |
    Select-Object name, arcMachineResourceId
```

The `sbe` block carries the values the deployment ARM template takes as `sbeVersion`, `sbeFamily`, `sbePublisher`, `sbeManifestSource` and `sbeManifestCreationDate` ([Learn: ARM template parameters](https://learn.microsoft.com/azure/azure-local/deploy/deployment-azure-resource-manager-template#arm-template-parameters-reference)).

The handoff files hold Azure resource IDs of your subscription. Keep them out of source control.

**Before Deploy on build `12.2690`:** an earlier Deploy on that build failed at "Deploy Arc infrastructure components" with `ParentResourceNotFound`, because the Arc machine names are device IDs. Check this before you deploy. See [Troubleshooting](troubleshooting.md#deploy-fails-with-parentresourcenotfound-on-build-2690).
