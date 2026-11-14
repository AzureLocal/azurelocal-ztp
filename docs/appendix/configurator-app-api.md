# Appendix B: The Azure Local Configurator app API

This appendix lists and explains every call of the interface that Microsoft's **Configurator app** uses to configure an Azure Local machine, in the maintenance environment and after the operating system is installed. It also covers what the Azure portal does through Azure for the same machines, so you can see the whole of what is possible.

ZTP is the tool that drives this service: its Device stage calls three of the 45 operations in the maintenance environment. The other calls ZTP makes (Azure Resource Manager, Redfish on the BMC) are in [Appendix A: API reference](./api-reference.md); [How ZTP uses this service](#how-ztp-uses-this-service) says which stage calls what.

> **Warning: this is not a published or supported API.**
> The service described here is an internal interface of Microsoft's Configurator app. Microsoft does not document it, does not promise its shape, and can change or remove any operation between builds. Everything below was read from one build (the maintenance image 10.2610.0.3063; see [Which build this describes](#which-build-this-describes)). The supported way to configure a machine is the Configurator app itself, and for provisioning, the Azure portal or the documented Azure resources. Use the calls here for understanding, diagnosis and lab automation at your own risk, never as a dependency you cannot replace. Calls marked **changes the machine** do exactly that.

## How to read this appendix

Every statement carries an **evidence label** so you know how we know:

| Label | Meaning |
| --- | --- |
| **Verified live** | We called it on real hardware (Dell AX-760 machines, 2026-11-07, maintenance image 10.2610.0.3063) and the response is real. Addresses and names are replaced with documentation values (`192.0.2.x`, `198.51.100.x`, MAC `00-00-5E-00-53-xx`). |
| **From the service's own metadata** | Read from the service's compiled data contract (the assemblies the service runs, read with a metadata reader, never executed or called). It says what the service **declares**: operation names, HTTP methods, request and response types, enum values, built-in message texts. It does **not** prove the operation works on a given machine. Every such item below is also marked **not called**. |
| **Documented by Microsoft** | A Microsoft Learn page says so; the link is given. |
| **From Azure-side ZTP evidence** | Seen in this repository's scripts, docs and run logs (Azure calls ZTP makes and what came back). Equivalent to Verified live for the Azure calls it names. |

Where two sources disagree, the page says so ([Conflicts and gaps](#conflicts-and-gaps)) instead of choosing quietly.

## How ZTP uses this service

ZTP calls **3 of the 45 operations**, all in the **Device stage** (`Set-ZtpDeviceConfiguration.ps1`), in the maintenance environment, before the Azure claim. No other stage calls this service.

| Step of the Device stage | Call | What ZTP does with it | Evidence |
| --- | --- | --- | --- |
| Find the node | TCP connect to port 20001, then `GET GetNetworkAdapters` | If the node list gives a `maintenance_address`, that address is used. Otherwise ZTP probes every address of `provisioning_dhcp_range` (default: the management subnet, at most 4096 addresses) on TCP 20001, 256 sockets at a time, repeating every poll interval until every node is found or `device_minutes` (30) passes. Each address that answers is asked `GetNetworkAdapters`, and the node is the one whose adapters include its management MAC (separators and case do not matter). A response without the MAC is ignored: the lease may have gone to another device. | **Verified live** (found by MAC in a .100-.250 scan, Dell AX-760, 2026-11-07) |
| Read the ports | `GET GetNetworkAdapters` | Finds the adapter with the management MAC; no match stops the node and lists the MACs found. An adapter that already reports `EnableDhcp` false with the address, mask, gateway, DNS and VLAN is left alone. | **Verified live** |
| Set the address | `POST SetArcBootstrapDeviceConfiguration` with `{ "Network": { "NetworkAdapters": [ { "MacAddress", "EnableDhcp": false, "IpAddress", "SubnetMask", "Gateway", "DnsAddressArray", "VlanId": 0 } ] } }` | Puts the static management address on the port with the management MAC. **No `HostName` is sent**: the Azure claim sets the host name. | **Verified live** |
| Follow it | `GET GetArcBootstrapDeviceConfigurationStatus`, then `GET GetNetworkAdapters` | Polls until the management adapter reports the static configuration, or `device_minutes` passes. A `Failed` status stops the node. If the changed port is the one the maintenance address is on, the service answers on the new address afterwards, so both are tried. | **Verified live** |

The other stages around it:

- **Media** presets the `edgeuser` password: only its SHA-512 crypt hash enters the image, from `provisioning.simplified.maintenance_password`. This is the password the Device stage then signs in with.
- **Network** (after the OS install) does **not** use this service. The maintenance environment is gone by then; the stage reads Azure's per-NIC report (`edgeMachines/<node>/networkAdapters`). See [Appendix A](./api-reference.md#network-adapters-and-applyconfiguration).
- **Vouchers** can take vouchers that were downloaded with Microsoft's Configurator app (`-VoucherFolder`) instead of reading them from the images. That is the desktop app, not these REST calls.

**How ZTP authenticates.** HTTP Basic as `edgeuser` (setting `provisioning.simplified.maintenance_environment.username`) over TLS on port 20001 (`...maintenance_environment.port`). The password is the one the image was built with (`provisioning.simplified.maintenance_password`, a secret reference read by azurelocal-toolkit's resolver), and without one the maintenance environment's published default, `Password1`. The service's certificate is self-signed and nothing can verify it, so this script, and only this script's calls, skip the certificate check. The password therefore goes to every host that answers on TCP 20001 in the scan range. Scan only an isolated provisioning network, keep `provisioning_dhcp_range` to the DHCP pool, and change the default password when you build the image. See also [Prerequisites](../prerequisites.md) and [Why the certificate check must be skipped](#why-the-certificate-check-must-be-skipped-and-the-risk).

**Checks before anything is sent.** Two nodes with the same static `ip_address`, or an `ip_address` inside a node's own `maintenance_scan_range` (the DHCP pool would lease it out), stop the run. `dhcp`, `dhcp_reservation` and `preconfigured` nodes are only reported, and only when the node list gives their maintenance address.

**What is not possible through this path**

- **Arc registration from the maintenance environment.** The service refuses it with `ArcConfigurationNotSupportedOnRoe` ("Arc configuration is not supported in the provisioning environment. Remove ArcConfiguration from the request and retry."). Azure registers the machine during the `ProvisionOs` job. ZTP never sends `ArcConfiguration`.
- **Choosing the Arc resource name** through the service in the maintenance environment, or through the claim: the service named the Arc machine `<device-id>-1` in every run ([details](#the-host-name-and-the-arc-resource-name)).
- **Releasing an address that another port holds.** Another adapter that already holds the target address statically stops the node before anything is sent; releasing it is not a request shape verified live, so ZTP never sends it.
- **Carrying the address into the OS.** Microsoft's OS install resets every port to DHCP, so the Device stage sets the address for the maintenance environment and the claim, and OS configuration sets the static after ZTP ends.
- **Setting the host name, time server, web proxy or remote-desktop options here.** The fields exist; ZTP sends none.

The calls ZTP makes to Azure and to the BMC are in [Appendix A: API reference](./api-reference.md).

## Contents

- [How ZTP uses this service](#how-ztp-uses-this-service)
- [Quick summary](#quick-summary)
- [Which build this describes](#which-build-this-describes)
- [Reaching the service](#reaching-the-service)
  - [Address, port, protocol](#address-port-protocol)
  - [Signing in](#signing-in)
  - [Why the certificate check must be skipped, and the risk](#why-the-certificate-check-must-be-skipped-and-the-risk)
  - [The local net.tcp endpoint](#the-local-nettcp-endpoint)
  - [Optional request headers](#optional-request-headers)
  - [Setup for the examples](#setup-for-the-examples)
- [Common shapes](#common-shapes)
- [The status model](#the-status-model)
- [Operations](#operations)
  - [Discovery and identity](#discovery-and-identity) (6)
  - [Network](#network) (2)
  - [Device configuration (the maintenance-environment path)](#device-configuration-the-maintenance-environment-path) (2)
  - [Single settings](#single-settings) (6)
  - [Arc bootstrap and registration](#arc-bootstrap-and-registration) (7)
  - [Reset](#reset) (2)
  - [Diagnostics and support logs](#diagnostics-and-support-logs) (6)
  - [Ownership voucher](#ownership-voucher) (1)
  - [Updates](#updates) (4)
  - [Package sideload and file upload](#package-sideload-and-file-upload) (5)
  - [Storage and power](#storage-and-power) (4)
- [Types in the contract that no operation takes](#types-in-the-contract-that-no-operation-takes)
- [The host name and the Arc resource name](#the-host-name-and-the-arc-resource-name)
- [Network configuration semantics](#network-configuration-semantics)
- [Reset: what each reset does](#reset-what-each-reset-does)
- [Logs the app writes, and how to read them](#logs-the-app-writes-and-how-to-read-them)
- [Typical errors](#typical-errors)
- [What the portal does through Azure](#what-the-portal-does-through-azure)
- [What is possible, in one view](#what-is-possible-in-one-view)
- [Not possible or not proven](#not-possible-or-not-proven)
- [Conflicts and gaps](#conflicts-and-gaps)
- [Sources](#sources)

## Quick summary

- The service has **45 operations** (the `IOobeService` contract). We **called 3** of them on real hardware: `GetNetworkAdapters`, `SetArcBootstrapDeviceConfiguration` and `GetArcBootstrapDeviceConfigurationStatus`. A status tree of the `GetArcBootstrapStatus` shape was also captured from a failed run. The other 41 are known **only from the service's metadata** and are marked **not called**.
- It is an HTTPS JSON service on **TCP 20001**, Basic authentication, a self-signed certificate. In the maintenance environment the user is the maintenance environment's local administrator account (`edgeuser`).
- **25 calls only read.** 2 run tests or collect a package (StartArcBootstrapDiagnostics, StartArcBootstrapSupportLogs: they write a report or a file, not configuration). **18 change the machine**, of which several can destroy data or the Arc registration (reset, volume delete, password change, shutdown, restart). Each section says which.
- The maintenance environment **refuses the Arc onboarding configuration** (the service's own message: "Arc configuration is not supported in the provisioning environment. Remove ArcConfiguration from the request and retry."). In the maintenance environment you can set the network, host name, time server, web proxy and remote-desktop options; Arc registration is done by Azure.
- The **Arc resource name** cannot be set through this service in the maintenance environment, and in our runs Azure named the Arc machine `<device-id>-1` regardless of what the claim asked for ([details](#the-host-name-and-the-arc-resource-name)).
- Reset was **never run** by us, through either the service or Azure.

## Which build this describes

| Item | Value | Source |
| --- | --- | --- |
| Maintenance image (ROE) | 10.2610.0.3063 (train 2610, GA) | **From Azure-side ZTP evidence**: the ZTP Resolve stage record (`maintenance ISO 10.2610.0.3063 (GA)`). |
| File version of the five assemblies we read | 10.3544.1.3015 | **From the service's own metadata** (the DLL copies' version resource). |
| Assemblies | `Microsoft.Azure.Edge.Bootstrap.ServiceContract`, `.Common`, `.Core`, `.OOBE`, `Microsoft.Azure.Edge.NodeConfiguration.Linux.RestService` | Copied from a maintenance environment. |

We did not establish how the two version numbers relate (the image version versus the component build). Treat every shape here as true for that image only.

## Reaching the service

### Address, port, protocol

`https://<machine>:20001/BootstrapOobeService/<Operation>`

- JSON in, JSON out, property names in PascalCase (`Content-Type: application/json`). **Verified live** (three operations); the metadata declares JSON for every operation except `DownloadArcBootstrapSupportLogs` and `DownloadOwnershipVoucher`, which return a raw file stream.
- The listener is Kestrel hosting CoreWCF WebHttp: log line `Now listening on: https://[::]:20001`, process `Microsoft.Azure.Edge.NodeConfiguration.Linux.RestService`. **Verified live** (maintenance environment, `ss -ltn` and the service log). All interfaces, so the service answers on every address the machine holds (the maintenance environment takes a DHCP lease on every port).
- There is also a loopback-only listener on 20002, and the service builds its own client URL as `https://localhost:<port>/BootstrapOobeService`. What 20002 is for is not shown by any evidence.
- The URL for every operation is the operation name. The metadata gives an explicit template only for `UploadFile` (`/UploadFile?fileName={fileName}`); the others use the default (the operation name), which is what the three live calls confirm.
- Reaching the machine: by IP address, or by name: `ROE-<serial>.local` ([Documented by Microsoft](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-configurator-app?view=azloc-2610#connection-options)). The Configurator app needs routable local-network access to the machine; Azure does not proxy it (same page).

### Signing in

| Device state | How | Evidence |
| --- | --- | --- |
| Maintenance environment | HTTP Basic, user `edgeuser`, with the maintenance environment's password. Learn documents a **default password** for the maintenance environment: see [Learn: Configurator App credential model](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-configurator-app?view=azloc-2610#credential-model). That password is published; **change it when you build the image** (azurelocal-ztp does this with `provisioning.simplified.maintenance_password`). | **Verified live** (Basic as `edgeuser`); **Documented by Microsoft**. A wrong password gives `401` ([ZTP troubleshooting](https://github.com/AzureLocal/azurelocal-ztp/blob/main/docs/troubleshooting.md)). |
| Installed operating system | Learn says to sign in with the user name and SSH key set during target OS setup. | **Documented by Microsoft** (same page, and [Collect system logs](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-collect-system-logs?view=azloc-2610#choose-the-correct-credentials)). We did not call the REST service on an installed OS, so whether Basic with a password works there is not shown. |

What the service's own code says about authentication (**From the service's own metadata**, **not called**):

- Two schemes exist: `BasicAuthentication`, and an **SSH-certificate** scheme (`asz-configurator-ssh-cert-v1`; token fields `Username`, `Nonce`, `Signature`, `Certificate`) with a challenge route `/api/authentication/ssh-challenge` that takes `{ "Username": ... }`. The HTTP method of that route is not decoded. When the SSH trust anchor cannot be loaded, "every SshCertificate request will be rejected" and the other schemes stay available.
- Basic is checked against the operating system (the message "NPAM authentication failed for user"); on a maintenance-environment ("ROE") device the user must be the configured `EdgeUser` ("User '...' is not the configured EdgeUser '...' on a ROE device."), and must be in an administrator group ("...does not have administrator privileges (expected membership in one of: ...)").

### Why the certificate check must be skipped, and the risk

The service presents a **self-signed certificate that the machine generates for itself** (the contract has certificate generation and export errors). There is no certificate authority and no name you can validate it against, so a normal TLS check always fails. The examples therefore use `-SkipCertificateCheck`.

The risk is that **you cannot tell the machine from an impostor**: anyone who can answer on that address can receive your Basic credential and your request. With the check skipped the password goes to every host that answers on the port. Reduce the risk:

- Use an **isolated provisioning network**, and never scan address ranges that hold other devices with a real password.
- Change the maintenance environment's default password when you build the image.
- Send only to an address you read off the machine's console.
- Do not reuse the maintenance-environment password anywhere else.

### The local net.tcp endpoint

**From the service's own metadata**, **not called**: a client configuration file shipped with the bootstrap management module (`ServiceClient.dll.config`) defines an endpoint `net.tcp://localhost:9098/BootstrapOobeService` for the same `IOobeService` contract: `netTcpBinding`, `transferMode` Streamed, `security mode` Transport with Windows credentials, `protectionLevel` EncryptAndSign, 30-minute send and receive timeouts, `maxReceivedMessageSize` 10 GiB. That is how the local PowerShell cmdlets (`Get-ArcBootstrapStatus` and the others of the `AzureEdgeBootstrap` module) talk to the service on the machine itself. In the same maintenance environment's `ss -ltn` output **nothing listens on 9098** (**Verified live**), so this endpoint is not served there; whether it is served on an installed Azure Stack HCI operating system is not shown by any evidence we have. It is loopback only by its address.

### Optional request headers

**From the service's own metadata**, **not called**: the service reads `Application`, `Version`, `Instance-Id`, `Client-Type`, `Request-Id`, `x-ms-client-request-id`, and any header starting `X-ConfiguratorApp-` or `X-ZTP-`; it logs them (`ZTP Request: ... | CorrelationId: ...`) and returns `x-ms-correlation-request-id`. A flag `IsFromConfigurator` exists. What the service does differently when the headers are present is not shown. Our calls sent none of them and worked.

### Setup for the examples

Every example uses PowerShell 7 and these two variables. The credential comes from `Get-Credential`; never write the password in a script.

```powershell
# The address is on the machine's console. Documentation range used here.
$base = 'https://192.0.2.50:20001/BootstrapOobeService'
$cred = Get-Credential -UserName 'edgeuser' -Message 'Maintenance environment sign-in'
```

`-Authentication Basic` needs HTTPS and a credential, which this has. `-SkipCertificateCheck` is explained above. A fault comes back as an HTTP error: wrap calls in `try`/`catch` and read `$_.ErrorDetails.Message`.

## Common shapes

All **From the service's own metadata** (`ServiceContract.Data`), unless a live example is shown. Types: `String`, `Boolean`, `Int32`, nullable types are marked `?`. Almost every request type also has an `ExtensionData` member (ignored by you) and a `Version` string (the only value in the enum `DataContractVersion` is `V1`).

**`Response`** (the node of every status tree and of the simple replies)

| Field | Type | Meaning |
| --- | --- | --- |
| `Name` | String | The step name ([status model](#the-status-model)). |
| `Description` | String | Free text, usually `null`. |
| `Status` | String | One of the [statuses](#the-status-model). |
| `Message` | String | Human text, for example `TO2 Protocol failed.` |
| `AdditionalData` | Dictionary of String to String | Extra values for the step (keys not documented; `null` in every live response). |
| `PercentComplete` | Int32? | Progress, `null` in every live response. |
| `Errors` | List of `ErrorInfo` | Failures of this step. |
| `DetailedResponse` | List of `Response` | The child steps. |
| `StartTime`, `EndTime` | String (UTC, ISO 8601) | `EndTime` is `null` while a step runs. |

**`ErrorInfo`**: `ErrorMessage`, `StackTrace`, `ExceptionType` (Strings; the last two were `null` in the live failure) and `RecommendedActions` (list of String; live: `["Contact Microsoft Support."]`).

**Wrappers.** Several operations return `{ "Version": "V1", "Response": <Response> }`: that is `BootstrapResponse`, `DeviceConfigurationResponse`, `DeviceCodeAuthenticationResponse`, `UpdateResponse` and `ProvisioningResponse`. **Verified live** for `DeviceConfigurationResponse`. Simple operations (`ConfigureHostName` and so on) return a bare `Response`.

**`NetworkAdapterConfiguration`** (one port)

| Field | Type | Meaning |
| --- | --- | --- |
| `Name` | String | The operating system's name for the port (Linux names in the maintenance environment, for example `eno8303`). |
| `MacAddress` | String | Returned as 12 lower-case hex digits without separators. Send it the same way. **Verified live.** |
| `DriverDescription` | String | Adapter description. When you identify an adapter by description, the message is "Specify the network adapter name or driver description." |
| `PortOrderingScheme` | String | `MacAddress`, `HardwareInfo` or `DeviceDefault` (enum). Meaning not documented. |
| `LogicalIndex` | UInt32 | The port's index. |
| `EnableDhcp` | Boolean | `true` for DHCP, `false` for static. |
| `IpAddress`, `SubnetMask`, `Gateway` | String | IPv4 dotted quad. Validation messages: "IP Address provided is invalid", "Subnet mask provided is invalid", "Gateway provided is invalid". |
| `DnsAddressArray` | String[] | DNS servers. |
| `Ssid`, `Passphrase` | String | Wi-Fi. "SSID is required when Passphrase is specified."; passphrase 8 to 63 characters; "WiFi and VLAN cannot be configured on the same interface." |
| `VlanId` | UInt16? | A number. The validation text says "VLAN ID must be between 1 and 4094." Live, `0` was accepted ([semantics](#network-configuration-semantics)). |

**`NetworkConfiguration`**: `{ "NetworkAdapters": [ NetworkAdapterConfiguration ] }`.

**`HostNameConfiguration`**: `Name` (String), `SkipReboot` (Boolean).

**`TimeConfiguration`**: `PrimaryTimeServer`, `SecondaryTimeServer`, `TimeZoneName` (Strings).

**`WebProxyConfiguration`**: `ConnectionUri` (String), `BypassList` (String[]). "Provide at least one proxy bypass entry when a proxy URL is configured."

**`RemoteConfiguration`**: `RemoteDesktopConnection` (Boolean).

**`ArcMultiServerConfiguration`** (how Arc registration is authorised)

| Field | Meaning |
| --- | --- |
| `SubscriptionId`, `ResourceGroup`, `TenantId`, `Location` | Where the Arc machine goes. Resource group: 1 to 90 characters; tenant must be a GUID; location without spaces (Learn: for example `EastUS`). |
| `Cloud` | `AzureCloud`, `AzureUSGovernment`, `AzureChinaCloud`, `Azure.Local`, `USSEC`, `USNAT`. |
| `ArmAccessToken` | An ARM access token. One of the two supported sign-ins. |
| `AccountId` | The signed-in account. |
| `ServicePrincipalClientId`, `ServicePrincipalSecret` | **No longer supported**: "Service principal authentication is no longer supported. Use device code authentication or an ARM access token." |
| `GatewayId` | The Arc gateway resource ID. |
| `AzureLocalCloudFQDN`, `AuthenticationScope`, `AuthorityHost` | Cloud endpoints; `AuthorityHost` and `AuthenticationScope` must be HTTPS URIs. |

**`ArcConfiguration`**: `SiteKey` (**no longer supported**: "Site key authentication is no longer supported."), `ArcMultiServerConfiguration`, `ArcOnboardingConfiguration` (`ResourceId`, `Location`, `TenantId`, `ArcVirtualMachineId`, `KeyPair`), `ConfigurationContent`. A resource ID must start with `/subscriptions/` and contain no traversal.

**`ConfigurationRequest`** (what `StartArcBootstrap` takes): `Network`, `WebProxy`, `Time`, `HostName`, `RemoteConfiguration`, `ConfigurationIntent` (`User` or `Site`), `ArcConfiguration`, `UpdateConfiguration`, `Storage`, `RequestSource`.

**`DeviceConfigurationRequest`** (what `SetArcBootstrapDeviceConfiguration` takes): `Network`, `WebProxy`, `Time`, `HostName`, `RemoteConfiguration`, `RequestSource`. **It has no `ArcConfiguration`, `UpdateConfiguration` or `Storage`.** That difference is the whole point of the operation: it configures the machine without registering it.

## The status model

`GetArcBootstrapStatus`, `StartArcBootstrap` and `GetArcBootstrapDeviceConfigurationStatus` report a tree of steps. The root is `Bootstrap`.

**Statuses** (**From the service's own metadata**, enum `Status`): `Invalid` (0), `NotStarted` (1), `NotApplicable` (2), `InProgress` (3), `Succeeded` (4), `Failed` (5), `Warning` (6), `RebootPending` (7). **Seen live:** `NotStarted`, `NotApplicable`, `InProgress`, `Succeeded`, `Failed`. Not seen: `Invalid`, `Warning`, `RebootPending`.

**Steps** (enum `Category`, 31 values). The ones seen live in the tree, in order:

| Step | Child of | What it covers | Seen live |
| --- | --- | --- | --- |
| `Bootstrap` | (root) | The whole configuration | yes |
| `NetworkConfig` | Bootstrap | Setting ports (static or DHCP) | yes: `Succeeded` after the live change; `NotApplicable` when no network was sent |
| `RemoteConfig` | Bootstrap | Remote desktop option | yes: `NotApplicable` |
| `WebProxy` | Bootstrap | Proxy settings | yes: went `InProgress` then `Succeeded` about 100 seconds later, with no proxy sent |
| `TimeServer` | Bootstrap | Time server and zone | yes: `NotStarted` then `NotApplicable` |
| `HostName` | Bootstrap | Host name | yes: `NotStarted` then `NotApplicable` (no host name sent) |
| `ArcConfiguration` | Bootstrap | Arc registration as a whole | yes: `Failed` in the TO2 failure |
| `ArtifactsUpload` | ArcConfiguration | Uploading artifacts | yes: `NotApplicable` |
| `ConnectivityValidation` | ArcConfiguration | Checking connectivity before registering | yes: `NotStarted` |
| `ArcRegistration` | ArcConfiguration | Registering the machine with Azure Arc | yes: `Failed` in the TO2 failure |
| `ArcExtensionInstall` | ArcConfiguration | Installing the mandatory Arc extensions | yes: `NotStarted` |
| `LocalArcExtensionEnable` | ArcConfiguration | Enabling the local extensions | yes: `NotStarted` |
| `Provisioning` | Bootstrap | The OS install driven from Azure | yes: `NotStarted` |
| `RoeSetup` | Bootstrap | The maintenance environment's own setup (voucher creation) | yes: `Succeeded` |

The rest of the enum, **not seen in any live tree**: `DeviceAuthentication`, `Diagnostic`, `LogCollection`, `UpdatePassword`, `Update`, `GatewayConfiguration`, `ResetArc`, `ExtensionCleanup`, `GatewayCleanup`, `AzcmAgentCleanup`, `BootstrapCleanup`, `Scan`, `Download`, `Install` (the three children of the `Update` tree), `FileUpload`, `Sideload`, `StorageConfig`. Their names point to the operations that use them (device-code sign-in, diagnostics, support logs, password, zero-day update, gateway, reset and its cleanups, sideload, storage); the mapping is inferred from the names.

**What `SetArcBootstrapDeviceConfiguration` reports** (**Verified live**): a `Bootstrap` root with exactly five children, `NetworkConfig`, `RemoteConfig`, `WebProxy`, `TimeServer`, `HostName`. No `ArcConfiguration`, `Provisioning` or `RoeSetup` there.

**A real tree, a failed run** (**Verified live**, 2026-11-07, maintenance image 10.2610.0.3063; the file records the tree but not which call returned it; its shape is `BootstrapResponse`, the type returned by `GetArcBootstrapStatus`). Times shortened to the second; `AdditionalData`, `Description`, `PercentComplete` are `null` throughout and omitted:

```text
Bootstrap [Failed]  Message: "TO2 Protocol failed."
  Errors: [ { ErrorMessage: "TO2 Protocol failed.", RecommendedActions: ["Contact Microsoft Support."] } ]
  NetworkConfig [NotApplicable]
  RemoteConfig [NotApplicable]
  WebProxy [Succeeded]
  TimeServer [NotApplicable]
  HostName [NotApplicable]
  ArcConfiguration [Failed]  (same error)
    ArtifactsUpload [NotApplicable]
    ConnectivityValidation [NotStarted]
    ArcRegistration [Failed]  (same error, 20 seconds after it started)
    ArcExtensionInstall [NotStarted]
    LocalArcExtensionEnable [NotStarted]
  Provisioning [NotStarted]
  RoeSetup [Succeeded]
```

The TO2 text is the visible end of a longer story in the device log: the machine's call-home to the Azure onboarding service (FIDO Device Onboard, "TO1/TO2") exchanged service-info messages until it hit a limit: `TO2MaxServiceInfoTripsException: Exceeded maximum allowed ServiceInfo exchange round trips on the device.`, reported to the server as error code `TO2_MaxServiceInfoTripsValidationFailure`, then `TO2 Failed, all TO2 Attempts failed with servers.` (**Verified live**, device logs of the same day). We did not establish its cause; the status line alone ("TO2 Protocol failed.") does not tell you. Read the device log (see [Logs](#logs-the-app-writes-and-how-to-read-them)).

## Operations

Conventions in each entry: **Method and URL** (relative to `/BootstrapOobeService`), **What it does**, **Request**, **Response**, **Works in** (ME = maintenance environment, OS = installed Azure Stack HCI operating system), **Changes the machine?**, **Evidence**, **Example**. HTTP method and request/response format are decoded from the contract for every operation (**From the service's own metadata**); where an entry says "not called" it was never invoked by us. "Bare" body means the JSON is the object itself, not wrapped in a name (the contract declares no wrapped body for any operation; the three live calls confirm it).

### Discovery and identity

#### GetDeviceSerialNumber

- **Method and URL:** `GET /GetDeviceSerialNumber`
- **What it does:** returns the machine's serial number (a string). The serial number names the voucher file and the `<serial>.local` host name.
- **Request:** none. **Response:** a JSON string.
- **Works in:** ME and OS (not shown which). **Changes the machine?** No (read).
- **Evidence:** From the service's own metadata; **not called**.

```powershell
Invoke-RestMethod -Uri "$base/GetDeviceSerialNumber" -Method Get -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### GetInstanceGuid

- **Method and URL:** `GET /GetInstanceGuid`
- **What it does:** returns the instance GUID (the `Instance-Id` the clients send). What the GUID identifies is not documented.
- **Request:** none. **Response:** a JSON string. **Works in:** not shown. **Changes the machine?** No.
- **Evidence:** From the service's own metadata; **not called**.

```powershell
Invoke-RestMethod -Uri "$base/GetInstanceGuid" -Method Get -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### GetSoftwareInfo

- **Method and URL:** `GET /GetSoftwareInfo`
- **What it does:** says which operating system is running and whether the target OS has been provisioned.
- **Request:** none. **Response:** `{ "OsName": String, "OsProvisioned": Boolean }`.
- **Works in:** not shown (the field exists to tell ME from OS). **Changes the machine?** No.
- **Evidence:** From the service's own metadata; **not called**. The values `OsName` takes are not documented; the contract's OS type names are `AzureLinux`, `AzureLinuxRoe` and `HCI`.

```powershell
Invoke-RestMethod -Uri "$base/GetSoftwareInfo" -Method Get -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### IsMicrosoftImage

- **Method and URL:** `GET /IsMicrosoftImage`
- **What it does:** returns `true` or `false`: whether the running image is a Microsoft image (as opposed to an OEM one).
- **Request:** none. **Response:** a JSON boolean. **Works in:** not shown. **Changes the machine?** No.
- **Evidence:** From the service's own metadata; **not called**. The exact meaning of "Microsoft image" is inferred from the name.

```powershell
Invoke-RestMethod -Uri "$base/IsMicrosoftImage" -Method Get -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### GetArcBootstrapVersion

- **Method and URL:** `GET /GetArcBootstrapVersion`
- **What it does:** returns the bootstrap component's version string.
- **Request:** none. **Response:** a JSON string. **Works in:** not shown. **Changes the machine?** No.
- **Evidence:** From the service's own metadata; **not called**. Use it first on a new build to see whether this appendix still applies.

```powershell
Invoke-RestMethod -Uri "$base/GetArcBootstrapVersion" -Method Get -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### TestConnect

- **Method and URL:** `POST /TestConnect`
- **What it does:** a test and echo call. Sends back `Data` and `IntData`. With `ThrowError` true it raises a fault on purpose.
- **Request:** `{ "ThrowError": Boolean, "Data": String, "IntData": Int32 }`. Messages show the rules: `Data` required ("{0} is required."), `IntData` must be even ("{0} must be even.").
- **Response:** `{ "Data": String, "IntData": Int32 }`.
- **Works in:** not shown. **Changes the machine?** No.
- **Evidence:** From the service's own metadata; **not called**. Useful for checking the sign-in and certificate handling without touching the machine.

```powershell
$body = @{ ThrowError = $false; Data = 'ping'; IntData = 2 } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/TestConnect" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

### Network

#### GetNetworkAdapters

- **Method and URL:** `GET /GetNetworkAdapters`
- **What it does:** lists every network port of the machine with its current configuration. This is how you find a machine by MAC address and read its ports before changing anything.
- **Request:** none.
- **Response:** `{ "NetworkAdapters": [ NetworkAdapterConfiguration, ... ] }`; see [Common shapes](#common-shapes). MAC addresses come back as 12 lower-case hex digits.
- **Works in:** ME (**Verified live**, HTTP 200). OS: not called.
- **Changes the machine?** No (read).
- **Evidence:** **Verified live** (2026-11-07, Dell AX-760 machines, build 2610); also the discovery call azurelocal-ztp uses to match a machine by its management MAC. Real result of the call on the second machine, before any change, addresses replaced:

```text
Name            MacAddress    EnableDhcp  IpAddress      SubnetMask     Gateway      DnsAddressArray
eno8303         00005e005301  True        192.0.2.101    255.255.255.0  192.0.2.1    192.0.2.30, 192.0.2.31
eno8403         00005e005302  True        192.0.2.102    255.255.255.0  192.0.2.1    192.0.2.30, 192.0.2.31
enp130s0f0np0   00005e005303  True        192.0.2.103    255.255.255.0  192.0.2.1    192.0.2.30, 192.0.2.31
enp130s0f1np1   00005e005304  True        192.0.2.104    255.255.255.0  192.0.2.1    192.0.2.30, 192.0.2.31
enp80s0f0np0    00005e005305  True        192.0.2.105    255.255.255.0  192.0.2.1    192.0.2.30, 192.0.2.31
enp80s0f1np1    00005e005306  True        192.0.2.106    255.255.255.0  192.0.2.1    192.0.2.30, 192.0.2.31
```

Six ports, six different DHCP leases: the maintenance environment takes a lease on every port.

```powershell
$result = Invoke-RestMethod -Uri "$base/GetNetworkAdapters" -Method Get -Authentication Basic -Credential $cred -SkipCertificateCheck
$result.NetworkAdapters | Select-Object Name, MacAddress, EnableDhcp, IpAddress, Gateway, VlanId | Format-Table -AutoSize
```

#### ConfigureNetwork

- **Method and URL:** `POST /ConfigureNetwork`
- **What it does:** applies network settings to one or more ports on their own, without the other configuration steps.
- **Request:** a `NetworkConfiguration` (bare): `{ "NetworkAdapters": [ { "MacAddress", "EnableDhcp", "IpAddress", "SubnetMask", "Gateway", "DnsAddressArray", "VlanId" } ] }`.
- **Response:** a bare `Response` (a single step, not a tree).
- **Works in:** not shown. For the maintenance environment use `SetArcBootstrapDeviceConfiguration`, the call that was proven. **Changes the machine?** **Yes**: ports change address; if you change the port you are connected through, the connection moves.
- **Evidence:** From the service's own metadata; **not called**. Whether it behaves like the network part of `SetArcBootstrapDeviceConfiguration` is not established.

```powershell
$body = @{ NetworkAdapters = @(@{ MacAddress = '00005e005301'; EnableDhcp = $false; IpAddress = '192.0.2.12'; SubnetMask = '255.255.255.0'; Gateway = '192.0.2.1'; DnsAddressArray = @('192.0.2.30', '192.0.2.31'); VlanId = 0 }) } | ConvertTo-Json -Depth 6
Invoke-RestMethod -Uri "$base/ConfigureNetwork" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

### Device configuration (the maintenance-environment path)

These two calls, with `GetNetworkAdapters` and `GetArcBootstrapDeviceConfigurationStatus`, are what ZTP's Device stage uses to put the right static address on the right port before the Azure claim ([how ZTP uses this service](#how-ztp-uses-this-service)).

#### SetArcBootstrapDeviceConfiguration

- **Method and URL:** `POST /SetArcBootstrapDeviceConfiguration`
- **What it does:** applies the device configuration (network, web proxy, time server, host name, remote desktop) **without Arc registration**, as an asynchronous job. The call returns at once with the status tree; poll [`GetArcBootstrapDeviceConfigurationStatus`](#getarcbootstrapdeviceconfigurationstatus).
- **Request** (`DeviceConfigurationRequest`, bare). All members optional in the contract; only the ones you send are acted on:

| Field | Type | Meaning |
| --- | --- | --- |
| `Network.NetworkAdapters[]` | `NetworkAdapterConfiguration` | Ports to change, matched by `MacAddress`. Verified live with `MacAddress`, `EnableDhcp`, `IpAddress`, `SubnetMask`, `Gateway`, `DnsAddressArray`, `VlanId`. |
| `WebProxy` | `WebProxyConfiguration` | Sent by ZTP's Device stage when `scenario.outbound_path` is `proxy`: `ConnectionUri` from `networking.outbound.proxy.url`, `BypassList` from `.bypass`, with the static address in the same request, or alone. **Not yet sent to a live maintenance environment.** The stage waits for the `WebProxy` step of the status tree to report `Succeeded`. |
| `Time` | `TimeConfiguration` | Not called. |
| `HostName` | `HostNameConfiguration` | Not called (ZTP sends none; the Azure claim sets the host name). |
| `RemoteConfiguration` | `RemoteConfiguration` | Not called. |
| `RequestSource` | String | Who is asking. Not called. |

The request that was **Verified live** (set a static address on one port, selected by MAC; addresses replaced):

```json
{ "Network": { "NetworkAdapters": [ {
    "MacAddress": "00005e005301", "EnableDhcp": false, "IpAddress": "192.0.2.12",
    "SubnetMask": "255.255.255.0", "Gateway": "192.0.2.1",
    "DnsAddressArray": [ "192.0.2.30", "192.0.2.31" ], "VlanId": 0 } ] } }
```

- **Response** (`DeviceConfigurationResponse`): **Verified live**, returned four seconds after the call (2026-11-07; times kept, nothing else changed except that `null` fields are left out here for length; the real response lists them all as `null`):

```json
{ "Version": "V1",
  "Response": {
    "Name": "Bootstrap", "Status": "InProgress",
    "DetailedResponse": [
      { "Name": "NetworkConfig", "Status": "Succeeded", "StartTime": "2026-11-07T06:01:13.355Z", "EndTime": "2026-11-07T06:01:15.028Z" },
      { "Name": "RemoteConfig",  "Status": "NotApplicable", "StartTime": "2026-11-07T06:01:15.095Z", "EndTime": "2026-11-07T06:01:15.095Z" },
      { "Name": "WebProxy",      "Status": "InProgress", "StartTime": "2026-11-07T06:01:15.160Z", "EndTime": null },
      { "Name": "TimeServer",    "Status": "NotStarted", "Errors": [] },
      { "Name": "HostName",      "Status": "NotStarted", "Errors": [] } ] } }
```

- **Works in:** ME (**Verified live**). OS: not called.
- **Changes the machine?** **Yes.** The port you name changes address. If it is the port you are connected through, azurelocal-ztp expects the service to answer on the new address and tries both the old and the new one; the live runs changed a port other than the one they were connected through, so that case was not observed. One live call left every other port untouched ([semantics](#network-configuration-semantics)). Resetting the OS later undoes it: the OS install resets every port to DHCP (**Verified live**, build 2610).
- **Preconditions:** the port's MAC must be in `GetNetworkAdapters`; the target address must not be held by another port of the same machine (ZTP stops rather than send a request in that case; a request that releases the other port is not proven).
- **Evidence:** **Verified live**, plus **From Azure-side ZTP evidence** (the ZTP Device stage uses it; four recorded live changes on 2026-11-07: one earlier test on one machine and three machines in one run, every one on the first onboard LOM port, status NetworkConfig Succeeded).

```powershell
$body = @{
    Network = @{ NetworkAdapters = @(@{
        MacAddress = '00005e005301'; EnableDhcp = $false; IpAddress = '192.0.2.12'
        SubnetMask = '255.255.255.0'; Gateway = '192.0.2.1'; DnsAddressArray = @('192.0.2.30', '192.0.2.31'); VlanId = 0 }) }
} | ConvertTo-Json -Depth 8
Invoke-RestMethod -Uri "$base/SetArcBootstrapDeviceConfiguration" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### GetArcBootstrapDeviceConfigurationStatus

- **Method and URL:** `GET /GetArcBootstrapDeviceConfigurationStatus`
- **What it does:** returns the status tree of the last device configuration job. Poll it until the root `Bootstrap` is `Succeeded` or `Failed`.
- **Request:** none. **Response:** `DeviceConfigurationResponse`, the same shape as above. **Verified live**, the final read of the same run, about 1 minute 50 seconds after the call:

```json
{ "Version": "V1",
  "Response": { "Name": "Bootstrap", "Status": "Succeeded",
    "DetailedResponse": [
      { "Name": "NetworkConfig", "Status": "Succeeded" },
      { "Name": "RemoteConfig",  "Status": "NotApplicable" },
      { "Name": "WebProxy",      "Status": "Succeeded",     "EndTime": "2026-11-07T06:02:55.175Z" },
      { "Name": "TimeServer",    "Status": "NotApplicable" },
      { "Name": "HostName",      "Status": "NotApplicable" } ] } }
```

- **Works in:** ME (**Verified live**). **Changes the machine?** No (read).
- **Timing (Verified live):** `NetworkConfig` finished in about 2 seconds; the whole job took about 1 minute 40 seconds, almost all of it in `WebProxy` although no proxy was sent. The root stays `InProgress` until `WebProxy` finishes. Read the adapters back with `GetNetworkAdapters` to confirm the address; the root `Succeeded` is not the only check.
- **Evidence:** **Verified live**.

```powershell
$status = Invoke-RestMethod -Uri "$base/GetArcBootstrapDeviceConfigurationStatus" -Method Get -Authentication Basic -Credential $cred -SkipCertificateCheck
$status.Response.DetailedResponse | Select-Object Name, Status
```

### Single settings

Each applies one part of the configuration on its own. They return a bare `Response`. **Not called** by us; whether they work in the maintenance environment is not shown. The same settings can be sent in one request through [`SetArcBootstrapDeviceConfiguration`](#setarcbootstrapdeviceconfiguration), which is the proven path.

#### ConfigureHostName

- **Method and URL:** `POST /ConfigureHostName`
- **What it does:** renames the machine.
- **Request:** `HostNameConfiguration`: `{ "Name": String, "SkipReboot": Boolean }`. Rules: on the Linux (maintenance) side, at least 1 character, letters, digits and hyphens only; on the Windows side, at least 3 characters, letters and digits only, not all digits.
- **Response:** a bare `Response`.
- **Works in:** not shown. **After Azure registration it is refused**: "Hostname rename not allowed after Azure registration." Learn: "Changing the hostname automatically restarts the machine" ([Documented by Microsoft](https://learn.microsoft.com/azure/azure-local/deploy/deployment-without-azure-arc-gateway?view=azloc-2610#register-azure-local-by-using-the-configurator-app), the OS-side app).
- **Changes the machine?** **Yes**: the name, and a restart unless `SkipReboot` is true.
- **Evidence:** From the service's own metadata; **not called**; rename-after-registration refusal from the service's message text; restart behaviour **Documented by Microsoft**.

```powershell
$body = @{ Name = 'node-01'; SkipReboot = $true } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/ConfigureHostName" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### ConfigureTimeServer

- **Method and URL:** `POST /ConfigureTimeServer`
- **What it does:** sets the time server(s) and time zone.
- **Request:** `TimeConfiguration`: `{ "PrimaryTimeServer", "SecondaryTimeServer", "TimeZoneName" }`. The time zone must be one returned by [`GetTimeZoneIds`](#gettimezoneids) ("The specified time zone is not valid."); the primary server must be reachable ("Enter a valid time zone and reachable primary time server, then retry."). Learn's default NTP server in the OS-side app is `time.windows.com` ([Documented by Microsoft](https://learn.microsoft.com/azure/azure-local/deploy/deployment-without-azure-arc-gateway?view=azloc-2610#register-azure-local-by-using-the-configurator-app)).
- **Response:** a bare `Response`. **Changes the machine?** **Yes** (time source and zone).
- **Evidence:** From the service's own metadata; **not called**.

```powershell
$body = @{ PrimaryTimeServer = 'ntp1.example.test'; SecondaryTimeServer = 'ntp2.example.test'; TimeZoneName = 'UTC' } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/ConfigureTimeServer" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### ConfigureWebProxy

- **Method and URL:** `POST /ConfigureWebProxy`
- **What it does:** sets the web proxy and bypass list.
- **Request:** `WebProxyConfiguration`: `{ "ConnectionUri": String, "BypassList": String[] }`. At least one bypass entry is required when a URL is set. Learn's bypass rules (comma-separated, wildcard patterns, no CIDR, no `<local>`) are for the OS-side app ([Documented by Microsoft](https://learn.microsoft.com/azure/azure-local/deploy/deployment-without-azure-arc-gateway?view=azloc-2610#register-azure-local-by-using-the-configurator-app)).
- **Response:** a bare `Response`. **Changes the machine?** **Yes** (the proxy used for outbound traffic, including Arc).
- **Evidence:** From the service's own metadata; **not called**. Note that the `WebProxy` step ran for about 100 seconds in the live device-configuration job although no proxy was sent.

```powershell
$body = @{ ConnectionUri = 'http://proxy.example.test:3128'; BypassList = @('192.0.2.*', '*.example.test') } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/ConfigureWebProxy" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### GetTimeZoneIds

- **Method and URL:** `GET /GetTimeZoneIds` returns a JSON array of the time zone names the service accepts (list of String).
- **Works in:** not shown. **Changes the machine?** No. **Evidence:** From the service's own metadata; **not called**.

```powershell
Invoke-RestMethod -Uri "$base/GetTimeZoneIds" -Method Get -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### GetTimeZoneIdsMap

- **Method and URL:** `GET /GetTimeZoneIdsMap` returns a dictionary of String to String (zone identifiers to display names, by the type; the meaning of keys and values is not documented).
- **Works in:** not shown. **Changes the machine?** No. **Evidence:** From the service's own metadata; **not called**.

```powershell
Invoke-RestMethod -Uri "$base/GetTimeZoneIdsMap" -Method Get -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### GetMultiSourceWebProxyConfiguration

- **Method and URL:** `GET /GetMultiSourceWebProxyConfiguration`
- **What it does:** reads the proxy from every place the machine can hold one, so you can see where a proxy actually comes from.
- **Response:** `{ "WinInetProxy": WebProxyConfiguration, "WinHttpProxy": WebProxyConfiguration, "EnvironmentVariableProxy": String[], "EnvironmentFileUpper": {HttpsProxy, HttpProxy, NoProxy}, "EnvironmentFileLower": {...}, "SystemdUpper": {...}, "SystemdLower": {...} }` (the upper and lower variants are the upper- and lower-case environment variable names; `Systemd*` is the systemd environment).
- **Works in:** not shown (the Windows and the Linux sources both exist in the type). **Changes the machine?** No. **Evidence:** From the service's own metadata; **not called**. Related live fact: the maintenance environment log recorded `Proxy env: HTTPS_PROXY=<unset>, HTTP_PROXY=<unset>, NO_PROXY=<unset>` at start.

```powershell
Invoke-RestMethod -Uri "$base/GetMultiSourceWebProxyConfiguration" -Method Get -Authentication Basic -Credential $cred -SkipCertificateCheck
```

### Arc bootstrap and registration

These are the calls of the registration flow the Configurator app drives on an installed OS ([Documented by Microsoft](https://learn.microsoft.com/azure/azure-local/deploy/deployment-without-azure-arc-gateway?view=azloc-2610#register-azure-local-by-using-the-configurator-app): Basics, then Arc agent setup, then Review and apply, then status). **In the maintenance environment Arc registration is done by Azure, and the service refuses an `ArcConfiguration`.**

#### ParseArcScript

- **Method and URL:** `POST /ParseArcScript`
- **What it does:** takes an Arc registration script (the kind generated for Arc onboarding), base64 encoded, and returns the registration settings it contains. The app uses it to fill in the registration form from a script.
- **Request:** the parameter is named `base64ConfigContent`: a single string (a JSON string with the base64 text; the exact wire form was not exercised).
- **Response:** `ArcMultiServerConfiguration` ([Common shapes](#common-shapes)).
- **Works in:** not shown. **Changes the machine?** No (parse only, by its name and type).
- **Evidence:** From the service's own metadata; **not called**. What the script must look like is not documented.

```powershell
$script = Get-Content -Raw ./arc-onboarding-script.ps1
$body = ConvertTo-Json -InputObject ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script)))
Invoke-RestMethod -Uri "$base/ParseArcScript" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### GetArcBootstrapConfig

- **Method and URL:** `GET /GetArcBootstrapConfig`
- **What it does:** returns the machine's current configuration, including (after registration) the Arc resource it registered as.
- **Response** (`ConfigurationResponse`): `{ "Network", "RemoteConfiguration", "WebProxy", "Time", "HostName", "Arc": { "ResourceLink", "ResourceName", "ResourceGroup", "SubscriptionId" } }`.
- **Works in:** not shown. **Changes the machine?** No. **Evidence:** From the service's own metadata; **not called**. `Arc.ResourceName` is where, after registration, the Arc machine name the machine believes it has would show; we have not read it.

```powershell
Invoke-RestMethod -Uri "$base/GetArcBootstrapConfig" -Method Get -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### StartArcBootstrap

- **Method and URL:** `POST /StartArcBootstrap`
- **What it does:** starts the whole configuration and Arc registration as an asynchronous job: network, proxy, time, host name, remote desktop, Arc registration, mandatory extension install, optional update and storage layout.
- **Request:** `ConfigurationRequest` (see [Common shapes](#common-shapes)). Registration sign-in is an ARM access token or a device-code sign-in; service principal and site key are refused.
- **Response:** `BootstrapResponse`: `{ "Version", "Response": <Bootstrap tree> }`.
- **Works in:** OS (it is the registration call). **ME: the Arc part is refused** (message below). **Changes the machine?** **Yes** (everything you send, and Arc registration).
- **Refusals (the service's own messages):** with an `ArcConfiguration` in the maintenance environment: "Arc configuration is not supported in the provisioning environment. Remove ArcConfiguration from the request and retry." Registration with a service principal or a site key: refused (use device code or an ARM access token). Update and Arc registration are separate: "Zero Day Update and Arc registration have to performed separately."
- **Evidence:** From the service's own metadata; **not called**. The refusal text is read from the compiled resource, not seen on the wire; no log we hold shows the refusal happening.

```powershell
$body = @{
    Network = @{ NetworkAdapters = @(@{ MacAddress = '00005e005301'; EnableDhcp = $false; IpAddress = '192.0.2.12'; SubnetMask = '255.255.255.0'; Gateway = '192.0.2.1'; DnsAddressArray = @('192.0.2.30') }) }
    HostName = @{ Name = 'node-01'; SkipReboot = $false }
    ArcConfiguration = @{ ArcMultiServerConfiguration = @{
        SubscriptionId = '00000000-0000-0000-0000-000000000000'; ResourceGroup = 'rg-iic-azl-01-azl'
        TenantId = '00000000-0000-0000-0000-000000000001'; Location = 'EastUS'; Cloud = 'AzureCloud'
        ArmAccessToken = $armToken } }   # $armToken: a token you obtained yourself, never typed into a script
} | ConvertTo-Json -Depth 10
Invoke-RestMethod -Uri "$base/StartArcBootstrap" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### GetArcBootstrapStatus

- **Method and URL:** `GET /GetArcBootstrapStatus`
- **What it does:** returns the status tree of the bootstrap: the whole [status model](#the-status-model).
- **Request:** none. **Response:** `BootstrapResponse`. A real failed-run tree is shown in the status model.
- **Works in:** ME and OS. The tree shows `RoeSetup` and `Provisioning` in the maintenance environment. On an installed OS the same tree is what the PowerShell cmdlet `Get-ArcBootstrapStatus` (module `AzureEdgeBootstrap` 1.0.0) returns; the companion monitor [Sonar](https://azurelocal.cloud/azurelocal-sonar/) reads it that way on the OEM-image route, which ZTP does not (**Verified live** on 11 October 2026 on an OS install: `NetworkConfig`, `RemoteConfig`, `WebProxy`, `TimeServer`, `HostName`, `ArcConfiguration` with its four sub-steps).
- **Changes the machine?** No (read).
- **Evidence:** the tree **Verified live**; that this exact call produced the saved tree is **not recorded** in the file (see [Conflicts and gaps](#conflicts-and-gaps)).

```powershell
$s = Invoke-RestMethod -Uri "$base/GetArcBootstrapStatus" -Method Get -Authentication Basic -Credential $cred -SkipCertificateCheck
$s.Response | Select-Object Name, Status, Message
$s.Response.DetailedResponse | Select-Object Name, Status
```

#### InvokeDeviceCodeAuthentication

- **Method and URL:** `POST /InvokeDeviceCodeAuthentication`
- **What it does:** starts an Azure device-code sign-in for Arc registration. You are shown a code and open a sign-in page on another device; the service waits and, on success, holds the credential for registration.
- **Request:** `DeviceCodeAuthenticationRequest`: `{ "ArcConfiguration": ArcMultiServerConfiguration }` (subscription, resource group, tenant, location, cloud).
- **Response:** `DeviceCodeAuthenticationResponse`: `{ "Version", "Response": Response }`. Where the code and the sign-in address appear (probably `Response.AdditionalData`) is not documented.
- **Works in:** OS. In ME: not shown (registration is refused there). **Changes the machine?** Starts a sign-in; stores a credential for the registration that follows.
- **Failure texts:** "Authentication to Azure Arc failed. Verification code expired." (recommended: "Reapply configuration to retry authentication."), "Failed to authenticate to Azure with device code: {0}".
- **Evidence:** From the service's own metadata; **not called**.

```powershell
$body = @{ ArcConfiguration = @{ SubscriptionId = '00000000-0000-0000-0000-000000000000'; ResourceGroup = 'rg-iic-azl-01-azl'; TenantId = '00000000-0000-0000-0000-000000000001'; Location = 'EastUS'; Cloud = 'AzureCloud' } } | ConvertTo-Json -Depth 6
Invoke-RestMethod -Uri "$base/InvokeDeviceCodeAuthentication" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### GetDeviceCodeAuthenticationStatus

- **Method and URL:** `GET /GetDeviceCodeAuthenticationStatus`
- **What it does:** reports whether the device-code sign-in is waiting, completed, failed or expired.
- **Response:** `DeviceCodeAuthenticationResponse`. **Works in:** not shown. **Changes the machine?** No.
- **Evidence:** From the service's own metadata; **not called**.

```powershell
Invoke-RestMethod -Uri "$base/GetDeviceCodeAuthenticationStatus" -Method Get -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### UpdateArcBootstrapUserPassword

- **Method and URL:** `POST /UpdateArcBootstrapUserPassword`
- **What it does:** changes the password of a local user on the machine (step `UpdatePassword`).
- **Request:** `UpdatePasswordRequest`: `{ "UserName": String, "OldPassword": String, "NewPassword": String }`. User name: 1 to 32 characters, start with a letter or underscore, then letters, digits, underscores, hyphens or periods.
- **Response:** a bare `Response`. **Works in:** not shown. **Changes the machine?** **Yes: it changes a credential.** Anything that signs in with the old password stops working (including your next call).
- **Evidence:** From the service's own metadata; **not called**. Which user is meant (the maintenance-environment `edgeuser` or an OS user) is not shown.

```powershell
$old = Read-Host -Prompt 'Old password' -AsSecureString
$new = Read-Host -Prompt 'New password' -AsSecureString
$body = @{
    UserName    = 'edgeuser'
    OldPassword = [System.Net.NetworkCredential]::new('', $old).Password
    NewPassword = [System.Net.NetworkCredential]::new('', $new).Password
} | ConvertTo-Json
Invoke-RestMethod -Uri "$base/UpdateArcBootstrapUserPassword" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

### Reset

See also [Reset: what each reset does](#reset-what-each-reset-does).

#### StartArcBootstrapReset

- **Method and URL:** `POST /StartArcBootstrapReset`
- **What it does:** resets the machine's **Azure Arc connection** (disconnects it from Azure Arc and cleans up what registration created) so that it can be registered again. It is not an operating system reinstall.
- **Request:** `ResetArcRequest`: `{ "ArmAccessToken": String, "TenantId": String }`. The token is required: "Arm access token is a required input."
- **Response:** `ResetArcResponse`: `{ "Version", "Responses": [Response], "Status": String, "Errors": [ErrorInfo], "LastUpdateTime": DateTime }`.
- **Preconditions (the service's own messages):** "Operation is only valid for non-deployed devices." / "Cannot run Arc reset in the current device state." / "Arc reset can not be performed while bootstrap is in progress." / "Reset Arc is already in progress." / "This device does not support resetting its Azure Arc connection." A failure reads "The device could not reset its Azure Arc connection."
- **Works in:** not shown. **Changes the machine?** **Yes, and it can be destructive:** the steps `ResetArc`, `ExtensionCleanup`, `GatewayCleanup`, `AzcmAgentCleanup` and `BootstrapCleanup` (names from the contract) point to removing the Arc extensions, the gateway configuration and the Arc agent registration. The Arc machine resource in Azure is not necessarily deleted by it; that is not shown.
- **Evidence:** From the service's own metadata; **not called. We never ran a reset, through this service or through Azure.**

```powershell
# $armToken: obtain it yourself (for example with Get-AzAccessToken); do not paste it into a script.
$body = @{ ArmAccessToken = $armToken; TenantId = '00000000-0000-0000-0000-000000000001' } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/StartArcBootstrapReset" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### GetArcBootstrapResetStatus

- **Method and URL:** `GET /GetArcBootstrapResetStatus`
- **What it does:** returns the status of the reset (`ResetArcResponse`). Retry hint when a step did not take effect: "Retry the operation. If the issue persists, restart the bootstrap service."
- **Works in:** not shown. **Changes the machine?** No. **Evidence:** From the service's own metadata; **not called**.

```powershell
Invoke-RestMethod -Uri "$base/GetArcBootstrapResetStatus" -Method Get -Authentication Basic -Credential $cred -SkipCertificateCheck
```

### Diagnostics and support logs

Learn describes the app's diagnostics and support package ([Troubleshoot simplified machine provisioning](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning?view=azloc-2610)): "Run diagnostic tests", then "Create" and "Download" a zipped package. These are the calls behind them (the mapping is inferred from names and types).

#### GetArcBootstrapPrerequisitesStatus

- **Method and URL:** `GET /GetArcBootstrapPrerequisitesStatus`
- **What it does:** the hardware prerequisite checks. The checks it names (display texts in the contract): "TPM version 2.0 hardware must be present and enabled.", "Secure Boot must be present and turned on.", "The processor is supported for Azure Stack HCI.", "There is at least 32-GB RAM per node."
- **Response:** `DiagnosticsResponse`: `{ "Version", "DestinationPath", "Results": [ { "Name", "Status", "Errors": [ErrorInfo] } ], "Status", "LastUpdateTime" }`.
- **Works in:** not shown. **Changes the machine?** No. **Evidence:** From the service's own metadata; **not called**.

```powershell
Invoke-RestMethod -Uri "$base/GetArcBootstrapPrerequisitesStatus" -Method Get -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### StartArcBootstrapDiagnostics

- **Method and URL:** `POST /StartArcBootstrapDiagnostics`
- **What it does:** runs diagnostics for a category (or several) as an asynchronous job.
- **Request:** one string, the parameter named `diagnosticsCategory`. The categories are bit flags (enum `DiagnosticsTestCategory`): `Time` 1, `WebProxy` 2, `InternetConnectivity` 4, `ArcConnectivity` 8, `Tpm` 16, `OemHook` 32, `BootstrapEnvironmentTests` 64, `SecureBoot` 128, `Processor` 256, `Memory` 512, `ImageRecipeValidation` 1024, `ECConnectivity` 2048, `ShellScripts` 4096, and `All` 511. Note that `All` = 1 to 256 and **does not include** `Memory`, `ImageRecipeValidation`, `ECConnectivity` or `ShellScripts`. How the string is written (a name, a number, a list) is not shown.
- **Response:** `DiagnosticsResponse`. **Failure texts:** "Diagnostics run is already in progress." / "Failed to start diagnostics run." / "Diagnostic tests timed out. Try running diagnostic tests again." and per category: "Web proxy settings are not correctly configured.", "Time is not synchronized with the time server.", "Could not connect to the internet.", "Arc is not connected.", "The Azure Arc agent is not installed.", "Oem hook for diagnostics failed to run.".
- **Works in:** not shown. **Changes the machine?** It runs tests and writes a report file; it does not change configuration.
- **Evidence:** From the service's own metadata; **not called**. Learn's own diagnostics list for the OS-side app: internet connectivity, web proxy, time sync, Azure Arc agent, environment checker ([Learn](https://learn.microsoft.com/azure/azure-local/manage/troubleshoot-deployment-configurator-app?view=azloc-2610#run-diagnostic-tests-from-the-app)).

```powershell
$body = ConvertTo-Json -InputObject 'All'    # the string form is an assumption; this call was never made
Invoke-RestMethod -Uri "$base/StartArcBootstrapDiagnostics" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### GetArcBootstrapDiagnosticsStatus

- **Method and URL:** `GET /GetArcBootstrapDiagnosticsStatus`
- **What it does:** the results of the last diagnostics run (`DiagnosticsResponse`): one `Results` entry per test with its `Status` and `Errors` (each with `RecommendedActions`). **Works in:** not shown. **Changes the machine?** No. **Evidence:** From the service's own metadata; **not called**.

```powershell
(Invoke-RestMethod -Uri "$base/GetArcBootstrapDiagnosticsStatus" -Method Get -Authentication Basic -Credential $cred -SkipCertificateCheck).Results
```

#### StartArcBootstrapSupportLogs

- **Method and URL:** `POST /StartArcBootstrapSupportLogs`
- **What it does:** collects a support package (a `.zip`) as an asynchronous job, either to a local path on the machine or to an SMB share.
- **Request:** `SupportLogsRequest`: `{ "DestinationPath": String (must end .zip; "Destination path already exists" if it does), "IncludeType": "Latest" or "All", "SmbUserName": String, "SmbPassword": String }`. The SMB fields are used when the destination is a share.
- **Response:** `SupportLogsResponse`: `{ "Version", "DestinationPath", "Response", "Status", "LastUpdateTime" }`.
- **Failure texts:** "Support logs collection is already in progress.", "Failed to start support logs collection.", "Support logs failed to copy to SMB share." (verify the share and the credentials), "Support logs failed to save to local path." (verify the path and disk space).
- **Works in:** not shown. Learn documents the app feature on both sides. **Changes the machine?** Writes a package file (and diagnostics output); no configuration change.
- **Evidence:** From the service's own metadata; **not called**.

```powershell
$body = @{ DestinationPath = '/var/staging/export/support-logs.zip'; IncludeType = 'Latest' } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/StartArcBootstrapSupportLogs" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

(The destination path in the example is a guess: the service's download guard restricts file access to the export folder `/var/staging/export`; see `DownloadArcBootstrapSupportLogs`, but we have not seen which path the app itself chooses.)

#### GetArcBootstrapSupportLogsStatus

- **Method and URL:** `GET /GetArcBootstrapSupportLogsStatus`
- **What it does:** returns the collection status (`SupportLogsResponse`). If no package was ever made it returns status `NotStarted` ("No previous support-log package found. Returning NotStarted status."). **Works in:** the Linux build implements it (the service logs `GetArcBootstrapSupportLogsStatus started.`). **Changes the machine?** No. **Evidence:** From the service's own metadata; **not called**.

```powershell
Invoke-RestMethod -Uri "$base/GetArcBootstrapSupportLogsStatus" -Method Get -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### DownloadArcBootstrapSupportLogs

- **Method and URL:** `POST /DownloadArcBootstrapSupportLogs`
- **What it does:** downloads a finished support package. Returns the file bytes (a stream), not JSON.
- **Request:** one string, the parameter named `supportLogsPath` (the package's path on the machine). "Access to files outside the export directory is not allowed." (the export directory is `/var/staging/export` on the Linux build); a non-`.zip` path is refused ("Destination path is not in .zip format").
- **Response:** the `.zip` bytes. **Works in:** not shown. **Changes the machine?** No (read).
- **Evidence:** From the service's own metadata; **not called**. The wire form of the string body is an assumption.

```powershell
$body = ConvertTo-Json -InputObject '/var/staging/export/support-logs.zip'
Invoke-RestMethod -Uri "$base/DownloadArcBootstrapSupportLogs" -Method Post -ContentType 'application/json' -Body $body -OutFile ./support-logs.zip -Authentication Basic -Credential $cred -SkipCertificateCheck
```

### Ownership voucher

#### DownloadOwnershipVoucher

- **Method and URL:** `GET /DownloadOwnershipVoucher`
- **What it does:** downloads the machine's ownership voucher (the `.pem` file Azure needs to claim the machine). Returns the file bytes. The Configurator app has a "Download the ownership voucher" action for this ([Documented by Microsoft](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-configurator-app?view=azloc-2610#download-ownership-vouchers)).
- **Request:** none. **Response:** the voucher file. The service reads `*.pem` from a `vouchers` directory under `/var/staging/export`; "No ownership voucher (.pem) files found in the vouchers directory." if there is none; it refuses any path outside the export directory.
- **Works in:** ME (the voucher is created there). **Changes the machine?** No (read). **Treat the voucher as a secret:** anyone holding it may be able to attempt to claim the machine ([Learn](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-zero-touch-provisioning?view=azloc-2610#how-ztp-works-for-azure-local-deployments)).
- **Evidence:** From the service's own metadata; **not called through the service**. The voucher's location is **Verified live** in the device log (created at `/var/staging/roesetup/di/<serial>.pem`, exported to `/var/staging/export/vouchers/<serial>`), and **Documented by Microsoft** (copy `/var/staging/export/vouchers/<serial-number>/<serial-number>.pem` with SCP, [Learn](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-installation?view=azloc-2610#extract-ownership-vouchers)). azurelocal-ztp reads vouchers from the virtual USB or the share, not through this call.

```powershell
Invoke-RestMethod -Uri "$base/DownloadOwnershipVoucher" -Method Get -OutFile ./voucher.pem -Authentication Basic -Credential $cred -SkipCertificateCheck
```

### Updates

The "zero-day update" brings the machine's solution software up to date before registration or deployment. On an installed OS, the status is read with the local cmdlet `Get-ArcZeroDaySolutionUpdateStatus` (**Verified live**, 11 October 2026): a root `Update` with children `Scan`, `Download`, `Install`.

#### CheckForAvailableUpdates

- **Method and URL:** `POST /CheckForAvailableUpdates`
- **Request:** `UpdateConfiguration`: `{ "EnableUpdate": Boolean, "TargetSolutionVersion": String, "ArcMultiServerConfiguration": ..., "LocalPlatformPackagePath": String, "Environment": "Production" or "Canary" }`. Versions are dotted numbers (3 or 4 parts are accepted by different checks; the contract holds both patterns). "Specified Environment {0} for Update is invalid."
- **Response:** `UpdateAvailabilityResponse`: `{ "IsUpdateAvailable": Boolean, "CurrentPlatformVersion", "CurrentSolutionVersion", "LatestPlatformVersion", "LatestSolutionVersion", "Status", "Errors" }`. Failure: "Failed to check for available updates." (check network connectivity and the update service).
- **Works in:** the Linux build implements it (log `UpdateAvailabilityCheck`). **Changes the machine?** No (query). **Evidence:** From the service's own metadata; **not called**.

```powershell
$body = @{ EnableUpdate = $false; Environment = 'Production' } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/CheckForAvailableUpdates" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### GetArcZeroDaySolutionUpdateConfig

- **Method and URL:** `POST /GetArcZeroDaySolutionUpdateConfig` (a POST, although it reads)
- **Request:** the parameter `arcConfig`: an `ArcMultiServerConfiguration` (so the service can query Azure for the updates that apply to that registration).
- **Response:** `ZeroDaySolutionUpdateConfig`: `{ "CurrentSolutionVersion", "CurrentPlatformVersion", "Updates": [ { "Version", "SolutionVersion", "UpdateName" } ] }`.
- **Works in:** not shown. **Changes the machine?** No (query). **Evidence:** From the service's own metadata; **not called**.

```powershell
$body = @{ SubscriptionId = '00000000-0000-0000-0000-000000000000'; ResourceGroup = 'rg-iic-azl-01-azl'; TenantId = '00000000-0000-0000-0000-000000000001'; Location = 'EastUS'; Cloud = 'AzureCloud'; ArmAccessToken = $armToken } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/GetArcZeroDaySolutionUpdateConfig" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### StartArcZeroDaySolutionUpdate

- **Method and URL:** `POST /StartArcZeroDaySolutionUpdate`
- **What it does:** downloads and installs a solution update, as an asynchronous job (`Scan`, `Download`, `Install`). A target version is required ("TargetSolutionVersion is a required parameter"; "Update version '{0}' is not available for this device."; "...not compatible with the current software version."). The update information is signature-checked ("The available update information could not be verified." and "Do not continue with the update." if unsigned). A local package (`LocalPlatformPackagePath`) can be used; with several zips present the call fails and asks you to name one.
- **Request:** `UpdateConfiguration` (above). **Response:** `UpdateResponse`: `{ "Version", "Response": Response }`.
- **Works in:** not shown. **Changes the machine?** **Yes** (installs software; may restart it). **Evidence:** From the service's own metadata; **not called**.

```powershell
$body = @{ EnableUpdate = $true; TargetSolutionVersion = '12.2610.1.1'; Environment = 'Production' } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/StartArcZeroDaySolutionUpdate" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

(The version in the example is a placeholder.)

#### GetArcZeroDaySolutionUpdateStatus

- **Method and URL:** `GET /GetArcZeroDaySolutionUpdateStatus`
- **Response:** `UpdateResponse` with root `Update` and children `Scan`, `Download`, `Install`. Failure text: "Update failed with Error Message : {0}." / "Update failed to complete within timeout".
- **Works in:** the same tree is returned on an installed OS by `Get-ArcZeroDaySolutionUpdateStatus` (**Verified live**, 11 October 2026, through PowerShell, not through this REST call). **Changes the machine?** No.
- **Evidence:** the REST form From the service's own metadata (**not called**); the tree **Verified live** through the cmdlet.

```powershell
(Invoke-RestMethod -Uri "$base/GetArcZeroDaySolutionUpdateStatus" -Method Get -Authentication Basic -Credential $cred -SkipCertificateCheck).Response.DetailedResponse | Select-Object Name, Status
```

### Package sideload and file upload

These load an OS image or a solution extension (a "SBE") onto the machine by hand, for machines that cannot download it. Sequence: `EnablePackageSideload`, `UploadFile` once per file, `CompletePackageSideload`, with `GetSideloadInfo` to check and `DisablePackageSideload` to undo. Types: `SideloadType` is `OsImage` or `SBE`. **All five: From the service's own metadata; not called.** All are implemented in the Linux build (their log texts are in it).

#### EnablePackageSideload

- **Method and URL:** `POST /EnablePackageSideload`. **Request** (`SideloadRequest`): `{ "SideloadItems": [ { "Type": "OsImage" | "SBE", "FileNames": [String] } ], "SolutionVersion": String }`; "At least one sideload item is required". **Response:** bare `Response`.
- **What it does:** prepares an upload directory (empties it first; "Prep upload directory") and records the intended files.
- **Changes the machine?** **Yes** (clears the upload directory, stores the sideload plan).

```powershell
$body = @{ SideloadItems = @(@{ Type = 'OsImage'; FileNames = @('os-image.zip') }); SolutionVersion = '12.2610.1.1' } | ConvertTo-Json -Depth 5
Invoke-RestMethod -Uri "$base/EnablePackageSideload" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### UploadFile

- **Method and URL:** `POST /UploadFile?fileName={fileName}` (the only operation with an explicit URL template). Body: the raw file bytes (a stream, `BodyStyle` bare).
- **What it does:** uploads one file into the upload directory. `fileName` is required and may not contain invalid characters; the stream must be readable. Replies with a bare `Response` ("uploaded successfully to '...'. Size: N bytes").
- **Changes the machine?** **Yes** (writes a file). The service accepts files up to the transport's limit (the contract's net.tcp client allows 10 GiB; the HTTPS limit is not shown).

```powershell
Invoke-RestMethod -Uri "$base/UploadFile?fileName=os-image.zip" -Method Post -ContentType 'application/octet-stream' -InFile ./os-image.zip -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### CompletePackageSideload

- **Method and URL:** `POST /CompletePackageSideload`. **Request:** `SideloadRequest`, as above. **Response:** bare `Response`.
- **What it does:** validates that every declared file exists in the upload directory ("Validated file exists", "File validation failed with N error(s)") and marks the sideload complete. Errors: "No sideload operation in progress. Call EnablePackageSideload first.", "Sideload already completed".
- **Changes the machine?** **Yes** (marks the sideload ready for the install to use).

```powershell
$body = @{ SideloadItems = @(@{ Type = 'OsImage'; FileNames = @('os-image.zip') }); SolutionVersion = '12.2610.1.1' } | ConvertTo-Json -Depth 5
Invoke-RestMethod -Uri "$base/CompletePackageSideload" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### GetSideloadInfo

- **Method and URL:** `GET /GetSideloadInfo`. **Response:** `{ "Status": String, "Items": [ { "Type", "PayloadPaths": [String] } ], "SolutionVersion": String }`. **Changes the machine?** No.

```powershell
Invoke-RestMethod -Uri "$base/GetSideloadInfo" -Method Get -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### DisablePackageSideload

- **Method and URL:** `POST /DisablePackageSideload` (no body). **Response:** bare `Response`.
- **What it does:** deletes the uploaded files and resets the sideload status to `NotStarted` ("No sideload configuration found, nothing to disable" if there is none). **Changes the machine?** **Yes** (deletes the uploaded files).

```powershell
Invoke-RestMethod -Uri "$base/DisablePackageSideload" -Method Post -Authentication Basic -Credential $cred -SkipCertificateCheck
```

### Storage and power

#### CreateVolume

- **Method and URL:** `POST /CreateVolume`. **Request** (`CreateVolumeApiRequest`): `{ "DiskName": String, "ParentDiskPath": String, "Path": String, "SizeInBytes": Int64, "FileSystem": String }`. **Response:** bare `Response` (the log notes the work item id).
- **What it does:** creates a volume (a partition on a disk) at a path. Related request type `PartitionConfiguration` (label, size, file system, mount path, reserved and encrypted flags) is part of `StartArcBootstrap`'s `Storage`.
- **Changes the machine?** **Yes** (alters the disk layout). **Evidence:** From the service's own metadata; **not called**.

```powershell
$body = @{ DiskName = 'data'; ParentDiskPath = '/dev/sdb'; Path = '/mnt/data'; SizeInBytes = 107374182400; FileSystem = 'ext4' } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/CreateVolume" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### DeleteVolume

- **Method and URL:** `POST /DeleteVolume`. **Request** (`DeleteVolumeApiRequest`): `{ "DiskName", "ParentDiskPath", "VolumePath", "ConfirmDeletion": Boolean }`. **`ConfirmDeletion` must be `true`**: "ConfirmDeletion must be set to true to authorize a destructive volume deletion."
- **Changes the machine?** **Yes: destructive. Data on the volume is lost.** **Evidence:** From the service's own metadata; **not called**. The example is deliberately inert (`ConfirmDeletion = $false`).

```powershell
$body = @{ DiskName = 'data'; ParentDiskPath = '/dev/sdb'; VolumePath = '/mnt/data'; ConfirmDeletion = $false } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/DeleteVolume" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### ShutdownDevice

- **Method and URL:** `POST /ShutdownDevice`. **Request** (`ShutdownRequest`): `{ "DelaySeconds": Int32 }` ("DelaySeconds must be between {0} and {1} seconds"; the limits are not shown). **Response:** bare `Response`.
- **Changes the machine?** **Yes: powers it off** after the delay. Someone must press the power button to bring it back.

```powershell
$body = @{ DelaySeconds = 30 } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/ShutdownDevice" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

#### RestartDevice

- **Method and URL:** `POST /RestartDevice`. **Request** (`RestartRequest`): `{ "DelaySeconds": Int32 }`. **Response:** bare `Response`. Failure: "Failed to restart the node." (retry, or restart manually).
- **Changes the machine?** **Yes: restarts it** after the delay (the service logs `Restarting device in N seconds`).

```powershell
$body = @{ DelaySeconds = 30 } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/RestartDevice" -Method Post -ContentType 'application/json' -Body $body -Authentication Basic -Credential $cred -SkipCertificateCheck
```

**Evidence for the whole storage and power group:** From the service's own metadata; **not called**. The Linux build implements all four (log texts).

## Types in the contract that no operation takes

The contract also defines types that no `IOobeService` operation accepts or returns. They are used inside the service (and describe the shape of the Azure-side job it receives). **From the service's own metadata.** Listed so nothing is left out:

| Type | Fields | Reading |
| --- | --- | --- |
| `ProvisioningRequest` | `Platform`, `PlatformVersion`, `OSProfileConfiguration`, `DownloadRequests[]`, `ArcConfiguration`, `UserConfiguration`, `ConfigurationRequest` | The service's internal form of the Azure `ProvisionOs` job's `provisioningRequest`. |
| `OSProfileConfiguration` | `OSName`, `OSType` (`AzureLinux`, `AzureLinuxRoe`, `HCI`), `OSVersion`, `OSImageUrl`, `VsrVersion` | Mirrors the job's `osProfile`. |
| `DownloadRequest` | `Endpoint` (must be HTTPS) | An image download. |
| `UserConfiguration` | `UserName`, `SecretLocation`, `SecretType` (`PlainText`, `KeyVault`, `SshPubKey`) | The administrator the install creates; mirrors the job's `userDetails`. |
| `ProvisioningResponse`, `LogCollectionResponse` | `Response`, `DestinationPath` | Replies not tied to an operation. |
| `AccessType` (enum) | `None`, `ARCMSI`, `Credential` | Not tied to any field we read. |
| `ConfigurationIntent` (enum) | `User`, `Site` | Field `ConfigurationIntent` of `ConfigurationRequest`. |
| `UpdateInfo`, `ValidatedRecipe*` types | Versions, payload URLs and hashes | The update manifest and the recipe's payloads; used by the update check. |
| `ApplicableUpdates` | `Version`, `SolutionVersion`, `UpdateName` | An entry of `ZeroDaySolutionUpdateConfig.Updates`. |

A list of 20 names seen in the bootstrap management module's contract strings (`n01-bootstrap-management-module.txt`) also holds `UpdateAndArcRegistrationIndependent` and `UpdateOuterConfiguration`. The first is a message text, not an operation (see `StartArcBootstrap`); the second is not an operation of the `IOobeService` interface we read. See [Conflicts and gaps](#conflicts-and-gaps).

## The host name and the Arc resource name

**Host name: it can be set.**

| Where | What | Evidence |
| --- | --- | --- |
| Azure claim | `edgeMachines` `properties.siteDetails.deviceConfiguration.hostName`. azurelocal-ztp sets it to the node name; the edge machine then carries that host name. | **From Azure-side ZTP evidence** (**Verified live**). |
| Configurator service, ME | `HostName` in the device configuration (`SetArcBootstrapDeviceConfiguration`) or `ConfigureHostName`. The `HostName` step reported `NotApplicable` when we sent none. | Step behaviour **Verified live**; the field **From the service's own metadata**, **not called**. |
| Configurator service, OS | `ConfigureHostName` / `StartArcBootstrap`. A rename restarts the machine. | **Documented by Microsoft** (OS-side app). |
| After registration | Refused: "Hostname rename not allowed after Azure registration." | From the service's own metadata. |

**Arc resource name: what we proved, and where.**

1. **Through the Configurator service in the maintenance environment: it cannot be set.** The only way to name an Arc machine in the service is inside an `ArcConfiguration` (`ArcOnboardingConfiguration.ResourceId`), and the service refuses an `ArcConfiguration` in the maintenance environment ("Arc configuration is not supported in the provisioning environment..."). **From the service's own metadata**; the refusal text is read, not triggered. There is no `ResourceName` field in the request types at all; `ResourceName` exists only in the reply of `GetArcBootstrapConfig`.
2. **Through the Azure claim: asking for a name does not work.** The claim sends `arcMachineResourceId` (the 2026-10-01 spec example does). In live runs on 2026-11-07 the service replaced it: the Arc machines came out first as `ROE1-<id>` and then, after the install, as `<device-id>-1`, in the site configuration's managed resource group, not the resource group of the machines. **From Azure-side ZTP evidence** (**Verified live**, several runs, build 2610; ZTP's troubleshooting page "Arc machine names" and `infrastructure-schema-5.md` call it an open research item). Cluster deployment must use each edge machine's `arcMachineResourceId` read after the machine is `Provisioned`, never the host name (Deploy on solution build 12.2690 failed with `ParentResourceNotFound` when the host name was used).
3. **What Microsoft says:** Learn's portal steps tell the person provisioning to "Provide the machine name as the Azure Arc resource name" ([Learn](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning?view=azloc-2610#step-3-provision-machines-from-azure)). On our runs the service named it by device ID anyway. We did not establish whether that is a defect, a preview limitation or intended.
4. **What the Azure job asks for:** the `ProvisionOs` job's `onboardingConfiguration.resourceId` is the Arc machine the job will onboard to. Whether you can set it yourself by writing the job is **not proven**: ZTP never writes the job, the service does.

Conclusion: you can choose the **host name**; you cannot, on this build, choose the **Arc machine name** by any route we tried; read the name Azure assigns.

## Network configuration semantics

All **Verified live** (2026-11-07, Dell AX-760 machines, build 2610) unless marked.

- **The adapter is chosen by MAC address.** The request carries `MacAddress` (12 lower-case hex digits). ZTP finds the target in `GetNetworkAdapters` by MAC, whatever the separators or case you wrote, and sends the digits only.
- **Other adapters are left alone.** The live before-and-after of one machine: six ports on DHCP; after the call, only the named port was static with the new address; the other five kept DHCP and their own leases, unchanged.
- **Static versus DHCP.** `EnableDhcp: false` with `IpAddress`, `SubnetMask`, `Gateway`, `DnsAddressArray` makes the port static. `EnableDhcp: true` returns a port to DHCP; sent on its own for another port (`{ "MacAddress": ..., "EnableDhcp": true }`) it is **not proven live**, and ZTP does not rely on it.
- **A port already holding the address.** If another port of the same machine already holds the target static address, ZTP stops without sending (releasing it is not a proven request shape).
- **VLAN: a number, not a string.** In the Configurator service `VlanId` is an unsigned 16-bit number (`0` was sent and accepted live; the validation text says 1 to 4094, so `0` appears to mean "no VLAN", which is an inference). In the Azure claim, the adapter's `vlanId` is a **string** (the template sends `string(vlan_id)`), while the site network configuration's `vLanId` and Azure's per-NIC `networkConfiguration.vlanId` are integers (live list: `0`). Three places, two types: take care when passing a value between them.
- **Reaching the service afterwards.** If the changed port is the one you connected through, the service is expected to answer on the new static address (azurelocal-ztp tries both). The live runs changed a port other than the connection port, so this was not observed. A read that does not list the target MAC is another device that took the old lease: ignore it.
- **The setting does not survive the OS install.** The install resets every port to DHCP (Verified live). After ZTP the management port has a DHCP address, or none, and OS configuration must set the static again, by MAC (the installed OS names ports `Port0` to `Port6`).
- **Azure's route for the same change is unreliable (observation).** See `ApplyConfiguration` below.

## Reset: what each reset does

**None of these was run by us.**

| | `StartArcBootstrapReset` (service) | `ProvisionOs` with `operationType` `Reset` (Azure) |
| --- | --- | --- |
| What it is | A call to the machine's service | A job written to the edge machine in Azure |
| Documented | No (internal) | The value `Reset` exists in the resource schema ([Learn: edgeMachines/jobs](https://learn.microsoft.com/azure/templates/microsoft.azurestackhci/2026-10-01/edgemachines/jobs#property-values): `operationType`: `Provision`, `ReImage`, `Reset`, `Update`; "Operation sub type of OS Provisioning") |
| Scope (as far as the evidence goes) | The machine's **Arc connection**: reset and cleanup steps (`ResetArc`, `ExtensionCleanup`, `GatewayCleanup`, `AzcmAgentCleanup`, `BootstrapCleanup`) | Not described on any Learn page we read. What `Reset` keeps and removes is **unknown**. |
| Keeps | Not shown. By the step names it keeps the OS and the host configuration, but that is an inference. | Unknown |
| Preconditions | ARM access token required; only for non-deployed devices; not while bootstrap runs; not twice at once; some devices do not support it | Unknown |
| Evidence | From the service's own metadata; **not called** | Documented (enum only); **not run** |

We also know the Azure `ProvisionOs` job can be resubmitted: the same job PUT again (with `osProfile`, `userDetails`, `target` `HCI`) retries a failed OS install, per [Learn: reattempt a failed OS provisioning](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning?view=azloc-2610#reattempt-a-failed-os-provisioning). That is a retry of `Provision`, not a `Reset`. azurelocal-ztp does it once per node on error 5901 and it succeeded each time (**Verified live**).

## Logs the app writes, and how to read them

[Documented by Microsoft](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning?view=azloc-2610#collect-logs-from-your-azure-subscription): connect with PowerShell (or SSH on the maintenance environment) and read:

| Target | Files Learn lists |
| --- | --- |
| Azure Stack HCI (installed OS) | `C:\Windows\System32\Bootstrap\Logs` |
| Maintenance environment | `/var/log/bootstrap`, `/var/log/provisioningextension`, `/var/log/trident-full.log`, `/var/log/messages`, `/var/log/bootstraprestservice` |

What we **found live** on build 2610.0.3063 (as the non-privileged maintenance user; `/var/log` listing, **Verified live**): `/var/log/provisioningextension`, `/var/log/messages`, `/var/log/trident-full.log`, `/var/log/targetprovisionagent`, `/var/log/nodeconfiguration`, `/var/log/nodeconfigurationrestservice`, `/var/log/nodeconfiguration_audit/`, and telemetry files `LinuxBootstrapConfigTelemetry`, `LinuxBootstrapDataConfigTelemetry`, `LinuxProxyConfigTelemetry`. **`/var/log/bootstrap` and `/var/log/bootstraprestservice` did not exist** (`ls: cannot access '/var/log/bootstrap': No such file or directory`). See [Conflicts and gaps](#conflicts-and-gaps). The REST service itself logs through the system log with the process name `Microsoft.Azure.Edge.NodeConfiguration.Linux.RestService`; the management service as `Microsoft.Azure.Edge.NodeConfiguration.Linux.ManagementService`; the provisioning extension as `...CloudPackages.ProvisioningExtension.Service`.

**Line format** (**Verified live**): `<UTC timestamp> <host> <Process>[pid]: [Level] [Component,Method] message`, with `Level` `Info`, `Warning`, `Error` or `Debug`; multi-line values have line breaks written as `#012`. Useful search terms:

| Look for | It tells you |
| --- | --- |
| `[Error]` near `TO2` / `StandardTOProtocolImpl` | The call-home to the Azure onboarding service failed. `Reported Error Code TO2_...` is what was sent to the server. |
| `[ProvisioningWorkItem,SetMainStatus] Failed` | The provisioning work item ended in failure; the line after has the exception type. |
| `[OrchestrationResponseFactory] Update status for category: Bootstrap to Failed` | The moment the `Bootstrap` tree went `Failed`. |
| `RunAZCMAgentCommand` | The Arc agent was asked its state (an empty `resourceName` etc. means not registered yet). |
| `Ownership Voucher has been created at` | Voucher created, with its path. |
| `Now listening on: https://[::]:20001` | The REST service started. |

Reading them from a workstation (SSH key or password per your build; the account is the maintenance user, which cannot use `sudo`):

```powershell
ssh edgeuser@192.0.2.50 'tail -n 200 /var/log/messages | grep -E "Error|Failed"'
```

The Configurator app can also create a support package for you ([Learn](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-collect-system-logs?view=azloc-2610)); the service-level calls behind it are in [Diagnostics and support logs](#diagnostics-and-support-logs).

## Typical errors

| Message | Where it shows | Meaning | Evidence |
| --- | --- | --- | --- |
| `TO2 Protocol failed.` (`RecommendedActions`: `Contact Microsoft Support.`) | `Bootstrap`, `ArcConfiguration`, `ArcRegistration` of the status tree | The machine's call-home to the Azure onboarding service failed; the log has the detail (`TO2MaxServiceInfoTripsException: Exceeded maximum allowed ServiceInfo exchange round trips on the device.`, code `TO2_MaxServiceInfoTripsValidationFailure`). Cause not established. | **Verified live** |
| `Arc configuration is not supported in the provisioning environment. Remove ArcConfiguration from the request and retry.` | A request containing `ArcConfiguration`, in the maintenance environment | Registration is done by Azure there | From the service's own metadata |
| `Service principal authentication is no longer supported. Use device code authentication or an ARM access token.` | Registration request | Refused sign-in method | From the service's own metadata |
| `Site key authentication is no longer supported. Use device code authentication or an ARM access token.` | Registration request | Refused sign-in method | From the service's own metadata |
| `Hostname rename not allowed after Azure registration.` | `ConfigureHostName` / `StartArcBootstrap` | Name is fixed once registered | From the service's own metadata |
| `Operation is only valid for non-deployed devices.` | `StartArcBootstrapReset` | Reset refused on a deployed machine | From the service's own metadata |
| `Authentication to Azure Arc failed. Verification code expired.` | `InvokeDeviceCodeAuthentication` | Reapply the configuration for a new code | From the service's own metadata |
| `The device could not read or update its Azure registration` (error 5901, step `SetupHybridComputeRP`, job code `Retryable`) | Azure `ProvisionOs` job, first attempt | Probably role assignments not yet propagated (not confirmed); resubmitting the job passed in about 2 minutes | **From Azure-side ZTP evidence** (**Verified live**) |
| `Job is not yet triggered as other jobs are still running` | Azure `ApplyConfiguration` job | The queued job never started (see below) | **From Azure-side ZTP evidence** (**Verified live**) |
| HTTP 401 | Any call | Wrong password | Documented by ZTP troubleshooting; **Verified live** |
| `The network configuration is invalid.` / `Review the IP address, subnet mask, gateway, and DNS server settings, then retry.` | Network requests | Bad address, mask, gateway or DNS | From the service's own metadata |
| `Setup is still in progress.` / `Wait a few minutes for setup to finish, then retry.` | Any call made too early | The service is up before setup is done | From the service's own metadata |
| `ConfirmDeletion must be set to true to authorize a destructive volume deletion.` | `DeleteVolume` | Safety guard | From the service's own metadata |
| `Access to files outside the export directory is not allowed.` | Downloads | Path guard | From the service's own metadata |

An error from the service is returned as a fault whose detail is an `ErrorInfo` (`ErrorMessage`, `ExceptionType`, `StackTrace`, `RecommendedActions`). The exact HTTP status and body of a fault were not captured live except for the 401.

## What the portal does through Azure

The Azure portal's **Machine provisioning (preview)** flow does everything through Azure Resource Manager; it never calls the machine's service. azurelocal-ztp deploys the same resource shapes the portal does. Prerequisites ([Documented by Microsoft](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning?view=azloc-2610#azure-prerequisites)): register the feature `Microsoft.DeviceOnboarding` / `AzureLocalZTP` on the subscription, and the `Microsoft.AzureStackHCI` resource provider. In this preview only the `eastus` region is supported ([Learn](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning?view=azloc-2610#when-you-provision-new-machines-you-receive-an-internal-server-error)). Every call, with its request and response, is in the [API reference](./api-reference.md).

| Resource | API version | What it is | Evidence |
| --- | --- | --- | --- |
| `Microsoft.Edge/sites` | 2025-06-01 | The site: groups the machines of one location. Only `displayName`. | **From Azure-side ZTP evidence** (**Verified live**); described by Learn as the Azure Arc site ([Learn](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-zero-touch-provisioning?view=azloc-2610)). |
| `Microsoft.Edge/configurations` (+ `configurationReferences` on the site) | 2025-12-01-preview | The site configuration, with a managed resource group where the Arc machines are created. | **Verified live**. The stable API versions list no properties for it; Learn does not document its properties. |
| `.../configurations/networkConfigurations` | 2025-12-01-preview | `kind` `LAN` or `WLAN`; `ipAssignments.ipAssignmentType` `Automatic` or `Manual`; `ipv4`: `addressRange` {`startIp`, `endIp`}, `defaultGateway`, `dnsServers`, `subnetMask`, `vLanId` (integer); `scenario` `Provisioning`. | **Verified live** |
| `.../configurations/timeServerConfigurations` | 2025-12-01-preview | `ntpConfigurationChoice` (`Automatic`/`Manual`), `ntpServerConfiguration` {`ntpServer`, `alternateNtpServer`}, `timezone`, `scenario`. | **Verified live** (created); the effect on the machine's time was not separately measured. |
| `.../configurations/connectivityConfigurations` | 2025-12-01-preview | `connectivityType` `Public` or `Proxy`, `scenario`. | **Verified live** (created) |
| `.../configurations/securityConfigurations` | 2025-12-01-preview | `secretReferences` with `purpose` `LocalAdminCredentials`, pointing at the Key Vault. | **Verified live** |
| `Microsoft.AzureStackHCI/edgeMachines` (create) | 2026-10-01 | The provisioned machine, claimed with the voucher. See the claim fields below. | **Documented by Microsoft** (resource schema, [Learn](https://learn.microsoft.com/azure/templates/microsoft.azurestackhci/2026-10-01/edgemachines/jobs#property-values)) and **Verified live** (ZTP; 2025-12-01-preview also proven). |
| `Microsoft.AzureStackHCI/locations/{location}/osImages` | 2026-10-01 | Catalogue of OS images (`solution-type=HCI`) and the validated solution recipe version. | **From Azure-side ZTP evidence** |
| `.../edgeMachines/{m}/jobs/ProvisionOs` | 2026-10-01 | The OS-install job. Created by the service at claim time; read to follow progress; rewritten to retry. | **Documented** + **Verified live** |
| `.../edgeMachines/{m}/jobs/{CollectLog, DownloadOs, RemoteSupport}` | 2026-10-01 | Other job types: `CollectLog` (`fromDate`, `toDate`), `DownloadOs`, `RemoteSupport` (`accessLevel`, `expirationTimestamp`, `type`). | **Documented by Microsoft** (schema only); **not run by us** |
| `.../edgeMachines/{m}/networkAdapters` | 2026-10-01 | List of the machine's NICs after the install: `networkConfiguration` (desired) and `reportedProperties` (what the machine reports). | **Verified live** |
| `.../networkAdapters/{name}/jobs/ApplyConfiguration` | 2026-10-01 | Change one NIC from Azure. | **Verified live: it did not run** (below) |
| `Microsoft.DeviceOnboarding` voucher service | (not an ARM call we make) | The FIDO Device Onboard rendezvous and owner services the machine calls home to (`https://onboardingservice-<id>.eastus.deviceonboard.azure.net:443` in the device log). | Device-side calls **Verified live** (the log); a user-callable API is **not shown** by any evidence. |

**The claim** (`edgeMachines` create, **Verified live**; fields as ZTP's template sends them):

- `identity` `SystemAssigned`; `location`.
- `properties.arcMachineResourceGroupId` and `arcMachineResourceId`: where the Arc machine should go and what to call it (the name is overwritten by the service, see [above](#the-host-name-and-the-arc-resource-name)).
- `properties.siteDetails.siteResourceId` and `siteDetails.deviceConfiguration`: `hostName`, and optionally `network.networkAdapters[]`, each `{ ipAssignmentType: "Manual", macAddress, adapterName, ipAddress, subnetMask, gateway, dnsAddressArray, vlanId (string) }`. **Finding:** a Manual adapter's MAC is ignored by the OS install; seen live, the address landed on a different port than the MAC named. So ZTP uses the maintenance-environment path instead (`SetArcBootstrapDeviceConfiguration`) and the claim carries no network adapter.
- `properties.ownershipVoucherDetails`: `ownerKeyType` `MicrosoftManaged`, `ownershipVoucher` (the `.pem` file, base64).
- `properties.provisioningDetails.osProfile` (`osType` `HCI`, `vsrVersion`) and `userDetails[]` (`userName`, `secretType` `KeyVault`, `secretLocation`: the Key Vault secret's **ARM resource ID**; the `https://` secret URI is rejected).
- Role assignments the edge machine's identity needs: Azure Connected Machine Resource Administrator on the resource group (delegated), Key Vault Secrets User on the vault, and the Azure Local resource provider's Azure Connected Machine Resource Manager role. Without the first, the install fails (see error 5901).

**`jobs/ProvisionOs`** ([Documented by Microsoft](https://learn.microsoft.com/azure/templates/microsoft.azurestackhci/2026-10-01/edgemachines/jobs#property-values)):

| Property | Meaning |
| --- | --- |
| `jobType` | `ProvisionOs` |
| `provisioningRequest.target` | `AzureLinux` or `HCI` |
| `provisioningRequest.osProfile.operationType` | `Provision`, `ReImage`, `Reset`, `Update`: "Operation sub type of OS Provisioning". Which value the live installs used is not recorded; the Learn retry script and ZTP's resubmit omit it. |
| `provisioningRequest.osProfile` other | `osType`, `osName`, `osVersion`, `osImageLocation`, `imageHash`, `gpgPubKey`, `vsrVersion` |
| `provisioningRequest.userDetails[]` | `userName`, `secretType`, `secretLocation` |
| `provisioningRequest.deviceConfiguration` | `TargetDeviceConfiguration` (host name and network, as in the claim) |
| `provisioningRequest.onboardingConfiguration` | `type` `HybridComputeMachine`, `resourceId`, `location`, `tenantId`, `arcVirtualMachineId`: the Arc machine to onboard to |
| `provisioningRequest.customConfiguration` | Base64 custom configuration |
| `reportedProperties` | Progress and step results |

Retry body (Learn's script, 2025-12-01-preview there; ZTP uses 2026-10-01): `PUT .../jobs/ProvisionOs` with `{ "properties": { "jobType": "ProvisionOs", "provisioningRequest": { "osProfile": <from the edge machine>, "userDetails": <from the edge machine>, "target": "HCI" } } }`. After a resubmit Azure keeps the earlier attempt's error in `properties.error` while the new attempt runs; read `status`, not that field alone.

**`ApplyConfiguration` (observation, dated).** On 2026-11-07, on two separate runs (Dell AX-760, build 2610), `PUT .../networkAdapters/<name>/jobs/ApplyConfiguration` with `{ "properties": { "jobType": "ApplyConfiguration", "deploymentMode": "Deploy", "targetConfiguration": { ...adapter settings... } } }` returned HTTP 201 and then stayed at `DeploymentInProgress` with `ApplyConfiguration` `NotStarted` and the message **"Job is not yet triggered as other jobs are still running"**; Azure marked it `Failed` after about 35 minutes. It never ran. This is an observation of two runs, not a statement that the job never works. azurelocal-ztp therefore offers it only behind an opt-in switch and recommends OS configuration instead. The shape of the request is from Microsoft's spec examples (`EdgeMachineNetworkAdapterJobs_CreateOrUpdate_ApplyConfiguration`) and the live PUT.

## What is possible, in one view

Where: **ME** = maintenance environment (before the OS is installed), **OS** = installed operating system, **Azure** = from the portal or Azure Resource Manager (no access to the machine needed). **Changes?** says whether it writes. Labels: **V** = Verified live, **M** = From the service's own metadata (not called), **D** = Documented by Microsoft.

| Capability | The call that does it | Where | Changes? | Evidence |
| --- | --- | --- | --- | --- |
| Find a machine by MAC | `GetNetworkAdapters` on each address that answers on 20001 | ME | Read | V |
| Read all ports | `GetNetworkAdapters`; after the install `edgeMachines/{m}/networkAdapters` | ME; Azure | Read | V |
| Set a static IP on one port, chosen by MAC | `SetArcBootstrapDeviceConfiguration` then `GetArcBootstrapDeviceConfigurationStatus` | ME | Changes | V |
| Set a static IP on a port, other ways | `ConfigureNetwork`; claim `siteDetails...networkAdapters` (wrong port seen); `jobs/ApplyConfiguration` (never ran) | ME; Azure; Azure | Changes | M; V (unreliable); V (did not run) |
| Return a port to DHCP | `EnableDhcp: true` in the same request | ME | Changes | M for this use (the shape is not proven live) |
| Set the host name | Claim `siteDetails.deviceConfiguration.hostName` (V); `ConfigureHostName` or `HostName` in the device configuration | Azure; ME / OS | Changes | V; M (OS: D that it restarts) |
| Set the time server and zone | `ConfigureTimeServer`; `TimeServer` in the device configuration; site `timeServerConfigurations` | ME / OS; Azure | Changes | M; M; V (created) |
| Set a web proxy | `ConfigureWebProxy`; `WebProxy` in the device configuration; site `connectivityConfigurations` | ME / OS; Azure | Changes | M; M; V (created) |
| Read where a proxy comes from | `GetMultiSourceWebProxyConfiguration` | not shown | Read | M |
| Enable remote desktop | `RemoteConfiguration.RemoteDesktopConnection` | OS (D: off by default) | Changes | M; D |
| Start Arc registration | `StartArcBootstrap` with `ArcConfiguration` (device code or ARM token) | OS only (refused in ME by the service's message) | Changes | M; D (the app flow) |
| Register in the maintenance environment | Not done by this service; Azure registers the machine during `ProvisionOs` | Azure | Changes | V |
| Sign in for Arc with a device code | `InvokeDeviceCodeAuthentication`, `GetDeviceCodeAuthenticationStatus` | OS | Changes | M |
| Parse an Arc script | `ParseArcScript` | not shown | Read | M |
| Read bootstrap status | `GetArcBootstrapStatus` (OS: `Get-ArcBootstrapStatus`) | ME; OS | Read | V (tree); V (OS cmdlet, 11 Oct 2026) |
| Read the configuration and Arc resource it registered as | `GetArcBootstrapConfig` | not shown | Read | M |
| Reset the Arc connection | `StartArcBootstrapReset`, `GetArcBootstrapResetStatus` | not shown (non-deployed only) | Changes (destructive) | M (not run) |
| Reset or reinstall the OS | Azure `ProvisionOs` with `operationType` `Reset` or `ReImage` | Azure | Changes (destructive) | D (enum only; not run) |
| Retry a failed OS install | Re-PUT `jobs/ProvisionOs` | Azure | Changes | D; V |
| Check prerequisites (TPM, Secure Boot, CPU, RAM) | `GetArcBootstrapPrerequisitesStatus` | not shown | Read | M |
| Run diagnostics | `StartArcBootstrapDiagnostics`, `GetArcBootstrapDiagnosticsStatus` | not shown | Read (writes a report) | M; D (the app feature) |
| Collect support logs | `StartArcBootstrapSupportLogs`, `GetArcBootstrapSupportLogsStatus`, `DownloadArcBootstrapSupportLogs`; or Azure job `CollectLog` | not shown; Azure | Writes a package | M; D; D (schema) |
| Download the ownership voucher | `DownloadOwnershipVoucher`; or SCP from `/var/staging/export/vouchers/<serial>/` | ME | Read | M; D |
| Claim a machine with its voucher | `edgeMachines` create with `ownershipVoucherDetails` | Azure | Changes | D + V |
| Check for updates | `CheckForAvailableUpdates`, `GetArcZeroDaySolutionUpdateConfig` | not shown | Read | M |
| Update the machine's software | `StartArcZeroDaySolutionUpdate`, `GetArcZeroDaySolutionUpdateStatus`; or `ProvisionOs` `operationType` `Update` | not shown; Azure | Changes | M; V (status tree through the OS cmdlet); D (enum) |
| Sideload an OS image or solution extension | `EnablePackageSideload`, `UploadFile`, `CompletePackageSideload`, `GetSideloadInfo`, `DisablePackageSideload` | not shown | Changes | M |
| Create or delete a volume | `CreateVolume`, `DeleteVolume` | not shown | Changes (destructive) | M |
| Shut down or restart | `ShutdownDevice`, `RestartDevice` | not shown | Changes (disruptive) | M |
| Change a local user's password | `UpdateArcBootstrapUserPassword` | not shown | Changes (credential) | M |
| Read serial number, instance GUID, software info, image type, version | `GetDeviceSerialNumber`, `GetInstanceGuid`, `GetSoftwareInfo`, `IsMicrosoftImage`, `GetArcBootstrapVersion` | not shown | Read | M |
| List time zones | `GetTimeZoneIds`, `GetTimeZoneIdsMap` | not shown | Read | M |
| Test the sign-in and certificate handling | `TestConnect` | not shown | Read | M |
| Set the site-wide network, time, proxy, key vault | `Microsoft.Edge/configurations` and its children | Azure | Changes | V |
| Read per-machine provisioning progress | `edgeMachines`, `jobs/ProvisionOs` | Azure | Read | V |

### Not possible or not proven

- **Choosing the Arc resource name.** Not possible through the service in the maintenance environment (`ArcConfiguration` refused, per the service's message). Not possible through the Azure claim on build 2610: the service overwrote the name in every run. Setting `onboardingConfiguration.resourceId` by writing the job yourself: not tried.
- **Anything we saw only in the service's metadata and never called**: 41 of the 45 operations (every one marked "not called" above). Their existence, method and types are known; their behaviour on real hardware is not. This includes everything for reset, diagnostics, support logs, updates, sideload, volumes, power, password and device-code sign-in.
- **A `Reset` or `ReImage` through Azure**, and what `Reset` keeps and removes.
- **Setting the host name, time server, web proxy or remote desktop in the maintenance environment** (the fields exist; we sent none).
- **Returning another port to DHCP in the same request** (`{ "MacAddress", "EnableDhcp": true }`): not proven live.
- **Releasing an address that another port of the machine holds** by request: not a proven shape.
- **Applying a network change from Azure** (`jobs/ApplyConfiguration`): observed not to run, twice, on 2026-11-07. Not shown to be impossible.
- **Using the service on an installed OS from a script**: how to sign in (the SSH-certificate scheme versus Basic) is not shown.
- **A faster or a cancel path**: there is no operation to cancel a running job, and none to read the service's own log. Neither is in the contract.
- **A user-callable `Microsoft.DeviceOnboarding` API**: not shown.
- **Whether a build other than 10.2610.0.3063 matches this page.**

## Conflicts and gaps

Where our sources disagree or leave a question open:

1. **Log folder names.** Learn lists `/var/log/bootstrap` and `/var/log/bootstraprestservice` for the maintenance environment. On the build we read neither exists; the service logs appear in `/var/log/nodeconfiguration`, `/var/log/nodeconfigurationrestservice` and `/var/log/messages`. Either the Learn page describes another build or those paths are not created until later. Not resolved.
2. **Who sets the host name in the maintenance environment.** An earlier description said the Device stage "sets the static management address and the host name on the port with the management MAC" through the Configurator service. ZTP's script and documentation say the opposite: **no `HostName` is sent**; the claim sets the host name. The script and the live logs agree with the latter, and this appendix follows the script.
3. **Build number.** The maintenance image is 10.2610.0.3063 (ZTP's Resolve record); the assemblies we read report file version 10.3544.1.3015. We did not establish how the two relate.
4. **Which call produced the saved failed-run tree.** The file (`n01-to2-failure-full-rerun-...json`) holds a `BootstrapResponse` tree and does not name the call. It is documented here as the `GetArcBootstrapStatus` shape; `StartArcBootstrap` returns the same type.
5. **A list of 20 "contract operations"** in `n01-bootstrap-management-module.txt` differs from the 45-operation interface read from the assembly: it is a string scan of another component, and includes `UpdateAndArcRegistrationIndependent` (a message text) and `UpdateOuterConfiguration` (not an operation of this interface). The 45-operation list is from the interface itself.
6. **`VlanId` `0`.** The service accepted `0` live, but its validation text says 1 to 4094. Taken to mean "no VLAN"; not verified.
7. **Where `ArcConfigurationNotSupportedOnRoe` was observed.** The owner-side understanding is that the Arc onboarding configuration is refused in the maintenance environment. The only evidence on disk is the message text in the compiled resources; no log or response shows the refusal happening.
8. **Port 20002 and the 9098 net.tcp endpoint.** A loopback listener on 20002 exists and nothing says what it is. The net.tcp client endpoint is configured but not listening in the maintenance environment.
9. **Learn's OS-side Configurator app versus the "V2" maintenance-environment app.** Learn describes two apps with the same sign-in model; the contract serves both (`ArcConfiguration` and `AzureLinuxRoe`/`HCI` in one interface). Where Learn's behaviour is for the OS-side app (host name restart, proxy bypass rules, NTP default), it is marked as such.

## Sources

Files read for this appendix (none were changed; no machine was called while writing it):

- Service contract, read with a metadata reader (no code executed): the five assemblies in `oobe-restservice-bin` of the lab evidence folder, and `contract-analysis.txt`; operation attributes (HTTP method, formats, URI templates), every data-contract type, enum value and embedded message text were extracted from them.
- Live calls and device logs of 2026-11-07: `n02-configurator-test.log`, `device-changes.jsonl`, `n01-arcregister-detail.txt`, `n01-to2-failure-*.txt`, `n01-to2-failure-full-rerun-1422Z.json`, `n01-local-rest-service.txt`, `n01-maintenance-logs-run4.txt`, `n01-messages-onboarding-run4.txt`, `n01-provisioningextension-run4.txt`, `n01-bootstrap-management-module.txt`, `n02-applyconfiguration.log`, `n02-networkAdapters-list.json`, `ztp-events.jsonl`.
- azurelocal-ztp (read only): `scripts/simplified-provisioning/Set-ZtpDeviceConfiguration.ps1`, `bicep/main.bicep`, `ZtpAzure.Common.ps1`, `Set-ZtpManagementAddress.ps1`, and the documents `environment-file.md`, `troubleshooting.md`, `azure-provisioning-vouchers.md`, `infrastructure-schema-5.md`, `architecture.md`.
- Microsoft Learn: [Install the operating system and register Azure Local machines by using simplified machine provisioning](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning?view=azloc-2610), [Troubleshoot simplified machine provisioning](https://learn.microsoft.com/azure/azure-local/deploy/troubleshoot-simplified-machine-provisioning?view=azloc-2610), [Configurator App for small form factor deployments](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-configurator-app?view=azloc-2610), [Collect system logs](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-collect-system-logs?view=azloc-2610), [Install the maintenance environment](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-installation?view=azloc-2610), [Zero-touch provisioning](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-zero-touch-provisioning?view=azloc-2610), [Troubleshoot registration using the Configurator app](https://learn.microsoft.com/azure/azure-local/manage/troubleshoot-deployment-configurator-app?view=azloc-2610), [Register Azure Local with Azure Arc without Arc gateway](https://learn.microsoft.com/azure/azure-local/deploy/deployment-without-azure-arc-gateway?view=azloc-2610), and the [Microsoft.AzureStackHCI edgeMachines/jobs template reference](https://learn.microsoft.com/azure/templates/microsoft.azurestackhci/2026-10-01/edgemachines/jobs).

Re-read the service against a new build with the same method before relying on this page for it: dump the interface from the new assemblies, compare the operation list, and re-check the three proven calls.
