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
| The runner must reach the BMCs and the maintenance environment | Redfish over HTTPS to each BMC (Boot, Bootstrap, Vouchers, Restore), and TCP 20001 to each node's maintenance environment during Device: its `maintenance_address`, or every address of `networking.management.provisioning_dhcp_range` that the stage scans. ZTP makes no WinRM connection to the nodes. |
| Elevation | The share, the local account and the firewall rule need administrator rights. Run the runner as a service under an account in local Administrators. |
| State on disk | The images, vouchers, state file and handoff are in the media folder (`provisioning.simplified.media_path`), outside the checkout: a run refuses a folder inside a git working tree. A resume must run on the **same runner**, with the same `provisioning.simplified.media_path`. |

Set the runner up once:

- PowerShell 7, the Az modules, `powershell-yaml`, and the Azure CLI with Bicep. See [Management host](operator-guide.md#management-host).
- Give it a dedicated label or capability (the examples use `ztp`) so that every job of a run lands on it.
- Don't let a workspace clean delete the parent of the checkout. In Azure DevOps, don't set `workspace: clean: all`. In GitLab, pin the clone path (see the GitLab example).
- Put the infrastructure file on the runner, or check it out from a private repository. ZTP needs no SBE. The infrastructure file has no secrets, but it has your addresses and IDs; keep it out of this public repository.

## Identity

The run needs one Azure identity with the roles in [Azure prerequisites](operator-guide.md#azure):

- Owner, or Contributor and Role Based Access Control Administrator, on the cluster resource group.
- Key Vault Secrets User on each vault a `keyvault://` reference of the infrastructure file names.
- On the vault that holds the provisioning administrator secret, rights to assign roles and deploy into its resource group.
- Reader on the subscription.
- Contributor on the subscription only if the run must create the resource group.

Set `azure.hci_resource_provider_object_id` in the infrastructure file. Otherwise the run looks the object up in Microsoft Entra ID, and a managed identity has no directory read rights by default.

| Option | How | Notes |
| --- | --- | --- |
| **Managed identity on the runner host** (recommended) | Pass `-UseManagedIdentity`. The script runs `Connect-AzAccount -Identity`. | Works when the runner is an Azure VM or an Azure Arc-enabled server. On an Arc-enabled Windows server, the account running the job must be in local Administrators or in **Hybrid agent extension applications** to get a token ([Learn: managed identity on Arc-enabled servers](https://learn.microsoft.com/azure/azure-arc/servers/managed-identity-authentication#prerequisites)). No secret to store or rotate, and the token is renewed for the whole run. |
| **Service principal** | Sign in with `Connect-AzAccount -ServicePrincipal` in the **same PowerShell session**, before you call the script without `-UseManagedIdentity`. Prefer a certificate in the runner's certificate store. | With workload identity federation (OIDC), the platform's token can expire before a 2-hour run ends. Test a full run, or use a managed identity. |

## Secrets

- Every credential is a secret reference in the infrastructure file, read by azurelocal-toolkit's one resolver (put a toolkit clone on the runner and set `AZL_TOOLKIT_ROOT`, or clone it next to the ZTP checkout; without it an `-Execute` run stops with exit code 2): the BMC login and the maintenance environment's `edgeuser` password (`provisioning.simplified.maintenance_password`) take `keyvault://`, `env://`, `file://` or `command://`; the provisioning administrator password is a `keyvault://` reference that Azure reads itself. ZTP creates no deployment admin, so it reads no password for one.
- Don't put passwords in pipeline variables, variable groups or CI/CD variables in plain text. The pipeline needs no secret of its own when it uses a managed identity.
- The scripts never print a secret or a voucher. The share password is generated per run and exists only in memory.
- Vouchers are written to `<media_path>\vouchers` on the runner. Restrict that folder and never upload it as an artifact.

## Run time, approval and concurrency

- **Long run.** Execute took about 1.5 to 2 hours for two nodes, plus up to about 45 minutes if a node registers late. The scripts wait up to 30 minutes at Device, 180 minutes at Ready and 60 minutes per Network job. With `bios_during_provisioning`, Restore adds a BIOS restart, a 5-minute wait and up to 180 minutes for the machines to be ready to cluster again. The examples set the execute job's timeout to 8 hours.
- **Execute in its own job, behind a manual approval.** The Boot stage reinstalls every node. The plan job runs first and shows exactly what execute will do. A person reviews it and approves.
- **One run per environment at a time.** The state file is per set of nodes, and the share and the BMCs can't serve two runs. The examples serialize runs: Azure DevOps with an **Exclusive lock** check on the environment, GitHub with `concurrency`, GitLab with `resource_group`.
- **Exit codes.** A failed gate throws, so the step fails with a non-zero exit code.

## Resume

Run the execute job again with the **same node list**. Completed stages are skipped. To run a stage and every later one again, set the `from` input (`-From <Stage>`): `Resolve`, `Media`, `Boot`, `Bootstrap`, `Vouchers`, `Device`, `Azure`, `Ready`, `Network`, `Restore` or `Handoff`. See [Resume a stopped run](operator-guide.md#resume-a-stopped-run) for which stage to pick, and for the extra step before you rerun `Boot` on a node that's already claimed.

Re-running the execute job asks for the approval again. That's intended: it can reinstall machines.

## After the run

The handoff is in `<media_path>\ztp-state\` on the runner: `<run>.ztp-handoff.json`, `<run>.ztp-cluster-inputs.yaml` and `<run>.arc-machine-names.json`. ZTP ends there: the machines are Provisioned and Arc-connected, with the management address on the management port. The next pipeline step is OS configuration (OEM drivers, an SBE in `C:\SBE` (optional, only when a person asks for it), DHCP off on the other NICs, DNS and time, the deployment admin; [Phase 03 OS Configuration](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/)), then Validate and Deploy. Pass the `arcMachineResourceId` values to your cluster deployment pipeline, and check each node's `managementAddressVerified` first. The handoff holds Azure resource IDs but no secrets. If you publish it as a pipeline artifact, keep the artifact private.

The examples call only the parameters `Invoke-ZtpEnvironment.ps1` has: `-InfrastructureFile`, `-Node`, `-From`, `-UseManagedIdentity` and `-Execute`.
