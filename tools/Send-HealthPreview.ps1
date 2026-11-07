#Requires -Version 7.2
<#
.SYNOPSIS
Sends sample server-health cards to your targets so you can see how they look without stopping services or
waiting for the alert timers. Reads nothing from VBR and never changes state.json.

.EXAMPLE
pwsh -File .\tools\Send-HealthPreview.ps1                          # every card, every target
pwsh -File .\tools\Send-HealthPreview.ps1 -Card down, recovered    # just these
pwsh -File .\tools\Send-HealthPreview.ps1 -Target discord          # one target
pwsh -File .\tools\Send-HealthPreview.ps1 -WhatIf                  # build only, log the payloads
#>
[CmdletBinding()]
param(
    [ValidateSet('down', 'downMany', 'reminder', 'recovered', 'stuck', 'watcher', 'watcherRecovered', 'updated')]
    [string[]]$Card = @('down', 'downMany', 'reminder', 'recovered', 'stuck', 'watcher', 'watcherRecovered', 'updated'),
    [string[]]$Target, [string]$ConfigPath, [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\VeeamAware.psm1') -Force
$cfgArgs = @{}; if ($ConfigPath) { $cfgArgs.Path = $ConfigPath }
$config = Get-VAConfig @cfgArgs
Initialize-VALog -Name 'preview' -Level $config.logging.level -RetentionDays $config.logging.retentionDays

$now = [datetimeoffset]::UtcNow
$iso = { param($minutesAgo) $now.AddMinutes(-$minutesAgo).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
$svc = { param($n, $d, $st = 'Stopped') [pscustomobject]@{ Name = $n; DisplayName = $d; Status = $st; StartType = 'Automatic' } }
$p9 = & $svc 'VeeamPl9Svc' 'Veeam Platform9 Service'
$mount = & $svc 'VeeamMountSvc' 'Veeam Mount Service'
$reason = [pscustomobject]@{ Text = 'The Veeam Platform9 Service service terminated unexpectedly. It has done this 1 time(s). (sample)' }

$build = @{
    down             = { New-VAServiceAlertEvent -Down @($p9) -New @($p9) -Since @{ VeeamPl9Svc = & $iso 17 } -Reasons @{ VeeamPl9Svc = $reason } -Services @($p9) -Now $now }
    downMany         = { New-VAServiceAlertEvent -Down @($p9, $mount) -New @($mount) -Since @{ VeeamPl9Svc = & $iso 40; VeeamMountSvc = & $iso 16 } -Reasons @{ VeeamPl9Svc = $reason } -Services @($p9, $mount) -Now $now }
    reminder         = { New-VAServiceAlertEvent -Down @($p9) -Since @{ VeeamPl9Svc = & $iso 135 } -Reminder 2 -Services @($p9) -Now $now }
    recovered        = { New-VAServiceAlertEvent -Recovered @('VeeamPl9Svc') -Services @($p9) -OutageSince (& $iso 95) -Now $now }
    stuck            = {
        $s = [pscustomobject]@{ id = [guid]::NewGuid().ToString(); jobId = [guid]::NewGuid().ToString(); name = 'Sample Backup Job (preview)'
            sessionType = 'BackupJob'; state = 'Working'; creationTime = & $iso 410
            progress = [pscustomobject]@{ progressPercent = 37; processedSize = 412316860416 } }
        New-VAStuckSessionEvent -Session $s -Reason 'stalled' -Elapsed ([timespan]::FromMinutes(410)) -LimitHours 6 -Typical ([timespan]::FromMinutes(95)) -Stalled ([timespan]::FromMinutes(250))
    }
    watcher          = { New-VAWatcherAlertEvent -Failures 3 -Since (& $iso 15) -LastError 'Cannot connect to the local Veeam backup server (sample)' -LastGood (& $iso 20) -Now $now }
    watcherRecovered = { New-VAWatcherAlertEvent -Recovered -Failures 4 -Since (& $iso 25) -Now $now }
    updated          = { New-VAVersionChangeEvent -From '13.1.0.411' -To '13.1.1.000' }
}

$sent = 0
foreach ($c in $Card) {
    $evt = & $build[$c]
    $evt.title = "[Preview] $($evt.title)"
    $n = Send-VAEvent -Config $config -Event $evt -OnlyTargets $Target -WhatIf:$WhatIf
    Write-Host ("{0,-17} -> {1} target(s)" -f $c, $n)
    $sent += $n
}
Write-Host "Done: $sent delivery(ies)$(if ($WhatIf) { ' (WhatIf: nothing sent)' })"
