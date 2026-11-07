# Server health, checked by the watcher on every pass:
#
#   services   Veeam services (and the configuration database) that should be running but have been stopped
#              for longer than firstAlertAfterMinutes. The wait hides reboots and service restarts.
#   sessions   job sessions that appear stuck: running far longer than the job usually takes, or with no
#              progress for a long time.
#   watcher    the watcher itself failing several runs in a row (VBR unreachable, bad credentials...).
#
# All of these stay quiet while Veeam is being upgraded (a Veeam installer is running, or VBR's version
# changed a few minutes ago) and while maintenance mode is on (Set-VeeamAwareMaintenance.ps1).
#
# The checks are plain functions over snapshots (services, sessions, signals) and the "health" part of the
# state, so the tests can drive them without a server. They return the events to send; the watcher sends
# them and saves the state.

function New-VAHealthState {
    [ordered]@{
        serviceDownSince  = [ordered]@{}   # service name -> first seen not running (UTC ISO)
        servicesAlerted   = @()            # services in the current outage (alerted, not yet back up for backUpFor)
        servicesAlertedAt = $null          # when the alert or the last reminder went out
        servicesReminders = 0
        servicesUpSince   = $null          # every alerted service running again since then
        servicesOutageSince = $null        # when the first alerted service went down
        sessionProgress   = [ordered]@{}   # running session id -> { p: progress signature, at: when it last changed }
        stuckAlerted      = @()            # session ids an "appears stuck" alert was sent for
        watchFailures     = 0              # watcher runs failed in a row
        watchFailingSince = $null
        watchLastError    = $null
        watchAlerted      = $false
        watchAlertedAt    = $null
        watchReminders    = 0
        vbrVersion        = $null
        upgradeSince      = $null          # when an upgrade signal was first seen (cleared when it goes away)
        quietUntil        = $null          # alerts stay quiet until then (after an upgrade finished)
        maintenanceUntil  = $null
        maintenanceReason = $null
        staleAlertedAt    = $null          # when the post-job hook last said the watcher had stopped running
    }
}

function ConvertTo-VAHealthState {
    <# Fills in missing keys and turns the DateTime values ConvertFrom-Json produces back into ISO strings. #>
    param($Health)
    $h = New-VAHealthState
    if ($Health -is [System.Collections.IDictionary]) { foreach ($k in @($Health.Keys)) { $h[$k] = $Health[$k] } }
    foreach ($k in 'serviceDownSince', 'sessionProgress') { if ($h[$k] -isnot [System.Collections.IDictionary]) { $h[$k] = [ordered]@{} } }
    foreach ($k in 'servicesAlerted', 'stuckAlerted') { $h[$k] = @($h[$k] | Where-Object { $_ } | ForEach-Object { "$_" }) }
    foreach ($k in @($h.serviceDownSince.Keys)) { $h.serviceDownSince[$k] = ConvertTo-VAIsoString $h.serviceDownSince[$k] }
    foreach ($k in @($h.sessionProgress.Keys)) {
        $p = $h.sessionProgress[$k]
        if ($p -is [System.Collections.IDictionary]) { foreach ($d in 'at', 'ra') { if ($p.Contains($d)) { $p[$d] = ConvertTo-VAIsoString $p[$d] } } } else { $h.sessionProgress.Remove($k) }
    }
    foreach ($k in 'watchFailingSince', 'watchAlertedAt', 'servicesAlertedAt', 'servicesUpSince', 'servicesOutageSince', 'upgradeSince', 'quietUntil', 'maintenanceUntil', 'staleAlertedAt') { $h[$k] = ConvertTo-VAIsoString $h[$k] }
    $h.watchFailures = [int]$h.watchFailures
    $h.watchReminders = [int]$h.watchReminders
    $h.servicesReminders = [int]$h.servicesReminders
    $h.watchAlerted = [bool]$h.watchAlerted
    return $h
}

function Get-VAIso { param([datetimeoffset]$Date) $Date.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }

function Save-VAHealthState {
    <#
    Saves the watcher's health state. Keys other processes own are left alone: maintenance* belong to
    Set-VeeamAwareMaintenance.ps1, staleAlertedAt to the post-job worker.
    #>
    param([Parameter(Mandatory)]$Health)
    $h = $Health
    Update-VAState {
        param($s)
        foreach ($k in @($h.Keys)) { if ($k -notlike 'maintenance*' -and $k -ne 'staleAlertedAt') { $s.health[$k] = $h[$k] } }
    } | Out-Null
}

function Get-VAWatcherStaleEvent {
    <#
    For the post-job worker: an alert when the watcher has not completed a run for max(30, 3 x interval)
    minutes (scheduled task disabled, deleted or failing to start), at most once a day. $null otherwise.
    #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$State, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)
    $w = $Config.watch
    if (-not $w.enabled -or -not (Get-VAProp $w 'health.enabled' $true)) { return $null }
    $last = ConvertTo-VADate $State.lastWatchUtc
    if (-not $last) { return $null }
    $limit = [Math]::Max(30, 3 * [int]$w.intervalMinutes)
    if (($Now - $last).TotalMinutes -lt $limit) { return $null }
    $h = ConvertTo-VAHealthState $State.health
    $maint = ConvertTo-VADate $h.maintenanceUntil
    if ($maint -and $maint -gt $Now) { return $null }
    # The watcher skips its VBR checks while Veeam upgrades, so it completes no runs then; not a fault.
    $settle = ConvertTo-VADate $h.quietUntil
    if ($h.upgradeSince -or ($settle -and $settle -gt $Now)) { return $null }
    $prev = ConvertTo-VADate $h.staleAlertedAt
    if ($prev -and ($Now - $prev).TotalHours -lt 24) { return $null }
    $ago = Format-VADuration ($Now - $last)
    $report = New-VAReport -Header 'Watcher' -Title 'VeeamAware Watch' -Status warning -Icon (Get-VAStatusInfo 'Warning').Emoji -Label 'NOT RUNNING' `
        -Summary @((New-VATimePart $last $(if (($Now - $last).TotalHours -ge 20) { 'f' } else { 't' }) 'last run '); "$ago ago") `
        -Facts @(New-VAFact 'Scheduled task' '\VeeamAware\VeeamAware Watch') `
        -Note 'Check the task in Task Scheduler. Until it runs, agent sessions, malware, repository, analyzer and health checks and digests wait.' `
        -Timestamp $Now
    New-VAEvent -Kind health -Severity warning -Status 'WatcherStale' -Title "VeeamAware watcher not running on $env:COMPUTERNAME" `
        -Text "The watcher last completed a run $ago ago ($($last.ToString('u')))." -Fingerprint (Get-VAFingerprint 'health' 'watcher') `
        -Report $report -Mention Warning -Details ([ordered]@{ check = 'watcherStale'; lastWatchUtc = $State.lastWatchUtc; minutes = [int]($Now - $last).TotalMinutes })
}

function Set-VAMaintenance {
    <# Turns maintenance mode on until $Until (health alerts quiet), or off with -Off. Returns the health state. #>
    param([datetimeoffset]$Until, [string]$Reason, [switch]$Off)
    $u = if ($Off) { $null } else { Get-VAIso $Until }
    $r = if ($Off) { $null } else { $Reason }
    Update-VAState { param($s) $s.health.maintenanceUntil = $u; $s.health.maintenanceReason = $r; $s.health }
}

# ---- Snapshots (the only parts that touch the machine) ----------------------------------------------------

function Get-VAServiceSnapshot {
    <#
    The services to watch: those matching services.include (name or display name), not services.exclude, and
    set to start automatically; plus services.required, which are reported as Missing when not installed.
    #>
    param($Settings)
    $include = @(Get-VAProp $Settings 'include' @('Veeam*'))
    $exclude = @(Get-VAProp $Settings 'exclude' @())
    $required = @(Get-VAProp $Settings 'required' @())
    $out = [System.Collections.Generic.List[object]]::new()
    $found = @{}
    foreach ($svc in @(Get-Service -ErrorAction SilentlyContinue)) {
        $name = "$($svc.Name)"; $display = "$($svc.DisplayName)"
        $isRequired = @($required | Where-Object { $name -like $_ }).Count -gt 0
        $included = @($include | Where-Object { $name -like $_ -or $display -like $_ }).Count -gt 0
        $excluded = @($exclude | Where-Object { $name -like $_ -or $display -like $_ }).Count -gt 0
        $auto = "$($svc.StartType)" -like 'Automatic*'
        if (-not ($isRequired -or ($included -and $auto -and -not $excluded))) { continue }
        $found[$name] = $true
        $out.Add([pscustomobject]@{ Name = $name; DisplayName = $display; Status = "$($svc.Status)"; StartType = "$($svc.StartType)" })
    }
    foreach ($r in $required) {
        if ($r -notmatch '[*?]' -and -not $found.ContainsKey($r)) {
            $out.Add([pscustomobject]@{ Name = $r; DisplayName = $r; Status = 'Missing'; StartType = '' })
        }
    }
    return $out.ToArray()
}

function Get-VAVbrVersion {
    <# VBR's version, from the Veeam Backup Service executable (works while VBR itself is down). #>
    try {
        $svc = Get-CimInstance Win32_Service -Filter "Name='VeeamBackupSvc'" -ErrorAction Stop
        if (-not $svc -or -not $svc.PathName) { return $null }
        $exe = if ($svc.PathName -match '^"([^"]+)"') { $Matches[1] } else { ($svc.PathName -split '\s+(?=-|/)')[0] }
        if (-not (Test-Path -LiteralPath $exe)) { return $null }
        $v = (Get-Item -LiteralPath $exe).VersionInfo
        $ver = if ($v.ProductVersion) { "$($v.ProductVersion)" } else { "$($v.FileVersion)" }
        return ($ver -split '\s')[0]
    }
    catch { return $null }
}

function Get-VAUpgradeSignals {
    <#
    Signs that Veeam is being installed or upgraded right now:
      Installers    processes named like upgrade.processNames; msiexec/setup processes whose path or command
                    line mentions Veeam; and setup-like programs (or anything run from a CD/ISO drive) signed
                    by Veeam, which catches Setup.exe on a mounted VBR ISO whose path says nothing about Veeam
      MsiInProgress Windows Installer is in the middle of an installation (any product)
      MsiService    the Windows Installer service is running (it starts for an install and stops when idle)
      Version       VBR's current version (a change between watcher runs means an upgrade just finished)
    The permanent Veeam Updater processes never count.
    #>
    param($Settings)
    $patterns = @(Get-VAProp $Settings 'processNames' @('*Veeam*Setup*', '*Veeam*Upgrade*'))
    $installers = [System.Collections.Generic.List[string]]::new()
    $cdDrives = try { @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' -ErrorAction Stop | ForEach-Object { "$($_.DeviceID)" }) } catch { @() }
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension("$($p.Name)")
            if ($name -like 'Veeam.Updater*') { continue }
            $exe = "$($p.ExecutablePath)"
            $where = "$exe $($p.CommandLine)"
            $byName = @($patterns | Where-Object { $name -like $_ }).Count -gt 0
            $byInstaller = $name -match '^(msiexec|setup)$' -and $where -match 'veeam'
            $bySigner = $false
            if (-not ($byName -or $byInstaller) -and $exe -and
                ($name -match 'setup|install|upgrade|wizard' -or @($cdDrives | Where-Object { $exe -like "$_\*" }).Count)) {
                $company = try { "$((Get-Item -LiteralPath $exe -ErrorAction Stop).VersionInfo.CompanyName)" } catch { '' }
                $bySigner = $company -like '*Veeam*'
            }
            if ($byName -or $byInstaller -or $bySigner) { $installers.Add("$($p.Name) ($($p.ProcessId))") }
        }
    }
    catch { Write-VALog "Process list unavailable for upgrade detection: $($_.Exception.Message)" -Level Debug }
    [pscustomobject]@{
        Installers    = $installers.ToArray()
        MsiInProgress = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress'
        MsiService    = "$((Get-Service msiserver -ErrorAction SilentlyContinue).Status)" -eq 'Running'
        Version       = Get-VAVbrVersion
    }
}

# ---- Quiet periods: upgrades and maintenance --------------------------------------------------------------

function Update-VAQuietState {
    <#
    Works out whether health alerts should stay quiet this run, and why. Returns
    { Quiet, Upgrading, Reason, Events } and updates $Health (upgradeSince, quietUntil, vbrVersion).
    Upgrading is true only while an installer is actually active: the watcher then leaves VBR alone (loading
    Veeam's PowerShell module would lock files the installer is replacing).

    An upgrade is "in progress" while a Veeam installer runs, or while Windows Installer is busy (an install
    in progress, or its service running) and a watched service is down. Every run that sees it pushes
    quietUntil to upgrade.quietMinutes ahead, so gaps between installer stages and the time services take to
    come back stay quiet. A signal that never goes away (a process that only looks like an installer) stops
    counting after upgrade.maxHours, and the run says so in the log.
    #>
    param($Settings, $Signals, $Health, [datetimeoffset]$Now, [bool]$ServicesDown)
    $events = [System.Collections.Generic.List[object]]::new()
    $up = Get-VAProp $Settings 'upgrade'
    $enabled = [bool](Get-VAProp $up 'enabled' $true)
    $quietMinutes = [int](Get-VAProp $up 'quietMinutes' 30)
    $maxHours = [double](Get-VAProp $up 'maxHours' 6)
    $reason = $null
    $upgrading = $false

    # Maintenance keys belong to Set-VeeamAwareMaintenance.ps1; an expired window is simply ignored here.
    $maint = ConvertTo-VADate $Health.maintenanceUntil
    if ($maint -and $maint -gt $Now) { $reason = "maintenance mode until $($maint.ToString('u'))$(if ($Health.maintenanceReason) { " ($($Health.maintenanceReason))" })" }

    if ($enabled -and $Signals) {
        $installers = @($Signals.Installers | Where-Object { $_ })
        $signal = if ($installers) { "installer running: $($installers -join ', ')" }
        elseif (($Signals.MsiInProgress -or (Get-VAProp $Signals 'MsiService' $false)) -and $ServicesDown) { 'Windows Installer busy while Veeam services are down' }
        if ($signal) {
            if (-not $Health.upgradeSince) { $Health.upgradeSince = Get-VAIso $Now; Write-VALog "Upgrade detected ($signal); health alerts paused" }
            $since = ConvertTo-VADate $Health.upgradeSince
            if (($Now - $since).TotalHours -lt $maxHours) {
                $Health.quietUntil = Get-VAIso $Now.AddMinutes($quietMinutes)
                $upgrading = $true
                if (-not $reason) { $reason = "Veeam upgrade in progress ($signal)" }
            }
            else { Write-VALog "Upgrade signal present for more than $maxHours h ($signal); health alerts are no longer paused for it" -Level Warning }
        }
        elseif ($Health.upgradeSince) { Write-VALog 'Upgrade signal gone'; $Health.upgradeSince = $null }

        $ver = "$($Signals.Version)"
        if ($ver) {
            $prev = "$($Health.vbrVersion)"
            if ($prev -and $prev -ne $ver) {
                Write-VALog "Veeam Backup & Replication version changed: $prev -> $ver"
                $Health.quietUntil = Get-VAIso $Now.AddMinutes($quietMinutes)
                if ([bool](Get-VAProp $up 'notifyVersionChange' $true)) { $events.Add((New-VAVersionChangeEvent -From $prev -To $ver)) }
            }
            $Health.vbrVersion = $ver
        }
    }
    $quiet = ConvertTo-VADate $Health.quietUntil
    if (-not $reason -and $quiet -and $quiet -gt $Now) { $reason = "settling after a Veeam upgrade until $($quiet.ToString('u'))" }
    elseif ($quiet -and $quiet -le $Now) { $Health.quietUntil = $null }
    [pscustomobject]@{ Quiet = [bool]$reason; Upgrading = $upgrading; Reason = $reason; Events = $events.ToArray() }
}

# ---- Alert timing -------------------------------------------------------------------------------------------
#
# Three timings, shared by every health check:
#   firstAlertAfterMinutes  a problem must last this long before the first alert (services; stuck sessions and
#                           the watcher have their own thresholds)
#   repeatEveryMinutes      while it lasts, a reminder this often (0 = alert once)
#   backUpForMinutes        a recovery must hold this long before "recovered" goes out; a relapse inside that
#                           window is the same outage (services)
# Each can be set once under watch.health and overridden per check (watch.health.services.repeatEveryMinutes...).

function Get-VAHealthTiming {
    param($Health, [Parameter(Mandatory)][string]$Check)
    $c = Get-VAProp $Health $Check
    [pscustomobject]@{
        FirstAlertAfter = [double](Get-VAProp $c 'firstAlertAfterMinutes' (Get-VAProp $c 'graceMinutes' (Get-VAProp $Health 'firstAlertAfterMinutes' 15)))
        RepeatEvery     = [double](Get-VAProp $c 'repeatEveryMinutes' (Get-VAProp $Health 'repeatEveryMinutes' 0))
        BackUpFor       = [double](Get-VAProp $c 'backUpForMinutes' (Get-VAProp $Health 'backUpForMinutes' 0))
    }
}

function Test-VAReminderDue {
    param($Timing, $LastSent, [datetimeoffset]$Now)
    $last = ConvertTo-VADate $LastSent
    [bool]($Timing.RepeatEvery -gt 0 -and $last -and ($Now - $last).TotalMinutes -ge $Timing.RepeatEvery)
}

# ---- Checks ------------------------------------------------------------------------------------------------

function Update-VAServiceHealth {
    <#
    Services not running are timed from the first run that saw them down; an alert goes out once one has been
    down for FirstAlertAfter. One alert lists every stopped service; a newly overdue service sends an update,
    and while any stays down a reminder goes out every RepeatEvery. "Running again" goes out once every
    alerted service has run for BackUpFor. While quiet the down timers restart (the grace period starts over
    when the upgrade or maintenance ends) and no alerts or reminders go out.
    #>
    param($Settings, [object[]]$Services, $Health, [datetimeoffset]$Now, [switch]$Quiet, $Timing, [scriptblock]$StopReason)
    if (-not $Timing) { $Timing = Get-VAHealthTiming ([ordered]@{ services = $Settings }) 'services' }
    $down = @($Services | Where-Object { $_ -and "$($_.Status)" -ne 'Running' })
    $downNames = @($down | ForEach-Object { "$($_.Name)" })
    $since = [ordered]@{}
    foreach ($s in $down) {
        $prev = if ($Health.serviceDownSince.Contains($s.Name)) { $Health.serviceDownSince[$s.Name] } else { $null }
        $since[$s.Name] = if ($prev -and -not $Quiet) { $prev } else { Get-VAIso $Now }
    }
    $Health.serviceDownSince = $since
    $overdue = @($down | Where-Object { ($Now - (ConvertTo-VADate $since[$_.Name])).TotalMinutes -ge $Timing.FirstAlertAfter })
    $alerted = @($Health.servicesAlerted)
    $show = @($down | Where-Object { $alerted -contains $_.Name -or @($overdue | ForEach-Object Name) -contains $_.Name })
    $events = [System.Collections.Generic.List[object]]::new()
    if (-not $Quiet) {
        $new = @($overdue | Where-Object { $alerted -notcontains $_.Name })
        if ($new) {
            $reasons = @{}
            if ($StopReason) { foreach ($s in $new) { $why = try { & $StopReason $s $since[$s.Name] } catch { $null }; if ($why) { $reasons[$s.Name] = $why } } }
            $events.Add((New-VAServiceAlertEvent -Down $show -New $new -Since $since -Reasons $reasons -Now $Now))
            if (-not $alerted.Count) {
                $Health.servicesReminders = 0
                $Health.servicesOutageSince = @($show | ForEach-Object { $since[$_.Name] } | Sort-Object | Select-Object -First 1)[0]
            }
            $alerted = @($alerted + @($new | ForEach-Object Name) | Select-Object -Unique)
            $Health.servicesAlertedAt = Get-VAIso $Now
        }
        # An outage alerted before reminders existed has no send time: start the reminder clock now.
        elseif ($alerted.Count -and -not $Health.servicesAlertedAt) { $Health.servicesAlertedAt = Get-VAIso $Now }
        elseif ($show.Count -and (Test-VAReminderDue $Timing $Health.servicesAlertedAt $Now)) {
            $Health.servicesReminders = [int]$Health.servicesReminders + 1
            $events.Add((New-VAServiceAlertEvent -Down $show -Since $since -Reminder $Health.servicesReminders -Now $Now))
            $Health.servicesAlertedAt = Get-VAIso $Now
        }
    }
    if ($alerted.Count -and -not @($alerted | Where-Object { $downNames -contains $_ }).Count) {
        if (-not $Health.servicesUpSince) { $Health.servicesUpSince = Get-VAIso $Now }
        if (($Now - (ConvertTo-VADate $Health.servicesUpSince)).TotalMinutes -ge $Timing.BackUpFor) {
            if ([bool](Get-VAProp $Settings 'notifyRecovery' $true)) { $events.Add((New-VAServiceAlertEvent -Recovered $alerted -Services $Services -OutageSince $Health.servicesOutageSince -Now $Now)) }
            $alerted = @(); $Health.servicesAlertedAt = $null; $Health.servicesReminders = 0; $Health.servicesUpSince = $null; $Health.servicesOutageSince = $null
        }
    }
    else { $Health.servicesUpSince = $null }
    $Health.servicesAlerted = $alerted
    [pscustomobject]@{ Down = $down; Overdue = $overdue; Events = $events.ToArray() }
}

function Get-VASessionProgressSignature {
    <# What "progress" means for the stall check: percent plus processed/transferred bytes. #>
    param($Session)
    "$(Get-VAProp $Session 'progress.progressPercent' '')|$(Get-VAProp $Session 'progress.processedSize' '')|$(Get-VAProp $Session 'progress.transferredSize' '')"
}

function Get-VAStuckLimitHours {
    <#
    The run-time limit for one session, in hours:
      * a sessions.jobs rule whose job pattern matches: its hours, as given
      * the job's typical duration known: usualFactor x typical, but never under minHours
      * otherwise: sessions.hours
    #>
    param($Settings, [string]$JobName, $Typical)
    foreach ($r in @(Get-VAProp $Settings 'jobs' @())) {
        if ($r -and $JobName -like "$(Get-VAProp $r 'job' '')") { return [double](Get-VAProp $r 'hours' (Get-VAProp $Settings 'hours' 12)) }
    }
    $factor = [double](Get-VAProp $Settings 'usualFactor' 3)
    if ($factor -gt 0 -and $Typical -is [timespan] -and $Typical.TotalSeconds -gt 0) {
        return [Math]::Max([double](Get-VAProp $Settings 'minHours' 2), $factor * $Typical.TotalHours)
    }
    [double](Get-VAProp $Settings 'hours' 12)
}

function Update-VAStuckSessions {
    <#
    A running session appears stuck when
      * it has run longer than its limit (Get-VAStuckLimitHours). The job's typical duration comes from
        $TypicalDuration, asked once per session after it has run minHours, and kept in the state; or
      * its progress (percent, processed and transferred bytes) has not moved for noProgressMinutes.
    Sessions of types in excludeTypes (backup copy jobs keep a session open all the time), in excludeStates
    (Idle = waiting for work) or of jobs matching excludeJobs are skipped. One alert per session, then a
    reminder every RepeatEvery while it keeps running.
    #>
    param($Settings, [object[]]$Sessions, $Health, [datetimeoffset]$Now, [switch]$Quiet, [scriptblock]$TypicalDuration, $Timing)
    if (-not $Timing) { $Timing = Get-VAHealthTiming ([ordered]@{ sessions = $Settings }) 'sessions' }
    $excludeTypes = @(Get-VAProp $Settings 'excludeTypes' @('BackupCopyJob', 'FileBackupCopy'))
    $excludeStates = @(Get-VAProp $Settings 'excludeStates' @('Idle'))
    $excludeJobs = @(Get-VAProp $Settings 'excludeJobs' @())
    $minHours = [double](Get-VAProp $Settings 'minHours' 2)
    $stallMinutes = [double](Get-VAProp $Settings 'noProgressMinutes' 240)
    $running = @($Sessions | Where-Object { $_ -and "$($_.state)" -ne 'Stopped' -and -not (Get-VAProp $_ 'endTime') } | Where-Object {
            $t = "$($_.sessionType)"; $st = "$($_.state)"; $n = "$($_.name)"
            -not (@($excludeTypes | Where-Object { $t -like $_ }).Count) -and -not (@($excludeStates | Where-Object { $st -like $_ }).Count) -and
            -not (@($excludeJobs | Where-Object { $n -like $_ }).Count)
        })
    $progress = [ordered]@{}
    $alerted = @($Health.stuckAlerted)
    $events = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $running) {
        $id = "$($s.id)"
        $sig = Get-VASessionProgressSignature $s
        $prev = if ($Health.sessionProgress.Contains($id)) { $Health.sessionProgress[$id] } else { $null }
        $changedAt = if ($prev -and "$($prev['p'])" -eq $sig -and $prev['at']) { $prev['at'] } else { Get-VAIso $Now }
        $entry = [ordered]@{ p = $sig; at = $changedAt }
        # t: typical seconds (-1 = not known); ra/rn: when the alert or last reminder went out, reminders sent
        foreach ($k in 't', 'ra', 'rn') { if ($prev -and $prev.Contains($k)) { $entry[$k] = $prev[$k] } }
        $progress[$id] = $entry
        if ($Quiet) { continue }

        $start = ConvertTo-VADate $s.creationTime
        if (-not $start) { continue }
        $elapsed = $Now - $start
        $stalled = $Now - (ConvertTo-VADate $changedAt)
        if ($alerted -contains $id) {
            if (-not $entry.Contains('ra') -or -not $entry['ra']) { $entry.ra = Get-VAIso $Now; $entry.rn = 0 }
            elseif (Test-VAReminderDue $Timing $entry['ra'] $Now) {
                $entry.rn = [int]$entry['rn'] + 1; $entry.ra = Get-VAIso $Now
                $events.Add((New-VAStuckSessionEvent -Session $s -Reason 'still' -Elapsed $elapsed -Stalled $stalled -Reminder $entry.rn))
            }
            continue
        }
        $typical = $null
        if ($elapsed.TotalHours -ge $minHours) {
            if (-not $entry.Contains('t')) {
                $tv = if ($TypicalDuration) { try { & $TypicalDuration $s } catch { $null } }
                $entry.t = if ($tv -is [timespan]) { [int]$tv.TotalSeconds } else { -1 }
            }
            if ([int]$entry.t -gt 0) { $typical = [timespan]::FromSeconds([int]$entry.t) }
        }
        $limit = Get-VAStuckLimitHours $Settings "$($s.name)" $typical
        $reason = $null
        if ($limit -gt 0 -and $elapsed.TotalHours -ge [Math]::Max($limit, $minHours)) { $reason = 'long' }
        if (-not $reason -and $stallMinutes -gt 0 -and $prev -and $stalled.TotalMinutes -ge $stallMinutes) { $reason = 'stalled' }
        if ($reason) {
            $events.Add((New-VAStuckSessionEvent -Session $s -Reason $reason -Elapsed $elapsed -LimitHours $limit -Typical $typical -Stalled $stalled))
            $alerted += $id; $entry.ra = Get-VAIso $Now; $entry.rn = 0
        }
    }
    $Health.sessionProgress = $progress
    $Health.stuckAlerted = @($alerted | Where-Object { $progress.Contains($_) })
    [pscustomobject]@{ Running = $running; Events = $events.ToArray() }
}

function Get-VATypicalDuration {
    <# Median duration of the job's recent finished runs, or $null with fewer than 3. #>
    param([Parameter(Mandatory)][string]$JobId)
    $d = @(Get-VAJobHistory -JobId $JobId -Count 10 | ForEach-Object {
            $a = ConvertTo-VADate $_.startTime; $b = ConvertTo-VADate $_.endTime
            if ($a -and $b -and $b -gt $a) { ($b - $a).TotalSeconds }
        } | Sort-Object)
    if ($d.Count -lt 3) { return $null }
    [timespan]::FromSeconds($d[[int][Math]::Floor($d.Count / 2)])
}

function Update-VAWatcherHealth {
    <#
    Counts failed watcher runs. After failureAlertAfter failures in a row an alert goes out (not while quiet,
    or while Veeam services are down: the service alert already explains it), then a reminder every
    RepeatEvery while it keeps failing; the next good run sends "recovered".
    #>
    param($Settings, $Health, [datetimeoffset]$Now, [switch]$Failed, [string]$ErrorMessage, [switch]$Quiet, $Timing, $LastGood)
    if (-not $Timing) { $Timing = Get-VAHealthTiming ([ordered]@{ watcher = $Settings }) 'watcher' }
    $after = [int](Get-VAProp $Settings 'failureAlertAfter' 3)
    $events = [System.Collections.Generic.List[object]]::new()
    if ($Failed) {
        if ($Quiet) { return [pscustomobject]@{ Events = @() } }   # expected while upgrading: not counted
        $Health.watchFailures = [int]$Health.watchFailures + 1
        if (-not $Health.watchFailingSince) { $Health.watchFailingSince = Get-VAIso $Now }
        $Health.watchLastError = Limit-VAText "$ErrorMessage" 500
        if ($after -gt 0 -and $Health.watchFailures -ge $after -and -not $Health.watchAlerted) {
            $events.Add((New-VAWatcherAlertEvent -Failures $Health.watchFailures -Since $Health.watchFailingSince -LastError $Health.watchLastError -LastGood $LastGood -Now $Now))
            $Health.watchAlerted = $true; $Health.watchAlertedAt = Get-VAIso $Now; $Health.watchReminders = 0
        }
        elseif ($Health.watchAlerted -and -not $Health.watchAlertedAt) { $Health.watchAlertedAt = Get-VAIso $Now }
        elseif ($Health.watchAlerted -and (Test-VAReminderDue $Timing $Health.watchAlertedAt $Now)) {
            $Health.watchReminders = [int]$Health.watchReminders + 1; $Health.watchAlertedAt = Get-VAIso $Now
            $events.Add((New-VAWatcherAlertEvent -Failures $Health.watchFailures -Since $Health.watchFailingSince -LastError $Health.watchLastError -Reminder $Health.watchReminders -LastGood $LastGood -Now $Now))
        }
    }
    else {
        if ($Health.watchAlerted -and [bool](Get-VAProp $Settings 'notifyRecovery' $true)) {
            $events.Add((New-VAWatcherAlertEvent -Recovered -Failures $Health.watchFailures -Since $Health.watchFailingSince -Now $Now))
        }
        $Health.watchFailures = 0; $Health.watchFailingSince = $null; $Health.watchLastError = $null; $Health.watchAlerted = $false
        $Health.watchAlertedAt = $null; $Health.watchReminders = 0
    }
    [pscustomobject]@{ Events = $events.ToArray() }
}

function Get-VAHealthNote {
    <# One line for the digest when something is wrong (or quiet), else $null. #>
    param($State, [datetimeoffset]$Now = [datetimeoffset]::UtcNow, $IntervalMinutes = 5)
    $h = ConvertTo-VAHealthState (Get-VAProp $State 'health')
    $lines = @()
    if ($h.servicesAlerted.Count) { $lines += "🛑 Veeam service$(if ($h.servicesAlerted.Count -ne 1) { 's' }) stopped: $($h.servicesAlerted -join ', ')" }
    if ($h.watchFailures -gt 0) { $lines += "🩺 Watcher failed its last $($h.watchFailures) run$(if ($h.watchFailures -ne 1) { 's' }): $(Limit-VAText "$($h.watchLastError)" 120)" }
    $last = ConvertTo-VADate (Get-VAProp $State 'lastWatchUtc')
    if ($last -and ($Now - $last).TotalMinutes -gt [Math]::Max(30, 3 * [int]$IntervalMinutes)) { $lines += "🩺 Watcher last completed $(Format-VADuration ($Now - $last)) ago" }
    $maint = ConvertTo-VADate $h.maintenanceUntil
    if ($maint -and $maint -gt $Now) { $lines += "🔧 Maintenance mode until $($maint.ToString('yyyy-MM-dd HH:mm')) UTC; health alerts paused" }
    if ($lines) { return ($lines -join "`n") }
    return $null
}

# ---- Events and reports ------------------------------------------------------------------------------------

function New-VAServiceAlertEvent {
    <#
    Laid out like a job report: header (what it is) / title (the service) / status line (since, down for) /
    what went wrong (the Service Control Manager's reason) / facts. Several services: a table instead.
    #>
    param([object[]]$Down, [object[]]$New, $Since, [hashtable]$Reasons = @{}, [int]$Reminder,
        [string[]]$Recovered, [object[]]$Services, $OutageSince, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)
    $display = { param($n) $m = @($Services | Where-Object { $_ -and "$($_.Name)" -eq $n }); if ($m) { "$($m[0].DisplayName)" } else { $n } }

    if ($Recovered) {
        $names = @($Recovered | ForEach-Object { & $display $_ })
        $one = $names.Count -eq 1
        $from = ConvertTo-VADate $OutageSince
        $ok = Get-VAStatusInfo 'Success'
        $report = New-VAReport -Header $(if ($one) { 'Veeam service' } else { 'Veeam services' }) `
            -Title $(if ($one) { $names[0] } else { "$($names.Count) Veeam services" }) -Status success -Icon $ok.Emoji -Label 'RUNNING AGAIN' `
            -Summary @((New-VARangePart $from $Now); $(if ($from) { "down $(Format-VADuration ($Now - $from))" })) `
            -Quotes @(if (-not $one) { [ordered]@{ text = $names -join ', ' } }) `
            -Facts @(if ($one) { New-VAFact 'Service' $Recovered[0] }) -Timestamp $Now
        return New-VAEvent -Kind health -Severity success -Status 'Recovered' -Title "$($names -join ', ') running again on $env:COMPUTERNAME" `
            -Text "Running again: $($names -join ', ')." -Markdown "Running again on $env:COMPUTERNAME: $($names -join ', ')." `
            -Fingerprint (Get-VAFingerprint 'health' 'services') -Resolved -Report $report `
            -Details ([ordered]@{ check = 'services'; recovered = @($Recovered); outageSince = $OutageSince })
    }

    $Down = @($Down)
    $one = $Down.Count -eq 1
    $newNames = @($New | Where-Object { $_ } | ForEach-Object Name)
    $sinceOf = { param($svc) ConvertTo-VADate $Since[$svc.Name] }
    $first = @($Down | ForEach-Object { & $sinceOf $_ } | Where-Object { $_ } | Sort-Object | Select-Object -First 1)
    $first = if ($first) { $first[0] } else { $null }
    $fail = Get-VAStatusInfo 'Failed'
    $allStopped = -not @($Down | Where-Object { "$($_.Status)" -ne 'Stopped' }).Count
    $word = if ($one -and "$($Down[0].Status)" -eq 'Missing') { 'MISSING' } elseif ($allStopped) { 'STOPPED' } else { 'NOT RUNNING' }
    $summary = @(
        if ($Reminder) { "reminder $Reminder" }
        if ($first) { New-VATimePart $first $(if (($Now - $first).TotalHours -ge 20) { 'f' } else { 't' }) 'since ' }
        if ($first) { "down $(Format-VADuration ($Now - $first))" }
    )
    $reasonOf = { param($svc) $r = $Reasons[$svc.Name]; if ($r) { Limit-VAText ("$(Get-VAProp $r 'Text' $r)" -replace '\s+', ' ') 400 } }
    if ($one) {
        $s = $Down[0]
        $why = & $reasonOf $s
        $quotes = @(if ($why) { [ordered]@{ text = $why } })
        $facts = @(
            New-VAFact 'Service' "$($s.Name)"
            New-VAFact 'State' "$($s.Status)"
            New-VAFact 'Start type' "$(Get-VAProp $s 'StartType' '')"
        )
        $sections = @()
        $title = "$($s.DisplayName)"
    }
    else {
        $quotes = @(); $facts = @()
        $rows = @($Down | ForEach-Object {
                $t = & $sinceOf $_
                [ordered]@{ status = 'Failed'; name = "$($_.DisplayName)"; size = "$($_.Status)"
                    duration = if ($t) { Format-VADuration ($Now - $t) } else { '' }; message = & $reasonOf $_ }
            })
        $sections = @([ordered]@{ type = 'objects'; title = "Not running · $($Down.Count)"; rows = $rows; more = 0; repository = $null })
        $title = "$($Down.Count) Veeam services"
    }
    $report = New-VAReport -Header $(if ($one) { 'Veeam service' } else { 'Veeam services' }) -Title $title -Status failed -Icon $fail.Emoji `
        -Label $(if ($Reminder) { "STILL $word" } else { $word }) -Summary $summary -Quotes $quotes -Facts $facts -Sections $sections `
        -Note $(if ($one) { 'Start it in services.msc. Jobs and restores that need it fail until it runs.' } else { 'Start them in services.msc. Jobs and restores that need them fail until they run.' }) `
        -Timestamp $Now
    $names = @($Down | ForEach-Object { "$($_.DisplayName)" }) -join ', '
    $title = if ($Reminder) { "Still not running on $env:COMPUTERNAME (reminder $Reminder): $names" } else { "Not running on $env:COMPUTERNAME: $names" }
    New-VAEvent -Kind health -Severity critical -Status 'ServiceDown' -Title (Limit-VAText $title 250) `
        -Text "Not running: $names." `
        -Markdown ("Veeam services not running on $env:COMPUTERNAME:`n`n" + (($Down | ForEach-Object { $t = & $sinceOf $_; $w = & $reasonOf $_
                        "- **$($_.DisplayName)** ($($_.Name)): $($_.Status)$(if ($t) { " since $($t.ToString('u'))" })$(if ($w) { " — $w" })" }) -join "`n")) `
        -Fingerprint (Get-VAFingerprint 'health' 'services') -Report $report -Mention Failure `
        -Details ([ordered]@{ check = 'services'; reminder = $Reminder; new = $newNames
            services = @($Down | ForEach-Object { [ordered]@{ name = $_.Name; displayName = $_.DisplayName; status = $_.Status; downSince = $Since[$_.Name]; reason = & $reasonOf $_ } }) })
}

function Get-VAServiceStopReason {
    <#
    Why a service stopped, from the Service Control Manager's events in the System log (crash, failed start,
    stopped). Newest matching event since shortly before it was seen down; $null when there is none.
    #>
    param([Parameter(Mandatory)]$Service, $Since)
    try {
        $t = ConvertTo-VADate $Since
        $from = if ($t) { $t.AddMinutes(-15).LocalDateTime } else { (Get-Date).AddDays(-1) }
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7000, 7009, 7011, 7022, 7023, 7024, 7031, 7034, 7036; StartTime = $from } -MaxEvents 300 -ErrorAction Stop)
        $mine = @($events | Where-Object { "$($_.Message)" -like "*$($Service.DisplayName)*" -or "$($_.Message)" -like "*$($Service.Name)*" })
        # A crash or failed start explains more than "entered the stopped state".
        $e = @($mine | Where-Object Id -ne 7036 | Select-Object -First 1) + @($mine | Select-Object -First 1) | Select-Object -First 1
        if (-not $e) { return $null }
        [pscustomobject]@{ Time = $e.TimeCreated; Id = $e.Id; Text = ("$($e.Message)" -replace '\s+', ' ').Trim() }
    }
    catch { return $null }
}

function New-VAStuckSessionEvent {
    param([Parameter(Mandatory)]$Session, [string]$Reason, [timespan]$Elapsed, [double]$LimitHours, $Typical, [timespan]$Stalled, [int]$Reminder)
    $s = $Session
    $pct = Get-VAProp $s 'progress.progressPercent'
    $warn = Get-VAStatusInfo 'Warning'
    $start = ConvertTo-VADate $s.creationTime
    $why = if ($Reason -eq 'stalled') { "no progress for $(Format-VADuration $Stalled)" } else { "running $(Format-VADuration $Elapsed)" }
    $report = New-VAReport -Header "$(Get-VAFriendlyType "$($s.sessionType)") job" -Title "$($s.name)" -Status warning -Icon $warn.Emoji `
        -Label $(if ($Reminder) { 'STILL STUCK' } else { 'APPEARS STUCK' }) `
        -Summary @(
            if ($Reminder) { "reminder $Reminder" }
            if ($start) { New-VATimePart $start $(if ($Elapsed.TotalHours -ge 20) { 'f' } else { 't' }) 'started ' }
            $why
        ) `
        -Note 'Check the session in the VBR console; stop and retry it if it is not moving.' `
        -Facts @(
            New-VAFact 'State' "$($s.state)"
            New-VAFact 'Progress' $(if ($null -ne $pct -and "$pct" -ne '') { "$pct%" })
            New-VAFact 'Processed' $(if (Get-VAProp $s 'progress.processedSize') { Format-VASize (Get-VAProp $s 'progress.processedSize') })
            New-VAFact 'No progress for' $(if ($Stalled.TotalMinutes -ge 30) { Format-VADuration $Stalled })
            New-VAFact 'Usually takes' $(if ($Typical -is [timespan]) { Format-VADuration $Typical })
        ) -Timestamp ([datetimeoffset]::UtcNow)
    $key = if ($s.jobId -and "$($s.jobId)" -ne '00000000-0000-0000-0000-000000000000') { "$($s.jobId)" } else { "$($s.name)" }
    $title = if ($Reminder) { "$($s.name) still appears stuck (reminder $Reminder)" } else { "$($s.name) appears stuck" }
    New-VAEvent -Kind health -Severity warning -Status 'Stuck' -Title $title `
        -Text "Job '$($s.name)' appears stuck: $why (state $($s.state))." `
        -Markdown "Job **$($s.name)** on $env:COMPUTERNAME appears stuck: $why.`n`n- State: $($s.state)`n- Started: $(if ($start) { $start.ToString('u') })`n- Session ID: ``$($s.id)``" `
        -Fingerprint (Get-VAFingerprint 'job' $key) -Report $report -Mention Warning `
        -Details ([ordered]@{ check = 'stuckSession'; reason = $Reason; reminder = $Reminder; sessionId = "$($s.id)"; jobId = "$($s.jobId)"; jobName = "$($s.name)"
            state = "$($s.state)"; startedAt = ConvertTo-VAIsoTime $s.creationTime; elapsedSeconds = [int]$Elapsed.TotalSeconds
            limitHours = $LimitHours; progressPercent = $pct; noProgressSeconds = [int]$Stalled.TotalSeconds })
}

function New-VAWatcherAlertEvent {
    param([int]$Failures, $Since, [string]$LastError, [switch]$Recovered, [int]$Reminder, $LastGood, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)
    $from = ConvertTo-VADate $Since
    $style = if ($from -and ($Now - $from).TotalHours -ge 20) { 'f' } else { 't' }
    if ($Recovered) {
        $ok = Get-VAStatusInfo 'Success'
        $report = New-VAReport -Header 'Watcher' -Title 'VeeamAware Watch' -Status success -Icon $ok.Emoji -Label 'WORKING AGAIN' `
            -Summary @((New-VARangePart $from $Now); "$Failures failed run$(if ($Failures -ne 1) { 's' })") -Timestamp $Now
        return New-VAEvent -Kind health -Severity success -Status 'Recovered' -Title "VeeamAware watcher working again on $env:COMPUTERNAME" `
            -Text "The watcher completed a run after $Failures failed run(s)." -Fingerprint (Get-VAFingerprint 'health' 'watcher') -Resolved -Report $report `
            -Details ([ordered]@{ check = 'watcher'; failures = $Failures; failingSince = $Since })
    }
    $warn = Get-VAStatusInfo 'Warning'
    $report = New-VAReport -Header 'Watcher' -Title 'VeeamAware Watch' -Status warning -Icon $warn.Emoji `
        -Label $(if ($Reminder) { 'STILL FAILING' } else { 'FAILING' }) `
        -Summary @(
            if ($Reminder) { "reminder $Reminder" }
            if ($from) { New-VATimePart $from $style 'since ' }
            "$Failures runs in a row"
        ) `
        -Quotes @(if ($LastError) { [ordered]@{ text = Limit-VAText $LastError 600 } }) `
        -Facts @(New-VAFact 'Last good run' (New-VATimePart $LastGood 'R')) `
        -Note 'Until it runs, agent sessions, malware, repository, analyzer and health checks and digests wait. Details: logs\watch-*.log.' `
        -Timestamp $Now
    New-VAEvent -Kind health -Severity warning -Status 'WatcherFailing' `
        -Title $(if ($Reminder) { "VeeamAware watcher still failing on $env:COMPUTERNAME (reminder $Reminder)" } else { "VeeamAware watcher failing on $env:COMPUTERNAME" }) `
        -Text "The watcher failed $Failures runs in a row. Last error: $LastError" -Fingerprint (Get-VAFingerprint 'health' 'watcher') `
        -Report $report -Mention Warning -Details ([ordered]@{ check = 'watcher'; reminder = $Reminder; failures = $Failures; failingSince = $Since; lastError = $LastError })
}

function New-VAVersionChangeEvent {
    param([string]$From, [string]$To)
    $report = New-VAReport -Header 'Veeam Backup & Replication' -Title "Updated to $To" -Status info -Icon '⬆️' -Label 'UPDATED' `
        -Summary @("from $From") -Note 'Health alerts stay quiet for a few minutes while services settle.' -Timestamp ([datetimeoffset]::UtcNow)
    New-VAEvent -Kind health -Severity info -Status 'Updated' -Title "Veeam Backup & Replication updated to $To on $env:COMPUTERNAME" `
        -Text "Veeam Backup & Replication was updated from $From to $To." -Fingerprint (Get-VAFingerprint 'health' 'version') -Report $report `
        -Details ([ordered]@{ check = 'version'; from = $From; to = $To })
}
