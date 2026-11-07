# Handoff

<!--
  Written at the END of every session by whichever tool was used.
  This is the single most important cross-tool file — the next session
  (possibly a different tool) starts by reading it.
-->

## Last session (2026-11-07, priority push for the tplabs rerun)

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
  1. Live rerun on tplabs: check the Device scan and the Restore of Slot2.
  2. The toolkit schema must list `static_method`, `provisioning_dhcp_range`, `bios_during_provisioning` and `maintenance_address`.
  3. Finish the refactor and its docs, including `docs/prerequisites.md`.

## Previous session

- **What changed and why:** The OS-install request's `networkAdapters[].macAddress` is accepted by Azure but ignored by the device (the maintenance environment's provisioning extension picks the first ready port), so on a Dell AX-760 the static management address landed on a ConnectX storage port. Two new orchestrator stages put it on the port named by MAC. **Device** (between Vouchers and Azure, `Set-ZtpDeviceConfiguration.ps1`): before the claim, through the maintenance environment's Configurator App REST service (`https://<maintenance_address>:20001/BootstrapOobeService`, Basic auth as `edgeuser`, self-signed certificate skipped for these calls only): `GetNetworkAdapters` (verified live), `SetArcBootstrapDeviceConfiguration` (body from the data contract, not yet sent live), `GetArcBootstrapDeviceConfigurationStatus` (response shape unverified). **Network** (between Ready and Handoff, `Set-ZtpManagementAddress.ps1`): after the OS install, through Azure's per-NIC API 2026-10-01 (`edgeMachines/<node>/networkAdapters`, `jobs/ApplyConfiguration`; list, PUT 201 and a queued job seen live), releasing the address from a wrong adapter to Dhcp first. Both are idempotent, have a plan mode, write `<evidence>\device-changes.jsonl` / `network-changes.jsonl` and events (stages `Device`, `Network`). Prepare leaves an address, prefix, gateway and DNS that are already right. New settings: `cluster_nodes[].maintenance_address` (schema 5: the `provisioning` port's `ip_address`), `ztp.maintenance_password_secret` (schema 5: `provisioning.simplified.maintenance_password`), read with -Execute and passed as `-EdgeUserPassword` to Media (image hash) and Device; default `Password1`.
- **Files touched:** New: `scripts/simplified-provisioning/Set-ZtpDeviceConfiguration.ps1`, `Set-ZtpManagementAddress.ps1`, `tests/simplified-provisioning/ZtpDevice.Tests.ps1`, `ZtpNetwork.Tests.ps1`. Modified: `Invoke-ZtpProvisioning.ps1`, `Invoke-ZtpEnvironment.ps1`, `Initialize-ZtpNode.ps1`, `ZtpAzure.Common.ps1` (network adapter helpers), `ZtpEnvironment.Common.ps1` (keys, schema 5 mapping), the settings and node schemas and examples, `ZtpProvisioning.Tests.ps1`, `ZtpEnvironment.Tests.ps1`, docs (environment-file, infrastructure-schema-5, troubleshooting, operator-guide, architecture, monitoring, automated-bootstrap), scripts README, pipeline examples.
- **Commands / tests run and results:** Pester 5.9.1 on `tests/`: 391 passed, 0 failed (Network 16, Device 14). PSScriptAnalyzer (Warning, Error) on the new and changed scripts: no new findings. Nothing was run against a machine or Azure.
- **Branch:** main (pushed).
- **Blockers:** The toolkit's schema 5.2 (`azurelocal-toolkit/config/infrastructure/infrastructure.schema.json`) doesn't list `provisioning.simplified.maintenance_password`, and `provisioning.simplified` has `additionalProperties: false`, so a schema 5 file with that key fails the toolkit validation until the toolkit adds it. The maintenance address has no discovery yet: it's a setting (a DHCP reservation for the provisioning port).
- **Exact next steps:** (1) Add `maintenance_password` (`kv_ref`) to the toolkit schema under `provisioning.simplified`. (2) Live: run `-From Device` on one node in the maintenance environment and record the real `SetArcBootstrapDeviceConfiguration` and status responses; correct the body or status reading if needed. (3) Live: run `-From Network` after an OS install and confirm the ApplyConfiguration job ends and the adapter reports the address. (4) Update `docs/diagrams/ztp-flow.drawio` and its PNG with the Device and Network stages.
