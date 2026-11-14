# Simplified provisioning scripts

Stage scripts that take nodes from bare metal to Arc-connected machines ready to cluster, using Microsoft's Simplified machine provisioning (preview, East US only) without a physical USB stick. PowerShell 7. Every script is a **plan by default**; hardware and Azure change only with an explicit `-Execute`.

ZTP ends at the Handoff: each machine is Provisioned in Azure and Arc-connected, with its management address on the management port (found by MAC). OEM drivers, an SBE (optional, only when a person asks for it), DHCP off on the other ports, DNS and time on the host, and the deployment admin are OS configuration, which comes next: [Phase 03 OS Configuration](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/).

Docs: [Prerequisites](../../docs/prerequisites.md), [Automated bootstrap](../../docs/automated-bootstrap.md) (the whole path, states, handoff, proofs still needed), [Bootstrap media](../../docs/bootstrap-media.md), [Redfish virtual USB and voucher read-back](../../docs/redfish-virtual-usb-vouchers.md) and [Azure provisioning from vouchers](../../docs/azure-provisioning-vouchers.md). They state what is proven live and what is not.

## Stages and scripts

| Stage | Script | What it does |
|-------|--------|--------------|
| All | `Invoke-ZtpProvisioning.ps1` | Runs the stages below in order (Resolve, Media, Boot, Bootstrap, Vouchers, Device, Azure, Ready, Network, Restore, Handoff), checks each result before the next, records completed stages in a state file and resumes there (`-Stage`, `-From`, `-ResetState`). Settings from parameters or a JSON file (`-ConfigPath`). |
| Resolve | `Get-ZtpBootstrapIso.ps1` | Finds the newest published maintenance ISO (`aka.ms/aep/installeros/<YYMM>`, calendar rule, preview opt-in), downloads it with resume, verifies it (trust on first use) and writes `bootstrap-manifest.json`. |
| Media | `Invoke-ZtpPrepareMedia.ps1` | Config-file driven: Resolve plus one verified image per node. No SBE: the OS install discovers its own. |
| Media | `New-ZtpVirtualUsbImage.ps1` | One raw `.img` per node: GPT, one FAT32 partition labelled `CDROM`, maintenance ISO contents, optional `edgeuser` hash. |
| Boot | `Publish-MaintenanceIso.ps1` | Read-write SMB share for the images, one generated account, TCP 445 only from the BMCs; `-Remove` undoes it. |
| Boot | `Mount-ZtpVirtualUsb.ps1` | `-Action Mount`, `Eject`, `Status` on the BMC USB-stick slot; read-back proof, one-time USB boot, `-Restart` needs `-ConfirmNotClustered`. |
| Boot | `Start-MaintenanceBoot.ps1` | BIOS settings first (`Set-ZtpBios.ps1`, only what differs; `hardware.bios` with `bios_during_provisioning` merged over it, originals saved), then publish and mount for all nodes in one process. |
| Bootstrap | `Wait-ZtpBootstrapComplete.ps1` | One read-only watch: Mounted, Booting, MaintenanceEnvironmentRunning, VoucherWritten, ReadyForPortal, with JSON-lines events (Redfish, voucher read-back, Azure prerequisites). |
| Vouchers | `Wait-ZtpVoucher.ps1` | Wait for the voucher in each image, eject, extract `<serial>.pem`; `-VoucherFolder` takes Configurator App vouchers. |
| Vouchers | `Read-ZtpVoucherFromImage.ps1` | Read and validate vouchers from images (read-only). |
| Device | `Set-ZtpDeviceConfiguration.ps1` | Before the claim: the static management address on the adapter with the management MAC, through the maintenance environment's REST service (`https://<maintenance address>:20001/BootstrapOobeService`, `SetArcBootstrapDeviceConfiguration`). Without a maintenance address it scans the provisioning DHCP range on TCP 20001 and finds the node by its MAC. Logs to `device-changes.jsonl`. |
| Azure | `Get-ZtpOsImage.ps1` | List or resolve the OS image versions (read-only). |
| Azure | `Invoke-ZtpAzureProvisioning.ps1` | Prereqs, Validate, Plan, Execute, Watch: site, configuration and edge machines from `bicep/main.bicep`. |
| Ready | `Wait-ZtpMachineReady.ps1` | Poll edge machines and `ProvisionOs` jobs until ready to cluster; `-RetryProvisionOs -Execute` resubmits a failed job. |
| Ready | `Update-ArcMachineNames.ps1` | Node to Arc machine name rows; `-MapPath` JSON map. |
| Ready | `Test-ProvisionedMachines.ps1` | Read-only check that the Arc machines are connected with the mandatory extensions. |
| Network | `Set-ZtpManagementAddress.ps1` | Verify-only: reads `edgeMachines/<node>/networkAdapters` (2026-10-01), finds the management port by MAC and records per node whether it has the file's address, with a reason naming the mode (A Reserved, B Static with DHCP, C Static without management DHCP). A static address the OS install reset is `Deferred` to OS configuration. Sends no job. `-ApplyThroughAzure` (opt-in, unreliable) moves a static address through `jobs/ApplyConfiguration` and logs to `network-changes.jsonl`. |
| Restore | `Restore-ZtpBios.ps1` | Sets each BIOS value changed for the install only (`bios_during_provisioning`) back to `hardware.bios`, or to the value saved before Boot; PATCH `OnReset`, restart through Redfish, wait until the BIOS reports it. The orchestrator then waits until every machine is Connected and ready to cluster again. Does nothing without `bios_during_provisioning`. |
| Handoff | `New-ZtpHandoff.ps1` | `ztp-handoff.json`, schema 2: what Azure generated during ZTP. Subscription, resource group, site, `solution.vsrVersion` (the build installed), and per node the edge machine and Arc machine names and IDs, `ready`, `managementAddressVerified` with its reason, `biosRestored`, `managementMode`, and `networkAdapters[]` (every port as Azure reports it after the install, matched by MAC to the file). Prints a table of the ports per node. The ISO details and the timestamps are in the state file, the stage evidence and the event log. |
| Handoff | `Convert-ZtpHandoffToClusterInputs.ps1` | The `arc_machine_names` block and `release.azure_local_version` for the cluster deployment environment file, YAML or JSON (`-Only arc_machine_names, release`). Reads handoff schema 2 and 1; a schema 1 `sbe` block is ignored. |
| Monitor | `Start-ZtpMonitor.ps1` | Writes a Sonar config for the event file and the edge machines and starts AzureLocal Sonar. |

## BMC tools

Outside the stages, for looking at or recovering the BMCs ZTP drives. Each takes the master `infrastructure.yml` (`-InfrastructureFile`, required, schema 5), `-NodeName` and `-Credential`; without `-Credential` the login is `hardware.bmc.username` and `.password` of the file (secret references), read by the toolkit's resolver (`Resolve-AzlBmcCredential`, azurelocal-toolkit `scripts/common/redfish/AzlRedfishCore.psm1`, found under `AZL_TOOLKIT_ROOT` or next to this repository). They never prompt. With neither a `-Credential` nor a login in the file they stop with exit code 2. Exit codes: 0 done or planned, 1 a BMC call failed, 2 an input is missing or not usable.

| Script | What it does |
|--------|--------------|
| `Get-ZtpBmcJob.ps1` | Read-only: each BMC's job queue (`<manager>/Jobs`, else `/redfish/v1/JobService/Jobs`), with `-JobState`, `-RecentMinutes` and `-Wait` until no job is active. |
| `Get-ZtpBootSetting.ps1` | Read-only: power state, boot mode, one-time override, boot order and boot options per node; `Unavailable:` options are counted as stale. |
| `Reset-ZtpBmc.ps1` | `Manager.Reset` (`GracefulRestart` or `ForceRestart`, if the BMC offers it): restarts the BMC, not the host. `-WhatIf` plans without a credential. |
| `Reset-ZtpBootSequence.ps1` | Dell iDRAC only (`hardware.vendor` Dell): clears the job queue (`JID_CLEARALL`), sets `SysPrepClean=Yes` with its BIOS job, clears a one-time override, restarts (`-NoRestart` stages it). Needs `-ConfirmNotClustered`; `-WhatIf` plans without a credential. |

Shared code (dot-sourced, no secrets in output): `ZtpVirtualUsb.Common.ps1` (image writer and reader, voucher validation, node list), `ZtpRedfish.Common.ps1` (small Redfish client), `ZtpAzure.Common.ps1` (ARM transport, status logic, OS image catalog), `ZtpHttp.Transport.ps1` (the one HTTP seam), `ZtpBootstrap.Common.ps1` (ISO resolution, resumable download, zip and image checks), `ZtpOem.Common.ps1` (OEM definitions loader: the BMC layer for the Bootstrap watch), `ZtpBios.Common.ps1` (BIOS settings from the node list, value comparison), `ZtpEnvironment.Common.ps1` (the infrastructure file: key check, schema 5 mapping, run folders), `ZtpEvents.Common.ps1` (events, state machine, signal readers), `ZtpBmcTool.Common.ps1` (the BMC tools' inputs: nodes and BMC addresses through `Read-ZtpInfrastructure`, the login through the toolkit's resolver, exit codes).

## Design rules

- **Explicit inputs.** No hidden environment lookups. Nodes come from `-Nodes` or `-NodesFile`, the BMC account from `-Credential`, Azure values from script parameters and the parameters file.
- **Plan by default.** `-Execute` is required to change hardware or Azure. `-Restart` is refused without `-ConfirmNotClustered`. A `ProvisionOs` retry needs both `-RetryProvisionOs` and `-Execute`.
- **Secrets stay in memory.** BMC passwords, the share password, the administrator password and the vouchers are never printed or written, except the voucher to `<serial>.pem`.
- **Each stage is callable alone** with explicit parameters, so an orchestrator can call them in order (Resolve, Media, Boot, Bootstrap, Vouchers, Device, Azure, Ready, Network, Restore, Handoff).

## Examples

- `../../config/simplified-provisioning/ztp-provisioning.example.json`: settings of `Invoke-ZtpProvisioning.ps1` (keys are its parameter names; no secrets).
- `../../config/simplified-provisioning/nodes.example.json`: node list (`name`, `service_tag`, `bmc_address`, optional `management_ip`, `maintenance_address` or `maintenance_scan_range`, `bios`, `bios_restore`). JSON schemas: `ztp-provisioning.schema.json` and `nodes.schema.json` in the same folder.
- `../../config/oem/<oem>.json`: OEM definitions, the BMC layer only (BMC kind, log services and signal patterns for the Bootstrap watch): Dell complete, Lenovo, HPE and Supermicro as layout. No SBE settings.
- `bicep/main.example.parameters.json`: Azure parameters (copy to `main.parameters.json`, git-ignored).

## Tests

```powershell
Import-Module Pester -RequiredVersion 5.9.1
Invoke-Pester ./tests
Invoke-ScriptAnalyzer -Path ./scripts/simplified-provisioning -Recurse -Severity Error, Warning
```

The tests build images in a temporary folder and mock every Redfish, ARM and HTTP call; nothing leaves the machine.
