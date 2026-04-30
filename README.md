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
│   └── Trigger-ZTPDeployment.ps1
├── config/
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

The Microsoft-validated hardware list for Simplified machine provisioning is the source of truth: [Hardware prerequisites](https://learn.microsoft.com/en-us/azure/azure-local/deploy/simplified-machine-provisioning#hardware-prerequisites). **AX-760 is not on the public-preview list** — don't use it for Simplified machine provisioning even though it appeared in private preview.

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
- [Single-node S2D deployment](docs/single-node-s2d-deployment.md)
- [Automation pipelines](docs/automation-pipelines.md) — planned CI/CD surface (currently stubs)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). This repo follows the org-wide [AzureLocal standards](https://azurelocal.cloud/standards/) — see [STANDARDS.md](STANDARDS.md).

## License

[MIT](LICENSE).
