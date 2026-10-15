# Azure provisioning from vouchers

> API versions of `bicep/main.bicep` (reviewed against Microsoft Learn on 15 Oct 2026): `Microsoft.AzureStackHCI/edgeMachines@2026-10-01` (stable; the live-proven version is `2025-12-01-preview` with the same properties), `Microsoft.Edge/sites@2025-06-01` (stable), the Edge configuration resources at `2025-12-01-preview` (the portal's shape; the stable documents list no properties for them). The stable versions have built and linted clean but have **not** been through a what-if or a deployment yet; run Plan and claim one node first (see [Automated bootstrap](automated-bootstrap.md)).

> Create the site, the site configuration and one edge machine per node from the ownership vouchers, wait until every node is ready to cluster, and record the Arc machine names.

This is the Azure half of simplified machine provisioning. It starts where [Redfish virtual USB and voucher read-back](redfish-virtual-usb-vouchers.md) ends: one `<serial>.pem` voucher per node. It does the same work as the portal's **Machine provisioning (preview) > Provision** wizard, from a template and a parameters file, so it is repeatable and reviewable.

All scripts live in `scripts/simplified-provisioning/`. The orchestrator is a plan by default and changes nothing in Azure until you pass `-Execute`.

## What is proven and what is not

| Area | State |
|------|-------|
| The Bicep template (`bicep/main.bicep`): site, `Microsoft.Edge/configurations` with network, time, connectivity and security settings, configuration reference, Azure Local resource provider role, one `edgeMachines` per node, constrained role delegations | **Proven**: it reproduces a portal deployment that worked end to end. It builds cleanly with `az bicep build`. |
| Response shapes and status logic (edge machine lifecycle, `ProvisionOs` job steps, ready-to-cluster check) | Verified against recorded live responses (`tests/simplified-provisioning/fixtures`). |
| Scripted submit end to end (`Invoke-ZtpAzureProvisioning.ps1 -Execute`) | **Not yet proven live.** Covered by mocked tests only. Plan and what-if first. |
| `ProvisionOs` retry (`-RetryProvisionOs -Execute`) | **Not yet proven live.** The body follows Microsoft's troubleshooting article. |

## Prerequisites

- PowerShell 7, the Azure CLI with Bicep (`az bicep version`), and the `Az.Accounts`, `Az.Resources` and `Az.KeyVault` modules. For the ready check also `Az.ConnectedMachine`.
- `Connect-AzAccount` as an operator with **Contributor and Role Based Access Control Administrator** (or Owner) on the target resource group.
- The `Microsoft.DeviceOnboarding/AzureLocalZTP` feature and the resource providers registered, see the [README](https://github.com/AzureLocal/azurelocal-ztp#azure-prerequisites).
- The target resource group and a **Key Vault** in the **East US** preview region. The administrator password secret lives in that vault. The scripts never put the password in the template; the template carries only the secret's resource ID (the service rejects the `https` secret URI).
- The object ID of the Azure Local resource provider first-party application in your tenant (the portal calls it `hciRPServiceprincipalID`).
- One `<serial>.pem` voucher per node in a folder (`<serial>.pem` or `<serial>\*.pem`).

## The parameters file

Copy the example and edit it. It uses the ARM parameters format, so it is also valid for `az deployment group create`.

```powershell
Copy-Item scripts/simplified-provisioning/bicep/main.example.parameters.json scripts/simplified-provisioning/bicep/main.parameters.json
```

| Key | Meaning |
|-----|---------|
| `location` | Provisioning region (preview: `eastus`). |
| `azl_rp_app_object_id` | Object ID of the Azure Local resource provider application in your tenant. |
| `key_vault_name`, `key_vault_resource_group` | The vault that holds the administrator secret. |
| `site_name`, `site_display_name`, `configuration_name` | The `Microsoft.Edge` site and its configuration. |
| `admin_username`, `admin_secret_name` | Local administrator user and the **name** of its Key Vault secret. |
| `time_zone` | For example `UTC`. |
| `nodes` | `name` (edge machine name and host name) and `service_tag` of each node. |
| `apply_site_settings`, `use_key_vault_configuration`, `assign_provisioning_roles`, `assign_hci_rp_role` | Switches, all default `true`. Turn `assign_hci_rp_role` off if the landing zone already holds that role assignment. |
| `network_kind`, `ip_assignment_type`, `ipv4`, `ntp_*`, `connectivity_type`, `managed_resource_group_name`, `tags` | Optional site settings. |

The subscription and resource group are script parameters, not file values. Vouchers, the OS version and the create/claim switches are **run-time values** added in memory; they never appear in a file. A `.bicepparam` file is also accepted (compiled with `az bicep build-params`).

## Run it

### Plan (changes nothing)

```powershell
./scripts/simplified-provisioning/Invoke-ZtpAzureProvisioning.ps1 `
    -SubscriptionId 00000000-0000-0000-0000-000000000000 `
    -ResourceGroupName rg-example `
    -ParameterFile ./scripts/simplified-provisioning/bicep/main.parameters.json `
    -VoucherPath D:\ZtpVouchers
```

The default run goes through **Prereqs, Validate and Plan**: tools present, template builds, parameters file complete, then read-only checks of the OS image catalog, the site, the configuration, existing edge machines, the voucher files and the administrator secret (by name), and finally an ARM **what-if**. If a voucher is missing the what-if covers the site and configuration only.

- `-OsVersion` defaults to `latest` (the newest release build; preview builds, which carry a non-calendar month in `12.YYMM` (for example `12.26NN` with `NN` above 12), are skipped). Use `latest-preview`, a validated solution recipe version such as `12.2609.1003.7`, or a composed image version. `Get-ZtpOsImage.ps1` lists the catalog.
- `-SiteMode Auto` (default) creates only the site and configuration that are missing; `Reuse` requires both to exist; `Create` always PUTs them.
- An edge machine that already exists is **never re-PUT**; only the other nodes are claimed. `-Node` limits the run.

### Execute

```powershell
$adminPassword = Read-Host -AsSecureString 'Provisioning administrator password'

./scripts/simplified-provisioning/Invoke-ZtpAzureProvisioning.ps1 `
    -SubscriptionId 00000000-0000-0000-0000-000000000000 `
    -ResourceGroupName rg-example `
    -ParameterFile ./scripts/simplified-provisioning/bicep/main.parameters.json `
    -VoucherPath D:\ZtpVouchers `
    -AdminPassword $adminPassword `
    -ArcMachineNameMapPath D:\ZtpState\arc-machine-names.json `
    -Execute
```

With `-Execute` the run continues with:

1. **Execute**: writes the administrator secret only if it is missing (from `-AdminPassword`, in memory; an existing secret is never touched and a missing one without `-AdminPassword` stops the run), then submits the deployment and waits until ARM has accepted it. It refuses to submit if any voucher is missing.
2. **Watch**: `Wait-ZtpMachineReady.ps1` polls each edge machine and its `ProvisionOs` job, prints each stage and step change once, and returns only when every node is ready to cluster. Then `Update-ArcMachineNames.ps1` writes the Arc name map.

You can resume or run a stage alone: `-Stage Watch` follows an interrupted run and never submits the deployment.

## Wait for ready

`Wait-ZtpMachineReady.ps1` can also be called on its own:

```powershell
./scripts/simplified-provisioning/Wait-ZtpMachineReady.ps1 `
    -SubscriptionId 00000000-0000-0000-0000-000000000000 `
    -ResourceGroupName rg-example -EdgeMachineName node-01, node-02
```

The lifecycle on a live run was `Creating`, `AwaitingConnection`, `Provisioning`, `ReadyForOs`, `InstallingOs`, `Provisioned`. A node is **ready to cluster** when:

- the lifecycle is `Provisioned` and the `ProvisionOs` job reports `DeploymentSuccess`,
- the edge machine is `Connected` and has an `arcMachineResourceId`,
- the mandatory Arc extensions `AzureEdgeDeviceManagement`, `AzureEdgeLifecycleManager`, `AzureEdgeRemoteSupport` and `AzureEdgeTelemetryAndDiagnostics` are `Succeeded`.

A failed lifecycle, stage, job or step is terminal: the script throws (non-zero exit) and names the failing step. On timeout it names the pending node, its stage and its missing extensions. Allow about an hour per node from claim to `Provisioned`.

### Retry a failed OS install

```powershell
./scripts/simplified-provisioning/Wait-ZtpMachineReady.ps1 `
    -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example `
    -EdgeMachineName node-02 -RetryProvisionOs -Execute
```

The retry re-PUTs `jobs/ProvisionOs` the way Microsoft's troubleshooting article does (the machine's own `osProfile` and `userDetails`, target `HCI`). It is sent **only with `-RetryProvisionOs` and `-Execute`**, at most `-MaxRetryCount` times per node (default 1). Without `-Execute` the retry is printed, not sent. Fix the cause first. This path is not yet proven live.

## Arc machine name map

Simplified provisioning names the Arc machine `<device-id>-1`, **not** the host name. Cluster deployment must therefore use each edge machine's `arcMachineResourceId`, never the node name.

`Update-ArcMachineNames.ps1` reads the `arcMachineResourceId` of each edge machine and returns one row per node (`Node`, `ArcMachineName`, `ArcMachineResourceId`, `ArcResourceGroup`, `Change`). With `-MapPath` it compares with, and with `-Execute` writes, a JSON map:

```json
{
  "node-01": "00000000-0000-0000-0000-000000000000-1",
  "node-02": "00000000-0000-0000-0000-000000000000-1"
}
```

Existing entries for other nodes are kept. A node that is not `Provisioned` is refused (its edge machine still points at a temporary maintenance-environment Arc machine) unless you pass `-AllowNotReady`. The Arc machines live in the configuration's **managed resource group**, not in your resource group.

Finally, `Test-ProvisionedMachines.ps1 -SubscriptionId ... -ResourceGroupName <managed resource group> -ExpectedMachineName <arc names>` confirms the Arc machines are connected with the mandatory extensions (read-only).

## What the template creates

`bicep/main.bicep` is deployed at resource group scope and creates, per the portal template:

- the `Microsoft.Edge` **site** and **configuration** (with the configuration reference), and the network, time, connectivity and security settings;
- the Azure Local resource provider's role on the resource group (deterministic name, so a re-run is an idempotent re-PUT);
- one `Microsoft.AzureStackHCI/edgeMachines` per node with a system-assigned identity, its voucher, the OS version and the administrator secret reference;
- each edge machine's **constrained role delegation** (Role Based Access Control Administrator limited by an ABAC condition) on the resource group, and on the Key Vault through `bicep/modules/key-vault-delegation.bicep`.

The role definition IDs in the template are Azure built-in roles, the only literal IDs in it.

## Caveats

- **Preview, East US only.** The provisioning region is `eastus` while the feature is in preview.
- **The Arc machine is named `<device-id>-1`.** Use the edge machine's `arcMachineResourceId` for cluster deployment.
- **Vouchers stay in memory.** They are read, base64-encoded into a secure parameter and discarded. They are never printed or written to a file by this script.
- **Not yet proven live:** the scripted submit end to end and the `ProvisionOs` retry. Use the plan and what-if, and compare with the portal if in doubt.

## Next steps

Provisioning leaves you with Arc-connected machines with the mandatory extensions. These steps come after it and are outside this repository:

- OEM solution builder extension (SBE) driver and node preparation.
- Azure Local cluster deployment, using each edge machine's `arcMachineResourceId`.

The NIC 2026 Azure Local public repository, <https://github.com/thisismydemo/nic2026_azl>, shows one worked example of those steps (it is published after the event, if it is not available yet).
