---
layout: home

hero:
  name: Azure Local ZTP
  text: Zero-touch provisioning for Azure Local
  tagline: From bare machines to provisioned, Arc-connected nodes, with one command and an environment file. No USB stick, no one in the rack.
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
    title: One input
    details: Fill in the environment file, started from the toolkit's template. Everything else is automated, behind gates that check each step is ready.
    link: /infrastructure-schema-5
    linkText: Master infrastructure.yml
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
    title: Management address by MAC
    details: Sets each static management address on the port with the management MAC in the maintenance environment, before the claim, and checks it through Azure after the install. Sets back BIOS values changed for the install only.
    link: /operator-guide#how-the-management-address-gets-set
    linkText: How the address gets set
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

![Azure Local ZTP: from infrastructure.yml to provisioned machines and the handoff](./diagrams/ztp-flow-to-handoff.png)

| You supply | You get |
| --- | --- |
| The environment file: machines, BMC addresses, network, Azure subscription, resource group, site, OS build, and Key Vault references | Every machine Provisioned on the pinned Azure Local build and Arc-connected, with its management IP on the management NIC (found by MAC), and a handoff with each machine's Arc machine name and `arcMachineResourceId` |

The stages are Resolve, Media, Boot, Bootstrap, Vouchers, Device, Azure, Ready, Network, Restore and Handoff.

::: tip What's next: OS configuration
ZTP ends with the nodes ready for OS configuration, not for Validate. OEM drivers, the SBE, DHCP off on the other NICs, DNS and time on the host, and the deployment admin come next, in [azurelocal-toolkit Phase 03: OS Configuration](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/). ZTP-built nodes name their NICs `Port0` to `Port6`, so OS configuration scripts must find NICs by MAC. See [What's next](/operator-guide#whats-next-os-configuration).
:::

::: warning Preview
Microsoft's simplified machine provisioning is in preview, in East US only, and doesn't support Arc gateway. Read the [overview](/overview) for the current status and limits, and the [prerequisites](/prerequisites), before you start.
:::

## Part of the Azure Local tools

Check the network with [Beacon](https://azurelocal.cloud/azurelocal-beacon/) before you start, watch the run with [Sonar](https://azurelocal.cloud/azurelocal-sonar/) (see [Monitoring a run](/monitoring)), and document the result with [Ranger](https://azurelocal.cloud/azurelocal-ranger/). More at [azurelocal.cloud](https://azurelocal.cloud/).
