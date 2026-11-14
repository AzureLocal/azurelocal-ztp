# Examples

Placeholder values only. Copy a file outside this repository before you put real values in it.

**The infrastructure file is not here.** ZTP reads one input, the `infrastructure.yml` of azurelocal-toolkit (schema 5), the same file every Azure Local tool reads. Start from the toolkit's example:

- [`infrastructure.ztp.example.yml`](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/config/variables/examples/infrastructure.ztp.example.yml) if you run nothing after ZTP, or
- [`infrastructure.example.yml`](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/config/variables/examples/infrastructure.example.yml) if you go on to OS configuration and deployment.

Check it with the toolkit's `scripts/common/infrastructure/Test-InfrastructureFile.ps1`. The keys ZTP reads are in the [Infrastructure file reference](../docs/environment-file.md).

| File | What it is |
| --- | --- |
| [`pipelines/azure-pipelines.yml`](pipelines/azure-pipelines.yml) | Azure DevOps: plan, approval, execute. |
| [`pipelines/github-actions.yml`](pipelines/github-actions.yml) | GitHub Actions: plan, approval, execute. Copy it to `.github/workflows/`. |
| [`pipelines/gitlab-ci.yml`](pipelines/gitlab-ci.yml) | GitLab CI: plan, manual job, execute. |

The pipelines need a self-hosted Windows runner on the management network, with the [prerequisites](../docs/prerequisites.md) and an azurelocal-toolkit clone (`AZL_TOOLKIT_ROOT`, or next to the ZTP checkout) for its secret resolver. Their `from` choice lists the stages: Resolve, Media, Boot, Bootstrap, Vouchers, Device, Azure, Ready, Network, Restore and Handoff. See [Running from a pipeline](../docs/automation-pipelines.md).

Other examples live next to the code they configure:

- `config/simplified-provisioning/ztp-provisioning.example.json` and `nodes.example.json`: inputs for running the orchestrator directly.
- `scripts/simplified-provisioning/bicep/main.example.parameters.json`: parameters of the Azure template.
