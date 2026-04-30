# Azure Local ZTP

> Zero-touch automation for Microsoft's [Simplified machine provisioning](https://learn.microsoft.com/en-us/azure/azure-local/deploy/simplified-machine-provisioning) feature (public preview, azloc-2604).

## What this repo does

Microsoft's official Simplified machine provisioning workflow requires an operator to physically:

1. Create a USB stick from the maintenance-environment ISO.
2. Plug it into each server.
3. Boot the server, wait, eject, repeat.

**This repo bypasses that.** It uses BMC/Redfish (iDRAC, XCC, iLO) to mount the maintenance-environment ISO as virtual media, set the boot source, and reboot — without anyone having to touch a USB stick or be physically in the rack.

The result is the same: each server boots into the maintenance environment, generates an FDO ownership voucher, and is ready to be claimed from the Azure portal. But you can drive it from anywhere.

## What this repo is not

This is **not** a replacement for the Microsoft documentation. It is the *automation layer* on top of it. The voucher claiming, site configuration, and Azure-side provisioning steps still happen in the Azure portal — see [Azure portal provisioning](azure-portal-provisioning.md).

## Status

- **Microsoft feature:** Public preview as of azloc-2604 (East US only)
- **This repo:** Active development; pipelines are stubbed pending real implementation. See [Automation pipelines](automation-pipelines.md).

## Where to start

| If you want to... | Read |
|------|------|
| Bring up servers via BMC automation (the differentiator) | [Server preparation](server-preparation.md) |
| Claim machines and configure the Azure side | [Azure portal provisioning](azure-portal-provisioning.md) |
| Deploy a single-node Azure Local instance | [Single-node S2D deployment](single-node-s2d-deployment.md) |
| Understand the planned CI/CD pipeline surface | [Automation pipelines](automation-pipelines.md) |

## Hardware support

This repo's BMC automation has been validated against:

- **Dell** — iDRAC 9 / iDRAC 10 (AX-650, AX-750)
- **Lenovo** — XCC2 (ThinkAgile MX650 V3, V4) — *planned*
- **HPE** — iLO 6 (ProLiant DL360 Gen11) — *planned*

The Microsoft-validated hardware list for Simplified machine provisioning is the source of truth: [Hardware prerequisites](https://learn.microsoft.com/en-us/azure/azure-local/deploy/simplified-machine-provisioning#hardware-prerequisites).
