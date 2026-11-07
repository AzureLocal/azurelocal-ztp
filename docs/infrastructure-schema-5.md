# Reading the master infrastructure.yml (schema 5)

> How `Invoke-ZtpEnvironment.ps1` reads the master `infrastructure.yml`, the one environment file every Azure Local tool reads, and where each of its keys goes.

The master file and its schema live in [azurelocal-toolkit](https://github.com/AzureLocal/azurelocal-toolkit/tree/main/config/infrastructure): `infrastructure.schema.json`, the examples (`examples/lom-management-ztp.yml` is a simplified-provisioning example with every port listed) and `README.md`, which describes every key. ZTP reads schema 5.x. Schema 5.2 adds the keys ZTP needs for each machine's ports, BIOS and run folders; schema 5.3 adds `bios_during_provisioning`, `networking.management.static_method` and `provisioning_dhcp_range`, `nodes[].maintenance_address`, `provisioning.simplified.maintenance_password` and `_metadata.scope`.

## The two templates

The toolkit has two templates. Start from the one that matches what you do after ZTP:

- **ZTP only**, with no automation after it: the [ZTP-only template](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/config/infrastructure/infrastructure.ztp.example.yml) (schema 5.3, `_metadata.scope: ztp`). It holds only what ZTP reads, and the toolkit's validator requires only those keys. The toolkit is adding it; it isn't published yet.
- **ZTP, then OS configuration and deployment**: the [full template](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/config/infrastructure/infrastructure.example.yml). ZTP reads its part and ignores the rest.

ZTP accepts `_metadata.scope` and ignores every key it doesn't read. To grow a ZTP-only file into the full one, add the sections and set `_metadata.scope: full` (or remove it).

Pass the file the same way as before:

```powershell
./scripts/simplified-provisioning/Invoke-ZtpEnvironment.ps1 -InfrastructureFile D:\envs\site-01\infrastructure.yml
```

The older [environment-file layout](environment-file.md) still works and is deprecated. [Prerequisites](prerequisites.md#values-you-need) lists every value ZTP reads, with an example and where to get it.

## How the file is read

1. **The format.** A file with `_metadata.schema_version` (or `schema_version` at the top) is schema 5. Anything else is the older layout, read as before.
2. **The check.** When an azurelocal-toolkit clone sits next to this repository (`..\azurelocal-toolkit`), or `$env:AZL_TOOLKIT_ROOT` names one, ZTP runs its `Test-AzlInfrastructure`: the schema and the toolkit's rules. Its errors stop the run, with their rule IDs; its warnings are shown. Without the toolkit, only ZTP's own checks run. Either way, ZTP then checks what it needs itself (`Test-ZtpInfrastructureV5`): `_metadata.schema_version` is 5.x, `scenario.os_install: simplified`, exactly one management port per node, every vault a `keyvault://` reference names is in `key_vaults`, every secret is in the provisioning admin vault's subscription, and one BMC login (`hardware.bmc`) for every node.
3. **The mapping.** The file is mapped onto the keys the scripts read (`ConvertFrom-ZtpInfrastructureV5`, the table below), and ZTP's key check runs on the result. Every problem is named in schema 5 paths (`ConvertTo-ZtpSchema5Message`), for example `site.time_zone is required` or `nodes[0] (node-01) management port mac_address is required`, and all of them at once.

## Where each key goes

| ZTP reads | From schema 5 |
| --- | --- |
| Node name, edge machine name | `nodes[].name` |
| Management address, MAC and port name | The node's management port: the `nodes[].network_adapters` entry with role `management` and an `ip_assignment` other than `none` (its `ip_address`, `mac_address`, `name`). Without `network_adapters`: `nodes[].management.ip_address`, `mac_address`, `adapter_name`. |
| Management mode, per node | That port's `ip_assignment`: `static` is static; `dhcp_reservation` and `dhcp` are ZTP's `dhcp` (the port keeps DHCP, and ZTP expects `ip_address` on it); `preconfigured` is preconfigured. Without `network_adapters`: `networking.management.ip_assignment` (default `static`). |
| Management VLAN | `networking.management.vlan_id`, the VLAN the host tags (0 for an access port). Without it, the management port's `vlan_id` (0 when its `vlan_mode` is `access`). |
| Serial number, BMC address | `nodes[].serial_number`, `nodes[].bmc.ip_address` |
| Arc machine name | `nodes[].arc_machine_name`, else `nodes[].arc_resource_name`, default the node name. The service currently overwrites it at claim time (open research item); the handoff records the name Azure used. |
| Maintenance address (the Device stage) | `nodes[].maintenance_address`, else the `ip_address` of the node's port with role `provisioning` (and not `management`), for example a `dhcp_reservation` port. Without either, the Device stage scans `networking.management.provisioning_dhcp_range` (default: the management subnet) on TCP 20001 and finds the node by its management MAC. |
| BIOS settings (final) | `hardware.bios`, with `nodes[].bios` merged over it. Boot applies them; Restore sets any temporary key back to them. |
| BIOS settings for the install only | `hardware.bios_during_provisioning`, with `nodes[].bios_during_provisioning` merged over it. Boot applies them over the final ones (they win); Restore sets each back to the final value, or to the value Boot saved before changing it. |
| Who sets a static management address | `networking.management.static_method`: `device` (default; the Device stage, by MAC, with the site `Automatic`) or `site` (the OS install, from the site's `Manual` setting) |
| Where the Device stage scans | `networking.management.provisioning_dhcp_range` (`start`, `end`; at most 4096 addresses) |
| Subnet, gateway, DNS servers | `networking.management.subnet`, `gateway`, `dns_servers` |
| Site range (only with `static_method: site`) | `networking.management.site_ip_range` |
| How the maintenance environment reaches Azure | `networking.management.provisioning_network` (the ports with role `provisioning` carry it) |
| Tenant, region | `azure.tenant_id`, `azure.location` |
| Site display name, time zone | `site.name`, `site.time_zone` |
| Subscription and resource group of the site and edge machines | `provisioning.simplified.subscription_id` and `resource_group`, else `azure.subscription_id` and `resource_group` |
| Site resource name, maintenance ISO, OS version | `provisioning.simplified.site_name`, `maintenance_iso`, `provisioning.os_version` |
| SMB share | `provisioning.simplified.media_share.name`, `host` or `host_adapter` |
| Run folders | `provisioning.simplified.media_path`, `evidence_path` |
| Provisioning administrator | `provisioning.simplified.admin.username`; the vault and secret from `admin.password` (`keyvault://<vault>/<secret>`), and that vault's `subscription_id` and `resource_group` from `key_vaults[]` |
| The maintenance environment's `edgeuser` password | `provisioning.simplified.maintenance_password` (`keyvault://<vault>/<secret>`, in `key_vaults`, in the provisioning admin vault's subscription). Schema 5.3. Without it: `Password1`. |
| BMC login | `hardware.bmc.username` (a `keyvault://` reference or the name itself) and `hardware.bmc.password` (a `keyvault://` reference). Required. |
| Vendor | `hardware.vendor` (picks `config/oem/<vendor>.json`, the BMC layer) |
| Resource provider object ID | `azure.hci_resource_provider_object_id` |
| Tags | `tags` |

Limits of the mapping, which the check names: ZTP reads every secret in the provisioning administrator vault's subscription, and uses one BMC login for every node (`hardware.bmc`; a node's own `bmc` login must be the same).

### Not read by ZTP

These keys belong to OS configuration and deployment. ZTP doesn't map them, doesn't require them, and a file can keep them:

| Key | Who reads it |
| --- | --- |
| `hardware.sbe` | OS configuration and deployment. ZTP accepts it and prints `Note: hardware.sbe ignored: SBE belongs to OS configuration.` The OS install discovers its own SBE (the `ProvisionOs` job's `SBEDiscoveryDownload` step). |
| `identity.local_admin` | The deployment admin, created in OS configuration. |
| `networking.ntp_servers` | Time on the host, set in OS configuration. The site's time setting is `Automatic`. |
| The other ports in `nodes[].network_adapters` (no role `management` or `provisioning`) | OS configuration (DHCP off, unused adapters disabled). The provisioned OS names its ports `Port0` to `Port6`, so find them by MAC there. |
| `hardware.model`, `site.code`, `nodes[].rack_position` | Not used by any stage. |

## What ZTP does with the ports

**The Device stage.** Before the claim, `Set-ZtpDeviceConfiguration.ps1` sets a static management address on the port named by its MAC in the maintenance environment, through the Configurator App's REST service on the maintenance address (TCP 20001). Without a maintenance address it finds the node by scanning `provisioning_dhcp_range` for the service and matching the MAC. See [The Device stage](environment-file.md#the-device-stage).

**The claim.** With `static_method: device` (the default), the edge machine's request carries no `networkAdapters` entry: the site is `Automatic`, and the address the Device stage set is the only static the node gets. With `static_method: site`, a static management port gets one entry, keyed by the port's MAC: `ipAssignmentType: Manual`, the address, mask, gateway, DNS servers and VLAN. The OS install accepts that MAC but doesn't use it: the address goes to the first ready port, which can be a storage port (see [Static IP lands on the wrong NIC](troubleshooting.md#static-ip-lands-on-the-wrong-nic)). For `dhcp`, `dhcp_reservation` and `preconfigured` there's no entry either way.

**The Network stage.** After Ready, `Set-ZtpManagementAddress.ps1` checks each static management address on the port named by its MAC through Azure (`edgeMachines/<node>/networkAdapters` and `jobs/ApplyConfiguration`, api-version 2026-10-01), and moves it there if it isn't. It matches the management port's `mac_address` against each adapter's reported MAC, whatever the separators and case, and stops when none matches. If another port reports the node's address, that port goes to DHCP first; then the management port gets the address, the mask from `networking.management.subnet`, the gateway, the DNS servers and the VLAN. A port already reporting all of that is left alone. For `dhcp`, `dhcp_reservation` and `preconfigured` it changes nothing and shows what the port reports. Changes go to `<evidence_path>\network-changes.jsonl`. See [The Network stage](environment-file.md#the-network-stage).

**The site's network setting.** `Automatic` with `static_method: device` (the default). With `static_method: site`, `Manual` when any management address is static, over `site_ip_range` (default: the lowest to the highest static address); `Automatic` otherwise. See [The site's network setting](environment-file.md#the-sites-network-setting).

**The maintenance environment.** It reaches Azure through a port with role `provisioning`, before the machine is claimed, and takes DHCP there (`provisioning_network: dhcp`). On a machine whose management network has no DHCP, mark data ports that do get DHCP as `provisioning`, as `lom-management-ztp.yml` does. A static address in the maintenance environment (`provisioning_network: static`) is a warning: Learn documents only the Configurator app for it, and whether the USB image can carry a preset address is an open research item.

**The other ports.** ZTP doesn't touch them. Turning DHCP off on them and disabling unused adapters is OS configuration ([Phase 03 OS Configuration](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/)).

## Open items

- **The Arc machine name.** ZTP sends `arcMachineResourceId` named after `arc_machine_name`, but in live runs (2026-11) the service overwrote it at claim time: the Arc machines came out as `ROE1-<id>` and then `<device-id>-1`. The handoff reads the name actually used from the edge machine after Ready.
- **A static address in the maintenance environment.** Unresearched beyond the Configurator app; see above.
