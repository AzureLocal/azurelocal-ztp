# Azure Local ZTP Portal Provisioning Guide

!!! note "Note"
    This guide covers the Azure Portal provisioning phase of Zero-Touch Provisioning (ZTP) for Azure Local. It picks up after the servers have been bootstrapped into the maintenance environment using the [Server Preparation Guide](ztp-server-preparation-guide.md).

## Overview

This guide covers Phase 2 of Azure Local Zero-Touch Provisioning (ZTP). After completing the server preparation phase, the servers are running the maintenance environment and are ready to be provisioned from Azure.

The complete ZTP workflow consists of three main phases:

1. **Server Preparation** ([Server Preparation Guide](ztp-server-preparation-guide.md)) - Configure environment and prepare servers ✅
2. **Azure Portal Provisioning** (This guide) - Collect vouchers, create sites, and provision machines via Azure
3. **Cluster Deployment** - Deploy Azure Local instance via Azure portal or ARM template

### What This Guide Covers

- Collecting ownership vouchers from bootstrapped servers
- Creating an Azure Site and configuring site-level settings
- Provisioning machines from the Azure portal
- Monitoring machine setup via the Configurator App
- Verifying Azure Arc connectivity
- Cleaning up evaluation resources

## Prerequisites

Before beginning this phase, ensure the following:

- **Server Preparation Complete:**
    - All servers are running the maintenance environment (completed via [Server Preparation Guide](ztp-server-preparation-guide.md))
    - Console shows "ROE setup completed successfully" on each server
    - Virtual media has been unmounted (cleanup step)

- **Azure Prerequisites:**
    - Subscription allowlisted for Azure Local ZTP private preview
    - Required feature flags enabled and resource providers registered
    - Resource group created: `{cluster_resource_group}`

- **Permissions:**
    - Resource group **Owner**, or **Contributor** + **Role Based Access Control Administrator** on the resource group
    - Access to Azure preview portal: https://aka.ms/ztp/tryit

- **Tools Required:**
    - Windows 11 PC with reliable internet connection
    - Configurator App for Azure Local V2 (downloaded from the Azure preview portal)

- **Cluster-Specific Information:**
    - Cluster Name: `{cluster_name}`
    - Azure Region: `{region}` (East US only for private preview)
    - Node Count: {node_count}x {node_model}
    - Resource Group: `{cluster_resource_group}`
    - Key Vault: `{keyvault_azure_local_name}`

!!! warning "Important"
    In this preview release, only the **East US** region is supported. Ensure that Resource group, Azure Site, Azure Site Configuration, Azure Arc resources, and Azure Onboarding Service resources are all created under the **East US** region.

## Step 1: Collect Ownership Vouchers

After the servers have been bootstrapped into the maintenance environment, collect the ownership voucher for each machine. The ownership voucher is a `.pem` file generated during the bootstrap process that proves device identity.

### Option A: Download Voucher via Configurator App

!!! warning "Important"
    Download the Configurator App from the Azure preview portal before starting. Go to **Azure Arc > Operations > Provisioning (preview)**, then click **View Downloads** on the **Get started** page.

1. Open the Start menu, type **Configurator App**, select **Configurator App for Azure Local V2**, and then select **Run as administrator**.

1. Connect to the device using either:
    - Hostname: `ROE-<device serial number>.local`
    - IP address of the server

1. Enter the local administrator credentials:
    - Default username: `edgeuser`
    - Default password: `Password1`

1. Download the ownership voucher for each machine.

1. Repeat for all servers in the cluster:

| Service Tag | iDRAC IP |
| --- | --- |

### Option B: Copy Voucher from USB Flash Drive

If you used the USB preparation method during server bootstrap:

1. Attach the USB flash drive to the Windows 11 PC.

1. Open the USB drive folder and navigate to `\vouchers\<serial-number>\`.

1. Check the log files (`bootstrap`, `messages`, `response`) for any errors. If errors are found, contact the Microsoft team.

1. Collect the ownership voucher — a small `.pem` file named after the device's serial number.

1. The `.pem` files are small enough (a few KBs) that you can email them or use any other trusted transfer mechanism. Consider zipping multiple files together for convenience.

!!! tip "Tip"
    **Recommendation:** After collecting the vouchers, disable USB in BIOS. Enter the BIOS/UEFI interface, locate USB Configuration, and set the options to disabled. Menu names may vary by device and BIOS/UEFI version.

## Step 2: Create Azure Site

!!! warning "Important"
    Use the Azure preview portal URL to access ZTP features: https://aka.ms/ztp/tryit

1. Navigate to **Azure Arc > Operations > Provisioning (preview)** in the Azure portal.

1. On the **Get started** page, click **Provision > Azure Local** to begin provisioning.

1. **Create Site:**
    - Select your subscription: `{mgmt_subscription_id}`
    - Select your resource group: `{cluster_resource_group}`
    - Enter a name for the site (e.g., `{cluster_name}-site`)
    - Select **East US** as the region

NOTE: Make a note of the resource group name. Ensure you have the required permissions (Owner, or Contributor + Role Based Access Control Administrator).

## Step 3: Configure Site-Level Settings

After creating the site, configure the provisioning settings. These settings apply to **all new machines** added to the site.

| Description / Configuration |
| --- |

!!! note "Note"
    Support for Azure Arc gateway (which enables minimal endpoint connections to Azure Arc) is not supported in this preview. You will be notified when it becomes available.

## Step 4: Provision Machines

With the site configured, add the servers for provisioning.

1. Select the **Site** created in Step 2.

1. Select the **Software version** for Azure Local.

1. Select the **Azure Key Vault** (`{keyvault_azure_local_name}`) for storing local administrator credentials.

1. Add the **ownership vouchers** collected in Step 1 for each machine.

1. If you have an existing onboarding service, select it. Otherwise, a new one is created.

1. Once machines are added, click the **pencil button** to **Edit** each machine.

1. Provide the **machine name** as the Arc resource name for each server:

| Service Tag |
| --- |

1. On the **Review + create** tab, review all details and select **Create**.

1. Ensure that the on-site staff have racked, cabled, and booted the machines.

1. Wait approximately **15 minutes** for Arc-enabled servers to be created and mandatory extensions to install.

## Step 5: Monitor Machine Setup (Optional)

Use the Configurator App to track installation progress from your Windows 11 PC. This app is user-friendly, designed for low-tech staff at remote sites.

!!! warning "Important"
    Skip this step if not using a static IP or not tracking server installation remotely. Start these steps a few minutes after powering on the server and connecting it to the local network.

1. Open the Start menu, type **Configurator App**, select **Configurator App for Azure Local V2**.

1. Connect using the device serial number or IP address.

1. Enter the local administrator credentials:
    - Default username: `edgeuser`
    - Default password: `Password1`

1. Wait for the Azure Arc configuration to finish on the maintenance environment. After this completes, the target operating system will also install.

1. After the target operating system installs, reconnect using the IP address or hostname. Use the administrator credentials configured in Step 3 (site-level credentials).

1. Wait for the configuration to finish.

1. Repeat all steps on each server until the Arc configuration succeeds on all nodes.

## Step 6: Verify Azure Arc Connectivity

Confirm that all machines are successfully connected to Azure. During provisioning, each machine performs these steps automatically:

1. **Connect maintenance environment to cloud** — Establishes an initial Azure connection using the device identity created from the ownership voucher.

1. **Install extensions on maintenance environment** — Installs mandatory Azure Arc extensions.

1. **Download & install Azure Local operating system** — An Arc extension downloads and installs the Azure Local OS image selected in Step 4.

1. **Azure Arc connect the Azure Local operating system** — After setup completes, the machine reboots into Azure Local OS and connects to Azure Arc automatically.

### Monitor Provisioning Status

1. In the Azure portal, navigate to **Azure Arc > Operations > Provisioning (preview)**.

1. Select the **Provisioned machines** tab (or **Devices** tab).

1. Verify your machines appear in the list. Select a machine's status to view progress details.

1. Wait for each machine status to show **Ready to cluster**.

NOTE: Expected time: Up to **60 minutes** for complete setup per machine.

### Verify All Nodes

Confirm all {node_count} nodes show as **Ready to cluster** before proceeding to cluster deployment:

| Expected Arc Resource | Status |
| --- | --- |

## Next Steps

Once all machines show **Ready to cluster**:

- **Deploy Azure Local instance** via one of the following options:
    - Deploy via Azure portal
    - Deploy via Azure Resource Manager (ARM) template

- **Troubleshoot** any registration issues using the Configurator App diagnostics

## Troubleshooting

You might need to collect logs or diagnose problems if you encounter issues during provisioning. Use the following resources:

### Run Diagnostic Tests from the Configurator App

1. Select the **help icon** in the top-right corner of the app to open the **Support + troubleshooting** pane.

1. Select **Run diagnostic tests**. The tests check the health of server hardware, time server, and network connectivity. They also check the status of the Azure Arc agent and extensions.

1. After the tests complete, review the results. Resolve any issues and retry the operation.

### Collect a Support Package from the App

1. Select the **help icon** in the top-right corner of the app to open the **Support + troubleshooting** pane.

1. Select **Create** to begin support package collection. This may take several minutes.

1. After the package is created, select **Download**. A zipped package downloads to your local system. Unzip the package to view system log files.

### Get Logs if Configurator App Cannot Connect

If you cannot access the machine via the Configurator App, retrieve logs directly from the server.

| Log Files |
| --- |

Access logs by connecting via SSH (for maintenance environment) or PowerShell (for Azure Stack HCI).

### Collect Logs from Your Azure Subscription

Launch Azure Cloud Shell using Bash and run the following command:

```bash
# Replace with your actual subscription ID and resource group name
curl -fsSL "https://aka.ms/ztp/collect-armjson.sh" | bash -s -- \
  --subscription "{mgmt_subscription_id}" \
  --resource-group "rg-c01-azl-eus-01"
```

### Common Issues

- **Machine not appearing in portal:**
    - Verify the ownership voucher was uploaded correctly
    - Check that the server has network connectivity to Azure endpoints
    - Ensure the onboarding service is in the same region as the resource group

- **Arc agent not connecting:**
    - Verify network connectivity and DNS resolution
    - Check proxy settings if using a proxy server
    - Review maintenance environment logs for errors

- **Machine stuck in provisioning:**
    - Allow up to 60 minutes for complete setup
    - Check the Configurator App for detailed progress
    - Review diagnostic test results for hardware or network issues

- **Extension installation failed:**
    - Verify the server has internet connectivity
    - Check Azure Arc agent status on the server
    - Review extension logs in the Azure portal

## Clean Up (Evaluation Only)

After evaluation is complete, clean up all entities. Delete the resource group directly or run the cleanup script for a full clean-up.

!!! warning "Important"
    For this preview, delete the resource group after running the cleanup script. This removes all resources under the resource group.

Launch Azure Cloud Shell using Bash and run:

```bash
# Replace with your actual subscription ID and resource group name
curl -fsSL "https://aka.ms/ztp/cleanup.sh" | bash -s -- \
  --subscription "{mgmt_subscription_id}" \
  --resource-group "rg-c01-azl-eus-01"
```

## Document References

- [Azure Local ZTP Server Preparation Guide](ztp-server-preparation-guide.md) — Phase 1: Server preparation and bootstrap
- [ZTP Pipeline Execution Checklist](ztp-pipeline-execution.md) — CI/CD pipeline reference
- [Microsoft ZTP Private Preview Documentation](../resources/microsoft/ZTP-for-Azure-Local-Private-Preview.md) — Official Microsoft reference
