# Running from a pipeline

> How to run zero-touch provisioning from Azure DevOps, GitHub Actions or GitLab CI: the runner, the identity, secrets, run time, approval and resume.

A pipeline runs the same entry point as an operator: `Invoke-ZtpEnvironment.ps1 -InfrastructureFile <file>`, first as a plan, then with `-Execute`. Read the [Operator guide](operator-guide.md) first. Every prerequisite there applies to the runner.

Example pipelines are in [`examples/pipelines/`](https://github.com/AzureLocal/azurelocal-ztp/tree/main/examples/pipelines):

| Platform | File | Approval mechanism |
| --- | --- | --- |
| Azure DevOps | `azure-pipelines.yml` | An environment with an **Approvals** check, on a deployment job |
| GitHub Actions | `github-actions.yml` | An environment with **required reviewers** |
| GitLab CI | `gitlab-ci.yml` | A `when: manual` job, plus a protected environment with deployment approvals if your tier has them |

Each one has a plan job, then the approval, then an execute job. Each passes `-InfrastructureFile`, and optionally `-Node` and `-From`.

## Why it needs a self-hosted Windows runner on the management network

Microsoft-hosted and Linux runners can't run this. The runner must be a **self-hosted Windows** runner (or agent) **on the management network**, and it must meet every management host requirement:

| Reason | Detail |
| --- | --- |
| The BMCs read the images from an SMB share on the runner | The Boot stage shares the images with Windows SMB, a local account and a Windows Firewall rule. Each BMC connects to the runner on TCP 445. A hosted runner isn't reachable from your BMCs. |
| The runner must reach the BMCs and the nodes | Redfish over HTTPS to each BMC, and WinRM (TCP 5985) to each node during Prepare. |
| Elevation | The share, the local account and the firewall rule need administrator rights. Run the runner as a service under an account in local Administrators. |
| State on disk | The images, vouchers, state file and handoff are in `_media` at the root of the checkout (git ignores it). A resume must run on the **same runner, from the same checkout path**. |

Set the runner up once:

- PowerShell 7, the Az modules, `powershell-yaml`, the Azure CLI with Bicep, and the WinRM TrustedHosts entries for the node addresses. See [Management host](operator-guide.md#management-host).
- Give it a dedicated label or capability (the examples use `ztp`) so that every job of a run lands on it.
- Don't let a workspace clean delete the parent of the checkout. In Azure DevOps, don't set `workspace: clean: all`. In GitLab, pin the clone path (see the GitLab example).
- Put the environment file and the SBE folder on the runner, or check them out from a private repository. The environment file has no secrets, but it has your addresses and IDs; keep it out of this public repository.

## Identity

The run needs one Azure identity with the roles in [Azure prerequisites](operator-guide.md#azure):

- Owner, or Contributor and Role Based Access Control Administrator, on the cluster resource group.
- Key Vault Secrets User on each vault the environment file names.
- On the vault that holds the provisioning administrator secret, rights to assign roles and deploy into its resource group.
- Reader on the subscription.
- Contributor on the subscription only if the run must create the resource group.

Set `ztp.azl_rp_object_id` in the environment file. Otherwise the run looks the object up in Microsoft Entra ID, and a managed identity has no directory read rights by default.

| Option | How | Notes |
| --- | --- | --- |
| **Managed identity on the runner host** (recommended) | Pass `-UseManagedIdentity`. The script runs `Connect-AzAccount -Identity`. | Works when the runner is an Azure VM or an Azure Arc-enabled server. On an Arc-enabled Windows server, the account running the job must be in local Administrators or in **Hybrid agent extension applications** to get a token ([Learn: managed identity on Arc-enabled servers](https://learn.microsoft.com/azure/azure-arc/servers/managed-identity-authentication#prerequisites)). No secret to store or rotate, and the token is renewed for the whole run. |
| **Service principal** | Sign in with `Connect-AzAccount -ServicePrincipal` in the **same PowerShell session**, before you call the script without `-UseManagedIdentity`. Prefer a certificate in the runner's certificate store. | With workload identity federation (OIDC), the platform's token can expire before a 2-hour run ends. Test a full run, or use a managed identity. |

## Secrets

- Every credential comes from **Key Vault** through references in the environment file: the BMC login, the provisioning administrator password, and the deployment admin password.
- Don't put passwords in pipeline variables, variable groups or CI/CD variables in plain text. The pipeline needs no secret of its own when it uses a managed identity.
- The scripts never print a secret or a voucher. The share password is generated per run and exists only in memory.
- Vouchers are written to `_media/vouchers` on the runner. Restrict that folder and never upload it as an artifact.

## Run time, approval and concurrency

- **Long run.** Execute took about 1.5 to 2 hours for two nodes, plus up to about 35 minutes if a node registers late. The scripts wait up to 180 minutes at Ready and 240 minutes at Prepare's first gate. The examples set the execute job's timeout to 8 hours.
- **Execute in its own job, behind a manual approval.** The Boot stage reinstalls every node. The plan job runs first and shows exactly what execute will do. A person reviews it and approves.
- **One run per environment at a time.** The state file is per set of nodes, and the share and the BMCs can't serve two runs. The examples serialize runs: Azure DevOps with an **Exclusive lock** check on the environment, GitHub with `concurrency`, GitLab with `resource_group`.
- **Exit codes.** A failed gate throws, so the step fails with a non-zero exit code.

## Resume

Run the execute job again with the **same node list**. Completed stages are skipped, and Prepare skips what's done. To run a stage and every later one again, set the `from` input (`-From <Stage>`). See [Resume a stopped run](operator-guide.md#resume-a-stopped-run) for which stage to pick, and for the extra step before you rerun `Boot` on a node that's already claimed.

Re-running the execute job asks for the approval again. That's intended: it can reinstall machines.

## After the run

The handoff is in `_media/ztp-state/` on the runner: `<run>.ztp-handoff.json`, `<run>.ztp-cluster-inputs.yaml` and `<run>.arc-machine-names.json`. Pass the `arcMachineResourceId` values to your cluster deployment pipeline. The handoff holds Azure resource IDs but no secrets. If you publish it as a pipeline artifact, keep the artifact private.

The examples call only the parameters `Invoke-ZtpEnvironment.ps1` has: `-InfrastructureFile`, `-Node`, `-From`, `-UseManagedIdentity` and `-Execute`.
