# Troubleshooting and known issues

> What the live runs showed, what the scripts do about it, and Microsoft Learn's recovery steps where they exist.

Unless a row cites Learn, the behavior below was **proven on Dell AX-760 / iDRAC 7.30**, with Azure Local build `12.2690.1003.15` and maintenance image `10.2610.0.3063`, on two nodes. Where a cause isn't confirmed, the page says so.

## Quick reference

| Symptom | Section |
| --- | --- |
| `ProvisionOs` fails at `SetupHybridComputeRP` with 5901 | [5901 and the automatic resubmit](#_5901-at-setuphybridcomputerp-and-the-automatic-resubmit) |
| A 409 on `jobs/ProvisionOs` right after the claim | [409 on ProvisionOs](#_409-on-provisionos-before-the-job-exists) |
| A node sits at `AwaitingConnection` after the claim | [Registration delay](#registration-delay-after-the-claim) |
| Insert fails with `IDRAC.2.9.SYS458`, `WriteProtected=True` is reported, the node boots its disk, or eject returns HTTP 500 | [iDRAC quirks](#idrac-quirks) |
| The Device stage scans and doesn't find a node | [The Device scan finds no node](#the-device-scan-finds-no-node) |
| The static management address is on another port than the one with the management MAC | [Static IP lands on the wrong NIC](#static-ip-lands-on-the-wrong-nic) |
| `BiosRestoreFailed`, or the Restore stage stops | [Restore fails](#restore-fails) |
| The handoff says `managementAddressVerified: false` | [The management address is not verified in the handoff](#the-management-address-is-not-verified-in-the-handoff) |
| The Arc machine has a device ID for a name | [Arc machine names](#arc-machine-names) |
| An unexpected adapter with a `169.254.0.x` address | [The Remote NDIS adapter](#the-remote-ndis-adapter) |
| Validate complains about inbox drivers or several default gateways (or about an empty `C:\SBE`, only when an SBE was asked for) | [Node state after the OS install](#node-state-after-the-os-install) |
| `Note: ztp.node_preparation ignored: SBE belongs to OS configuration.` | [SBE settings are ignored](#sbe-settings-are-ignored) |
| Deploy fails with `ParentResourceNotFound` | [Deploy on build 2690](#deploy-fails-with-parentresourcenotfound-on-build-2690) |
| A job that's running again still carries an error | [Stale error after a resubmit](#stale-error-after-a-resubmit) |
| The machine keeps reinstalling the maintenance environment | [USB boot loop](#usb-boot-loop) |

## 5901 at `SetupHybridComputeRP` and the automatic resubmit

**What you see.** On the first OS-install attempt, the `ProvisionOs` job failed at the step `SetupHybridComputeRP` with error 5901: "The device could not read or update its Azure registration". The job code was `Retryable`. On the earlier runs this happened on every node. On the 2026-11-06 run, one of the two nodes passed on its first attempt and the other hit 5901, so expect it, but not on every node.

**Cause, as far as it's known.** The maintenance environment's log showed HTTP 403 when it read the new Arc machine. The role that allows that read is assigned seconds after the machine is created. The most likely cause is RBAC propagation taking longer than the device's retry window, which seems to be about 20 minutes. That isn't confirmed past minute 6.

**What the run does.** The Ready stage re-PUTs `jobs/ProvisionOs` once per node, with the edge machine's existing OS profile and user details and target `HCI`. That's the body of Learn's retry script. The resubmit passed the step in about 2 minutes every time.

**Learn's recovery.** "Simplified machine provisioning currently doesn't support automatic retries from the service in case the OS installation fails." To retry, resubmit the `ProvisionOs` job; it can take up to 30 minutes ([Learn: reattempt a failed OS provisioning](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning#reattempt-a-failed-os-provisioning)).

**If the second attempt also fails.** Fix the cause the job names, then run the same command with `-From Ready`. That's a new run, so it resubmits once more. To resubmit one node by hand:

```powershell
./scripts/simplified-provisioning/Wait-ZtpMachineReady.ps1 -SubscriptionId <subscription-id> -ResourceGroupName <resource-group> `
    -EdgeMachineName node-02 -RetryProvisionOs -Execute
```

## 409 on ProvisionOs before the job exists

**What you see.** Right after the claim, `GET .../edgeMachines/<node>/jobs/ProvisionOs` answers HTTP 409 instead of 404 (seen live, 2026-11).

**What the run does.** Nothing for you to do. The Ready stage and `New-ZtpHandoff.ps1` read a 404 or a 409 on that job as "not there yet" and keep waiting, with the edge machine's `operationDetails` standing in for the job's status.

## Registration delay after the claim

**What you see.** After the claim, a node can wait up to about 45 minutes before it registers with the onboarding service (42 minutes on the 2026-11-06 run): `RegisterMachine` stayed `NotStarted` and the lifecycle stayed `AwaitingConnection`. Another node in the same run can take a few minutes. It recovered by itself each time.

**Cause.** Likely the device's retry gap. Not confirmed.

**What to do.** Wait. The Ready stage allows 180 minutes. If it times out, run the same command with `-From Ready`. If a node never registers, check its outbound access to Azure ([Learn: firewall requirements](https://learn.microsoft.com/azure/azure-local/concepts/firewall-requirements)). You can also collect logs. In the maintenance environment they're under `/var/log/bootstrap`, `/var/log/provisioningextension` and `/var/log/bootstraprestservice`; after the OS install, under `C:\Windows\System32\Bootstrap\Logs` ([Learn: collect logs](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning#collect-logs-from-your-azure-subscription)).

## iDRAC quirks

These are iDRAC 7.30 behaviors, not generic Redfish. `Mount-ZtpVirtualUsb.ps1` handles each one; you don't need to do anything. They're listed so the log lines make sense.

| Behavior | What the script does |
| --- | --- |
| `InsertMedia` rejects the field `WriteProtected=false` with `IDRAC.2.9.SYS458`. | Sets the manager attribute `RFS.<n>.WriteProtected = Read Write` with a Redfish PATCH on `/redfish/v1/Managers/iDRAC.Embedded.1/Attributes`, then inserts without the field. Eject sets it back to `Read Only`. |
| After that insert, Redfish still reports `WriteProtected=True`, although the share is opened for write. | Warns and continues. The voucher appearing in the image proves write access. |
| The allowable boot override targets don't include `Usb`. The USB-stick slot boots as virtual floppy (`vFDD`). | Sets the iDRAC attributes `ServerBoot.1.FirstBootDevice = vFDD` and `ServerBoot.1.BootOnce = Enabled`. |
| The iDRAC applies that attribute in the background. A reset before it lands boots the disk instead. | Also sets the standard one-time override to `Once/Floppy`, and waits up to 2 minutes until the system reports it. No reset without it. |
| A node can boot its installed OS anyway. | Watches the iDRAC log for 10 minutes after the reset. If `OSE1002` appears (logged on these runs as "C: boot completed"), the stage fails for that node. |
| Eject can return HTTP 500 (`VRM0010`) just after the node writes to the image. | Retries up to 6 times, 30 seconds apart. |

If a run fails during Boot, check each node before you retry: the virtual media is ejected and the one-time boot override is cleared. Use `Mount-ZtpVirtualUsb.ps1 -Action Status` to read them and `-Action Eject` to eject.

## The Device scan finds no node

**What you see.** For a static node without `maintenance_address`, the Device stage fails with `DeviceConfigurationFailed` and a message like:

```text
node-01: no maintenance environment with the management MAC 00:00:5e:00:53:11 answers on TCP 20001 in 192.0.2.1-192.0.2.254 within 30 minutes (30 scan(s)). Check that the node booted the maintenance environment, that this host reaches that network on TCP 20001, and the MAC; or set maintenance_address (or network_intents.management.provisioning_dhcp_range).
```

**How the scan works.** It probes every address of `network_intents.management.provisioning_dhcp_range` (schema 5: `networking.management.provisioning_dhcp_range`; without it, the management subnet) on TCP 20001, all at once. Each address that answers is asked `GET GetNetworkAdapters`, and the node is the one that lists its management MAC. It scans again every poll interval (60 seconds from the entry point) until the stage's 30 minutes pass. Each port of the maintenance environment takes a DHCP lease, so a node can answer on several addresses. The scan was verified live on a Dell AX-760 with DHCP from a firewall and no reservation. The calls and what the service refuses are in [Appendix B](appendix/configurator-app-api.md#how-ztp-uses-this-service).

**What to check.**

| Check | How |
| --- | --- |
| The node is still booting | Look at the node's virtual console in the BMC. The maintenance environment shows its address there once it's up. A node that's still restarting answers on a later scan; run `-From Device` if the stage timed out first. |
| This host reaches TCP 20001 in the range | `Test-NetConnection -ComputerName 192.0.2.140 -Port 20001` from the management host, to the address on the console. A firewall or a route between the host and the provisioning network blocks the scan. |
| `provisioning_dhcp_range` covers the pool | The range must hold the addresses the DHCP server leases to the maintenance environment. Without it the stage scans the management subnet, which misses a lease from another subnet. At most 4096 addresses. |
| The MAC | `cluster_nodes[].mac_address` (schema 5: the node's management port MAC) must be the management port's MAC. If an address answers but lists other MACs, the MAC in the file is wrong. |
| The password | A responder that answers 401 isn't matched. The `edgeuser` password is `ztp.maintenance_password_secret`, else `Password1`, and must be the one the images were built with. |

If you know the address, set `cluster_nodes[].maintenance_address` and the stage goes there directly, with no scan. Then run `-From Device`.

## Static IP lands on the wrong NIC

**What you see.** With a static management address, the node comes up after the OS install with `ip_address` on a port other than the one whose MAC the environment file names. On a Dell AX-760 it landed on a ConnectX storage port, not the LOM named by MAC. The node doesn't answer on its management address from the management network, and Validate would find the management address on the wrong adapter.

**Cause.** With a `Manual` site setting and a `Manual` adapter in the claim, the OS-install request carries the port's MAC in `siteDetails.deviceConfiguration.network.networkAdapters[].macAddress`. Azure accepts it, but the device ignores it. The maintenance environment's provisioning extension (`ProvisioningExtension.dll`) picks the port with `FindReadyPhysicalInterfaceName` and has no `MacAddress` property, so the static address goes to the first ready physical port.

**What the run does.** Two stages, one before the OS install and one after it.

The Device stage, before the claim, sets the address the way the Configurator App does: through the maintenance environment's REST service (`https://<maintenance_address>:20001/BootstrapOobeService`), `SetArcBootstrapDeviceConfiguration` for the adapter with the management MAC. A node without `maintenance_address` is found by the scan above. With `static_method: device` (the default), the site's network setting is `Automatic` and the claim carries no `Manual` adapter, so the OS install has no static address to misplace. The request and the status response were verified live. See [The Device stage](environment-file.md#the-device-stage) and [Appendix B](appendix/configurator-app-api.md#how-ztp-uses-this-service).

`static_method: site` is the old path, for environments without the Device stage: the site is `Manual` and the claim carries a `Manual` adapter by MAC, so the install puts the address on the first ready port.

**Then the OS install resets every port to DHCP.** The maintenance environment's network settings don't carry into the OS (verified live, Dell AX-760, build 2610, 2026-11-07). So in Modes B and C the management port has a DHCP address (B) or none (C) when ZTP finishes, whatever the Device stage set. OS configuration sets the static by MAC: the toolkit's `Set-AzureLocalNodeConfiguration.ps1`, Network step, over Arc Run Command. Mode A (a DHCP reservation per management MAC) needs nothing set. See [Management address modes](prerequisites.md#management-address-modes).

The Network stage, after Ready, only verifies. `GET .../edgeMachines/<node>/networkAdapters` (api-version 2026-10-01) lists the adapters; `properties.reportedProperties.macAddress` (12 hex digits, no separators, lower case on the live run) finds the management port, separators and case aside. No match stops the stage and lists the MACs found. Otherwise the node's result, with a reason naming the mode, the port, its MAC, what it has and what the file expects, goes to the handoff as `managementAddressVerified` and `managementAddressReason`. A static address the install reset is recorded as `Deferred` (event `ManagementAddressDeferredToOsConfiguration`), not as a failure.

**Why not fix it through Azure.** Azure Local has a per-NIC job, `PUT .../networkAdapters/<name>/jobs/ApplyConfiguration`. On two separate live runs it never started: it sat at `DeploymentInProgress` with "Job is not yet triggered as other jobs are still running", and Azure marked it `Failed` after about 35 minutes. The orchestrator's `-ApplyThroughAzure` keeps that path as an opt-in (release the address from a port that holds it, then `ipInterfaceType: Static` with the address, mask, gateway, DNS servers, VLAN and `interfaceState: up` on the management port; changes in `<evidence_path>\network-changes.jsonl`), and then fails the stage when a static address isn't set. Don't count on it.

**If the stage stops.**

| Message | What to do |
| --- | --- |
| Device: "the maintenance environment's REST service at &lt;address&gt;:20001 doesn't answer" | `maintenance_address` is the address on the node's console, TCP 20001 is open from this server, and the password is the one the image was built with (`ztp.maintenance_password_secret`, else `Password1`). A 401 means the password. |
| Device: "no maintenance environment with the management MAC ... answers on TCP 20001" | See [The Device scan finds no node](#the-device-scan-finds-no-node). |
| Device: "no network adapter in the maintenance environment reports the management MAC" | The message lists the MACs the maintenance environment reports. Correct `mac_address`, then run `-From Device`. |
| "no network adapter of edge machine &lt;node&gt; reports the management MAC" | The message lists the MACs the machine reports. Correct the management port's `mac_address` in the environment file, then run `-From Network`. |
| With `-ApplyThroughAzure`: a job stays `DeploymentInProgress` with "Job is not yet triggered as other jobs are still running", or "ApplyConfiguration (apply) failed" | The behaviour seen live. Run the stage without `-ApplyThroughAzure` (`-From Network`) and let OS configuration set the address. |

## Restore fails

The Restore stage sets each `bios_during_provisioning` attribute back, restarts the node through Redfish, waits for the BIOS to report the values, then waits for Azure to report the machine `Connected` and ready to cluster again. Each change is in `<evidence_path>\bios-changes.jsonl`.

| Message | Cause | What to do |
| --- | --- | --- |
| `BiosRestoreFailed`: "&lt;node&gt;: no value saved for &lt;attribute&gt; before Boot changed it (the run state lost it). Set hardware.bios.&lt;attribute&gt; to the final value." | The environment file gives no final value in `hardware.bios`, and the state file has no `biosOriginal` for that attribute: the state was reset (`-ResetState`, another `-StatePath`) or deleted after Boot. | Add the attribute to `hardware.bios` with its final value, then run `-From Restore`. `bios-changes.jsonl` has the original value in its `original` line. |
| "&lt;node&gt; BIOS still reports &lt;attribute&gt;=&lt;value&gt; 30 minutes after the restart. Check the BIOS job in the BMC's job queue." | The BIOS didn't apply the change, or doesn't report it. | Look at the BMC's job queue and the node's console. Fix the job, then run `-From Restore`; values already right are left alone. |
| "The BIOS has no attribute &lt;attribute&gt;." | The attribute name is wrong. Names are case-sensitive. | Read the names from `/redfish/v1/Systems/<id>/Bios`, correct the environment file, run `-From Restore`. |
| "Restore: -Credential (the BMC account) is required with -Execute." or "applying the BIOS restarts the nodes. Pass -ConfirmNotClustered." | Only when you run the orchestrator directly. | Pass `-BmcCredential` and `-ConfirmNotClustered`. The entry point passes both. |
| "Restore failed on &lt;node&gt;: ... Outcome per node: node-01 Restored, node-02 Failed" | One node failed, or `Set-ZtpBios.ps1` returned no result or a status other than `Changed`/`AlreadySet` (not proof of a restore). A node marked `Restored` has already restarted. | Fix the failed node, then run `-From Restore`: the node whose BIOS is already right is reported `AlreadySet` and not restarted again. |
| "Restore: the Arc machines are not Connected again after the BIOS restart within N minutes: ... Connected since ..., before the restart" | The machine still reads the `Connected` it had before the restart, or never connected again. The check needs Arc to have changed the status after the restart. | Check the node's console and its outbound access. Once the machine has reconnected, run `-From Ready`. |
| "Restore: &lt;node&gt; isn't ready to cluster after the BIOS restart." | The machine didn't come back `Connected` and ready to cluster within the Ready budget. | Check the node's console and its outbound access. Once the machine reads `Connected` again (portal or Sonar), run `-From Ready`. Ready checks it, and Network and Restore find everything already right, so nothing is changed or restarted. A rerun `-From Restore` alone doesn't wait for Azure again: with the BIOS already right, the node isn't restarted. |

## The management address is not verified in the handoff

**What you see.** `New-ZtpHandoff.ps1` warns `Management address not verified on: <node> (<reason>). OS configuration must fix it before Validate.` The node's `managementAddressVerified` is `false` and `managementAddressReason` says why. The handoff is still written.

| Reason | Meaning | What to do |
| --- | --- | --- |
| `Mode B (Static with DHCP): the management port Port1 (MAC 00:00:5e:00:53:aa) has DHCP 192.0.2.116 after the install; expected static 192.0.2.11; OS configuration sets it by MAC.` | Expected in Mode B: the OS install reset the static the Device stage set. | Run OS configuration (`Set-AzureLocalNodeConfiguration.ps1`); its Network step sets the static by MAC. |
| `Mode C (Static without management DHCP): the management port Port1 (MAC ...) has DHCP and no address after the install; expected static 192.0.2.11; OS configuration sets it by MAC over Arc.` | Expected in Mode C: no DHCP on the management network, so the port has no address; Arc reaches the node over the provisioning port. | The same: OS configuration sets it over Arc, before it turns DHCP off on any other port. |
| `Mode A (Reserved): the management port Port1 (MAC ...) has DHCP 192.0.2.140 after the install; expected the reserved 192.0.2.11; check the DHCP reservation for MAC ...` | The reservation is missing or for another MAC. | Fix the reservation for the management MAC, then restart the port's lease or run OS configuration, which verifies it again. |
| `dhcp without a reservation (not Mode A, B or C): the management port Port0 (MAC ...) has DHCP 192.0.2.200 after the install; expected 192.0.2.12; reserve the address for the MAC (Mode A) or make it static (Mode B or C).` | A `dhcp` node: ZTP only reports its address and doesn't change it. | Reserve the address (Mode A), or set the port `static` and let OS configuration set it ([Task 03 Static IP](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-03-configure-static-ip-address)). |
| `...: the management port Port0 (MAC ...) has no address after the install; ...` | The management port has no address. | Check the port's link and the DHCP server (Mode A), then OS configuration. |
| `...: no management MAC in the infrastructure file, so the port wasn't checked` | The environment file names no `mac_address` for the node. | Add it. OS configuration finds NICs by MAC. |
| `no Network stage result for this node` | The state file has no Network result for the node, for example after `-Stage Handoff` with a reset state. | Run `-From Network`. |
| `no management settings in the infrastructure file` | The node has no management block. | Add the management settings, or set the address in OS configuration. |

In Modes B and C an unverified static node is the normal result, not a failure: the Network stage is verify-only. Only with `-ApplyThroughAzure` does it fail when a static address is not on the management port.

## Arc machine names

**What you see.** The provisioned machine (`edgeMachines`) has the host name, and sits in the Arc site. The Arc for Servers machine, though, is named by the service `<device-id>-1`. The `arcMachineResourceId` set at claim time is replaced. The Arc machines are in the site configuration's managed resource group, not in your resource group.

Learn's portal steps say to "Provide the machine name as the Azure Arc resource name" ([Learn: provision machines](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#step-3-provision-machines-from-azure)). On these runs the service named the Arc machine by device ID anyway.

**What to do.** Use each node's `arcMachineResourceId` from the handoff for the cluster deployment, never the host name. The handoff reads it from the edge machine after Ready. See [What to hand to the cluster deployment](operator-guide.md#what-to-hand-to-the-cluster-deployment).

## The Remote NDIS adapter

**What you see.** The iDRAC's USB link to the OS (Remote NDIS) shows up on the node as a network adapter with a `169.254.0.x` address.

**What to do.** Nothing in ZTP: it has no gateway and ZTP doesn't touch it. In the cluster deployment, keep this adapter **out of every network intent**. It isn't a cluster port.

## Node state after the OS install

**What you see.** After ZTP, a node has Microsoft inbox network drivers, DHCP and a default gateway on more than one port, and an empty `C:\SBE` (an SBE is optional; it is side-loaded only when a person asks for it). The ports are named `Port0` to `Port6`.

**Why it matters.** Learn: "Inbox drivers are not supported for use with Azure Local" ([host network requirements](https://learn.microsoft.com/azure/azure-local/concepts/host-network-requirements#driver-requirements)). Cloud deployment validation fails if it finds more than one physical adapter with a default gateway ([decision 8](https://learn.microsoft.com/azure/azure-local/plan/cloud-deployment-network-considerations#decision-8-determine-management-ips-and-infrastructure-network)). Learn says to install the OEM's drivers and put the SBE in `C:\SBE` before deployment ([install drivers and firmware](https://learn.microsoft.com/azure/azure-local/deploy/deployment-install-os#install-drivers-and-firmware)). Dell says its SBE can't install drivers or firmware during deployment, so they're installed before it.

**What to do.** This is expected: ZTP ends at the Handoff and doesn't install OEM drivers, copy the SBE package to the nodes (optional; the package itself must already be on a share), turn DHCP off on the other NICs, set DNS and time, or create the deployment admin. Do those in OS configuration, before Validate: [Phase 03 OS Configuration](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/). The tasks that cover the network are [Task 04 Disable DHCP on all adapters](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-04-disable-dhcp-on-management-adapter), [Task 05 DNS](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-05-configure-dns-servers), [Task 07 NTP](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-07-configure-time-synchronization-ntp), [Task 09 Disable unused adapters](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-09-disable-unused-network-adapters), the [Task 15 combined script](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-15-complete-combined-script-all-steps) and [Task 16 Verification](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-16-phase03-verification). Find the NICs by MAC: the port names don't match the hardware.

## SBE settings are ignored

**What you see.** The entry point prints `Note: ztp.node_preparation ignored: SBE belongs to OS configuration.` (schema 5: `Note: hardware.sbe ignored: SBE belongs to OS configuration.`). The orchestrator prints `<key> in <file> ignored: SBE belongs to OS configuration.` for an older settings file with `SbeModel`, `SbeFamily`, `SbeSolutionVersion` or `SbePackagePath`.

**What to do.** Nothing. ZTP no longer reads these keys; the run goes on. Remove them from the file when you like. If you want an SBE, ask OS configuration to side-load it (`hardware.sbe.delivery`); it is never the default.

## Deploy fails with `ParentResourceNotFound` on build 2690

**What you see.** On build `12.2690`, an earlier cluster Deploy failed at "Deploy Arc infrastructure components" with `ParentResourceNotFound`. The cause was that the Arc machine names are device IDs, not host names.

**What to do.** This solution stops before Deploy. Before you deploy on that build, check that your deployment inputs use the `arcMachineResourceId` values from the handoff, and test Deploy on one environment first. No Learn recovery step is known for this.

## Stale error after a resubmit

After a `ProvisionOs` resubmit, Azure keeps the earlier attempt's error in the job's `properties.error`, while the new attempt runs and after it succeeds. A tool that reads that field alone shows the old error as if it were current. Read the job's current `status` and step times, or the console, instead.

The run doesn't read `properties.error`: the Ready stage decides on the job's status, provisioning state and steps. Sonar's `main` counts the error as a failure only while the job itself reports failure; otherwise it files it under the node's `previousErrors` as an earlier attempt. See [Reading what you see](monitoring.md#reading-what-you-see).

## USB boot loop

**Learn:** when the BIOS setting **Boot USB Devices First** is on, the machine boots from the USB device on every restart, reinstalls the maintenance environment, and loops about every 10 minutes. Boot from USB once, then from the internal disk ([Learn: USB boot loop](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning#usb-boot-loop-issue-with-maintenance-environment)). The run uses a one-time boot, but turn that BIOS setting off anyway.

## Other Learn troubleshooting

Learn's troubleshooting article also covers an empty OS image list (register `Microsoft.AzureStackHCI`), ARM template validation failing on `hciRPServiceprincipalID` (first use in the subscription), and an internal server error caused by Azure Policy (region, naming or required tags). See [Learn: troubleshoot simplified machine provisioning](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning).
