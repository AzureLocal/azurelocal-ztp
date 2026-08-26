# Repo intent — azurelocal-ztp

**Automation for Microsoft's Simplified Machine Provisioning feature on Azure Local — bypasses the manual USB-media step using BMC/Redfish.**

## What this repo is

Microsoft's official Simplified Machine Provisioning workflow requires an
operator to physically create a USB stick from the maintenance-environment ISO,
plug it into each server, and boot — repeated per node. **This repo bypasses
that**, using BMC/Redfish (iDRAC, XCC, iLO) to mount the maintenance-environment
ISO as virtual media, set the boot source, and reboot remotely. End result is
identical to the manual flow: each server boots into the maintenance
environment, generates an FDO ownership voucher, and is ready to be claimed from
the Azure portal — but drivable from anywhere with BMC network reachability.

## Status

Microsoft feature: Public preview as of azloc-2604 (East US only). This repo:
active development — CI/CD pipelines are placeholder stubs pending real
implementation; documentation is mid-completion.
