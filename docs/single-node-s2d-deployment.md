# Single-Node Storage Spaces Direct Deployment Guide — Dell AX-760

## Overview

Complete deployment guide for transforming Dell AX-760 (node04/tplabs-01-n04) into single-node Storage Spaces Direct cluster.

**Server Details:**

- New hostname: `tplabs-s2d-n01`
- New IP: `192.168.211.15`
- Cluster name: `tplabs-s2d-clus`
- Cluster IP: `192.168.211.30`

This guide provides detailed PowerShell commands for all deployment phases.

<<<

## Operating System & Initial Configuration

### Install Windows Server 2025

Boot from installation media and install Windows Server 2025 Datacenter.

### Configure Hostname and Network

```powershell
# Set computer name
Rename-Computer -NewName "tplabs-s2d-n01" -Force

# Set timezone
Set-TimeZone -Id "Eastern Standard Time"

# Install required roles and features
# FS-SMBBW is required by Network ATC for SMB bandwidth management
Install-WindowsFeature -Name Hyper-V, Failover-Clustering, Data-Center-Bridging, `
    NetworkATC, FS-SMBBW, FS-FileServer, RSAT-Clustering-PowerShell, RSAT-Hyper-V-Tools -IncludeManagementTools

# Reboot required — Hyper-V role requires restart to complete installation.
# The hostname change from Rename-Computer also takes effect after this reboot.
Restart-Computer -Force
```

IMPORTANT: The reboot above is mandatory. Hyper-V will not function until the server is restarted after role installation.

### Install Windows Updates

After reboot, install all available updates before proceeding. S2D and Failover Clustering are sensitive to OS patch level — running an unpatched OS can cause cluster validation failures.

```powershell
# Install PSWindowsUpdate module
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers

# Scan and install all available updates
Get-WindowsUpdate -AcceptAll -Install -AutoReboot
```

NOTE: If the server reboots for updates, log back in and verify with `Get-WindowsUpdate` that no pending updates remain.

## Temporary Network Configuration

Network ATC (Network Intents) will configure the final networking — vSwitch, RDMA, RoCEv2, DCB/QoS, and jumbo frames — automatically after the cluster is created. For now, we only need basic connectivity to join the domain and create the cluster.

### Verify Physical Adapter Mapping

Verify the physical slot/port layout matches expectations before configuring. The Dell AX-760 has Mellanox ConnectX-6 Lx (2× 100 Gbps) in Slots 3 and 6, plus Broadcom NetXtreme (2× 1 Gbps) embedded.

```powershell
# List all physical adapters with slot info and link speed
Get-NetAdapter | Select-Object Name, InterfaceDescription, MacAddress, LinkSpeed, Status | Format-Table -AutoSize

# Verify RDMA-capable adapters (should be the Mellanox adapters only)
Get-NetAdapterRdma | Select-Object Name, InterfaceDescription, Enabled | Format-Table -AutoSize
```

Expected output should show four Mellanox adapters (`Slot 3 Port 1`, `Slot 3 Port 2`, `Slot 6 Port 1`, `Slot 6 Port 2`) at 100 Gbps and two Broadcom embedded adapters at 1 Gbps.

### Disable Broadcom and iDRAC NDIS Adapters

The embedded Broadcom 1 Gbps NICs are not used on this standalone S2D node — all traffic runs on the Mellanox 100 Gbps adapters. The Dell iDRAC NDIS adapter (USB NIC for OS-to-iDRAC pass-through) must also be disabled before creating the cluster — otherwise it appears as a cluster network. iDRAC management is unaffected; it uses its own dedicated management port.

```powershell
# Disable Broadcom embedded NICs
Get-NetAdapter | Where-Object {$_.InterfaceDescription -like "*Broadcom*"} | Disable-NetAdapter -Confirm:$false

# Disable iDRAC NDIS (USB NIC) — prevents it from appearing as a cluster network
Get-NetAdapter | Where-Object {$_.InterfaceDescription -like "*NDIS*"} | Disable-NetAdapter -Confirm:$false
```

### Configure Temporary Management IP

Assign a temporary management IP directly on a physical adapter so we can join the domain and create the cluster. Network ATC will replace this with the proper vSwitch + SET configuration when network intents are applied.

```powershell
# Assign temporary management IP on Slot 3 Port 1
New-NetIPAddress -InterfaceAlias "Slot 3 Port 1" -IPAddress 192.168.211.15 `
    -PrefixLength 24 -DefaultGateway 192.168.211.1
Set-DnsClientServerAddress -InterfaceAlias "Slot 3 Port 1" `
    -ServerAddresses 10.250.1.36, 10.250.1.37
```

IMPORTANT: This is a temporary configuration. When Network ATC creates the vSwitch (Configure Network Intents section), it will consume `Slot 3 Port 1` and `Slot 6 Port 1` into the SET team. The management IP will migrate to the virtual adapter automatically.

### Disable DHCP on All Adapters (Except NDIS)

Disable DHCP on every network adapter except NDIS virtual adapters. The Mellanox ports will use static IPs (management IP assigned above, storage IPs assigned later). Leaving DHCP enabled can cause unexpected IP assignments or routing conflicts.

```powershell
# Disable DHCP on all adapters except NDIS virtual adapters
Get-NetAdapter | Where-Object {$_.InterfaceDescription -notlike "*NDIS*"} | ForEach-Object {
    Set-NetIPInterface -InterfaceAlias $_.Name -Dhcp Disabled -ErrorAction SilentlyContinue
    Write-Host "Disabled DHCP on $($_.Name)" -ForegroundColor Green
}
```

## Active Directory Preparation, Domain Join & CNO Pre-Staging

### Create OU Structure

Run these commands from a domain controller or a management machine with `RSAT-AD-PowerShell`. This creates the S2D branch under the existing Clusters OU and a dedicated sub-OU for this cluster's objects (node, CNO, deployment account).

```powershell
# Run from a domain controller or machine with RSAT-AD-PowerShell:

# Create S2D OU under Clusters (skip if it already exists)
New-ADOrganizationalUnit -Name "S2D" `
    -Path "OU=Clusters,OU=Servers,OU=MGMT,DC=azrl,DC=mgmt" -ProtectedFromAccidentalDeletion $true

# Create cluster-specific OU under S2D
New-ADOrganizationalUnit -Name "tplabs-s2d-clus" `
    -Path "OU=S2D,OU=Clusters,OU=Servers,OU=MGMT,DC=azrl,DC=mgmt" -ProtectedFromAccidentalDeletion $true
```

The resulting OU structure:

```
OU=Clusters,OU=Servers,OU=MGMT,DC=azrl,DC=mgmt
  └── OU=S2D
        └── OU=tplabs-s2d-clus    ← node, CNO, and deployment account live here
```

### Create S2D Admins Security Group

Ensure the `S2D Admins` security group exists before domain-joining the node. This group will be added to the local Administrators group on S2D cluster nodes.

```powershell
# Run from a domain controller or machine with RSAT-AD-PowerShell:

# Check if the group already exists; create it if not
if (-not (Get-ADGroup -Filter 'Name -eq "S2D Admins"' -SearchBase "OU=Security Groups,OU=MGMT,DC=azrl,DC=mgmt" -ErrorAction SilentlyContinue)) {
    New-ADGroup -Name "S2D Admins" `
        -SamAccountName "S2D Admins" `
        -GroupCategory Security `
        -GroupScope DomainLocal `
        -Path "OU=Security Groups,OU=MGMT,DC=azrl,DC=mgmt" `
        -Description "Local administrators for S2D cluster nodes"
    Write-Host "Created 'S2D Admins' security group." -ForegroundColor Green
} else {
    Write-Host "'S2D Admins' security group already exists." -ForegroundColor Yellow
}
```

NOTE: Add the appropriate user accounts to this group after creation. Members of `S2D Admins` will have local administrator rights on all S2D cluster nodes.

### Join Domain

Domain join places the node computer object directly into the cluster OU. This must happen before CNO pre-staging so the node account exists when we set ACL permissions.

```powershell
# Join to domain azrl.mgmt — place the computer object in the cluster OU
$cred = Get-Credential -Message "Enter Domain Administrator credentials"
Add-Computer -DomainName "azrl.mgmt" -Credential $cred `
    -OUPath "OU=tplabs-s2d-clus,OU=S2D,OU=Clusters,OU=Servers,OU=MGMT,DC=azrl,DC=mgmt" -Restart
```

### Pre-Stage Cluster Name Object (CNO) & Deployment Account

Run these commands from a domain controller or management machine. The node must already be domain-joined (above) so its computer account exists when we grant it permissions on the CNO.

```powershell
# Run from a domain controller or machine with RSAT-AD-PowerShell:

$clusterOU = "OU=tplabs-s2d-clus,OU=S2D,OU=Clusters,OU=Servers,OU=MGMT,DC=azrl,DC=mgmt"

# Pre-stage the CNO in the cluster OU (disabled until cluster creation activates it)
New-ADComputer -Name "tplabs-s2d-clus" -SamAccountName "tplabs-s2d-clus$" `
    -Path $clusterOU -Enabled $false

# Grant the node's computer account Full Control on the CNO
$cno = Get-ADComputer -Identity "tplabs-s2d-clus"
$node = Get-ADComputer -Identity "tplabs-s2d-n01"
$acl = Get-Acl "AD:\$($cno.DistinguishedName)"
$ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule `
    $node.SID, "GenericAll", "Allow"
$acl.AddAccessRule($ace)
Set-Acl "AD:\$($cno.DistinguishedName)" $acl

# Create the lifecycle management (deployment) account in the same OU
# (must be created BEFORE granting it CNO permissions below)
$lcmPassword = Read-Host -AsSecureString -Prompt "Enter password for lcm-s2d-clus01"
New-ADUser -Name "lcm-s2d-clus01" `
    -SamAccountName "lcm-s2d-clus01" `
    -UserPrincipalName "lcm-s2d-clus01@azrl.mgmt" `
    -Path $clusterOU `
    -AccountPassword $lcmPassword `
    -Enabled $true `
    -PasswordNeverExpires $true `
    -CannotChangePassword $true `
    -Description "Lifecycle management account for tplabs-s2d-clus"

# Grant the deployment account Full Control on the CNO
# (required if lcm-s2d-clus01 will run New-Cluster — the account creating the cluster
# must have permission to activate the pre-staged CNO)
$lcm = Get-ADUser -Identity "lcm-s2d-clus01"
$acl = Get-Acl "AD:\$($cno.DistinguishedName)"
$ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule `
    $lcm.SID, "GenericAll", "Allow"
$acl.AddAccessRule($ace)
Set-Acl "AD:\$($cno.DistinguishedName)" $acl
```

### Add Local Administrators

Now that the S2D Admins group and `lcm-s2d-clus01` deployment account exist in AD, add them to the local Administrators group on the node.

```powershell
# Run on the cluster node (tplabs-s2d-n01)
Add-LocalGroupMember -Group "Administrators" -Member "MGMT\S2D Admins"
Add-LocalGroupMember -Group "Administrators" -Member "MGMT\lcm-s2d-clus01"
```

## Create Failover Cluster

```powershell
# Create output directory for validation report
New-Item -ItemType Directory -Path "C:\Temp" -Force

# Validate cluster configuration
Test-Cluster -Node "tplabs-s2d-n01" -Include "Storage Spaces Direct", Inventory, Network `
    -ReportName "C:\Temp\ClusterValidation"

# Create cluster
New-Cluster -Name "tplabs-s2d-clus" -Node "tplabs-s2d-n01" `
    -StaticAddress 192.168.211.30 -NoStorage
```

NOTE: A cloud witness is not configured for this cluster. With only one node, a quorum witness provides no benefit — if the single node goes down, the witness alone cannot maintain quorum. If this cluster is later expanded to two or more nodes, add a cloud witness at that time with `Set-ClusterQuorum -CloudWitness`.

## Configure Network Intents (Network ATC)

Network ATC automates the full network stack configuration. The intents will create the vSwitch with SET, configure RDMA (RoCEv2), DCB/QoS policies, jumbo frames, and storage network adapters — all in one shot.

IMPORTANT: The cluster must exist before adding intents. Network ATC is cluster-aware and applies configuration across all cluster nodes.

### Add Compute + Management Intent

This intent creates the SET-based vSwitch for compute and management traffic on `Slot 3 Port 1` and `Slot 6 Port 1`.

```powershell
# Create the compute + management intent
Add-NetIntent -Name "Compute_Management" `
    -Compute -Management `
    -AdapterName "Slot 3 Port 1", "Slot 6 Port 1"
```

### Add Storage Intent

This intent configures RDMA (RoCEv2), DCB/QoS, and jumbo frames on `Slot 3 Port 2` and `Slot 6 Port 2`.

```powershell
# Create storage intent with RDMA
Add-NetIntent -Name "Storage" `
    -Storage `
    -AdapterName "Slot 3 Port 2", "Slot 6 Port 2" `
    -StorageVlans 712, 713
```

NOTE: Each VLAN maps to the adapter in the same position: VLAN 712 → Slot 3 Port 2 (Storage A), VLAN 713 → Slot 6 Port 2 (Storage B). Network ATC auto-assigns storage IPs from the 10.71.1.0/24 and 10.71.2.0/24 subnets.

### Verify Intent Status

```powershell
# Check overall intent status (both should show Completed/Success)
Get-NetIntentStatus | Format-List IntentName, ConfigurationStatus, ProvisioningStatus, Error

# Verify the vSwitch was created by the Compute_Management intent
Get-VMSwitch | Select-Object Name, SwitchType, EmbeddedTeamingEnabled, NetAdapterInterfaceDescriptions

# Verify Network ATC configured RDMA, jumbo frames, and DCB
Get-NetAdapterAdvancedProperty -Name "Slot 3 Port 2", "Slot 6 Port 2" `
    -RegistryKeyword "*NetworkDirectTechnology" | Select-Object Name, RegistryKeyword, RegistryValue
Get-NetAdapterAdvancedProperty -Name "Slot 3 Port 1", "Slot 6 Port 1", "Slot 3 Port 2", "Slot 6 Port 2" `
    -DisplayName "Jumbo Packet" | Select-Object Name, DisplayValue
Get-NetAdapterRdma | Select-Object Name, Enabled, Operational | Format-Table
Get-NetQosTrafficClass | Format-Table Name, Priority, BandwidthPercentage, Algorithm
Get-NetQosPolicy | Format-Table Name, PriorityValue8021Action, NetDirectPortMatchCondition
```

NOTE: Network ATC handles all of the following automatically: vSwitch creation (SET), RDMA enablement, RoCEv2 technology setting, DCB/QoS policies (PFC priority 3, ETS bandwidth allocation), jumbo frames (MTU 9014), and SMB bandwidth limits.

### Configure Cluster Networks

After intents are provisioned, set the cluster network roles. The Dell iDRAC NDIS adapter (USB NIC for OS-to-iDRAC pass-through) also appears as a cluster network and must be excluded — it's a low-bandwidth internal link that should not carry cluster heartbeat or CSV traffic.

```powershell
# List all cluster networks to identify them
Get-ClusterNetwork | Format-Table Name, Address, Role -AutoSize

# Exclude the iDRAC NDIS adapter (USB NIC) — it shows as "Unused:Cluster Network 3" with no IP address.
# Do NOT let it participate in cluster traffic.
(Get-ClusterNetwork -Name "Unused:Cluster Network 3").Role = 0  # None

# Storage networks: cluster-internal only (heartbeat + CSV/S2D traffic)
(Get-ClusterNetwork | Where-Object {$_.Address -eq "10.71.1.0"}).Role = 1  # ClusterOnly
(Get-ClusterNetwork | Where-Object {$_.Address -eq "10.71.2.0"}).Role = 1  # ClusterOnly

# Management network: cluster + client access
(Get-ClusterNetwork | Where-Object {$_.Address -eq "192.168.211.0"}).Role = 3  # ClusterAndClient
```

NOTE: The iDRAC NDIS adapter has no IP address assigned and appears as `Unused:Cluster Network 3`. If the name differs on your system, identify it from the `Get-ClusterNetwork` output — it will be the network with a blank or missing Address — and set its Role to 0 by whatever name it has.

## Enable Storage Spaces Direct

```powershell
# Enable S2D in single-node mode
Enable-ClusterStorageSpacesDirect -SkipEligibilityChecks -CacheState Disabled -Confirm:$false -Verbose

# Create volume (Fixed provisioning — ~14TB usable from 4× Dell NVMe 3.84TB)
New-Volume -FriendlyName "VMs" -FileSystem CSVFS_ReFS `
    -StoragePoolFriendlyName "S2D on tplabs-s2d-clus" `
    -Size 13.5TB -ResiliencySettingName "Simple" -ProvisioningType Fixed

# Verify
Get-ClusterSharedVolume | Select-Object Name, State
Get-VirtualDisk | Select-Object FriendlyName, HealthStatus
```

## Configure Hyper-V

```powershell
# Grant the deployment account full control on the CSV volume
# The CSV mounts using the volume FriendlyName, not "Volume1"
icacls "C:\ClusterStorage\VMs" /grant "MGMT\lcm-s2d-clus01:(OI)(CI)F"

# Create folder structure (must exist before Set-VMHost will accept the paths)
New-Item -Path "C:\ClusterStorage\VMs\Templates" -ItemType Directory -Force
New-Item -Path "C:\ClusterStorage\VMs\Production" -ItemType Directory -Force

# Set default VM paths
Set-VMHost -VirtualHardDiskPath "C:\ClusterStorage\VMs" `
    -VirtualMachinePath "C:\ClusterStorage\VMs"
```

NOTE: CSV volumes are created with restricted NTFS ACLs. Local Administrators group membership alone does not grant access — an explicit `icacls` grant is required for the deployment account.

## SMB & RDMA Verification

```powershell
# Verify SMB Multichannel
Get-SmbClientConfiguration | Select-Object EnableMultichannel
Get-SmbServerConfiguration | Select-Object EnableMultiChannel

# Remove any default SMB bandwidth limits (no limit = full speed)
Remove-SmbBandwidthLimit -Category Default -ErrorAction SilentlyContinue

# Verify RDMA is active on storage interfaces
Get-SmbServerNetworkInterface | Where-Object {$_.RdmaCapable} |
    Select-Object InterfaceDescription, IpAddress, RdmaCapable | Format-Table -AutoSize

# Verify SMB Direct (RDMA) connections are established
Get-SmbClientNetworkInterface | Where-Object {$_.RdmaCapable} |
    Select-Object InterfaceDescription, IpAddress, RdmaCapable | Format-Table -AutoSize

# Verify RDMA adapter status
Get-NetAdapterRdma | Select-Object Name, Enabled, Operational | Format-Table -AutoSize

# Test RDMA connectivity (should show RdmaEnabled: True)
Get-ClusterStorageSpacesDirect | Select-Object BusType, CacheState
```

WARNING: If `Get-SmbServerNetworkInterface` shows `RdmaCapable: False` for the storage adapters, verify the intent provisioned correctly with `Get-NetIntentStatus` and check `Get-NetAdapterAdvancedProperty -Name "Slot 3 Port 2", "Slot 6 Port 2" -RegistryKeyword "*NetworkDirectTechnology"`.

## Validation

```powershell
# Comprehensive validation script
Write-Host "=== Cluster Status ===" -ForegroundColor Cyan
Get-Cluster | Select-Object Name, Domain, QuorumType

Write-Host "=== Cluster Nodes ===" -ForegroundColor Cyan
Get-ClusterNode | Select-Object Name, State

Write-Host "=== Storage Health ===" -ForegroundColor Cyan
Get-StoragePool -FriendlyName "S2D*" | Select-Object FriendlyName, HealthStatus
Get-VirtualDisk | Select-Object FriendlyName, HealthStatus, ResiliencySettingName

Write-Host "=== Network Status ===" -ForegroundColor Cyan
Get-NetAdapter | Where-Object {$_.Status -eq "Up"} | Select-Object Name, LinkSpeed
Get-NetAdapterRdma | Where-Object {$_.Enabled} | Select-Object Name, Enabled

Write-Host "=== CSV Volumes ===" -ForegroundColor Cyan
Get-ClusterSharedVolume | Format-Table Name, State, Node -AutoSize
```

## Post-Deployment Configuration

### Register with Azure Arc (Optional)

If this server will be managed from Azure:

```powershell
# Download and install the Azure Connected Machine agent
Invoke-WebRequest -Uri "https://aka.ms/azcmagent-windows" -OutFile "$env:TEMP\AzureConnectedMachineAgent.msi"
msiexec /i "$env:TEMP\AzureConnectedMachineAgent.msi" /qn

# Register with Azure Arc
& "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe" connect `
    --resource-group "rg-azl-arc-mgmt-tplabs-eus-01" `
    --tenant-id "a9b67171-3fbb-45bf-8394-eb56d02a86e4" `
    --location "eastus" `
    --subscription-id "{mgmt_subscription_id}"
```

### Enable Remote Management

```powershell
# Enable WinRM for remote management
Enable-PSRemoting -Force
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force

# Enable and configure OpenSSH Server
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

# Configure Windows Firewall rules for remote management
New-NetFirewallRule -DisplayName "WinRM HTTPS" -Direction Inbound -Protocol TCP `
    -LocalPort 5986 -Action Allow -Profile Domain
```

### Install Management Tools (Optional)

```powershell
# Download and install Windows Admin Center (WAC) silently
$wacUrl = "https://aka.ms/wacdownload"
$wacInstaller = "$env:TEMP\WindowsAdminCenter.msi"
Invoke-WebRequest -Uri $wacUrl -OutFile $wacInstaller

# Install WAC on port 443 with a self-signed certificate
msiexec /i $wacInstaller /qn /L*v "$env:TEMP\WAC_Install.log" `
    SME_PORT=443 SSL_CERTIFICATE_OPTION=generate

# Verify WAC service is running
Get-Service ServerManagementGateway | Select-Object Name, Status, StartType
```

## Troubleshooting

### Cluster Service Won't Start

```powershell
Start-ClusterNode -FixQuorum
```

### Storage Degraded

```powershell
Repair-VirtualDisk -FriendlyName "VMs"
Get-StorageJob  # Monitor progress
```

### RDMA Not Working

```powershell
# Check if Network ATC intents provisioned correctly
Get-NetIntentStatus | Format-List IntentName, ConfigurationStatus, ProvisioningStatus, Error

# If intents show errors, remove and re-add
Remove-NetIntent -Name "Storage"
# Then re-add the storage intent from the Configure Network Intents section

# Verify RDMA technology type is set correctly (4 = RoCEv2)
Get-NetAdapterAdvancedProperty -Name "Slot 3 Port 2", "Slot 6 Port 2" -RegistryKeyword "*NetworkDirectTechnology"

# Manually re-enable RDMA if needed (Network ATC should handle this)
Enable-NetAdapterRdma -Name "Slot 3 Port 2", "Slot 6 Port 2"

# Restart the storage adapters
Restart-NetAdapter -Name "Slot 3 Port 2", "Slot 6 Port 2"

# Verify operational status
Get-NetAdapterRdma | Select-Object Name, Enabled, Operational | Format-Table
```

## Appendix: Quick Reference

**Server Details:**

- Hostname: `tplabs-s2d-n01`
- Management IP: `192.168.211.15`
- Cluster Name: `tplabs-s2d-clus`
- Cluster IP: `192.168.211.30`
- Domain: `azrl.mgmt`

**Network Configuration:**

- Management: VLAN 711 (192.168.211.0/24)
- Storage A: VLAN 712 — 10.71.1.0/24 (Slot 3 Port 2)
- Storage B: VLAN 713 — 10.71.2.0/24 (Slot 6 Port 2)
- Tenant 1: VLAN 718 (192.168.221.0/24)
- Tenant 2: VLAN 719 (192.168.222.0/24)

**Storage Paths:**

- VMs: `C:\ClusterStorage\VMs`

**Important Notes:**

- Single-node cluster = NO high availability
- Simple resiliency only (no mirroring/parity)
- No cloud witness (single-node — witness provides no benefit)
- RDMA enabled for storage performance

## Version History

| Date | Changes |
| --- | --- |

---

*End of Deployment Guide*
