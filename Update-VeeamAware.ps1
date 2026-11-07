#Requires -Version 7.2
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Checks GitHub for a newer VeeamAware release and installs it.

.DESCRIPTION
The channel comes from config "update.channel" (stable or preview), or -Channel, which is also saved to the
config. stable follows full releases; preview also gets pre-releases (and stable releases when they are
newer). config\config.json, secrets\, state\, logs\ and plugins\ are kept; the scheduled task is paused
while files are replaced.

.EXAMPLE
.\Update-VeeamAware.ps1 -Check            # only report what is available
.\Update-VeeamAware.ps1                   # update to the newest release on the configured channel
.\Update-VeeamAware.ps1 -Channel preview  # switch to the preview channel and update
.\Update-VeeamAware.ps1 -Tag v0.3.0       # install exactly this release (also to go back a version)
#>
[CmdletBinding()]
param(
    [ValidateSet('', 'stable', 'preview')][string]$Channel = '',
    [string]$Tag,
    [switch]$Check,
    [switch]$Force    # reinstall even when already up to date
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\VeeamAware.psm1') -Force
$config = Get-VAConfig
if ($Channel -and "$($config.update.channel)" -ne $Channel) {
    $path = Join-Path $PSScriptRoot 'config\config.json'
    $json = Get-Content -Raw $path | ConvertFrom-Json
    if (-not $json.PSObject.Properties['update']) { $json | Add-Member update ([pscustomobject]@{}) }
    $json.update | Add-Member channel $Channel -Force
    $json | ConvertTo-Json -Depth 20 | Set-Content $path -Encoding utf8NoBOM
    Write-Host "Update channel set to $Channel."
    $config = Get-VAConfig
}
$settings = Get-VAUpdateSettings $config

if (-not $Tag) {
    $info = Get-VAUpdateInfo -Config $config -Force
    if ($info.Error) { throw "Can't check for updates: $($info.Error)" }
    Write-Host "Installed: $($info.Current)   Newest on $($info.Channel): $($info.Latest)$(if ($info.Prerelease) { ' (pre-release)' })"
    if ($info.Url) { Write-Host "Release notes: $($info.Url)" }
    if ($Check) { if ($info.Available) { exit 10 } else { exit 0 } }
    if (-not $info.Available -and -not $Force) { Write-Host 'Already up to date.'; return }
    $Tag = $info.Tag
}
elseif ($Check) { throw '-Check and -Tag do not go together.' }

# Run the bootstrap from a temporary copy: it replaces the files in this folder, itself included.
$boot = Join-Path ([IO.Path]::GetTempPath()) "veeamaware-install-$([guid]::NewGuid().ToString('N')).ps1"
Copy-Item (Join-Path $PSScriptRoot 'install.ps1') $boot
try {
    $bootArgs = @{ Path = $PSScriptRoot; Channel = $settings.Channel; Tag = $Tag; Repository = $settings.Repository; Update = $true }
    & $boot @bootArgs
}
finally { Remove-Item $boot -Force -ErrorAction SilentlyContinue }
Write-Host "Updated to $Tag."
