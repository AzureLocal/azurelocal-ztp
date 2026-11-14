# Infrastructure file reference

> Every key of the infrastructure file that ZTP reads, what it's for, and an example.

ZTP has one input: the `infrastructure.yml` of [azurelocal-toolkit](https://github.com/AzureLocal/azurelocal-toolkit/tree/main/config/variables), schema 5. Every Azure Local tool reads the same file. Pass it with `-InfrastructureFile`; there is no default path. The keys on this page are the ones ZTP reads (`ConvertFrom-ZtpInfrastructureV5`, `Test-ZtpInfrastructureV5` and `Test-ZtpEnvironment` in `scripts/simplified-provisioning/ZtpEnvironment.Common.ps1`); the toolkit's registry (`config/variables/schema/master-registry.yaml`) lists `ztp` in their `used_by`. The file can hold every other key of the schema: ZTP ignores them.

The file holds **no secrets**: each credential is a secret reference, read at run time by the toolkit's one resolver (see [Secrets](#secrets)). Example values on this page are placeholders for the example company Infinite Improbability Corp (`iic-*` names, documentation addresses, all-zero GUIDs).

## Which template to start from

Start from a template in azurelocal-toolkit, never from scratch:

- **ZTP only.** You install the OS and register the machines with ZTP, and run no automation after it: the [ZTP-only template](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/config/variables/examples/infrastructure.ztp.example.yml) (`_metadata.scope: ztp`). It holds only the keys ZTP reads.
- **ZTP, then OS configuration and deployment.** The [full template](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/config/variables/examples/infrastructure.example.yml). ZTP reads its part of it and ignores the rest.

Check it with the toolkit before a run: `./scripts/common/infrastructure/Test-InfrastructureFile.ps1 -Path ./infrastructure.yml` (in the toolkit clone).

## How the file is checked

1. **Schema 5 or nothing.** A file without `_metadata.schema_version` 5.x stops the run with exit code 2 and a message that names the file and points at the toolkit's `config/variables/examples/infrastructure.example.yml`. A missing, empty or unreadable file is exit code 2 too. ZTP's own environment-file layout (`cluster_nodes`, `network_intents`, `ztp`) is retired.
2. **The toolkit's check.** When the toolkit is found (`$env:AZL_TOOLKIT_ROOT`, else an `azurelocal-toolkit` clone next to this repository), ZTP runs its `Test-AzlInfrastructure`: the schema and the toolkit's rules. Its errors stop the run with their rule IDs; its warnings are shown.
3. **ZTP's check.** Always: `scenario.os_install: simplified`, exactly one management port per node, every vault a `keyvault://` reference names is in `key_vaults`, one BMC login for every node, and every key on this page in its format. Every problem is named in schema 5 paths and all of them at once, before anything runs, for example `site.time_zone is required` or `nodes[0] (iic-azl-n01) management port mac_address is required`.
4. **An extra validator**, only when `-ValidatorPath` names one. ZTP looks for no validator by default.

## Keys

"Optional" means the run works without it, with the default shown.

### Not read by ZTP

ZTP ends at the Handoff, so it reads nothing that OS configuration or deployment owns. These keys can stay in the file:

| Key | Who reads it |
| --- | --- |
| `hardware.sbe` | OS configuration and deployment. ZTP prints `Note: hardware.sbe ignored: SBE belongs to OS configuration.` The OS install discovers its own SBE. |
| `identity.*` | The deployment admin and the domain, in OS configuration and deployment. |
| `networking.ntp_servers` | Time on the host, set in OS configuration. The site's time setting is `provisioning.simplified.ntp`. |
| `networking.intents`, `networking.storage`, `cluster`, `storage`, `environment` | Deployment. |
| The other ports in `nodes[].network_adapters` (no role `management` or `provisioning`) | OS configuration (DHCP off, unused adapters disabled). ZTP copies them to the handoff only. |
| `site.code`, `nodes[].rack_position` | No stage. |

OS configuration (azurelocal-toolkit [Phase 03 OS Configuration](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/)) reads them, before Validate and Deploy.

### Scenario

| Key | Required | Format | Used for |
| --- | --- | --- | --- |
| `_metadata.schema_version` | Yes | `5.x.y` | The schema. Anything else is exit code 2. |
| `_metadata.scope` | Optional | `ztp` or `full` | For the toolkit's validator: `ztp` requires only the keys ZTP reads. |
| `scenario.os_install` | Yes | `simplified` | ZTP provisions with simplified machine provisioning only. |
| `scenario.outbound_path` | Optional | `direct` (default) or `proxy` | How the machines reach Azure. `direct`: the site's connectivity setting is `Public`. `proxy`: it is `Proxy`, and the Device stage sends `networking.outbound.proxy` to every node's maintenance environment. `arc_gateway`, `proxy_arc_gateway` and `private_path` are refused: Microsoft doesn't support Arc gateway with simplified machine provisioning in the preview. |
| `networking.outbound.proxy.url` | With `proxy` | `http://<host>:<port>` | The proxy server. A plain proxy: no credentials, no PAC file, no `.local` domain (Learn). |
| `networking.outbound.proxy.bypass` | With `proxy` | Non-empty list | What goes direct: each machine's address and NetBIOS name, the cluster's, and the infrastructure addresses. One entry per item; `localhost`, not `<local>`; a wildcard such as `192.0.2.*` for a subnet (no CIDR) and `*.improbability.cloud` for a domain. |

### Nodes

`nodes` is a list with one entry per machine.

| Key | Required | Format | Used for |
| --- | --- | --- | --- |
| `nodes[].name` | Yes | Text, unique | Host name, edge machine name, image name (`ztp-usb-<name>.img`). `-Node` takes these names. |
| `nodes[].serial_number` | Yes | Text | The machine's serial number. Maps each voucher (`\vouchers\<serial>\`) to its node. |
| `nodes[].bmc.ip_address` | Yes | IPv4 | The BMC address. Redfish target, and the only source allowed to reach the SMB share. The BMC login is `hardware.bmc`; a node's own `bmc.username` and `password` must be the same. |
| `nodes[].arc_machine_name` | Optional | 1-54 letters, digits, `-`, `_`, `.`; not ending in `.` | Name of the node's Arc machine. Default: `nodes[].arc_resource_name`, else the node's `name`. In live runs the service replaced it at claim time; the handoff records the name Azure used. See [Arc machine names](troubleshooting.md#arc-machine-names). |
| `nodes[].network_adapters[]` | Yes (or `nodes[].management`) | List of ports: `name`, `mac_address`, `slot`, `model`, `roles`, `ip_assignment`, `ip_address`, `vlan_mode`, `vlan_id` | The machine's ports. ZTP reads the **management port**: the one entry with role `management` and an `ip_assignment` other than `none`. Every port goes to the node list for the handoff, and `slot` feeds the BIOS plan. ZTP doesn't configure the others. |
| Management port `mac_address` | Yes | `AA:BB:CC:DD:EE:FF` or `AA-BB-CC-DD-EE-FF` | The Device stage finds the maintenance environment's adapter by it (and, without a maintenance address, finds the node itself by it); the Network stage finds the edge machine's network adapter by it. Separators and case don't matter. The provisioned OS names its ports `Port0` to `Port6`, so OS configuration must find the port by this MAC too. |
| Management port `ip_address` | With `static` | IPv4, inside `networking.management.subnet` | The node's management address. How it gets there depends on `ip_assignment` and `networking.management.static_method`. See [The site's network setting](#the-sites-network-setting). |
| Management port `ip_assignment` | Yes | `static`, `dhcp_reservation`, `dhcp` or `preconfigured` | How the management address is set ([Management address modes](prerequisites.md#management-address-modes)). `dhcp_reservation` (Mode A, recommended): the port stays on DHCP and the DHCP server reserves `ip_address` for the MAC; the Network stage verifies it. `static` (Mode B or C): ZTP sets `ip_address`, the mask, gateway and DNS on the port before the install; the install resets the port, the Network stage records it as left to OS configuration, and OS configuration sets it again by MAC. Mode B when the port also has role `provisioning` and `provisioning_network` is `dhcp`, else Mode C. `dhcp`: no reservation, so the address can change; reported only. `preconfigured`: ZTP doesn't change the port. |
| Management port `name` | Optional | Text | Sent with `static_method: site`. Leave it as the toolkit writes it; the MAC is enough. |
| Management port `vlan_mode`, `vlan_id` | Optional | `access` or `tagged`; 0-4094 | The VLAN the host tags when `networking.management.vlan_id` isn't set (0 for `access`). |
| `nodes[].management.ip_address`, `.mac_address`, `.adapter_name` | Instead of `network_adapters` | As above | The schema 5.0 form: one management port. Its mode is `networking.management.ip_assignment` (default `static`). |
| `nodes[].maintenance_address` | Optional | IPv4 | The maintenance environment's address, when you know it before the run (a DHCP reservation, or the lease the node's console shows). Without it, ZTP takes the `ip_address` of the node's port with role `provisioning` (and not `management`), when the file gives one. Without either, the Device stage **scans by MAC**: it probes every address of `networking.management.provisioning_dhcp_range` (default: the management subnet) on TCP 20001 in parallel, asks each answer for its adapters (`GetNetworkAdapters`), and takes the one that lists the node's management MAC. Verified live (Dell AX-760, DHCP with no reservation). See [The Device stage](#the-device-stage). |
| `nodes[].bios`, `nodes[].bios_during_provisioning` | Optional | Mapping: BIOS attribute name -> value | One node's own BIOS values, merged over `hardware.bios` and `hardware.bios_during_provisioning`. See [BIOS settings](#bios-settings). |
| `nodes[].san.hbas[].slot`, `.type`, `.model` | Optional | `Slot <n>`; `fibre_channel`, ... | The SAN adapters. ZTP turns their PCIe slots off for the OS install (`provisioning.simplified.isolate_san_adapters`). |
| `nodes[].san.hbas[].bios_attribute`, `.bios_disabled_value`, `.bios_enabled_value` | Optional | Text | The vendor's BIOS attribute for the HBA's slot, for a vendor without a slot mapping or a label that isn't `Slot <n>`. |

### Management network

| Key | Required | Format | Used for |
| --- | --- | --- | --- |
| `networking.management.subnet` | Yes | CIDR, for example `192.0.2.0/24` | Prefix length of the static address. Every static address must be inside it. Also the default scan range of the Device stage. |
| `networking.management.gateway` | Yes | IPv4 | The default gateway of the management port. |
| `networking.management.dns_servers` | Yes | List of IPv4 | DNS of the management port. Learn: DNS servers can't be changed after deployment ([DNS server considerations](https://learn.microsoft.com/azure/azure-local/plan/cloud-deployment-network-considerations#dns-server-considerations)). |
| `networking.management.vlan_id` | Optional | 0-4094 | The VLAN the host tags on the management port, for the Device and Network stages and the site's `Manual` setting. 0 for an access port. Default: the management port's `vlan_id` (0 when its `vlan_mode` is `access`). |
| `networking.management.static_method` | Optional | `device` (default) or `site` | Who sets a static management address. `device`: the Device stage, on the port with the management MAC, in the maintenance environment before the claim. The site's network setting is `Automatic` and the claim carries no `Manual` adapter, so that address is the only static the node gets. `site`: Microsoft's OS install, from the site's `Manual` setting over `site_ip_range` and a `Manual` adapter in the claim, keyed by MAC. For environments without the Device stage. With `site`, the install puts the address on the first ready port and ignores the MAC (seen live on a Dell AX-760); the Network stage then reports it. |
| `networking.management.site_ip_range.start`, `.end` | Optional | IPv4, inside `subnet`, start before end | Only with `static_method: site`: the address range of the site's `Manual` network setting. Default: the lowest to the highest static node address. Every static node address must be inside it. |
| `networking.management.provisioning_dhcp_range.start`, `.end` | Optional | IPv4, start before end, at most 4096 addresses | The DHCP pool on the provisioning network, where the maintenance environment takes its address. The Device stage scans it on TCP 20001 for each node without a maintenance address. Default: the management subnet. A node's static address must not be inside it. |
| `networking.management.provisioning_network` | Optional | `dhcp` (default) or `static` | How the maintenance environment gets the address it reaches Azure with, before the machine is claimed. `dhcp`: a DHCP server answers on a port with role `provisioning` (on a machine with no DHCP on its management network, another port carries it: Mode C). `static`: the run warns, or stops when no port with role `provisioning` takes DHCP (G23). Learn documents only the Configurator app for a static address there. |
| `networking.management.ip_assignment` | Optional | As the management port's | Only for nodes in the schema 5.0 form (`nodes[].management`). |

#### The site's network setting

The site configuration has one network setting for the machines it provisions. ZTP derives it from the management mode and `static_method` (`Get-ZtpSiteNetwork`).

| `ip_assignment` | `static_method` | Site setting | Manual adapter in the claim |
| --- | --- | --- | --- |
| `static` | `device` (default) | `Automatic` | None. The Device stage has set the address by MAC before the claim. |
| `static` | `site` | `Manual`: `addressRange { startIp, endIp }` from `site_ip_range` (default: the lowest to the highest static node address), `defaultGateway` and `dnsServers` from the management network, `subnetMask` from `subnet`, `vLanId` from the VLAN (0 when absent) | One per node, keyed by the management MAC, with the address, mask, gateway, DNS and VLAN. |
| `dhcp_reservation`, `dhcp` | either | `Automatic` | None. |
| `preconfigured` | either | `Automatic` | None. ZTP doesn't manage the address. |

The plan prints the setting, for example `Site network: Automatic.` with `device`, or `Site network: Manual 192.0.2.11-192.0.2.12, gateway 192.0.2.1, mask 255.255.255.0, DNS 192.0.2.30, 192.0.2.31, VLAN 0` with `site`. It also prints who sets the static addresses.

#### The Device stage

The maintenance environment runs the Configurator App's REST service, and the Device stage (`Set-ZtpDeviceConfiguration.ps1`, between Vouchers and Azure) uses it to put the static address on the port with the management MAC before the claim, as the Configurator App would. It needs TCP 20001 from this server to the maintenance environment. The operations, how ZTP signs in and what is not possible are in [Appendix B](appendix/configurator-app-api.md#how-ztp-uses-this-service).

| | |
| --- | --- |
| Service | `https://<maintenance address>:20001/BootstrapOobeService/<Operation>`: CoreWCF WebHttp, JSON, property names in PascalCase. |
| Finding it | The node's maintenance address when it has one. Otherwise a scan of `provisioning_dhcp_range` (default: the management subnet) on TCP 20001; the node is the answer whose `GetNetworkAdapters` lists its management MAC. The maintenance environment takes a lease on every port, so it can answer on several addresses; one not on the management port is preferred. The event log records `MaintenanceEnvironmentFound`. |
| Sign-in | HTTP Basic as `edgeuser` (`provisioning.simplified.maintenance_environment.username`), with the password of `provisioning.simplified.maintenance_password` when it's set (the Media stage builds it into each image), otherwise the maintenance environment's default `Password1`. |
| Certificate | Self-signed by the maintenance environment, with nothing to check it against, so these calls skip the certificate check. No other call in ZTP does. The password therefore goes to every host that answers on TCP 20001 in the scan range: scan only an isolated provisioning network and keep the range to the DHCP pool ([Prerequisites](prerequisites.md#network)). |
| Read-back | A read of the adapters counts as this node's only when it lists the management MAC. A response without the MAC (another device on that address) is ignored, and the configuration status is read only from an address that passed that check. |
| Known limit | If another port of the same machine already holds the target static address, the node stops with a message naming the port, its MAC and the address, and nothing is sent. Free the address on that port, or correct the management port's `ip_address` or `mac_address`. |
| Checks before any request | Two nodes with the same static address, or a static address inside `provisioning_dhcp_range` (the pool would lease it to another device), fail the file check and the Device stage. |

For each static node:

1. `GET GetNetworkAdapters` (**verified live**: HTTP 200, `{ "NetworkAdapters": [ { "MacAddress", "Name", "EnableDhcp", "IpAddress", "Gateway", "SubnetMask", "DnsAddressArray", "VlanId", "LogicalIndex", ... } ] }`, MACs as 12 lower-case hex digits). The adapter with the management MAC is found whatever the separators and case; none stops the node and lists the MACs found. An adapter that already reports `EnableDhcp: false` with the address, mask, gateway, DNS and VLAN is left alone.
2. `POST SetArcBootstrapDeviceConfiguration` with `{ "Network": { "NetworkAdapters": [ { "MacAddress", "EnableDhcp": false, "IpAddress", "SubnetMask", "Gateway", "DnsAddressArray", "VlanId" } ] } }`, the MAC as 12 lower-case hex digits. No `HostName` is sent: the claim sets the host name. **Verified live** (Dell AX-760, 2026-11-07, `VlanId: 0`): the status reports `NetworkConfig` `Succeeded`, and `GetNetworkAdapters` then reads the static address back on the management port. With `scenario.outbound_path: proxy` the Device stage also sends the proxy URL and bypass list (`WebProxyConfiguration`) and waits for the `WebProxy` step.
3. `GET GetArcBootstrapDeviceConfigurationStatus` and `GET GetNetworkAdapters` until the adapter reports the static configuration, up to `provisioning.simplified.timeouts.device_minutes` (30). A `Status` that reads `Failed` stops the node.

`dhcp` and `preconfigured` nodes are only reported, and only when they have a maintenance address; they aren't scanned for. Each change goes to `<evidence_path>\device-changes.jsonl`, and its progress to the event log with stage `Device`. The plan (without `-Execute`) prints the request it would send. To run it again: `-From Device`.

The OS install then resets every port to DHCP: the maintenance environment's network settings don't carry into the OS (verified live, Dell AX-760, build 2610, 2026-11-07). So after ZTP the management port has a DHCP address (Mode B) or none (Mode C), and OS configuration sets the static again by MAC. See [Management address modes](prerequisites.md#management-address-modes).

#### The Network stage

After Ready, the Network stage (`Set-ZtpManagementAddress.ps1`) **verifies** each node's management address. It reads Azure's per-NIC report (`edgeMachines/<node>/networkAdapters`, api-version 2026-10-01), finds the management port (the adapter whose reported MAC is the management MAC, whatever the card or slot), and compares it with the file. It changes nothing, and needs no WinRM and no firewall change. For each node:

| Mode | What the Network stage records |
| --- | --- |
| A, Reserved (`dhcp_reservation`) | Verified when the management port has `ip_address`; without `ip_address` in the file, when it has any DHCP address. Otherwise not verified, with what to check (the reservation for the MAC). |
| B and C, static | Verified when the management port reports `ip_address` as static and no other port has it. After a normal install it doesn't: the row is `Deferred` (event `ManagementAddressDeferredToOsConfiguration`) and the reason says what the port has, for example `Mode B (Static with DHCP): the management port Port1 (MAC 00:00:5e:00:53:aa) has DHCP 192.0.2.116 after the install; expected static 192.0.2.11; OS configuration sets it by MAC.` |
| `dhcp`, `preconfigured` | Reported only: verified when the port has `ip_address`. Never changed. |

A management MAC no adapter reports stops the node, listing the MACs found: the file is wrong, and OS configuration would fail on it the same way. The result goes to the state file and the handoff (`managementAddressVerified`, `managementAddressReason`, `managementMode`, and every port in `networkAdapters[]`). To run it again: `-From Network`.

**`-ApplyThroughAzure` (opt-in, unreliable).** The orchestrator's `-ApplyThroughAzure` brings back the earlier fix for static nodes through `jobs/ApplyConfiguration`. On two separate live runs (Dell AX-760, build 2610, 2026-11-07) the job never started and Azure marked it `Failed` after about 35 minutes. Use OS configuration instead.

```yaml
networking:
  management:
    subnet: "192.0.2.0/24"
    gateway: "192.0.2.1"
    vlan_id: 0
    dns_servers: ["192.0.2.30", "192.0.2.31"]
    static_method: device                                              # optional; the default
    provisioning_dhcp_range: { start: "192.0.2.100", end: "192.0.2.199" } # optional; default: the subnet
    provisioning_network: dhcp                                         # optional; the default
nodes:
  - name: "iic-azl-n01"
    serial_number: "SERIAL01"
    bmc: { ip_address: "198.51.100.11", type: idrac }
    network_adapters:
      - { name: "Embedded NIC 1", slot: "Embedded", mac_address: "00:00:5E:00:53:11", roles: [management], ip_assignment: static, ip_address: "192.0.2.11", vlan_mode: access, vlan_id: 711 }
      - { name: "Slot 3 Port 1", slot: "Slot 3", mac_address: "00:00:5E:00:53:13", roles: [provisioning], ip_assignment: none }
```

### Hardware

| Key | Required | Format | Used for |
| --- | --- | --- | --- |
| `hardware.vendor` | Yes | Text, for example `Dell` | Picks `config/oem/<vendor>.json`: the BMC kind, its log services, the signal patterns the Bootstrap watch reads, and the BIOS slot mapping. |
| `hardware.model` | Optional | Text | Compared with the vendor's `verified_models` for the derived BIOS plan (a warning, never a stop). |
| `hardware.bmc.username` | Yes | Secret reference, or the user name itself | The BMC login of every node. See [Secrets](#secrets). |
| `hardware.bmc.password` | Yes | Secret reference | The BMC password. |
| `hardware.bmc.verify_certificate` | Optional | `true` or `false` (default `false`) | Check the BMC's TLS certificate. BMCs ship a self-signed one. |
| `hardware.bmc.rfs_write_attribute` | Optional | `true` or `false` | Also set the BMC's Remote File Share write attribute in the Boot stage. Default: the vendor's `bmc.rfsWriteAttribute` (Dell `true`, the others `false`). |
| `hardware.bios` | Optional | Mapping: BIOS attribute name -> value, values quoted as strings | The machine's **final** BIOS state. The Boot stage sets it before the maintenance boot, and the Restore stage sets any key that `bios_during_provisioning` changed back to this value. |
| `hardware.bios_during_provisioning` | Optional | Same | **Temporary** BIOS values, for the install only. The Boot stage applies them over `hardware.bios` (these win), and saves each attribute's value as found. The Restore stage, after Network and before Handoff, sets each key back to `hardware.bios[key]`, or to the saved value. |

#### BIOS settings

ZTP derives the two BIOS actions most machines need from the inventory, so nobody has to write a vendor's attribute names: a SAN adapter's slot (`nodes[].san.hbas[].slot`) is turned off for the install, and the embedded NICs are enabled when a management or provisioning port is in slot `Embedded`. The mapping is in `config/oem/<vendor>.json` (Dell today). See [Hardware-aware BIOS actions](infrastructure-schema-5.md#hardware-aware-bios-actions-schema-54). The raw maps are explicit overrides and always win:

```yaml
hardware:
  bios:                       # the final state
    Slot2: "BootDriverDisabled"
  bios_during_provisioning:   # for the install only
    Slot2: "Disabled"
nodes:
  - name: "iic-azl-n02"
    bios_during_provisioning:
      Slot2: "Enabled"        # this node has no HBA there
```

Names are the attributes of the BMC's Redfish Bios resource (`GET /redfish/v1/Systems/System.Embedded.1/Bios` on an iDRAC), and they're case-sensitive. Quote every value: ZTP converts it to the type the BIOS reports for that attribute. The check refuses a value that isn't a string and a name with spaces.

In the Boot stage, before it mounts the image, ZTP does this for each node that has settings (`Set-ZtpBios.ps1`):

1. Reads the current values and the attribute registry. An attribute the BIOS doesn't have, or a value it doesn't allow, stops the run before anything changes. If every value already matches, it moves on without a restart.
2. Sends only the values that differ: `PATCH /redfish/v1/Systems/System.Embedded.1/Bios/Settings` with `"@Redfish.SettingsApplyTime": { "ApplyTime": "OnReset" }`.
3. Powers the node on if it's off, otherwise restarts it, so the BIOS job runs.
4. Waits, up to `provisioning.simplified.timeouts.bios_minutes` (30), until the Bios resource reports every new value. Then it mounts the image and sets the one-time boot.

Every change goes to `<evidence_path>\bios-changes.jsonl`, to the Boot stage's evidence, and to the event log as a `BiosChanged` event.

#### The Restore stage

The Restore stage (`Restore-ZtpBios.ps1`, between Network and Handoff) undoes `bios_during_provisioning` and the derived temporary values. For each node it sets every temporary key back to `hardware.bios[key]` (with the node's own `bios` merged over it) when the file names one, otherwise to the original value the Boot stage saved. It restarts the node through Redfish and waits until the BIOS reports the values. Then the orchestrator waits `provisioning.simplified.timeouts.restore_settle_minutes` (5) and checks that each Arc machine is Connected and each edge machine still ready to cluster. If the state file lost an original and `hardware.bios` doesn't name the key, the stage stops and asks you to set `hardware.bios.<key>`. The handoff records what was set back as `biosRestored`.

### Azure

| Key | Required | Format | Used for |
| --- | --- | --- | --- |
| `azure.tenant_id` | Yes | GUID | Tenant of every Azure call. |
| `azure.location` | Yes | Azure region | Region of the site configuration and edge machines, of the OS image catalog, and of the resource group if the run creates it. In the preview only `eastus` works for the provisioning resources ([Learn](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#azure-prerequisites)). |
| `azure.subscription_id`, `azure.resource_group` | Yes | GUID; text | Subscription and resource group of the site and edge machines. The group is created if missing (`provisioning.simplified.create_resource_group`). |
| `provisioning.simplified.subscription_id`, `.resource_group` | Optional | GUID; text | The same, when the provisioning resources go elsewhere than `azure.*`. |
| `azure.hci_resource_provider_object_id` | Optional | GUID | Object ID of the Azure Local resource provider's service principal in your tenant. If you leave it out, the run looks it up, which needs directory read rights. A managed identity doesn't have those by default, so set it for pipelines. |
| `site.name` | Yes | Text | Display name of the `Microsoft.Edge` site. |
| `site.time_zone` | Yes | Text, for example `Central Standard Time` | Site time zone. |
| `provisioning.simplified.site_name` | Yes | Text | Resource name of the `Microsoft.Edge` site. Also names the ARM deployment `ztp-<site_name>` and the default run folders. |
| `provisioning.os_version` | Yes | `latest`, `latest-preview`, or a validated solution recipe version (`12.YYMM.x.y`) | The OS the machines install. Pin a version. `Get-ZtpOsImage.ps1` lists the catalog. The handoff records the build actually installed. See [Pin the OS version](operator-guide.md#pin-the-os-version). |
| `provisioning.simplified.maintenance_iso` | Yes | `latest`, a train (`2610`), a build, or a Microsoft download URL | The maintenance ISO. `latest` takes the newest published general-availability train. |
| `tags` | Optional | Mapping | Tags on the site configuration and the edge machines. The resource group gets them only if the run creates it. Learn: a policy that *requires* tags isn't supported ([troubleshooting](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning#when-you-provision-new-machines-you-receive-an-internal-server-error)). |

To find the resource provider's object ID once with an account that can read the directory:

```powershell
(Get-AzADServicePrincipal -ApplicationId '1412d89f-b8a8-4111-b4fd-e82905cbd85d').Id
```

### Secrets

Every credential in the file is a **secret reference**, never a value. ZTP reads the references through azurelocal-toolkit's one resolver, `scripts/common/secrets/AzlSecret.psm1`, which every Azure Local tool uses. It finds the toolkit under `$env:AZL_TOOLKIT_ROOT`, else in an `azurelocal-toolkit` clone next to this repository; with `-Execute` and no toolkit, the run stops with exit code 2 before it writes anything and asks you to set `AZL_TOOLKIT_ROOT` or clone the toolkit there. The plan (without `-Execute`) reads no secret. Values stay `SecureString`s in memory and are never written or logged; messages name the reference only. Nothing prompts.

| Reference | Provider | Needs |
| --- | --- | --- |
| `keyvault://<vault>/<secret>` | Azure Key Vault (the default provider) | The vault listed in `key_vaults`, and an Az sign-in that can read its secrets (Key Vault Secrets User). |
| `env://<VARIABLE>` | An environment variable of the run | The variable set and not empty. |
| `file://<name>` | A file in `secrets.file.directory` | `secrets.file.directory` (an absolute path). One secret per file. |
| `command://<name>` | The output of `secrets.command` | `secrets.command.executable` and `.arguments` (with `{name}`), optional `.timeout_seconds`. |

| Key | Required | Format | Used for |
| --- | --- | --- | --- |
| `key_vaults[].name`, `.subscription_id`, `.resource_group` | With a `keyvault://` reference | Text; GUID; text | Every vault a `keyvault://` reference names. The provisioning administrator's vault gives the Bicep template its subscription and resource group (it assigns roles on it). ZTP keeps every `keyvault://` secret in that vault's subscription. |
| `hardware.bmc.username` | Yes | Secret reference, or the user name itself | The BMC user name. |
| `hardware.bmc.password` | Yes | Secret reference (any provider) | The BMC password. |
| `provisioning.simplified.maintenance_password` | Optional | Secret reference (any provider) | The maintenance environment's `edgeuser` password. The Media stage writes its SHA-512 crypt hash into each image, and the Device stage signs in with it. Without it the image keeps the default, `Password1`, which is published and works for anyone who reaches TCP 20001 while the maintenance environment runs. |
| `provisioning.simplified.admin.username` | Yes | Text | Local administrator that the OS install creates. |
| `provisioning.simplified.admin.password` | Yes | `keyvault://<vault>/<secret>` only | The provisioning administrator password. **Azure reads it from the vault itself** when it provisions the machines: the template passes the vault and the secret name, never a value. So this one is a Key Vault reference. **Create it before the run.** Learn asks for at least 12 characters with lowercase, uppercase, a digit and a special character ([provision machines](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#step-3-provision-machines-from-azure)). |
| `secrets.file.directory`, `secrets.command.*` | With `file://` or `command://` | See the toolkit | Where the resolver reads those providers from. |

```yaml
key_vaults:
  - { name: "kv-iic-mgmt-01", subscription_id: "00000000-0000-0000-0000-000000000000", resource_group: "rg-iic-mgmt-01" }
hardware:
  bmc:
    username: "keyvault://kv-iic-mgmt-01/bmc-username"   # or env://IIC_BMC_USER, or the name itself
    password: "keyvault://kv-iic-mgmt-01/bmc-password"   # or env://, file://, command://
provisioning:
  simplified:
    admin: { username: "administrator", password: "keyvault://kv-iic-mgmt-01/provisioning-admin-password" }
    maintenance_password: "keyvault://kv-iic-mgmt-01/maintenance-password"
```

### Media and share

| Key | Required | Format | Used for |
| --- | --- | --- | --- |
| `provisioning.simplified.media_share.host` | One of the two | IPv4 | The management host's address **as the BMCs reach it**. The BMCs mount `//<host>/<name>/ztp-usb-<node>.img`. |
| `provisioning.simplified.media_share.host_adapter` | One of the two | Adapter name | Instead of `host`: the local network adapter whose IPv4 address the BMCs reach. Useful when that address changes, for example on a VPN. It wins over `host`. |
| `provisioning.simplified.media_share.name` | Yes | Text, letters, digits and hyphens | Name of the SMB share for the images. |
| `provisioning.simplified.media_share.account_name` | Optional | Default `svc-ztp-media` | The local account the BMCs sign in to the share with. |
| `provisioning.simplified.media_share.keep` | Optional | Default `false` | Keep the share, firewall rule and account after the vouchers are collected. |

### Run data: media and evidence

A run downloads and writes a lot: the maintenance ISO, one USB image per node (about 4 GB each), the ownership vouchers and the run state. It also leaves evidence: the event log that monitors follow, change logs, and with `-Execute` a transcript. None of it belongs in a git repository.

| Key | Required | Format | Used for |
| --- | --- | --- | --- |
| `provisioning.simplified.media_path` | Optional | Full path, outside any git working tree | Downloads and run data: `bootstrap\`, `ztp-virtual-usb\`, `vouchers\` and `ztp-state\`. Default: `%ProgramData%\AzureLocalZtp\<site_name>\media`. `-MediaPath` overrides it. |
| `provisioning.simplified.evidence_path` | Optional | Full path, outside any git working tree | Evidence: `ztp-events.jsonl` (the event log Sonar and `Start-ZtpMonitor.ps1` follow), `bios-changes.jsonl`, `device-changes.jsonl`, `network-changes.jsonl`, and a transcript for each `-Execute` run. Default: `%ProgramData%\AzureLocalZtp\<site_name>\evidence`. `-EvidencePath` overrides it. |

The run creates both folders when they're missing. It refuses a folder inside a git working tree, whether it came from the file, from the parameter or from the default, before it writes anything (`Resolve-ZtpDataPath`). Keep the folders where they last: a rerun skips the stages the state file records as completed, and resuming (`-From`) reads the state and vouchers there. See [Paths](prerequisites.md#paths).

### Settings with a default

Every other choice ZTP makes is a key of `provisioning.simplified`. Each default is what ZTP did before the key existed. [The variables audit](variables-audit.md) lists every action and threshold with the key that controls it.

| Key | Default | Used for |
| --- | --- | --- |
| `isolate_san_adapters` | `true` when the node lists `san.hbas` | Turn the HBAs' slots off for the install. |
| `enable_embedded_nics` | `true` | Enable the embedded NICs when a management or provisioning port is `Embedded`. |
| `create_resource_group` | `true` | Create the resource group when it's missing; `false` stops instead. |
| `configuration_name` | `default` | Name of the site configuration. |
| `managed_resource_group_name` | empty (the service chooses) | The managed resource group. |
| `apply_site_settings`, `use_key_vault_configuration`, `assign_provisioning_roles`, `assign_hci_rp_role` | `true` | The site settings, the Key Vault configuration, the edge machine delegations and the Azure Local resource provider role. |
| `network_kind` | `LAN` | `LAN` or `WLAN`. |
| `ntp.configuration`, `.server`, `.alternate_server` | `Automatic` | The site's time setting; `Manual` needs `server`. |
| `site_mode` | `Auto` | `Auto`, `Create` or `Reuse` the site. |
| `deployment_name` | `ztp-<site_name>` | Name of the ARM deployment. |
| `skip_azure_check`, `include_preview` | `false` | Skip the Azure checks of the Resolve stage; consider preview trains for `maintenance_iso: latest`. |
| `max_train` | none | The newest train `latest` may pick (`YYMM`). |
| `retry_provision_os` | `true` | One automatic resubmit of a failed OS install per node per run. |
| `usb_image.size_gb`, `.name_prefix` | `4`, `ztp-usb-` | The virtual USB images. |
| `maintenance_environment.port`, `.username` | `20001`, `edgeuser` | The Configurator service the Device stage calls. |
| `timeouts.voucher_wait_minutes`, `bootstrap_minutes`, `bootstrap_voucher_minutes`, `bootstrap_stall_minutes`, `device_minutes`, `ready_minutes`, `network_minutes`, `restore_settle_minutes`, `bios_minutes`, `poll_interval_seconds` | `120`, `120`, `90`, `20`, `30`, `180`, `60`, `5`, `30`, `60` | The stage budgets. |
