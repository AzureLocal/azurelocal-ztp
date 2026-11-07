# Examples

Placeholder values only. Copy a file outside this repository before you put real values in it.

| File | What it is |
| --- | --- |
| [`infrastructure.example.yml`](infrastructure.example.yml) | An environment file for `Invoke-ZtpEnvironment.ps1`, in the older, deprecated layout. Keys: [Environment file reference](../docs/environment-file.md). |
| [`pipelines/azure-pipelines.yml`](pipelines/azure-pipelines.yml) | Azure DevOps: plan, approval, execute. |
| [`pipelines/github-actions.yml`](pipelines/github-actions.yml) | GitHub Actions: plan, approval, execute. Copy it to `.github/workflows/`. |
| [`pipelines/gitlab-ci.yml`](pipelines/gitlab-ci.yml) | GitLab CI: plan, manual job, execute. |

For a new environment file, start from a schema 5 template in azurelocal-toolkit instead: the [ZTP-only template](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/config/infrastructure/infrastructure.ztp.example.yml) if you run nothing after ZTP (being added by the toolkit, not published yet), or the [full template](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/config/infrastructure/infrastructure.example.yml) if you go on to OS configuration and deployment. See [Reading the master infrastructure.yml](../docs/infrastructure-schema-5.md).

The pipelines need a self-hosted Windows runner on the management network, with the [prerequisites](../docs/prerequisites.md). Their `from` choice lists the stages: Resolve, Media, Boot, Bootstrap, Vouchers, Device, Azure, Ready, Network, Restore and Handoff. See [Running from a pipeline](../docs/automation-pipelines.md).

Other examples live next to the code they configure:

- `config/simplified-provisioning/ztp-provisioning.example.json` and `nodes.example.json`: inputs for running the orchestrator directly.
- `scripts/simplified-provisioning/bicep/main.example.parameters.json`: parameters of the Azure template.
