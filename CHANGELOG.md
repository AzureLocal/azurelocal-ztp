# Changelog

All notable changes to this project are documented in this file. Releases and entries are managed by [release-please](https://github.com/googleapis/release-please) — do not edit by hand.

## Unreleased

### Refactor

- The old configuration layer is retired: `scripts/common` (`AzureLocalConfig.psm1`, `RedfishUtils.psm1`, `config-loader.ps1`, `keyvault-helper.ps1`, the discovery, service-principal and utility scripts), `scripts/tools`, `scripts/examples`, `scripts/Trigger-ZTPDeployment.ps1`, `config/cluster-reference.env.template`, `config/cluster/cluster-config.md.template` and `docs/server-preparation.md`. Every job they did is done by `scripts/simplified-provisioning` or by azurelocal-toolkit (see `scripts/README.md`). Four BMC tools take their place where nothing did the job: `Get-ZtpBmcJob.ps1`, `Get-ZtpBootSetting.ps1`, `Reset-ZtpBmc.ps1` and `Reset-ZtpBootSequence.ps1`. They take `-InfrastructureFile` (schema 5, no default path), read it through `Read-ZtpInfrastructure`, never prompt, take the BMC login from `-Credential` or the file's secret references (the toolkit's resolver), stop with exit code 2 when neither is there, and support `-WhatIf` for every change. No built-in vendor is left in the provisioning flow: `-Oem` of `Invoke-ZtpProvisioning.ps1` and `Wait-ZtpBootstrapComplete.ps1` has no `Dell` default any more (the Boot and Bootstrap stages stop without it; `Invoke-ZtpEnvironment.ps1` passes `hardware.vendor`), and the iDRAC one-time USB boot attributes (`ServerBoot.1.BootOnce`, `FirstBootDevice=vFDD`, override `Floppy`) moved from `Mount-ZtpVirtualUsb.ps1` into `bmc.usbBootOnce` of `config/oem/dell.json`, passed through a new `-Oem` of `Mount-ZtpVirtualUsb.ps1` and `Start-MaintenanceBoot.ps1`.

## [0.1.0] — 2026-04-30

### Documentation

- Initial public-preview alignment for Microsoft "Simplified machine provisioning" (azloc-2604).
- Repository converted to MkDocs (`docs/`) and AzureLocal organization standards baseline.

### Notes

This release re-targets the repository from the private-preview "ZTP" workflow to the public-preview "Simplified machine provisioning" feature, while preserving the iDRAC/Redfish automation that bypasses the manual USB media step required by the official workflow.
