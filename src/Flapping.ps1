# Flapping: a problem that keeps clearing and coming back (a service that crashes every half hour, a
# repository hovering on a free-space threshold, a watcher that fails every other run). Without this, every
# turn sends a card: down, recovered, down, recovered...
#
# Each alert or recovery for the same fingerprint counts as one change; reminders don't count. When a
# fingerprint changes watch.flapping.changes times within withinMinutes, one "flapping" card goes out and
# further cards for it are held back. Once it has gone settleMinutes without a change, one "settled" card says
# where it ended up (still a problem, or fine). Applies to service, watcher and repository alerts.
#
# The state lives in state.flapping: fingerprint -> { changes: [ISO times], flapping, since, last: {title,
# resolved, severity, kind, header, subject} }.

function Test-VAFlapCandidate {
    <# Events that come in alert/recovery pairs. Stuck sessions and version changes don't flap. #>
    param($Event)
    if (-not $Event -or -not $Event.fingerprint) { return $false }
    if ($Event.kind -eq 'repository') { return $true }
    $check = "$(Get-VAProp $Event.details 'check' '')"
    return ($Event.kind -eq 'health' -and $check -in 'services', 'watcher')
}

function Get-VAFlapSettings {
    param($Config)
    $f = Get-VAProp $Config 'watch.flapping'
    [pscustomobject]@{
        Enabled = [bool](Get-VAProp $f 'enabled' $true)
        Changes = [int](Get-VAProp $f 'changes' 4)
        Within  = [double](Get-VAProp $f 'withinMinutes' 60)
        Settle  = [double](Get-VAProp $f 'settleMinutes' 30)
    }
}

function Invoke-VAFlapGate {
    <#
    Decides what to send for one event. Returns the events to send instead: the event itself, a "flapping"
    card in its place, or nothing while the fingerprint is flapping. Updates $Flaps (state.flapping) in place.
    #>
    param([Parameter(Mandatory)]$Event, [Parameter(Mandatory)][System.Collections.IDictionary]$Flaps,
        [Parameter(Mandatory)]$Settings, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)
    if (-not $Settings.Enabled -or -not (Test-VAFlapCandidate $Event)) { return $Event }
    $fp = "$($Event.fingerprint)"
    $entry = if ($Flaps.Contains($fp)) { $Flaps[$fp] } else { [ordered]@{ changes = @(); flapping = $false; since = $null; last = $null } }
    $Flaps[$fp] = $entry
    $reminder = [int](Get-VAProp $Event.details 'reminder' 0) -gt 0
    $entry.last = [ordered]@{
        title = "$($Event.title)"; resolved = [bool]$Event.resolved; severity = "$($Event.severity)"; kind = "$($Event.kind)"
        header = "$(Get-VAProp $Event.report 'header' '')"; subject = "$(Get-VAProp $Event.report 'title' '')"; mention = "$($Event.mention)"
    }
    if ($reminder) { if ($entry.flapping) { return } else { return $Event } }

    $cut = $Now.AddMinutes(-$Settings.Within)
    $entry.changes = @(@($entry.changes) + (Get-VAIso $Now) | Where-Object { $_ -and (ConvertTo-VADate $_) -ge $cut })
    if ($entry.flapping) { return }
    if ($Settings.Changes -gt 0 -and $entry.changes.Count -ge $Settings.Changes) {
        $entry.flapping = $true
        $entry.since = ConvertTo-VAIsoString $entry.changes[0]
        return (New-VAFlapEvent -Entry $entry -Fingerprint $fp -Settings $Settings -Now $Now)
    }
    return $Event
}

function Send-VAFlapGated {
    <#
    Sends one event through the flap gate with $Send (a scriptblock taking the event). A change only counts
    once it is delivered: if $Send throws, the fingerprint's entry goes back to how it was, so an outage
    while the targets are unreachable doesn't look like flapping.
    #>
    param([Parameter(Mandatory)]$Event, [Parameter(Mandatory)][System.Collections.IDictionary]$Flaps,
        [Parameter(Mandatory)]$Settings, [datetimeoffset]$Now = [datetimeoffset]::UtcNow, [Parameter(Mandatory)][scriptblock]$Send)
    $fp = if (Test-VAFlapCandidate $Event) { "$($Event.fingerprint)" } else { '' }
    $before = $null
    if ($fp -and $Flaps.Contains($fp)) { $before = [ordered]@{}; foreach ($k in @($Flaps[$fp].Keys)) { $before[$k] = $Flaps[$fp][$k] } }
    try { foreach ($e in @(Invoke-VAFlapGate -Event $Event -Flaps $Flaps -Settings $Settings -Now $Now)) { & $Send $e } }
    catch {
        if ($fp) { if ($before) { $Flaps[$fp] = $before } elseif ($Flaps.Contains($fp)) { $Flaps.Remove($fp) } }
        throw
    }
}

function Send-VAFlapSettled {
    <#
    Sends the "settled" cards that are due and forgets each fingerprint once its card is delivered. Never
    throws: a card that can't be delivered stays due and is tried again on the next pass. Returns the number sent.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Flaps, [Parameter(Mandatory)]$Settings,
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow, [Parameter(Mandatory)][scriptblock]$Send)
    $n = 0
    foreach ($e in @(Get-VAFlapSettledEvents -Flaps $Flaps -Settings $Settings -Now $Now)) {
        try { & $Send $e; $Flaps.Remove("$($e.fingerprint)"); $n++ }
        catch { Write-VALog "Settled card not delivered, will retry: $($_.Exception.Message)" -Level Warning }
    }
    $n
}

function Get-VAFlapSettledEvents {
    <# Once per watch pass: flapping fingerprints quiet for settleMinutes get one "settled" card; stale entries go. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Flaps, [Parameter(Mandatory)]$Settings, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($fp in @($Flaps.Keys)) {
        $e = $Flaps[$fp]
        $lastChange = @($e.changes | ForEach-Object { ConvertTo-VADate $_ } | Where-Object { $_ } | Sort-Object | Select-Object -Last 1)
        $lastChange = if ($lastChange) { $lastChange[0] } else { $null }
        $idle = if ($lastChange) { ($Now - $lastChange).TotalMinutes } else { [double]::MaxValue }
        # The entry stays until the card is delivered (Send-VAFlapSettled removes it), so a failed send retries.
        if ($e.flapping) {
            if ($idle -ge $Settings.Settle) { $out.Add((New-VAFlapEvent -Entry $e -Fingerprint $fp -Settings $Settings -Now $Now -Settled)) }
        }
        elseif ($idle -ge $Settings.Within) { $Flaps.Remove($fp) }
    }
    $out.ToArray()
}

function New-VAFlapEvent {
    param($Entry, [string]$Fingerprint, $Settings, [datetimeoffset]$Now, [switch]$Settled)
    $last = $Entry.last
    $subject = if ($last.subject) { $last.subject } else { $last.title }
    $header = if ($last.header) { $last.header } else { 'VeeamAware' }
    $since = ConvertTo-VADate $Entry.since
    $n = @($Entry.changes).Count
    if (-not $Settled) {
        $report = New-VAReport -Header $header -Title $subject -Status warning -Icon '🔁' -Label 'FLAPPING' `
            -Summary @("$n changes in $([int]$Settings.Within) min"; (New-VATimePart $since 't' 'since ')) `
            -Quotes @([ordered]@{ text = "Latest: $($last.title)" }) `
            -Note "It keeps going wrong and coming back. Further cards for it are held until it stays the same for $([int]$Settings.Settle) minutes; then one card says how it ended up." `
            -Timestamp $Now
        return New-VAEvent -Kind $last.kind -Severity warning -Status 'Flapping' -Title "Flapping on ${env:COMPUTERNAME}: $subject" `
            -Text "$subject keeps changing state ($n changes in $([int]$Settings.Within) minutes). Latest: $($last.title)" `
            -Fingerprint $Fingerprint -Report $report -Mention $(if ($last.mention) { 'Warning' } else { '' }) `
            -Details ([ordered]@{ check = 'flapping'; changes = $n; since = $Entry.since; latest = $last.title })
    }
    $ok = [bool]$last.resolved
    $report = New-VAReport -Header $header -Title $subject -Status $(if ($ok) { 'success' } else { 'failed' }) `
        -Icon $(if ($ok) { (Get-VAStatusInfo 'Success').Emoji } else { (Get-VAStatusInfo 'Failed').Emoji }) `
        -Label $(if ($ok) { 'SETTLED · OK' } else { 'SETTLED · STILL A PROBLEM' }) `
        -Summary @((New-VARangePart $since $Now); "steady for $([int]$Settings.Settle) min") `
        -Quotes @([ordered]@{ text = "Now: $($last.title)" }) -Timestamp $Now
    New-VAEvent -Kind $last.kind -Severity $(if ($ok) { 'success' } else { $last.severity }) -Status 'Settled' `
        -Title "Stopped flapping on ${env:COMPUTERNAME}: $subject" -Text "$subject stopped flapping. Now: $($last.title)" `
        -Fingerprint $Fingerprint -Resolved:$ok -Report $report -Mention $(if ($ok) { '' } else { $last.mention }) `
        -Details ([ordered]@{ check = 'flapping'; settled = $true; resolved = $ok; latest = $last.title })
}
