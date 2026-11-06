# Examples

Placeholder values only. Copy a file outside this repository before you put real values in it.

| File | What it is |
| --- | --- |
| [`infrastructure.example.yml`](infrastructure.example.yml) | An environment file for `Invoke-ZtpEnvironment.ps1`. Keys: [Environment file reference](../docs/environment-file.md). |
| [`pipelines/azure-pipelines.yml`](pipelines/azure-pipelines.yml) | Azure DevOps: plan, approval, execute. |
| [`pipelines/github-actions.yml`](pipelines/github-actions.yml) | GitHub Actions: plan, approval, execute. Copy it to `.github/workflows/`. |
| [`pipelines/gitlab-ci.yml`](pipelines/gitlab-ci.yml) | GitLab CI: plan, manual job, execute. |

The pipelines need a self-hosted Windows runner on the management network. See [Running from a pipeline](../docs/automation-pipelines.md).

Other examples live next to the code they configure:

- `config/simplified-provisioning/ztp-provisioning.example.json` and `nodes.example.json`: inputs for running the orchestrator directly.
- `scripts/simplified-provisioning/bicep/main.example.parameters.json`: parameters of the Azure template.
