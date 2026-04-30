# Azure Local Configuration System

This directory contains the centralized configuration system for Azure Local ZTP deployments. Instead of hardcoding values in scripts, all configuration is stored in structured files that can be easily updated and version controlled.

## Configuration Files

### environment.yaml (Recommended)
- Human-readable format with comments
- Supports complex data structures
- Better for configuration management
- Requires PowerShell-YAML module (recommended) or uses basic parsing

### environment.json
- Machine-friendly format
- No comments support
- Native PowerShell JSON support
- Smaller file size

Both formats contain identical data and are automatically detected by the configuration module.

## Usage

### Basic Usage
```powershell
# Import the configuration module
Import-Module ".\scripts\common\AzureLocalConfig.psm1"

# Load configuration (auto-detects YAML or JSON)
$config = Get-AzureLocalConfig

# Access values using dot notation
$subscriptionId = $config.GetValue('azure.mgmt_subscription_id')
$clusterName = $config.GetValue('resources.cluster_name')
```

### Convenience Functions
```powershell
# Quick access to single values
$adminUser = Get-ConfigValue 'deployment.local_admin_username'
$nodeIPs = Get-ConfigValue 'nodes.node_01.ip'
```

### Specialized Methods
```powershell
# Get all node hostnames
$hostnames = $config.GetNodeHostnames()

# Get all iDRAC IPs
$idracIPs = $config.GetIdracIPs()

# Get node details by hostname
$node = $config.GetNodeByHostname('{node_hostname_1}')

# Get network configuration section
$networking = $config.GetSection('networking')
```

## Configuration Structure

```
azure:                    # Azure identity and subscriptions
resources:               # Azure resource names and IDs
keyvault:               # Key Vault configuration
active_directory:       # AD domain and server details
nodes:                  # Physical node configurations
arc_nodes:              # Azure Arc resource IDs
networking:             # Network configuration
storage:                # Storage (Pure) configuration
deployment:             # Deployment credentials and settings
hardware:               # Hardware specifications
switch_ports:           # Network switch port mappings
ztp:                    # ZTP-specific settings
scripts:                # Script directory paths
```

## Examples

See `scripts/examples/ConfigExample.ps1` for complete usage examples.

## Updating Configuration

1. Edit `environment.yaml` or `environment.json`
2. Update values as needed for different environments
3. Commit changes to version control
4. All scripts automatically use updated values

## Security Notes

- Sensitive values like passwords are marked as `[SECURED]`
- Use Azure Key Vault for actual credential storage
- Never commit real credentials to version control
- Use the Key Vault integration functions for secure credential retrieval

## Migration from Hardcoded Values

When updating existing scripts:

1. Replace hardcoded values with configuration lookups
2. Use `Get-ConfigValue` for simple values
3. Use `$config.GetValue()` for complex access patterns
4. Test scripts with new configuration system

Example migration:
```powershell
# Before
$subscriptionId = "{mgmt_subscription_id}"

# After
$subscriptionId = Get-ConfigValue 'azure.mgmt_subscription_id'
```

## Benefits

- **Single Source of Truth**: All configuration in one place
- **Environment Flexibility**: Easy switching between dev/test/prod
- **Version Control**: Configuration changes are tracked
- **Consistency**: All scripts use identical values
- **Maintainability**: Updates require changes in only one file
- **Security**: Sensitive data can be externalized to Key Vault