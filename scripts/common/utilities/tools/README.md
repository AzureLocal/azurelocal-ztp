# Azure Local ZTP Utilities

This directory contains utility scripts and tools for Azure Local Zero-Touch Provisioning (ZTP) operations.

## Directory Structure

```
utilities/
├── helpers/           # Shared helper functions and modules
├── tools/            # Standalone utility scripts
└── README.md         # This file
```

## Available Tools

### Server Discovery and Inventory

- **`Discover-Servers.ps1`** - Performs Redfish-based server discovery and basic inventory
- **`Get-DellServerInventory-FromiDRAC.ps1`** (in discovery/) - Comprehensive Dell server inventory via iDRAC

### ISO Management

- **`Mount-AzureLocalISO.ps1`** - Mounts Azure Local maintenance environment ISO as virtual media

### Boot Configuration

- **`Set-ServerBootSource.ps1`** - Configures boot source override for one-time booting

### Server Control

- **`Restart-Servers.ps1`** - Initiates server reboots via Redfish API

## Helper Modules

The `helpers/` directory contains shared functions used by multiple tools:

- **`config-loader.ps1`** - Configuration file loading utilities
- **`error-handling.ps1`** - Standardized error handling functions
- **`keyvault-helper.ps1`** - Azure Key Vault integration helpers
- **`logging.ps1`** - Logging and output formatting functions
- **`registry-variable.ps1`** - Registry-based variable management

## Prerequisites

All tools require:
- PowerShell 7.0 or later
- Network access to BMC/iDRAC interfaces
- Valid BMC credentials with appropriate permissions
- Azure CLI (for Azure-integrated operations)

## Usage Examples

### Basic Server Discovery
```powershell
$cred = Get-Credential
.\Discover-Servers.ps1 -ServerIPs "192.168.200.11","192.168.200.12" -Credential $cred
```

### Mount ISO and Configure Boot
```powershell
# Mount ISO (using Key Vault credentials)
.\Mount-AzureLocalISO.ps1 -IsoSharePath "\\fileserver\share\maintenance-env.iso"

# Or using interactive credentials
.\Mount-AzureLocalISO.ps1 -ServerIPs "192.168.200.11" -Credential $cred -IsoSharePath "\\fileserver\share\maintenance-env.iso"

# Set boot source (using Key Vault credentials)
.\Set-ServerBootSource.ps1

# Or using interactive credentials
.\Set-ServerBootSource.ps1 -ServerIPs "192.168.200.11" -Credential $cred

# Restart server (using Key Vault credentials)
.\Restart-Servers.ps1

# Simultaneous reboot for parallel imaging
.\Restart-Servers.ps1 -DelayBetweenServers 0 -Force

# Or using interactive credentials
.\Restart-Servers.ps1 -ServerIPs "192.168.200.11" -Credential $cred
```

## Security Considerations

- Credentials are handled securely using PSCredential objects
- Scripts validate SSL certificates but can be configured to skip for self-signed BMC certificates
- All operations are logged with timestamps for audit purposes
- Results are exported to CSV/JSON for compliance tracking

## Troubleshooting

### Common Issues

1. **Redfish API Connection Failed**
   - Verify BMC IP address and network connectivity
   - Check BMC credentials and permissions
   - Ensure Redfish API is enabled in BMC settings

2. **Virtual Media Not Available**
   - Confirm BMC supports virtual media
   - Check available virtual media slots
   - Verify ISO file accessibility

3. **Boot Source Not Applied**
   - Ensure server supports boot source override
   - Check BMC firmware version compatibility
   - Verify one-time boot settings

### Logs and Diagnostics

- All tools export operation results to timestamped CSV and JSON files
- Check BMC/iDRAC event logs for hardware-specific errors
- Review PowerShell error output for script-specific issues

## Contributing

When adding new utilities:
1. Include comprehensive help documentation
2. Follow PowerShell best practices
3. Add appropriate error handling
4. Export results in consistent formats
5. Update this README with new tools

## Related Documentation

- [Azure Local ZTP Guide](../resources/ZTP-for-Azure-Local-Private-Preview.adoc)
- [Server Preparation Guide](../../docs/guides/ztp-server-preparation-guide.adoc)
- [Discovery Scripts](../discovery/)