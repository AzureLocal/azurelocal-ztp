# Configuration

Your environment's values are not here. They are in one master `infrastructure.yml` (azurelocal-toolkit schema 5) that you keep outside this repository and pass to every script with `-InfrastructureFile`. Start from a toolkit template: the [ZTP-only template](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/config/variables/examples/infrastructure.ztp.example.yml) or the [full template](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/config/variables/examples/infrastructure.example.yml). How ZTP reads it, key by key: [Master infrastructure.yml (schema 5)](../docs/infrastructure-schema-5.md). The file holds secret references only (`keyvault://<vault>/<secret>` and the toolkit's other forms), never a secret.

This folder holds what the scripts need besides that file:

| Path | What it is |
| --- | --- |
| `oem/<vendor>.json` | OEM definitions: the BMC kind, the log services and signal patterns the Bootstrap watch reads, and the BIOS slot attributes. Picked by `hardware.vendor`. No SBE settings. |
| `simplified-provisioning/ztp-provisioning.example.json` and `.schema.json` | Settings of `Invoke-ZtpProvisioning.ps1` when you drive the orchestrator directly (keys are its parameter names; no secrets). `Invoke-ZtpEnvironment.ps1` writes the real one from the infrastructure file. |
| `simplified-provisioning/nodes.example.json` and `.schema.json` | The node list of the stage scripts (`name`, `service_tag`, `bmc_address` and the optional keys). `Invoke-ZtpEnvironment.ps1` writes the real one. |

Real copies of the generated files are git-ignored. The older configuration layer (`environment.yaml`, `environment.json`, `cluster/cluster-config.md`, `cluster-reference.env` and the `AzureLocalConfig.psm1` loader) is retired.
