# Redfish virtual USB and voucher read-back

> Boot every node into the Azure Local maintenance environment from a per-node virtual USB image over the BMC, then read each node's ownership voucher straight out of that image. No USB stick, no one in the rack.

This page covers the media half of simplified machine provisioning: **build the images, boot the nodes, collect the vouchers**. The Azure half (claiming the vouchers, provisioning, waiting for ready) is in [Azure provisioning from vouchers](azure-provisioning-vouchers.md).

All scripts live in `scripts/simplified-provisioning/`. Every script is a plan by default and changes nothing until you pass `-Execute`.

## What is proven and what is not

| Area | State |
|------|-------|
| Booting the maintenance environment from a raw `.img` on the BMC **USB-stick (RemovableDisk) slot** | Proven on a Dell 16G server (iDRAC). |
| Pure-PowerShell image writer (GPT, one FAT32 partition labelled `CDROM`) and the matching reader | Proven by the Pester suite with synthetic media; the image layout booted on hardware. |
| Read-write mount with read-back proof, one-time USB boot, eject | Covered by the Pester suite against mocked Redfish. The same insert, one-time boot and restart sequence with a **write-protected** image booted on hardware; the read-write variant is **not yet proven live**. |
| The maintenance environment **writing the voucher back** into the read-write image | **Not yet proven live.** The scripts, the reader and the validation are built for it. If the voucher does not appear, use the Configurator App fallback below. |
| Booting the same content as an **ISO on the iDRAC CD slot** | **Failed** (`sr0` medium errors). Use the USB-stick slot image. |

The media can be built from the newest maintenance ISO automatically and the boot can be watched end to end: see [Automated bootstrap](automated-bootstrap.md) and [Bootstrap media and the OEM SBE](bootstrap-media-and-sbe.md). A maintenance ISO of the 2610 train (`10.2610.0.3061`) was downloaded, turned into a per-node image and read-back checked on 15 Oct 2026 without hardware; booting it is not yet proven.

## How it works

1. `New-ZtpVirtualUsbImage.ps1` writes one raw disk image per node. It copies the contents of the maintenance ISO onto a GPT disk with **one FAT32 partition labelled `CDROM`**, the same layout Microsoft's `usb_prep.exe` produces. Optionally it adds the `edgeuser` password hash.
2. `Publish-MaintenanceIso.ps1 -ReadWrite` shares the image folder over SMB to one generated account (password only in memory), open only to your BMC addresses on TCP 445.
3. `Mount-ZtpVirtualUsb.ps1` inserts each node's image on the BMC USB-stick slot over CIFS with `WriteProtected=false`, **reads back** that the image is attached and not write-protected, sets a **one-time USB boot** and, with `-Restart`, power-cycles the node.
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

`Invoke-ZtpProvisioning.ps1` runs the whole flow in order: **Media** (images), **Boot** (share, mount, one-time boot), **Vouchers** (read back, or the Configurator App folder), **Azure** (site, configuration, edge machines; see [Azure provisioning from vouchers](azure-provisioning-vouchers.md)) and **Ready** (wait, Arc machine names, Arc check). It checks each stage's result before the next one starts: an image per node, every node booted with a writable image, a valid voucher per node, the deployment accepted, every machine ready to cluster.

Without `-Execute` it prints the stage table, the command of every stage and the plan of the next stage, and changes nothing. With `-Execute` it records each completed stage in a state file (`./ztp-provisioning.state.json` by default) and a rerun resumes at the first stage that did not complete. `-Stage <name>` runs one stage again, `-From <name>` runs a stage and every later one again, `-ResetState` forgets the record.

Settings come from parameters or from a JSON file whose keys are the parameter names: copy `config/simplified-provisioning/ztp-provisioning.example.json` to `ztp-provisioning.json` and edit it. Credentials and passwords are never in that file; pass them as parameters.

```powershell
$bmc = Get-Credential -Message 'BMC account'
$admin = Read-Host -AsSecureString -Prompt 'Provisioning administrator password'
./scripts/simplified-provisioning/Invoke-ZtpProvisioning.ps1 -ConfigPath ./config/simplified-provisioning/ztp-provisioning.json          # plan
./scripts/simplified-provisioning/Invoke-ZtpProvisioning.ps1 -ConfigPath ./config/simplified-provisioning/ztp-provisioning.json -BmcCredential $bmc -AdminPassword $admin -ConfirmNotClustered -Execute
./scripts/simplified-provisioning/Invoke-ZtpProvisioning.ps1 -ConfigPath ./config/simplified-provisioning/ztp-provisioning.json -BmcCredential $bmc -Stage Vouchers -VoucherFolder D:\Downloads\vouchers -Execute
```

The orchestrator is unit-tested with stub stages; it has not yet run end to end on hardware.

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
    -SkipCertificateCheck -Execute
```

- `-ShareHost` is the address of this host **as the BMCs reach it**.
- `-Restart` power-cycles each node into the one-time USB boot. It is **refused without `-ConfirmNotClustered`**, because the maintenance boot reinstalls the machine. Never run it against a node that carries a cluster you want to keep.
- `-SkipCertificateCheck` accepts the BMC's self-signed certificate.
- `-RfsWriteAttribute` also sets the iDRAC `RFS.<n>.WriteProtected` attributes to `Read Write` before the insert, for firmware that ignores `WriteProtected` in the insert request. They are set back to `Read Only` on eject.
- `-ReadOnlyMedia` shares and inserts read-only. It boots, but the maintenance environment then cannot write the voucher back.

If the BMC reports the image as write-protected after the insert, `Mount-ZtpVirtualUsb.ps1` stops with an error that points to `-RfsWriteAttribute`. **Leave the media inserted** until the voucher has been read: the maintenance environment writes to it after it has installed itself.

You can also call the stages separately, with explicit parameters: `Publish-MaintenanceIso.ps1`, then `Mount-ZtpVirtualUsb.ps1 -Action Mount`. `Mount-ZtpVirtualUsb.ps1 -Action Status` shows the slot, power state and boot override (read-only).

### 3. Collect the vouchers

```powershell
./scripts/simplified-provisioning/Wait-ZtpVoucher.ps1 `
    -NodeName node-01, node-02 -NodesFile ./nodes.json `
    -ImageDirectory D:\ZtpVirtualUsb -OutputDirectory D:\ZtpVouchers `
    -Credential $bmcCredential -SkipCertificateCheck -Execute
```

`Wait-ZtpVoucher.ps1` polls every image (read-only, shared with the BMC's open handle) until `\vouchers\<service tag>\*.pem` holds a complete, valid voucher or `-TimeoutMinutes` (default 120) runs out. For each ready node it ejects the virtual media so the BMC closes the file, reads the image exclusively and writes `D:\ZtpVouchers\<serial>.pem`. Without `-Execute` nothing is ejected.

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
- Verified BMC platform: Dell 16G servers (iDRAC). Other vendors' BMCs (Lenovo XCC, HPE iLO) expose Redfish virtual media too, but the USB-stick slot handling is not verified there.

## Script reference

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

Continue with [Azure provisioning from vouchers](azure-provisioning-vouchers.md). OEM solution builder extension (SBE) driver and node preparation, and the cluster deployment itself, come after provisioning and are outside this repository. One worked example is the NIC 2026 Azure Local public repository at <https://github.com/thisismydemo/nic2026_azl> (published after the event, if it is not available yet).
