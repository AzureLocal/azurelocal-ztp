---
layout: home

hero:
  name: Azure Local ZTP
  text: Zero-touch provisioning for Azure Local
  tagline: From bare machines to nodes that are ready for cluster Validate, with one command, an environment file and the OEM's SBE. No USB stick, no one in the rack.
  image:
    src: /assets/images/azurelocal-ztp-icon.svg
    alt: Azure Local ZTP
  actions:
    - theme: brand
      text: Operator guide
      link: /operator-guide
    - theme: alt
      text: How it works
      link: /architecture
    - theme: alt
      text: View on GitHub
      link: https://github.com/AzureLocal/azurelocal-ztp

features:
  - icon: 🧾
    title: Two inputs
    details: Fill in the environment file and point it at the OEM's Solution Builder Extension. Everything else is automated, behind gates that check each step is ready.
    link: /environment-file
    linkText: Environment file reference
  - icon: 🔌
    title: Boot over the BMC
    details: Builds one virtual USB image per machine and boots every machine from it at once over Redfish. The ownership voucher is read back from the image.
    link: /redfish-virtual-usb-vouchers
    linkText: Virtual USB and vouchers
  - icon: ☁️
    title: Claimed in Azure
    details: A Bicep template creates the site and claims the machines with their vouchers. The run waits for Ready to cluster and resubmits a failed OS install once.
    link: /azure-provisioning-vouchers
    linkText: Azure provisioning
  - icon: 🧰
    title: Ready for Validate
    details: Installs the OEM network drivers from the SBE, puts the SBE in C:\SBE, sets one static management address and one gateway, and checks every machine.
    link: /architecture#the-prepare-gates
    linkText: The Prepare gates
  - icon: 🚦
    title: Management host or pipeline
    details: Runs from a Windows management host, or from a self-hosted Windows runner with an approval before the destructive Boot stage. Resume with -From.
    link: /automation-pipelines
    linkText: Running from a pipeline
  - icon: 🩺
    title: Known issues, handled
    details: Proven live on Dell AX-760 with iDRAC 7.30. The issues found on those runs, and Microsoft Learn's recovery steps, are written down.
    link: /troubleshooting
    linkText: Troubleshooting
---

## How a run flows

![From the environment file to machines ready to join a cluster](./diagrams/ztp-flow.png)

| You supply | You get |
| --- | --- |
| The environment file: machines, BMC addresses, network, Azure subscription, resource group, site, OS build, and Key Vault references | Every machine provisioned on the pinned Azure Local build, Arc connected, and ready for cluster Validate |
| The folder with the OEM's SBE files | The OEM network drivers installed, the SBE in `C:\SBE`, and a handoff with each machine's `arcMachineResourceId` |

::: warning Preview
Microsoft's simplified machine provisioning is in preview, in East US only, and doesn't support Arc gateway. Read the [overview](/overview) for the current status and limits before you start.
:::

## Part of the Azure Local tools

Check the network with [Beacon](https://azurelocal.cloud/azurelocal-beacon/) before you start, watch the run with [Sonar](https://azurelocal.cloud/azurelocal-sonar/), and document the result with [Ranger](https://azurelocal.cloud/azurelocal-ranger/). More at [azurelocal.cloud](https://azurelocal.cloud/).
