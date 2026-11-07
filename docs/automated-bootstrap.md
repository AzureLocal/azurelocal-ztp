# Orchestrator reference

> How to drive `Invoke-ZtpProvisioning.ps1` directly, without the environment file: its settings file, stage controls, the state file, the bootstrap watch, the event format and the handoff format.

Most operators don't need this page. `Invoke-ZtpEnvironment.ps1` writes the orchestrator's inputs from the environment file and runs it. See the [Operator guide](operator-guide.md) and [Design and architecture](architecture.md). Use the orchestrator directly when you need a setting the entry point fixes, or want to run one stage.

The orchestrator covers every ZTP stage, Resolve to Handoff. ZTP ends at the Handoff: each machine is Provisioned in Azure, Arc-connected, with its management address on the management port (found by MAC). OS configuration comes next; see [Where ZTP ends](architecture.md#where-ztp-ends).

## Run it

The orchestrator reads its settings from parameters, or from a JSON file whose keys are its parameter names (`-ConfigPath`). A parameter wins over the file. Credentials are never in the file.

```powershell
Copy-Item ./config/simplified-provisioning/ztp-provisioning.example.json ./config/simplified-provisioning/ztp-provisioning.json   # edit your values
Copy-Item ./config/simplified-provisioning/nodes.example.json ./config/simplified-provisioning/nodes.json
Copy-Item ./scripts/simplified-provisioning/bicep/main.example.parameters.json ./scripts/simplified-provisioning/bicep/main.parameters.json

# Plan: changes nothing; prints every stage's command and the plan of the next stage
./scripts/simplified-provisioning/Invoke-ZtpProvisioning.ps1 -ConfigPath ./config/simplified-provisioning/ztp-provisioning.json

# Execute: resumable; a rerun continues at the first stage that didn't complete
$bmc = Get-Credential -Message 'BMC account'
Connect-AzAccount
./scripts/simplified-provisioning/Invoke-ZtpProvisioning.ps1 -ConfigPath ./config/simplified-provisioning/ztp-provisioning.json `
    -BmcCredential $bmc -ConfirmNotClustered -RetryProvisionOs -Execute
```

`config/simplified-provisioning/ztp-provisioning.schema.json` validates the settings file, and `nodes.schema.json` the node list. Pass `-AdminPassword` (a `SecureString`) only if the provisioning administrator secret doesn't exist yet; the Azure stage then writes it to Key Vault. The environment-file path never does that.

Set `RfsWriteAttribute` to `true` for iDRAC 7.30 (see [iDRAC quirks](troubleshooting.md#idrac-quirks)). The example file has it `true`.

An older settings file can still carry `SbeModel`, `SbeFamily`, `SbeSolutionVersion` or `SbePackagePath`. The run accepts them and prints one line per key, for example `SbePackagePath in ./ztp-provisioning.json ignored: SBE belongs to OS configuration.` Any other unknown key stops the run.

## Stages and their scripts

| Stage | Script | Result checked before the next stage |
| --- | --- | --- |
| Resolve | `Get-ZtpBootstrapIso.ps1` | A verified maintenance ISO exists. Its version, URL and SHA-256 go to the stage evidence. Skipped when `BootstrapCacheDirectory` is empty; `SourcePath` is then the ISO. |
| Media | `New-ZtpVirtualUsbImage.ps1` | One image per node |
| Boot | `Start-MaintenanceBoot.ps1` (`Set-ZtpBios.ps1`, `Publish-MaintenanceIso.ps1`, `Mount-ZtpVirtualUsb.ps1`) | Every node's BIOS reports the node list's `bios`; every node attached and restarted. Each changed attribute's original value is saved in the state file. |
| Bootstrap | `Wait-ZtpBootstrapComplete.ps1` | Every node `ReadyForPortal` |
| Vouchers | `Wait-ZtpVoucher.ps1`, then `Publish-MaintenanceIso.ps1 -Remove` | A valid voucher per node |
| Device | `Set-ZtpDeviceConfiguration.ps1` | Each static node reports the static address on its management adapter in the maintenance environment. A node without `maintenance_address` is found first by scanning `maintenance_scan_range` (or the management subnet) on TCP 20001 for its management MAC. |
| Azure | `Invoke-ZtpAzureProvisioning.ps1` stages Prereqs, Validate, Plan, Execute | No voucher problem; deployment accepted |
| Ready | `Invoke-ZtpAzureProvisioning.ps1 -Stage Watch`, `Test-ProvisionedMachines.ps1` | Every machine ready to cluster and its Arc machine verified |
| Network | `Set-ZtpManagementAddress.ps1` | Each static node's management adapter (found by MAC) reports the static address, and no other adapter reports it. Each node's result goes to the state file for the handoff. |
| Restore | `Restore-ZtpBios.ps1` (`Set-ZtpBios.ps1`), then `Invoke-ZtpAzureProvisioning.ps1 -Stage Watch` and `Test-ProvisionedMachines.ps1` | Every node's BIOS reports the final values of its `bios_restore`; each machine is `Connected` and ready to cluster again. Without `bios_restore` in the node list the stage is a no-op: `nothing to restore: no bios_during_provisioning`. |
| Handoff | `New-ZtpHandoff.ps1`, `Convert-ZtpHandoffToClusterInputs.ps1` | Both files written |

What each stage does is in [Design and architecture](architecture.md#stages-and-gates).

### Stage controls

| Parameter | Effect |
| --- | --- |
| (none) | Runs from the first stage the state file doesn't record as completed. |
| `-Stage <name>` | Runs one stage again. |
| `-From <name>` | Runs that stage and every later one, whatever the state file says. |
| `-ResetState` | Forgets the recorded stages before the run. |
| `-StatePath` | The state file (default `./ztp-provisioning.state.json`). It records the node list; a run with other nodes is refused. |
| `-RebuildImages` | Replaces existing images in Media. |
| `-KeepShare` | Leaves the share, firewall rule and account after Vouchers. |
| `-VoucherFolder` | Takes vouchers downloaded with the Configurator App instead of reading them from the images. |
| `-RestoreSettleMinutes` | Restore: how long to wait after the BIOS restart before checking the Arc machines again (default 5). An Arc machine reads `Connected` for a while after its host went down. |
| `-BiosTimeoutMinutes` | Restore: how long to wait for a node's BIOS to report the restored values (default 30). |

`-Stage` and `-From` take `Resolve`, `Media`, `Boot`, `Bootstrap`, `Vouchers`, `Device`, `Azure`, `Ready`, `Network`, `Restore` or `Handoff`. `-Stage` also takes `All` (the default). `Invoke-ZtpEnvironment.ps1 -From` takes the same names.

Restore with `-Execute` needs `-BmcCredential` and `-ConfirmNotClustered` when a node has something to restore, because applying the BIOS restarts the node.

Each stage writes `StageStarted`, `StageCompleted` or `StageFailed` events (node `*`) to the event file.

`Invoke-ZtpPrepareMedia.ps1 -ConfigPath ... [-Execute]` runs only Resolve and Media (the maintenance ISO and the images), plus a read-back check of the images.

### The node list's BIOS keys

`Invoke-ZtpEnvironment.ps1` writes these from the environment file. Set them yourself when you drive the orchestrator directly.

| Key | Contents |
| --- | --- |
| `nodes[].bios` | What Boot sets before the maintenance boot: `hardware.bios` with the node's own values, and `bios_during_provisioning` merged over it. For example `{ "Slot2": "Disabled", "EmbNic1Nic2": "Enabled" }`. |
| `nodes[].bios_restore` | What Restore sets back: one entry per `bios_during_provisioning` key, with the final value from `hardware.bios`, or `""` for the value saved before Boot changed it. For example `{ "Slot2": "Enabled" }`. |

## The state file

One JSON file per set of nodes (`-StatePath`). The orchestrator writes it after every stage.

| Key | Contents |
| --- | --- |
| `orchestrator`, `version` | `Invoke-ZtpProvisioning`, `1`. Another value stops the run. |
| `nodes` | The node names of the run. |
| `stages.<name>.completed` | UTC time the stage completed. |
| `stages.<name>.evidence` | The same text the console prints for the stage. |
| `stages.Resolve.data` | `isoPath`, `bootstrapVersion`, `isoSha256`, `bootstrapUrl`, `bootstrapManifest`. A later run takes the ISO from `isoPath` when `SourcePath` is empty. |
| `stages.Network.data.managementAddress[]` | Per node: `node`, `verified`, `reason`. The handoff's `managementAddressVerified` and `managementAddressReason` come from here. |
| `stages.Restore.data.restored` | Node name to the attributes Restore set back. The handoff's `biosRestored` comes from here. |
| `biosOriginal` | Node name to each BIOS attribute's value as found, before Boot first changed it. Saved once per attribute: a later Boot run reads the already-changed value and doesn't overwrite it. `-ResetState` clears it with the rest of the state, so keep `hardware.bios` complete for every temporary key. |
| `updated` | UTC time of the last write. |

The same BIOS values are also in `bios-changes.jsonl` beside the event file, one line per attribute and phase (`original`, `requested`, `applied`).

## The bootstrap watch

`Wait-ZtpBootstrapComplete.ps1` polls all nodes in one loop. It starts at 15 seconds and backs off by 1.5 times up to 120 seconds while nothing changes. None of its signals needs a credential on the node.

| Signal | Source | Strength |
| --- | --- | --- |
| Virtual media inserted, slot write protection | Redfish `VirtualMedia` (GET) | Strong for `Mounted`. A write-protected attach is rejected while there's no voucher. |
| Power state, boot override consumed, power transitions | Redfish `Systems` (GET) | Weak. Only changes the reported state. |
| BMC log entries matching the OEM patterns in `config/oem/<oem>.json` | Redfish `LogServices` | Weak. The patterns are conventions, marked unverified in the OEM file. |
| `\vouchers\<serial>\*.pem` valid in the read-write image | Image read-back on the host | Decisive. **Proven on Dell AX-760 / iDRAC 7.30**: the maintenance environment writes the voucher back into the image. |
| Voucher in a Configurator App folder | `-VoucherFolder` | Fallback. Replaces the BMC and image signals. |
| Feature `Microsoft.DeviceOnboarding/AzureLocalZTP`, resource providers, OS image catalog | ARM GET | Shows Azure is ready to claim, not that it saw the device |

States per node: `NotStarted`, `Mounted`, `Booting`, `MaintenanceEnvironmentRunning`, `VoucherWritten`, `ReadyForPortal`. Failure states: `MediaRejected`, `VoucherMissing`, `Failed`.

Learn documents no Azure-side signal that a device is waiting to be claimed. `ReadyForPortal` therefore means "a valid, new voucher is in hand and the Azure prerequisites are verified". Weak signals never fail a node. A node fails only at the voucher deadline (`VoucherMissing`, default 90 minutes) or the overall budget (`Failed`). A voucher that's already in the image before the node is seen booting isn't accepted until the node boots or the voucher changes, so an image reused from an earlier run can't pass.

### Events

One JSON object per line:

```json
{"timestamp":"2026-10-15T14:00:00.0000000Z","node":"node-01","state":"VoucherWritten","evidence":"valid ownership voucher read back from the image; voucher SHA256 <hash>","nextAction":"Checking that Azure is ready to claim the voucher.","level":"Info","stage":"Bootstrap"}
```

Levels are `Info`, `Warning` and `Error`. Vouchers are never logged, only their SHA-256. Every `state` value, and how to follow the file, is in [Monitoring a run](monitoring.md#the-event-file). `Start-ZtpMonitor.ps1` points AzureLocal Sonar at this file; see [Follow the run in Sonar](monitoring.md#follow-the-run-in-sonar).

## Handoff format

`New-ZtpHandoff.ps1` requires every machine to be ready to cluster. It writes the handoff JSON, schema version 2. It holds only what Azure generated during ZTP, never a value the environment file already holds:

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
    "managementAddressVerified": true, "managementAddressReason": null,
    "biosRestored": { "Slot2": "Enabled" }
  } ]
}
```

| Key | Contents |
| --- | --- |
| `schemaVersion`, `generatedUtc`, `tool` | `2`, the time the file was written, `azurelocal-ztp` |
| `subscriptionId`, `resourceGroup` | Where the edge machines are |
| `site` | `resourceId`, `name` |
| `solution.vsrVersion` | The solution build the machines actually installed. The environment file may say `latest`. |
| `nodes[]` | `name`, `serial`, `edgeMachineName`, `edgeMachineId`, `arcMachineName`, `arcMachineResourceId`, `arcMachineResourceGroup`, `ready` |
| `nodes[].managementAddressVerified` | From the Network stage: `true` when the port with the management MAC carries the environment file's address |
| `nodes[].managementAddressReason` | `null` when verified. Otherwise a short reason, for example `dhcp: the management port Port0 reports 192.0.2.200, the infrastructure file expects 192.0.2.12`, or `no Network stage result for this node`. |
| `nodes[].biosRestored` | The attributes Restore set back, attribute to value. `{}` when none. |

Schema 1 also had `sbe`, `bootstrap`, `timestamps`, `connectivity` and a top-level `arcMachineResourceGroup`. Schema 2 drops them. The maintenance ISO's version, URL and SHA-256 are in the Resolve stage's evidence: the state file's `stages.Resolve.data` and the `StageCompleted` event, for example `maintenance ISO 10.2610.0.3061 (GA), SHA256 ..., from <url>`. Times are in the event log (`StageStarted` and `StageCompleted` per stage) and the state file (`stages.<name>.completed`).

A node whose management address isn't verified doesn't stop the handoff. `New-ZtpHandoff.ps1` warns `Management address not verified on: <node> (<reason>). OS configuration must fix it before Validate.`

`Convert-ZtpHandoffToClusterInputs.ps1` reads schema 2 and schema 1 and turns the handoff into the block a cluster deployment environment file reads:

```yaml
arc_machine_names:
  node-01: node-01
  node-02: node-02
release:
  azure_local_version: 12.2609.1003.7
```

The Arc machine names are the ones Azure reports on the edge machine after Ready. On the live runs the service named them `<device-id>-1`, not after the host; see [Arc machine names](troubleshooting.md#arc-machine-names). `-Only` takes `arc_machine_names` and `release`. Only `arc_machine_names` is required by the cluster deployment inputs. A schema 1 handoff's `sbe` block is ignored. Check `release.*` against your environment schema before you paste it. The handoff holds Azure resource IDs; keep it out of source control.

## Known gaps

- Role assignment names in `main.bicep` use the portal's per-run salt (`newGuid()`). A rerun after a partial failure reconciles role assignments only for machines it creates. Check by hand the role assignments of a machine that a failed run created.
- Hashing and extracting the downloaded zip are separate steps. Protect the cache folder from other writers.
