# Appendix A: API reference

This appendix lists every API and call the ZTP process uses, and the ones it could use, with what each one does and how we know. It covers three families:

- **Azure Resource Manager (ARM) and the Azure PowerShell modules**: `Microsoft.AzureStackHCI` (edge machines, jobs, network adapters, OS images), `Microsoft.Edge` (sites and site configuration), `Microsoft.HybridCompute` (Arc machines and extensions), `Microsoft.Resources` (deployments), the feature and resource-provider registrations, and Key Vault.
- **Redfish on the BMC** (iDRAC on the Dell machines ZTP was proven on): BIOS attributes and pending settings, virtual media, boot override, power and reset, and the log services.
- **The Configurator app REST service in the maintenance environment**: described in full in [Appendix B](./configurator-app-api.md), summarised here so the three families sit side by side.

ZTP runs from a Windows management host and is the client for all of them. Its stages are described in [Design and architecture](../architecture.md#stages-and-gates); this page says which calls each stage makes.

> **None of the Microsoft interfaces below is a promise of stability.** The simplified machine provisioning resources are in preview, the Configurator service is an internal interface, and iDRAC behaviour differs by firmware. Shapes and quirks here come from the builds named in each row (mostly Dell AX-760, iDRAC 7.30, maintenance image 10.2610.0.3063, `Microsoft.AzureStackHCI` 2026-10-01). Re-check against the Microsoft Learn page linked in a row before relying on it for another build.

## How to read this appendix

Every row carries an **evidence label** so you can tell what ZTP does today from what is only possible.

| Label | Meaning |
| --- | --- |
| **Used by ZTP** | A ZTP script makes this call today. The script is named. Where the repository records a live run, the row says **proven live** with the hardware (Dell AX-760, 2026-10 and 2026-11). |
| **Observed once** | Seen in one run or a few runs, and written down, but not something to rely on. The row says what was seen and when. |
| **Read from Microsoft docs** | A Microsoft Learn page or API spec says so; ZTP does not make the call (or makes it only in the shape the page shows). The page is linked or named. |
| **Not made by ZTP** | The call exists, and ZTP could make it, but no ZTP script does. Listed so you can see what is possible; it carries no ZTP evidence at all. |

Addresses, names and identifiers in examples are documentation values: `192.0.2.x` and `198.51.100.x`, all-zero GUIDs, `rg-example`, `node-01`, MAC `00-00-5E-00-53-xx`.

## Contents

- [Which stage makes which call](#which-stage-makes-which-call)
- [How ZTP signs in](#how-ztp-signs-in)
- [Azure Resource Manager](#azure-resource-manager)
  - [Readiness: features and resource providers](#readiness-features-and-resource-providers)
  - [OS image catalog](#os-image-catalog)
  - [The claim: the Bicep deployment](#the-claim-the-bicep-deployment)
  - [Edge machines](#edge-machines)
  - [Jobs: ProvisionOs](#jobs-provisionos)
  - [Network adapters and ApplyConfiguration](#network-adapters-and-applyconfiguration)
  - [Arc machines and extensions](#arc-machines-and-extensions)
  - [Key Vault and the resource group](#key-vault-and-the-resource-group)
  - [Reads ZTP does not make](#reads-ztp-does-not-make)
- [Redfish on the BMC](#redfish-on-the-bmc)
  - [Session](#session)
  - [BIOS attributes and pending settings](#bios-attributes-and-pending-settings)
  - [Virtual media](#virtual-media)
  - [Boot override, power and reset](#boot-override-power-and-reset)
  - [Manager attributes: the RFS write-protection attribute](#manager-attributes-the-rfs-write-protection-attribute)
  - [Log services](#log-services)
  - [Redfish calls ZTP does not make](#redfish-calls-ztp-does-not-make)
- [The Configurator app REST service](#the-configurator-app-rest-service)
- [Plain HTTP downloads](#plain-http-downloads)
- [What is possible, in one view](#what-is-possible-in-one-view)
- [Calls ZTP does not make but could](#calls-ztp-does-not-make-but-could)
- [Sources](#sources)

## Which stage makes which call

| Stage | Script | Azure (ARM and modules) | Redfish (BMC) | Configurator REST | Other |
| --- | --- | --- | --- | --- | --- |
| Resolve | `Get-ZtpBootstrapIso.ps1` | none | none | none | HEAD and GET on `https://aka.ms/aep/installeros/<YYMM>` and the Microsoft download host it redirects to ([plain HTTP downloads](#plain-http-downloads)) |
| Media | `Invoke-ZtpPrepareMedia.ps1`, `New-ZtpVirtualUsbImage.ps1` | none | none | none | Writes the `edgeuser` password hash into each image. It is an input to the REST sign-in later, not a call. |
| Boot | `Start-MaintenanceBoot.ps1`, `Set-ZtpBios.ps1`, `Mount-ZtpVirtualUsb.ps1` | none | [Session](#session), [BIOS](#bios-attributes-and-pending-settings), [virtual media](#virtual-media), [boot override, power](#boot-override-power-and-reset), [RFS attribute](#manager-attributes-the-rfs-write-protection-attribute), [log services](#log-services) (reads) | none | SMB share for the images |
| Bootstrap | `Wait-ZtpBootstrapComplete.ps1` | [Readiness](#readiness-features-and-resource-providers) (feature, providers, OS image catalog), every 5 minutes | Read only: virtual media, power, boot override, [log services](#log-services) | none | The voucher in the image |
| Vouchers | `Wait-ZtpVoucher.ps1`, `Read-ZtpVoucherFromImage.ps1` | none | [Eject](#virtual-media), RFS attribute back to Read Only | none | Reads the voucher from the image on the share |
| Device | `Set-ZtpDeviceConfiguration.ps1` | none | none | `GetNetworkAdapters`, `SetArcBootstrapDeviceConfiguration`, `GetArcBootstrapDeviceConfigurationStatus` | TCP probe of port 20001 |
| Azure | `Invoke-ZtpAzureProvisioning.ps1` | [OS images](#os-image-catalog), [site and configuration](#the-claim-the-bicep-deployment) (GET), [edge machines](#edge-machines) (GET), the [Bicep deployment](#the-claim-the-bicep-deployment) (what-if, PUT), [Key Vault](#key-vault-and-the-resource-group) | none | none | `az bicep` for the template |
| Ready | `Wait-ZtpMachineReady.ps1`, `Update-ArcMachineNames.ps1`, `Test-ProvisionedMachines.ps1` | [Edge machines](#edge-machines) and [jobs/ProvisionOs](#jobs-provisionos) (GET, and PUT to retry), [Arc machines and extensions](#arc-machines-and-extensions) | none | none | |
| Network | `Set-ZtpManagementAddress.ps1` | [networkAdapters](#network-adapters-and-applyconfiguration) (GET); `jobs/ApplyConfiguration` (PUT, GET) only with `-ApplyThroughAzure` | none | none | Verify-only by default |
| Restore | `Restore-ZtpBios.ps1` | [Arc machines](#arc-machines-and-extensions) (wait for Connected again) | [BIOS](#bios-attributes-and-pending-settings), [reset](#boot-override-power-and-reset) | none | |
| Handoff | `New-ZtpHandoff.ps1` | [Edge machines](#edge-machines), [jobs/ProvisionOs](#jobs-provisionos), [networkAdapters](#network-adapters-and-applyconfiguration) (GET) | none | none | Writes files only |

The Network stage does **not** use the Configurator service. After the OS install the maintenance environment is gone and the machine is reached through Azure's per-NIC report.

## How ZTP signs in

| Target | How | Where it is set |
| --- | --- | --- |
| Azure | The operator's own Az PowerShell context (`Connect-AzAccount`, `Set-AzContext`). Every ARM call goes through `Invoke-AzRestMethod`, or an Az cmdlet, under that context. No token is read, stored or printed. | You sign in before the run. The role assignments the run needs are in [Prerequisites](../prerequisites.md). |
| Key Vault | `Get-AzKeyVaultSecret` under the same context: the BMC login, and when set, the `edgeuser` password. | `ztp.bmc_secret.*`, `ztp.maintenance_password_secret` in the environment file. |
| BMC | A Redfish session (`POST /redfish/v1/SessionService/Sessions`, then the `X-Auth-Token` header). If the BMC refuses a session, ZTP falls back to HTTP Basic. The session is deleted at the end of each script. | The BMC login from Key Vault. `ztp.verify_bmc_certificate` (default off) controls the certificate check. |
| Maintenance environment | HTTP Basic as `edgeuser` over TLS, certificate check skipped (the service signs its own certificate). The password is the one the image was built with, otherwise the published default. | `provisioning.simplified.maintenance_password` (older layout `ztp.maintenance_password_secret`); port and user name under `provisioning.simplified.maintenance_environment`. See [Appendix B](./configurator-app-api.md#how-ztp-uses-this-service). |

The vouchers never touch a file on the management host in the claim path: the Bicep template receives them as a secure run-time object in memory.

## Azure Resource Manager

All ARM calls from ZTP go through one function, `Invoke-ZtpArm` (`ZtpAzure.Common.ps1`), a thin wrapper over `Invoke-AzRestMethod`. It accepts only `GET` and `PUT`, adds `api-version`, returns `$null` for a 404 (and 409 for a job that is not created yet) when the caller allows it, and throws with the status and the ARM error code and message, never the request body. The Bicep deployment and a few Azure PowerShell cmdlets are the other ways ZTP reaches Azure.

`{rg}` below is `/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}`.

### Readiness: features and resource providers

| Call | api-version | What it does | Evidence |
| --- | --- | --- | --- |
| `GET /subscriptions/{sub}/providers/Microsoft.Features/featureProviders/Microsoft.DeviceOnboarding/subscriptionFeatureRegistrations/AzureLocalZTP` | `2021-07-01` | Reads whether the `AzureLocalZTP` feature is `Registered`. Without it the voucher claim is refused. Read-only. | **Used by ZTP** (`Get-ZtpAzureReadiness` in `ZtpEvents.Common.ps1`, called by the Bootstrap stage). |
| `GET /subscriptions/{sub}/providers/{namespace}` for `Microsoft.AzureStackHCI`, `Microsoft.Edge`, `Microsoft.HybridCompute`, `Microsoft.DeviceOnboarding` | `2021-04-01` | Reads `registrationState`; each must be `Registered`. Read-only. | **Used by ZTP**, same function. |

Learn documents no Azure-side signal for "this device is waiting to be claimed": a device is unknown to Azure until its voucher is submitted. These checks prove the Azure side is ready, not that the device was seen. ZTP does not register the feature or the providers for you; the message names the `az feature register` command.

### OS image catalog

| Call | api-version | What it does | Evidence |
| --- | --- | --- | --- |
| `GET /subscriptions/{sub}/providers/Microsoft.AzureStackHCI/locations/{location}/osImages?solution-type=HCI` | `2026-10-01` | Lists the OS images: `validatedSolutionRecipeVersion`, `composedImageVersion`, `composedImageIsoUrl`, `composedImageIsoHash`. ZTP picks the newest release build (`latest`), the newest including previews (`latest-preview`), or an exact version. Read-only. | **Used by ZTP** (`Get-ZtpOsImageCatalog`, `Resolve-ZtpOsImage`), proven live. |

Response shape (the properties ZTP reads):

```json
{
  "value": [
    { "properties": {
        "validatedSolutionRecipeVersion": "12.2609.1003.7",
        "composedImageVersion": "12.2609.0.3009",
        "composedImageIsoUrl": "https://example.invalid/12.2609.0.3009.iso",
        "composedImageIsoHash": "3940326C8CD53092C281E0FDD8DE6D1397F70E3EC4AD486690E9B588BFF94514" } }
  ]
}
```

A version whose month part (`12.YYMM`) is not a calendar month, for example `12.2699`, is treated as a preview build and chosen only by `latest-preview` or an exact version.

### The claim: the Bicep deployment

The claim is **one resource-group deployment** of `scripts/simplified-provisioning/bicep/main.bicep`, made with `New-AzResourceGroupDeployment -Mode Incremental` after a `Get-AzResourceGroupDeploymentWhatIfResult` preview. Every resource shape is the one the Azure portal deploys at **Machine provisioning (preview) > Provision**. The ownership vouchers arrive only as a `@secure()` run-time object.

| Resource | api-version | What it is | Evidence |
| --- | --- | --- | --- |
| `Microsoft.Edge/sites` | `2025-06-01` | The site that groups the machines of one location. Only `displayName`. | **Used by ZTP**, proven live. |
| `Microsoft.Edge/configurations` | `2025-12-01-preview` | The site configuration, with a managed resource group where the Arc machines are created (`managedResourcesConfiguration`). | **Used by ZTP**, proven live. No published Bicep types (BCP081 is disabled for it); the stable 2025-06-01 and 2025-08-01 documents list no properties for it. |
| `.../configurations/networkConfigurations` | `2025-12-01-preview` | `kind` `LAN`/`WLAN`; `ipAssignments.ipAssignmentType` `Automatic` or `Manual`; `ipv4` {`addressRange`, `defaultGateway`, `dnsServers`, `subnetMask`, `vLanId`}; `scenario` `Provisioning`. | **Used by ZTP**, proven live (created). |
| `.../configurations/timeServerConfigurations` | `2025-12-01-preview` | `ntpConfigurationChoice`, `ntpServerConfiguration`, `timezone`, `scenario`. | **Used by ZTP** (created; the effect on the machine's time was not separately measured). |
| `.../configurations/connectivityConfigurations` | `2025-12-01-preview` | `connectivityType` `Public` or `Proxy`, `scenario`. Arc gateway is not supported in the preview. ZTP sets `Public` for `scenario.outbound_path` `direct` and `Proxy` for `proxy`. The properties that would carry a proxy URL and bypass list here aren't published, so ZTP sends those to each maintenance environment instead (`WebProxy` of `SetArcBootstrapDeviceConfiguration`). | **Used by ZTP** (created with `Public`; `Proxy` not yet proven live). |
| `.../configurations/securityConfigurations` | `2025-12-01-preview` | `secretReferences` with `purpose` `LocalAdminCredentials`, pointing at the Key Vault. | **Used by ZTP**, proven live. |
| `Microsoft.Edge/configurationReferences` (on the site) | `2025-12-01-preview` | Links the site to its configuration. | **Used by ZTP**, proven live. |
| `Microsoft.AzureStackHCI/edgeMachines` | `2026-10-01` | The machine, claimed with its ownership voucher. See [Edge machines](#edge-machines). | **Used by ZTP**, proven live (Dell AX-760, 2026-11; the same properties on `2025-12-01-preview`). |
| `Microsoft.Authorization/roleAssignments` | `2022-04-01` | The Azure Local resource provider's *Azure Connected Machine Resource Manager* role on the resource group; each edge machine's constrained *Role Based Access Control Administrator* delegation on the resource group (limited to *Azure Connected Machine Resource Administrator*); and the same kind of delegation on the Key Vault (limited to *Key Vault Secrets User*), through `modules/key-vault-delegation.bicep`. | **Used by ZTP**, proven live. Without the first delegation the install fails with error 5901. |

Other deployment-time calls:

| Call | What it does | Evidence |
| --- | --- | --- |
| `Get-AzResourceGroupDeploymentWhatIfResult` | Previews the deployment at resource-group scope (`ResourceIdOnly`). Writes nothing. | **Used by ZTP** (plan mode). |
| `New-AzResourceGroupDeployment -AsJob` | Submits the deployment. ZTP waits only until ARM has accepted it (up to 10 minutes), because the edge machine PUTs run until the machines provision; progress is then followed on the edge machines. | **Used by ZTP**, only with `-Execute`. |
| `Get-AzResourceGroupDeployment` | Reads the deployment record to see that it was accepted and has not failed. | **Used by ZTP**. |

A re-run does not re-claim a machine that already has an edge machine: the script reads each `edgeMachines/{name}` first and claims only the missing ones.

### Edge machines

`Microsoft.AzureStackHCI/edgeMachines`, api-version `2026-10-01` (stable). Earlier versions are previews from `2025-12-01-preview`; `2026-10-15-preview` exists and ZTP does not use it.

| Call | What it does | Evidence |
| --- | --- | --- |
| `PUT {rg}/providers/Microsoft.AzureStackHCI/edgeMachines/{name}` (through the Bicep deployment) | Claims the machine. | **Used by ZTP**, proven live. |
| `GET {rg}/providers/Microsoft.AzureStackHCI/edgeMachines/{name}` | Reads one machine: lifecycle, stages, job state, Arc machine, the extensions the machine reports. A 404 means "not there yet". | **Used by ZTP** (Azure, Ready, Handoff; `Wait-ZtpMachineReady.ps1`, `Update-ArcMachineNames.ps1`, `New-ZtpHandoff.ps1`), proven live. |
| `GET .../edgeMachines` (list) | Lists the machines in a resource group. | **Not made by ZTP**; [Sonar](https://azurelocal.cloud/azurelocal-sonar/) reads it. |
| `DELETE .../edgeMachines/{name}` | Removes the edge machine. | **Not made by ZTP**; a re-claim after removal is a manual step. |

**The claim body** (from `main.bicep`, as the template sends it; `static_method: device`, the default, sends no Manual adapter):

```json
{
  "location": "eastus",
  "identity": { "type": "SystemAssigned" },
  "properties": {
    "arcMachineResourceGroupId": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/AzLocal-ManagedResources-rg-example-0000",
    "arcMachineResourceId": "<managed resource group>/providers/Microsoft.HybridCompute/machines/node-01",
    "siteDetails": {
      "siteResourceId": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.Edge/sites/site-example",
      "deviceConfiguration": { "hostName": "node-01" }
    },
    "ownershipVoucherDetails": { "ownerKeyType": "MicrosoftManaged", "ownershipVoucher": "<base64 of the voucher .pem, in memory only>" },
    "provisioningDetails": {
      "osProfile": { "osType": "HCI", "vsrVersion": "12.2609.1003.7" },
      "userDetails": [ { "userName": "administrator", "secretType": "KeyVault",
        "secretLocation": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-sec/providers/Microsoft.KeyVault/vaults/kv-example/secrets/provisioning-admin" } ]
    }
  }
}
```

- `secretLocation` is the Key Vault secret's **ARM resource ID**. The service rejects the `https://` secret URI.
- `arcMachineResourceId` names the Arc machine, but **in our runs (2026-11) the service overwrote it** at claim time: the Arc machines came out as `ROE1-<id>` and then `<device-id>-1`. ZTP sends it anyway and the handoff reads the name the service really used. See [the host name and the Arc resource name](./configurator-app-api.md#the-host-name-and-the-arc-resource-name).
- With `static_method: site`, a static management address goes per machine in `siteDetails.deviceConfiguration.network.networkAdapters[]`, keyed by the port's MAC: `{ ipAssignmentType: "Manual", macAddress, adapterName, ipAddress, subnetMask, gateway, dnsAddressArray, vlanId (string) }`. **Observed once** (Dell AX-760): the OS install ignores a Manual adapter's MAC and puts the address on the first ready port, a ConnectX port in that run. That is why the default is the Device stage.
- For `dhcp` and `preconfigured` nodes the `networkAdapters` entry is left out, not sent as `Automatic`: `Automatic` is what the service applies to every port without an entry.

**What a provisioned machine returns** (the properties ZTP reads, from a recorded response with documentation values):

```json
{
  "name": "node-01",
  "properties": {
    "provisioningState": "Succeeded",
    "machineState": "Purposed",
    "connectivityStatus": "Connected",
    "arcMachineResourceId": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.HybridCompute/machines/00000000-0000-0000-0000-000000000000-1",
    "lifecycleDetails": {
      "lifecycleStatus": { "status": "Provisioned", "message": "Machine has been successfully provisioned." },
      "lifecycleStages": [
        { "name": "ProvisionMachine", "status": "Completed",
          "subStages": [ { "name": "RegisterMachine" }, { "name": "ArcEnableMaintenanceEnvironment" }, { "name": "InstallExtensions" } ] },
        { "name": "InstallOs", "status": "Completed",
          "subStages": [ { "name": "Initialize" }, { "name": "DownloadOs" }, { "name": "PrepareOs" }, { "name": "RebootOs" }, { "name": "InstallExtensions" }, { "name": "Finalize" } ] }
      ]
    },
    "operationDetails": [ { "name": "ProvisionOs", "type": "ProvisionOs", "status": "Succeeded" } ],
    "reportedProperties": {
      "extensionProfile": { "extensions": [
        { "extensionResourceId": ".../machines/<arc>/extensions/AzureEdgeDeviceManagement", "state": "Succeeded" },
        { "extensionResourceId": ".../machines/<arc>/extensions/AzureEdgeLifecycleManager", "state": "Succeeded" },
        { "extensionResourceId": ".../machines/<arc>/extensions/AzureEdgeRemoteSupport", "state": "Succeeded" },
        { "extensionResourceId": ".../machines/<arc>/extensions/AzureEdgeTelemetryAndDiagnostics", "state": "Succeeded" } ] }
    }
  }
}
```

**How ZTP decides "ready to cluster"** (`Get-ZtpEdgeMachineStatus`): all of these hold: lifecycle `Provisioned`; the `ProvisionOs` job status `DeploymentSuccess` (or, before the job is readable, the `ProvisionOs` entry of `operationDetails` is `Succeeded`); `connectivityStatus` `Connected`; an `arcMachineResourceId`; the four mandatory extensions `Succeeded`; and no failure in any stage, sub-stage, job step or provisioning state. The lifecycle seen on live runs is `Creating`, `AwaitingConnection`, `Provisioning`, `ReadyForOs`, `InstallingOs`, `Provisioned`; the sequence is **Observed**, not documented by Learn (its `machineState` enum differs).

Other documented properties ZTP does not set or read: `machineState` values `Created`, `Preparing`, `Registering`, `Transitioning`, `Purposed`, `Unpurposed`, `Resetting`, `Updating`, `Failed` (**Read from Microsoft docs**, [Learn template reference](https://learn.microsoft.com/azure/templates/microsoft.azurestackhci/2026-10-01/edgemachines)). `Failed` means the only way to recover is to provision the machine again.

### Jobs: ProvisionOs

| Call | What it does | Evidence |
| --- | --- | --- |
| `GET {edgeMachine}/jobs/ProvisionOs` | Reads the OS-install job: `status`, `provisioningState`, `startTimeUtc`, `endTimeUtc`, `error`, `reportedProperties.deploymentStatus` with its `steps`. The service creates the job at claim time; before that the GET answers 404 or 409 (**Observed**, 2026-11), and ZTP treats both as "not there yet". | **Used by ZTP**, proven live. |
| `PUT {edgeMachine}/jobs/ProvisionOs` | Resubmits a failed install (the retry). ZTP does this once by default (`retry_provision_os`), and waits 10 minutes for the service to restart the job. | **Used by ZTP**, proven live; the retry is the article [Troubleshoot simplified machine provisioning](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning?view=azloc-2610). |
| `PUT .../jobs/DownloadOs`, `.../jobs/CollectLog`, `.../jobs/RemoteSupport` | Other job types: `DownloadOs`; `CollectLog` (`fromDate`, `toDate`); `RemoteSupport` (`accessLevel`, `expirationTimestamp`, `type`). | **Read from Microsoft docs** (schema only); **not run by us**. |
| `PUT .../jobs/ProvisionOs` with `osProfile.operationType` `Reset` or `ReImage` | Resets or reinstalls the OS. The enum is `Provision`, `ReImage`, `Reset`, `Update`. | **Read from Microsoft docs** (enum only); **not run by us**. |

**The retry body** (`Get-ZtpProvisionOsRetryBody`, the shape of Microsoft's troubleshooting article):

```json
{
  "properties": {
    "jobType": "ProvisionOs",
    "provisioningRequest": {
      "osProfile": { "osType": "HCI", "vsrVersion": "12.2609.1003.7" },
      "userDetails": [ { "userName": "administrator", "secretType": "KeyVault",
        "secretLocation": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-sec/providers/Microsoft.KeyVault/vaults/kv-example/secrets/provisioning-admin" } ],
      "target": "HCI"
    }
  }
}
```

`osProfile` and `userDetails` are copied from the edge machine's `provisioningDetails`. If the machine does not return `secretLocation`, ZTP uses the secret ARM ID it computed.

**What the job returns** (recorded response, abridged): `properties.jobType` `ProvisionOs`; `deploymentMode` `Deploy`; `provisioningRequest` with `deviceConfiguration.hostName`, `onboardingConfiguration` {`type` `HybridComputeMachine`, `resourceId`, `arcVirtualMachineId`, `location`, `tenantId`}, `osProfile` {`operationType` `Provision`, `osImageLocation`, `osType`, `vsrVersion`}, `target` `HCI`, `userDetails`; `provisioningState`; `reportedProperties.deploymentStatus` {`status`, `steps[]` with `name`, `description`, `status`, `startTimeUtc`, `endTimeUtc`, `percentComplete`}. Job `status` values: `NotSpecified`, `ValidationInProgress`, `ValidationSuccess`, `ValidationFailed`, `DeploymentInProgress`, `DeploymentFailed`, `DeploymentSuccess`, `Succeeded`, `Failed`, `Canceled`, `Paused`, `Scheduled` (**Read from Microsoft docs**).

After a resubmit, Azure keeps the earlier attempt's error in `properties.error` while the new attempt runs and after it succeeds, so read `status`, not that field alone.

### Network adapters and ApplyConfiguration

`edgeMachines/{machine}/networkAdapters` exists after the OS install: `properties.networkConfiguration` is the desired configuration and `properties.reportedProperties` is what the machine reports (the same fields plus `macAddress`, `interfaceDescription` and `componentId`).

| Call | What it does | Evidence |
| --- | --- | --- |
| `GET {edgeMachine}/networkAdapters` (`2026-10-01`) | Lists the machine's NICs, with the MAC as 12 lower-case hex digits. The Network stage finds the management port by that MAC and compares what it reports with the file, by management-address mode. The Handoff stage reads it too. Read-only. | **Used by ZTP** (`Set-ZtpManagementAddress.ps1`, `New-ZtpHandoff.ps1`), proven live. The shape is also Microsoft's spec example `EdgeMachineNetworkAdapters_List`. |
| `GET {edgeMachine}/networkAdapters/{name}/jobs/ApplyConfiguration` | Reads a network job. | **Used by ZTP**, only with `-ApplyThroughAzure`. |
| `PUT {edgeMachine}/networkAdapters/{name}/jobs/ApplyConfiguration` | Changes one NIC from Azure. | **Used by ZTP** only with `-ApplyThroughAzure` (opt-in). **Observed once, twice:** on 2026-11-07, on two runs (Dell AX-760, build 2610), the PUT returned HTTP 201 and then stayed at `DeploymentInProgress` with `ApplyConfiguration` `NotStarted`, message "Job is not yet triggered as other jobs are still running"; Azure marked it `Failed` after about 35 minutes. It never ran. That is an observation of two runs, not a statement that the job never works. |

The request body ZTP sends with `-ApplyThroughAzure` (static, then a Dhcp release of any other adapter that holds the address):

```json
{
  "properties": {
    "jobType": "ApplyConfiguration",
    "deploymentMode": "Deploy",
    "targetConfiguration": {
      "adapterName": "Port1",
      "ipInterfaceType": "Static",
      "ip4Address": "192.0.2.11",
      "subnetMask": "255.255.255.0",
      "defaultGateway": "192.0.2.1",
      "dnsServers": [ "192.0.2.53" ],
      "vlanId": 0,
      "interfaceState": "up"
    }
  }
}
```

A release uses `ipInterfaceType` `Dhcp`, an empty `dnsServers`, and the adapter's reported `vlanId` and `interfaceState`.

**Why the Network stage is verify-only by default.** The Device stage sets a static address by MAC in the maintenance environment and that works, but Microsoft's OS install then resets every port to DHCP (the maintenance environment's network settings do not carry into the OS; Dell AX-760, build 2610, 2026-11-07). Azure's `ApplyConfiguration` did not start on two runs, so the stage reports and defers the static address to OS configuration (the toolkit's `Set-AzureLocalNodeConfiguration.ps1`, over Arc Run Command, by MAC).

### Arc machines and extensions

| Call | What it does | Evidence |
| --- | --- | --- |
| `Get-AzConnectedMachine` (list in a resource group, and by name) | Reads the Arc machine: `Status` (must be `Connected`), `LastStatusChange`, `OSName`. After the BIOS restore, ZTP uses `LastStatusChange` to require that the machine connected again after the restart. The api-version is the module's choice, not ZTP's. | **Used by ZTP** (`Test-ProvisionedMachines.ps1`, in Ready and Restore), proven live. The cmdlet is `GET Microsoft.HybridCompute/machines`. |
| `Get-AzConnectedMachineExtension` | Lists the machine's extensions. The four mandatory ones, `AzureEdgeDeviceManagement`, `AzureEdgeLifecycleManager`, `AzureEdgeRemoteSupport`, `AzureEdgeTelemetryAndDiagnostics`, must have `ProvisioningState` `Succeeded`. | **Used by ZTP** (`Test-ProvisionedMachines.ps1`). The cmdlet is `GET Microsoft.HybridCompute/machines/{name}/extensions`. |
| `GET {arcMachineResourceId}` | Reads one Arc machine directly, with `properties.status`, `lastStatusChange`, agent version, and `networkProfile.networkInterfaces[]` (with `macAddress` and `ipAddresses`), which is where to find the DHCP address the OS took when the node does not answer on the address the file gives it. | **Not made by ZTP** as a direct call; `ZtpAzure.Common.ps1` has a helper that reads this shape (`Get-ZtpArcMachineAddress`), and no stage calls it today. [Sonar](https://azurelocal.cloud/azurelocal-sonar/) reads it at `2026-07-15`. |
| `PUT .../machines/{name}/runCommands/{command}` (`2024-11-10-preview` in the Learn examples) | Runs a script on the Arc machine through the Connected Machine agent. | **Read from Microsoft docs**; **not made by ZTP**. Needs agent 1.33+ and `runCommands/write` (*Azure Connected Machine Resource Administrator* or higher). It is a preview, not in the portal, and `instanceView` output is capped at the last 4 KB. The toolkit's OS configuration uses it; ZTP ends before that. |
| `az ssh arc` (Az.Ssh) | SSH to an Arc machine without a public address. | **Read from Microsoft docs**; **not made by ZTP**. Needs *Owner* or *Contributor* on the Arc machine, agent 1.31+, `sshd` on the node, `Microsoft.HybridConnectivity` registered; setup PUTs HybridConnectivity resources. |

ZTP never writes to an Arc machine or to its extensions.

### Key Vault and the resource group

| Call | What it does | Evidence |
| --- | --- | --- |
| `Get-AzKeyVaultSecret` | Reads the BMC login, the `edgeuser` password when one is named, and (in the Azure stage) whether the provisioning administrator secret exists. The value stays in memory as a `SecureString`. | **Used by ZTP** (`Invoke-ZtpEnvironment.ps1`, `Invoke-ZtpAzureProvisioning.ps1`). |
| `Set-AzKeyVaultSecret` | Writes the provisioning administrator secret, the same shape as the portal's (the password as the value, no content type, no expiry, no tags), but only when it is missing and `-AdminPassword` was passed. | **Used by ZTP**, only with `-Execute`. |
| `Get-AzResourceGroup`, `New-AzResourceGroup` | Reads the resource group and creates it when `provisioning.simplified.create_resource_group` is true (the default). | **Used by ZTP** (`Invoke-ZtpEnvironment.ps1`), only with `-Execute` for the create. |
| `Set-AzContext`, `Get-AzContext` | Selects the tenant and subscription for the process only (`-Scope Process`). | **Used by ZTP**. |

### Reads ZTP does not make

These are Azure reads the companion monitor [Sonar](https://azurelocal.cloud/azurelocal-sonar/) makes, all `GET`s through `Invoke-AzRestMethod`. ZTP does not. They are listed because they show what Azure reports about a deployment, and they follow the same shapes as the calls above.

| Resource | Path (after `{rg}`) | api-version | What it gives |
| --- | --- | --- | --- |
| Cluster deployment settings | `/providers/Microsoft.AzureStackHCI/clusters/{cluster}/deploymentSettings/default` | `2026-10-01` (`2025-10-01` as a fallback) | Validation and deployment step trees, mode, provisioning state. |
| Edge machines (list) | `/providers/Microsoft.AzureStackHCI/edgeMachines` | `2026-10-01` | All machines of the resource group in one call. |
| Arc machine | `/providers/Microsoft.HybridCompute/machines/{name}` | `2026-07-15` | Arc status, last status change, agent version, registration time. |
| Arc machine extensions | `{arcMachineId}/extensions` | `2026-07-15` | The four mandatory extensions. |
| Running ARM deployments | `/providers/Microsoft.Resources/deployments/?$filter=provisioningState eq 'Running'` | `2021-04-01` | Which deployment is running now. |
| Update summary, updates, update runs | `/providers/Microsoft.AzureStackHCI/clusters/{cluster}/updateSummaries/default`, `.../updates`, `.../updates/{name}/updateRuns` | `2026-10-01` | The update track of a deployed cluster. |

ZTP makes no Azure Resource Graph query and no Activity Log read. It reads state by resource, with the `GET`s above, and decides from the edge machine and its job.

## Redfish on the BMC

ZTP talks to the BMC with `Invoke-RestMethod` over HTTPS (`ZtpRedfish.Common.ps1`): `GET`, `POST`, `PATCH` and `DELETE`, up to three attempts for HTTP 429, 502, 503, 504 and timeouts, an error that names the method, path and status but never the body. The BMC is found by `redfish/v1/Managers` and `redfish/v1/Systems` (the first member, or the one named in the OEM profile), and the OEM profile in `config/oem/dell.json` names the Dell identifiers (`iDRAC.Embedded.1`, `System.Embedded.1`, the `RemovableDisk` slot, the log services).

The calls below were **proven live on Dell AX-760 with iDRAC 7.30** unless a row says otherwise. HPE, Lenovo and Supermicro profiles exist in `config/oem/` and their log paths and message patterns are **unverified**.

### Session

| Call | What it does | Evidence |
| --- | --- | --- |
| `POST /redfish/v1/SessionService/Sessions` with `{ "UserName": "...", "Password": "..." }` | Opens a session; the `X-Auth-Token` response header is sent on every later call. If the BMC refuses, ZTP falls back to HTTP Basic. | **Used by ZTP** (`New-ZtpRedfishSession`). |
| `GET /redfish/v1` | Proves the service answers. | **Used by ZTP**. |
| `DELETE {session location}` | Closes the session, best effort, never throws. | **Used by ZTP** (`Remove-ZtpRedfishSession`). |

### BIOS attributes and pending settings

| Call | What it does | Evidence |
| --- | --- | --- |
| `GET /redfish/v1/Systems/{id}/Bios` | Reads the current attributes and the pointer to the attribute registry (`@Redfish.AttributeRegistry`) and to the settings object (`@Redfish.Settings`). Read-only. | **Used by ZTP** (`Set-ZtpBios.ps1`, `Start-MaintenanceBoot.ps1`, `Restore-ZtpBios.ps1`). |
| `GET /redfish/v1/Registries/{id}`, then the registry document it locates | Reads the allowed values of each enumeration attribute, so ZTP can refuse a value the BMC does not allow before changing anything. If the registry cannot be read, the check fails open with a warning. | **Used by ZTP** (`Get-ZtpBiosAllowedValue`). |
| `GET /redfish/v1/Systems/{id}/Bios/Settings` | Reads the pending settings. A value already pending (an earlier run stopped before the reset) is not sent again, because the BMC refuses a second job. | **Used by ZTP**. |
| `PATCH /redfish/v1/Systems/{id}/Bios/Settings` | Stages BIOS attributes to apply on the next reset. | **Used by ZTP**. |

The BIOS change is **staged, then applied at a reset**:

```json
{ "Attributes": { "Slot2": "Disabled" }, "@Redfish.SettingsApplyTime": { "ApplyTime": "OnReset" } }
```

After the reset ZTP reads `Bios` until the attributes report the new values (default timeout `bios_minutes`, 30). The original value of every attribute ZTP changes is written to the evidence first, so Restore can set it back. Attribute names are case-sensitive; read them from `/redfish/v1/Systems/<id>/Bios`. On Dell, PCIe slot *n* is `Slot<n>` (`Enabled`, `Disabled`, `BootDriverDisabled`), and the onboard NICs are `EmbNic1Nic2` (ships as `DisabledOs`).

### Virtual media

| Call | What it does | Evidence |
| --- | --- | --- |
| `GET /redfish/v1/Managers/{id}/VirtualMedia` and each member | Finds the slot whose `MediaTypes` contains `USBStick` (iDRAC: `RemovableDisk`) and reads `Inserted`, `Image`, `WriteProtected`. | **Used by ZTP** (`Mount-ZtpVirtualUsb.ps1`, `Wait-ZtpBootstrapComplete.ps1`, reads). |
| `POST {slot}/Actions/VirtualMedia.InsertMedia` | Attaches the node's image from the SMB share. | **Used by ZTP**. |
| `POST {slot}/Actions/VirtualMedia.EjectMedia` | Detaches the image. | **Used by ZTP**. |

The insert body (the share password is removed from the in-memory body after the call):

```json
{ "Image": "//192.0.2.10/ztp-virtual-usb/ztp-node-01.img", "Inserted": true, "TransferProtocolType": "CIFS",
  "WriteProtected": false, "UserName": "<share user>", "Password": "<share password>" }
```

iDRAC 7.30 quirks, all **Observed** and handled in the script:

- It rejects `WriteProtected: false` in `InsertMedia` (`IDRAC.2.9.SYS458`); ZTP leaves it out and sets the RFS attribute instead (below).
- It accepts `InsertMedia` before it has opened the share, so ZTP reads the slot back and requires `Inserted`, the image name, and the write protection to match.
- `EjectMedia` can return HTTP 500 (`VRM0010`) just after the node writes to the image; ZTP retries up to 6 times, 30 seconds apart.
- It reports `WriteProtected` even when the RFS attribute is `Read Write` and the share is open for write; the voucher found in the image is the real proof of write access.

### Boot override, power and reset

| Call | What it does | Evidence |
| --- | --- | --- |
| `GET /redfish/v1/Systems/{id}` | Reads `PowerState`, and `Boot.BootSourceOverrideEnabled`, `BootSourceOverrideTarget` and its allowable values. | **Used by ZTP**. |
| `PATCH /redfish/v1/Systems/{id}` with `{ "Boot": { "BootSourceOverrideEnabled": "Once", "BootSourceOverrideTarget": "Usb" } }` | One-time boot from the virtual USB slot. | **Used by ZTP** when `Usb` is an allowed target. |
| `PATCH /redfish/v1/Systems/{id}` with `Floppy` as the target | One-time boot on iDRAC 7.30, whose USB-stick slot boots as virtual floppy and which does not offer `Usb`. ZTP then does not reset until the system reports `Once/Floppy`. | **Used by ZTP**, proven live (iDRAC 7.30). |
| `POST /redfish/v1/Systems/{id}/Actions/ComputerSystem.Reset` with `{ "ResetType": "ForceRestart" }` or `"On"` | Restarts (or powers on) the machine to apply a BIOS change or to boot the image. `On` when the power state is `Off`, otherwise `ForceRestart`. | **Used by ZTP**. |

### Manager attributes: the RFS write-protection attribute

| Call | What it does | Evidence |
| --- | --- | --- |
| `GET /redfish/v1/Managers/{id}/Attributes` | Finds the `RFS.<n>.WriteProtected` attributes. | **Used by ZTP**. |
| `PATCH /redfish/v1/Managers/{id}/Attributes` with `{ "Attributes": { "RFS.1.WriteProtected": "Read Write" } }` | Makes the remote file share writable so the maintenance environment can write its voucher back; set back to `Read Only` on eject. | **Used by ZTP** (`-RfsWriteAttribute`, default on for Dell). |
| `PATCH /redfish/v1/Managers/{id}/Attributes` with `{ "Attributes": { "ServerBoot.1.BootOnce": "Enabled", "ServerBoot.1.FirstBootDevice": "vFDD" } }` | The iDRAC-specific one-time boot to the virtual floppy. The iDRAC applies it in the background, so ZTP also sets the standard override and waits for it. A reset before it lands boots the disk instead (**Observed** on a second node, 2026-11-05). | **Used by ZTP**, proven live. |

### Log services

| Call | What it does | Evidence |
| --- | --- | --- |
| `GET /redfish/v1/Managers/{id}/LogServices/Lclog/Entries?$top=25` | After the restart, ZTP watches the Lifecycle log for 10 minutes for `OSE1002` ("C: boot completed"), which iDRAC logs when the installed Windows starts its service module. The maintenance environment does not run it, so the entry means the machine booted its installed OS, and ZTP stops. A BMC without `Lclog` gives a warning and the check is skipped. | **Used by ZTP** (`Mount-ZtpVirtualUsb.ps1`). |
| `GET .../LogServices/{Lclog,Sel}/Entries` | The Bootstrap stage reads new entries and matches them against the OEM signal patterns (booted from media, completion, reset). | **Used by ZTP** (`Get-ZtpBmcReading`). The Dell paths are Dell conventions: `signalsStatus` in the profile says **unverified against the maintenance environment**. |

### Redfish calls ZTP does not make

| Call | What it would do | Evidence |
| --- | --- | --- |
| `GET /redfish/v1/UpdateService/FirmwareInventory` | Lists firmware versions of the BIOS, BMC, NICs and storage controllers. | **Not made by ZTP.** A standard Redfish resource; ZTP has no evidence of how iDRAC 7.30 answers it. |
| `POST /redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate` | Updates firmware from a URI. | **Not made by ZTP**; firmware is out of scope. |
| `GET /redfish/v1/Systems/{id}/Storage`, `.../EthernetInterfaces`, `/Chassis/{id}/NetworkAdapters` | Reads storage controllers, NIC ports and their MACs. | **Not made by ZTP**: the MACs come from the environment file, and the node inventory scripts under `scripts/common/discovery/` are separate tools. |
| `POST /redfish/v1/Systems/{id}/Actions/ComputerSystem.Reset` with `GracefulShutdown`, `PushPowerButton` | Other reset types. | **Not made by ZTP**: it uses `On` and `ForceRestart` only. |
| `DELETE`/`POST /redfish/v1/Managers/{id}/Actions/Manager.Reset` | Resets the BMC. | **Not made by ZTP**; `Reset-iDRAC.ps1` in `scripts/common/utilities/tools/` is a separate tool. |

## The Configurator app REST service

The maintenance environment runs the Configurator app's service: `https://<maintenance address>:20001/BootstrapOobeService/<Operation>`, HTTP Basic as `edgeuser`, a self-signed certificate. It has 45 operations. ZTP calls three:

| Operation | Method | Used for | Evidence |
| --- | --- | --- | --- |
| `GetNetworkAdapters` | GET | Find the node by its management MAC in a scan of TCP 20001, and read every port. | **Used by ZTP**, proven live. |
| `SetArcBootstrapDeviceConfiguration` | POST | Set the static management address on the port with the management MAC. | **Used by ZTP**, proven live. |
| `GetArcBootstrapDeviceConfigurationStatus` | GET | Follow the change until it reports success. | **Used by ZTP**, proven live. |

The service refuses the Arc onboarding configuration in the maintenance environment (`ArcConfigurationNotSupportedOnRoe`), so Arc registration is always done by Azure during `ProvisionOs`. The full list of operations, request and response shapes, the evidence behind each, and what is not possible is in [Appendix B](./configurator-app-api.md).

## Plain HTTP downloads

| Call | What it does | Evidence |
| --- | --- | --- |
| `HEAD https://aka.ms/aep/installeros/<YYMM>` (no redirects) | A published month redirects to a blob on a Microsoft download host; an unpublished month redirects to a search page and is ignored. "Latest" is the highest published train whose month is 01 to 12 and not after the current month. | **Used by ZTP** (`Get-ZtpBootstrapIso.ps1`). |
| `GET` on the download URL with `Range` | Downloads the maintenance zip with resume, then checks the zip, extracts `provision-os.iso` and checks the ISO 9660 signature. | **Used by ZTP**. Only `https` on a Microsoft download host is accepted, checked again after redirects. |

Microsoft publishes no hash for this download. ZTP records the first good download in a trust-on-first-use manifest and refuses a later download of the same version whose hash differs. See [Bootstrap media](../bootstrap-media.md).

## What is possible, in one view

| What you want | The call | Family | Changes? | Evidence |
| --- | --- | --- | --- | --- |
| Check the subscription can claim a voucher | Feature `AzureLocalZTP` and the four providers | ARM | Read | **Used by ZTP** |
| Pick the OS build | `locations/{loc}/osImages?solution-type=HCI` | ARM | Read | **Used by ZTP** |
| Create the site and its settings | Bicep: `Microsoft.Edge/sites`, `configurations` and children | ARM | Changes | **Used by ZTP** |
| Claim a machine with its voucher | `edgeMachines` PUT through Bicep | ARM | Changes | **Used by ZTP** |
| Follow the install | `edgeMachines/{m}`, `jobs/ProvisionOs` | ARM | Read | **Used by ZTP** |
| Retry a failed install | `PUT jobs/ProvisionOs` | ARM | Changes | **Used by ZTP** |
| Read the machine's NICs after the install | `edgeMachines/{m}/networkAdapters` | ARM | Read | **Used by ZTP** |
| Change a NIC from Azure | `networkAdapters/{n}/jobs/ApplyConfiguration` | ARM | Changes | **Used by ZTP** (opt-in); **Observed** not to run, twice |
| Check the Arc machine and its extensions | `Get-AzConnectedMachine`, `Get-AzConnectedMachineExtension` | Az module | Read | **Used by ZTP** |
| Run a script on the machine | Arc `runCommands` | ARM | Changes | **Read from Microsoft docs**; not made by ZTP |
| Collect logs, reset or reinstall the OS | `jobs/CollectLog`, `jobs/ProvisionOs` with `Reset` or `ReImage` | ARM | Changes | **Read from Microsoft docs**; not run |
| Change a BIOS value | `Bios/Settings` PATCH, then `ComputerSystem.Reset` | Redfish | Changes | **Used by ZTP** |
| Boot the machine from a virtual USB | `VirtualMedia.InsertMedia`, boot override, reset | Redfish | Changes | **Used by ZTP** |
| See what the BMC logged | `LogServices/{Lclog,Sel}/Entries` | Redfish | Read | **Used by ZTP** |
| Find a node in the maintenance environment by MAC | `GetNetworkAdapters` on each address that answers on 20001 | Configurator | Read | **Used by ZTP** |
| Set a static address in the maintenance environment | `SetArcBootstrapDeviceConfiguration` | Configurator | Changes | **Used by ZTP** |
| Register in Arc from the maintenance environment | `ArcConfiguration` | Configurator | n/a | **Refused** by the service (`ArcConfigurationNotSupportedOnRoe`) |
| Read firmware versions | `UpdateService/FirmwareInventory` | Redfish | Read | **Not made by ZTP** |

## Calls ZTP does not make but could

Everything below is possible and carries no ZTP evidence:

- **Arc side:** `runCommands` and `az ssh arc` on a provisioned machine; reading extension state directly with `GET .../extensions` instead of the Az cmdlet; removing or reinstalling extensions.
- **Edge machine:** `GET .../edgeMachines` as a list; `DELETE` of an edge machine; the `CollectLog`, `DownloadOs` and `RemoteSupport` jobs; `ProvisionOs` with `operationType` `Reset` or `ReImage`; setting `onboardingConfiguration.resourceId` by writing the job yourself (**not tried**, and not proven to be honoured: the service overwrote the name in every run).
- **Azure-wide reads:** Azure Resource Graph queries across the subscription; the Activity Log of the resource group for failed operations; `Microsoft.Resources/deployments` operations for a deployment that failed. ZTP names the Deployments blade in its error and reads nothing more.
- **BMC:** firmware inventory and update; storage and NIC inventory; other reset types; BMC reset. See [Redfish calls ZTP does not make](#redfish-calls-ztp-does-not-make).
- **Configurator service:** the other 42 operations of the 45 (reset, diagnostics, support logs, updates, sideload, volumes, power, password). ZTP calls three, and the rest are known only from the service's metadata, marked **not called** in [Appendix B](./configurator-app-api.md).

## Sources

- ZTP scripts (this repository): `scripts/simplified-provisioning/ZtpAzure.Common.ps1`, `Invoke-ZtpAzureProvisioning.ps1`, `Wait-ZtpMachineReady.ps1`, `Update-ArcMachineNames.ps1`, `Test-ProvisionedMachines.ps1`, `Set-ZtpManagementAddress.ps1`, `New-ZtpHandoff.ps1`, `ZtpEvents.Common.ps1`, `bicep/main.bicep`; `ZtpRedfish.Common.ps1`, `ZtpBios.Common.ps1`, `Set-ZtpBios.ps1`, `Restore-ZtpBios.ps1`, `Mount-ZtpVirtualUsb.ps1`, `Wait-ZtpBootstrapComplete.ps1`, `config/oem/dell.json`; `Set-ZtpDeviceConfiguration.ps1`; `Get-ZtpBootstrapIso.ps1`. The recorded responses in `tests/simplified-provisioning/fixtures/`.
- Reads of the companion monitor Sonar: its Azure `GET` list (clusters, update resources, Arc machines, deployments).
- Microsoft Learn: [Install the operating system and register Azure Local machines by using simplified machine provisioning](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning?view=azloc-2610), [Troubleshoot simplified machine provisioning](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning?view=azloc-2610), the [`edgeMachines` and `jobs` template reference](https://learn.microsoft.com/azure/templates/microsoft.azurestackhci/2026-10-01/edgemachines/jobs#property-values), and the Arc [run command](https://learn.microsoft.com/azure/azure-arc/servers/run-command) and [SSH](https://learn.microsoft.com/azure/azure-arc/servers/ssh-arc-overview) pages.
- The Configurator service: [Appendix B](./configurator-app-api.md).
