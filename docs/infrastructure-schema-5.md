# Reading the master infrastructure.yml (schema 5)

> How `Invoke-ZtpEnvironment.ps1` reads the master `infrastructure.yml`, the one infrastructure file every Azure Local tool reads and ZTP's only input, and where each of its keys goes.

The master file and its schema live in [azurelocal-toolkit](https://github.com/AzureLocal/azurelocal-toolkit/tree/main/config/variables): `schema/infrastructure.schema.json`, the templates in `examples/`, and `docs/VARIABLES.md`, which describes every key. ZTP reads schema 5.x and nothing else. Schema 5.2 adds the keys ZTP needs for each machine's ports, BIOS and run folders; schema 5.3 adds `bios_during_provisioning`, `networking.management.static_method` and `provisioning_dhcp_range`, `nodes[].maintenance_address`, `provisioning.simplified.maintenance_password` and `_metadata.scope`; schema 5.4 puts every other ZTP setting in the master file (see [Every setting is a key](#every-setting-is-a-key-schema-54)).

## The two templates

The toolkit has two templates. Start from the one that matches what you do after ZTP:

- **ZTP only**, with no automation after it: the [ZTP-only template](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/config/variables/examples/infrastructure.ztp.example.yml) (`_metadata.scope: ztp`). It holds only what ZTP reads, and the toolkit's validator requires only those keys.
- **ZTP, then OS configuration and deployment**: the [full template](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/config/variables/examples/infrastructure.example.yml). ZTP reads its part and ignores the rest.

ZTP accepts `_metadata.scope` and ignores every key it doesn't read. To grow a ZTP-only file into the full one, add the sections and set `_metadata.scope: full` (or remove it).

Pass the file with `-InfrastructureFile` (there is no default path):

```powershell
./scripts/simplified-provisioning/Invoke-ZtpEnvironment.ps1 -InfrastructureFile D:\envs\iic-azl-01\infrastructure.yml
```

The [infrastructure file reference](environment-file.md) describes every key ZTP reads. [Prerequisites](prerequisites.md#values-you-need) lists every value, with an example and where to get it.

## How the file is read

1. **Schema 5 only.** A file without `_metadata.schema_version` 5.x (ZTP's retired environment-file layout, another schema major, anything else) stops the run with exit code 2, naming the file and pointing at the toolkit's `config/variables/examples/infrastructure.example.yml`.
2. **The check.** When the toolkit is found (`$env:AZL_TOOLKIT_ROOT`, else an azurelocal-toolkit clone next to this repository), ZTP runs its `Test-AzlInfrastructure`: the schema and the toolkit's rules. Its errors stop the run, with their rule IDs; its warnings are shown. Without the toolkit, only ZTP's own checks run. Either way, ZTP then checks what it needs itself (`Test-ZtpInfrastructureV5`): `scenario.os_install: simplified`, exactly one management port per node, every vault a `keyvault://` reference names is in `key_vaults`, every `keyvault://` secret is in the provisioning admin vault's subscription, the provisioning admin password is a `keyvault://` reference, and one BMC login (`hardware.bmc`) for every node.
3. **The mapping.** The file is mapped onto the internal keys the scripts read (`ConvertFrom-ZtpInfrastructureV5`, the table below), and ZTP's key check runs on the result. Every problem is named in schema 5 paths (`ConvertTo-ZtpSchema5Message`), for example `site.time_zone is required` or `nodes[0] (iic-azl-n01) management port mac_address is required`, and all of them at once.
4. **The secrets.** With `-Execute`, the BMC login and the maintenance password are read through the toolkit's one secret resolver (`scripts/common/secrets/AzlSecret.psm1`: `keyvault://`, `env://`, `file://`, `command://`). Without the toolkit the run stops with exit code 2 before it writes anything. See [Secrets](environment-file.md#secrets).

## Where each key goes

| ZTP reads | From schema 5 |
| --- | --- |
| Node name, edge machine name | `nodes[].name` |
| Management address, MAC and port name | The node's management port: the `nodes[].network_adapters` entry with role `management` and an `ip_assignment` other than `none` (its `ip_address`, `mac_address`, `name`). Without `network_adapters`: `nodes[].management.ip_address`, `mac_address`, `adapter_name`. |
| Management mode, per node | That port's `ip_assignment`, kept as it is: `dhcp_reservation` (Mode A, Reserved: the port keeps DHCP, `ip_address` optional), `static` (Mode B or C), `dhcp` (no reservation, warned), `preconfigured`. Static is Mode B (Static with DHCP) when `networking.management.provisioning_network` is `dhcp` and the management port also has role `provisioning`; otherwise Mode C (Static without management DHCP). See [Management address modes](prerequisites.md#management-address-modes). Without `network_adapters`: `networking.management.ip_assignment` (default `static`). |
| The node's ports, for the handoff | Every `nodes[].network_adapters` entry (`name`, `mac_address`, `roles`, `ip_assignment`, `ip_address`) goes to the node list, so the handoff can match each port Azure reports by MAC. ZTP doesn't configure them. |
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
| Outbound path and proxy | `scenario.outbound_path`: `direct` (default; the site connectivity is `Public`) or `proxy` (the site connectivity is `Proxy`, and the Device stage sends `networking.outbound.proxy.url` and `.bypass` to each maintenance environment, as the Configurator App's proxy URL and bypass list). `arc_gateway`, `proxy_arc_gateway` and `private_path` stop the run: Microsoft doesn't support Arc gateway with simplified machine provisioning in the preview. Bypass list rules from Learn: each machine's address and NetBIOS name, the cluster's, the infrastructure addresses; `localhost`, not `<local>`; a wildcard such as `192.0.2.*`, not CIDR. |
| Tenant, region | `azure.tenant_id`, `azure.location` |
| Site display name, time zone | `site.name`, `site.time_zone` |
| Subscription and resource group of the site and edge machines | `provisioning.simplified.subscription_id` and `resource_group`, else `azure.subscription_id` and `resource_group` |
| Site resource name, maintenance ISO, OS version | `provisioning.simplified.site_name`, `maintenance_iso`, `provisioning.os_version` |
| SMB share | `provisioning.simplified.media_share.name`, `host` or `host_adapter` |
| Run folders | `provisioning.simplified.media_path`, `evidence_path` |
| Provisioning administrator | `provisioning.simplified.admin.username`; the vault and secret from `admin.password` (`keyvault://<vault>/<secret>`), and that vault's `subscription_id` and `resource_group` from `key_vaults[]` |
| The maintenance environment's `edgeuser` password | `provisioning.simplified.maintenance_password`: a secret reference of any provider (a `keyvault://` vault in `key_vaults`, in the provisioning admin vault's subscription). Schema 5.3. Without it: `Password1`. |
| BMC login | `hardware.bmc.username` (a secret reference or the name itself) and `hardware.bmc.password` (a secret reference of any provider). Required. |
| Vendor | `hardware.vendor` (picks `config/oem/<vendor>.json`, the BMC layer) |
| Resource provider object ID | `azure.hci_resource_provider_object_id` |
| Tags | `tags` |
| BIOS actions derived from the inventory (5.4) | `nodes[].san.hbas[].slot` and `type`, `nodes[].network_adapters[].slot`, `provisioning.simplified.isolate_san_adapters`, `enable_embedded_nics`. See [Hardware-aware BIOS actions](#hardware-aware-bios-actions-schema-54). |
| Azure site choices (5.4) | `provisioning.simplified.create_resource_group`, `configuration_name`, `managed_resource_group_name`, `apply_site_settings`, `use_key_vault_configuration`, `assign_provisioning_roles`, `assign_hci_rp_role`, `network_kind`, `ntp`, `site_mode`, `deployment_name` |
| Stage budgets, retries, USB image, Configurator service (5.4) | `provisioning.simplified.timeouts.*`, `retry_provision_os`, `skip_azure_check`, `include_preview`, `max_train`, `usb_image`, `maintenance_environment`, `media_share.account_name`, `media_share.keep` |
| BMC behaviour (5.4) | `hardware.bmc.rfs_write_attribute` (default: true for Dell, false for the other vendors), `hardware.bmc.verify_certificate` (default false) |

Limits of the mapping, which the check names: every `keyvault://` secret is in the provisioning administrator vault's subscription, the provisioning administrator password is a `keyvault://` reference (Azure reads it from the vault), and one BMC login serves every node (`hardware.bmc`; a node's own `bmc` login must be the same).

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

**The Device stage.** Before the claim, `Set-ZtpDeviceConfiguration.ps1` sets a static management address on the port named by its MAC in the maintenance environment, through the Configurator App's REST service on the maintenance address (TCP 20001). Without a maintenance address it finds the node by scanning `provisioning_dhcp_range` for the service and matching the MAC. See [The Device stage](environment-file.md#the-device-stage) and [Appendix B](appendix/configurator-app-api.md#how-ztp-uses-this-service).

**The claim.** With `static_method: device` (the default), the edge machine's request carries no `networkAdapters` entry: the site is `Automatic`, and the address the Device stage set is the only static the node gets. With `static_method: site`, a static management port gets one entry, keyed by the port's MAC: `ipAssignmentType: Manual`, the address, mask, gateway, DNS servers and VLAN. The OS install accepts that MAC but doesn't use it: the address goes to the first ready port, which can be a storage port (see [Static IP lands on the wrong NIC](troubleshooting.md#static-ip-lands-on-the-wrong-nic)). For `dhcp`, `dhcp_reservation` and `preconfigured` there's no entry either way.

**The Network stage.** After Ready, `Set-ZtpManagementAddress.ps1` verifies each management address on the port named by its MAC, through Azure's per-NIC report (`edgeMachines/<node>/networkAdapters`, api-version 2026-10-01). It matches the management port's `mac_address` against each adapter's reported MAC, whatever the separators and case, and stops when none matches. It changes nothing: a static address the OS install reset to DHCP is recorded as left to OS configuration, which sets it by MAC. `-ApplyThroughAzure` (opt-in, unreliable: the job never started on two live runs) moves it through `jobs/ApplyConfiguration` instead. See [The Network stage](environment-file.md#the-network-stage).

**The site's network setting.** `Automatic` with `static_method: device` (the default). With `static_method: site`, `Manual` when any management address is static, over `site_ip_range` (default: the lowest to the highest static address); `Automatic` otherwise. See [The site's network setting](environment-file.md#the-sites-network-setting).

**The maintenance environment.** It reaches Azure through a port with role `provisioning`, before the machine is claimed, and takes DHCP there (`provisioning_network: dhcp`). On a machine whose management network has no DHCP, mark data ports that do get DHCP as `provisioning`, as `lom-management-ztp.yml` does. A static address in the maintenance environment (`provisioning_network: static`) is a warning: Learn documents only the Configurator app for it, and whether the USB image can carry a preset address is an open research item.

**The other ports.** ZTP doesn't touch them. Turning DHCP off on them and disabling unused adapters is OS configuration ([Phase 03 OS Configuration](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/)).

## Hardware-aware BIOS actions (schema 5.4)

`hardware.bios` and `hardware.bios_during_provisioning` are raw vendor attribute names (`Slot2: Disabled`); only someone who knows Dell's names can fill them in. From schema 5.4 ZTP derives the two actions that need them from the inventory, and the raw maps stay as explicit overrides.

| The file says | ZTP does | Switch (default) |
| --- | --- | --- |
| `nodes[].san.hbas[].slot: "Slot 2"` | Turns that PCIe slot off in the BIOS for the install (so the maintenance environment can't install onto a SAN LUN). The Restore stage puts it back to the value Boot found; if Boot found it already disabled (a crashed earlier run left it), to the vendor's enabled value. | `provisioning.simplified.isolate_san_adapters` (true when THIS node lists `san.hbas`, else false) |
| A `management` or `provisioning` port with `slot: Embedded` | Makes sure the embedded NICs are enabled, and leaves them so (Dell ships them as `DisabledOs`). | `provisioning.simplified.enable_embedded_nics` (true) |

The slot label to attribute mapping is data, in `config/oem/<vendor>.json`, section `bios`: `slot_attribute` (`Slot{n}`), `disabled`, `enabled`, `embedded_nic_attribute`, `embedded_enabled`. Only Dell has one (`verified_models`: AX-760; on another model the plan prints a warning to confirm the attribute, and does not block). For a vendor without it an HBA must name its own attribute, `nodes[].san.hbas[].bios_attribute` (with optional `bios_disabled_value` and `bios_enabled_value`); otherwise ZTP stops. An unrelated raw key in `bios_during_provisioning` does not excuse the missing mapping, and ZTP never guesses a name. To add a vendor, add its `bios` section.

Restore target: ZTP does not assume the original value was the vendor's "enabled". Boot saves each attribute's value before it changes anything, and Restore puts that back (`BootDriverDisabled` stays `BootDriverDisabled`). The one exception is a slot Boot found already at the isolating value: it goes back to the enabled value. If the saved value is lost, Restore stops and asks for `hardware.bios.<attribute>`. An explicit `hardware.bios` value wins. The handoff records `biosRestoreComplete` and `biosNotRestored` per node, so an unfinished restore is visible.

Precedence: an explicit key (in `hardware.bios`, `nodes[].bios` or the `bios_during_provisioning` twins) always wins over a derived one for the same attribute and phase; two derivations that target one attribute with different values are a problem. The plan output prints each decision with its reason:

```
PLAN: node-01 BIOS Slot2 Disabled for the install because nodes[0].san.hbas[0] is in Slot 2 (the Restore stage sets it back to Enabled)
PLAN: node-01 BIOS EmbNic1Nic2 Enabled because the management port 'Embedded NIC 1' of nodes[0] is in slot Embedded (the OS can't see disabled embedded NICs)
```

Everything that can be wrong is found before ZTP touches a machine: a slot label that is not `Slot <n>`, a slot that also holds a network port (the port's label is read loosely, so `Slot 2 Port 1` or `PCIe Slot 2` count), a vendor with no mapping and no `bios_attribute`, two derivations on one attribute. The Boot stage then reads every node's BIOS and the BMC's attribute registry first and stops before it changes any node, if an attribute is missing (saying why ZTP looked for it) or the registry does not allow the value (attribute, node, value, the allowed ones). If the registry cannot be read it warns and continues; whether the attribute exists is always checked. Switches are read strictly: a boolean, or the strings `true` and `false` in any case; `0` or `yes` is a problem naming the key.

## Every setting is a key (schema 5.4)

The master file holds every setting ZTP reads; ZTP keeps no key of its own. Each new key has the value ZTP used before it existed as its default, so a file without them behaves as it always did. [`variables-audit.md`](variables-audit.md) lists every action, threshold and literal in the stages with the key that controls it, and the few that stay fixed with the reason.

## Open items

- **The Arc machine name.** ZTP sends `arcMachineResourceId` named after `arc_machine_name`, but in live runs (2026-11) the service overwrote it at claim time: the Arc machines came out as `ROE1-<id>` and then `<device-id>-1`. The handoff reads the name actually used from the edge machine after Ready.
- **A static address in the maintenance environment.** Unresearched beyond the Configurator app; see above.
