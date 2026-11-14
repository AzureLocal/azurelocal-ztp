# Handoff

<!--
  Written at the END of every session by whichever tool was used.
  This is the single most important cross-tool file — the next session
  (possibly a different tool) starts by reading it.
-->

## Last session (2026-11-14, refactor: the old configuration layer is retired)

- **What changed and why (owner requirement: one infrastructure file feeds every tool, no prompts, no default path):**
  - Removed `scripts/common` (`AzureLocalConfig.psm1`, `RedfishUtils.psm1`, `discovery/`, `service-principals/`, `utilities/helpers/*` including `config-loader.ps1` and `keyvault-helper.ps1`, `utilities/tools/*`), `scripts/tools`, `scripts/examples`, `scripts/Trigger-ZTPDeployment.ps1`, `config/cluster-reference.env.template`, `config/cluster/cluster-config.md.template` and `docs/server-preparation.md` (64 files). `scripts/README.md` has the table of what does each job now (simplified provisioning or azurelocal-toolkit).
  - Four BMC tools replace the ones nothing else did: `Get-ZtpBmcJob.ps1` (was `Get-iDRACJobs.ps1`), `Get-ZtpBootSetting.ps1` (was `Get-BootSettings.ps1`), `Reset-ZtpBmc.ps1` (was `Reset-iDRAC.ps1`), `Reset-ZtpBootSequence.ps1` (was `Reset-BootSequence.ps1`), with `ZtpBmcTool.Common.ps1`. Mandatory `-InfrastructureFile` (schema 5 only), read through `Read-ZtpInfrastructure -ToolkitModulePath none`; the BMC login is `-Credential` or `hardware.bmc` secret references through the toolkit's `Resolve-AzlBmcCredential`; exit 2 when neither; exit 0/1/2; `-WhatIf` on the two that change something; `Reset-ZtpBootSequence.ps1` needs `-ConfirmNotClustered` and `hardware.vendor` Dell.
  - No built-in vendor (coordinator, pass H): `-Oem` of `Invoke-ZtpProvisioning.ps1` and `Wait-ZtpBootstrapComplete.ps1` lost its `Dell` default (orchestrator: the Boot and Bootstrap stages need it; the watch: mandatory). The iDRAC boot-once attributes moved from `Mount-ZtpVirtualUsb.ps1` to `config/oem/dell.json` `bmc.usbBootOnce` (`Get-ZtpOemUsbBootOnce` in `ZtpOem.Common.ps1`); new `-Oem` on `Mount-ZtpVirtualUsb.ps1` and `Start-MaintenanceBoot.ps1`. A BMC without a `Usb` override target and no `usbBootOnce` fails before the restart.
  - Docs: README, scripts READMEs, config README, api-reference (new section "Redfish calls of the BMC tools"), troubleshooting (BMC tools table), overview, azure-portal-provisioning (links), VitePress nav, CHANGELOG, automation.md (retired workflow stubs), .gitignore comment.
- **Tests:** Pester 5.9.1, whole `tests` folder in a separate `pwsh -NoProfile`, `AZL_TOOLKIT_ROOT` = the toolkit clone: 592 tests, 591 passed, 0 failed, 1 skipped (as before), 14 of 14 files loaded (main before: 554, 553 passed, 1 skipped). New: `ZtpBmcTool.Tests.ps1` (30), 2 in `ZtpOem.Tests.ps1`, 4 in `ZtpVirtualUsb.Tests.ps1`, 2 in `ZtpProvisioning.Tests.ps1`. One earlier full run had a flaky failure in `ZtpBios.Tests.ps1` (the Boot BIOS order file written from parallel runspaces); it passed alone 4 of 4 times and in the final run. PSScriptAnalyzer (Error, Warning) on the new files: clean.
- **Branch:** `old-layout` (worktree), committed, not pushed.
- **Open:**
  1. The toolkit's registry (`tools.ztp.parameters`) still lists the removed scripts' parameters and lacks the four BMC tools.
  2. `Read-ZtpInfrastructure` still accepts the older environment-file layout (`docs/environment-file.md`, `examples/infrastructure.example.yml`); retiring that is a separate step.
  3. `Invoke-ZtpEnvironment.ps1` reads its secrets with `Get-AzKeyVaultSecret`, not the toolkit's resolver (keyvault:// only).
  4. The BMC tools are proven against mocks only, not on an iDRAC.

## Previous session (2026-11-07, refactor: ZTP ends after Network and Restore, at the Handoff)

- **What changed and why (owner decisions 2026-11-07):**
  - **Prepare removed.** `Initialize-ZtpNode.ps1` and its tests are gone, and so is `-From Prepare`. OEM drivers, `C:\SBE`, DHCP off on the other NICs, DNS/time and the deployment admin are OS configuration (azurelocal-toolkit Phase 03; https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/).
  - **No SBE in ZTP.** Removed `Get-ZtpSbe.ps1`, the parser and selector in `ZtpSbe.Common.ps1`, `fixtures/sbe-discovery-dell.xml` and the `sbe` blocks of `config/oem/*.json`. The BMC part of the OEM loader moved to `ZtpOem.Common.ps1`. Retired settings keys (`SbeModel`, `SbeFamily`, `SbeSolutionVersion`, `SbePackagePath`) and `ztp.node_preparation` / `hardware.sbe` are ignored with a one-line note.
  - **Keys no longer read:** `credentials.local_admin_*`, `onprem.ntp_servers`, `hardware.model`, and the mapped `cluster_nodes[].network_adapters` (the other ports). The `-For Prepare` mode of the key check is gone.
  - **Handoff schema 2:** only what Azure generated (Arc and edge names and IDs, site, installed vsrVersion), plus per-node `managementAddressVerified`/`managementAddressReason` (from the Network stage, kept in the state file) and `biosRestored`. Removed: `sbe`, `bootstrap`, `timestamps`, `connectivity`.
    - The bootstrap ISO version, URL and SHA256 are in the Resolve evidence and state data; timestamps are in the event log and state file.
    - `Convert-ZtpHandoffToClusterInputs.ps1` reads schema 2 and 1 and emits `arc_machine_names` and `release.azure_local_version` only.
  - `docs/bootstrap-media-and-sbe.md` was renamed to `docs/bootstrap-media.md`.
  - New page `docs/prerequisites.md`, with a values table in schema 5 paths.
  - Rewritten docs: README, operator guide, architecture, monitoring, environment-file, infrastructure-schema-5, automated-bootstrap, troubleshooting, the scripts READMEs and the pipeline examples.
  - Two test races fixed: parallel runspaces appending to one file, in `ZtpRestore.Tests.ps1` and in the Boot BIOS test.
- **Tests:** Pester 5.9.1, 394 passed, 0 failed (main before this refactor: 419). The removed groups: 18 SBE, 21 Prepare/SBE environment, and a few replaced. PSScriptAnalyzer (Error, Warning): 2 findings, both pre-existing.
- **Branch:** main (pushed).
- **Open:**
  1. The toolkit's ZTP-only template (`config/infrastructure/infrastructure.ztp.example.yml`) isn't published yet, so the docs link 404s until it is. Its local copy still carries `hardware.sbe`, `identity.local_admin` and `networking.ntp_servers`, and says "Prepare".
  2. The flow diagram (`docs/diagrams/ztp-flow.drawio` and its PNG) is being redrawn by the coordinator.
  3. No live timing yet for the run up to the Handoff after Restore.

## Previous session (2026-11-07, priority push for the lab rerun)

- **What changed and why (owner decisions 2026-11-07):**
  - **static_method** (`network_intents.management.static_method`, schema 5 `networking.management.static_method`): `device` is the default. With it the site network is Automatic and the claim carries no Manual adapter, because a Manual site makes the OS install put the static address on the first ready port. `site` keeps the old Manual path.
  - **Device stage scans by MAC** when a node has no `maintenance_address`. It probes `provisioning_dhcp_range` (or the management subnet) on TCP 20001 in parallel, calls `GetNetworkAdapters` on each responder, and polls until the stage deadline. The `SetArcBootstrapDeviceConfiguration` body `{ Network: { NetworkAdapters: [...] } }` (no HostName) and the status shape are marked verified live.
  - **Ready** treats 404 and 409 on `jobs/ProvisionOs` as "not created yet" (`Invoke-ZtpArm -NotFoundStatus`).
  - **New Restore stage** (Network -> Restore -> Handoff). It covers `hardware.bios_during_provisioning` and `cluster_nodes[].bios_during_provisioning`: Boot applies them over `hardware.bios` and saves the originals once (state `biosOriginal`, change log phase `original`). `Restore-ZtpBios.ps1` sets them back, restarts the node, and waits for the BIOS values; then the orchestrator waits until the node is Connected and ready. Events: `BiosRestoreStarted`, `BiosRestored`, `BiosRestoreFailed`. The handoff records `nodes[].biosRestored`.
  - **SBE no longer required** for provisioning. `hardware.sbe` and `ztp.node_preparation` are ignored with a note. `Invoke-ZtpEnvironment.ps1` no longer runs Prepare.
  - Schema 5 now maps `nodes[].maintenance_address` directly.
- **Tests:** Pester 5.9.1, 419 passed, 0 failed (the base had 391).
- **Branch:** pushed to main. The refactor (ZTP ends at Network, Prepare and SBE removed, handoff schema 2, docs) is parked on the local branch `refactor/ztp-ends-at-network`. It will be rebased on this push.
- **Next:**
  1. Live rerun in the lab: check the Device scan and the Restore of Slot2.
  2. The toolkit schema must list `static_method`, `provisioning_dhcp_range`, `bios_during_provisioning` and `maintenance_address`.
  3. Finish the refactor and its docs, including `docs/prerequisites.md`.

## Previous session

- **What changed and why:** The OS-install request's `networkAdapters[].macAddress` is accepted by Azure but ignored by the device (the maintenance environment's provisioning extension picks the first ready port), so on a Dell AX-760 the static management address landed on a ConnectX storage port. Two new orchestrator stages put it on the port named by MAC. **Device** (between Vouchers and Azure, `Set-ZtpDeviceConfiguration.ps1`): before the claim, through the maintenance environment's Configurator App REST service (`https://<maintenance_address>:20001/BootstrapOobeService`, Basic auth as `edgeuser`, self-signed certificate skipped for these calls only): `GetNetworkAdapters` (verified live), `SetArcBootstrapDeviceConfiguration` (body from the data contract, not yet sent live), `GetArcBootstrapDeviceConfigurationStatus` (response shape unverified). **Network** (between Ready and Handoff, `Set-ZtpManagementAddress.ps1`): after the OS install, through Azure's per-NIC API 2026-10-01 (`edgeMachines/<node>/networkAdapters`, `jobs/ApplyConfiguration`; list, PUT 201 and a queued job seen live), releasing the address from a wrong adapter to Dhcp first. Both are idempotent, have a plan mode, write `<evidence>\device-changes.jsonl` / `network-changes.jsonl` and events (stages `Device`, `Network`). Prepare leaves an address, prefix, gateway and DNS that are already right. New settings: `cluster_nodes[].maintenance_address` (schema 5: the `provisioning` port's `ip_address`), `ztp.maintenance_password_secret` (schema 5: `provisioning.simplified.maintenance_password`), read with -Execute and passed as `-EdgeUserPassword` to Media (image hash) and Device; default `Password1`.
- **Files touched:** New: `scripts/simplified-provisioning/Set-ZtpDeviceConfiguration.ps1`, `Set-ZtpManagementAddress.ps1`, `tests/simplified-provisioning/ZtpDevice.Tests.ps1`, `ZtpNetwork.Tests.ps1`. Modified: `Invoke-ZtpProvisioning.ps1`, `Invoke-ZtpEnvironment.ps1`, `Initialize-ZtpNode.ps1`, `ZtpAzure.Common.ps1` (network adapter helpers), `ZtpEnvironment.Common.ps1` (keys, schema 5 mapping), the settings and node schemas and examples, `ZtpProvisioning.Tests.ps1`, `ZtpEnvironment.Tests.ps1`, docs (environment-file, infrastructure-schema-5, troubleshooting, operator-guide, architecture, monitoring, automated-bootstrap), scripts README, pipeline examples.
- **Commands / tests run and results:** Pester 5.9.1 on `tests/`: 391 passed, 0 failed (Network 16, Device 14). PSScriptAnalyzer (Warning, Error) on the new and changed scripts: no new findings. Nothing was run against a machine or Azure.
- **Branch:** main (pushed).
- **Blockers:** The toolkit's schema 5.2 (`azurelocal-toolkit/config/infrastructure/infrastructure.schema.json`) doesn't list `provisioning.simplified.maintenance_password`, and `provisioning.simplified` has `additionalProperties: false`, so a schema 5 file with that key fails the toolkit validation until the toolkit adds it. The maintenance address has no discovery yet: it's a setting (a DHCP reservation for the provisioning port).
- **Exact next steps:** (1) Add `maintenance_password` (`kv_ref`) to the toolkit schema under `provisioning.simplified`. (2) Live: run `-From Device` on one node in the maintenance environment and record the real `SetArcBootstrapDeviceConfiguration` and status responses; correct the body or status reading if needed. (3) Live: run `-From Network` after an OS install and confirm the ApplyConfiguration job ends and the adapter reports the address. (4) Update `docs/diagrams/ztp-flow.drawio` and its PNG with the Device and Network stages.
