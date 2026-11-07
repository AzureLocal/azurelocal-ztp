# Appendices

Reference material for the interfaces ZTP talks to. These pages say what each call does, which ZTP stage makes it, and how we know: every statement carries an evidence label (used by ZTP, observed once, read from Microsoft documentation, or not made by ZTP).

| Appendix | What it covers |
| --- | --- |
| [A. API reference](./api-reference) | Every Azure Resource Manager call (`Microsoft.AzureStackHCI` edge machines, jobs, network adapters and OS images; `Microsoft.Edge` sites and configurations; Arc machines and extensions; deployments; Key Vault) and every Redfish call on the BMC (BIOS attributes and pending settings, virtual media, boot override, power and reset, logs). Which stage makes which call, with request and response examples, and the calls ZTP does not make but could. |
| [B. The Azure Local Configurator app API](./configurator-app-api) | The REST service the maintenance environment runs (`BootstrapOobeService`, TCP 20001): all 45 operations, how the Device stage uses three of them, how it signs in, and what is not possible (for example Arc registration, which the maintenance environment refuses). |

The stages these calls belong to are described in [Design and architecture](../architecture#stages-and-gates); what to look at while a run is going is in [Monitoring a run](../monitoring).

::: warning Not supported interfaces
The simplified machine provisioning resources are in preview, the Configurator service is an internal interface of Microsoft's Configurator app, and iDRAC behaviour differs by firmware. Microsoft does not promise any of these shapes. Use the pages for understanding, diagnosis and lab automation, and re-check them against the build you run.
:::
