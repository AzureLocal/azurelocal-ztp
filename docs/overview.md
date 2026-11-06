# Overview

![Azure Local ZTP](/assets/images/azurelocal-ztp-banner.svg)

> Zero-touch provisioning for Azure Local: from bare machines to nodes that are ready for cluster Validate, with one command and no USB stick.

## What this repo does

Microsoft's [simplified machine provisioning (preview)](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning) has an operator write a USB stick, plug it into each machine, collect each voucher, and claim the machines in the portal. This repo automates the whole flow from a management host or a pipeline:

1. Downloads and checks the maintenance ISO, and builds one virtual USB image per node.
2. Boots each node from its image over the BMC (Redfish virtual media). No one needs to be in the rack.
3. Reads each node's ownership voucher back from its image.
4. Claims the machines in Azure with a Bicep template, waits for the OS install and Arc, and resubmits a failed OS install once.
5. Installs the OEM's network drivers from the SBE, copies the SBE to `C:\SBE`, creates the deployment admin and sets one static management address.
6. Writes a handoff with each machine's `arcMachineResourceId` for the cluster deployment.

You supply two things: an environment file and the OEM's SBE. Then you run `Invoke-ZtpEnvironment.ps1`, first as a plan, then with `-Execute`.

![Azure Local ZTP flow](./diagrams/ztp-flow.png)

## Status

| Item | State |
| --- | --- |
| Microsoft feature | Preview. Provisioning resources in East US only. Arc gateway not supported ([Learn](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning)). |
| End-to-end flow | **Proven on Dell AX-760 / iDRAC 7.30**, two nodes, Azure Local build `12.2690.1003.15`, maintenance image `10.2610.0.3063`. AX-760 isn't on Learn's validated list for this flow, so it's not supported by Microsoft. |
| Other OEMs | The BMC handling and Prepare are proven on Dell iDRAC only. Lenovo, HPE and Supermicro have OEM files with the SBE manifest address only. |
| Scope | Ends at "ready for Validate". Active Directory preparation, Validate and Deploy are separate. |

## Where to start

| If you want to... | Read |
| --- | --- |
| Understand the stages, gates, data flow and limits | [Design and architecture](architecture.md) |
| Run it from a management host | [Operator guide](operator-guide.md) |
| Fill in the environment file | [Environment file reference](environment-file.md) |
| Run it from Azure DevOps, GitHub Actions or GitLab CI | [Running from a pipeline](automation-pipelines.md) |
| Fix a failed or slow run | [Troubleshooting and known issues](troubleshooting.md) |
| Drive the orchestrator directly, or read the event format | [Orchestrator reference](automated-bootstrap.md) |
| Know how the ISO and SBE are found and checked | [Bootstrap media and the OEM SBE](bootstrap-media-and-sbe.md) |
| Know how the virtual USB boot and voucher read-back work | [Redfish virtual USB and voucher read-back](redfish-virtual-usb-vouchers.md) |
| Know what the Azure template creates | [Azure provisioning from vouchers](azure-provisioning-vouchers.md) |

The [Server preparation](server-preparation.md) and [Azure portal provisioning](azure-portal-provisioning.md) guides describe an earlier, manual route. They're kept for reference and are superseded by the operator guide.
