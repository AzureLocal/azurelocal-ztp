# ZTP Deployment Scripts

This directory contains PowerShell scripts for Azure Local Zero-Touch Provisioning deployment operations.

## Directory Structure

```
scripts/
├── common/                    # Shared modules and utilities
│   ├── AzureLocalConfig.psm1  # Configuration management module
│   └── RedfishUtils.psm1      # iDRAC Redfish API utilities
├── tools/
│   └── utilities/             # Individual operation scripts
│       ├── Discover-Servers.ps1
│       ├── Mount-AzureLocalISO.ps1
│       ├── Set-ServerBootSource.ps1
│       └── Restart-Servers.ps1
├── examples/                  # Example and test scripts
│   ├── ConfigExample.ps1      # Configuration usage examples
│   └── Test-ZTPDeployment.ps1 # Pipeline validation script
└── Trigger-ZTPDeployment.ps1  # Manual workflow trigger script
```

## Key Scripts

### Trigger-ZTPDeployment.ps1
Manually triggers the ZTP deployment pipeline via GitHub API.

**Usage:**
```powershell
.\scripts\Trigger-ZTPDeployment.ps1 `
    -GitHubToken "ghp_your_token" `
    -RepositoryOwner "AzureLocal" `
    -RepositoryName "azurelocal-ztp" `
    -DryRun `
    -WaitForCompletion
```

**Features:**
- Trigger workflow with custom parameters
- Optional wait for completion
- Progress monitoring
- Error handling

### Individual Operation Scripts

#### Discover-Servers.ps1
Discovers hardware information from iDRAC endpoints.

```powershell
.\scripts\tools\utilities\Discover-Servers.ps1 `
    -ServerIPs "{idrac_ips}" `
    -Credential $cred `
    -Full
```

#### Mount-AzureLocalISO.ps1
Mounts ISO files to virtual media on iDRAC.

```powershell
# Using interactive credentials
.\scripts\tools\utilities\Mount-AzureLocalISO.ps1 `
    -ServerIPs "{idrac_ips}" `
    -Credential $cred `
    -IsoSharePath "{share_network_path}\{iso_filename}"

# Using Azure Key Vault (automatic from config)
.\scripts\tools\utilities\Mount-AzureLocalISO.ps1 `
    -IsoSharePath "{share_network_path}\{iso_filename}"
```

#### Set-ServerBootSource.ps1
Configures boot source for next boot.

```powershell
.\scripts\tools\utilities\Set-ServerBootSource.ps1 `
    -ServerIPs "{idrac_ips}" `
    -Credential $cred `
    -BootSource "Cd"
```

#### Restart-Servers.ps1
Restarts servers via iDRAC.

```powershell
.\scripts\tools\utilities\Restart-Servers.ps1 `
    -ServerIPs "{idrac_ips}" `
    -Credential $cred `
    -ForceRestart
```

## Configuration Management

All scripts use centralized configuration from `config/environment.yaml` or `config/environment.json`.

### Loading Configuration
```powershell
Import-Module ".\scripts\common\AzureLocalConfig.psm1"
$config = Get-AzureLocalConfig

# Get values
$subscriptionId = $config.GetValue('azure.mgmt_subscription_id')
$nodeIPs = $config.GetNodeIPs()
```

### Quick Access
```powershell
# Get single values quickly
$clusterName = Get-ConfigValue 'resources.cluster_name'
```

## Prerequisites

### PowerShell Modules
```powershell
# Required for configuration
Install-Module -Name powershell-yaml -Force

# Required for Azure operations
Install-Module -Name Az -Force
```

### Permissions
- GitHub Personal Access Token (for trigger script)
- Azure subscription access
- iDRAC network access
- File share permissions

## Usage Patterns

### Test Configuration
```powershell
.\scripts\examples\Test-ZTPDeployment.ps1 -DryRun
```

### Manual Operations
```powershell
# Load config
Import-Module ".\scripts\common\AzureLocalConfig.psm1"
$config = Get-AzureLocalConfig

# Get credentials
$cred = Get-Credential -Message "Enter iDRAC credentials"

# Run individual operations
.\scripts\tools\utilities\Discover-Servers.ps1 -ServerIPs $config.GetIdracIPs() -Credential $cred
```

### Full Pipeline Trigger
```powershell
.\scripts\Trigger-ZTPDeployment.ps1 `
    -GitHubToken $env:GITHUB_TOKEN `
    -RepositoryOwner "AzureLocal" `
    -RepositoryName "azurelocal-ztp" `
    -SkipDiscovery `
    -WaitForCompletion
```

## Logging

All scripts generate detailed logs in the `logs/` directory:

```
logs/
├── ztp-deployment/           # Pipeline logs
├── discovery/               # Hardware discovery
├── mount/                   # ISO mount operations
├── reboot/                  # Restart operations
└── verification/            # Verification steps
```

## Error Handling

Scripts include comprehensive error handling:
- Network connectivity checks
- Credential validation
- Operation timeouts
- Detailed error messages
- Structured logging

## Security

- Credentials never logged in plain text
- Secure credential handling
- Key Vault integration for secrets
- No hardcoded sensitive data

## Testing

Use the test script to validate setup:
```powershell
.\scripts\examples\Test-ZTPDeployment.ps1 -DryRun
```

This validates:
- Configuration loading
- Script dependencies
- Directory structure
- Network connectivity (optional)

## Troubleshooting

### Common Issues

**Configuration not found:**
- Verify `config/environment.yaml` exists
- Check file permissions
- Validate YAML/JSON syntax

**Module import errors:**
- Install required PowerShell modules
- Check PowerShell execution policy
- Verify module paths

**Network connectivity:**
- Test iDRAC IP reachability
- Verify firewall rules
- Check DNS resolution

**Authentication failures:**
- Validate iDRAC credentials
- Check Key Vault access
- Verify Azure permissions

### Debug Mode
Most scripts support verbose logging:
```powershell
$VerbosePreference = "Continue"
.\script.ps1 -Verbose
```

## Contributing

When adding new scripts:
1. Follow PowerShell best practices
2. Include comprehensive help documentation
3. Add error handling and logging
4. Update this README
5. Test with dry-run mode