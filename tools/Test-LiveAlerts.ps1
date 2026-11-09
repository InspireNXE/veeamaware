#Requires -Version 7.2
<#
.SYNOPSIS
Tries the stuck-job and watcher-failure alerts for real on the VBR server, then puts everything back.

.DESCRIPTION
Send-HealthPreview.ps1 shows what every health card looks like with made-up data. This makes the real
conditions happen, so the whole path is tested: the watcher notices, waits as configured, sends, and recovers.

-Stuck <job>  Gives that job a 3-minute run-time limit (watch.health.sessions.jobs). Start the job in VBR; within
              a watch interval or two after 3 minutes you get "appears stuck". Saves config.json first.
-Watcher      Makes every watcher run fail with a clear test error. After watch.health.watcher.failureAlertAfter
              runs in a row (3 by default, so about 15 minutes) you get the watcher alert.
-Stop         Ends both tests: restores config.json and lets the watcher run again. The next good run sends
              "watcher recovered".
-Status       Shows which tests are on.

.EXAMPLE
pwsh -File .\tools\Test-LiveAlerts.ps1 -Stuck 'Daily Backup'
pwsh -File .\tools\Test-LiveAlerts.ps1 -Watcher
pwsh -File .\tools\Test-LiveAlerts.ps1 -Stop
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'Run')][string]$Stuck,
    [Parameter(ParameterSetName = 'Run')][switch]$Watcher,
    [Parameter(ParameterSetName = 'Stop')][switch]$Stop,
    [Parameter(ParameterSetName = 'Status')][switch]$Status,
    [string]$ConfigPath
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\VeeamAware.psm1') -Force

$cfgPath = if ($ConfigPath) { $ConfigPath } else { Resolve-VAPath 'config\config.json' }
$backup = "$cfgPath.before-live-test"
$flag = Resolve-VAPath 'state\test-watcher-failure'

function Show-Status {
    Write-Host "Config changes:   $(if (Test-Path -LiteralPath $backup) { 'yes (-Stop restores config.json)' } else { 'none' })"
    Write-Host "Watcher test:     $(if (Test-Path -LiteralPath $flag) { 'on (every watcher run fails)' } else { 'off' })"
}

if ($Stop) {
    if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $cfgPath -Force; Write-Host 'Restored config.json.' }
    if (Test-Path -LiteralPath $flag) { Remove-Item -LiteralPath $flag -Force; Write-Host 'The watcher runs normally again; its next run sends "recovered" if the alert went out.' }
    Show-Status; return
}
if (-not $Stuck -and -not $Watcher) { Show-Status; return }

# Both tests need the watcher and health alerts switched on; config.json is saved first and -Stop restores it.
if (-not (Test-Path -LiteralPath $cfgPath)) { throw "No config at $cfgPath. Run Install-VeeamAware.ps1 first." }
if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $cfgPath -Destination $backup }
$json = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
foreach ($k in 'watch.enabled', 'watch.health.enabled') {
    if (-not (Get-VASetupValue $json $k $true)) { Set-VASetupValue $json $k $true; Write-Host "Turned on $k for the test." }
}
if ($Watcher -and [int](Get-VASetupValue $json 'watch.health.watcher.failureAlertAfter' 3) -le 0) {
    Set-VASetupValue $json 'watch.health.watcher.failureAlertAfter' 3; Write-Host 'Turned on watcher failure alerts (after 3 runs) for the test.'
}
$json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath -Encoding utf8NoBOM

if ($Stuck) {
    $json = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
    Set-VASetupValue $json 'watch.health.sessions.enabled' $true
    Set-VASetupValue $json 'watch.health.sessions.minHours' 0
    Set-VASetupValue $json 'watch.health.sessions.jobs' @([pscustomobject]@{ job = $Stuck; hours = 0.05 })
    Set-VASetupValue $json 'watch.health.sessions.excludeJobs' @()
    $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath -Encoding utf8NoBOM
    Write-Host "Stuck-job test on: '$Stuck' now counts as stuck after 3 minutes."
    Write-Host 'Start the job in VBR. The alert arrives on the first watcher run after 3 minutes (the watcher runs every few minutes).'
}
if ($Watcher) {
    New-Item -ItemType File -Path $flag -Force | Out-Null
    $n = [int](Get-VAProp (Get-VAConfig -Path $cfgPath -AllowNoTargets) 'watch.health.watcher.failureAlertAfter' 3)
    Write-Host "Watcher test on: every watcher run fails. The alert goes out after $n failed run(s) in a row."
}
Write-Host ''
Write-Host 'When done:  pwsh -File .\tools\Test-LiveAlerts.ps1 -Stop' -ForegroundColor Cyan
