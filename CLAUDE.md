# CLAUDE.md — azurelocal-ztp

This file gives Claude Code session context for this repository. Read it before doing non-trivial work here.

## What this repo is

Automation for Microsoft's [Simplified machine provisioning](https://learn.microsoft.com/en-us/azure/azure-local/deploy/simplified-machine-provisioning) feature (public preview, azloc-2604).

The repo's *unique* value is the BMC/Redfish automation that bypasses the manual USB-media step the Microsoft documentation requires. The Azure-side provisioning (voucher claim, site config, cluster deploy) is documented and supported by Microsoft — this repo does not duplicate it, it *gets servers ready* so it can happen.

## Where the value lives

| Path | Contains | Why it matters |
|------|----------|----------------|
| `scripts/common/utilities/tools/` | iDRAC/Redfish operations: `Mount-AzureLocalISO.ps1`, `Set-ServerBootSource.ps1`, `Restart-Servers.ps1`, `Verify-ISOMount.ps1` | The differentiator. This is what bypasses USB. |
| `scripts/common/discovery/` | Hardware inventory from BMC: `Get-DellServerInventory-FromiDRAC.ps1`, `Inventory-AzureTenant.ps1`, `Compare-Discovery.ps1` | Pre-flight checks |
| `scripts/common/service-principals/` | Azure SP creation: `New-PipelineSP.ps1`, `New-ArcOnboardingSP.ps1`, `Assign-AzureLocalRBAC.ps1` | Azure-side prep |
| `scripts/common/AzureLocalConfig.psm1`, `RedfishUtils.psm1` | Shared modules | Used by everything in `scripts/` |
| `config/environment.{yaml,json}` | Centralized config (subscription IDs, node specs, network) | Single source of truth |
| `docs/` | MkDocs documentation source | User-facing |

## Conventions

### Placeholders, not real values

This is a public-facing repo. Do **not** commit:

- Real Azure subscription IDs, tenant IDs, or resource group names
- Real hostnames, IPs, or BMC credentials
- Real serial numbers / service tags

Use `{placeholder_name}` form in docs and templates. Real values come from `config/environment.{yaml,json}` (which is `.gitignore`'d for the user-specific instance) or environment-specific overrides.

### Hardware vendor scope

The Microsoft-validated hardware list for Simplified machine provisioning is the source of truth. Don't add automation for hardware not on that list without checking first. Currently:

- Dell AX-650, AX-750 (iDRAC 9 / iDRAC 10) — **validated**
- Lenovo MX650 V3, V4 (XCC2) — **planned**
- HPE DL360 Gen11 (iLO 6) — **planned**

Avoid Dell AX-760 references — it was on the private-preview list but **isn't supported** in public preview.

### PowerShell style

- Approved verbs, `[CmdletBinding()]`, `param()` blocks
- `Write-Verbose` for diagnostic output
- Guard destructive ops with `-WhatIf` / `-Confirm`
- No hardcoded values — pull from `config/` or accept as parameters

### Documentation

- Source format is **Markdown** for MkDocs Material rendering
- Admonitions use `!!! note "Title"` (mkdocs admonition syntax), not GitHub-flavored alerts
- Do not author in AsciiDoc — the repo migrated off `.adoc` in v0.1.0

## Workflows

All `.github/workflows/*.yml` files in this repo are currently **placeholder stubs**. They document the intended surface but contain no real CI/CD logic. See `repo-management/automation.md` for the planned implementation per workflow.

Do **not** implement workflow logic without explicit user direction — the user has chosen to land placeholders only at this stage.

## Org standards

This repo follows the org-wide AzureLocal standards. Canonical reference: [azurelocal.cloud/standards](https://azurelocal.cloud/standards/). See `STANDARDS.md` for the pointer.

Key standards that affect day-to-day editing here:

- Conventional Commits (`feat:`, `fix:`, `docs:`, `infra:`, `chore:`, `refactor:`)
- release-please manages `CHANGELOG.md` — never edit it manually
- Issues use `type/*`, `priority/*`, `solution/*` labels (synced from the org)

## Working scope

The user actively works on this repo from `e:\git\azurelocal\azurelocal-ztp\` (note the extra `azurelocal\` parent — sibling repos will move to that parent over time, but currently other repos are at `e:\git\azurelocal-<name>`).

## Status (2026-04-30)

Repository is **mid-migration** from private-preview ZTP to public-preview Simplified machine provisioning. State:

- ✅ Sensitive content scrubbed (subscription IDs, private-preview docs)
- ✅ AzureLocal org baseline files in place
- ✅ Docs converted from AsciiDoc to MkDocs (manual table cleanup still pending)
- ✅ Workflows replaced with placeholder stubs
- ⏳ Public-preview language updates in guides (ROE → maintenance environment, hardware list, RP list)
- ⏳ README rewrite around the BMC-automation differentiator
- ⏳ Empty IaC scaffolding (`helm/`, `docker/`, `policies/`, etc.) pending decision on whether to keep
