# Monitoring a run

> What a zero-touch provisioning run watches at each stage, where it writes what it sees, and how you follow it: in the console, in the event file, in AzureLocal Sonar, with your own Azure calls, and in the portal.

The run watches itself. Every stage after Boot is a wait with its own checks, poll interval and timeout, and the run stops with the reason when a check fails. You don't have to watch anything for the run to be correct. You watch it to know where it is, and to tell a slow stage from a stuck one.

Everything on this page comes from the scripts in `scripts/simplified-provisioning/`. The intervals and timeouts are the values `Invoke-ZtpEnvironment.ps1` passes, or the script defaults where it passes none. Examples come from live runs on two Dell AX-760 nodes with iDRAC 7.30 and Azure Local build `12.2690.1003.15`.

## What the run watches at each stage

Every Azure read is an ARM GET through `Invoke-AzRestMethod` under your Az PowerShell sign-in. Every BMC read is a Redfish GET. The run sends a write only where the table says so.

| Stage | What is checked | Source and how it's read | How often | Timeout | Pass | Fail |
| --- | --- | --- | --- | --- | --- | --- |
| Boot: attach | The node's image is in the USB-stick slot, with the expected write protection | Redfish GET of the virtual media slot, right after `InsertMedia` (`Mount-ZtpVirtualUsb.ps1`) | Once per node | None | The slot reports `Inserted` with this node's image. With `-RfsWriteAttribute`, which the entry point sets, a `WriteProtected=True` report is only a warning: iDRAC 7.30 reports it even when the slot is writable. | The image isn't attached, or it's attached write-protected without `-RfsWriteAttribute`. |
| Boot: override read-back | The one-time boot to the virtual USB slot took | Redfish GET of the system, `Boot.BootSourceOverrideEnabled` and `BootSourceOverrideTarget`. Only when the BMC doesn't offer `Usb` as a target (iDRAC 7.30). Otherwise the run sets `Once/Usb` without a read-back. | Every 5 s | 120 s | The system reports `Once/Floppy`. Only then is the node reset. | Any other value after 120 s. The node isn't reset. |
| Boot: lifecycle log watch | The node didn't boot its installed OS | Redfish GET of the iDRAC lifecycle log, `LogServices/Lclog/Entries?$top=25` | Every 20 s | 10 minutes after the reset | No `OSE1002` entry newer than the reset for 10 minutes. On the live runs `OSE1002` was logged as "C: boot completed", when the installed OS started. | An `OSE1002` entry newer than the reset: the stage fails for that node. |
| Bootstrap: BMC signals | Media inserted and its write protection, power state, the one-time override consumed, power transitions after it, BMC log entries | Redfish GETs of the manager's virtual media, the system, and the log services and message patterns in `config/oem/<oem>.json` (Dell: `Lclog` and `Sel`) (`Wait-ZtpBootstrapComplete.ps1`) | 15 s, backing off by 1.5 times up to 120 s while nothing changes | None of its own. A stall writes a warning after 20 minutes in the same state. | Moves the node to `Mounted`, `Booting` or `MaintenanceEnvironmentRunning`. These signals are weak and never fail a node. | `MediaRejected`: this node's image isn't inserted after 3 minutes, or it's write-protected without `-RfsWriteAttribute`. |
| Bootstrap: voucher in the image | A complete, valid ownership voucher for the node's serial under `\vouchers\<serial>\` | The host opens the node's image file read-only, shared with the iDRAC's open handle, and validates the `.pem` | Same loop | 90 minutes from the start (voucher deadline), 120 minutes overall | `VoucherWritten`. This is the decisive signal. A voucher that was already in the image before the node was seen booting doesn't count until the node boots or the voucher changes. | `VoucherMissing` at the voucher deadline, `Failed` at the overall budget. |
| Bootstrap: Azure readiness | The subscription can claim a voucher now (`Get-ZtpAzureReadiness`) | ARM GETs: the feature `Microsoft.DeviceOnboarding/AzureLocalZTP` (api-version `2021-07-01`) is `Registered`; the providers `Microsoft.AzureStackHCI`, `Microsoft.Edge`, `Microsoft.HybridCompute` and `Microsoft.DeviceOnboarding` (`2021-04-01`) are `Registered`; the OS image catalog `locations/<location>/osImages?solution-type=HCI` (`2026-10-01`) isn't empty | Only once a node has a valid voucher. The result is cached for 5 minutes. | Same budgets | `ReadyForPortal`: a valid voucher and Azure ready. It doesn't mean Azure saw the device: Learn documents no Azure signal for a device waiting to be claimed. | Doesn't fail by itself. The node stays at `VoucherWritten` with a warning event naming what isn't ready, until the overall budget. |
| Vouchers | The same voucher check, then eject and an exclusive read | Image read (`Wait-ZtpVoucher.ps1`), Redfish `EjectMedia`, then `Read-ZtpVoucherFromImage.ps1` | Every 60 s | 120 minutes | A valid voucher written to `<media_path>/vouchers/<serial>.pem` for every node | No voucher in time. The error names each node's last image status. |
| Device: scan | Only for a static node without `maintenance_address`: which address answers on TCP 20001 and lists the node's management MAC | A TCP connect to every address of `provisioning_dhcp_range` (default: the management subnet; at most 4096 addresses), all at once, 500 ms each. Then `GET GetNetworkAdapters` on each address that answers (`Set-ZtpDeviceConfiguration.ps1`). | Every 60 s | 30 minutes | `MaintenanceEnvironmentFound` with the address | No address lists the MAC in time: `DeviceConfigurationFailed`, and the stage fails |
| Device: configuration | The management adapter in the maintenance environment reports the static address | `GET GetArcBootstrapDeviceConfigurationStatus` and `GET GetNetworkAdapters` on the Configurator App's REST service, Basic sign-in as `edgeuser` | Every 60 s | 30 minutes | `DeviceAddressSet` or `DeviceAddressAlreadySet` | The status reads `Failed`, no adapter has the MAC, or the timeout: `DeviceConfigurationFailed` |
| Azure | ARM accepted the claim deployment | `Get-AzResourceGroupDeployment` for the deployment name | Every 15 s | 10 minutes | The deployment record appears, newer than the submit, and isn't `Failed` | The record shows `Failed`, the job fails, or nothing appears in 10 minutes |
| Ready | Each edge machine and its OS install (`Wait-ZtpMachineReady.ps1`, `Get-ZtpEdgeMachineStatus`) | ARM GETs of `Microsoft.AzureStackHCI/edgeMachines/<node>` and `edgeMachines/<node>/jobs/ProvisionOs`, api-version `2026-10-01`. See [Ready in detail](#ready-in-detail). | Every 60 s | 180 minutes | Every node ready to cluster. Then `Update-ArcMachineNames.ps1` reads each Arc machine name, and `Test-ProvisionedMachines.ps1` checks each Arc machine is `Connected` with the four mandatory extensions `Succeeded`. | A failure that remains after the one resubmit, or the timeout |
| Network | The port with the management MAC reports the static address, and no other port does | ARM GET of `edgeMachines/<node>/networkAdapters`, then PUT and GET of `networkAdapters/<name>/jobs/ApplyConfiguration` where a change is needed (`Set-ZtpManagementAddress.ps1`) | Every 60 s | 60 minutes per job | `ManagementAddressSet` or `ManagementAddressAlreadySet` | No adapter has the MAC, or a job fails or times out: `ManagementAddressFailed` |
| Restore: BIOS | The BIOS reports the final values after the restart | Redfish PATCH of the Bios Settings resource with `OnReset` and a restart, then GETs of the Bios resource (`Restore-ZtpBios.ps1`, `Set-ZtpBios.ps1`). Only for nodes with `bios_during_provisioning`. | Every 30 s | 30 minutes | `BiosRestored` | The BIOS doesn't have the attribute, no original value is saved, or the values don't show in time: `BiosRestoreFailed` |
| Restore: back in Azure | Each machine is `Connected` and ready to cluster again after the restart | First a 5-minute wait (`RestoreSettleMinutes`): an Arc machine reads `Connected` for a while after its host went down. Then the same reads and rules as Ready, and `Test-ProvisionedMachines.ps1`. | Every 60 s | 180 minutes | The stage's `StageCompleted`, with "Connected and ready again" | "Restore: &lt;node&gt; isn't ready to cluster after the BIOS restart" |

The Resolve, Media and Handoff stages don't wait on anything outside the host. Their result is checked when the stage script returns. When no node has `bios_during_provisioning`, Restore doesn't touch the BIOS or wait, and its evidence reads `nothing to restore: no bios_during_provisioning`.

### Ready in detail

Each poll reads two resources per node:

- `GET /subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.AzureStackHCI/edgeMachines/<node>?api-version=2026-10-01`
- `GET .../edgeMachines/<node>/jobs/ProvisionOs?api-version=2026-10-01`

A 404 means "not created yet". On the job, a 409 before the service creates it means the same (seen live, 2026-11), and the run keeps waiting. The job is read only once the edge machine exists. Until the job is readable, the edge machine's `properties.operationDetails` entry named `ProvisionOs` stands in for its status.

A node is **ready to cluster** when all of these are true:

| Field | Value |
| --- | --- |
| `properties.lifecycleDetails.lifecycleStatus.status` | `Provisioned` |
| Job `properties.status` | `DeploymentSuccess` (or `operationDetails` `ProvisionOs` `Succeeded` before the job is readable) |
| `properties.connectivityStatus` | `Connected` |
| `properties.arcMachineResourceId` | Set |
| `properties.reportedProperties.extensionProfile.extensions` | `AzureEdgeDeviceManagement`, `AzureEdgeLifecycleManager`, `AzureEdgeRemoteSupport` and `AzureEdgeTelemetryAndDiagnostics` each with `state` `Succeeded` |
| Failure checks below | None |

A node has **failed** when any of these is true:

| Field | Failed when |
| --- | --- |
| `lifecycleDetails.lifecycleStatus.status` | Contains `Fail` |
| Any `lifecycleDetails.lifecycleStages[].status` or `subStages[].status` | Contains `Fail` |
| Edge machine `properties.provisioningState` | `Failed` |
| Job `properties.status` | Contains `Fail` |
| Job `properties.provisioningState` | `Failed` |
| Job `properties.reportedProperties.deploymentStatus.status` | Contains `Fail` |
| Any job `reportedProperties.deploymentStatus.steps[].status` | Contains `Fail` or `Error` |
| `operationDetails` `ProvisionOs` `status` (before the job is readable) | Contains `Fail` |

The run doesn't read the job's `properties.error`. That matters after a resubmit; see [Reading what you see](#reading-what-you-see).

**The single resubmit.** `Invoke-ZtpEnvironment.ps1` passes `-RetryProvisionOs`, and `-MaxRetryCount` is 1. When a node fails, the next poll re-PUTs `jobs/ProvisionOs` with the edge machine's `provisioningDetails.osProfile` and `userDetails` and target `HCI`, the body of [Learn's retry procedure](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning#reattempt-a-failed-os-provisioning). For 10 minutes after the resubmit, a failure that still carries the old job's `startTimeUtc` isn't counted, so the service has time to restart the job. A second failure ends the stage. A new run (`-From Ready`) resubmits once more.

**The console.** Each change of the lifecycle, of a lifecycle stage or sub-stage, and of a job step is printed once, with its start and end time. A step that hasn't started is printed only once it moves. The sub-stages seen on live runs are `ProvisionMachine`: `RegisterMachine`, `ArcEnableMaintenanceEnvironment`, `InstallExtensions`; and `InstallOs`: `Initialize`, `DownloadOs`, `PrepareOs`, `RebootOs`, `InstallExtensions`, `Finalize`. The lifecycle seen on live runs is `Creating`, `AwaitingConnection`, `Provisioning`, `ReadyForOs`, `InstallingOs`, `Provisioned`.

## The console

| Lines | Written by |
| --- | --- |
| `Note: <key> ignored: SBE belongs to OS configuration.` | The entry point, before the run, once per SBE key the environment file still carries: `ztp.node_preparation` (older layout) or `hardware.sbe` (schema 5). Nothing to do; ZTP doesn't read them. |
| `[HH:mm:ssZ] [ztp] ...` | The orchestrator: the stage table at the start, `=== Stage <name> ===`, and `Stage <name> completed in <n> min: <evidence>` |
| `[HH:mm:ssZ] node-01 lifecycle ...`, `... stage ...`, `... job ProvisionOs ...`, `... step ...` | The Ready wait, and the Ready watch after Restore, one line per change |
| `[HH:mm:ssZ] [ztp] Restore: BIOS set back on ...; waiting 5 min, ...` | Restore, after the BIOS restart, before it checks the machines in Azure again |
| `[HH:mm:ssZ] [ztp] ZTP is done: ...`, then `[HH:mm:ssZ] [ztp] Next: OS configuration ...` | The end of the run, after the Handoff. See [Where the run ends](#where-the-run-ends). |

The Boot, Bootstrap and Vouchers waits print little on the console. Their detail is in the event file.

## The event file

### Where it is

| How you run | Path |
| --- | --- |
| `Invoke-ZtpEnvironment.ps1` | `ztp-events.jsonl` in the evidence folder: `ztp.evidence_path` of the environment file, or `-EvidencePath`, by default `%ProgramData%\AzureLocalZtp\<site>\evidence`. Before this change it was `_media\ztp-state\ztp-events.jsonl` in the clone; point monitors at the new path. |
| `Invoke-ZtpProvisioning.ps1` directly | `-EventLogPath`, default `ztp-events.jsonl` in the current folder |

The file is only ever appended to, so it holds every run that used it. Each event carries its own UTC time.

### Schema

One JSON object per line, UTF-8 without a BOM. The writer opens the file with read sharing, so a reader can follow it while the run appends.

| Key | Contents |
| --- | --- |
| `timestamp` | UTC, round-trip format, for example `2026-11-05T14:02:11.1234567Z` |
| `node` | The node name, or `*` for a stage event |
| `state` | See the table below |
| `evidence` | What the state is based on. Vouchers appear only as their SHA-256. |
| `nextAction` | What the run waits for next, or what to do |
| `level` | `Info`, `Warning` or `Error` |
| `stage` | `Boot`, `Bootstrap`, `Device`, `Network` or `Restore` for node events. For stage events, the stage: `Resolve`, `Media`, `Boot`, `Bootstrap`, `Vouchers`, `Device`, `Azure`, `Ready`, `Network`, `Restore` or `Handoff`. |

### Every state the scripts write

| `state` | `node` | `level` | Written when |
| --- | --- | --- | --- |
| `StageStarted` | `*` | `Info` | The orchestrator starts a stage. |
| `StageCompleted` | `*` | `Info` | A stage's result is checked. The evidence is the same text the console prints. |
| `StageFailed` | `*` | `Error` | A stage throws. The evidence holds the error. |
| `BiosChanged` | node | `Info` | Boot: the node's BIOS was changed before the maintenance boot. The evidence lists each attribute. |
| `NotStarted` | node | `Info` | The bootstrap watch starts. |
| `NotStarted` | node | `Warning` | A valid voucher is already in the image before the node was seen booting: an image reused from an earlier run. |
| `Mounted` | node | `Info` | The node's image is inserted. |
| `Booting` | node | `Info` | Power on, and the one-time override consumed or a boot log entry seen. |
| `MaintenanceEnvironmentRunning` | node | `Info` | A reset after the media boot, or the completion message in the BMC log. |
| `VoucherWritten` | node | `Info` | A valid voucher is read back from the image. |
| `VoucherWritten` | node | `Warning` | The node has a voucher but the Azure readiness check, or the image read, reports a problem. Written each time the detail changes. |
| `ReadyForPortal` | node | `Info` | A valid voucher and Azure ready. The node's watch ends. |
| `NotStarted`, `Mounted`, `Booting`, `MaintenanceEnvironmentRunning` | node | `Warning` | No change for 20 minutes. Written once per state. |
| `MediaRejected` | node | `Error` | The image isn't inserted after 3 minutes, or it's inserted write-protected. |
| `VoucherMissing` | node | `Error` | No valid voucher by the voucher deadline (90 minutes). |
| `Failed` | node | `Error` | The overall bootstrap budget (120 minutes) ran out. |
| `MaintenanceEnvironmentFound` | node | `Info` | Device: the scan found the node's maintenance environment by its management MAC. The evidence names the MAC, the address and the range scanned, for example `maintenance environment found by its management MAC 00:00:5e:00:53:11 at 192.0.2.140 (scan of 192.0.2.100-192.0.2.250)`. |
| `DeviceConfigurationSubmitted` | node | `Info` | Device: `SetArcBootstrapDeviceConfiguration` was sent to the maintenance environment. |
| `DeviceConfigurationStatus` | node | `Info` | Device: the status or the management adapter's report changed. |
| `DeviceAddressSet` | node | `Info` | Device: the management adapter reports the static address in the maintenance environment. |
| `DeviceAddressAlreadySet` | node | `Info` | Device: it already did; nothing was sent. |
| `DeviceAddressReported` | node | `Info` | Device: a `dhcp`, `dhcp_reservation` or `preconfigured` node with a `maintenance_address`; the evidence is what its management adapter reports. |
| `DeviceConfigurationFailed` | node | `Error` | Device: the scan didn't find the node, the service didn't answer, no adapter has the management MAC, or the status reported a failure or the wait timed out. |
| `NetworkJobSubmitted` | node | `Info` | Network: an `ApplyConfiguration` job was sent to an adapter (or an unfinished one with the same target is followed). The evidence names the adapter, its MAC and the target. |
| `NetworkJobStatus` | node | `Info` | Network: the job's status or steps changed, for example `DeploymentInProgress` with "Job is not yet triggered as other jobs are still running". |
| `ManagementAddressReleased` | node | `Info` | Network: another adapter held the management address and is now on DHCP. |
| `ManagementAddressSet` | node | `Info` | Network: the management adapter reports the static address. |
| `ManagementAddressAlreadySet` | node | `Info` | Network: the management adapter already reported it; nothing was sent. |
| `ManagementAddressReported` | node | `Info` | Network: a `dhcp` or `preconfigured` node; the evidence is what its management adapter reports. |
| `ManagementAddressFailed` | node | `Error` | Network: no adapter has the management MAC, or a job failed or timed out. The evidence holds the reason. |
| `BiosRestoreStarted` | node | `Info` | Restore: the run is setting the node's temporary BIOS values back. The evidence lists each attribute and its final value. |
| `BiosRestored` | node | `Info` | Restore: the BIOS reports the final values. The evidence ends with `(already set; no restart)` when nothing had to change. |
| `BiosRestoreFailed` | node | `Error` | Restore: no original value is saved for an attribute and `hardware.bios` gives none, or the BIOS change failed or timed out. The evidence holds the reason. |

`ZtpEvents.Common.ps1` also declares the failure states `BootStalled` and `EnvironmentStalled`, but no script writes them. A stall is a `Warning` event on the current state.

Node events come from the Boot, Bootstrap, Device, Network and Restore stages. Vouchers, Azure, Ready and Handoff write only their stage events: follow those on the console, in Azure or in Sonar. Event files from older runs can still hold `Prepare` events; the current scripts don't write them.

Example lines:

```json
{"timestamp":"2026-11-05T14:00:03.5120000Z","node":"*","state":"StageStarted","evidence":"stage Bootstrap","nextAction":"","level":"Info","stage":"Bootstrap"}
{"timestamp":"2026-11-05T14:00:04.0210000Z","node":"node-01","state":"NotStarted","evidence":"bootstrap watch started","nextAction":"Waiting for the first signal: mount the virtual USB and boot the node (Start-MaintenanceBoot.ps1).","level":"Info","stage":"Bootstrap"}
{"timestamp":"2026-11-05T14:00:05.3300000Z","node":"node-01","state":"Mounted","evidence":"virtual media inserted","nextAction":"Waiting for the node to boot from the virtual USB.","level":"Info","stage":"Bootstrap"}
{"timestamp":"2026-11-05T14:24:41.9000000Z","node":"node-01","state":"ReadyForPortal","evidence":"valid voucher in hand and Azure prerequisites verified; voucher SHA256 <hash>","nextAction":"Collect the voucher (Wait-ZtpVoucher.ps1), then create the site and edge machine (Invoke-ZtpAzureProvisioning.ps1).","level":"Info","stage":"Bootstrap"}
```

### Follow it live

From the clone root, in a second PowerShell 7 window:

```powershell
$events = 'D:\Data\azl-ztp\site-01\evidence\ztp-events.jsonl'   # ztp.evidence_path

# Every new event as one line. -Tail 20 starts with the last 20 instead of the whole history.
Get-Content -Path $events -Tail 20 -Wait | ForEach-Object {
    $e = ConvertFrom-Json -InputObject $_
    '{0:HH:mm:ss}Z {1,-8} {2,-30} {3,-7} {4}' -f $e.timestamp, $e.node, $e.state, $e.level, $e.evidence
}
```

Parse each line on its own (`ConvertFrom-Json -InputObject $_`). Piped straight into `ConvertFrom-Json`, the lines are collected until the input ends, which `-Wait` never does.

Only warnings and errors, live:

```powershell
Get-Content -Path $events -Tail 0 -Wait |
    ForEach-Object { ConvertFrom-Json -InputObject $_ } |
    Where-Object level -ne 'Info' |
    ForEach-Object { '{0:HH:mm:ss}Z {1} {2} {3}: {4} -> {5}' -f $_.timestamp, $_.level, $_.node, $_.state, $_.evidence, $_.nextAction }
```

After the fact:

```powershell
$all = Get-Content -Path $events | ForEach-Object { ConvertFrom-Json -InputObject $_ }

# Errors only
$all | Where-Object level -eq 'Error' | Format-Table timestamp, stage, node, state, evidence -Wrap

# The stage timeline
$all | Where-Object node -eq '*' | Format-Table timestamp, stage, state, evidence -Wrap

# The last event of each node
$all | Where-Object node -ne '*' | Group-Object node | ForEach-Object { $_.Group[-1] } |
    Format-Table node, state, level, timestamp, nextAction -Wrap
```

## Follow the run in Sonar

[AzureLocal Sonar](https://github.com/AzureLocal/azurelocal-sonar) is a read-only monitor in the browser. During a ZTP run it shows the event file in its log pane and the edge machines from Azure in its Provisioning panel. Afterwards it follows the cluster's Validate and Deploy. Sonar's own page on this is [Following a zero-touch provisioning run](https://azurelocal.cloud/azurelocal-sonar/ztp).

### What you need

| Need | Notes |
| --- | --- |
| A clone of the Sonar repository, `main` | Its `main` has the `ztpEvents` option and the handling of an error left from an earlier attempt. |
| PowerShell 7.4 or later | Sonar's start script requires it. |
| Az.Accounts, signed in | `Connect-AzAccount`, with read access to the resource group of the edge machines and to the resource group that holds their Arc machines. Reader on the subscription covers both. |
| The event file | On the same host, or a path Sonar can open. |
| For node logs during Validate and Deploy | WinRM (or SSH) to the seed node and an account for it. See Sonar's getting-started page. Not needed to follow provisioning. |

### Start it with `Start-ZtpMonitor.ps1`

`Start-ZtpMonitor.ps1` writes a Sonar config and starts `Start-AzlSonar.ps1` from the Sonar folder you name. Without `-Execute` it only prints the config and the command.

| Parameter | Default | What it does |
| --- | --- | --- |
| `-SonarPath` | required | Folder of the Sonar clone (it must contain `Start-AzlSonar.ps1`) |
| `-SubscriptionId` | required | Subscription of the edge machines |
| `-ResourceGroupName` | required | Resource group of the edge machines |
| `-NodesFile` | required | The node list. The entry point writes it to `config/simplified-provisioning/nodes.json`. |
| `-NodeName` | every node | Nodes to follow |
| `-EventLogPath` | `.\ztp-events.jsonl` | The event file. Written to the config as a full path. |
| `-ClusterName` | `ztp-provisioning` | The name Sonar shows, and the cluster whose `deploymentSettings` Sonar reads. Pass the real cluster name if you want Sonar to follow Validate and Deploy. |
| `-IdentityModel` | `ActiveDirectory` | `ActiveDirectory` or `LocalIdentity`. Picks Sonar's log-access guidance. |
| `-SonarConfigPath` | `.\ztp-sonar.config.json` | Where the config is written |
| `-Port` | `8642` | Local port of the page |
| `-NoBrowser` | off | Don't open the browser |
| `-Record` | none | Record the run to this file |
| `-Execute` | off | Write the config and start Sonar |

The config it writes:

```json
{
  "subscriptionId": "<subscription-id>",
  "resourceGroup": "<resource-group>",
  "clusterName": "ztp-provisioning",
  "provisioningRoute": "simplified",
  "identityModel": "ActiveDirectory",
  "pollSeconds": 20,
  "nodes": [
    { "name": "node-01", "address": "192.0.2.11", "seed": true },
    { "name": "node-02", "address": "192.0.2.12" }
  ],
  "ztpEvents": { "path": "D:\\Data\\azl-ztp\\site-01\\evidence\\ztp-events.jsonl" },
  "credential": { "source": "prompt" }
}
```

Each node's `address` is its `management_ip` from the node list, or its `bmc_address` when there's none. The first node is the seed, whose logs Sonar reads during Deploy.

Run it in a second window, from the ZTP clone root, while the run goes on in the first:

```powershell
Connect-AzAccount -Tenant <tenant-id>
./scripts/simplified-provisioning/Start-ZtpMonitor.ps1 -SonarPath D:\git\azurelocal-sonar `
    -SubscriptionId <subscription-id> -ResourceGroupName <resource-group> `
    -NodesFile ./config/simplified-provisioning/nodes.json `
    -EventLogPath D:\Data\azl-ztp\site-01\evidence\ztp-events.jsonl -ClusterName <cluster-name> -Execute
```

Sonar asks once for the account that reads the seed node's logs, because the config says `credential.source: prompt`. You can cancel: Sonar then uses your Windows identity, and provisioning is shown either way. The page opens at `http://localhost:8642/`. Press Ctrl+C in that window to stop Sonar; the run isn't affected.

### Start Sonar by hand

Write a config with the keys Sonar's `Config.ps1` reads, then start Sonar from its own folder:

| Key | Value for a ZTP run |
| --- | --- |
| `subscriptionId`, `resourceGroup` | Those of the edge machines |
| `clusterName` | The cluster to be deployed, so Sonar follows Validate and Deploy |
| `identityModel` | `LocalIdentity` or `ActiveDirectory` (required) |
| `provisioningRoute` | `simplified`. `auto` also works once an edge machine maps to a node, but `simplified` doesn't wait for that. |
| `nodes[]` | `name` (the node name, which is also the edge machine name), `address`, one `seed: true`. Leave `arcMachineName` out: Sonar reads the `<device-id>-1` name from Azure. |
| `ztpEvents.path` | The event file. A relative path is relative to the config file. |
| `pollSeconds` | Azure poll interval, 5 to 3600, default 20 |
| `credential` | `prompt`, `parameter` (with `-Credential`) or `keyvault` with `vault`, `usernameSecret`, `passwordSecret`. Never a password. |
| `recordPath` | Optional. Records like `-Record`. |

```powershell
Connect-AzAccount -Tenant <tenant-id>
Set-Location D:\git\azurelocal-sonar
./Start-AzlSonar.ps1 -ConfigPath D:\ztp\ztp-sonar.config.json
```

### The page

Open `http://localhost:8642/` (or the port you chose). Sonar listens on localhost only.

| Part | What it shows during a ZTP run |
| --- | --- |
| Header | The cluster name, the phase chip **Provisioning**, the overall status (for example "Provisioning: 1 of 2 machines ready"), elapsed time, last poll, and one chip per node with its Arc machine status |
| Provisioning panel | One item per node: the edge machine's lifecycle as a chip, a progress bar, the Arc machine, the extension count and the lifecycle message. Expand it for the lifecycle stages and sub-stages and a **ProvisionOs job** item with the job's steps, their times and errors inline. Before the claim, each node reads `NotCreated`: "No edge machine for this node in the resource group yet." |
| Live logs | Each event of the event file as a line: `<time> [ztp] <node> <state>: <evidence> -> next: <nextAction>`. Errors and warnings are coloured. Pick `ztp-events` in the file filter to see only them. Once the seed node answers, its deployment logs appear here too. |
| Steps | Empty during provisioning. The validation and deployment steps appear once Azure reports them. |
| Log access | The account, folders and timing for each phase |

The progress bar is Sonar's estimate, not Azure's: `Creating` 0, `AwaitingConnection` 5, `Provisioning` 15, `ReadyForOs` 25, `InstallingOs` 25 plus 70 times the share of finished job steps, `Provisioned` 100.

Sonar shows the events of every run in the file, each at its own time. It reads the event file every 2 seconds and Azure every `pollSeconds`.

### The Device, Network and Restore steps in Sonar

With `ztpEvents.path` set, Sonar shows ZTP's per-machine stages as steps of each machine, built from the events above. **Management address (maintenance environment)** (Device, before the claim) comes first and shows before the edge machine exists. **Management address on the management NIC** (Network, after the OS install) and **BIOS restored** (Restore) come last. Only a failed state is an error, so a Network job queued behind other jobs shows as running.

A machine is done when Azure reports it **Provisioned**, its Network step succeeded, and its Restore step succeeded or doesn't apply (the stage ended with no events for that machine). Until then it stays running at 95%. When every machine is done, the phase chip reads **ZTP complete** and a note under the header links the OS configuration guide. Sonar no longer shows a Prepare for Validate step or says Ready for Validate on this route. This needs Sonar `main` from November 2026 or later.

### After provisioning: Validate and Deploy

Sonar reads `clusters/<clusterName>/deploymentSettings/default` in the same resource group on every poll. Once Azure reports validation steps, the phase becomes **Validation**; once it reports deployment steps, **Deployment**; then **Done** or **Failed**. The Provisioning panel collapses when validation starts. This needs the real cluster name in `clusterName`, and the cluster in the resource group of the edge machines. Until it exists, the state Sonar serves carries the warning that `deploymentSettings` wasn't found yet; that's expected during provisioning.

### Read-only, credentials and recording

- **Read-only.** Sonar sends only GET requests to Azure and only reads the event file and the node logs. `Start-ZtpMonitor.ps1` writes only the Sonar config. Neither changes the run.
- **Credentials.** The Azure reads use your Az PowerShell sign-in. The node account is used only for the seed node's logs. No secret goes in the config.
- **Recording is off by default.** Sonar records only with `-Record <file>` (or `recordPath` in the config). `Start-ZtpMonitor.ps1 -Record <file>` passes it on. A recording masks secrets but keeps identifiers such as names and addresses. To share one, record with `-Publishable` into a new file; `Start-ZtpMonitor.ps1` doesn't pass that switch, so start Sonar by hand with the generated config: `./Start-AzlSonar.ps1 -ConfigPath <config> -Record <new-file> -Publishable`.

## Check it yourself without Sonar

The same reads the Ready stage makes, with Az PowerShell. Replace the placeholders:

```powershell
Connect-AzAccount -Tenant <tenant-id>
Set-AzContext -Subscription '<subscription-id>'

$api  = '2026-10-01'
$base = '/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.AzureStackHCI/edgeMachines/node-01'

$m = Invoke-AzRestMethod -Method GET -Path "${base}?api-version=$api"
if ($m.StatusCode -eq 404) { 'No edge machine yet.'; return }
$machine = ($m.Content | ConvertFrom-Json -Depth 64).properties

$j = Invoke-AzRestMethod -Method GET -Path "${base}/jobs/ProvisionOs?api-version=$api"
$job = if ($j.StatusCode -eq 200) { ($j.Content | ConvertFrom-Json -Depth 64).properties } else { $null }

# The current step: the first lifecycle sub-stage that is neither Completed, NotStarted nor Skipped (the scripts' rule)
$current = foreach ($stage in $machine.lifecycleDetails.lifecycleStages) {
    foreach ($sub in $stage.subStages) {
        if ($sub.status -and $sub.status -notin 'Completed', 'NotStarted', 'Skipped') { "$($stage.name)/$($sub.name)=$($sub.status)" }
    }
}

[pscustomobject]@{
    Lifecycle    = $machine.lifecycleDetails.lifecycleStatus.status
    Message      = $machine.lifecycleDetails.lifecycleStatus.message
    Connectivity = $machine.connectivityStatus
    CurrentStage = @($current)[0]
    JobStatus    = if ($job) { $job.status } else { 'not submitted' }
    JobState     = if ($job) { $job.provisioningState } else { '' }
    ArcMachine   = $machine.arcMachineResourceId
} | Format-List
```

The job's steps, with their times:

```powershell
$job.reportedProperties.deploymentStatus.steps |
    Format-Table name, status, startTimeUtc, endTimeUtc, description -Wrap
```

The lifecycle stages, and the extensions the edge machine reports:

```powershell
$machine.lifecycleDetails.lifecycleStages | ForEach-Object {
    $s = $_
    [pscustomobject]@{ Stage = $s.name; SubStage = ''; Status = $s.status; Start = $s.startTimeUtc; End = $s.endTimeUtc }
    $s.subStages | ForEach-Object { [pscustomobject]@{ Stage = $s.name; SubStage = $_.name; Status = $_.status; Start = $_.startTimeUtc; End = $_.endTimeUtc } }
} | Format-Table

$machine.reportedProperties.extensionProfile.extensions |
    Select-Object @{ n = 'Extension'; e = { ($_.extensionResourceId -split '/')[-1] } }, state
```

Times of `0001-01-01T00:00:00Z` mean "not set". The job's `properties.error` (code and message) can belong to an earlier attempt; read it together with the job's current `status`. To see each node once a minute, put the first block in a loop with `Start-Sleep -Seconds 60`, the Ready stage's interval. [Learn: Invoke-AzRestMethod](https://learn.microsoft.com/powershell/module/az.accounts/invoke-azrestmethod).

## The portal view

In the Azure portal, go to **Azure Arc** > **Operations** > **Provisioning (preview)** and select the **Provisioned machines** tab. Select a machine's status to see its progress details, and wait for **Ready to cluster** ([Learn: verify Azure Arc connectivity](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#step-5-verify-azure-arc-connectivity)). The portal shows the edge machines only after the claim, so it covers the Azure and Ready stages.

## Reading what you see

### What normal looks like

| Stage | Normal |
| --- | --- |
| Boot | Each node: attach proven, override `Once/Floppy`, reset, then 10 minutes without `OSE1002`. All nodes at once. |
| Bootstrap | Events per node: `NotStarted`, `Mounted`, then often `Booting` and `MaintenanceEnvironmentRunning` (weak signals, which may be skipped), then `VoucherWritten` and `ReadyForPortal`. Learn says the maintenance environment setup usually takes up to 30 minutes, with two reboots ([prepare machines](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#step-2-prepare-machines)). A 20-minute stall warning in `Mounted` or `Booting` alone isn't a problem: the voucher decides. |
| Vouchers | Usually done at the first poll: the voucher is already in the image. |
| Device | Without `maintenance_address`: `MaintenanceEnvironmentFound` first. Then `DeviceConfigurationSubmitted`, `DeviceConfigurationStatus` and `DeviceAddressSet` per static node. |
| Azure | What-if, then "deployment accepted". The edge machines appear in Azure and in Sonar. |
| Ready | Each node walks `Creating`, `AwaitingConnection`, `Provisioning`, `ReadyForOs`, `InstallingOs`, `Provisioned`. Expect the first install attempt to fail with 5901 and be resubmitted once (see below). |
| Network | `ManagementAddressAlreadySet` per static node when Device put the address on the right port. A job can sit at `DeploymentInProgress` behind other jobs right after the install. |
| Restore | With `bios_during_provisioning`: `BiosRestoreStarted`, a restart, `BiosRestored`, a 5-minute wait, then the Ready lines again until each machine is `Connected`. Without it: the stage completes at once with `nothing to restore: no bios_during_provisioning`. |
| Handoff | `ZTP is done: ...` and `Next: OS configuration ...` on the console. A `Management address not verified on: ...` warning names nodes that OS configuration must fix. |

### Two things that look wrong but aren't

**5901 at `SetupHybridComputeRP`, then a resubmit.** On the live runs, the first `ProvisionOs` attempt often failed at the step `SetupHybridComputeRP` with error 5901: on every node on the earlier runs, and on one of two nodes on the 2026-11-06 run. The Ready stage resubmitted the job once, automatically, and the new attempt passed that step in about 2 minutes. From the failure until the service restarts the job, the job reads failed, and Sonar shows the node and the phase as failed (**Failed: Provisioning**). After the restart, Azure keeps the first attempt's error in the job's `properties.error`. The run doesn't read that field. Sonar's `main` files it under the node's `previousErrors` as an earlier attempt, not as a failure, and the node shows as running again. `previousErrors` is in the state Sonar serves, exports and records; the page doesn't draw it. Wait.

**Late registration.** After the claim, one node sat at lifecycle `AwaitingConnection`, with `RegisterMachine` `NotStarted`, for 34 minutes. The other took 6 minutes. It recovered by itself. Wait: the Ready stage allows 180 minutes.

The causes, and what's known about them, are in [Troubleshooting](troubleshooting.md).

### When to act and when to wait

| You see | Do |
| --- | --- |
| A stall warning in Bootstrap | Wait for the voucher. Look at the node's virtual console if it's near the 90-minute voucher deadline. |
| `MediaRejected` | Act. Mount the image read-write and run again. See [iDRAC quirks](troubleshooting.md#idrac-quirks). |
| `VoucherMissing` or `Failed` in Bootstrap | Act. Look at the console. The fallback is the Configurator App voucher (`-VoucherFolder`). |
| `VoucherWritten` with a warning about Azure | Act on what it names: the feature, a provider, or the OS image catalog. The node moves on by itself once it's fixed, within the overall budget. |
| Boot fails with "booted its installed OS" | Act. The one-time boot didn't take. Check the BMC, then run again. |
| 5901 on a node's first install attempt | Wait. The run resubmits once. |
| A second `ProvisionOs` failure | Act. Fix what the job names, then run the same command with `-From Ready`. |
| `AwaitingConnection` with `RegisterMachine` `NotStarted` | Wait, up to the 180-minute budget. If the node never registers, check its outbound access. |
| Ready times out | The run may still be going in Azure. Run the same command with `-From Ready`. |
| Device scans and doesn't find a node | Wait up to the 30 minutes. Then act: see [The Device scan finds no node](troubleshooting.md#the-device-scan-finds-no-node). |
| `BiosRestoreFailed` | Act. See [Restore fails](troubleshooting.md#restore-fails), then run `-From Restore`. |
| `Management address not verified on: ...` at the Handoff | Act after ZTP: OS configuration must put the address on the management port before Validate. See [The management address is not verified in the handoff](troubleshooting.md#the-management-address-is-not-verified-in-the-handoff). |

## Where the run ends

The run ends after the Handoff with two console lines:

```text
[12:00:00Z] [ztp] ZTP is done: the machines are Provisioned and Arc-connected, with the management address on the management port. <handoff> has the Arc machine names and IDs; <cluster inputs> has arc_machine_names for the cluster deployment environment file.
[12:00:00Z] [ztp] Next: OS configuration (OEM drivers, the SBE in C:\SBE, DHCP off on the other ports, DNS and time, the deployment admin), then Validate and Deploy. ZTP does none of these. See https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/. Hardware must not be clustered by this repository.
```

The last events are the Handoff's `StageCompleted`. Nothing after that is watched by ZTP. The next steps are in [Phase 03 OS Configuration](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/) of [Part 4 Cluster Deployment](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/): for example [Task 04 Disable DHCP on all adapters](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-04-disable-dhcp-on-management-adapter), [Task 05 DNS](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-05-configure-dns-servers), [Task 07 NTP](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-07-configure-time-synchronization-ntp) and [Task 16 Verification](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-16-phase03-verification). Then Validate and Deploy: [Phase 05 Cluster Deployment](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-05-cluster-deployment/). Sonar keeps following the cluster through Validate and Deploy; see [After provisioning: Validate and Deploy](#after-provisioning-validate-and-deploy).
