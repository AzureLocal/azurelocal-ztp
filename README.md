# azurelocal-ztp

> Zero-touch provisioning for Azure Local. Automates Microsoft's [simplified machine provisioning (preview)](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning) end to end, from bare machines to provisioned, Arc-connected nodes, with no USB stick and no one in the rack.

## What it does

You supply an environment file. One command then:

1. Downloads and checks the maintenance ISO, and builds one virtual USB image per node.
2. Sets the BIOS values the file names, and boots each node from its image over the BMC (Redfish virtual media, USB-stick slot), all nodes in parallel.
3. Reads each node's ownership voucher back from its image.
4. Sets each static management address on the port with the node's management MAC, in the maintenance environment, before the claim.
5. Claims the machines in Azure with a Bicep template, waits for "Ready to cluster", and resubmits a failed OS install once.
6. Checks each management address on the management port through Azure, and moves it there if the install put it elsewhere.
7. Sets back any BIOS value that was changed for the install only, and waits until each machine is Connected again.
8. Writes a handoff with each machine's Arc machine name and `arcMachineResourceId`.

The stages are Resolve, Media, Boot, Bootstrap, Vouchers, Device, Azure, Ready, Network, Restore and Handoff. Each stage starts only when the gate before it passes, and a rerun resumes where the last run stopped.

**The result:** each machine is **Provisioned** in Azure and **Arc-connected**, with its management IP on the management NIC (found by MAC) as the infrastructure file says. The nodes are ready for OS configuration, not yet for Validate. See [What's next: OS configuration](#whats-next-os-configuration).

![Azure Local ZTP flow, from start to handoff](docs/diagrams/ztp-flow-to-handoff.png)

## Status

| Item | State |
| --- | --- |
| Microsoft feature | Preview. Provisioning resources in **East US** only. Arc gateway not supported. |
| End-to-end flow | **Proven on Dell AX-760 / iDRAC 7.30**: two nodes, Azure Local build `12.2690.1003.15`, maintenance image `10.2610.0.3063`. |
| Microsoft support | AX-760 isn't on Learn's [validated hardware list](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#hardware-prerequisites) for this flow (Dell AX-650 and AX-750, Lenovo ThinkAgile MX650 V3 and V4, HPE ProLiant DL360 Gen11). It works, but Microsoft doesn't support it. |
| Other OEMs | BMC handling is proven on Dell iDRAC only. |
| Scope | Ends at the handoff: provisioned, Arc-connected nodes with the management address on the management NIC. OS configuration, Active Directory preparation, Validate and Deploy are separate. |

## Quickstart

Check the [Prerequisites](docs/prerequisites.md) first. Then, on a Windows management host that reaches the BMCs, in an elevated PowerShell 7 session:

```powershell
git clone https://github.com/AzureLocal/azurelocal-ztp.git
cd azurelocal-ztp

# 1. Copy a toolkit template outside the repo and fill it in (no secrets: Key Vault references only).
#    ZTP only: infrastructure.ztp.example.yml. ZTP, then OS configuration and deployment: infrastructure.example.yml.
Copy-Item <azurelocal-toolkit>\config\infrastructure\infrastructure.ztp.example.yml D:\ztp\infrastructure.yml

# 2. Plan: changes nothing in Azure, on the BMCs or on the nodes
Connect-AzAccount -Tenant <tenant-id>
./scripts/simplified-provisioning/Invoke-ZtpEnvironment.ps1 -InfrastructureFile D:\ztp\infrastructure.yml

# 3. Execute: REINSTALLS the nodes; rerun the same command to resume
./scripts/simplified-provisioning/Invoke-ZtpEnvironment.ps1 -InfrastructureFile D:\ztp\infrastructure.yml -Execute
```

Which template to start from:

| You use | Start from |
| --- | --- |
| ZTP only, with nothing automated after it | The toolkit's ZTP-only template, [`infrastructure.ztp.example.yml`](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/config/infrastructure/infrastructure.ztp.example.yml) |
| ZTP, then OS configuration and cluster deployment | The full template, [`infrastructure.example.yml`](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/config/infrastructure/infrastructure.example.yml) |

Read the [Operator guide](docs/operator-guide.md) before you run it.

### Things to know before you run it

- **Static management address by MAC, before the claim.** `networking.management.static_method` is `device` (the default) or `site`. With `device`, the Device stage sets the address on the management port in the maintenance environment, the site's network setting is **Automatic**, and the claim carries no `Manual` adapter. `site` keeps the earlier path (site `Manual` over `site_ip_range`) for environments without the Device stage. The Network stage checks the address after the install either way.
- **No maintenance address needed.** Without `maintenance_address`, the Device stage scans `networking.management.provisioning_dhcp_range` (default: the management subnet, at most 4096 addresses) on TCP 20001 and finds each node by its management MAC.
- **Restore stage.** `hardware.bios_during_provisioning` holds BIOS values for the install only. Boot applies them; Restore sets them back to `hardware.bios` (or the value saved before Boot), restarts the node, and waits until it's Connected again. Without the key, Restore does nothing.
- **Handoff schema 2.** The handoff carries only what Azure generated: the site, the installed `solution.vsrVersion`, and per node the edge and Arc machine names and IDs, `managementAddressVerified` and `biosRestored`. It no longer carries `sbe`, `bootstrap`, `timestamps`, `connectivity` or a top-level `arcMachineResourceGroup`.
- **No SBE.** The OS install discovers its own SBE, and OS configuration stages it. A file with `hardware.sbe` or `ztp.node_preparation` still works; the run ignores them with a `Note:` line.

## What's next: OS configuration

ZTP doesn't install OEM drivers, stage the SBE in `C:\SBE`, turn DHCP off on the other NICs, set DNS or time on the host, or create the deployment admin. Those happen in OS configuration, [azurelocal-toolkit Phase 03: OS Configuration](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/), before Validate and Deploy.

| Step | Page |
| --- | --- |
| Check the static management address ZTP set | [Task 03: Static IP](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-03-configure-static-ip-address) |
| Turn DHCP off on the other NICs | [Task 04: Disable DHCP on all adapters](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-04-disable-dhcp-on-management-adapter) |
| Set DNS | [Task 05: DNS](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-05-configure-dns-servers) |
| Set time | [Task 07: NTP](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-07-configure-time-synchronization-ntp) |
| Disable unused NICs | [Task 09: Disable unused adapters](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-09-disable-unused-network-adapters) |
| All steps in one script | [Task 15: Combined script](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-15-complete-combined-script-all-steps) |
| Verify the phase | [Task 16: Verification](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/task-16-phase03-verification) |

OEM drivers, the SBE and the deployment admin are part of [Phase 03](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/) too. Then cluster deployment continues with [Phase 05: Cluster Deployment](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-05-cluster-deployment/). The whole sequence is in [Part 4: Cluster Deployment](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/).

**Find NICs by MAC.** ZTP-built nodes run Microsoft's provisioned OS, which names the NICs `Port0` to `Port6`. OS configuration scripts must find each NIC by its MAC, not by name.

## Documentation

| Page | What it covers |
| --- | --- |
| [Prerequisites](docs/prerequisites.md) | What to have in place before the first run |
| [Design and architecture](docs/architecture.md) | Stages and gates, what runs where, data flow, resume, parallelism, limits |
| [Operator guide](docs/operator-guide.md) | Prerequisites, inputs, plan and execute runs, watching, resume, the handoff, what's next |
| [Monitoring a run](docs/monitoring.md) | What each stage checks, the event file, Sonar, reading what you see |
| [Master infrastructure.yml (schema 5)](docs/infrastructure-schema-5.md) | How ZTP reads the master file every Azure Local tool reads, key by key |
| [Environment file reference](docs/environment-file.md) | Every key the scripts read, in the older layout (deprecated) |
| [Running from a pipeline](docs/automation-pipelines.md) | Self-hosted runner, identity, secrets, approval; examples for Azure DevOps, GitHub Actions and GitLab CI |
| [Troubleshooting and known issues](docs/troubleshooting.md) | 5901 and the resubmit, registration delay, iDRAC quirks, Arc names, node state after install |
| [Orchestrator reference](docs/automated-bootstrap.md) | Driving `Invoke-ZtpProvisioning.ps1` directly; events and handoff format |
| [Bootstrap media](docs/bootstrap-media.md) | How the maintenance ISO is found and checked, and why there's no SBE in ZTP |
| [Redfish virtual USB and vouchers](docs/redfish-virtual-usb-vouchers.md) | The virtual USB boot and voucher read-back, script by script |
| [Azure provisioning from vouchers](docs/azure-provisioning-vouchers.md) | The Bicep template, the claim and the wait for ready |

The docs site is built with VitePress from `docs/`:

```powershell
cd docs
npm install
npm run docs:dev
```

## Repository layout

```text
.
├── docs/                          # VitePress documentation; diagrams/ holds the draw.io flow chart and its PNG
├── examples/                      # Example environment file (older layout) and pipelines (placeholders only)
├── scripts/
│   ├── simplified-provisioning/   # Entry point, orchestrator, stage scripts, Bicep
│   └── common/                    # Earlier BMC, discovery and utility scripts
├── config/
│   ├── oem/                       # OEM definitions: BMC kind, log services and signal patterns
│   └── simplified-provisioning/   # Example and schema of the orchestrator inputs (generated files are git-ignored)
└── tests/simplified-provisioning/ # Pester 5 tests with recorded fixtures (no hardware, no Azure)
```

Run the tests with `Invoke-Pester ./tests/simplified-provisioning`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). This repo follows the org-wide [AzureLocal standards](https://azurelocal.cloud/standards/); see [STANDARDS.md](STANDARDS.md).

## License

[MIT](LICENSE).
