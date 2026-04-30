# Contributing

Thank you for your interest in contributing to **azurelocal-ztp**. This repo automates the bring-up of Azure Local machines for the [Simplified machine provisioning](https://learn.microsoft.com/en-us/azure/azure-local/deploy/simplified-machine-provisioning) feature, with an emphasis on bypassing the manual USB-media step using BMC/Redfish (iDRAC, XCC, iLO) automation.

## Before You Start

- Read the [README](README.md) for an overview of the project.
- This project drives infrastructure changes against real hardware — **test all changes in a non-production environment**.
- Check open issues and pull requests to avoid duplicate work.

## How to Contribute

### Reporting Bugs

Open an issue with:
- Azure Local version (e.g. 2604)
- Hardware platform (Dell / Lenovo / HPE)
- BMC firmware version (iDRAC / XCC / iLO)
- Which script or stage failed and the full error output

### Suggesting Features

Open an issue describing the use case, not just the solution. Indicate whether the change affects the iDRAC/Redfish automation path, the voucher/FDO handling, or the Azure portal provisioning workflow.

### Documentation Issues

Open an issue for missing, incorrect, or unclear documentation.

### Submitting Pull Requests

1. Fork the repo and create a branch from `main`.
2. Name branches using conventional types: `feat/redfish-virtual-media`, `fix/iso-mount-timeout`, `docs/voucher-collection`.
3. Keep changes focused — one logical change per PR.
4. Update `docs/` if your change affects user-facing behavior.
5. Test your changes against at least one real BMC platform before submitting.
6. Fill out the pull request template.

## Commit Messages

This project uses [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>
```

| Type | When |
|------|------|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `infra` | CI/CD, workflows, config |
| `chore` | Maintenance |
| `refactor` | Code improvement, no behavior change |
| `test` | Tests |

Examples:
- `feat(redfish): add HPE iLO 6 virtual media support`
- `fix(scripts): handle non-200 response from Mount-AzureLocalISO`
- `docs(guides): align with azloc-2604 RP list`

## Development Guidelines

### PowerShell Style

- Use approved PowerShell verbs (`Get-`, `Set-`, `New-`, `Remove-`, etc.)
- Include `[CmdletBinding()]` and `param()` blocks on all scripts
- Use `Write-Verbose` for diagnostic output, `Write-Warning` for non-fatal issues, `Write-Error` for failures
- Guard destructive operations with `-WhatIf` / `-Confirm` where practical
- No hardcoded subscription IDs, IPs, hostnames, or credentials — use `{placeholder}` form or pull from `config/`

### Testing

- Test against a real BMC and a real Azure Local target before submitting changes that affect the automation path.
- Describe your test environment in the PR.

## Standards

This project follows the **org-wide AzureLocal standards** documented at [azurelocal.cloud/standards](https://azurelocal.cloud/standards/). See also [`STANDARDS.md`](STANDARDS.md) in this repo.

## Code of Conduct

Be respectful and constructive. Keep discussions on-topic and collaborative.
