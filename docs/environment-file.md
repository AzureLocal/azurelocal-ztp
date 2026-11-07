# Environment file reference

> Every key that `Invoke-ZtpEnvironment.ps1` and `Initialize-ZtpNode.ps1` read from the environment file, what it's for, and an example.

::: warning Deprecated layout
This page describes ZTP's own environment-file layout (`cluster_nodes`, `network_intents`, `ztp`, ...). It still works, and it's deprecated: use the master `infrastructure.yml` (schema 5), which every Azure Local tool reads and which lists each machine's ports. Pass it through the same `-InfrastructureFile`; ZTP detects the format. See [Reading the master infrastructure.yml](infrastructure-schema-5.md) for where each key below comes from in schema 5.
:::

The environment file is YAML. It describes the machines, the management network, and the Azure targets. It holds **no secrets**: each credential is a Key Vault reference. The file can hold other keys for other tools; ZTP ignores keys that aren't listed here.

A complete example with placeholder values is in [`examples/infrastructure.example.yml`](https://github.com/AzureLocal/azurelocal-ztp/blob/main/examples/infrastructure.example.yml).

## How the file is checked

- The run checks the file before it does anything else and lists every problem at once. `Invoke-ZtpEnvironment.ps1` needs the **Provision** keys. `Initialize-ZtpNode.ps1` on its own (or `-From Prepare`) needs only the **Prepare** keys.
- If a script named `tools\Validate-Infrastructure.ps1` exists in the same folder as the environment file, the entry point runs it first and stops if it fails. If there's no such script, it prints a warning and goes on.

## Keys

"Needed by" says which run needs the key: **P+P** means both Provision and Prepare, **Prov** means Provision only. "Optional" means the run works without it.

### Nodes

`cluster_nodes` is a list with one entry per machine.

| Key | Needed by | Format | Used for |
| --- | --- | --- | --- |
| `cluster_nodes[].name` | P+P | Text, unique | Host name, edge machine name, image name (`ztp-usb-<name>.img`). |
| `cluster_nodes[].ip_address` | P+P | IPv4 | The node's management address. How it gets there depends on `network_intents.management.ip_assignment`. With `static`, the provisioning service sets it at the OS install, on the first ready port rather than the port with `mac_address`; the Network stage then moves it to the port with `mac_address` through Azure, and Prepare checks it in the OS and sets it only if it's still missing. Prepare signs in on this address if the node answers there, and otherwise on the address the node's Arc machine reports for the management MAC. That address must be in this server's WinRM TrustedHosts. |
| `cluster_nodes[].mac_address` | P+P | `AA:BB:CC:DD:EE:FF` or `AA-BB-CC-DD-EE-FF` | The management port. The provisioning request names the port by this MAC (the OS install ignores it), the Network stage finds the edge machine's network adapter by it, and Prepare finds the Windows adapter by it. Separators and case don't matter. |
| `cluster_nodes[].adapter_name` | P+P, optional | Text | Name of the management port, also sent in the provisioning request. Leave it out unless you know the name the installed OS gives the port; the MAC is enough. |
| `cluster_nodes[].arc_machine_name` | Prov, optional | 1-54 letters, digits, `-`, `_`, `.` | Name of the node's Arc machine. Default: the node's `name`. Sent as the edge machine's `arcMachineResourceId`. Without it the service names the Arc machine `ROE1-<id>`, and an Arc machine can't be renamed. |
| `cluster_nodes[].service_tag` | Prov | Text | The machine's serial number. Maps each voucher (`\vouchers\<serial>\`) to its node. |
| `cluster_nodes[].idrac_ip` | Prov | IPv4 | The BMC address. Redfish target, and the only source allowed to reach the SMB share. |
| `cluster_nodes[].maintenance_address` | Prov, optional | IPv4 | The maintenance environment's address: the DHCP lease of the port it reaches Azure through, as the node's console shows it. Give that port's MAC a DHCP reservation so the address is known before the run. The Device stage reaches the maintenance environment's REST service there; a node without it is skipped by that stage, and the Network stage sets its address after the OS install. See [The Device stage](#the-device-stage). |
| `cluster_nodes[].ip_assignment` | P+P, optional | `static`, `dhcp` or `preconfigured` | This node's management mode, instead of `network_intents.management.ip_assignment`. The schema 5 reader sets it from each node's management port. |

### Management network, time and the deployment admin

| Key | Needed by | Format | Used for |
| --- | --- | --- | --- |
| `network_intents.management.subnet` | P+P | CIDR, for example `192.0.2.0/24` | Prefix length of the static address. |
| `network_intents.management.gateway` | P+P | IPv4 | The one default gateway, on the management adapter. |
| `network_intents.management.dns_servers` | P+P | List of IPv4 | DNS on the management adapter. Learn: DNS servers can't be changed after deployment ([DNS server considerations](https://learn.microsoft.com/azure/azure-local/plan/cloud-deployment-network-considerations#dns-server-considerations)). |
| `network_intents.management.ip_assignment` | P+P, optional | `static` (default), `dhcp` or `preconfigured` | How each node's management address is set. `static`: the provisioning request carries `ip_address`, the mask, gateway and DNS for the port with `mac_address` (edge machine `siteDetails.deviceConfiguration.network.networkAdapters[]`, `ipAssignmentType: Manual`), but the OS install puts them on the first ready port. So the Device stage sets them on the port with `mac_address` in the maintenance environment before the claim (see [The Device stage](#the-device-stage)), the Network stage checks and moves them through Azure after the install (see [The Network stage](#the-network-stage)), and Prepare checks them in the OS. `dhcp`: the port stays on DHCP, so reserve `ip_address` for the MAC; Prepare checks the node has it. `preconfigured`: the port is already set up, and ZTP doesn't change it. In every mode Prepare turns DHCP and default gateways off on the other ports. |
| `network_intents.management.vlan_id` | Prov, optional | 0-4094, default 0 | VLAN of the management port in the provisioning request. 0 for an access port. |
| `network_intents.management.site_ip_range.start`, `.end` | Prov, optional | IPv4, inside `subnet`, start before end | With `ip_assignment: static`, the address range of the site's network setting (`Microsoft.Edge/configurations/networkConfigurations`, Manual). Default: the lowest to the highest `cluster_nodes[].ip_address`. Every node address must be inside it. See [The site's network setting](#the-sites-network-setting). |
| `network_intents.management.provisioning_network` | Prov, optional | `dhcp` (default) or `static` | How the maintenance environment gets the address it reaches Azure with, before the machine is claimed. `dhcp`: a DHCP server must answer on a port of the machine (on a machine with no DHCP on its management network, another port, for example a data port, carries it). `static`: the run warns and sets nothing. Learn documents only the Configurator app for a static address there, and whether the USB image can carry a preset address is an open research item. |
| `onprem.ntp_servers` | P+P, optional | List | Time source. Prepare sets it with `w32tm` and waits until the node syncs from one of them. |
| `credentials.local_admin_username` | P+P | Text; not `Administrator` or `Guest` | The deployment admin that Prepare creates in local Administrators. |
| `credentials.local_admin_password_secret` | P+P | `keyvault://<vault>/<secret>` | The deployment admin's password. The vault must be in the subscription named by `ztp.admin_secret.subscription_id`. Learn asks for at least 14 characters with lowercase, uppercase, a digit and a special character ([install the OS](https://learn.microsoft.com/azure/azure-local/deploy/deployment-install-os#prerequisites)). |

#### The site's network setting

The site configuration has one network setting for the machines it provisions. ZTP derives it from the management mode:

| `ip_assignment` | Site setting | `ipv4` |
| --- | --- | --- |
| `static` | `Manual` | `addressRange { startIp, endIp }` from `site_ip_range` (default: the lowest to the highest node address), `defaultGateway` and `dnsServers` from the management network, `subnetMask` from `subnet`, `vLanId` from `vlan_id` (0 when absent). |
| `dhcp` | `Automatic` | none |
| `preconfigured` | `Automatic` | none. ZTP doesn't manage the address, and the newly installed OS takes DHCP until whatever preconfigures the port does. |

Each edge machine also pins its own address on its management port (`networkAdapters`, by MAC); the site range is what the portal shows. The plan prints both, for example `Site network: Manual 192.0.2.11-192.0.2.12, gateway 192.0.2.1, mask 255.255.255.0, DNS 192.0.2.53, 192.0.2.54, VLAN 0`.

#### The Device stage

The maintenance environment runs the Configurator App's REST service, and the Device stage (`Set-ZtpDeviceConfiguration.ps1`, between Vouchers and Azure) uses it to put the static address on the port with `mac_address` before the claim, as the Configurator App would. It needs the node's `maintenance_address` and TCP 20001 from this server to it.

| | |
| --- | --- |
| Service | `https://<maintenance_address>:20001/BootstrapOobeService/<Operation>`: CoreWCF WebHttp, JSON, property names in PascalCase. |
| Sign-in | HTTP Basic as `edgeuser`, with the password in `ztp.maintenance_password_secret` when it's set (the Media stage builds it into each image), otherwise the maintenance environment's default `Password1`. |
| Certificate | Self-signed by the maintenance environment, with nothing to check it against, so these calls skip the certificate check. No other call in ZTP does. |

For each static node:

1. `GET GetNetworkAdapters` (**verified live**: HTTP 200, `{ "NetworkAdapters": [ { "MacAddress", "Name", "EnableDhcp", "IpAddress", "Gateway", "SubnetMask", "DnsAddressArray", "VlanId", "LogicalIndex", ... } ] }`, MACs as 12 lower-case hex digits). The adapter with `mac_address` is found whatever the separators and case; none stops the node and lists the MACs found. An adapter that already reports `EnableDhcp: false` with the address, mask, gateway, DNS and VLAN is left alone.
2. `POST SetArcBootstrapDeviceConfiguration` with `{ "HostName": <node name>, "Network": { "NetworkAdapters": [ { "MacAddress", "EnableDhcp": false, "IpAddress", "SubnetMask", "Gateway", "DnsAddressArray", "VlanId" } ] } }`. Another adapter that holds the address statically gets `{ "MacAddress", "EnableDhcp": true }` in the same list. **Unverified live**: the operation and the field names come from the service's data contract (`DeviceConfigurationRequest`, `NetworkConfiguration`, `NetworkAdapterConfiguration`), but no request has been sent to a machine yet, and `VlanId` is sent in the type `GetNetworkAdapters` reports.
3. `GET GetArcBootstrapDeviceConfigurationStatus` and `GET GetNetworkAdapters` until the adapter reports the static configuration, up to 30 minutes (the orchestrator's `-DeviceTimeoutMinutes`). **Unverified live**: the status response's shape; a `Status`, `State`, `ConfigurationStatus` or `DeploymentStatus` property that reads `Failed` stops the node. If the management port is the one the maintenance address is on, the service answers on the static address afterwards, and both are tried.

`dhcp` and `preconfigured` nodes are only reported. Each change goes to `<evidence_path>\device-changes.jsonl` (time, node, address, adapter, MAC, before, the request, phase `requested`, `applied`, `failed` or `timedOut`), and its progress to the event log with stage `Device`. The plan (without `-Execute`) reads the adapters and prints the request it would send. To run it again: `-From Device`. The service also has `ConfigureNetwork` and `ConfigureHostName`; their bodies are unverified, and ZTP doesn't use them.

The Network stage after the OS install stays as the second check: it reads the adapters through Azure and changes only what isn't right.

#### The Network stage

The OS install accepts the MAC in the edge machine's `networkAdapters` entry but doesn't use it: the static address lands on the first ready port, which can be a storage port (see [Static IP lands on the wrong NIC](troubleshooting.md#static-ip-lands-on-the-wrong-nic)). So after Ready, the Network stage (`Set-ZtpManagementAddress.ps1`) puts it on the right port through Azure's per-NIC API (`edgeMachines/<node>/networkAdapters`, api-version 2026-10-01). It needs no WinRM and no firewall change. For each node:

| Mode | What the Network stage does |
| --- | --- |
| `static` | Finds the adapter whose reported MAC is `mac_address` and stops if none does, listing the MACs it found. If another adapter reports `ip_address`, it sets that adapter to DHCP first and waits until the address is gone, so two ports never carry it. Then it sends `jobs/ApplyConfiguration` to the management adapter: static `ip_address`, the mask from `subnet`, `gateway`, `dns_servers`, `vlan_id`, interface up. An adapter that already reports all of that is left alone. Each job is followed until it succeeds or fails, up to 60 minutes (the orchestrator's `-NetworkTimeoutMinutes`), and then until the adapter reports the result; right after the OS install a job can wait queued with "Job is not yet triggered as other jobs are still running". |
| `dhcp`, `preconfigured` | Changes nothing. It shows what the management adapter reports, and warns when that isn't `ip_address`. |

Each change goes to `<evidence_path>\network-changes.jsonl` (time, node, adapter, MAC, action `release` or `apply`, before, after, phase `requested`, `applied`, `failed` or `timedOut`, job status), and its progress to the event log with stage `Network`. The plan (without `-Execute`) reads the adapters and prints what it would change. To run it again: `-From Network`.

```yaml
network_intents:
  management:
    subnet: 192.0.2.0/24
    gateway: 192.0.2.1
    dns_servers: [192.0.2.53, 192.0.2.54]
    ip_assignment: static
    vlan_id: 0
    site_ip_range: { start: 192.0.2.11, end: 192.0.2.12 }   # optional; this is the default for nodes .11 and .12
    provisioning_network: dhcp                              # optional; the default
```

### Hardware

| Key | Needed by | Format | Used for |
| --- | --- | --- | --- |
| `hardware.vendor` | P+P | Text, for example `Dell` | Picks `config/oem/<vendor>.json`: the SBE manifest URL, the driver folders inside the SBE, and the BMC log patterns. |
| `hardware.model` | Prov | Text, for example `AX-760` | SBE selection. Hyphens are removed, so `AX-760` becomes `AX760`. |
| `hardware.bios` | Prov, optional | Mapping: BIOS attribute name -> value, values quoted as strings | BIOS attributes the Boot stage sets on every node before the maintenance boot. See [BIOS settings](#bios-settings). |
| `cluster_nodes[].bios` | Prov, optional | Same | One node's own BIOS attributes, merged over `hardware.bios` (the node's value wins). |

#### BIOS settings

Some machines need a BIOS change before the maintenance environment works, and the file holds it, so nothing is set by hand. Two Dell examples:

```yaml
hardware:
  bios:
    Slot2: "Disabled"       # a Fibre Channel HBA in slot 2: the maintenance environment offered its SAN LUN as the install disk
    EmbNic1Nic2: "Enabled"  # the embedded LOMs shipped as DisabledOs, so the OS couldn't see the management ports
cluster_nodes:
  - name: node-02
    bios:
      Slot2: "Enabled"      # this node has no HBA there
```

Names are the attributes of the BMC's Redfish Bios resource (`GET /redfish/v1/Systems/System.Embedded.1/Bios` on an iDRAC), and they're case-sensitive. Quote every value: ZTP converts it to the type the BIOS reports for that attribute (a number or a boolean). The check refuses a value that isn't a string and a name with spaces.

In the Boot stage, before it mounts the image, ZTP does this for each node that has settings (`Set-ZtpBios.ps1`):

1. Reads the current values. An attribute the BIOS doesn't have stops the run before anything changes. If every value already matches, it moves on without a restart.
2. Sends only the values that differ: `PATCH /redfish/v1/Systems/System.Embedded.1/Bios/Settings` with `"@Redfish.SettingsApplyTime": { "ApplyTime": "OnReset" }`. A value already pending from an earlier run isn't sent again.
3. Powers the node on (`On`) if it's off, otherwise restarts it (`ForceRestart`), so the BIOS job runs.
4. Waits, up to 30 minutes, until the Bios resource reports every new value. Then it mounts the image and sets the one-time boot, so the BIOS reset can't use up the boot to the virtual USB.

Every change goes to `<evidence_path>\bios-changes.jsonl` (time, node, BMC, attribute, before, after, `requested` then `applied`), to the Boot stage's evidence, and to the event log as a `BiosChanged` event. The plan (without `-Execute`) lists the settings it would apply; run `Set-ZtpBios.ps1` with `-Credential` and without `-Execute` to see the current values and what would change.

### Azure

| Key | Needed by | Format | Used for |
| --- | --- | --- | --- |
| `azure_identity.azure_tenant_id` | P+P | GUID | Tenant of every Azure call. |
| `azure_resources.location` | Prov | Azure region | Region of the site configuration and edge machines, and of the resource group if the run creates it. In the preview only `eastus` works for the provisioning resources ([Learn](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#azure-prerequisites)). |
| `site.name` | Prov | Text | Display name of the `Microsoft.Edge` site. |
| `ztp.subscription_id` | P+P | GUID | Subscription of the site and edge machines. |
| `ztp.resource_group` | P+P | Text | Resource group of the site and edge machines. Created if missing. |
| `ztp.site_name` | Prov | Text | Resource name of the `Microsoft.Edge` site. Also names the ARM deployment `ztp-<site_name>`. |
| `ztp.time_zone` | Prov | Text, for example `UTC` | Site time zone. |
| `ztp.os_version` | Prov | `latest`, `latest-preview`, or a validated solution recipe version (`12.YYMM.x.y`) | The OS the machines install. It's also the solution version the SBE must be validated with; `latest` skips that check. Pin a version. `Get-ZtpOsImage.ps1` lists the catalog. See [Pin the OS version](operator-guide.md#pin-the-os-version). |
| `ztp.provisioning_iso` | Prov | `latest`, a train (`2610`), a build, or a Microsoft download URL | The maintenance ISO. `latest` takes the newest published general-availability train. |
| `ztp.azl_rp_object_id` | Prov, optional | GUID | Object ID of the Azure Local resource provider's service principal in your tenant. If you leave it out, the run looks it up, which needs directory read rights. A managed identity doesn't have those by default, so set it for pipelines. |
| `ztp.tags` | Prov, optional | Mapping | Tags on the site configuration and the edge machines. The resource group gets them only if the run creates it. Learn: a policy that *requires* tags isn't supported ([troubleshooting](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning#when-you-provision-new-machines-you-receive-an-internal-server-error)). |

To find the resource provider's object ID once with an account that can read the directory:

```powershell
(Get-AzADServicePrincipal -ApplicationId '1412d89f-b8a8-4111-b4fd-e82905cbd85d').Id
```

That application ID is what `Invoke-ZtpEnvironment.ps1` uses for the lookup.

### Secrets in Key Vault

| Key | Needed by | Format | Used for |
| --- | --- | --- | --- |
| `ztp.admin_secret.subscription_id` | P+P | GUID | Subscription of the vault. The BMC secret vault and the deployment admin vault are read in this subscription too. |
| `ztp.admin_secret.resource_group` | Prov | Text | Resource group of the vault. The template assigns roles on the vault there. |
| `ztp.admin_secret.vault` | P+P | Vault name | Vault that holds the provisioning administrator secret. |
| `ztp.admin_secret.name` | P+P | Secret name | The provisioning administrator password. **Create it before the run**; the environment-file path doesn't create it. Learn asks for at least 12 characters with lowercase, uppercase, a digit and a special character ([provision machines](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#step-3-provision-machines-from-azure)). |
| `ztp.admin_secret.username` | P+P | Text | Local administrator that the OS install creates. Prepare signs in as `<node>\<username>`. |
| `ztp.bmc_secret.vault` | Prov | Vault name | Vault that holds the BMC login. |
| `ztp.bmc_secret.username_name` | Prov | Secret name | Secret whose value is the BMC user name. Not needed with `username`. |
| `ztp.bmc_secret.username_vault` | Prov, optional | Vault name | Vault of `username_name`, when it isn't `ztp.bmc_secret.vault`. |
| `ztp.bmc_secret.username` | Prov, optional | Text | The BMC user name itself, instead of a secret. |
| `ztp.bmc_secret.password_name` | Prov | Secret name | Secret whose value is the BMC password. |
| `ztp.maintenance_password_secret` | Prov, optional | `keyvault://<vault>/<secret>` | The maintenance environment's `edgeuser` password. The Media stage writes its SHA-512 crypt hash into each image, and the Device stage signs in with it. Without it the image keeps the default, `Password1`, which is published and works for anyone who reaches TCP 20001 while the maintenance environment runs. The vault must be in the subscription named by `ztp.admin_secret.subscription_id`. |

### Media and share

| Key | Needed by | Format | Used for |
| --- | --- | --- | --- |
| `ztp.share_host` | Prov, one of the two | IPv4 | The management host's address **as the BMCs reach it**. The BMCs mount `//<share_host>/<share_name>/ztp-usb-<node>.img`. |
| `ztp.share_host_adapter` | Prov, one of the two | Adapter name | Instead of `share_host`: the name of the local network adapter whose IPv4 address the BMCs reach. Useful when that address changes, for example on a VPN. It wins over `share_host`. |
| `ztp.share_name` | Prov | Text, letters, digits and hyphens | Name of the SMB share for the images. |
| `ztp.node_preparation.sbe_bundle` | P+P | Folder path on the management host | Folder with the OEM's SBE: exactly one `SBE_*.zip`, its `SBE_*.xml`, and `SBE_Discovery_<oem>.xml`. See [Download the SBE](operator-guide.md#step-2-download-the-oem-sbe). |
| `ztp.node_preparation.allow_unvalidated_sbe` | Prov, optional | `true` or `false` (default `false`) | **Test only.** Use the SBE in `sbe_bundle` even though the OEM's manifest doesn't list it as validated with `ztp.os_version`, for example to test a new Azure Local build before the OEM publishes a matching SBE. The SBE's hash is still checked; only the solution-compatibility check is skipped. The run warns, and the handoff records `compatibilityChecked: false`. The OEM doesn't support the combination, and cluster Validate or Deploy may still refuse it. |

### Run data: media and evidence

A run downloads and writes a lot: the maintenance ISO, one USB image per node (about 4 GB each), the SBE's unpacked drivers, the ownership vouchers and the run state. It also leaves evidence: the event log that monitors follow, change logs, and with `-Execute` a transcript. None of it belongs in a git repository, so ZTP keeps it in two folders that the file names.

| Key | Needed by | Format | Used for |
| --- | --- | --- | --- |
| `ztp.media_path` | P+P, optional | Full path, outside any git working tree | Downloads and run data: `bootstrap\` (the ISO cache), `ztp-virtual-usb\` (the images), `vouchers\`, `sbe-drivers\` (Prepare's unpacked drivers) and `ztp-state\` (the state, handoff and Arc-name files). Default: `%ProgramData%\AzureLocalZtp\<ztp.site_name>\media`. `-MediaPath` overrides it. |
| `ztp.evidence_path` | P+P, optional | Full path, outside any git working tree | Evidence: `ztp-events.jsonl` (the event log Sonar and `Start-ZtpMonitor.ps1` follow), the BIOS change log, and `<run>.<time>.transcript.log` for each `-Execute` run. Default: `%ProgramData%\AzureLocalZtp\<ztp.site_name>\evidence`. `-EvidencePath` overrides it. |

The run creates both folders when they're missing. It refuses a folder inside a git working tree (any folder with a `.git` above it), whether it came from the file, from the parameter or from the default, before it writes anything. Keep the folders where they last: resuming a run (`-From`) reads the state and vouchers there.

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
| Provisioning network | `LAN`. IP assignment from the management mode: `Manual` with the site range for `static`, `Automatic` otherwise (see [The site's network setting](#the-sites-network-setting)). |
| Provisioning time | NTP `Automatic` |
| Connectivity | `Public` (no proxy) |
| Role assignments | Site settings, Key Vault configuration, edge machine delegations and the Azure Local resource provider role are all on. |
| BMC handling | `RfsWriteAttribute` on, `SkipCertificateCheck` on (BMCs with self-signed certificates). |
| Timeouts | Voucher wait 120 min, bootstrap 120 min (voucher 90 min), Device 30 min, Ready 180 min, Network 60 min per adapter job, poll 60 s. Prepare: Ready 240 min, sign-in 30 min. |
| Preview trains | Not considered for `provisioning_iso: latest`. |
| `ProvisionOs` retry | On: one automatic resubmit per node per run. |
