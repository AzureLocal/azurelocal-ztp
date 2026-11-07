# azurelocal-ztp

> Zero-touch provisioning for Azure Local. Automates Microsoft's [simplified machine provisioning (preview)](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning) end to end, from bare machines to nodes that are ready for cluster Validate, with no USB stick and no one in the rack.

## What it does

You supply an environment file and the OEM's Solution Builder Extension (SBE). One command then:

1. Downloads and checks the maintenance ISO, and builds one virtual USB image per node.
2. Boots each node from its image over the BMC (Redfish virtual media, USB-stick slot), all nodes in parallel.
3. Reads each node's ownership voucher back from its image.
4. Claims the machines in Azure with a Bicep template, waits for "Ready to cluster", and resubmits a failed OS install once.
5. Writes a handoff with each machine's `arcMachineResourceId`.
6. Prepares each node for Validate: the SBE's network drivers, the SBE in `C:\SBE`, the deployment admin, one static management address and one default gateway.

Each stage starts only when the gate before it passes, and a rerun resumes where the last run stopped.

![Azure Local ZTP flow](docs/diagrams/ztp-flow.png)

## Status

| Item | State |
| --- | --- |
| Microsoft feature | Preview. Provisioning resources in **East US** only. Arc gateway not supported. |
| End-to-end flow | **Proven on Dell AX-760 / iDRAC 7.30**: two nodes, Azure Local build `12.2690.1003.15`, maintenance image `10.2610.0.3063`. |
| Microsoft support | AX-760 isn't on Learn's [validated hardware list](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning#hardware-prerequisites) for this flow (Dell AX-650 and AX-750, Lenovo ThinkAgile MX650 V3 and V4, HPE ProLiant DL360 Gen11). It works, but Microsoft doesn't support it. |
| Other OEMs | BMC handling and node preparation are proven on Dell iDRAC only. |
| Scope | Ends at "ready for Validate". Active Directory preparation, Validate and Deploy are separate. |

## Quickstart

On a Windows management host that reaches the BMCs, in an elevated PowerShell 7 session:

```powershell
git clone https://github.com/AzureLocal/azurelocal-ztp.git
cd azurelocal-ztp

# 1. Copy the example environment file outside the repo and fill it in (no secrets: Key Vault references only)
Copy-Item ./examples/infrastructure.example.yml D:\ztp\infrastructure.yml

# 2. Download the OEM SBE (zip, its xml, SBE_Discovery_<OEM>.xml) and set ztp.node_preparation.sbe_bundle to that folder

# 3. Plan: changes nothing in Azure, on the BMCs or on the nodes
Connect-AzAccount -Tenant <tenant-id>
./scripts/simplified-provisioning/Invoke-ZtpEnvironment.ps1 -InfrastructureFile D:\ztp\infrastructure.yml

# 4. Execute: REINSTALLS the nodes; rerun the same command to resume
./scripts/simplified-provisioning/Invoke-ZtpEnvironment.ps1 -InfrastructureFile D:\ztp\infrastructure.yml -Execute
```

Read the [Operator guide](docs/operator-guide.md) before you run it. It lists the Azure, hardware, BMC, network and host prerequisites.

## Documentation

| Page | What it covers |
| --- | --- |
| [Design and architecture](docs/architecture.md) | Stages and gates, what runs where, data flow, resume, parallelism, limits |
| [Operator guide](docs/operator-guide.md) | Prerequisites, inputs, plan and execute runs, watching, resume, the handoff |
| [Master infrastructure.yml (schema 5)](docs/infrastructure-schema-5.md) | How ZTP reads the master file every Azure Local tool reads, key by key |
| [Environment file reference](docs/environment-file.md) | Every key the scripts read, in the older layout (deprecated) |
| [Running from a pipeline](docs/automation-pipelines.md) | Self-hosted runner, identity, secrets, approval; examples for Azure DevOps, GitHub Actions and GitLab CI |
| [Troubleshooting and known issues](docs/troubleshooting.md) | 5901 and the resubmit, registration delay, iDRAC quirks, Arc names, node state after install |
| [Orchestrator reference](docs/automated-bootstrap.md) | Driving `Invoke-ZtpProvisioning.ps1` directly; events and handoff format |
| [Bootstrap media and the OEM SBE](docs/bootstrap-media-and-sbe.md) | How the ISO and SBE are found and checked |
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
├── examples/                      # Example environment file and pipelines (placeholders only)
├── scripts/
│   ├── simplified-provisioning/   # Entry point, orchestrator, stage scripts, node preparation, Bicep
│   └── common/                    # Earlier BMC, discovery and utility scripts
├── config/
│   ├── oem/                       # OEM definitions: SBE manifest, driver folders, BMC log patterns
│   └── simplified-provisioning/   # Example and schema of the orchestrator inputs (generated files are git-ignored)
└── tests/simplified-provisioning/ # Pester 5 tests with recorded fixtures (no hardware, no Azure)
```

Run the tests with `Invoke-Pester ./tests/simplified-provisioning`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). This repo follows the org-wide [AzureLocal standards](https://azurelocal.cloud/standards/); see [STANDARDS.md](STANDARDS.md).

## License

[MIT](LICENSE).
