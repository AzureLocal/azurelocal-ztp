# Design and architecture

> How the zero-touch provisioning (ZTP) solution takes bare machines to Provisioned and Arc-connected machines with their management address on the management port: the stages and their gates, what runs where, how data moves, how a run resumes, and where ZTP ends.

The solution automates Microsoft's [simplified machine provisioning (preview)](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning) without a USB stick or anyone in the rack. The baseboard management controller (BMC) presents a virtual USB image to each machine. The maintenance environment writes its ownership voucher back into that image. The solution then claims the machines in Azure, waits for the OS install, puts each management address on the port with the management MAC, and sets back any BIOS values it changed for the install only.

For the operator steps, see the [Operator guide](operator-guide.md). To run it from CI/CD, see [Running from a pipeline](automation-pipelines.md).

## The flow

![Azure Local ZTP: from the environment file to machines ready to join a cluster](./diagrams/ztp-flow.png)

The diagram source is [`diagrams/ztp-flow.drawio`](https://github.com/AzureLocal/azurelocal-ztp/blob/main/docs/diagrams/ztp-flow.drawio). It has four lanes: the operator, the management host, Azure, and the machine with its BMC. The operator supplies one input, the environment file. Then the operator runs one command: `Invoke-ZtpEnvironment.ps1 -InfrastructureFile <file>`, first as a plan, then with `-Execute`.

## Entry point and layers

| Layer | Script | Role |
| --- | --- | --- |
| Entry point | `Invoke-ZtpEnvironment.ps1` | Reads and checks the environment file. Writes the generated inputs (node list, orchestrator settings, Bicep parameters). Reads the BMC login, and the `edgeuser` password when the file names one, from Key Vault. Creates the resource group if it's missing. Runs the orchestrator. |
| Orchestrator | `Invoke-ZtpProvisioning.ps1` | Runs the eleven provisioning stages in order, Resolve to Handoff. Checks each stage's result. Records completed stages in a state file. |
| Stage scripts | `Get-ZtpBootstrapIso.ps1`, `New-ZtpVirtualUsbImage.ps1`, `Start-MaintenanceBoot.ps1`, `Set-ZtpBios.ps1`, `Mount-ZtpVirtualUsb.ps1`, `Publish-MaintenanceIso.ps1`, `Wait-ZtpBootstrapComplete.ps1`, `Wait-ZtpVoucher.ps1`, `Set-ZtpDeviceConfiguration.ps1`, `Invoke-ZtpAzureProvisioning.ps1`, `Wait-ZtpMachineReady.ps1`, `Set-ZtpManagementAddress.ps1`, `Restore-ZtpBios.ps1`, `New-ZtpHandoff.ps1`, `Convert-ZtpHandoffToClusterInputs.ps1` | Each stage's work. Each script can run alone and is a plan unless you pass `-Execute`. |
| OEM layer | `ZtpOem.Common.ps1`, `config/oem/<oem>.json` | The BMC layer only: the BMC kind, its manager and system IDs, the virtual-media slot, the log services and the signal patterns the Bootstrap watch reads. Adding an OEM is adding a file. The OEM files hold no SBE settings. |
| Template | `bicep/main.bicep` | Site, site configuration, role assignments and one edge machine per node, claimed with the vouchers. |

All scripts are in `scripts/simplified-provisioning/`. The orchestrator reference is [Orchestrator reference](automated-bootstrap.md).

## Stages and gates

A stage starts only when the gate before it passes. A gate that fails, or times out, stops the run and names the reason.

| # | Stage | What it does | Gate before the next stage |
| --- | --- | --- | --- |
| 0 | Start | Checks the environment file and stops if it's invalid. Writes the generated inputs. Reads the BMC login from Key Vault. Keys ZTP no longer reads are accepted and named in a note, for example `Note: ztp.node_preparation ignored: SBE belongs to OS configuration.` | The environment file is valid. |
| 1 | Resolve | Finds, downloads and hash-checks the maintenance ISO for the train named in `ztp.provisioning_iso`. Its version, URL and SHA-256 go to the stage evidence. ZTP resolves no SBE. | A verified ISO exists. |
| 2 | Media | Builds one raw virtual-USB image per node from the ISO: GPT, one FAT32 partition labelled `CDROM`. | One image per node. |
| 3 | Boot | Sets each node's BIOS from `hardware.bios` with `bios_during_provisioning` merged over it (the temporary values win), and saves each changed attribute's original value once. Shares the images over SMB, read-write, to the BMC addresses only. Closes stale SMB handles. Inserts each node's image in the BMC's USB-stick slot, sets a one-time boot and resets the node. All nodes in parallel. | On iDRAC 7.30 the boot override must read `Once/Floppy` before the reset (the USB-stick slot boots as virtual floppy there; see [iDRAC quirks](troubleshooting.md#idrac-quirks)). For 10 minutes after the reset, the iDRAC log must not show `OSE1002`, logged on the live runs as "C: boot completed" when the installed OS booted. |
| 4 | Bootstrap | Watches the BMC and the image until the maintenance environment writes its voucher back. | Every node reaches `ReadyForPortal`: a valid voucher, and the Azure prerequisites checked. |
| 5 | Vouchers | Reads each voucher from its image, checks the serial, replaces a spent local copy, ejects the media, removes the share. | One valid voucher per serial. |
| 6 | Device | In the maintenance environment, before the claim: sets each static management address on the port with the node's management MAC through the Configurator App's REST service (`https://<maintenance_address>:20001/BootstrapOobeService`, `SetArcBootstrapDeviceConfiguration`). A node without `maintenance_address` is found by a scan: every address of `network_intents.management.provisioning_dhcp_range` (default: the management subnet) is probed on TCP 20001, and the node is the responder whose `GetNetworkAdapters` lists its management MAC. The scan repeats until the node is found or 30 minutes pass. See [The Device stage](environment-file.md#the-device-stage). | Each static node reports the static configuration on its management adapter in the maintenance environment. |
| 7 | Azure | Checks prerequisites, builds the Bicep template, runs a what-if, then submits the claim. With `static_method: device` (the default) the site's network setting is Automatic and the claim carries no Manual adapter. Refuses to submit when a voucher is missing. | ARM accepted the deployment. |
| 8 | Ready | Waits for "Ready to cluster" on every node. A 404 or 409 on `jobs/ProvisionOs` before the service creates the job means "not there yet". If a `ProvisionOs` job fails, it re-PUTs `jobs/ProvisionOs` once with the edge machine's existing OS profile and user details. | Each node: lifecycle `Provisioned`, `ProvisionOs` succeeded, Arc `Connected`, mandatory extensions `Succeeded`. |
| 9 | Network | The backstop after the install. Checks each static management address on the port with the node's management MAC, through Azure's per-NIC API (`edgeMachines/<node>/networkAdapters`, `jobs/ApplyConfiguration`), and moves it there if needed. A port that holds the address by mistake goes to DHCP first. With `static_method: site` the OS install ignores the MAC and uses the first ready port; see [Static IP lands on the wrong NIC](troubleshooting.md#static-ip-lands-on-the-wrong-nic). `dhcp` and `preconfigured` nodes are only reported. Each node's result goes to the state file for the handoff. | Each static node's management adapter reports the address, mask, gateway, DNS and VLAN, and no other adapter reports the address. |
| 10 | Restore | Sets every `bios_during_provisioning` attribute back to `hardware.bios[key]` when the file gives one, otherwise to the original value Boot saved. PATCH with `OnReset`, restart through Redfish, wait until the BIOS reports the values. Then waits `RestoreSettleMinutes` (5) and runs the Ready watch and check again. Without `bios_during_provisioning` it does nothing and says so. | Each restarted node is `Connected` and ready to cluster again. |
| 11 | Handoff | Writes the handoff file and the cluster inputs with each machine's Arc machine name and `arcMachineResourceId`. | Both files written. |

All eleven stages are the orchestrator. ZTP ends at the Handoff; see [Where ZTP ends](#where-ztp-ends).

### Why Restore exists

Some hardware must look different during the install than in production. Example: an Emulex Fibre Channel HBA presents a SAN LUN that the install could pick as a target. The environment file then says:

```yaml
hardware:
  bios:
    Slot2: Enabled
    EmbNic1Nic2: Enabled
  bios_during_provisioning:
    Slot2: Disabled
```

Boot turns slot 2 off before the maintenance boot, so the LUN stays out of the install. Restore turns it back on after the Network stage, before the handoff. `cluster_nodes[].bios_during_provisioning` sets values for one node only.

## What runs where

| Where | What runs there |
| --- | --- |
| Management host | Every script, in PowerShell 7, elevated. It must be Windows because the Boot stage shares the images with Windows SMB, a local account and a Windows Firewall rule. It's the Redfish client to the BMCs, the REST client to the maintenance environment in the Device stage, and the ARM client to Azure. All media, vouchers, state and handoff files live on this host. |
| BMC | Mounts the node's image from the host's SMB share as a USB stick. Applies the BIOS settings, the one-time boot and the resets. Writes the event log the Boot gate reads. |
| Machine | Boots the maintenance environment from the virtual USB. It installs itself to the boot disk and writes the voucher back into the image. Its REST service takes the static management address in the Device stage. After the claim, it calls home and Azure installs the OS, the Arc agent and the extensions. The OS install does its own SBE discovery (the `ProvisionOs` job's `SBEDiscoveryDownload` step). |
| Azure | The site, site configuration, edge machines and role assignments from `bicep/main.bicep`. The device onboarding service, the `ProvisionOs` job, the per-NIC API, and Azure Arc. Key Vault holds the BMC login, the provisioning administrator password and, when you set one, the `edgeuser` password. |

### Network paths

| From | To | Port | Used by |
| --- | --- | --- | --- |
| Management host | Each BMC | TCP 443 (Redfish over HTTPS) | Boot, Bootstrap, Vouchers (eject), Restore |
| Each BMC | Management host | TCP 445 (SMB) | Boot: the BMC's SMB client connects out from its management IP to the host's share, then reads and writes the image. No inbound SMB port is needed on the BMC. |
| Management host | Each node's maintenance address, or every address of `provisioning_dhcp_range` | TCP 20001 (HTTPS, self-signed) | Device: the maintenance environment's REST service, before the claim. Without `maintenance_address`, the scan probes the range. |
| Management host | Azure, Microsoft download | TCP 443 | Every stage that reads or changes Azure, Network included (it changes the node's ports through Azure, not on the node); Resolve |
| Each node | Azure | TCP 443 (and 80) | Onboarding, OS download, Arc ([firewall requirements](https://learn.microsoft.com/azure/azure-local/concepts/firewall-requirements)) |

The host needs inbound TCP 445 from the BMC addresses only. `Publish-MaintenanceIso.ps1` creates that Windows Firewall rule, scoped to the BMC addresses in the environment file. It also creates a dedicated local account with Change access on the share (Read when it shares an ISO). The Vouchers stage removes the share, the rule and the account. ZTP makes no WinRM connection to the nodes.

## Data flow

| Data | Path | Where it's kept |
| --- | --- | --- |
| Maintenance ISO | Microsoft download link `https://aka.ms/aep/installeros/<YYMM>`, then the host cache, then one image per node, then the SMB share, then the BMC, then the machine. | `<media_path>/bootstrap/<version>/` with a trust-on-first-use manifest. Microsoft publishes no hash for this download; see [Bootstrap media](bootstrap-media.md). Its version, URL and SHA-256 are in the Resolve stage's evidence. |
| Per-node image | Built on the host, shared to the BMC, written back by the machine. | `<media_path>/ztp-virtual-usb/ztp-usb-<node>.img` |
| Ownership voucher | The machine writes `\vouchers\<serial>\*.pem` into its own image. The host reads it after the eject and writes `<serial>.pem`. At claim time it's base64-encoded into a secure deployment parameter. It's never printed. | `<media_path>/vouchers/<serial>.pem`. Vouchers are one-time use. |
| BMC login | Key Vault, read into memory. | Never written. |
| `edgeuser` password | Key Vault (`ztp.maintenance_password_secret`), read into memory. Only its SHA-512 crypt hash goes into the images; the Device stage signs in with it. Without the secret, the published default `Password1`. | Key Vault |
| SMB share account | Generated with a random password for each publish, held in memory only, removed after the Vouchers stage. | Never written. |
| Provisioning administrator password | Must already exist as a Key Vault secret. The template passes only the secret's resource ID. Each edge machine's identity gets a constrained right to grant Key Vault Secrets User on the vault, so the OS install can read it. ZTP itself doesn't read it. | Key Vault |
| BIOS originals | Boot reads each attribute it changes and saves the value found, once per attribute and node. Restore sets temporary values back to it when `hardware.bios` gives no final value. | The state file (`biosOriginal`) and `<evidence_path>/bios-changes.jsonl` (phases `original`, `requested`, `applied`). |
| Management address result | The Network stage records per node whether the port with the management MAC carries the environment file's address, or why not. | The state file (`stages.Network.data`), then the handoff. |
| The claim | One ARM deployment of `bicep/main.bicep` with the vouchers in memory. | Resource group deployment history |
| Handoff | Written at the end, schema 2. Holds only what Azure generated during ZTP: the site, the installed solution version (`solution.vsrVersion`), and per node the edge machine and Arc machine names and IDs, read from the edge machine after Ready, so it names the service-created `<device-id>-1` Arc machine. Also each node's `managementAddressVerified` and `managementAddressReason` from Network, and `biosRestored` from Restore. No addresses, MACs, ISO details or timestamps: those are in the environment file, the state file and the event log. | `<media_path>/ztp-state/<run>.ztp-handoff.json`, `<run>.ztp-cluster-inputs.yaml`, `<run>.arc-machine-names.json` |
| Events | One JSON line per state change and per stage. | `<evidence_path>/ztp-events.jsonl` |

`<media_path>` and `<evidence_path>` are `ztp.media_path` and `ztp.evidence_path` of the environment file, by default `%ProgramData%\AzureLocalZtp\<site>\media` and `\evidence`; `-MediaPath` and `-EvidencePath` of `Invoke-ZtpEnvironment.ps1` override them. Neither may be inside a git working tree. `<run>` is the node names of the run joined with `+`, for example `node-01+node-02`.

The entry point also writes three generated files inside the clone. They hold environment values, so keep them out of source control:

- `config/simplified-provisioning/nodes.json`
- `config/simplified-provisioning/ztp-provisioning.json`
- `scripts/simplified-provisioning/bicep/main.parameters.json`

## Idempotence and resume

- **State per set of nodes.** The orchestrator records each completed stage, with its evidence, in `<media_path>/ztp-state/<run>.ztp-provisioning.state.json`. Each set of nodes keeps its own state, so a run for `node-02` alone never disturbs a run for both nodes.
- **A rerun resumes.** Run the same command again with the same `-Node` list. The orchestrator starts at the first stage that didn't complete.
- **`-From <Stage>`** runs that stage and every later one, whatever the state file says. The stages you can name are `Resolve`, `Media`, `Boot`, `Bootstrap`, `Vouchers`, `Device`, `Azure`, `Ready`, `Network`, `Restore` and `Handoff`.
- **The Azure stage never re-PUTs an existing edge machine.** It claims only the nodes whose edge machine doesn't exist yet. If ARM already has every edge machine, Azure goes straight to Ready.
- **Images.** A run from the start, or `-From Resolve` or `-From Media`, rebuilds the images. That's a fresh provisioning.
- **BIOS.** Boot changes only the attributes that differ. It saves an attribute's original value the first time it changes it; a later Boot run reads the already-changed value and doesn't overwrite the saved one.
- **Device** reads the maintenance environment's adapters first and sends nothing when the management adapter is already static and right.
- **Network** reads each node's adapters first and sends no job to an adapter that already reports the right configuration. A rerun follows an unfinished job with the same target instead of sending another.
- **Restore** reads the BIOS first. A node whose BIOS already reports the final values isn't restarted.

Running from `Boot` or earlier reinstalls the machines. For a node that's already claimed, delete its edge machine in Azure first. See [Resume a stopped run](operator-guide.md#resume-a-stopped-run).

## Parallelism

| Stage | How nodes run |
| --- | --- |
| Media | The first image is built. The others are byte copies. |
| Boot | One worker per node (`ForEach-Object -Parallel`). Each one sets its BIOS, mounts, resets and watches its own BMC. A failure on one node doesn't stop the others. The stage fails afterwards with every node's error. |
| Bootstrap, Vouchers, Ready | One polling loop over all nodes. |
| Device | One scan for all nodes without a maintenance address, probing every address of the range at once. |
| Azure | One deployment claims every node that has no edge machine yet. |
| Restore | One worker per node (`ForEach-Object -Parallel`), then one Ready watch over all nodes. |

## Where ZTP ends

ZTP ends at the Handoff. Each machine is **Provisioned** in Azure, **Arc-connected**, and has its management IP on the management NIC (found by MAC) as the environment file says. The Arc machine names and IDs are in the handoff. The provisioned OS names the ports `Port0` to `Port6`, so later scripts must find NICs by MAC.

These steps are not ZTP:

| Not done | Notes |
| --- | --- |
| OS configuration | OEM drivers, the SBE in `C:\SBE`, DHCP off on the other NICs, DNS and time on the host, and the deployment admin. They come next, before Validate and Deploy: [Phase 03 OS Configuration](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/) (azurelocal-toolkit Phase 03), part of [Part 4 Cluster Deployment](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/). |
| Active Directory preparation | Learn lists it as an on-site prerequisite of simplified machine provisioning ([prerequisites](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#on-site-prerequisites)). |
| Cluster Validate and Deploy | Use the handoff's `arcMachineResourceId` values with the portal or the ARM template. See [What to hand to the cluster deployment](operator-guide.md#what-to-hand-to-the-cluster-deployment) and [Phase 05 Cluster Deployment](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-05-cluster-deployment/). |
| Firmware updates | ZTP installs no drivers or firmware. |
| Arc gateway or a proxy | Simplified machine provisioning doesn't support Arc gateway in the preview ([Learn](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#about-simplified-machine-provisioning-process)). The environment-file path sets the site connectivity to `Public`. |
| Management VLAN | The environment-file path sets no VLAN. Learn says a management VLAN must be on the physical adapter before Arc registration ([management VLAN ID](https://learn.microsoft.com/azure/azure-local/plan/cloud-deployment-network-considerations#management-vlan-id)). |

## Limits

- Simplified machine provisioning is in **preview**. Only the **East US** region supports the provisioning resources ([Learn](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#azure-prerequisites)).
- Learn's validated hardware for this flow is Lenovo ThinkAgile MX650 V3 and V4, HPE ProLiant DL360 Gen11, and Dell AX-750 and AX-650 ([hardware prerequisites](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#hardware-prerequisites)). The end-to-end flow here was **proven on Dell AX-760 / iDRAC 7.30**, which isn't on that list. It works, but Microsoft doesn't support it for this flow.
- The BMC handling is proven on Dell iDRAC only. `config/oem/` also has HPE, Lenovo and Supermicro definitions; their log patterns are unverified.
