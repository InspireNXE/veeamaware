#Requires -Version 7.2
<#
.SYNOPSIS
Pauses VeeamAware's health alerts (Veeam services down, stuck sessions, watcher failures) for planned work.

.DESCRIPTION
Job reports, malware, repository and analyzer alerts still go out. VeeamAware also pauses health alerts by
itself while it sees a Veeam installer running, and for a while after VBR's version changes; maintenance mode
is for everything else (Windows updates, storage work, moving the database...).

Run as administrator (the state folder is limited to SYSTEM and Administrators).

.EXAMPLE
.\Set-VeeamAwareMaintenance.ps1                                  # show the current state
.\Set-VeeamAwareMaintenance.ps1 -Minutes 120 -Reason 'Patching'  # quiet for two hours
.\Set-VeeamAwareMaintenance.ps1 -Off                             # end it now
#>
[CmdletBinding(DefaultParameterSetName = 'Show')]
param(
    [Parameter(Mandatory, ParameterSetName = 'On')][ValidateRange(1, 10080)][int]$Minutes,
    [Parameter(ParameterSetName = 'On')][string]$Reason,
    [Parameter(Mandatory, ParameterSetName = 'Off')][switch]$Off
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\VeeamAware.psm1') -Force
Initialize-VALog -Name 'maintenance'

switch ($PSCmdlet.ParameterSetName) {
    'On' {
        Set-VAMaintenance -Until ([datetimeoffset]::UtcNow.AddMinutes($Minutes)) -Reason $Reason | Out-Null
        Write-VALog "Maintenance mode on for $Minutes minutes$(if ($Reason) { " ($Reason)" })"
    }
    'Off' { Set-VAMaintenance -Off | Out-Null; Write-VALog 'Maintenance mode off' }
}

$h = (Read-VAState).health
$until = ConvertTo-VADate $h.maintenanceUntil
if ($until -and $until -gt [datetimeoffset]::UtcNow) {
    Write-Host "Maintenance mode is ON until $($until.ToLocalTime().ToString('yyyy-MM-dd HH:mm')) (local)$(if ($h.maintenanceReason) { ": $($h.maintenanceReason)" }). Health alerts are paused."
}
else { Write-Host 'Maintenance mode is off. Health alerts are active.' }
if ($h.upgradeSince) { Write-Host "A Veeam upgrade was detected at $((ConvertTo-VADate $h.upgradeSince).ToLocalTime().ToString('yyyy-MM-dd HH:mm')); health alerts are paused while it runs." }
