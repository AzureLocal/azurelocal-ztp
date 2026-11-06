# Environment file reference

> Every key that `Invoke-ZtpEnvironment.ps1` and `Initialize-ZtpNode.ps1` read from the environment file, what it's for, and an example.

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
| `cluster_nodes[].ip_address` | P+P | IPv4 | The node's static management address, which Prepare sets. After the OS install the node takes its address from DHCP. Prepare signs in on this address if the node answers there (a DHCP reservation for the management MAC), and otherwise on the address the node's Arc machine reports for the management MAC. That address must be in this server's WinRM TrustedHosts. |
| `cluster_nodes[].mac_address` | P+P | `AA:BB:CC:DD:EE:FF` or `AA-BB-CC-DD-EE-FF` | Picks the management adapter on the node. |
| `cluster_nodes[].service_tag` | Prov | Text | The machine's serial number. Maps each voucher (`\vouchers\<serial>\`) to its node. |
| `cluster_nodes[].idrac_ip` | Prov | IPv4 | The BMC address. Redfish target, and the only source allowed to reach the SMB share. |

### Management network, time and the deployment admin

| Key | Needed by | Format | Used for |
| --- | --- | --- | --- |
| `network_intents.management.subnet` | P+P | CIDR, for example `192.0.2.0/24` | Prefix length of the static address. |
| `network_intents.management.gateway` | P+P | IPv4 | The one default gateway, on the management adapter. |
| `network_intents.management.dns_servers` | P+P | List of IPv4 | DNS on the management adapter. Learn: DNS servers can't be changed after deployment ([DNS server considerations](https://learn.microsoft.com/azure/azure-local/plan/cloud-deployment-network-considerations#dns-server-considerations)). |
| `onprem.ntp_servers` | P+P, optional | List | Time source. Prepare sets it with `w32tm` and waits until the node syncs from one of them. |
| `credentials.local_admin_username` | P+P | Text; not `Administrator` or `Guest` | The deployment admin that Prepare creates in local Administrators. |
| `credentials.local_admin_password_secret` | P+P | `keyvault://<vault>/<secret>` | The deployment admin's password. The vault must be in the subscription named by `ztp.admin_secret.subscription_id`. Learn asks for at least 14 characters with lowercase, uppercase, a digit and a special character ([install the OS](https://learn.microsoft.com/azure/azure-local/deploy/deployment-install-os#prerequisites)). |

### Hardware

| Key | Needed by | Format | Used for |
| --- | --- | --- | --- |
| `hardware.vendor` | P+P | Text, for example `Dell` | Picks `config/oem/<vendor>.json`: the SBE manifest URL, the driver folders inside the SBE, and the BMC log patterns. |
| `hardware.model` | Prov | Text, for example `AX-760` | SBE selection. Hyphens are removed, so `AX-760` becomes `AX760`. |

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
| `ztp.bmc_secret.username_name` | Prov | Secret name | Secret whose value is the BMC user name. |
| `ztp.bmc_secret.password_name` | Prov | Secret name | Secret whose value is the BMC password. |

### Media and share

| Key | Needed by | Format | Used for |
| --- | --- | --- | --- |
| `ztp.share_host` | Prov, one of the two | IPv4 | The management host's address **as the BMCs reach it**. The BMCs mount `//<share_host>/<share_name>/ztp-usb-<node>.img`. |
| `ztp.share_host_adapter` | Prov, one of the two | Adapter name | Instead of `share_host`: the name of the local network adapter whose IPv4 address the BMCs reach. Useful when that address changes, for example on a VPN. It wins over `share_host`. |
| `ztp.share_name` | Prov | Text, letters, digits and hyphens | Name of the SMB share for the images. |
| `ztp.node_preparation.sbe_bundle` | P+P | Folder path on the management host | Folder with the OEM's SBE: exactly one `SBE_*.zip`, its `SBE_*.xml`, and `SBE_Discovery_<oem>.xml`. See [Download the SBE](operator-guide.md#step-2-download-the-oem-sbe). |
| `ztp.node_preparation.allow_unvalidated_sbe` | Prov, optional | `true` or `false` (default `false`) | **Test only.** Use the SBE in `sbe_bundle` even though the OEM's manifest doesn't list it as validated with `ztp.os_version`, for example to test a new Azure Local build before the OEM publishes a matching SBE. The SBE's hash is still checked; only the solution-compatibility check is skipped. The run warns, and the handoff records `compatibilityChecked: false`. The OEM doesn't support the combination, and cluster Validate or Deploy may still refuse it. |

## Values the entry point sets for you

`Invoke-ZtpEnvironment.ps1` fixes these values in the generated inputs. To change one, run the orchestrator directly (see [Orchestrator reference](automated-bootstrap.md)).

| Setting | Value |
| --- | --- |
| Site configuration name | `default` |
| Provisioning network | `LAN`, IP assignment `Automatic` (DHCP during provisioning) |
| Provisioning time | NTP `Automatic` |
| Connectivity | `Public` (no proxy) |
| Role assignments | Site settings, Key Vault configuration, edge machine delegations and the Azure Local resource provider role are all on. |
| BMC handling | `RfsWriteAttribute` on, `SkipCertificateCheck` on (BMCs with self-signed certificates). |
| Timeouts | Voucher wait 120 min, bootstrap 120 min (voucher 90 min), Ready 180 min, poll 60 s. Prepare: Ready 240 min, sign-in 30 min. |
| Preview trains | Not considered for `provisioning_iso: latest`. |
| `ProvisionOs` retry | On: one automatic resubmit per node per run. |
