#Requires -Version 7.2
<#
.SYNOPSIS
Periodic watcher (the "VeeamAware Watch" scheduled task, every watch.intervalMinutes). It sends:

  * sessions routed "immediate"/"both" that no post-job hook reported: agent policies (which never run
    post-job scripts) and any job without the hook. With the hook attached reports arrive in seconds; without
    it, within one watch interval.
  * new malware detection events
  * repositories crossing the free-space warning/critical thresholds, going offline, or recovering
  * Security & Compliance Analyzer violations after each analyzer run (and "all clear" when they are gone)
  * pending four-eyes authorization requests
  * server health: Veeam services stopped longer than a grace period, sessions that appear stuck, and the
    watcher itself failing several runs in a row (quiet while Veeam upgrades or maintenance mode is on)

and then starts any digest whose schedule is due (Invoke-VeeamAwareDigest.ps1 -Scheduled).
The first run records what already exists without sending it, so installing VeeamAware does not flood targets.
#>
[CmdletBinding()]
param([string]$ConfigPath, [switch]$WhatIf)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\VeeamAware.psm1') -Force

$cfgArgs = @{}; if ($ConfigPath) { $cfgArgs.Path = $ConfigPath }
$config = Get-VAConfig @cfgArgs
Initialize-VALog -Name 'watch' -Level $config.logging.level -RetentionDays $config.logging.retentionDays
$w = $config.watch
if (-not $w.enabled) { Write-VALog 'Watcher disabled in config.'; return }

$now = [datetimeoffset]::UtcNow
$state = Read-VAState
$firstRun = -not $state.lastWatchUtc
$since = if ($firstRun) { $now.AddMinutes(-[int]$w.intervalMinutes) } else { (ConvertTo-VADate $state.lastWatchUtc).AddMinutes(-2) }
$script:sent = 0
$hs = $w.health
$health = $state.health
$quiet = [pscustomobject]@{ Quiet = $false; Upgrading = $false; Reason = $null; Events = @() }
$servicesDown = $false

function Send-WatchEvent($Evt) {
    $script:sent += Send-VAEvent -Config $config -Event $Evt -WhatIf:$WhatIf
}

function Send-HealthEvents([object[]]$Events, [string]$AlertedKey) {
    <# Sends health events; if none could be delivered, forgets the "alerted" marks so the next run retries. #>
    $before = if ($AlertedKey) { @($health[$AlertedKey]) } else { $null }
    try { foreach ($e in @($Events | Where-Object { $_ })) { Send-WatchEvent $e } }
    catch {
        Write-VALog "Health alert not delivered: $($_.Exception.Message)" -Level Warning
        if ($AlertedKey) { $health[$AlertedKey] = @($health[$AlertedKey] | Where-Object { $before -contains $_ }) }
    }
}

# ---- Health: services and upgrades, before connecting (VBR itself may be what is down) ------------------
if ($hs.enabled) {
    try {
        $services = if ($hs.services.enabled) { @(Get-VAServiceSnapshot $hs.services) } else { @() }
        $servicesDown = @($services | Where-Object { $_.Status -ne 'Running' }).Count -gt 0
        $quiet = Update-VAQuietState -Settings $hs -Signals (Get-VAUpgradeSignals $hs.upgrade) -Health $health -Now $now -ServicesDown $servicesDown
        if ($quiet.Quiet) { Write-VALog "Health alerts quiet: $($quiet.Reason)" }
        Send-HealthEvents $quiet.Events
        if ($hs.services.enabled) {
            $r = Update-VAServiceHealth -Settings $hs.services -Services $services -Health $health -Now $now -Quiet:$quiet.Quiet -Timing (Get-VAHealthTiming $hs 'services') -StopReason { param($svc, $since) Get-VAServiceStopReason -Service $svc -Since $since }
            if ($r.Down) { Write-VALog "Not running: $(($r.Down | ForEach-Object { "$($_.Name) ($($_.Status))" }) -join ', ')" -Level Warning }
            Send-HealthEvents $r.Events 'servicesAlerted'
        }
    }
    catch { Write-VALog "Health check failed: $($_.Exception.Message)" -Level Warning }
}

# While a Veeam installer is active, leave VBR alone: loading Veeam's PowerShell module would lock files the
# installer is replacing, and VBR is down anyway. Sessions, malware, repositories and digests catch up on the
# first run after (lastWatchUtc stays put, so nothing in between is missed).
if ($quiet.Upgrading) {
    Write-VALog 'Veeam upgrade in progress: skipping the VBR checks and digests this run'
    if ($hs.enabled -and -not $WhatIf) { Save-VAHealthState $health }
    Write-VALog "Watch pass complete: $script:sent delivery(ies) (upgrade in progress, VBR checks skipped)"
    return
}

try {
    Connect-VASource -Config $config

    # ---- Sessions no hook reported (and, from the same list, sessions that appear stuck) ----------------
    $wantStuck = $hs.enabled -and $hs.sessions.enabled
    $sessions = $null
    if ($w.missedSessions -or $wantStuck) { $sessions = Test-VARestOptional -What 'recent sessions' { Get-VASessions -EndedAfter $since } }
    if ($wantStuck -and $null -ne $sessions) {
        $typical = { param($s) if ("$($s.jobId)") { Get-VATypicalDuration -JobId "$($s.jobId)" } }
        $r = Update-VAStuckSessions -Settings $hs.sessions -Sessions @($sessions | Where-Object { Test-VAReportableSession $_ }) `
            -Health $health -Now $now -Quiet:$quiet.Quiet -TypicalDuration $typical -Timing (Get-VAHealthTiming $hs 'sessions')
        foreach ($e in $r.Events) { Write-VALog "Session appears stuck: $($e.details.jobName) ($($e.details.reason))" -Level Warning }
        Send-HealthEvents $r.Events 'stuckAlerted'
    }
    if ($w.missedSessions) {
        foreach ($s in @($sessions | Where-Object { Test-VAReportableSession $_ })) {
            $route = Get-VASessionRoute -Config $config -Session $s
            if ($route.Mode -notin 'immediate', 'both') { continue }
            # A hook worker still waiting for this session will claim it within seconds; leave fresh ones to it.
            $end = ConvertTo-VADate $s.endTime
            if ($end -and ($now - $end).TotalSeconds -lt 60) { continue }

            $id = "$($s.id)"
            if ($WhatIf) { if (Test-VASessionNotified $id) { continue } }
            elseif (-not (Add-VANotifiedSession $id)) { continue }   # the post-job worker already sent it
            try {
                $tasks = Test-VARestOptional -What 'task sessions' { Get-VATaskSessions $id }
                $log = Test-VARestOptional -What 'session log' { Get-VASessionLog $id }
                $summary = Add-VASessionContext -Summary (Get-VASessionSummary -Session $s -TaskSessions @($tasks) -Log @($log))
                Send-WatchEvent (New-VASessionEvent -Config $config -Summary $summary)
                Write-VALog "Session $id ($($s.name): $($summary.Result)) sent by the watcher (rule '$($route.Rule)')"
            }
            catch { if (-not $WhatIf) { Remove-VANotifiedSession $id }; throw }
        }
    }

    # ---- Malware events -------------------------------------------------------------------------------
    if ($w.malware) {
        $events = Test-VARestOptional -What 'malware events' { Get-VAMalwareEvents }
        if ($null -ne $events) {
            $seen = [System.Collections.Generic.HashSet[string]]::new([string[]]@($state.seenMalwareEvents))
            $new = @($events | Where-Object { $_ -and $_.id -and -not $seen.Contains("$($_.id)") })
            if ($firstRun) { Write-VALog "First run: recording $($new.Count) existing malware event(s) without sending" }
            else { foreach ($e in $new) { Send-WatchEvent (New-VAMalwareAlertEvent $e) } }
            if ($new -and -not $WhatIf) {
                $ids = @($new | ForEach-Object { "$($_.id)" })
                Update-VAState { param($s) $s.seenMalwareEvents = @($s.seenMalwareEvents) + $ids } | Out-Null
            }
        }
    }

    # ---- Repository capacity --------------------------------------------------------------------------
    if ($w.repositories.enabled) {
        $repos = Test-VARestOptional -What 'repository states' { Get-VARepositoryStates }
        if ($null -ne $repos) {
            $levels = @{}
            $rank = @{ ok = 0; warning = 1; critical = 2; offline = 3 }
            $seen = [System.Collections.Generic.List[object]]::new()
            foreach ($r in @($repos | Where-Object { $_ })) {
                $info = Get-VARepositoryInfo $r
                if (@($w.repositories.exclude | Where-Object { $_ -and $info.Name -like $_ })) { continue }
                $seen.Add($info)
                Add-VARepositoryTrendInfo -Infos @($info) -State $state
                $level = Get-VARepositoryLevel $info $w.repositories
                $prev = if ($state.repositoryLevels.Contains($info.Id)) { $state.repositoryLevels[$info.Id] } else { 'ok' }
                $levels[$info.Id] = $level
                $worse = $rank[$level] -gt $rank[$prev]
                $recovered = $level -eq 'ok' -and $prev -ne 'ok' -and $w.repositories.notifyRecovery
                if ($worse -or $recovered) {
                    Send-WatchEvent (New-VARepositoryAlertEvent -Info $info -Level $level -PreviousLevel $prev)
                    Write-VALog "Repository $($info.Name): $prev -> $level ($($info.PercentFree)% free)"
                }
            }
            if (-not $WhatIf) {
                Update-VAState { param($s) $s.repositoryLevels = $levels } | Out-Null
                Add-VARepositoryReadings -Infos $seen.ToArray()   # daily free-space history for the fill-up estimate
            }
        }
    }

    # ---- Security & Compliance Analyzer ---------------------------------------------------------------
    if ($w.securityAnalyzer) {
        $lastRun = Test-VARestOptional -What 'security analyzer last run' { Get-VAAnalyzerLastRun }
        $runId = "$(Get-VAProp $lastRun 'sessionId' (Get-VAProp $lastRun 'id' (Get-VAProp $lastRun 'endTime')))"
        if ($lastRun -and $runId -and $runId -ne "$($state.analyzerRunId)") {
            $practices = Test-VARestOptional -What 'security analyzer results' { Get-VAAnalyzerBestPractices }
            if ($null -ne $practices) {
                $violations = @($practices | Where-Object { "$(Get-VAProp $_ 'status')" -match 'Violation|Fail' })
                $key = { param($p) "$(Get-VAProp $p 'id' (Get-VAProp $p 'bestPractice'))" }
                $known = @($state.analyzerViolations)
                $newV = @($violations | Where-Object { $known -notcontains (& $key $_) })
                $cleared = $violations.Count -eq 0 -and $known.Count -gt 0
                if (-not $firstRun -and ($newV.Count -or $cleared)) {
                    Send-WatchEvent (New-VAAnalyzerAlertEvent -NewViolations $newV -AllViolations $violations -LastRun $lastRun)
                }
                if (-not $WhatIf) {
                    $ids = @($violations | ForEach-Object { & $key $_ })
                    Update-VAState { param($s) $s.analyzerRunId = $runId; $s.analyzerViolations = $ids } | Out-Null
                }
            }
        }
    }

    # ---- Four-eyes authorization requests -------------------------------------------------------------
    if ($w.authorizationRequests) {
        $auth = Test-VARestOptional -What 'authorization events' { Get-VAAuthorizationEvents }
        if ($null -ne $auth) {
            $seen = @($state.seenAuthEvents)
            $pending = @($auth | Where-Object { $_ -and $_.id -and $seen -notcontains "$($_.id)" -and "$(Get-VAProp $_ 'state')" -match 'Pending|Waiting|^$' })
            if (-not $firstRun) { foreach ($e in $pending) { Send-WatchEvent (New-VAAuthorizationAlertEvent $e) } }
            if ($pending -and -not $WhatIf) {
                $ids = @($pending | ForEach-Object { "$($_.id)" })
                Update-VAState { param($s) $s.seenAuthEvents = @($s.seenAuthEvents) + $ids } | Out-Null
            }
        }
    }

    if ($hs.enabled) { Send-HealthEvents (Update-VAWatcherHealth -Settings $hs.watcher -Health $health -Now $now -Timing (Get-VAHealthTiming $hs 'watcher')).Events }
    if (-not $WhatIf) {
        if ($hs.enabled) { Save-VAHealthState $health }
        Update-VAState { param($s) $s.lastWatchUtc = $now.ToString('o') } | Out-Null
    }
    Write-VALog "Watch pass complete: $script:sent delivery(ies)$(if ($firstRun) { ' (first run baseline)' })"
}
catch {
    $err = $_
    Write-VALog "Watcher failed: $($err.Exception.Message)" -Level Error
    Write-VALog $err.ScriptStackTrace -Level Debug
    if ($hs.enabled -and -not $WhatIf) {
        # Not counted while Veeam upgrades or its services are down: the service alert already covers that.
        try {
            $r = Update-VAWatcherHealth -Settings $hs.watcher -Health $health -Now $now -Failed -ErrorMessage $err.Exception.Message -Quiet:($quiet.Quiet -or $servicesDown) -Timing (Get-VAHealthTiming $hs 'watcher') -LastGood $state.lastWatchUtc
            Send-HealthEvents $r.Events
            if ($r.Events) { Write-VALog "Watcher has failed $($health.watchFailures) runs in a row; alert sent" -Level Warning }
            Save-VAHealthState $health
        }
        catch { Write-VALog "Could not record the watcher failure: $($_.Exception.Message)" -Level Warning }
    }
    exit 1
}
finally {
    Disconnect-VASource
}

# ---- Digests: a separate process, only when one is due or still needs its first baseline -----------------
if (-not $WhatIf) {
    $state = Read-VAState
    $pending = @(Get-VADigests $config | Where-Object {
            $d = Get-VADigestDue -Digest $_ -LastRun $state.digests["$($_.name)"] -Now ([datetimeoffset]::UtcNow)
            $d.Due -or $d.Baseline
        })
    if ($pending) {
        $digestArgs = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'Invoke-VeeamAwareDigest.ps1'), '-Scheduled')
        if ($ConfigPath) { $digestArgs += @('-ConfigPath', $ConfigPath) }
        & (Join-Path $PSHOME 'pwsh.exe') @digestArgs
        if ($LASTEXITCODE) { Write-VALog "Digest run exited with $LASTEXITCODE (see the digest log)" -Level Warning }
    }
}
