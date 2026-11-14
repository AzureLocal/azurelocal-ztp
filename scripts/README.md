# Scripts

PowerShell 7 scripts of azurelocal-ztp. Everything is in [`simplified-provisioning/`](simplified-provisioning/README.md).

```text
scripts/
└── simplified-provisioning/   # Entry point, orchestrator, stage scripts, BMC tools, Bicep
```

## Where to start

| You want to | Run |
| --- | --- |
| Provision nodes end to end (plan, then `-Execute`) | `simplified-provisioning/Invoke-ZtpEnvironment.ps1 -InfrastructureFile <path>` |
| Drive the stages yourself | `simplified-provisioning/Invoke-ZtpProvisioning.ps1` (see [Orchestrator reference](../docs/automated-bootstrap.md)) |
| Look at or recover a node's BMC | The BMC tools: `Get-ZtpBmcJob.ps1`, `Get-ZtpBootSetting.ps1`, `Reset-ZtpBmc.ps1`, `Reset-ZtpBootSequence.ps1` (below) |

The entry point and the BMC tools read the one master `infrastructure.yml` (azurelocal-toolkit schema 5) that every Azure Local tool reads; the file has no default path. No script prompts: a credential comes from a `-Credential` parameter or from a secret reference in the file.

## BMC tools

Small tools for the BMCs ZTP drives. Each takes `-InfrastructureFile` (required), `-NodeName` (default: every node in the file) and `-Credential` (default: `hardware.bmc.username` and `hardware.bmc.password` of the file, secret references read by the toolkit's resolver). They read only `nodes[].name`, `nodes[].bmc.ip_address`, `hardware.bmc` and, for `Reset-ZtpBootSequence.ps1`, `hardware.vendor`. Exit codes: 0 done (or planned with `-WhatIf`), 1 a BMC call failed, 2 an input is missing or not usable (nothing was sent).

| Script | What it does | Changes |
| --- | --- | --- |
| `Get-ZtpBmcJob.ps1` | Lists each BMC's job queue (for example the BIOS jobs of the Boot and Restore stages); `-JobState`, `-RecentMinutes`, `-Wait` until no job is active | Nothing |
| `Get-ZtpBootSetting.ps1` | Power state, boot mode, one-time override, boot order and boot options, with the stale (`Unavailable:`) entries counted | Nothing |
| `Reset-ZtpBmc.ps1` | Restarts the BMC (`Manager.Reset`, `GracefulRestart` or `ForceRestart`); the host keeps running | The BMC, with `-WhatIf` |
| `Reset-ZtpBootSequence.ps1` | Dell only: clears the iDRAC job queue, sets `SysPrepClean` with its BIOS job, clears a one-time override and restarts (`-NoRestart` stages it). Needs `-ConfirmNotClustered` | The node's UEFI boot entries, with `-WhatIf` |

```powershell
./scripts/simplified-provisioning/Get-ZtpBootSetting.ps1 -InfrastructureFile D:\ztp\infrastructure.yml -NodeName iic-node-01
./scripts/simplified-provisioning/Reset-ZtpBmc.ps1 -InfrastructureFile D:\ztp\infrastructure.yml -NodeName iic-node-01 -WhatIf
```

## What replaced the older scripts

Earlier versions of this folder had `common/`, `tools/` and `examples/`, with their own configuration loader (`environment.yaml`, `cluster-config.md`) and interactive prompts. They are retired. What does each job now:

| Job | Where it is now |
| --- | --- |
| Reading the configuration | `simplified-provisioning/ZtpEnvironment.Common.ps1` (`Read-ZtpInfrastructure`) reads the master `infrastructure.yml`. The toolkit's templates (`config/variables/examples`) and its `Test-InfrastructureFile.ps1` replace `cluster-config.md`, `cluster-reference.env` and their generators and validators |
| Secrets | The toolkit's secret resolver, `scripts/common/secrets/AzlSecret.psm1` (`keyvault://`, `env://`, `file://`, `command://`). Vaults and a check that the secrets the file names exist: the toolkit's `Deploy-KeyVaults.ps1` |
| Hardware discovery (serial numbers, MACs, inventory) | azurelocal-toolkit `Invoke-HardwareDiscovery.ps1`, `Get-HardwareInventory.ps1`, `Update-InfrastructureYml-FromDiscovery.ps1` |
| Maintenance ISO download, share, mount, boot source, restart, watch | `Get-ZtpBootstrapIso.ps1`, `Publish-MaintenanceIso.ps1`, `Mount-ZtpVirtualUsb.ps1` (`Mount`, `Eject`, `Status`, `-Restart`), `Start-MaintenanceBoot.ps1`, `Wait-ZtpBootstrapComplete.ps1`, `Start-ZtpMonitor.ps1` |
| Resource group | `Invoke-ZtpAzureProvisioning.ps1` (`provisioning.simplified.create_resource_group`); outside ZTP the toolkit's `Deploy-ResourceGroups.ps1` |
| BOSS virtual disk, gold-image ISO mount | azurelocal-toolkit `Invoke-ResetBossVirtualDisk.ps1`, `Invoke-MountGoldImageISO.ps1` |
| Azure tenant and on-premises server inventory | azurelocal-toolkit `scripts/common/discovery/` (`Inventory-AzureTenant.ps1`, `Get-TenantInfo.ps1`, `Get-OnPremInventory.ps1`) |
| Service principals and role assignments | azurelocal-toolkit `New-CicdBootstrap.ps1` (the automation identity) and `Assign-AzureLocalRBAC.ps1`. ZTP needs no Arc onboarding principal: the claim registers the machines with Arc |
| Cluster shutdown | azurelocal-toolkit `scripts/common/utilities/tools/Stop-AzureLocalCluster.ps1` |
| Running from a pipeline | [`examples/pipelines/`](../examples/README.md) and [Running from a pipeline](../docs/automation-pipelines.md) |

## Tests

```powershell
Import-Module Pester -RequiredVersion 5.9.1
Invoke-Pester ./tests
```

The tests mock every Redfish, Azure and HTTP call; nothing leaves the machine. Set `AZL_TOOLKIT_ROOT` to an azurelocal-toolkit clone (or keep one next to this repository) to also run the checks against the toolkit's schema and templates.
