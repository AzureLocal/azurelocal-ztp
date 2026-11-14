# Redfish virtual USB and voucher read-back

> Boot every node into the Azure Local maintenance environment from a per-node virtual USB image over the BMC, then read each node's ownership voucher straight out of that image. No USB stick, no one in the rack.

This page covers the media half of simplified machine provisioning: **build the images, boot the nodes, collect the vouchers**. The Azure half (claiming the vouchers, provisioning, waiting for ready) is in [Azure provisioning from vouchers](azure-provisioning-vouchers.md).

All scripts live in `scripts/simplified-provisioning/`. Every script is a plan by default and changes nothing until you pass `-Execute`.

## What is proven and what is not

| Area | State |
|------|-------|
| Booting the maintenance environment `10.2610.0.3063` from a raw `.img` on the BMC **USB-stick (RemovableDisk) slot** | **Proven on Dell AX-760 / iDRAC 7.30**, two nodes in parallel. |
| Pure-PowerShell image writer (GPT, one FAT32 partition labelled `CDROM`) and the matching reader | Proven on hardware, and by the Pester suite with synthetic media. |
| Read-write mount, one-time boot, reset, eject | **Proven on Dell AX-760 / iDRAC 7.30**, with the iDRAC 7.30 handling described in [iDRAC quirks](troubleshooting.md#idrac-quirks). |
| The maintenance environment **writing the voucher back** into the read-write image | **Proven on Dell AX-760 / iDRAC 7.30.** The Configurator App fallback below is still there. |
| Booting the same content as an **ISO on the iDRAC CD slot** | **Failed** (`sr0` medium errors). Use the USB-stick slot image. |

To run all of this as part of the whole flow, use the [Operator guide](operator-guide.md). This page explains the mechanism and how to call the scripts one at a time.

## How it works

1. `New-ZtpVirtualUsbImage.ps1` writes one raw disk image per node. It copies the contents of the maintenance ISO onto a GPT disk with **one FAT32 partition labelled `CDROM`**, the same layout Microsoft's `usb_prep.exe` produces. Optionally it adds the `edgeuser` password hash.
2. `Publish-MaintenanceIso.ps1 -ReadWrite` shares the image folder over SMB to one generated account (password only in memory), open only to your BMC addresses on TCP 445.
3. `Mount-ZtpVirtualUsb.ps1` inserts each node's image on the BMC USB-stick slot over CIFS, writable, and **reads back** that the image is attached. It sets a **one-time boot** to that slot and, with `-Restart`, power-cycles the node. Then it watches the BMC log for 10 minutes and fails if the installed OS boots instead. On iDRAC 7.30, writable means the manager attribute `RFS.<n>.WriteProtected = Read Write` (`-RfsWriteAttribute`), and the one-time boot is `Once/Floppy`, because the USB-stick slot boots as virtual floppy (`vFDD`) on that firmware. See [iDRAC quirks](troubleshooting.md#idrac-quirks).
4. The maintenance environment installs itself (about 20 to 30 minutes) and writes the voucher back to the one writable USB drive it finds, under `\vouchers\<serial>\`.
5. `Wait-ZtpVoucher.ps1` polls the image, ejects the media, reads the image exclusively with `Read-ZtpVoucherFromImage.ps1` and writes `<serial>.pem` per node.

`Start-MaintenanceBoot.ps1` runs steps 2 and 3 in one process (the share credential never leaves memory).

## Prerequisites

- PowerShell 7 on a Windows host that the BMCs can reach on TCP 445 (the SMB share) and that can reach each BMC on HTTPS.
- An elevated session for the share, the local account and the firewall rule (`Publish-MaintenanceIso.ps1`) and for mounting an ISO (`Mount-DiskImage`).
- The maintenance-environment ISO from Microsoft (Azure Local, simplified machine provisioning downloads), or a folder with its extracted contents.
- A BMC account per node (Redfish, virtual media and power). Pass it as a `PSCredential`; nothing is stored.
- A node list with the **service tag** (serial number) and BMC address of every node, see below.

## The node list

Every script takes nodes explicitly, either as objects (`-Nodes`) or from a file (`-NodesFile`). There is no hidden lookup.

```powershell
Copy-Item config/simplified-provisioning/nodes.example.json ./nodes.json
# edit ./nodes.json: name, service_tag (Dell service tag) and bmc_address of each node
```

```json
{
  "nodes": [
    { "name": "node-01", "service_tag": "EXAMPLE1", "bmc_address": "198.51.100.11" },
    { "name": "node-02", "service_tag": "EXAMPLE2", "bmc_address": "198.51.100.12" }
  ]
}
```

The same shape works as `-Nodes @([pscustomobject]@{ name = 'node-01'; service_tag = 'EXAMPLE1'; bmc_address = '198.51.100.11' })`. YAML files (`.yml`, `.yaml`) are read when the `powershell-yaml` module is installed. Keep your real node list out of git (it is ignored by the repo's `.gitignore`).

## All stages with one command

The orchestrator runs these steps as its Boot, Bootstrap and Vouchers stages, together with the Device, Azure, Ready, Network, Restore and Handoff stages, and checks each result before the next. Use the [Operator guide](operator-guide.md) for the whole flow from an environment file, or the [Orchestrator reference](automated-bootstrap.md) to drive the orchestrator directly. For the Configurator App fallback, rerun the Vouchers stage with `-VoucherFolder`.

## Step by step

### 1. Build one image per node

```powershell
$edgeUserPassword = Read-Host -AsSecureString 'edgeuser password'

./scripts/simplified-provisioning/New-ZtpVirtualUsbImage.ps1 `
    -SourcePath D:\Media\provision-os.iso `
    -NodeName node-01, node-02 `
    -OutputDirectory D:\ZtpVirtualUsb `
    -EdgeUserPassword $edgeUserPassword
```

Without `-Execute` this prints the plan only. Add `-Execute` to write the files. The first image is built and the others are byte-identical copies named `ztp-usb-node-01.img`, `ztp-usb-node-02.img`. **One image per node is required**: each maintenance environment writes its own voucher into the media it booted from.

- `-SourcePath` is the ISO or an extracted folder. An ISO is mounted read-only with `Mount-DiskImage`, which **needs an elevated session**. Without elevation, extract the ISO and pass the folder.
- `-EdgeUserPassword` is optional. It writes only the SHA-512 crypt hash to `prov_config\download\hash_password.txt`; without it `edgeuser` stays locked. The password itself is never written.
- `-SizeBytes` defaults to 4 GiB (a size that booted on Dell 16G). `-Force` replaces existing images.

### 2. Boot the nodes

Plan first (no share, no BMC call):

```powershell
./scripts/simplified-provisioning/Start-MaintenanceBoot.ps1 `
    -ImageDirectory D:\ZtpVirtualUsb -ShareHost 192.0.2.10 `
    -NodeName node-01, node-02 -NodesFile ./nodes.json
```

Then run it for real:

```powershell
$bmcCredential = Get-Credential   # BMC account

./scripts/simplified-provisioning/Start-MaintenanceBoot.ps1 `
    -ImageDirectory D:\ZtpVirtualUsb -ShareHost 192.0.2.10 `
    -NodeName node-01, node-02 -NodesFile ./nodes.json `
    -Credential $bmcCredential -Restart -ConfirmNotClustered `
    -RfsWriteAttribute -SkipCertificateCheck -Execute
```

- `-ShareHost` is the address of this host **as the BMCs reach it**.
- `-Restart` power-cycles each node into the one-time USB boot. It is **refused without `-ConfirmNotClustered`**, because the maintenance boot reinstalls the machine. Never run it against a node that carries a cluster you want to keep.
- `-SkipCertificateCheck` accepts the BMC's self-signed certificate.
- `-RfsWriteAttribute` sets the iDRAC manager attribute `RFS.<n>.WriteProtected = Read Write` with a Redfish PATCH on `/redfish/v1/Managers/iDRAC.Embedded.1/Attributes` before the insert, and leaves `WriteProtected` out of `InsertMedia`. Eject sets it back to `Read Only`. **Required on iDRAC 7.30**, which rejects `WriteProtected=false` in `InsertMedia` (`IDRAC.2.9.SYS458`).
- `-ReadOnlyMedia` shares and inserts read-only. It boots, but the maintenance environment then cannot write the voucher back.

Without `-RfsWriteAttribute`, if the BMC reports the image as write-protected after the insert, `Mount-ZtpVirtualUsb.ps1` stops with an error that points to `-RfsWriteAttribute`. With it, iDRAC 7.30 still reports `WriteProtected=True` although the share is opened for write; the script warns and continues, and the voucher in the image proves write access. **Leave the media inserted** until the voucher has been read: the maintenance environment writes to it after it has installed itself.

On iDRAC 7.30, `Usb` isn't an allowed boot override target. When a BMC doesn't offer `Usb`, the script takes the one-time boot from the OEM definition (`-Oem`, from `hardware.vendor`): `bmc.usbBootOnce` names the manager attributes to set and the standard override target to set with them. For Dell (`config/oem/dell.json`) that is `ServerBoot.1.FirstBootDevice = vFDD` with `BootOnce`, and the override `Once/Floppy`; the script doesn't reset until the system reports it. Without `-Oem`, or with a definition that has no `bmc.usbBootOnce`, such a BMC fails the mount before any restart. After the reset it watches the iDRAC log for 10 minutes; `OSE1002`, logged on the live runs as "C: boot completed", means the installed OS booted, and the node fails. If a run fails during Boot, check that the media is ejected and the one-time boot is cleared before you retry (`-Action Status`).

You can also call the stages separately, with explicit parameters: `Publish-MaintenanceIso.ps1`, then `Mount-ZtpVirtualUsb.ps1 -Action Mount`. `Mount-ZtpVirtualUsb.ps1 -Action Status` shows the slot, power state and boot override (read-only).

### 3. Collect the vouchers

```powershell
./scripts/simplified-provisioning/Wait-ZtpVoucher.ps1 `
    -NodeName node-01, node-02 -NodesFile ./nodes.json `
    -ImageDirectory D:\ZtpVirtualUsb -OutputDirectory D:\ZtpVouchers `
    -Credential $bmcCredential -SkipCertificateCheck -Execute
```

`Wait-ZtpVoucher.ps1` polls every image (read-only, shared with the BMC's open handle) until `\vouchers\<service tag>\*.pem` holds a complete, valid voucher or `-TimeoutMinutes` (default 120) runs out. For each ready node it ejects the virtual media so the BMC closes the file, reads the image exclusively and writes `D:\ZtpVouchers\<serial>.pem`. Without `-Execute` nothing is ejected. iDRAC 7.30 can answer the eject with HTTP 500 (`VRM0010`) just after the node writes to the image; the eject is retried up to 6 times, 30 seconds apart.

Vouchers are secrets: whoever holds one can claim the machine. Restrict the folder they're written to, and never commit them.

To read images you already have, use `Read-ZtpVoucherFromImage.ps1` directly (`-ReportOnly` lists everything without throwing).

### 4. Clean up

```powershell
./scripts/simplified-provisioning/Mount-ZtpVirtualUsb.ps1 -NodeName node-01, node-02 -NodesFile ./nodes.json -Credential $bmcCredential -Action Eject -SkipCertificateCheck -Execute
./scripts/simplified-provisioning/Publish-MaintenanceIso.ps1 -Remove -ShareName ztp-virtual-usb -Execute
```

`-Remove` deletes the share, the firewall rule and the generated account. The image folder is kept.

## Voucher validation and safety

- The voucher is validated before it is accepted: one `OWNERSHIP VOUCHER` PEM block, base64 that decodes to a CBOR array of five items (an FDO ownership voucher), and the node's service tag present inside it.
- A voucher is mapped to a node by its folder name. If the maintenance environment could not read the serial and used a GUID folder, the serial inside the voucher decides. An image that holds another node's voucher is flagged.
- Voucher contents are **never printed and never written anywhere except `<serial>.pem`**. An existing, different `<serial>.pem` is not replaced without `-Force`.
- The image is opened read-only by the reader. By default the open fails while the BMC holds the image, so eject first (`-AllowOpenImage` reads a possibly half-written file, for probing only).
- The share account has a random 32-character password that exists only in memory and is rotated on every publish. The share grants change rights to that one account only, and the firewall rule admits only the BMC addresses you listed.
- BMC passwords are used for the request only and never appear in output or error messages.

## Caveats

- **One partition only.** The image has exactly one FAT32 partition labelled `CDROM`. The maintenance environment copies the voucher to the first writable partition of the one writable USB drive it finds; do not add partitions or attach other writable USB media.
- **Configurator App fallback.** If no voucher appears, download the vouchers with Microsoft's Configurator App and run `Wait-ZtpVoucher.ps1 -NodeName ... -NodesFile ... -VoucherFolder <folder> -OutputDirectory <folder>`. This **only works if the maintenance environment's own USB export did not already happen**; once the export has run, the app can no longer fetch them.
- **ISO source needs elevation.** `New-ZtpVirtualUsbImage.ps1` mounts an ISO with `Mount-DiskImage`, which needs an elevated session. Otherwise pass an extracted folder.
- **No ISO on the CD slot.** An ISO on the iDRAC CD virtual media slot failed in testing (`sr0` medium errors). Use the USB-stick slot image.
- **Preview.** The Microsoft feature is in public preview and East US only. Check the [Microsoft hardware prerequisites](https://learn.microsoft.com/en-us/azure/azure-local/deploy/simplified-machine-provisioning#hardware-prerequisites) for your server model.
- **The share is a tampering risk while it's up.** The machine boots from it. It's limited to the BMC addresses and one account, and it's removed after the vouchers are read. Consider requiring SMB signing on the host, and test that your BMC still connects.
- Verified BMC platform: Dell iDRAC; the end-to-end flow is **proven on Dell AX-760 / iDRAC 7.30**. Other vendors' BMCs (Lenovo XCC, HPE iLO) expose Redfish virtual media too, but the USB-stick slot handling is not verified there.

## Script reference

Every Redfish call these scripts make is in [Appendix A: API reference](appendix/api-reference.md#redfish-on-the-bmc).

| Script | Purpose |
|--------|---------|
| `New-ZtpVirtualUsbImage.ps1` | Build the per-node `.img` files. |
| `Publish-MaintenanceIso.ps1` | Share the images read-write to the BMCs, or `-Remove` the share. |
| `Mount-ZtpVirtualUsb.ps1` | `-Action Mount`, `Eject` or `Status` on the BMC USB-stick slot. |
| `Start-MaintenanceBoot.ps1` | Publish and mount for all nodes in one process. |
| `Wait-ZtpVoucher.ps1` | Wait for the vouchers, eject, extract; or take Configurator App vouchers. |
| `Read-ZtpVoucherFromImage.ps1` | Read and validate vouchers from images. |
| `ZtpVirtualUsb.Common.ps1`, `ZtpRedfish.Common.ps1` | Shared image writer/reader, voucher validation and the Redfish client. |

Use `Get-Help ./scripts/simplified-provisioning/<script>.ps1 -Full` for every parameter.

## Next steps

Continue with [Azure provisioning from vouchers](azure-provisioning-vouchers.md). After the machines are ready to cluster, the Network, Restore and Handoff stages finish ZTP; see [Design and architecture](architecture.md#stages-and-gates). OS configuration comes next, before Validate and Deploy; see [Where ZTP ends](architecture.md#where-ztp-ends). Cluster deployment is outside this repository.
