# Automation Pipelines

> **Status:** Placeholder. The GitHub Actions workflows in `.github/workflows/` are currently stubs that document the intended surface but contain no real CI/CD logic. This page describes the planned design so it can be filled in incrementally.

## Planned workflow surface

The repo will expose three repo-specific workflows for end-to-end automation, in addition to the org-wide baseline workflows:

| Workflow | Trigger | Role |
|----------|---------|------|
| `ztp-runner-setup.yml` | manual `workflow_dispatch` | Provision a self-hosted runner with the prerequisites for BMC/Redfish operations |
| `ztp-config-bootstrap.yml` | manual `workflow_dispatch` | Generate `config/environment.{json,yaml}` from a runtime template; validate against the schema |
| `ztp-deployment.yml` | manual `workflow_dispatch` | Drive end-to-end automation: discover BMCs, mount ISO, set boot source, reboot, collect vouchers |

For the org-wide workflows (release-please, add-to-project, validate-repo-structure, deploy-docs), see [`repo-management/automation.md`](https://github.com/AzureLocal/azurelocal-ztp/blob/main/repo-management/automation.md).

## Why this is a separate concern

The BMC automation in `scripts/` works as a standalone tool — you can run it from any workstation against any BMC network. The pipelines are an optional orchestration layer that adds:

- **Auditable runs** — every deployment is tracked as a workflow run with logs and artifacts.
- **Self-hosted runner placement** — for sites where the BMC network is air-gapped from GitHub.com, a self-hosted runner inside the management network can be the only path to drive the automation.
- **Parameterization** — feed a config from secrets / repository variables so the same workflow drives many sites.

If you don't need any of that, you can use the scripts directly. The pipelines are not on the critical path.

## Open design questions

These will be resolved before the placeholder stubs are filled in:

1. **Self-hosted runner vs workstation?** If most users will run from a workstation (because the BMC network is reachable from a laptop), the self-hosted runner workflow may be unnecessary. For air-gapped sites it's a hard requirement.
2. **Where does Azure-side provisioning fit?** The Azure portal provisioning step (claiming machines, configuring sites) has a documented Microsoft REST API surface in `Microsoft.DeviceOnboarding`. The pipeline could drive that directly via `az` CLI or `Invoke-AzRest`, but the public preview portal flow is more discoverable. Decide whether to script Azure-side or stop at "vouchers collected, hand off to portal."
3. **Cluster deployment ARM template** — once machines are `Ready to cluster`, the Azure Local ARM template fires the actual cluster create. Should that be wrapped in a fourth pipeline?
