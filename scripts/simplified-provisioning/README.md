# Simplified provisioning scripts

Stage scripts that take nodes from bare metal to Arc-connected machines ready to cluster, using Microsoft's Simplified machine provisioning (preview, East US only) without a physical USB stick. PowerShell 7. Every script is a **plan by default**; hardware and Azure change only with an explicit `-Execute`.

Docs: [Redfish virtual USB and voucher read-back](../../docs/redfish-virtual-usb-vouchers.md) and [Azure provisioning from vouchers](../../docs/azure-provisioning-vouchers.md). Both state what is proven live and what is not.

## Stages and scripts

| Stage | Script | What it does |
|-------|--------|--------------|
| All | `Invoke-ZtpProvisioning.ps1` | Runs the five stages below in order, checks each result before the next, records completed stages in a state file and resumes there (`-Stage`, `-From`, `-ResetState`). Settings from parameters or a JSON file (`-ConfigPath`). |
| Media | `New-ZtpVirtualUsbImage.ps1` | One raw `.img` per node: GPT, one FAT32 partition labelled `CDROM`, maintenance ISO contents, optional `edgeuser` hash. |
| Boot | `Publish-MaintenanceIso.ps1` | Read-write SMB share for the images, one generated account, TCP 445 only from the BMCs; `-Remove` undoes it. |
| Boot | `Mount-ZtpVirtualUsb.ps1` | `-Action Mount`, `Eject`, `Status` on the BMC USB-stick slot; read-back proof, one-time USB boot, `-Restart` needs `-ConfirmNotClustered`. |
| Boot | `Start-MaintenanceBoot.ps1` | Publish and mount for all nodes in one process. |
| Vouchers | `Wait-ZtpVoucher.ps1` | Wait for the voucher in each image, eject, extract `<serial>.pem`; `-VoucherFolder` takes Configurator App vouchers. |
| Vouchers | `Read-ZtpVoucherFromImage.ps1` | Read and validate vouchers from images (read-only). |
| Azure | `Get-ZtpOsImage.ps1` | List or resolve the OS image versions (read-only). |
| Azure | `Invoke-ZtpAzureProvisioning.ps1` | Prereqs, Validate, Plan, Execute, Watch: site, configuration and edge machines from `bicep/main.bicep`. |
| Ready | `Wait-ZtpMachineReady.ps1` | Poll edge machines and `ProvisionOs` jobs until ready to cluster; `-RetryProvisionOs -Execute` resubmits a failed job. |
| Ready | `Update-ArcMachineNames.ps1` | Node to Arc machine name rows; `-MapPath` JSON map. |
| Ready | `Test-ProvisionedMachines.ps1` | Read-only check that the Arc machines are connected with the mandatory extensions. |

Shared code (dot-sourced, no secrets in output): `ZtpVirtualUsb.Common.ps1` (image writer and reader, voucher validation, node list), `ZtpRedfish.Common.ps1` (small Redfish client), `ZtpAzure.Common.ps1` (ARM transport, status logic, OS image catalog).

## Design rules

- **Explicit inputs.** No hidden environment lookups. Nodes come from `-Nodes` or `-NodesFile`, the BMC account from `-Credential`, Azure values from script parameters and the parameters file.
- **Plan by default.** `-Execute` is required to change hardware or Azure. `-Restart` is refused without `-ConfirmNotClustered`. A `ProvisionOs` retry needs both `-RetryProvisionOs` and `-Execute`.
- **Secrets stay in memory.** BMC passwords, the share password, the administrator password and the vouchers are never printed or written, except the voucher to `<serial>.pem`.
- **Each stage is callable alone** with explicit parameters, so an orchestrator can call them in order (Media, Boot, Vouchers, Azure, Ready).

## Examples

- `../../config/simplified-provisioning/ztp-provisioning.example.json`: settings of `Invoke-ZtpProvisioning.ps1` (keys are its parameter names; no secrets).
- `../../config/simplified-provisioning/nodes.example.json`: node list (`name`, `service_tag`, `bmc_address`).
- `bicep/main.example.parameters.json`: Azure parameters (copy to `main.parameters.json`, git-ignored).

## Tests

```powershell
Invoke-Pester ./tests/simplified-provisioning
Invoke-ScriptAnalyzer -Path ./scripts/simplified-provisioning -Recurse -Severity Error, Warning
```

The tests build images in a temporary folder and mock every Redfish and ARM call.
