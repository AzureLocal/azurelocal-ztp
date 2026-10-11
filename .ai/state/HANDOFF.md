# Handoff

<!--
  Written at the END of every session by whichever tool was used.
  This is the single most important cross-tool file — the next session
  (possibly a different tool) starts by reading it.
-->

## Last session

- **What changed and why:** Ported the zero-touch-provisioning automation into attendee/product form under `scripts/simplified-provisioning/`: per-node virtual USB image writer and reader (pure PowerShell GPT + FAT32), Redfish mount/eject/status with read-back proof and one-time USB boot, SMB share publisher, voucher waiter/reader with Configurator App fallback, a small self-contained Redfish client, the Azure half (OS image resolver, Bicep template reproducing the portal deployment, orchestrator with Prereqs/Validate/Plan/Execute/Watch, ready poller with `ProvisionOs` retry, Arc machine name map) and Pester tests with recorded-response fixtures. All inputs are explicit parameters or two documented example files; no lab values. Two docs pages added (VitePress nav and sidebar updated), README and docs index link them.
- **Files touched:**
  - New: `scripts/simplified-provisioning/*.ps1` (14 scripts), `scripts/simplified-provisioning/README.md`, `scripts/simplified-provisioning/bicep/main.bicep`, `bicep/modules/key-vault-delegation.bicep`, `bicep/main.example.parameters.json`, `config/simplified-provisioning/nodes.example.json`, `tests/simplified-provisioning/{ZtpVirtualUsb,ZtpAzure,ZtpRedfish}.Tests.ps1`, `tests/simplified-provisioning/fixtures/*.json`, `docs/redfish-virtual-usb-vouchers.md`, `docs/azure-provisioning-vouchers.md`.
  - Modified: `docs/.vitepress/config.mts` (nav + sidebar), `docs/index.md`, `README.md`, `scripts/README.md`, `config/README.md`, `.gitignore` (real node lists/parameters/vouchers/images), `.ai/state/HANDOFF.md`, `.ai/memory/COMMANDS.md`.
  - `CHANGELOG.md` not edited: release-please owns it.
- **Commands / tests run and results:** `Invoke-Pester tests/simplified-provisioning` (Pester 5.9.1): 107 passed, 0 failed, 0 skipped (includes `az bicep build` of the template). `Invoke-ScriptAnalyzer` (Error + Warning, default rules, scripts and tests): 0 findings. `az bicep build` of `main.bicep` and the module: clean. VitePress build not run (no `node_modules`, offline); `config.mts` nav and sidebar parsed and checked. No hardware, BMC or Azure call was made.
- **Branch:** main — committed: no — pushed: no
- **Blockers:** None. Not proven live: voucher write-back by the maintenance environment into the read-write image, the scripted Azure submit end to end, the `ProvisionOs` retry. Proven: USB-stick-slot `.img` boot on Dell 16G, portal-equivalent Azure deployment.
- **Exact next steps:** (1) Review and commit (`feat(simplified-provisioning): ...`). (2) Done in the same session: `scripts/simplified-provisioning/Invoke-ZtpProvisioning.ps1` (Media -> Boot -> Vouchers -> Azure -> Ready; plan by default, `-Execute`, `-Stage`/`-From`, resumable state file, settings via `-ConfigPath` with `config/simplified-provisioning/ztp-provisioning.example.json`), `tests/simplified-provisioning/ZtpProvisioning.Tests.ps1` (10 tests with stub stages; suite now 117 passed, 0 failed), analyzer 0, docs section "All stages with one command" in `docs/redfish-virtual-usb-vouchers.md`, README and scripts README updated, `.gitignore` ignores `*.state.json`. Not run on hardware. (3) Run the live checks listed above on real hardware and update the "proven" tables in the two docs pages. (4) Run `cd docs && npm install && npm run docs:build` to confirm the site builds.
