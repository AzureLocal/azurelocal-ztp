# Reading the master infrastructure.yml (schema 5)

> How `Invoke-ZtpEnvironment.ps1` and `Initialize-ZtpNode.ps1` read the master `infrastructure.yml`, the one environment file every Azure Local tool reads, and where each of its keys goes.

The master file and its schema live in [azurelocal-toolkit](https://github.com/AzureLocal/azurelocal-toolkit/tree/main/config/infrastructure): `infrastructure.schema.json`, the examples (`examples/lom-management-ztp.yml` is a simplified-provisioning example with every port listed) and `README.md`, which describes every key. ZTP reads schema 5.x; schema 5.2 adds the keys ZTP needs to set up each machine's ports, BIOS and run folders.

Pass the file the same way as before:

```powershell
./scripts/simplified-provisioning/Invoke-ZtpEnvironment.ps1 -InfrastructureFile D:\envs\site-01\infrastructure.yml
```

The older [environment-file layout](environment-file.md) still works and is deprecated.

## How the file is read

1. **The format.** A file with `_metadata.schema_version` (or `schema_version` at the top) is schema 5. Anything else is the older layout, read as before.
2. **The check.** When an azurelocal-toolkit clone sits next to this repository (`..\azurelocal-toolkit`), or `$env:AZL_TOOLKIT_ROOT` names one, ZTP runs its `Test-AzlInfrastructure`: the schema and the rules AZL-000 to AZL-025. Its errors stop the run, with their rule IDs; its warnings are shown. Without the toolkit, only ZTP's own checks run. Either way, ZTP then checks what it needs itself: `scenario.os_install: simplified`, one management port per node, the vaults in `key_vaults`, and one BMC login.
3. **The mapping.** The file is mapped onto the keys the scripts read (the table below), and ZTP's key check runs on the result. Every problem is named in schema 5 paths, for example `site.time_zone is required` or `nodes[0] (node-01) management port mac_address is required`, and all of them at once.

## Where each key goes

| ZTP reads | From schema 5 |
| --- | --- |
| Node name, edge machine name | `nodes[].name` |
| Management address, MAC and port name | The node's management port: the `nodes[].network_adapters` entry with role `management` and an `ip_assignment` other than `none` (its `ip_address`, `mac_address`, `name`). Without `network_adapters`: `nodes[].management.ip_address`, `mac_address`, `adapter_name`. |
| Management mode, per node | That port's `ip_assignment`: `static` is static; `dhcp_reservation` and `dhcp` are ZTP's `dhcp` (the port keeps DHCP, and Prepare expects `ip_address`); `preconfigured` is preconfigured. Without `network_adapters`: `networking.management.ip_assignment`. |
| Management VLAN | `networking.management.vlan_id`, the VLAN the host tags (0 for an access port). |
| Serial number, BMC address | `nodes[].serial_number`, `nodes[].bmc.ip_address` |
| Arc machine name | `nodes[].arc_machine_name`, default the node name. The service currently overwrites it at claim time (open research item). |
| BIOS settings | `hardware.bios`, with `nodes[].bios` merged over it |
| The other ports | `nodes[].network_adapters`: Prepare leaves DHCP on a port without role `management` only when its `ip_assignment` is `dhcp` or `dhcp_reservation`. |
| Subnet, gateway, DNS servers | `networking.management.subnet`, `gateway`, `dns_servers` |
| Site range | `networking.management.site_ip_range` |
| How the maintenance environment reaches Azure | `networking.management.provisioning_network` (the ports with role `provisioning` carry it) |
| Time servers | `networking.ntp_servers` |
| Tenant, region | `azure.tenant_id`, `azure.location` |
| Site display name, time zone | `site.name`, `site.time_zone` |
| Subscription and resource group of the site and edge machines | `provisioning.simplified.subscription_id` and `resource_group`, else `azure.subscription_id` and `resource_group` |
| Site resource name, maintenance ISO, OS version | `provisioning.simplified.site_name`, `maintenance_iso`, `provisioning.os_version` |
| SMB share | `provisioning.simplified.media_share.name`, `host` or `host_adapter` |
| Run folders | `provisioning.simplified.media_path`, `evidence_path` |
| Provisioning administrator | `provisioning.simplified.admin.username`; the vault and secret from `admin.password` (`keyvault://<vault>/<secret>`), and that vault's `subscription_id` and `resource_group` from `key_vaults[]` |
| BMC login | `hardware.bmc.username` (a `keyvault://` reference or the name itself) and `hardware.bmc.password` |
| Deployment admin | `identity.local_admin.username`, `password` |
| Vendor, model, SBE | `hardware.vendor`, `model`, `sbe.bundle_path`, `sbe.allow_unvalidated` |
| Resource provider object ID | `azure.hci_resource_provider_object_id` |
| Tags | `tags` |

Limits of the mapping, which the check names: ZTP reads every secret in the provisioning administrator vault's subscription, and uses one BMC login for every node (`hardware.bmc`; a node's own `bmc` login must be the same).

## What ZTP does with the ports

**The OS-install request.** For a static management port, each edge machine's request carries one `networkAdapters` entry, keyed by the port's MAC: `ipAssignmentType: Manual`, the address, mask, gateway, DNS servers and VLAN. For `dhcp`, `dhcp_reservation` and `preconfigured` there's no entry: Automatic is what the service applies to every port without one, so an Automatic entry would change nothing.

**The site's network setting.** `Manual` when any management address is static, over `site_ip_range` (default: the lowest to the highest static address); `Automatic` otherwise. See [The site's network setting](environment-file.md#the-sites-network-setting).

**The maintenance environment.** It reaches Azure through a port with role `provisioning`, before the machine is claimed, and takes DHCP there (`provisioning_network: dhcp`). On a machine whose management network has no DHCP, mark data ports that do get DHCP as `provisioning`, as `lom-management-ztp.yml` does. A static address in the maintenance environment (`provisioning_network: static`) is a warning: Learn documents only the Configurator app for it, and whether the USB image can carry a preset address is an open research item.

**Prepare.** It finds the management port by its MAC and applies its mode as before (static: sets the address if it's missing; dhcp: checks the node holds `ip_address`; preconfigured: leaves it). On every other port it turns DHCP off and removes routable addresses and default gateways, so the management port holds the only default gateway, which deployment validation requires. The exception: a port without role `management` that the file marks `dhcp` or `dhcp_reservation` keeps DHCP; the plan shows it as `DHCP kept on <port> (dhcp in the file)`. If its DHCP server hands out a gateway, the node has two and Prepare's last check fails, as Validate would.

## Open items

- **The Arc machine name.** ZTP sends `arcMachineResourceId` named after `arc_machine_name`, but in live runs (2026-11) the service overwrote it at claim time: the Arc machines came out as `ROE1-<id>` and then `<device-id>-1`. The handoff reads the name actually used from the edge machine after Ready.
- **A static address in the maintenance environment.** Unresearched beyond the Configurator app; see above.
