# Orchestrator reference

> How to drive `Invoke-ZtpProvisioning.ps1` directly, without the environment file: its settings file, stage controls, the bootstrap watch, the event format and the handoff format.

Most operators don't need this page. `Invoke-ZtpEnvironment.ps1` writes the orchestrator's inputs from the environment file and runs it, then runs Prepare. See the [Operator guide](operator-guide.md) and [Design and architecture](architecture.md). Use the orchestrator directly when you need a setting the entry point fixes, or want to run one stage.

The orchestrator covers stages Resolve to Handoff. It doesn't run Prepare; run `Initialize-ZtpNode.ps1 -InfrastructureFile <file> [-Node ...] [-Execute]` after it.

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

Set `RfsWriteAttribute` to `true` for iDRAC 7.30 (see [iDRAC quirks](troubleshooting.md#idrac-quirks)). The example file has it `false`.

## Stages and their scripts

| Stage | Script | Result checked before the next stage |
| --- | --- | --- |
| Resolve | `Get-ZtpBootstrapIso.ps1`, `Get-ZtpSbe.ps1` | A verified ISO exists. Skipped when `BootstrapCacheDirectory` is empty; `SourcePath` is then the ISO. |
| Media | `New-ZtpVirtualUsbImage.ps1` | One image per node |
| Boot | `Start-MaintenanceBoot.ps1` (`Publish-MaintenanceIso.ps1`, `Mount-ZtpVirtualUsb.ps1`) | Every node attached and restarted |
| Bootstrap | `Wait-ZtpBootstrapComplete.ps1` | Every node `ReadyForPortal` |
| Vouchers | `Wait-ZtpVoucher.ps1`, then `Publish-MaintenanceIso.ps1 -Remove` | A valid voucher per node |
| Azure | `Invoke-ZtpAzureProvisioning.ps1` stages Prereqs, Validate, Plan, Execute | No voucher problem; deployment accepted |
| Ready | `Invoke-ZtpAzureProvisioning.ps1 -Stage Watch`, `Test-ProvisionedMachines.ps1` | Every machine ready to cluster and its Arc machine verified |
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

Each stage writes `StageStarted`, `StageCompleted` or `StageFailed` events (node `*`) to the event file.

`Invoke-ZtpPrepareMedia.ps1 -ConfigPath ... [-Execute]` runs only Resolve and Media, plus a read-back check of the images.

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

`New-ZtpHandoff.ps1` requires every machine to be ready to cluster. It writes the handoff JSON (schema version 1):

| Key | Contents |
| --- | --- |
| `nodes[]` | `name`, `serial`, `edgeMachineName`, `edgeMachineId`, `arcMachineName`, `arcMachineResourceId`, `arcMachineResourceGroup`, `connectivity`, `ready` |
| `site` | `resourceId`, `name` |
| `solution.vsrVersion` | The solution recipe version the machines installed |
| `bootstrap` | Maintenance ISO `version`, `isoSha256`, `url` |
| `sbe` | `oem`, `version`, `family`, `publisher`, `manifestSource`, `manifestCreationDate`, `packageSha256`, `compatibilityChecked` |
| `timestamps` | First and last bootstrap event, handoff time |

`Convert-ZtpHandoffToClusterInputs.ps1` turns it into the block a cluster deployment environment file reads:

```yaml
arc_machine_names:
  node-01: '<device-id-of-node-01>-1'
  node-02: '<device-id-of-node-02>-1'
sbe:
  version: '<sbe-version>'
  family: '<sbe-family>'
  publisher: Dell
  manifest_source: 'https://aka.ms/AzureStackSBEUpdate/DellEMC'
  manifest_creation_date: '<manifest-creation-date>'
release:
  azure_local_version: '<solution-version>'
  sbe_version: '<sbe-version>'
```

Only `arc_machine_names` is required by the cluster deployment inputs. Check `release.*` against your environment schema before you paste it. The handoff holds Azure resource IDs; keep it out of source control.

## Known gaps

- Role assignment names in `main.bicep` use the portal's per-run salt (`newGuid()`). A rerun after a partial failure reconciles role assignments only for machines it creates. Check by hand the role assignments of a machine that a failed run created.
- Hashing and extracting the downloaded zip are separate steps. Protect the cache folder from other writers.
