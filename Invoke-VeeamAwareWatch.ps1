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
  * server health: Veeam services stopped longer than firstAlertAfterMinutes, sessions that appear stuck, and the
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
Write-VAConfigWarnings
$w = $config.watch
if (-not $w.enabled) { Write-VALog 'Watcher disabled in config.'; return }

$now = [datetimeoffset]::UtcNow
try { $state = Read-VAState }
catch { Write-VALog "Watcher failed: $($_.Exception.Message)" -Level Error; exit 1 }
$firstRun = -not $state.lastWatchUtc
# Sessions are read from where the last successful read left off, with 15 minutes of overlap: a post-job worker
# may hold a claim for a few minutes while it retries a failing target, then release it for the watcher to pick
# up. notifiedSessions stops the overlap from sending anything twice. At most 7 days back.
$since = if ($firstRun) { $now.AddMinutes(-[int]$w.intervalMinutes) } else {
    $from = ConvertTo-VADate $(if ($state.sessionsSeenUtc) { $state.sessionsSeenUtc } else { $state.lastWatchUtc })
    $from = $from.AddMinutes(-15)
    if ($from -lt $now.AddDays(-7)) { $now.AddDays(-7) } else { $from }
}
$script:sent = 0
$hs = $w.health
$health = $state.health
$quiet = [pscustomobject]@{ Quiet = $false; Upgrading = $false; Reason = $null; Events = @() }
$servicesDown = $false

$flapSettings = Get-VAFlapSettings $config
$flaps = $state.flapping

$deliver = {
    param($e)
    if ("$(Get-VAProp $e.details 'check' '')" -eq 'flapping') { Write-VALog "Flapping: $($e.title)" -Level Warning }
    $script:sent += Send-VAEvent -Config $config -Event $e -WhatIf:$WhatIf
}

function Send-WatchEvent($Evt) {
    # Something that keeps going wrong and coming back gets one "flapping" card instead of every change.
    Send-VAFlapGated -Event $Evt -Flaps $flaps -Settings $flapSettings -Now $now -Send $deliver
}

function Send-FlapSettled {
    # Every pass, including failed ones and upgrades: a flap that ends broken often means VBR is unreachable too.
    if ($quiet.Quiet) { return }
    try { $null = Send-VAFlapSettled -Flaps $flaps -Settings $flapSettings -Now $now -Send $deliver }
    catch { Write-VALog "Flapping check failed: $($_.Exception.Message)" -Level Warning }
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
    Send-FlapSettled
    if (-not $WhatIf) {
        if ($hs.enabled) { Save-VAHealthState $health }
        Update-VAState { param($s) $s.flapping = $flaps } | Out-Null
    }
    Write-VALog "Watch pass complete: $script:sent delivery(ies) (upgrade in progress, VBR checks skipped)"
    return
}

try {
    # tools\Test-LiveAlerts.ps1 -Watcher creates this file to try the watcher-failure alert for real.
    $simulate = Resolve-VAPath 'state\test-watcher-failure'
    if (Test-Path -LiteralPath $simulate) { throw "Test failure (tools\Test-LiveAlerts.ps1 -Watcher). Run it with -Stop to end the test." }
    Connect-VASource -Config $config

    # ---- Sessions no hook reported (and, from the same list, sessions that appear stuck) ----------------
    $wantStuck = $hs.enabled -and $hs.sessions.enabled
    # An empty list comes back as $null just like a failed read, so whether the read worked is tracked apart.
    $sessions = @(); $listRead = @{ Ok = $false }
    if ($w.missedSessions -or $wantStuck) {
        $sessions = @(Test-VARestOptional -What 'recent sessions' { $list = @(Get-VASessions -EndedAfter $since); $listRead.Ok = $true; $list } | Where-Object { $_ })
    }
    if ($wantStuck -and $listRead.Ok) {
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
            if (@($state.notifiedSessions) -contains $id) { continue }   # cheap check first: the window overlaps
            if ($WhatIf) { if (Test-VASessionNotified $id) { continue } }
            elseif (-not (Add-VANotifiedSession $id)) { continue }   # the post-job worker already sent it
            try {
                $tasks = @(Test-VARestOptional -What 'task sessions' { Get-VATaskSessions $id } | Where-Object { $_ })
                $log = @(Test-VARestOptional -What 'session log' { Get-VASessionLog $id } | Where-Object { $_ })
                $summary = Add-VASessionContext -Summary (Get-VASessionSummary -Session $s -TaskSessions $tasks -Log $log)
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
            # The seen list is capped, so an event older than a day before the newest one already seen counts as
            # seen too; otherwise ids trimmed off the list would alert again on every run.
            $high = ConvertTo-VADate $state.malwareHighWaterUtc
            $when = { param($e) ConvertTo-VADate (Get-VAProp $e 'detectionTimeUtc' (Get-VAProp $e 'creationTime')) }
            $new = @($events | Where-Object {
                    $_ -and $_.id -and -not $seen.Contains("$($_.id)") -and -not ($high -and (& $when $_) -and (& $when $_) -lt $high.AddDays(-1))
                })
            $latest = @(@($events | ForEach-Object { & $when $_ }) + @($high) | Where-Object { $_ } | Sort-Object | Select-Object -Last 1)
            $done = [System.Collections.Generic.List[string]]::new()
            try {
                if ($firstRun) { Write-VALog "First run: recording $($new.Count) existing malware event(s) without sending"; $new | ForEach-Object { $done.Add("$($_.id)") } }
                else { foreach ($e in $new) { Send-WatchEvent (New-VAMalwareAlertEvent $e); $done.Add("$($e.id)") } }
            }
            finally {
                # Record what was sent even if a later one failed, so those don't go out again.
                if (-not $WhatIf -and ($done.Count -or $latest)) {
                    $ids = $done.ToArray(); $hw = if ($latest) { $latest[0].ToString('o') } else { $null }
                    Update-VAState { param($s) $s.seenMalwareEvents = @($s.seenMalwareEvents) + $ids; if ($hw) { $s.malwareHighWaterUtc = $hw } } | Out-Null
                }
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
                # No earlier result on record (it wasn't readable on the first pass): report what's open, not "new".
                $allOpen = -not "$($state.analyzerRunId)"
                if ($firstRun) { Write-VALog "First run: recording $($violations.Count) open analyzer finding(s) without sending" }
                elseif ($newV.Count -or $cleared) {
                    Send-WatchEvent (New-VAAnalyzerAlertEvent -NewViolations $newV -AllViolations $violations -LastRun $lastRun -AllOpen:$allOpen)
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
    Send-FlapSettled
    if (-not $WhatIf) {
        if ($hs.enabled) { Save-VAHealthState $health }
        # The session window only moves on once the session list was actually read, so a failed read is
        # covered by the next run instead of being skipped.
        $sessionsRead = $listRead.Ok -or -not ($w.missedSessions -or $wantStuck)
        Update-VAState { param($s) $s.lastWatchUtc = $now.ToString('o'); if ($sessionsRead) { $s.sessionsSeenUtc = $now.ToString('o') } } | Out-Null
        if (-not $sessionsRead) { Write-VALog 'Session list not read this run; the next run looks back further to cover it.' -Level Warning }
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
    if (-not $WhatIf) { Send-FlapSettled }
    exit 1
}
finally {
    Disconnect-VASource
    if (-not $WhatIf) {
        try { Update-VAState { param($s) $s.flapping = $flaps } | Out-Null }
        catch { Write-VALog "Could not save the flapping state: $($_.Exception.Message)" -Level Warning }
    }
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
