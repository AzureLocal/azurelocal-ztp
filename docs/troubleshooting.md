# Troubleshooting and known issues

> What the live runs showed, what the scripts do about it, and Microsoft Learn's recovery steps where they exist.

Unless a row cites Learn, the behavior below was **proven on Dell AX-760 / iDRAC 7.30**, with Azure Local build `12.2690.1003.15` and maintenance image `10.2610.0.3063`, on two nodes. Where a cause isn't confirmed, the page says so.

## Quick reference

| Symptom | Section |
| --- | --- |
| `ProvisionOs` fails at `SetupHybridComputeRP` with 5901 | [5901 and the automatic resubmit](#_5901-at-setuphybridcomputerp-and-the-automatic-resubmit) |
| A node sits at `AwaitingConnection` after the claim | [Registration delay](#registration-delay-after-the-claim) |
| Insert fails with `IDRAC.2.9.SYS458`, `WriteProtected=True` is reported, the node boots its disk, or eject returns HTTP 500 | [iDRAC quirks](#idrac-quirks) |
| The Arc machine has a device ID for a name | [Arc machine names](#arc-machine-names) |
| An unexpected adapter with a `169.254.0.x` address | [The Remote NDIS adapter](#the-remote-ndis-adapter) |
| The session drops during the Prepare restart | [Restart over WinRM](#restart-over-winrm) |
| Validate complains about inbox drivers or several default gateways | [Node state after the OS install](#node-state-after-the-os-install) |
| Deploy fails with `ParentResourceNotFound` | [Deploy on build 2690](#deploy-fails-with-parentresourcenotfound-on-build-2690) |
| A job that's running again still carries an error | [Stale error after a resubmit](#stale-error-after-a-resubmit) |
| The machine keeps reinstalling the maintenance environment | [USB boot loop](#usb-boot-loop) |
| Prepare can't sign in to a node | [Prepare fails to sign in](#prepare-fails-to-sign-in) |

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

## Arc machine names

**What you see.** The provisioned machine (`edgeMachines`) has the host name, and sits in the Arc site. The Arc for Servers machine, though, is named by the service `<device-id>-1`. The `arcMachineResourceId` set at claim time is replaced. The Arc machines are in the site configuration's managed resource group, not in your resource group.

Learn's portal steps say to "Provide the machine name as the Azure Arc resource name" ([Learn: provision machines](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#step-3-provision-machines-from-azure)). On these runs the service named the Arc machine by device ID anyway.

**What to do.** Use each node's `arcMachineResourceId` from the handoff for the cluster deployment, never the host name. The handoff reads it from the edge machine after Ready. See [What to hand to the cluster deployment](operator-guide.md#what-to-hand-to-the-cluster-deployment).

## The Remote NDIS adapter

**What you see.** The iDRAC's USB link to the OS (Remote NDIS) shows up on the node as a network adapter with a `169.254.0.x` address.

**What to do.** Nothing in Prepare: it has no gateway and Prepare leaves link-local addresses alone. In the cluster deployment, keep this adapter **out of every network intent**. It isn't a cluster port.

## Restart over WinRM

**What you see.** Restarting a node inside a remote call kills the WinRM session before the call returns, and that reads as a failure.

**What the run does.** Prepare schedules the restart 10 seconds out (`shutdown /r /t 10`) so the call returns first. Then it waits until WinRM stops answering, waits for the node to come back, and checks that the boot time changed. It restarts at most once.

## Node state after the OS install

**What you see.** After the OS install, a node has Microsoft inbox network drivers, DHCP and a default gateway on more than one port, and an empty `C:\SBE`.

**Why it matters.** Learn: "Inbox drivers are not supported for use with Azure Local" ([host network requirements](https://learn.microsoft.com/azure/azure-local/concepts/host-network-requirements#driver-requirements)). Cloud deployment validation fails if it finds more than one physical adapter with a default gateway ([decision 8](https://learn.microsoft.com/azure/azure-local/plan/cloud-deployment-network-considerations#decision-8-determine-management-ips-and-infrastructure-network)). Learn says to install the OEM's drivers and put the SBE in `C:\SBE` before deployment ([install drivers and firmware](https://learn.microsoft.com/azure/azure-local/deploy/deployment-install-os#install-drivers-and-firmware)). Dell says its SBE can't install drivers or firmware during deployment, so they're installed before it.

**What the run does.** Prepare fixes all of it before Validate. See [the Prepare gates](architecture.md#the-prepare-gates). If Prepare warns "No SBE driver for &lt;adapter&gt;", that adapter stays on its current driver and Validate may reject it. Check that you downloaded the right SBE family for the model.

If gate 4 fails with "default gateway on ..." or "DHCP still on ...", run `-From Prepare` again. If it fails again, look at the adapters on the node from the BMC console.

## Deploy fails with `ParentResourceNotFound` on build 2690

**What you see.** On build `12.2690`, an earlier cluster Deploy failed at "Deploy Arc infrastructure components" with `ParentResourceNotFound`. The cause was that the Arc machine names are device IDs, not host names.

**What to do.** This solution stops before Deploy. Before you deploy on that build, check that your deployment inputs use the `arcMachineResourceId` values from the handoff, and test Deploy on one environment first. No Learn recovery step is known for this.

## Stale error after a resubmit

After a `ProvisionOs` resubmit, Azure keeps the earlier attempt's error in the job's `properties.error`, while the new attempt runs and after it succeeds. A tool that reads that field alone shows the old error as if it were current. Read the job's current `status` and step times, or the console, instead.

The run doesn't read `properties.error`: the Ready stage decides on the job's status, provisioning state and steps. Sonar's `main` counts the error as a failure only while the job itself reports failure; otherwise it files it under the node's `previousErrors` as an earlier attempt. See [Reading what you see](monitoring.md#reading-what-you-see).

## USB boot loop

**Learn:** when the BIOS setting **Boot USB Devices First** is on, the machine boots from the USB device on every restart, reinstalls the maintenance environment, and loops about every 10 minutes. Boot from USB once, then from the internal disk ([Learn: USB boot loop](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning#usb-boot-loop-issue-with-maintenance-environment)). The run uses a one-time boot, but turn that BIOS setting off anyway.

## Prepare fails to sign in

| Message | Check |
| --- | --- |
| "No sign-in to &lt;ip&gt; with the ZTP administrator secret" | The node answers on `cluster_nodes[].ip_address` (DHCP reservation for the management MAC). TCP 5985 is open from the host. The node addresses are in the host's WinRM TrustedHosts list ([Learn](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_remote_troubleshooting#how-to-use-an-ip-address-in-a-remote-command)). The secret in `ztp.admin_secret` is the one the claim used. |
| "No adapter on &lt;node&gt; has the environment file's MAC" | `cluster_nodes[].mac_address` is the management adapter's MAC. |
| "&lt;node&gt; reported no result within 30 minutes" | Look at the node from the BMC console. The task's result is in `C:\ProgramData\AzureLocalZtp\result.json`. |

## Other Learn troubleshooting

Learn's troubleshooting article also covers an empty OS image list (register `Microsoft.AzureStackHCI`), ARM template validation failing on `hciRPServiceprincipalID` (first use in the subscription), and an internal server error caused by Azure Policy (region, naming or required tags). See [Learn: troubleshoot simplified machine provisioning](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning).
