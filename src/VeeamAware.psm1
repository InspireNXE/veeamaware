#Requires -Version 7.2
# VeeamAware - notifications for Veeam Backup & Replication v13 (Discord, Teams, generic webhooks, plugins).
# Copyright (c) 2026 InspireNXE. MIT License, see LICENSE.

Set-StrictMode -Version 3.0

$script:VAVersion = '0.1.1'
# GitHub owner/repo that releases and updates come from (config update.repository overrides it).
$script:VARepository = 'inspirenxe/veeamaware'
$script:VARoot = Split-Path -Parent $PSScriptRoot

foreach ($part in 'Common', 'Config', 'State', 'Rest', 'PSProvider', 'Source', 'Report', 'Events', 'Targets', 'Routing', 'Health', 'Flapping', 'Update', 'Setup') {
    . (Join-Path $PSScriptRoot "$part.ps1")
}

# Target types (built-in, then plugins\targets). Dot-sourced here so their functions live in the module.
foreach ($file in @(Get-VATargetModuleFiles)) {
    try { . $file.FullName }
    catch {
        $script:VAPluginErrors.Add("$($file.Name): $($_.Exception.Message)")
        Write-Warning "VeeamAware: target module $($file.FullName) failed to load: $($_.Exception.Message)"
    }
}
Remove-Variable file -ErrorAction SilentlyContinue

Export-ModuleMember -Function *-VA*
