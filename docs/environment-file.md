# Environment file reference

> Every key that `Invoke-ZtpEnvironment.ps1` reads from the environment file, what it's for, and an example.

::: warning Deprecated layout
This page describes ZTP's own environment-file layout (`cluster_nodes`, `network_intents`, `ztp`, ...). It still works, and it's deprecated: use the master `infrastructure.yml` (schema 5), which every Azure Local tool reads and which lists each machine's ports. Pass it through the same `-InfrastructureFile`; ZTP detects the format. See [Reading the master infrastructure.yml](infrastructure-schema-5.md) for where each key below comes from in schema 5, and [Prerequisites](prerequisites.md#values-you-need) for every value in schema 5 paths.
:::

This layout is frozen. Settings added from schema 5.4 on (BIOS actions derived from the inventory, the Azure site choices, timeouts, the USB image, the Configurator service, the BMC options) exist only in the master file, so no key lives in ZTP alone: see [Reading the master infrastructure.yml](infrastructure-schema-5.md#every-setting-is-a-key-schema-54) and [the variables audit](variables-audit.md). A file in this layout runs with the defaults ZTP always used.

The environment file is YAML. It describes the machines, the management network, and the Azure targets. It holds **no secrets**: each credential is a Key Vault reference. The file can hold other keys for other tools; ZTP ignores keys that aren't listed here.

A complete example with placeholder values is in [`examples/infrastructure.example.yml`](https://github.com/AzureLocal/azurelocal-ztp/blob/main/examples/infrastructure.example.yml).

## Which template to start from

For a new file, start from a schema 5 template in azurelocal-toolkit instead of this layout:

- **ZTP only.** You install the OS and register the machines with ZTP, and run no automation after it: start from the [ZTP-only template](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/config/infrastructure/infrastructure.ztp.example.yml) (schema 5.3, `_metadata.scope: ztp`). It holds only the keys ZTP reads. The toolkit is adding it; it isn't published yet.
- **ZTP, then OS configuration and deployment.** Start from the [full template](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/config/infrastructure/infrastructure.example.yml). ZTP reads its part of it and ignores the rest.

ZTP's key check accepts `_metadata.scope`: it ignores every key it doesn't read.

## How the file is checked

- The run checks the file before it does anything else and lists every problem at once (`Test-ZtpEnvironment` in `ZtpEnvironment.Common.ps1`).
- If a script named `tools\Validate-Infrastructure.ps1` exists in the same folder as the environment file, or `-ValidatorPath` names one, the entry point runs it next and stops if it fails. Without either, only the built-in check runs.

## Keys

Every key on this page is read by provisioning (`Invoke-ZtpEnvironment.ps1`). "Optional" means the run works without it.

### Ignored keys: they belong to OS configuration

ZTP ends at the Handoff, so it reads nothing that OS configuration owns. A file can keep these keys; ZTP accepts them and ignores them:

- `ztp.node_preparation.*` (the SBE folder and `allow_unvalidated_sbe`). The run prints `Note: ztp.node_preparation ignored: SBE belongs to OS configuration.`
- `credentials.local_admin_username` and `credentials.local_admin_password_secret` (the deployment admin).
- `onprem.ntp_servers` (time on the host).
- `hardware.model` (it chose the SBE).
- The `network_adapters` mapping of the other ports (DHCP off and so on).

OS configuration (azurelocal-toolkit [Phase 03 OS Configuration](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/)) reads these, before Validate and Deploy.

### Nodes

`cluster_nodes` is a list with one entry per machine.

| Key | Required | Format | Used for |
| --- | --- | --- | --- |
| `cluster_nodes[].name` | Yes | Text, unique | Host name, edge machine name, image name (`ztp-usb-<name>.img`). |
| `cluster_nodes[].ip_address` | Yes | IPv4, inside `network_intents.management.subnet` | The node's management address. How it gets there depends on `network_intents.management.ip_assignment` and `static_method`. With `static` and `static_method: device` (the default), the Device stage sets it on the port with `mac_address` before the claim, and the Network stage checks it after the install. See [The site's network setting](#the-sites-network-setting). |
| `cluster_nodes[].mac_address` | Yes | `AA:BB:CC:DD:EE:FF` or `AA-BB-CC-DD-EE-FF` | The management port. The Device stage finds the maintenance environment's adapter by it (and, without `maintenance_address`, finds the node itself by it), and the Network stage finds the edge machine's network adapter by it. With `static_method: site`, the claim names the port by this MAC too. Separators and case don't matter. The provisioned OS names its ports `Port0` to `Port6`, so OS configuration must find the port by this MAC too. |
| `cluster_nodes[].adapter_name` | Optional | Text | Name of the management port, sent with `static_method: site`. Leave it out unless you know the name the installed OS gives the port; the MAC is enough. |
| `cluster_nodes[].arc_machine_name` | Optional | 1-54 letters, digits, `-`, `_`, `.`; not ending in `.` | Name of the node's Arc machine. Default: the node's `name`. Sent as the edge machine's `arcMachineResourceId`. In live runs the service replaced it at claim time; the handoff records the name Azure actually used. See [Arc machine names](troubleshooting.md#arc-machine-names). |
| `cluster_nodes[].service_tag` | Yes | Text | The machine's serial number. Maps each voucher (`\vouchers\<serial>\`) to its node. |
| `cluster_nodes[].idrac_ip` | Yes | IPv4 | The BMC address. Redfish target, and the only source allowed to reach the SMB share. |
| `cluster_nodes[].maintenance_address` | Optional | IPv4 | The maintenance environment's address, when you know it before the run: a DHCP reservation, or the lease the node's console shows. The Device stage reaches the maintenance environment's REST service there. Without it, the Device stage **scans by MAC**: it probes every address of `network_intents.management.provisioning_dhcp_range` (default: the management subnet) on TCP 20001 in parallel, asks each answer for its adapters (`GetNetworkAdapters`), and takes the one that lists the node's `mac_address`. It scans again every poll interval until the node answers or the Device stage's 30 minutes pass. Verified live (Dell AX-760, DHCP with no reservation). See [The Device stage](#the-device-stage). |
| `cluster_nodes[].ip_assignment` | Optional | `static`, `dhcp` or `preconfigured` | This node's management mode, instead of `network_intents.management.ip_assignment`. The schema 5 reader sets it from each node's management port. |

### Management network

| Key | Required | Format | Used for |
| --- | --- | --- | --- |
| `network_intents.management.subnet` | Yes | CIDR, for example `192.0.2.0/24` | Prefix length of the static address. Every static `ip_address` must be inside it. Also the default scan range of the Device stage. |
| `network_intents.management.gateway` | Yes | IPv4 | The default gateway of the management port. |
| `network_intents.management.dns_servers` | Yes | List of IPv4 | DNS of the management port. Learn: DNS servers can't be changed after deployment ([DNS server considerations](https://learn.microsoft.com/azure/azure-local/plan/cloud-deployment-network-considerations#dns-server-considerations)). |
| `network_intents.management.ip_assignment` | Optional | `static` (default), `dhcp_reservation`, `dhcp` or `preconfigured` | How each node's management address is set ([Management address modes](prerequisites.md#management-address-modes)). `dhcp_reservation` (Mode A, recommended): the port stays on DHCP and the DHCP server reserves `ip_address` for the MAC; the Network stage verifies it. `static` (Mode B or C): ZTP sets `ip_address`, the mask, gateway and DNS on the port with `mac_address` before the install (who sets it is `static_method`); the install resets the port, the Network stage records it as left to OS configuration, and OS configuration sets it again by MAC (see [The Network stage](#the-network-stage)). `dhcp`: the port stays on DHCP with no reservation, so its address can change; reported only. `preconfigured`: the port is already set up, and ZTP doesn't change it. |
| `network_intents.management.static_method` | Optional | `device` (default) or `site` | Who sets a static management address. `device`: the Device stage, on the port with `mac_address`, in the maintenance environment before the claim. The site's network setting is `Automatic` and the claim (`siteDetails.deviceConfiguration.network.networkAdapters`) carries no `Manual` adapter, so that address is the only static the node gets. `site`: Microsoft's OS install, from the site's `Manual` setting over `site_ip_range` and a `Manual` adapter in the claim, keyed by MAC. For environments without the Device stage. With `site`, the install puts the address on the first ready port and ignores the MAC (seen live on a Dell AX-760: a ConnectX port); the Network stage then moves it. |
| `network_intents.management.vlan_id` | Optional | 0-4094, default 0 | VLAN of the management port, for the Device and Network stages and the site's `Manual` setting. 0 for an access port. |
| `network_intents.management.site_ip_range.start`, `.end` | Optional | IPv4, inside `subnet`, start before end | Only with `static_method: site`: the address range of the site's `Manual` network setting (`Microsoft.Edge/configurations/networkConfigurations`). Default: the lowest to the highest static `cluster_nodes[].ip_address`. With `site`, every static node address must be inside it. Ignored with `device`. |
| `network_intents.management.provisioning_dhcp_range.start`, `.end` | Optional | IPv4, start before end, at most 4096 addresses | The DHCP pool on the provisioning network, where the maintenance environment takes its address. The Device stage scans it on TCP 20001 for each node without `maintenance_address`. Default: the management subnet. Narrow it to the pool, so the scan stays short. A node's static address must not be inside it, and the scan doesn't support a /31 or /32 management subnet. |
| `network_intents.management.provisioning_network` | Optional | `dhcp` (default) or `static` | How the maintenance environment gets the address it reaches Azure with, before the machine is claimed. `dhcp`: a DHCP server must answer on a port of the machine (on a machine with no DHCP on its management network, another port, for example a data port, carries it). `static`: the run warns and sets nothing. Learn documents only the Configurator app for a static address there, and whether the USB image can carry a preset address is an open research item. |

#### The site's network setting

The site configuration has one network setting for the machines it provisions. ZTP derives it from the management mode and `static_method` (`Get-ZtpSiteNetwork`).

| `ip_assignment` | `static_method` | Site setting | Manual adapter in the claim |
| --- | --- | --- | --- |
| `static` | `device` (default) | `Automatic` | None. The Device stage has set the address by MAC before the claim. |
| `static` | `site` | `Manual`: `addressRange { startIp, endIp }` from `site_ip_range` (default: the lowest to the highest static node address), `defaultGateway` and `dnsServers` from the management network, `subnetMask` from `subnet`, `vLanId` from `vlan_id` (0 when absent) | One per node, keyed by `mac_address`, with the address, mask, gateway, DNS and VLAN. |
| `dhcp` | either | `Automatic` | None. |
| `preconfigured` | either | `Automatic` | None. ZTP doesn't manage the address, and the newly installed OS takes DHCP until whatever preconfigures the port does. |

The plan prints the setting, for example `Site network: Automatic.` with `device`, or `Site network: Manual 192.0.2.11-192.0.2.12, gateway 192.0.2.1, mask 255.255.255.0, DNS 192.0.2.53, 192.0.2.54, VLAN 0` with `site`. It also prints who sets the static addresses.

#### The Device stage

The maintenance environment runs the Configurator App's REST service, and the Device stage (`Set-ZtpDeviceConfiguration.ps1`, between Vouchers and Azure) uses it to put the static address on the port with `mac_address` before the claim, as the Configurator App would. It needs TCP 20001 from this server to the maintenance environment. The operations, how ZTP signs in and what is not possible are in [Appendix B](appendix/configurator-app-api.md#how-ztp-uses-this-service).

| | |
| --- | --- |
| Service | `https://<maintenance address>:20001/BootstrapOobeService/<Operation>`: CoreWCF WebHttp, JSON, property names in PascalCase. |
| Finding it | `maintenance_address` when the node has one. Otherwise a scan of `provisioning_dhcp_range` (default: the management subnet) on TCP 20001; the node is the answer whose `GetNetworkAdapters` lists its management MAC. The maintenance environment takes a lease on every port, so it can answer on several addresses; one not on the management port is preferred. The event log records `MaintenanceEnvironmentFound`. |
| Sign-in | HTTP Basic as `edgeuser`, with the password in `ztp.maintenance_password_secret` when it's set (the Media stage builds it into each image), otherwise the maintenance environment's default `Password1`. |
| Certificate | Self-signed by the maintenance environment, with nothing to check it against, so these calls skip the certificate check. No other call in ZTP does. The password therefore goes to every host that answers on TCP 20001 in the scan range: scan only an isolated provisioning network and keep the range to the DHCP pool ([Prerequisites](prerequisites.md#network)). |
| Read-back | A read of the adapters counts as this node's only when it lists the management MAC. The old DHCP lease is free once the static address applies, so a response without the MAC (another device on that address) is ignored, and the configuration status is read only from an address that passed that check. |
| Known limit | If another port of the same machine already holds the target static address, the node stops with a message naming the port, its MAC and the address, and nothing is sent. Releasing another port isn't a request shape verified live, so ZTP doesn't do it: free the address on that port, or correct `ip_address` or `mac_address`. |
| Checks before any request | Two nodes with the same static `ip_address`, or a static address inside `provisioning_dhcp_range` (the pool would lease it to another device), fail the environment file check and the Device stage. |

For each static node:

1. `GET GetNetworkAdapters` (**verified live**: HTTP 200, `{ "NetworkAdapters": [ { "MacAddress", "Name", "EnableDhcp", "IpAddress", "Gateway", "SubnetMask", "DnsAddressArray", "VlanId", "LogicalIndex", ... } ] }`, MACs as 12 lower-case hex digits). The adapter with `mac_address` is found whatever the separators and case; none stops the node and lists the MACs found. An adapter that already reports `EnableDhcp: false` with the address, mask, gateway, DNS and VLAN is left alone.
2. `POST SetArcBootstrapDeviceConfiguration` with `{ "Network": { "NetworkAdapters": [ { "MacAddress", "EnableDhcp": false, "IpAddress", "SubnetMask", "Gateway", "DnsAddressArray", "VlanId" } ] } }`, the MAC as 12 lower-case hex digits. No `HostName` is sent: the claim sets the host name. **Verified live** (Dell AX-760, 2026-11-07, `VlanId: 0`): the status reports `NetworkConfig` `Succeeded`, and `GetNetworkAdapters` then reads the static address back on the management port. Another adapter that holds the address statically gets `{ "MacAddress", "EnableDhcp": true }` in the same list; that entry isn't proven live.
3. `GET GetArcBootstrapDeviceConfigurationStatus` and `GET GetNetworkAdapters` until the adapter reports the static configuration, up to 30 minutes (the orchestrator's `-DeviceTimeoutMinutes`). The status shape is **verified live**: `{ "Response": { "Name": "Bootstrap", "Status", "DetailedResponse": [ { "Name": "NetworkConfig" | "RemoteConfig" | "WebProxy" | "TimeServer" | "HostName", "Status" } ] }, "Version" }`. A `Status` that reads `Failed` stops the node. If the management port is the one the maintenance address is on, the service answers on the static address afterwards, and both are tried.

`dhcp` and `preconfigured` nodes are only reported, and only when they have a `maintenance_address`; they aren't scanned for. Each change goes to `<evidence_path>\device-changes.jsonl` (time, node, address, adapter, MAC, before, the request, phase `requested`, `applied`, `failed` or `timedOut`), and its progress to the event log with stage `Device`. The plan (without `-Execute`) reads the adapters and prints the request it would send. To run it again: `-From Device`.

The OS install then resets every port to DHCP: the maintenance environment's network settings don't carry into the OS (verified live, Dell AX-760, build 2610, 2026-11-07). So after ZTP the management port has a DHCP address (Mode B) or none (Mode C), and OS configuration sets the static again by MAC. See [Management address modes](prerequisites.md#management-address-modes).

#### The Network stage

After Ready, the Network stage (`Set-ZtpManagementAddress.ps1`) **verifies** each node's management address. It reads Azure's per-NIC report (`edgeMachines/<node>/networkAdapters`, api-version 2026-10-01), finds the management port (the adapter whose reported MAC is `mac_address`, whatever the card or slot), and compares it with the file. It changes nothing, and sends or waits on no Microsoft job. It needs no WinRM and no firewall change. For each node:

| Mode | What the Network stage records |
| --- | --- |
| A, Reserved (`dhcp_reservation`) | Verified when the management port has `ip_address`; without `ip_address` in the file, when it has any DHCP address. Otherwise not verified, with what to check (the reservation for the MAC). |
| B and C, static | Verified when the management port reports `ip_address` as static and no other port has it. After a normal install it doesn't: the row is `Deferred` (event `ManagementAddressDeferredToOsConfiguration`) and the reason says what the port has, for example `Mode B (Static with DHCP): the management port Port1 (MAC 00:00:5e:00:53:aa) has DHCP 192.0.2.116 after the install; expected static 192.0.2.11; OS configuration sets it by MAC.` |
| `dhcp`, `preconfigured` | Reported only: verified when the port has `ip_address`. Never changed. |

A management MAC no adapter reports still stops the node, listing the MACs found: the file is wrong, and OS configuration would fail on it the same way. An edge machine that reports no adapters yet is recorded as not verified instead. The result goes to the state file and the handoff (`managementAddressVerified`, `managementAddressReason`, `managementMode`, and every port in `networkAdapters[]`), and the stage never fails on it. Progress goes to the event log with stage `Network`. To run it again: `-From Network`.

**`-ApplyThroughAzure` (opt-in, unreliable).** The orchestrator's `-ApplyThroughAzure` (or `"ApplyThroughAzure": true` in the settings file) brings back the earlier fix for static nodes: if another adapter reports `ip_address`, it sets that adapter to DHCP first and waits until the address is gone; then it sends `jobs/ApplyConfiguration` to the management adapter (static `ip_address`, the mask from `subnet`, `gateway`, `dns_servers`, `vlan_id`, interface up), follows each job up to `-NetworkTimeoutMinutes` (60), and fails the stage when a static address isn't set. Each change goes to `<evidence_path>\network-changes.jsonl`. **Evidence against it:** on two separate live runs (Dell AX-760, build 2610, 2026-11-07) the job never started. It sat at "Job is not yet triggered as other jobs are still running", and Azure marked it `Failed` after about 35 minutes. Use OS configuration instead.

```yaml
network_intents:
  management:
    subnet: 192.0.2.0/24
    gateway: 192.0.2.1
    dns_servers: [192.0.2.53, 192.0.2.54]
    ip_assignment: static
    static_method: device                                          # optional; the default
    vlan_id: 0
    provisioning_dhcp_range: { start: 192.0.2.100, end: 192.0.2.199 } # optional; default: the subnet
    provisioning_network: dhcp                                     # optional; the default
```

### Hardware

| Key | Required | Format | Used for |
| --- | --- | --- | --- |
| `hardware.vendor` | Yes | Text, for example `Dell` | Picks `config/oem/<vendor>.json`: the BMC kind, its log services and the signal patterns the Bootstrap watch reads. |
| `hardware.bios` | Optional | Mapping: BIOS attribute name -> value, values quoted as strings | The machine's **final** BIOS state. The Boot stage sets it on every node before the maintenance boot, and the Restore stage sets any key that `bios_during_provisioning` changed back to this value. See [BIOS settings](#bios-settings). |
| `cluster_nodes[].bios` | Optional | Same | One node's own final BIOS attributes, merged over `hardware.bios` (the node's value wins). |
| `hardware.bios_during_provisioning` | Optional | Same | **Temporary** BIOS values, for the install only. The Boot stage applies `hardware.bios` with these merged over it (these win), and saves each attribute's value as found, once, in the run state (`biosOriginal`) and in `bios-changes.jsonl` (phase `original`). The Restore stage, after Network and before Handoff, sets each key back to `hardware.bios[key]`, or to the saved value when `hardware.bios` doesn't name it. See [The Restore stage](#the-restore-stage). |
| `cluster_nodes[].bios_during_provisioning` | Optional | Same | One node's own temporary values, merged over `hardware.bios_during_provisioning`. |

#### BIOS settings

Some machines need a BIOS change before the maintenance environment works, or only while the OS installs. The file holds both, so nothing is set by hand. A Dell example with a Fibre Channel HBA in slot 2:

```yaml
hardware:
  bios:                       # the final state
    Slot2: "Enabled"          # the FC HBA is on once the OS is installed
    EmbNic1Nic2: "Enabled"    # the embedded LOMs shipped as DisabledOs, so the OS couldn't see the management ports
  bios_during_provisioning:   # for the install only
    Slot2: "Disabled"         # the maintenance environment would offer the HBA's SAN LUN as the install disk
cluster_nodes:
  - name: node-02
    bios_during_provisioning:
      Slot2: "Enabled"        # this node has no HBA there
```

Names are the attributes of the BMC's Redfish Bios resource (`GET /redfish/v1/Systems/System.Embedded.1/Bios` on an iDRAC), and they're case-sensitive. Quote every value: ZTP converts it to the type the BIOS reports for that attribute (a number or a boolean). The check refuses a value that isn't a string and a name with spaces.

In the Boot stage, before it mounts the image, ZTP does this for each node that has settings (`Set-ZtpBios.ps1`):

1. Reads the current values. An attribute the BIOS doesn't have stops the run before anything changes. If every value already matches, it moves on without a restart.
2. Sends only the values that differ: `PATCH /redfish/v1/Systems/System.Embedded.1/Bios/Settings` with `"@Redfish.SettingsApplyTime": { "ApplyTime": "OnReset" }`. A value already pending from an earlier run isn't sent again.
3. Powers the node on (`On`) if it's off, otherwise restarts it (`ForceRestart`), so the BIOS job runs.
4. Waits, up to 30 minutes, until the Bios resource reports every new value. Then it mounts the image and sets the one-time boot, so the BIOS reset can't use up the boot to the virtual USB.

Every change goes to `<evidence_path>\bios-changes.jsonl` (time, node, BMC, attribute, before, after, `original`, `requested` then `applied`), to the Boot stage's evidence, and to the event log as a `BiosChanged` event. The plan (without `-Execute`) lists the settings it would apply and what the Restore stage would set back; run `Set-ZtpBios.ps1` with `-Credential` and without `-Execute` to see the current values and what would change.

#### The Restore stage

The Restore stage (`Restore-ZtpBios.ps1`, between Network and Handoff) undoes `bios_during_provisioning`. For each node with temporary values, it sets every temporary key back to `hardware.bios[key]` (with the node's own `bios` merged over it) when the file names one, otherwise to the original value the Boot stage saved in the state file. It sends `PATCH ... Bios/Settings` with `OnReset`, restarts the node through Redfish and waits until the BIOS reports the values. Then the orchestrator waits `-RestoreSettleMinutes` (default 5) and runs the Ready watch and `Test-ProvisionedMachines.ps1` until each Arc machine is Connected and each edge machine still ready to cluster.

Without `bios_during_provisioning` it does nothing (`nothing to restore: no bios_during_provisioning`). If the state file lost an original and `hardware.bios` doesn't name the key, the stage stops and asks you to set `hardware.bios.<key>`. Events: stage `Restore`, `BiosRestoreStarted`, `BiosRestored`, `BiosRestoreFailed`. The handoff records what was set back as `biosRestored` (`{}` when nothing).

### Azure

| Key | Required | Format | Used for |
| --- | --- | --- | --- |
| `azure_identity.azure_tenant_id` | Yes | GUID | Tenant of every Azure call. |
| `azure_resources.location` | Yes | Azure region | Region of the site configuration and edge machines, of the OS image catalog the Bootstrap stage reads, and of the resource group if the run creates it. In the preview only `eastus` works for the provisioning resources ([Learn](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#azure-prerequisites)). |
| `site.name` | Yes | Text | Display name of the `Microsoft.Edge` site. |
| `ztp.subscription_id` | Yes | GUID | Subscription of the site and edge machines. |
| `ztp.resource_group` | Yes | Text | Resource group of the site and edge machines. Created if missing. |
| `ztp.site_name` | Yes | Text | Resource name of the `Microsoft.Edge` site. Also names the ARM deployment `ztp-<site_name>` and the default run folders. |
| `ztp.time_zone` | Yes | Text, for example `UTC` | Site time zone. |
| `ztp.os_version` | Yes | `latest`, `latest-preview`, or a validated solution recipe version (`12.YYMM.x.y`) | The OS the machines install. Pin a version. `Get-ZtpOsImage.ps1` lists the catalog. The handoff records the build actually installed (`solution.vsrVersion`). See [Pin the OS version](operator-guide.md#pin-the-os-version). |
| `ztp.provisioning_iso` | Yes | `latest`, a train (`2610`), a build, or a Microsoft download URL | The maintenance ISO. `latest` takes the newest published general-availability train. |
| `ztp.azl_rp_object_id` | Optional | GUID | Object ID of the Azure Local resource provider's service principal in your tenant. If you leave it out, the run looks it up, which needs directory read rights. A managed identity doesn't have those by default, so set it for pipelines. |
| `ztp.tags` | Optional | Mapping | Tags on the site configuration and the edge machines. The resource group gets them only if the run creates it. Learn: a policy that *requires* tags isn't supported ([troubleshooting](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning#when-you-provision-new-machines-you-receive-an-internal-server-error)). |

To find the resource provider's object ID once with an account that can read the directory:

```powershell
(Get-AzADServicePrincipal -ApplicationId '1412d89f-b8a8-4111-b4fd-e82905cbd85d').Id
```

That application ID is what `Invoke-ZtpEnvironment.ps1` uses for the lookup.

### Secrets in Key Vault

| Key | Required | Format | Used for |
| --- | --- | --- | --- |
| `ztp.admin_secret.subscription_id` | Yes | GUID | Subscription of the vault. The BMC secrets and the `edgeuser` password are read in this subscription too. |
| `ztp.admin_secret.resource_group` | Yes | Text | Resource group of the vault. The template assigns roles on the vault there. |
| `ztp.admin_secret.vault` | Yes | Vault name | Vault that holds the provisioning administrator secret. |
| `ztp.admin_secret.name` | Yes | Secret name | The provisioning administrator password. **Create it before the run**; the environment-file path doesn't create it. Learn asks for at least 12 characters with lowercase, uppercase, a digit and a special character ([provision machines](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#step-3-provision-machines-from-azure)). |
| `ztp.admin_secret.username` | Yes | Text | Local administrator that the OS install creates. |
| `ztp.bmc_secret.vault` | Yes | Vault name | Vault that holds the BMC password (and the user name, unless `username_vault` says otherwise). |
| `ztp.bmc_secret.username_name` | Yes, unless `username` is set | Secret name | Secret whose value is the BMC user name. |
| `ztp.bmc_secret.username_vault` | Optional | Vault name | Vault of `username_name`, when it isn't `ztp.bmc_secret.vault`. |
| `ztp.bmc_secret.username` | Optional | Text | The BMC user name itself, instead of a secret. |
| `ztp.bmc_secret.password_name` | Yes | Secret name | Secret whose value is the BMC password. |
| `ztp.maintenance_password_secret` | Optional | `keyvault://<vault>/<secret>` | The maintenance environment's `edgeuser` password. The Media stage writes its SHA-512 crypt hash into each image, and the Device stage signs in with it. Without it the image keeps the default, `Password1`, which is published and works for anyone who reaches TCP 20001 while the maintenance environment runs. The vault must be in the subscription named by `ztp.admin_secret.subscription_id`. |

### Media and share

| Key | Required | Format | Used for |
| --- | --- | --- | --- |
| `ztp.share_host` | One of the two | IPv4 | The management host's address **as the BMCs reach it**. The BMCs mount `//<share_host>/<share_name>/ztp-usb-<node>.img`. |
| `ztp.share_host_adapter` | One of the two | Adapter name | Instead of `share_host`: the name of the local network adapter whose IPv4 address the BMCs reach. Useful when that address changes, for example on a VPN. It wins over `share_host`. |
| `ztp.share_name` | Yes | Text, letters, digits and hyphens | Name of the SMB share for the images. |

### Run data: media and evidence

A run downloads and writes a lot: the maintenance ISO, one USB image per node (about 4 GB each), the ownership vouchers and the run state. It also leaves evidence: the event log that monitors follow, change logs, and with `-Execute` a transcript. None of it belongs in a git repository, so ZTP keeps it in two folders that the file names.

| Key | Required | Format | Used for |
| --- | --- | --- | --- |
| `ztp.media_path` | Optional | Full path, outside any git working tree | Downloads and run data: `bootstrap\` (the ISO cache), `ztp-virtual-usb\` (the images), `vouchers\` and `ztp-state\` (the state with the saved BIOS originals, the handoff and the Arc-name files). Default: `%ProgramData%\AzureLocalZtp\<ztp.site_name>\media`. `-MediaPath` overrides it. |
| `ztp.evidence_path` | Optional | Full path, outside any git working tree | Evidence: `ztp-events.jsonl` (the event log Sonar and `Start-ZtpMonitor.ps1` follow), `bios-changes.jsonl`, `device-changes.jsonl`, `network-changes.jsonl`, and `<run>.<time>.transcript.log` for each `-Execute` run. Default: `%ProgramData%\AzureLocalZtp\<ztp.site_name>\evidence`. `-EvidencePath` overrides it. |

The run creates both folders when they're missing. It refuses a folder inside a git working tree (any folder with a `.git` above it), whether it came from the file, from the parameter or from the default, before it writes anything (`Resolve-ZtpDataPath`). Keep the folders where they last: a rerun skips the stages the state file records as completed, and resuming (`-From`) reads the state and vouchers there. See [Paths](prerequisites.md#paths).

```yaml
ztp:
  media_path: 'D:\Data\azl-ztp\site-01\media'
  evidence_path: 'D:\Data\azl-ztp\site-01\evidence'
```

## Values the entry point sets for you

`Invoke-ZtpEnvironment.ps1` fixes these values in the generated inputs. To change one, run the orchestrator directly (see [Orchestrator reference](automated-bootstrap.md)).

| Setting | Value |
| --- | --- |
| Site configuration name | `default` |
| Provisioning network | `LAN`. IP assignment `Automatic`, except `Manual` over the site range for static addresses with `static_method: site` (see [The site's network setting](#the-sites-network-setting)). |
| Provisioning time | NTP `Automatic` |
| Connectivity | `Public` (no proxy) |
| Role assignments | Site settings, Key Vault configuration, edge machine delegations and the Azure Local resource provider role are all on. |
| BMC handling | `RfsWriteAttribute` on, `SkipCertificateCheck` on (BMCs with self-signed certificates). |
| Timeouts | Voucher wait 120 min, bootstrap 120 min (voucher 90 min), Device 30 min, Ready 180 min, Network 60 min per adapter job, poll 60 s. Restore waits the orchestrator's default settle time (5 min) before its Ready watch. |
| Preview trains | Not considered for `provisioning_iso: latest`. |
| `ProvisionOs` retry | On: one automatic resubmit per node per run. |
