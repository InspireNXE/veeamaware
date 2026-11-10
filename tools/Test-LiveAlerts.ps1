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
# The settings the test changed and what they were, so -Stop puts back just those and keeps any other edit.
$saved = "$cfgPath.live-test.json"
$oldBackup = "$cfgPath.before-live-test"   # whole-file copy made by 0.1.2 and earlier
$flag = Resolve-VAPath 'state\test-watcher-failure'

function Get-RawSetting($Json, [string]$Path) {
    $o = $Json
    foreach ($p in $Path.Split('.')) {
        if ($o -isnot [System.Management.Automation.PSCustomObject] -or -not $o.PSObject.Properties[$p]) { return @{ had = $false; value = $null } }
        $o = $o.$p
    }
    @{ had = $true; value = $o }
}

function Remove-RawSetting($Json, [string]$Path) {
    $parts = $Path.Split('.'); $o = $Json
    foreach ($p in $parts[0..($parts.Count - 2)]) {
        if ($o -isnot [System.Management.Automation.PSCustomObject] -or -not $o.PSObject.Properties[$p]) { return }
        $o = $o.$p
    }
    if ($o -is [System.Management.Automation.PSCustomObject]) { $o.PSObject.Properties.Remove($parts[-1]) }
}

function Show-Status {
    $changed = (Test-Path -LiteralPath $saved) -or (Test-Path -LiteralPath $oldBackup)
    Write-Host "Config changes:   $(if ($changed) { 'yes (-Stop puts the changed settings back)' } else { 'none' })"
    Write-Host "Watcher test:     $(if (Test-Path -LiteralPath $flag) { 'on (every watcher run fails)' } else { 'off' })"
}

if ($Stop) {
    if (Test-Path -LiteralPath $saved) {
        $json = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
        $orig = Get-Content -Raw -LiteralPath $saved | ConvertFrom-Json
        foreach ($p in $orig.PSObject.Properties) {
            if ($p.Value.had) { Set-VASetupValue $json $p.Name $p.Value.value } else { Remove-RawSetting $json $p.Name }
        }
        $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath -Encoding utf8NoBOM
        Remove-Item -LiteralPath $saved -Force
        Write-Host "Put back $(@($orig.PSObject.Properties).Count) setting(s) in config.json."
    }
    elseif (Test-Path -LiteralPath $oldBackup) { Move-Item -LiteralPath $oldBackup -Destination $cfgPath -Force; Write-Host 'Restored config.json.' }
    if (Test-Path -LiteralPath $flag) { Remove-Item -LiteralPath $flag -Force; Write-Host 'The watcher runs normally again; its next run sends "recovered" if the alert went out.' }
    Show-Status; return
}
if (-not $Stuck -and -not $Watcher) { Show-Status; return }

# Both tests need the watcher and health alerts switched on. Each setting's first value is kept for -Stop.
if (-not (Test-Path -LiteralPath $cfgPath)) { throw "No config at $cfgPath. Run Install-VeeamAware.ps1 first." }
$json = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
$orig = [ordered]@{}
if (Test-Path -LiteralPath $saved) { foreach ($p in (Get-Content -Raw -LiteralPath $saved | ConvertFrom-Json).PSObject.Properties) { $orig[$p.Name] = $p.Value } }
$change = {
    param([string]$Path, $Value)
    if (-not $orig.Contains($Path)) { $orig[$Path] = Get-RawSetting $json $Path }
    Set-VASetupValue $json $Path $Value
}
foreach ($k in 'watch.enabled', 'watch.health.enabled') {
    if (-not (Get-VASetupValue $json $k $true)) { & $change $k $true; Write-Host "Turned on $k for the test." }
}
if ($Watcher -and [int](Get-VASetupValue $json 'watch.health.watcher.failureAlertAfter' 3) -le 0) {
    & $change 'watch.health.watcher.failureAlertAfter' 3; Write-Host 'Turned on watcher failure alerts (after 3 runs) for the test.'
}
if ($Stuck) {
    # A sessions.jobs rule's hours apply as given (minHours doesn't raise them), so only this job is affected.
    & $change 'watch.health.sessions.enabled' $true
    $rules = @(@(Get-VASetupValue $json 'watch.health.sessions.jobs' @()) | Where-Object { $_ -and "$(Get-VAProp $_ 'job' '')" -ne $Stuck })
    & $change 'watch.health.sessions.jobs' @(@([pscustomobject]@{ job = $Stuck; hours = 0.05 }) + $rules)
    $excl = @(Get-VASetupValue $json 'watch.health.sessions.excludeJobs' @())
    if (@($excl | Where-Object { $Stuck -like $_ })) { & $change 'watch.health.sessions.excludeJobs' @($excl | Where-Object { $Stuck -notlike $_ }) }
}
$orig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $saved -Encoding utf8NoBOM
$json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath -Encoding utf8NoBOM

if ($Stuck) {
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
