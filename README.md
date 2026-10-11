# azurelocal-ztp

> Automation for Microsoft's [Simplified machine provisioning](https://learn.microsoft.com/en-us/azure/azure-local/deploy/simplified-machine-provisioning) feature on Azure Local — bypasses the manual USB-media step using BMC/Redfish.

## What this gets you

Microsoft's official Simplified machine provisioning workflow requires an operator to physically:

1. Create a USB stick from the maintenance-environment ISO.
2. Plug it into each server.
3. Boot the server, wait, repeat for every node.

**This repo bypasses that.** It uses BMC/Redfish (iDRAC, XCC, iLO) to mount the maintenance-environment ISO as virtual media, set the boot source, and reboot — all without anyone in the rack and without USB media.

The end result is identical to the manual flow: each server boots into the maintenance environment, generates an FDO ownership voucher, and is ready to be claimed from the Azure portal. But you can drive it from anywhere with reachability to the BMC network.

## Status

- **Microsoft feature:** Public preview as of azloc-2604 (East US only).
- **This repo:** Active development. CI/CD pipelines are placeholder stubs pending real implementation. Documentation is mid-conversion from AsciiDoc to MkDocs — table layouts may need cleanup.

## Quickstart

```powershell
# 1. Clone
git clone https://github.com/AzureLocal/azurelocal-ztp.git
cd azurelocal-ztp

# 2. Generate a per-cluster config from the reference template
Copy-Item config\cluster-reference.env.template config\cluster-reference.env
# ...edit config\cluster-reference.env with your values...
.\scripts\common\utilities\tools\Generate-ConfigFromReference.ps1

# 3. Discover the BMCs and inventory the hardware
.\scripts\common\utilities\tools\Discover-Servers.ps1

# 4. Mount the maintenance-environment ISO and reboot
.\scripts\common\utilities\tools\Mount-AzureLocalISO.ps1
.\scripts\common\utilities\tools\Set-ServerBootSource.ps1 -BootSource Cd
.\scripts\common\utilities\tools\Restart-Servers.ps1

# 5. Collect ownership vouchers, then claim machines from the Azure portal
#    (see docs/azure-portal-provisioning.md)
```

For the long-form walkthrough, see [docs/server-preparation.md](docs/server-preparation.md).

### Simplified-provisioning scripts (virtual USB, vouchers, Azure)

`scripts/simplified-provisioning/` holds the stage scripts that take nodes from bare metal to Arc-connected machines ready to cluster. Every script is a plan by default and changes hardware or Azure only with an explicit `-Execute`.

```powershell
# Everything in order, resumable (plan by default; settings: config/simplified-provisioning/ztp-provisioning.example.json)
./scripts/simplified-provisioning/Invoke-ZtpProvisioning.ps1 -ConfigPath ./config/simplified-provisioning/ztp-provisioning.json
./scripts/simplified-provisioning/Invoke-ZtpProvisioning.ps1 -ConfigPath ./config/simplified-provisioning/ztp-provisioning.json -BmcCredential $bmc -AdminPassword $admin -ConfirmNotClustered -Execute

# Or stage by stage. Media: one image per node, boot over the BMC, read the vouchers back (no USB stick)
./scripts/simplified-provisioning/New-ZtpVirtualUsbImage.ps1 -SourcePath D:\Media\provision-os.iso -NodeName node-01, node-02 -OutputDirectory D:\ZtpVirtualUsb
./scripts/simplified-provisioning/Start-MaintenanceBoot.ps1 -ImageDirectory D:\ZtpVirtualUsb -ShareHost 192.0.2.10 -NodeName node-01, node-02 -NodesFile ./nodes.json
./scripts/simplified-provisioning/Wait-ZtpVoucher.ps1 -NodeName node-01, node-02 -NodesFile ./nodes.json -ImageDirectory D:\ZtpVirtualUsb -OutputDirectory D:\ZtpVouchers

# Azure: site, configuration and edge machines from the vouchers, then wait for ready
./scripts/simplified-provisioning/Invoke-ZtpAzureProvisioning.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example -ParameterFile ./scripts/simplified-provisioning/bicep/main.parameters.json -VoucherPath D:\ZtpVouchers
```

Read [Redfish virtual USB and voucher read-back](docs/redfish-virtual-usb-vouchers.md) and [Azure provisioning from vouchers](docs/azure-provisioning-vouchers.md) first: they state what is proven on hardware (USB-stick-slot `.img` boot on Dell 16G, a portal-equivalent Azure deployment) and what is not yet proven live (voucher write-back by the maintenance environment, the scripted Azure submit end to end, the `ProvisionOs` retry). Neutral examples: [config/simplified-provisioning/nodes.example.json](config/simplified-provisioning/nodes.example.json) and [scripts/simplified-provisioning/bicep/main.example.parameters.json](scripts/simplified-provisioning/bicep/main.example.parameters.json). Tests: `Invoke-Pester tests/simplified-provisioning`.

## Repository layout

```text
.
├── docs/                       # MkDocs documentation source (mkdocs.yml at root)
├── scripts/
│   ├── common/
│   │   ├── AzureLocalConfig.psm1
│   │   ├── RedfishUtils.psm1   # BMC/Redfish operations — the differentiator
│   │   ├── discovery/          # Hardware inventory
│   │   ├── service-principals/ # Azure SP creation
│   │   └── utilities/          # Standalone tools (mount, boot, restart, etc.)
│   ├── simplified-provisioning/ # Virtual USB images, Redfish boot, voucher read-back, Azure provisioning, Bicep
│   └── Trigger-ZTPDeployment.ps1
├── tests/simplified-provisioning/ # Pester 5 tests and recorded-response fixtures (no hardware, no Azure)
├── config/
│   ├── simplified-provisioning/nodes.example.json  # Node list example (copy to nodes.json, git-ignored)
│   ├── environment.yaml        # Generated, .gitignore'd — your cluster's values
│   ├── environment.json        # Generated, .gitignore'd
│   ├── cluster-reference.env.template   # Template — edit this, then generate
│   └── cluster/cluster-config.md        # Generated/local-only, .gitignore'd
├── .github/                    # CODEOWNERS, ISSUE_TEMPLATE, workflows (stubs)
├── repo-management/            # Repo operations docs (org standard)
└── CLAUDE.md                   # Context for Claude Code sessions
```

## Hardware support

This repo's BMC automation has been validated against:

| Vendor | Model | BMC | Status |
| ------ | ----- | --- | ------ |
| Dell | AX-650, AX-750 | iDRAC 9 / iDRAC 10 | Validated |
| Lenovo | ThinkAgile MX650 V3, V4 | XCC2 | Planned |
| HPE | ProLiant DL360 Gen11 | iLO 6 | Planned |

The Microsoft-validated hardware list for Simplified machine provisioning is the source of truth: [Hardware prerequisites](https://learn.microsoft.com/en-us/azure/azure-local/deploy/simplified-machine-provisioning#hardware-prerequisites). **AX-760 is not on the public-preview list** — don't use it for Simplified machine provisioning even though it appeared in preview.

## Azure prerequisites

```bash
# Register the feature
az feature register --subscription <subId> \
  --namespace Microsoft.DeviceOnboarding --name AzureLocalZTP

# Register the resource providers
for rp in Microsoft.HybridCompute Microsoft.AzureStackHCI \
          Microsoft.DeviceOnboarding Microsoft.Edge Microsoft.GuestConfiguration \
          Microsoft.HybridConnectivity Microsoft.KeyVault Microsoft.ManagedIdentity \
          Microsoft.PolicyInsights Microsoft.Storage Microsoft.Insights; do
  az provider register --namespace $rp
done
```

You also need:

- Resource group **Owner**, or **Contributor** + **Role Based Access Control Administrator** on the target RG.
- A region that supports the feature — currently **East US only**.

## Documentation

Documentation is built with MkDocs (`mkdocs.yml`). To run locally:

```bash
pip install mkdocs mkdocs-material
mkdocs serve
```

Key pages:

- [Server preparation](docs/server-preparation.md) — the BMC-automation walkthrough
- [Azure portal provisioning](docs/azure-portal-provisioning.md) — voucher claim, site config
- [Redfish virtual USB and voucher read-back](docs/redfish-virtual-usb-vouchers.md) — per-node images, BMC boot, vouchers from the image
- [Azure provisioning from vouchers](docs/azure-provisioning-vouchers.md) — site, configuration, edge machines, wait for ready, Arc machine names
- [Single-node S2D deployment](docs/single-node-s2d-deployment.md)
- [Automation pipelines](docs/automation-pipelines.md) — planned CI/CD surface (currently stubs)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). This repo follows the org-wide [AzureLocal standards](https://azurelocal.cloud/standards/) — see [STANDARDS.md](STANDARDS.md).

## License

[MIT](LICENSE).
