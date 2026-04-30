# Azure Local Configuration Module
# Provides centralized configuration management for all deployment scripts

using namespace System.Collections.Generic

class AzureLocalConfig {
    [hashtable]$Config

    AzureLocalConfig([string]$configPath) {
        if (-not (Test-Path $configPath)) {
            throw "Configuration file not found: $configPath"
        }

        $extension = [System.IO.Path]::GetExtension($configPath).ToLower()

        try {
            switch ($extension) {
                '.yaml' {
                    if (Get-Module -Name 'powershell-yaml' -ListAvailable) {
                        Import-Module powershell-yaml
                        $this.Config = Get-Content $configPath -Raw | ConvertFrom-Yaml
                    } else {
                        Write-Host "Installing PowerShell-YAML module for proper YAML parsing..." -ForegroundColor Yellow
                        try {
                            Install-Module -Name powershell-yaml -Scope CurrentUser -Force -ErrorAction Stop
                            Import-Module powershell-yaml
                            $this.Config = Get-Content $configPath -Raw | ConvertFrom-Yaml
                            Write-Host "PowerShell-YAML module installed successfully." -ForegroundColor Green
                        } catch {
                            Write-Warning "Failed to install PowerShell-YAML module. Using basic YAML parsing. $($_.Exception.Message)"
                            $this.Config = $this.ParseYamlFile($configPath)
                        }
                    }
                }
                '.json' {
                    $jsonContent = Get-Content $configPath -Raw
                    $this.Config = $jsonContent | ConvertFrom-Json -AsHashtable
                }
                default {
                    throw "Unsupported configuration file format: $extension. Supported formats: .yaml, .json"
                }
            }
        }
        catch {
            throw "Failed to load configuration from $configPath`: $($_.Exception.Message)"
        }
    }

    [object] GetValue([string]$path) {
        $keys = $path -split '\.'
        $current = $this.Config

        foreach ($key in $keys) {
            if ($current -is [hashtable] -and $current.ContainsKey($key)) {
                $current = $current[$key]
            }
            elseif ($current -is [System.Collections.IDictionary] -and $current.ContainsKey($key)) {
                $current = $current[$key]
            }
            else {
                throw "Configuration path not found: $path"
            }
        }

        return $current
    }

    [object] GetValue([string]$path, [object]$defaultValue) {
        try {
            return $this.GetValue($path)
        }
        catch {
            return $defaultValue
        }
    }

    [hashtable] GetSection([string]$section) {
        return $this.GetValue($section)
    }

    [string[]] GetNodeHostnames() {
        $hostnames = @()
        foreach ($nodeKey in $this.Config.nodes.Keys) {
            $hostnames += $this.Config.nodes[$nodeKey].hostname
        }
        return $hostnames
    }

    [string[]] GetNodeIPs() {
        $ips = @()
        foreach ($nodeKey in $this.Config.nodes.Keys) {
            $ips += $this.Config.nodes[$nodeKey].ip
        }
        return $ips
    }

    [string[]] GetIdracIPs() {
        $ips = @()
        foreach ($nodeKey in $this.Config.nodes.Keys) {
            $ips += $this.Config.nodes[$nodeKey].idrac_ip
        }
        return $ips
    }

    [hashtable] GetNodeByHostname([string]$hostname) {
        foreach ($nodeKey in $this.Config.nodes.Keys) {
            if ($this.Config.nodes[$nodeKey].hostname -eq $hostname) {
                return $this.Config.nodes[$nodeKey]
            }
        }
        throw "Node not found: $hostname"
    }

    [hashtable] GetNodeByIP([string]$ip) {
        foreach ($nodeKey in $this.Config.nodes.Keys) {
            if ($this.Config.nodes[$nodeKey].ip -eq $ip) {
                return $this.Config.nodes[$nodeKey]
            }
        }
        throw "Node not found: $ip"
    }

    [hashtable] GetNodeByIdracIP([string]$idracIP) {
        foreach ($nodeKey in $this.Config.nodes.Keys) {
            if ($this.Config.nodes[$nodeKey].idrac_ip -eq $idracIP) {
                return $this.Config.nodes[$nodeKey]
            }
        }
        throw "Node not found: $idracIP"
    }

    # Basic YAML parser for when PowerShell-YAML is not available
    hidden [hashtable] ParseYamlFile([string]$filePath) {
        $content = Get-Content $filePath -Raw
        $lines = $content -split "`n"
        $result = @{}
        $currentSection = $result
        $sectionStack = New-Object System.Collections.Stack

        foreach ($line in $lines) {
            $line = $line.Trim()

            # Skip empty lines and comments
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
                continue
            }

            # Handle section headers
            if ($line -match '^(\w+):$') {
                $sectionName = $matches[1]
                $newSection = @{}
                $currentSection[$sectionName] = $newSection
                $sectionStack.Push($currentSection)
                $currentSection = $newSection
            }
            # Handle key-value pairs
            elseif ($line -match '^(\w+):\s*(.+)$') {
                $key = $matches[1]
                $value = $matches[2].Trim('"')

                # Try to convert to appropriate type
                if ($value -match '^\d+$') {
                    $value = [int]$value
                }
                elseif ($value -match '^\d+\.\d+$') {
                    $value = [double]$value
                }
                elseif ($value -eq 'true') {
                    $value = $true
                }
                elseif ($value -eq 'false') {
                    $value = $false
                }

                $currentSection[$key] = $value
            }
            # Handle list items
            elseif ($line -match '^\s*-\s*(.+)$') {
                $value = $matches[1].Trim('"')
                if (-not $currentSection.ContainsKey('_list')) {
                    $currentSection['_list'] = @()
                }
                $currentSection['_list'] += $value
            }
        }

        return $result
    }
}

function Get-AzureLocalConfig {
    <#
    .SYNOPSIS
        Loads the Azure Local configuration from environment.yaml or environment.json

    .DESCRIPTION
        Creates an AzureLocalConfig object that provides centralized access to all
        cluster configuration values. Supports both YAML and JSON formats.
        Prefers YAML if both files exist.

    .PARAMETER ConfigPath
        Path to the configuration file. If not specified, automatically detects
        environment.yaml or environment.json in the config directory.

    .EXAMPLE
        $config = Get-AzureLocalConfig
        $subscriptionId = $config.GetValue('azure.mgmt_subscription_id')

    .EXAMPLE
        $config = Get-AzureLocalConfig -ConfigPath "C:\path\to\environment.json"
        $nodeIPs = $config.GetNodeIPs()
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath
    )

    if (-not $ConfigPath) {
        # Auto-detect configuration file
        # Get the repository root (assuming this module is in scripts/common/)
        $modulePath = $PSScriptRoot
        $repoRoot = Split-Path -Parent (Split-Path -Parent $modulePath)

        $yamlPath = Join-Path $repoRoot "config\environment.yaml"
        $jsonPath = Join-Path $repoRoot "config\environment.json"

        if (Test-Path $yamlPath) {
            $ConfigPath = $yamlPath
        }
        elseif (Test-Path $jsonPath) {
            $ConfigPath = $jsonPath
        }
        else {
            throw "No configuration file found. Expected environment.yaml or environment.json in config directory."
        }
    }

    try {
        $resolvedPath = Resolve-Path $ConfigPath
        Write-Verbose "Loading configuration from: $resolvedPath"

        $config = [AzureLocalConfig]::new($resolvedPath)
        return $config
    }
    catch {
        Write-Error "Failed to load Azure Local configuration: $($_.Exception.Message)"
        throw
    }
}

function Get-ConfigValue {
    <#
    .SYNOPSIS
        Gets a configuration value using dot notation

    .DESCRIPTION
        Convenience function to quickly retrieve configuration values without
        needing to create a config object first.

    .PARAMETER Path
        Configuration path using dot notation (e.g., 'azure.mgmt_subscription_id')

    .PARAMETER DefaultValue
        Default value to return if the path is not found

    .EXAMPLE
        $subId = Get-ConfigValue 'azure.mgmt_subscription_id'

    .EXAMPLE
        $timeout = Get-ConfigValue 'deployment.timeout' 300
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [object]$DefaultValue
    )

    try {
        $config = Get-AzureLocalConfig
        if ($PSBoundParameters.ContainsKey('DefaultValue')) {
            return $config.GetValue($Path, $DefaultValue)
        }
        else {
            return $config.GetValue($Path)
        }
    }
    catch {
        if ($PSBoundParameters.ContainsKey('DefaultValue')) {
            return $DefaultValue
        }
        else {
            throw
        }
    }
}

# Export functions
Export-ModuleMember -Function Get-AzureLocalConfig, Get-ConfigValue