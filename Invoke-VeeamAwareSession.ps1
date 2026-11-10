#Requires -Version 7.2
<#
.SYNOPSIS
Waits for a VBR job session to finish, then sends its report to every interested target.

.DESCRIPTION
Started by VeeamAware.ps1 (the post-job hook). It can also be run by hand to re-send or preview a session:

    pwsh -File .\Invoke-VeeamAwareSession.ps1 -SessionId <guid> -WhatIf    # print each target's payload, send nothing
    pwsh -File .\Invoke-VeeamAwareSession.ps1 -JobId <guid> -Force         # re-send the job's latest session
    pwsh -File .\Invoke-VeeamAwareSession.ps1 -JobId <guid> -Target hook -Force

What happens to the session follows config "routing": immediate / both send now; digest marks it deferred
(only targets with includeDeferred get it now, everyone sees it in the digest); off sends nothing.
-Force sends now whatever the route says.
#>
[CmdletBinding()]
param(
    [string]$JobId,
    [string]$SessionId,
    [string]$ConfigPath,
    [string[]]$Target,
    [switch]$WhatIf,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\VeeamAware.psm1') -Force

$cfgArgs = @{}; if ($ConfigPath) { $cfgArgs.Path = $ConfigPath }
$config = Get-VAConfig @cfgArgs
Initialize-VALog -Name 'session' -Level $config.logging.level -RetentionDays $config.logging.retentionDays
Write-VAConfigWarnings
Write-VALog "Worker started: job=$JobId session=$SessionId whatIf=$WhatIf"

try {
    Connect-VASource -Config $config

    # Resolve the session: prefer the explicit ID, fall back to the job's latest session.
    $session = $null
    if ($SessionId) {
        try { $session = Get-VASession $SessionId }
        catch { Write-VALog "Session $SessionId not found ($($_.Exception.Message)); falling back to job lookup" -Level Warning }
        # The hook passes both IDs; a session of another job means the ID was wrong, so ask the job instead.
        $sj = "$(Get-VAProp $session 'jobId' '')"
        if ($session -and $JobId -and $sj -and $sj -ne $JobId) {
            Write-VALog "Session $SessionId belongs to job $sj, not $JobId; falling back to job lookup" -Level Warning
            $session = $null
        }
    }
    if (-not $session -and $JobId) {
        # The hook can start before VBR has the session listed as the latest; give it a moment.
        for ($i = 0; $i -lt 6 -and -not $session; $i++) {
            # A preview (-WhatIf) does not wait, so it reports the latest *finished* session instead of a running one.
            $session = Get-VALatestJobSession $JobId -Completed:$WhatIf
            if (-not $session) { Start-Sleep -Seconds 5 }
        }
    }
    if (-not $session) { throw "Could not find a session for job '$JobId' / session '$SessionId'." }
    $SessionId = "$($session.id)"

    # Wait for VBR to close the session (it stays open until this post-job script's parent returns).
    $deadline = (Get-Date).AddMinutes([int]$config.notifications.sessionWaitMinutes)
    while ("$($session.state)" -ne 'Stopped' -and -not $WhatIf) {
        if ((Get-Date) -gt $deadline) { throw "Session $SessionId still '$($session.state)' after $($config.notifications.sessionWaitMinutes) minutes; giving up." }
        Start-Sleep -Seconds 15
        $session = Get-VASession $SessionId
    }
    $result = "$(Get-VAProp $session 'result.result' 'None')"
    if ($WhatIf -and ("$($session.state)" -ne 'Stopped' -or -not $session.endTime)) {
        Write-VALog "Note: session $($session.id) has not finished yet (state '$($session.state)'); the preview shows it as it is now." -Level Warning
    }
    Write-VALog "Session '$($session.name)' ($($session.sessionType)) started $($session.creationTime): $result"

    $route = Get-VASessionRoute -Config $config -Session $session
    Write-VALog "Routing: $($route.Mode) (rule '$($route.Rule)')"
    if ($route.Mode -eq 'off' -and -not $Force) { Write-VALog 'Routed off; nothing sent.'; return }
    $deferred = $route.Mode -eq 'digest'

    # Claim the session so the watcher does not send it again (and a re-run of the hook does not duplicate it).
    if (-not $WhatIf) {
        if (-not $Force -and -not (Add-VANotifiedSession $SessionId)) { Write-VALog 'Session already notified; nothing sent.'; return }
        if ($Force) { Add-VANotifiedSession $SessionId | Out-Null }
    }

    try {
        $tasks = @(Test-VARestOptional -What 'task sessions' { Get-VATaskSessions $SessionId } | Where-Object { $_ })
        $log = @(Test-VARestOptional -What 'session log' { Get-VASessionLog $SessionId } | Where-Object { $_ })
        $summary = Get-VASessionSummary -Session $session -TaskSessions $tasks -Log $log
        # Job history / repository space for the report; skipped when it only goes to the digest.
        if (-not ($deferred -and -not $Force)) { $summary = Add-VASessionContext -Summary $summary }
        $evt = New-VASessionEvent -Config $config -Summary $summary -Deferred:($deferred -and -not $Force)
        $sent = Send-VAEvent -Config $config -Event $evt -OnlyTargets $Target -WhatIf:$WhatIf
        Write-VALog "Session $SessionId delivered to $sent target(s)$(if ($deferred -and -not $Force) { ' (routed to the digest)' })"
    }
    catch {
        $err = $_
        # Release the claim so the watcher sends it instead; a failed release would leave it unsent for good.
        if (-not $WhatIf) {
            for ($i = 1; $i -le 3; $i++) {
                try { Remove-VANotifiedSession $SessionId; break }
                catch {
                    if ($i -eq 3) { Write-VALog "Could not release session $SessionId for the watcher: $($_.Exception.Message)" -Level Error }
                    else { Start-Sleep -Seconds 2 }
                }
            }
        }
        throw $err
    }

    # The watcher cannot report its own scheduled task not running; the hook still runs, so it checks.
    if (-not $WhatIf) {
        try {
            # Check and mark in one step under the state lock, so several jobs ending together send it once.
            $at = [datetimeoffset]::UtcNow.ToString('o')
            $claim = Update-VAState {
                param($s)
                $e = Get-VAWatcherStaleEvent -Config $config -State $s
                if ($e) { $prev = $s.health.staleAlertedAt; $s.health.staleAlertedAt = $at; @{ Event = $e; Prev = $prev; Last = $s.lastWatchUtc } }
            }
            if ($claim) {
                Write-VALog "Watcher has not run since $($claim.Last); sending a health alert" -Level Warning
                try { Send-VAEvent -Config $config -Event $claim.Event | Out-Null }
                catch { $p = $claim.Prev; Update-VAState { param($s) $s.health.staleAlertedAt = $p } | Out-Null; throw }
            }
        }
        catch { Write-VALog "Watcher check failed: $($_.Exception.Message)" -Level Debug }
    }
}
catch {
    Write-VALog "Worker failed: $($_.Exception.Message)" -Level Error
    Write-VALog $_.ScriptStackTrace -Level Debug
    exit 1
}
finally {
    Disconnect-VASource
}
