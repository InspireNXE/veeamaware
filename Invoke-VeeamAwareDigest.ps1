#Requires -Version 7.2
<#
.SYNOPSIS
Builds and sends digests: roll-ups of the sessions since the previous digest, with per-machine detail for
Veeam Agent jobs/policies, repository capacity and security events. Each digest in config "digests" has its
own schedule, job filter, sections and targets.

.DESCRIPTION
The watcher task runs this with -Scheduled whenever a digest is due, so there is no separate digest task and
schedule changes take effect without re-running the installer. By hand:

    pwsh -File .\Invoke-VeeamAwareDigest.ps1 -WhatIf                 # preview every enabled digest
    pwsh -File .\Invoke-VeeamAwareDigest.ps1 -Name weekly -WhatIf    # preview one
    pwsh -File .\Invoke-VeeamAwareDigest.ps1 -Name daily -Hours 72   # custom window (keeps the schedule marker)
    pwsh -File .\Invoke-VeeamAwareDigest.ps1 -Name daily -Hours 24 -Target teams   # send to one target only
#>
[CmdletBinding()]
param([string]$ConfigPath, [string[]]$Name, [int]$Hours, [string[]]$Target, [switch]$Scheduled, [switch]$WhatIf)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\VeeamAware.psm1') -Force

$cfgArgs = @{}; if ($ConfigPath) { $cfgArgs.Path = $ConfigPath }
$config = Get-VAConfig @cfgArgs
Initialize-VALog -Name 'digest' -Level $config.logging.level -RetentionDays $config.logging.retentionDays

$now = [datetimeoffset]::UtcNow
$state = Read-VAState
$digests = @(Get-VADigests $config -IncludeDisabled:([bool]$Name) | Where-Object { -not $Name -or $Name -contains "$($_.name)" })
if ($Name -and $digests.Count -ne @($Name).Count) {
    $known = @(Get-VADigests $config -IncludeDisabled | ForEach-Object { "$($_.name)" }) -join ', '
    throw "Unknown digest name(s): $(@($Name | Where-Object { $_ -notin @($digests | ForEach-Object { "$($_.name)" }) }) -join ', '). Configured: $known"
}

# Work out each digest's window. Scheduled runs follow the schedule; manual runs cover the time since the
# digest last ran (or one period), or -Hours.
$runs = foreach ($d in $digests) {
    $n = "$($d.name)"
    $last = $state.digests[$n]
    if ($Scheduled) {
        $due = Get-VADigestDue -Digest $d -LastRun $last -Now $now
        if ($due.Baseline) {
            Write-VALog "Digest '$n': first run, recording the baseline (next digest covers the time from now)"
            if (-not $WhatIf) { Set-VADigestLastRun -Name $n -At $now }
            continue
        }
        if (-not $due.Due) { continue }
        @{ Digest = $d; Name = $n; From = $due.From; To = $now }
    }
    else {
        $from = if ($Hours) { $now.AddHours(-$Hours) } elseif (ConvertTo-VADate $last) { ConvertTo-VADate $last } else { $now - (Get-VADigestPeriod $d) }
        @{ Digest = $d; Name = $n; From = $from; To = $now }
    }
}
$runs = @($runs)
if (-not $runs) { Write-VALog 'No digest due.' -Level Debug; return }

$failed = 0
try {
    # Phase timings go to the log, so a slow digest shows where the time went.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lap = { param($what) Write-VALog ('Timing: {0} {1:N1}s' -f $what, $sw.Elapsed.TotalSeconds); $sw.Restart() }
    Connect-VASource -Config $config
    & $lap 'connect'

    # Read everything once for all digests in this run.
    # The job table shows each job's last 7 days, so read at least that far back.
    $historyDays = 7
    $earliest = @(@($runs | ForEach-Object From) + @($runs | ForEach-Object { $_.To.AddDays(-$historyDays) }) | Sort-Object)[0]
    $detailFrom = @($runs | ForEach-Object From | Sort-Object)[0]
    $allSessions = @(Get-VASessions -EndedAfter $earliest -DetailAfter $detailFrom |Where-Object { Test-VAReportableSession $_ })
    & $lap "sessions ($($allSessions.Count) since $($earliest.ToString('u')), $(@($allSessions | Where-Object { $_.PSObject.Properties['thin'] }).Count) history-only)"
    $wantsSection = { param($d, $s) @(Get-VAProp $d 'sections' @('agents', 'jobs', 'repositories', 'security')) -contains $s }
    $needRepos = @($runs | Where-Object { & $wantsSection $_.Digest 'repositories' }).Count -gt 0
    $needSecurity = @($runs | Where-Object { & $wantsSection $_.Digest 'security' }).Count -gt 0

    $repos = @()
    if ($needRepos) {
        $raw = Test-VARestOptional -What 'repository states' { Get-VARepositoryStates }
        $repos = @($raw | Where-Object { $_ } | ForEach-Object { Get-VARepositoryInfo $_ } |
                Where-Object { $rn = $_.Name; -not @($config.watch.repositories.exclude | Where-Object { $_ -and $rn -like $_ }) })
        if (-not $WhatIf) { Add-VARepositoryReadings -Infos $repos }
        Add-VARepositoryTrendInfo -Infos $repos
        & $lap "repositories ($($repos.Count))"
    }
    $malwareAll = @(); $violations = -1
    if ($needSecurity) {
        $malwareAll = @(Test-VARestOptional -What 'malware events' { Get-VAMalwareEvents }) | Where-Object { $_ }
        $practices = Test-VARestOptional -What 'security analyzer results' { Get-VAAnalyzerBestPractices }
        if ($null -ne $practices) { $violations = @($practices | Where-Object { "$(Get-VAProp $_ 'status')" -match 'Violation|Fail' }).Count }
        & $lap 'security'
    }
    $taskCache = @{}
    $updateNote = $null

    foreach ($run in $runs) {
        $d = $run.Digest
        try {
            Write-VALog "Building digest '$($run.Name)' for $($run.From.ToString('u')) .. $($run.To.ToString('u'))"
            $sessions = @($allSessions | Where-Object {
                    $end = ConvertTo-VADate $_.endTime
                    $end -and $end -ge $run.From -and $end -le $run.To -and
                    (Test-VADigestWantsSession -Digest $d -Session $_ -Route (Get-VASessionRoute -Config $config -Session $_))
                })
            $historySessions = @($allSessions | Where-Object {
                    $end = ConvertTo-VADate $_.endTime
                    $end -and $end -ge $run.To.AddDays(-$historyDays) -and $end -le $run.To -and (Test-VADigestWantsSession -Digest $d -Session $_ -Route (Get-VASessionRoute -Config $config -Session $_)) -and
                    (& $wantsSection $d $(if (Test-VAAgentSession $_) { 'agents' } else { 'jobs' }))
                })
            $agentSessions = @($sessions | Where-Object { Test-VAAgentSession $_ })
            $otherSessions = @($sessions | Where-Object { -not (Test-VAAgentSession $_) })
            $agentSummaries = @()
            if (& $wantsSection $d 'agents') {
                $agentSummaries = @(foreach ($s in $agentSessions) {
                        $id = "$($s.id)"
                        if (-not $taskCache.ContainsKey($id)) { $taskCache[$id] = @(Test-VARestOptional -What "task sessions of $id" { Get-VATaskSessions $id }) }
                        Get-VASessionSummary -Session $s -TaskSessions $taskCache[$id]
                    })
                & $lap "agent task sessions ($($agentSessions.Count))"
            }
            $malware = @(); $dv = -1
            if (& $wantsSection $d 'security') {
                $malware = @($malwareAll | Where-Object {
                        ($t = ConvertTo-VADate (Get-VAProp $_ 'detectionTimeUtc' (Get-VAProp $_ 'creationTime'))) -and $t -ge $run.From -and $t -le $run.To
                    })
                $dv = $violations
            }
            $shownOther = if (& $wantsSection $d 'jobs') { $otherSessions } else { @() }
            if ((Get-VAProp $d 'skipWhenEmpty' $false) -and -not ($agentSummaries.Count + $shownOther.Count + $malware.Count)) {
                Write-VALog "Digest '$($run.Name)': nothing to report, skipped (skipWhenEmpty)"
            }
            else {
                $report = New-VADigestReport -Config $config -Digest $d -From $run.From -To $run.To -AgentSummaries $agentSummaries `
                    -OtherSessions $shownOther -Repositories $(if (& $wantsSection $d 'repositories') { $repos } else { @() }) `
                    -MalwareEvents $malware -AnalyzerViolations $dv -HistorySessions $historySessions -HistoryDays $historyDays `
                    -PreviousAnalyzerViolations $(if ($state.digestAnalyzer.Contains($run.Name)) { [int]$state.digestAnalyzer[$run.Name] } else { -1 })
                if ($null -eq $updateNote) {
                    # Once per run; Get-VAUpdateInfo caches GitHub's answer for 12 hours and never throws.
                    $updateNote = ''
                    if ((Get-VAUpdateSettings $config).Notify) {
                        $u = Get-VAUpdateInfo -Config $config
                        if ($u.Available) { $updateNote = "⬆️ VeeamAware $($u.Latest) is available$(if ($u.Prerelease) { ' (preview)' }) · run Update-VeeamAware.ps1" }
                        elseif ($u.Error) { Write-VALog "Update check: $($u.Error)" -Level Debug }
                    }
                }
                if ($updateNote) { $report['note'] = if ($report['note']) { "$($report['note'])`n$updateNote" } else { $updateNote } }
                # Services down, watcher failing or maintenance on: one line each (nothing when all is well).
                $healthNote = Get-VAHealthNote -State $state -IntervalMinutes $config.watch.intervalMinutes
                if ($healthNote) { $report['note'] = if ($report['note']) { "$healthNote`n$($report['note'])" } else { $healthNote } }
                & $lap 'report build'
                $all = @($agentSummaries | ForEach-Object Result) + @($shownOther | ForEach-Object { "$(Get-VAProp $_ 'result.result')" })
                $counts = @{
                    total   = $all.Count
                    success = @($all | Where-Object { $_ -match '^Success' }).Count
                    warning = @($all | Where-Object { $_ -match '^Warning' }).Count
                    failed  = @($all | Where-Object { $_ -match '^Fail' }).Count
                    malware = $malware.Count; analyzerViolations = $dv
                }
                # -Target (manual runs) sends to those targets instead of the digest's own list.
                $targets = if ($Target) { @(Get-VATargets $config | ForEach-Object { "$($_.name)" } | Where-Object { $Target -contains $_ }) } else { @(Resolve-VADigestTargets -Config $config -Digest $d) }
                if (-not $targets) { Write-VALog "Digest '$($run.Name)' has no matching targets; nothing sent." -Level Warning }
                else {
                    $evt = New-VADigestEvent -Name $run.Name -Report $report -From $run.From -To $run.To -Counts $counts
                    $sent = Send-VAEvent -Config $config -Event $evt -OnlyTargets $targets -WhatIf:$WhatIf
                    & $lap 'send'
                    Write-VALog "Digest '$($run.Name)' sent to $sent target(s): $($counts.total) session(s), $($agentSummaries.Count) agent session(s)"
                }
            }
            if (-not $WhatIf -and -not $Hours -and -not $Target) {   # test runs leave the schedule alone
                Set-VADigestLastRun -Name $run.Name -At $run.To
                if ($dv -ge 0) { Update-VAState { param($s) $s.digestAnalyzer[$run.Name] = $dv } | Out-Null }
            }
        }
        catch {
            $failed++
            Write-VALog "Digest '$($run.Name)' failed: $($_.Exception.Message)" -Level Error
            Write-VALog $_.ScriptStackTrace -Level Debug
        }
    }
}
catch {
    Write-VALog "Digest run failed: $($_.Exception.Message)" -Level Error
    Write-VALog $_.ScriptStackTrace -Level Debug
    exit 1
}
finally {
    Disconnect-VASource
}
if ($failed) { exit 1 }
