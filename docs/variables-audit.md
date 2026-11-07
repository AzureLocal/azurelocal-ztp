# Variables audit: every action, threshold and literal in ZTP

> Owner's requirement (2026-11-07): with ZTP every action taken is backed by a variable, the environment file copes with servers that have several ports on different adapter types, and everything in the ZTP environment file is a key of the master `infrastructure.yml` schema in azurelocal-toolkit. One file for every tool; no key that only ZTP knows.

This page walks every stage and script in `scripts/simplified-provisioning/` (Resolve, Media, Boot, Bootstrap, Vouchers, Device, Azure, Ready, Network, Restore, Handoff, the orchestrator `Invoke-ZtpProvisioning.ps1`, `Invoke-ZtpEnvironment.ps1`, `ZtpEnvironment.Common.ps1` and the Bicep) and lists what changes behaviour. Paths are schema 5.4 paths of the master file; the environment-file key is what the schema 5 reader (`ConvertFrom-ZtpInfrastructureV5`) hands to the scripts, which is also the key of the older ZTP layout. Placeholder names and documentation address ranges only.

**Status words.** `controlled`: a variable already backed it. `controlled (new)`: it was fixed in code or in the script wrapper, and 5.4 makes it a key with today's value as the default. `HARD-CODED (fixed)`: it assumed a vendor, and this change removes the assumption. `HARD-CODED (kept)`: it stays in code, for the reason given.

## Summary

100 items. Before this change 29 were controlled and 71 were not (a literal in code, or in the wrapper that writes the settings). Now **63 are backed by a variable** (the 29, plus 34 that became keys with today's value as the default), **2 vendor assumptions were fixed**, and **35 stay hard-coded** with a reason each:

| Group | Items kept hard-coded | Why |
| --- | --- | --- |
| Microsoft's formats and APIs | M3, M4, B18, D10, A15, A23, A24, A27, H1 | They are the service's contract (GPT and FAT32 with label `CDROM`, the `USBStick` media type, the Configurator REST operations, built-in role IDs, API versions, what Ready means, the handoff format). A value can't change them; a code change would. |
| Security design | B16, B17 | A generated share password and TCP 445 only from the BMCs, read-write because the voucher is written through it. |
| Safety and correctness | B5, B6, B21, B22, V3, A26, A29, N2 | The BIOS read before any change, the restart type (the machine is reinstalled next), idempotence, one retry, the unreliable `ApplyConfiguration` path kept off. |
| Layout and evidence | R6, M7, M8, H2, H3 | Sub-folder and file names under the controlled `media_path` and `evidence_path`; Sonar follows the log names. |
| Internal polling and tuning | R4, R5, M5, B8, Bt4, Bt6, V2, D9 | Probe windows, poll intervals, cluster size: no environment has needed another value. |
| Dell protocol, auto-detected | B19 | The iDRAC 7.30 boot-target workaround is chosen from the BMC's `AllowableValues`, not by the operator. A gap on an HPE or Lenovo BMC without `Usb`. |
| Unsupported by the service path | A11, V5 | Connectivity `Public` (no proxy details in the site setting), and the Configurator App voucher fallback. |

## Resolve (`Get-ZtpBootstrapIso.ps1`)

| # | What it does | Schema 5 path | Environment-file key | Default | Status |
| --- | --- | --- | --- | --- | --- |
| R1 | Which maintenance ISO: `latest`, a train (2610), a build, or a Microsoft download URL | `provisioning.simplified.maintenance_iso` | `ztp.provisioning_iso` | none (required) | controlled |
| R2 | Consider preview trains (a month above 12) | `provisioning.simplified.include_preview` | `ztp.include_preview` | false | controlled (new) |
| R3 | Highest train to consider with `latest` | `provisioning.simplified.max_train` | `ztp.max_train` | none | controlled (new) |
| R4 | How many calendar months of `https://aka.ms/aep/installeros/<YYMM>` it probes (24) | none | none | 24 | HARD-CODED (kept): Microsoft's publication pattern; a pin (R1) covers anything older |
| R5 | The publication URL pattern and the Microsoft download hosts it accepts | none | none | `aka.ms/aep/installeros` | HARD-CODED (kept): Microsoft's location, not an environment choice; R1 takes any Microsoft URL |
| R6 | Download cache layout (`<media>\bootstrap\<version>\provision-os.iso`), SHA-256 trust on first use, 256 MB headroom check | `provisioning.simplified.media_path` roots it | `ztp.media_path` | `%ProgramData%\AzureLocalZtp\<site_name>\media` | HARD-CODED (kept): the layout is the integrity design; the root is controlled |

## Media (`New-ZtpVirtualUsbImage.ps1`)

| # | What it does | Schema 5 path | Environment-file key | Default | Status |
| --- | --- | --- | --- | --- | --- |
| M1 | Image file name `<prefix><node>.img` | `provisioning.simplified.usb_image.name_prefix` | `ztp.usb_image.name_prefix` | `ztp-usb-` | controlled (new) |
| M2 | Image size (4 GiB booted on Dell 16G; the ISO needs about 1 GiB) | `provisioning.simplified.usb_image.size_gb` | `ztp.usb_image.size_gb` | 4 | controlled (new) |
| M3 | GPT with one FAT32 partition (what Microsoft's `usb_prep.exe` writes) | none | none | fixed | HARD-CODED (kept): Microsoft's format |
| M4 | Volume label `CDROM` | none | none | `CDROM` | HARD-CODED (kept): the maintenance boot searches for the label |
| M5 | FAT32 cluster size 4096 | none | none | 4096 | HARD-CODED (kept): script parameter, no environment needs another |
| M6 | The `edgeuser` password hash written to `prov_config\download\hash_password.txt` (only when a password is set) | `provisioning.simplified.maintenance_password` | `ztp.maintenance_password_secret` | none: the image keeps Microsoft's out-of-box password | controlled |
| M7 | Rebuild this tool's own images when a run starts from the beginning (never after Boot) | none | none | on | HARD-CODED (kept): a fresh provisioning needs a fresh image; the vouchers live in the image after Boot |
| M8 | Sub-folders `ztp-virtual-usb`, `vouchers`, `ztp-state` of the media folder | `provisioning.simplified.media_path` roots them | `ztp.media_path` | as above | HARD-CODED (kept): layout under a controlled root |

## Boot (`Set-ZtpBios.ps1`, `Publish-MaintenanceIso.ps1`, `Mount-ZtpVirtualUsb.ps1`, `Start-MaintenanceBoot.ps1`)

| # | What it does | Schema 5 path | Environment-file key | Default | Status |
| --- | --- | --- | --- | --- | --- |
| B1 | BIOS attributes set before the maintenance boot (read first, change only what differs) | `hardware.bios`, `nodes[].bios`, `hardware.bios_during_provisioning`, `nodes[].bios_during_provisioning` | the same names | none | controlled |
| B2 | BIOS: turn the SAN adapter slots off for the install, back on in Restore | `provisioning.simplified.isolate_san_adapters` with `nodes[].san.hbas[].slot` | `ztp.isolate_san_adapters` with `cluster_nodes[].san.hbas[].slot` | true when any node lists `san.hbas` | controlled (new): was only possible by writing Dell's `Slot2` by hand |
| B3 | BIOS: enable the embedded NICs for a management or provisioning port in slot Embedded | `provisioning.simplified.enable_embedded_nics` with `nodes[].network_adapters[].slot` | `ztp.enable_embedded_nics` | true | controlled (new) |
| B4 | The slot label to attribute mapping (`Slot{n}`, `Disabled`, `Enabled`, `EmbNic1Nic2`) | none (vendor data) | `config/oem/<vendor>.json`, `bios` | Dell only | controlled (new): data, not code; other vendors need the raw map |
| B5 | Before any node changes: read every node's BIOS and stop on an attribute the BMC lacks | none | none | always | HARD-CODED (kept): a safety check, no reason to switch it off |
| B6 | BIOS applied `OnReset`, then the node is restarted (`ForceRestart`, or `On` when it is off) | none | none | OnReset, ForceRestart | HARD-CODED (kept): the machine is reinstalled next; a graceful restart buys nothing |
| B7 | How long to wait for the BIOS to report the new values | `provisioning.simplified.timeouts.bios_minutes` | `ztp.timeouts.bios_minutes` | 30 | controlled (new) |
| B8 | BIOS poll interval while waiting | none | none | 30 s | HARD-CODED (kept): script parameter, internal polling |
| B9 | Which BMC, which login | `nodes[].bmc.ip_address`, `hardware.bmc.username`, `hardware.bmc.password` | `cluster_nodes[].idrac_ip`, `ztp.bmc_secret.*` | none (required) | controlled |
| B10 | Accept the BMC's self-signed TLS certificate | `hardware.bmc.verify_certificate` | `ztp.verify_bmc_certificate` | false (accept) | controlled (new): was always on |
| B11 | Also set the iDRAC Remote File Share write attribute before inserting media | `hardware.bmc.rfs_write_attribute` | `ztp.rfs_write_attribute` | true for Dell, false for the other vendors (`config/oem/<vendor>.json`, `bmc.rfsWriteAttribute`) | HARD-CODED (fixed): was `true` for every vendor, and fails on a BMC that has no `RFS.<n>.WriteProtected` |
| B12 | SMB share name | `provisioning.simplified.media_share.name` | `ztp.share_name` | none (required) | controlled |
| B13 | The address the BMCs reach this host on | `provisioning.simplified.media_share.host` or `host_adapter` | `ztp.share_host`, `ztp.share_host_adapter` | none (required) | controlled |
| B14 | The local account the BMCs sign in with | `provisioning.simplified.media_share.account_name` | `ztp.share_account_name` | `svc-ztp-media` | controlled (new) |
| B15 | Keep the share, firewall rule and account after the vouchers are collected | `provisioning.simplified.media_share.keep` | `ztp.keep_share` | false | controlled (new) |
| B16 | The share password: 32 random characters, never stored or printed | none | none | generated | HARD-CODED (kept): security design |
| B17 | The share is read-write (the maintenance environment writes its voucher) and TCP 445 is open only from the BMC addresses | none | none | read-write, 445 | HARD-CODED (kept): security design; read-write is how the voucher gets out |
| B18 | Virtual media: the first slot whose `MediaTypes` has `USBStick`, `TransferProtocolType` CIFS | none | none | fixed | HARD-CODED (kept): the standard Redfish type; the OEM file's `virtualMediaSlot` is informational |
| B19 | One-time boot target: `Usb` when the BMC offers it, else the iDRAC 7.30 workaround (`ServerBoot.1.FirstBootDevice=vFDD` plus a `Floppy` override, 120 s wait for it to land) | none | none | auto-detected from the BMC's `AllowableValues` | HARD-CODED (kept): detected, not chosen; the fallback is iDRAC-specific (see Hardware below) |
| B20 | After the restart, watch 10 minutes (every 20 s) for the iDRAC Lifecycle log message `OSE1002` ("booted its installed OS") and stop if it appears | none | none | 10 min, Lclog | HARD-CODED (fixed): skipped with a warning on a BMC without an `Lclog` service (it threw a 404); the 10 minutes stay, see Hardware |
| B21 | Manager and system: the first member of `/redfish/v1/Managers` and `/redfish/v1/Systems` | none | none | first | HARD-CODED (kept): vendor-neutral Redfish; one system per BMC |
| B22 | `-ConfirmNotClustered` and the restart are passed on `-Execute`; every node boots at once (throttle = node count) | none | none | on | HARD-CODED (kept): `-Execute` is the operator's confirmation; the machines are reinstalled |
| B23 | Which BMC family's log services and signals the watch reads | `hardware.vendor` | `hardware.vendor` | none (required) | controlled |

## Bootstrap (`Wait-ZtpBootstrapComplete.ps1`)

| # | What it does | Schema 5 path | Environment-file key | Default | Status |
| --- | --- | --- | --- | --- | --- |
| Bt1 | Overall budget until every node is ready for the portal | `provisioning.simplified.timeouts.bootstrap_minutes` | `ztp.timeouts.bootstrap_minutes` | 120 | controlled (new) |
| Bt2 | Budget until a valid voucher appears | `provisioning.simplified.timeouts.bootstrap_voucher_minutes` | `ztp.timeouts.bootstrap_voucher_minutes` | 90 | controlled (new) |
| Bt3 | How long the BMC may show no change before a stall is reported | `provisioning.simplified.timeouts.bootstrap_stall_minutes` | `ztp.timeouts.bootstrap_stall_minutes` | 20 | controlled (new) |
| Bt4 | Poll interval (15 s, backing off to 120 s) | none | none | 15 s, 120 s | HARD-CODED (kept): internal polling |
| Bt5 | The Azure prerequisite check (feature `Microsoft.DeviceOnboarding/AzureLocalZTP`; providers `Microsoft.AzureStackHCI`, `Microsoft.Edge`, `Microsoft.HybridCompute`, `Microsoft.DeviceOnboarding`; the OS image catalog) | `provisioning.simplified.skip_azure_check` | `ztp.skip_azure_check` | false (check) | controlled (new) |
| Bt6 | The list in Bt5 | none | none | fixed | HARD-CODED (kept): what Microsoft requires for the claim |
| Bt7 | Catalog region of the check | `azure.location` | `azure_resources.location` | none (required) | controlled |
| Bt8 | The voucher: `\vouchers\<serial>\*.pem` in the image, validated as PEM, matched to the node by serial number | `nodes[].serial_number` | `cluster_nodes[].service_tag` | none (required) | controlled |
| Bt9 | Log services and message patterns the watch reads | none (vendor data) | `config/oem/<vendor>.json`, `bmc.logServices`, `bmc.signals` | Dell patterns marked unverified; other vendors empty | controlled: data file |

## Vouchers (`Wait-ZtpVoucher.ps1`, `Read-ZtpVoucherFromImage.ps1`)

| # | What it does | Schema 5 path | Environment-file key | Default | Status |
| --- | --- | --- | --- | --- | --- |
| V1 | How long to wait for each node's voucher in its image | `provisioning.simplified.timeouts.voucher_wait_minutes` | `ztp.timeouts.voucher_wait_minutes` | 120 | controlled (new) |
| V2 | Poll interval 60 s; eject retries every 30 s | none | none | 60 s, 30 s | HARD-CODED (kept): internal polling |
| V3 | Replace a local voucher (a voucher is one-time use; the image holds the current one) | none | none | on | HARD-CODED (kept): correctness |
| V4 | Where `<serial>.pem` is written | `provisioning.simplified.media_path` | `ztp.media_path` | `<media>\vouchers` | controlled (root) |
| V5 | The Configurator App voucher folder fallback | none | none (orchestrator `-VoucherFolder`) | off | HARD-CODED (kept): a manual fallback, not part of the unattended flow |

## Device (`Set-ZtpDeviceConfiguration.ps1`)

| # | What it does | Schema 5 path | Environment-file key | Default | Status |
| --- | --- | --- | --- | --- | --- |
| D1 | TCP port of the maintenance environment's Configurator service | `provisioning.simplified.maintenance_environment.port` | `ztp.maintenance_environment.port` | 20001 | controlled (new) |
| D2 | The service's user | `provisioning.simplified.maintenance_environment.username` | `ztp.maintenance_environment.username` | `edgeuser` | controlled (new) |
| D3 | Its password | `provisioning.simplified.maintenance_password` | `ztp.maintenance_password_secret` | Microsoft's published out-of-box password | controlled |
| D4 | Where it scans for the service of a node without an address (one TCP connect to the port per address) | `networking.management.provisioning_dhcp_range` | `network_intents.management.provisioning_dhcp_range` | the management subnet; at most 4096 addresses | controlled |
| D5 | A node's own maintenance address | `nodes[].maintenance_address`, else the `ip_address` of its `provisioning` port | `cluster_nodes[].maintenance_address` | none | controlled |
| D6 | How long the scan and the wait for the address may take | `provisioning.simplified.timeouts.device_minutes` | `ztp.timeouts.device_minutes` | 30 | controlled (new) |
| D7 | Which port gets the static address: the one with the management MAC | `nodes[].network_adapters[]` (role `management`), `networking.management.static_method` | `cluster_nodes[].mac_address`, `network_intents.management.static_method` | `device` | controlled |
| D8 | Address, mask, gateway, DNS, VLAN sent | `nodes[].network_adapters[].ip_address`, `networking.management.*` | `cluster_nodes[].ip_address`, `network_intents.management.*` | none | controlled |
| D9 | Skip the certificate check of the maintenance environment; probe timeout 500 ms; request timeout 30 s; poll interval from the Ready stage | none | none | fixed | HARD-CODED (kept): the maintenance environment's certificate is self-generated and can't be pinned; the timeouts are tuning |
| D10 | The REST operations (`GetNetworkAdapters`, `SetArcBootstrapDeviceConfiguration`, ...) | none | none | fixed | HARD-CODED (kept): Microsoft's API |

## Azure and Ready (`Invoke-ZtpAzureProvisioning.ps1`, `Wait-ZtpMachineReady.ps1`, `bicep/main.bicep`, `Invoke-ZtpEnvironment.ps1`)

| # | What it does | Schema 5 path | Environment-file key | Default | Status |
| --- | --- | --- | --- | --- | --- |
| A1 | Subscription and resource group of the site and edge machines | `provisioning.simplified.subscription_id`, `resource_group`, else `azure.subscription_id`, `azure.resource_group` | `ztp.subscription_id`, `ztp.resource_group` | none (required) | controlled |
| A2 | Create the resource group when it is missing (in `azure.location`, with the tags) | `provisioning.simplified.create_resource_group` | `ztp.create_resource_group` | true | controlled (new) |
| A3 | Site resource name and display name | `provisioning.simplified.site_name`, `site.name` | `ztp.site_name`, `site.name` | none (required) | controlled |
| A4 | Name of the site configuration (`Microsoft.Edge/configurations`) | `provisioning.simplified.configuration_name` | `ztp.configuration_name` | `default` | controlled (new) |
| A5 | Managed resource group name | `provisioning.simplified.managed_resource_group_name` | `ztp.managed_resource_group_name` | empty: the service chooses | controlled (new) |
| A6 | Create the site's network, time, connectivity and security settings | `provisioning.simplified.apply_site_settings` | `ztp.apply_site_settings` | true | controlled (new) |
| A7 | Network setting kind | `provisioning.simplified.network_kind` | `ztp.network_kind` | `LAN` | controlled (new) |
| A8 | Network setting: Manual or Automatic, with the range, gateway, DNS, VLAN | `networking.management.*`, `static_method`, the nodes' `ip_assignment` | `network_intents.management.*` | Automatic with `static_method: device` | controlled |
| A9 | Time setting: Automatic or Manual NTP and the servers | `provisioning.simplified.ntp.configuration`, `server`, `alternate_server` | `ztp.ntp.*` | Automatic | controlled (new) |
| A10 | Time zone | `site.time_zone` | `ztp.time_zone` | none (required) | controlled |
| A11 | Connectivity setting `Public` | none | none | `Public` | HARD-CODED (kept): the site setting carries no proxy details, and Arc gateway is not supported with simplified provisioning (rule AZL-016); a proxy path needs a new Bicep shape first |
| A12 | Security setting: reference the Key Vault (purpose `LocalAdminCredentials`) | `provisioning.simplified.use_key_vault_configuration` | `ztp.use_key_vault_configuration` | true | controlled (new) |
| A13 | Role assignment: the Azure Local resource provider's Connected Machine Resource Manager role on the resource group | `provisioning.simplified.assign_hci_rp_role` | `ztp.assign_hci_rp_role` | true | controlled (new) |
| A14 | Role assignment: each edge machine's constrained delegation (RBAC Administrator, conditioned to Connected Machine Resource Administrator) on the resource group and the Key Vault | `provisioning.simplified.assign_provisioning_roles` | `ztp.assign_provisioning_roles` | true | controlled (new) |
| A15 | The role definition IDs and the delegation condition | none | none | fixed | HARD-CODED (kept): Azure's built-in roles and the portal template's condition |
| A16 | Resource provider object ID | `azure.hci_resource_provider_object_id` | `ztp.azl_rp_object_id` | looked up by the first-party application ID `1412d89f-b8a8-4111-b4fd-e82905cbd85d` when the directory is readable | controlled (the application ID is Microsoft's constant) |
| A17 | Tags on the resource group, configuration and edge machines (Microsoft.Edge sites take none) | `tags` | `ztp.tags` | none | controlled |
| A18 | Site mode: create what is missing, create only, or reuse | `provisioning.simplified.site_mode` | `ztp.site_mode` | `Auto` | controlled (new) |
| A19 | ARM deployment name | `provisioning.simplified.deployment_name` | `ztp.deployment_name` | `ztp-<site_name>` | controlled (new) |
| A20 | The OS version (`latest`, `latest-preview`, or a validated solution recipe version), resolved from the `osImages` catalog | `provisioning.os_version` | `ztp.os_version` | none (required; AZL-013 warns about `latest`) | controlled |
| A21 | The provisioning administrator: user name and the Key Vault secret | `provisioning.simplified.admin.username`, `admin.password` | `ztp.admin_secret.*` | none (required) | controlled |
| A22 | Arc machine name (the service may overwrite it at claim time: open item in `infrastructure-schema-5.md`) | `nodes[].arc_machine_name` | `cluster_nodes[].arc_machine_name` | the node name | controlled |
| A23 | Edge machine identity `SystemAssigned`, owner key type `MicrosoftManaged`, `osType` HCI, secret type `KeyVault` | none | none | fixed | HARD-CODED (kept): the API's constants for Azure Local |
| A24 | API versions: sites `2025-06-01`, configurations `2025-12-01-preview`, edge machines and jobs `2026-10-01` | none | none | fixed | HARD-CODED (kept): the scripts and the Bicep are written against those shapes; another version needs code, not a value |
| A25 | Resubmit a failed OS install job | `provisioning.simplified.retry_provision_os` | `ztp.retry_provision_os` | true | controlled (new) |
| A26 | How many times (1) | none | none | 1 | HARD-CODED (kept): script parameter; a second failure is a real failure, not one to retry past |
| A27 | Ready means: lifecycle `Provisioned`, job `DeploymentSuccess`, Arc `Connected`, the four required extensions (`AzureEdgeDeviceManagement`, `AzureEdgeLifecycleManager`, `AzureEdgeRemoteSupport`, `AzureEdgeTelemetryAndDiagnostics`) | none | none | fixed | HARD-CODED (kept): Azure Local's own definition |
| A28 | Ready polling budget and interval | `provisioning.simplified.timeouts.ready_minutes`, `poll_interval_seconds` | `ztp.timeouts.ready_minutes`, `ztp.timeouts.poll_interval_seconds` | 180, 60 | controlled (new) |
| A29 | Edge machines that already exist are left out of the claim | none | none | on | HARD-CODED (kept): idempotence |
| A30 | Sign in as a managed identity | none (`-UseManagedIdentity`) | none | off | controlled: a switch of the script |

## Network, Restore, Handoff

| # | What it does | Schema 5 path | Environment-file key | Default | Status |
| --- | --- | --- | --- | --- | --- |
| N1 | Network: find the management port by MAC and compare the address with the file; verify only | `nodes[].network_adapters[]` | `cluster_nodes[].mac_address`, `ip_address`, `ip_assignment` | verify | controlled |
| N2 | Network: move the address through Azure's `ApplyConfiguration` | none (`-ApplyThroughAzure`) | none | off | HARD-CODED (kept): documented unreliable (the job never started on two live runs); opt-in on the orchestrator |
| N3 | Network: how long each Azure configuration job may take | `provisioning.simplified.timeouts.network_minutes` | `ztp.timeouts.network_minutes` | 60 | controlled (new) |
| Rs1 | Restore: which BIOS values are set back (the final values, or the value saved before Boot) | `hardware.bios*`, `nodes[].bios*`, the derived plan | `bios_restore` in the node list | none | controlled |
| Rs2 | Restore: settle time before the Arc check | `provisioning.simplified.timeouts.restore_settle_minutes` | `ztp.timeouts.restore_settle_minutes` | 5 | controlled (new) |
| Rs3 | Restore: how long the Arc machines may take to reconnect | `provisioning.simplified.timeouts.ready_minutes` | `ztp.timeouts.ready_minutes` | 180 | controlled |
| H1 | Handoff content: edge machine and Arc machine names and IDs, the site, the installed solution version, each node's Network result, the BIOS values Restore set back | none | none | fixed | HARD-CODED (kept): the output contract |
| H2 | Handoff and cluster-input files, run name (nodes joined by `+`), event and change log names (`ztp-events.jsonl`, `bios-changes.jsonl`, `device-changes.jsonl`, `network-changes.jsonl`) | `provisioning.simplified.media_path`, `evidence_path` root them | `ztp.media_path`, `ztp.evidence_path` | `%ProgramData%\AzureLocalZtp\<site_name>\...` | HARD-CODED (kept): names are the evidence contract Sonar follows; the folders are controlled |
| H3 | A transcript of every `-Execute` run in the evidence folder | none | none | on | HARD-CODED (kept): evidence |

## Is ZTP generic about the hardware?

| Question | Answer |
| --- | --- |
| Port counts | Yes. Nothing counts ports. The Device stage matches the maintenance environment's adapter list to the management MAC, the Network stage matches Azure's per-NIC report to the same MAC, and the management port is the one `network_adapters[]` entry with role `management` and an `ip_assignment` other than `none`. A node with 2, 6 or 12 ports is read the same way; the OS names them `Port0` to `PortN`, which ZTP never relies on. |
| Adapter models and types | Yes. An onboard LOM plus a PCIe NIC of another vendor, or several PCIe cards, are just entries with a MAC, roles, and (new) a `slot`. `model` is carried to the handoff and read by nothing else. |
| Slot names | Only the BIOS plan reads them: `Slot <n>` for a PCIe slot and `Embedded` for a LOM, and only to find the BIOS attribute through the vendor's mapping (B2 to B4). An unreadable label stops the run before anything changes. |
| Vendor | Partly. The Redfish client is vendor-neutral (first manager, first system, the `USBStick` media type). Dell-specific behaviours found: **B11** (the RFS attribute, fixed: default by vendor), **B20** (the `Lclog` gate, fixed: skipped with a warning on another BMC), **B19** (the `ServerBoot.1.*` vFDD workaround, used only when the BMC doesn't offer `Usb`; left, and a gap on an HPE or Lenovo BMC that lacks `Usb`), the Dell-only log signals in `config/oem/dell.json` (`unverified`; HPE, Lenovo and Supermicro have none, so their Bootstrap watch relies on the voucher in the image), the default `-Oem Dell` of the orchestrator and `Wait-ZtpBootstrapComplete.ps1` when they are run by hand (`Invoke-ZtpEnvironment.ps1` always passes `hardware.vendor`), and the BIOS slot mapping (B4), which only Dell has. Messages that say "iDRAC" are wording only. |
| BMC type | `nodes[].bmc.type` (`idrac`, `ilo`, `xcc`, `other`) is not read; the BMC is whatever answers Redfish. One BMC login serves every node (`hardware.bmc`); a node with its own login is a validation error. |
| Flagged: assumes a particular server | The 4 GiB image size (booted on Dell 16G): now M2. The 10 minute disk-boot gate "covers POST on these machines" (B20): kept; a server with a longer POST would see the gate end early, not fail. The `OSE1002` message ID is Dell's. Comments naming the AX-760 and the ConnectX port are history, not logic. |

## Moving an existing file to 5.4

A file that uses none of the new keys behaves exactly as before. To let ZTP derive the BIOS plan instead of the raw Dell attributes: set `_metadata.schema_version` to `5.4.0`, list each machine's HBA in `nodes[].san.hbas[]` with `slot: "Slot 2"`, give the onboard ports `slot: "Embedded"`, and delete the raw `Slot2` and `EmbNic1Nic2` entries from `hardware.bios` and `hardware.bios_during_provisioning` (or keep them: an explicit key wins and gives the same values). The derived plan then reads `Slot2` Disabled for the install, `Slot2` Enabled after it, and `EmbNic1Nic2` Enabled.