# Persistent state (state\state.json): what has already been notified, so the hook, watcher and digest
# never double-post. Every read-modify-write goes through Update-VAState, which holds a global mutex.

$script:VAStatePath = Join-Path $script:VARoot 'state\state.json'
$script:VAMaxRemembered = 2000

function Set-VAStatePath { param([Parameter(Mandatory)][string]$Path) $script:VAStatePath = $Path }

function New-VAState {
    [ordered]@{
        version           = 1
        lastWatchUtc      = $null
        sessionsSeenUtc   = $null   # when the watcher last read the session list successfully
        malwareHighWaterUtc = $null # newest malware detection seen (older ones count as seen; see the watcher)
        digests           = [ordered]@{}   # digest name -> last run (UTC, ISO-8601)
        notifiedSessions  = @()   # session ids posted individually (hook or watcher)
        seenMalwareEvents = @()
        seenAuthEvents    = @()
        repositoryLevels  = [ordered]@{}   # repository id -> ok | warning | critical | offline
        analyzerRunId     = $null
        analyzerViolations = @()
        repositorySpace   = [ordered]@{}   # repository id -> daily readings [{ d: yyyy-MM-dd, free: GB, cap: GB }]
        digestAnalyzer    = [ordered]@{}   # digest name -> analyzer violation count at its last run
        health            = New-VAHealthState   # see Health.ps1
        flapping          = [ordered]@{}   # fingerprint -> recent changes and flapping status (see Flapping.ps1)
    }
}

function ConvertTo-VAIsoString {
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
    return $Value
}

function Read-VAState {
    $state = New-VAState
    if (Test-Path $script:VAStatePath) {
        # A file another program holds open for a moment (antivirus, backup) is retried, and if it still can't be
        # read the caller fails rather than carrying on with empty state, which would forget everything already
        # sent once it was saved. Only a file that reads but doesn't parse is set aside as corrupt.
        $text = $null
        for ($i = 1; $null -eq $text; $i++) {
            try { $text = [System.IO.File]::ReadAllText($script:VAStatePath) }
            catch [System.IO.IOException], [System.UnauthorizedAccessException] {
                # Locked by another process, or briefly "access denied" while another process replaces it.
                if ($i -ge 5) { throw "Can't read $($script:VAStatePath): $($_.Exception.Message)" }
                Start-Sleep -Milliseconds (200 * $i)
            }
        }
        try {
            $json = $text | ConvertFrom-Json -AsHashtable
            if ($json -isnot [System.Collections.IDictionary]) { throw 'not a JSON object' }
            foreach ($k in @($json.Keys)) { $state[$k] = $json[$k] }
        }
        catch {
            Write-VALog "State file unreadable, starting fresh: $_" -Level Warning
            Copy-Item $script:VAStatePath "$($script:VAStatePath).corrupt" -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($list in 'notifiedSessions', 'seenMalwareEvents', 'seenAuthEvents', 'analyzerViolations') {
        $state[$list] = @($state[$list] | Where-Object { $_ })
    }
    if ($null -eq $state.repositoryLevels) { $state.repositoryLevels = [ordered]@{} }
    if ($null -eq $state.digests) { $state.digests = [ordered]@{} }
    foreach ($k in 'repositorySpace', 'digestAnalyzer', 'flapping') { if ($state[$k] -isnot [System.Collections.IDictionary]) { $state[$k] = [ordered]@{} } }
    foreach ($fp in @($state.flapping.Keys)) {
        $f = $state.flapping[$fp]
        if ($f -isnot [System.Collections.IDictionary]) { $state.flapping.Remove($fp); continue }
        $f['changes'] = @($f['changes'] | Where-Object { $_ } | ForEach-Object { ConvertTo-VAIsoString $_ })
        $f['since'] = ConvertTo-VAIsoString $f['since']
        $f['flapping'] = [bool]$f['flapping']
    }
    foreach ($id in @($state.repositorySpace.Keys)) {
        foreach ($r in @($state.repositorySpace[$id])) { if ($r -and $r['d'] -is [datetime]) { $r['d'] = $r['d'].ToString('yyyy-MM-dd') } }
    }
    # ConvertFrom-Json turns ISO timestamps into DateTime; keep them as ISO-8601 UTC strings.
    foreach ($k in @($state.digests.Keys)) { $state.digests[$k] = ConvertTo-VAIsoString $state.digests[$k] }
    foreach ($k in 'lastWatchUtc', 'sessionsSeenUtc', 'malwareHighWaterUtc') { $state[$k] = ConvertTo-VAIsoString $state[$k] }
    $state.health = ConvertTo-VAHealthState $state.health
    # Pre-release builds kept one digest marker; it belongs to the "daily" digest that config migration creates.
    if ($state.Contains('lastDigestUtc')) {
        $v = ConvertTo-VAIsoString $state.lastDigestUtc
        if ($v -and -not $state.digests.Contains('daily')) { $state.digests['daily'] = $v }
        $state.Remove('lastDigestUtc')
    }
    return $state
}

function Write-VAState {
    param([Parameter(Mandatory)]$State)
    foreach ($list in 'notifiedSessions', 'seenMalwareEvents', 'seenAuthEvents') {
        $items = @($State[$list])
        if ($items.Count -gt $script:VAMaxRemembered) { $State[$list] = $items[-$script:VAMaxRemembered..-1] }
    }
    $dir = Split-Path -Parent $script:VAStatePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$($script:VAStatePath).tmp"
    $State | ConvertTo-Json -Depth 8 | Set-Content -Path $tmp -Encoding utf8NoBOM
    Move-Item -Path $tmp -Destination $script:VAStatePath -Force
}

function Update-VAState {
    <# Runs $ScriptBlock with the current state as $args[0] under the mutex, then saves it. Returns the block's output. #>
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock)
    $userBlock = $ScriptBlock   # Invoke-VAWithMutex has its own $ScriptBlock; avoid the dynamic-scope clash
    Invoke-VAWithMutex {
        $state = Read-VAState
        $out = & $userBlock $state
        Write-VAState $state
        $out
    }
}

function Test-VASessionNotified {
    param([Parameter(Mandatory)][string]$SessionId)
    return (Read-VAState).notifiedSessions -contains $SessionId
}

function Add-VANotifiedSession {
    <# Atomically claims a session id. Returns $false when another process already claimed it. #>
    param([Parameter(Mandatory)][string]$SessionId)
    Update-VAState {
        param($s)
        if ($s.notifiedSessions -contains $SessionId) { return $false }
        $s.notifiedSessions = @($s.notifiedSessions) + $SessionId
        return $true
    }
}

function Set-VADigestLastRun {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][datetimeoffset]$At)
    Update-VAState { param($s) $s.digests[$Name] = $At.ToString('o') } | Out-Null
}

function Remove-VANotifiedSession {
    <# Releases a claim when sending failed, so the watcher can retry. #>
    param([Parameter(Mandatory)][string]$SessionId)
    Update-VAState { param($s) $s.notifiedSessions = @($s.notifiedSessions | Where-Object { $_ -ne $SessionId }) } | Out-Null
}

# ---- Repository space history (for "full in ~N days") ------------------------------------------------------

function Add-VARepositoryReadings {
    <# Records today's free space for each repository (one reading per day, the latest wins; 35 days kept). #>
    param([object[]]$Infos, [datetimeoffset]$At = [datetimeoffset]::UtcNow)
    $infos = @($Infos | Where-Object { $_ -and $_.Id -and $null -ne $_.PercentFree })
    if (-not $infos) { return }
    $day = $At.UtcDateTime.ToString('yyyy-MM-dd')
    Update-VAState {
        param($s)
        foreach ($i in $infos) {
            $list = @($s.repositorySpace[$i.Id] | Where-Object { $_ -and "$($_['d'])" -ne $day })
            $list += [ordered]@{ d = $day; free = [Math]::Round([double]$i.FreeGB, 2); cap = [Math]::Round([double]$i.CapacityGB, 2) }
            $s.repositorySpace[$i.Id] = @($list | Sort-Object { "$($_['d'])" } | Select-Object -Last 35)
        }
    } | Out-Null
}

function Get-VARepositoryTrend {
    <#
    Least-squares trend of free space over the last 14 daily readings. Returns $null with fewer than 3 days of
    readings, else { PercentPerDay (negative = filling up), DaysToFull ($null when not filling) }.
    #>
    param([Parameter(Mandatory)]$Info, $State)
    if (-not $State) { $State = Read-VAState }
    $r = @($State.repositorySpace[$Info.Id] | Where-Object { $_ } | Sort-Object { "$($_['d'])" } | Select-Object -Last 14)
    if ($r.Count -lt 3) { return $null }
    $t0 = [datetime]::ParseExact("$($r[0]['d'])", 'yyyy-MM-dd', $null)
    $xs = @($r | ForEach-Object { ([datetime]::ParseExact("$($_['d'])", 'yyyy-MM-dd', $null) - $t0).TotalDays })
    $ys = @($r | ForEach-Object { [double]$_['free'] })
    $mx = ($xs | Measure-Object -Average).Average; $my = ($ys | Measure-Object -Average).Average
    $num = 0.0; $den = 0.0
    for ($k = 0; $k -lt $xs.Count; $k++) { $num += ($xs[$k] - $mx) * ($ys[$k] - $my); $den += [Math]::Pow($xs[$k] - $mx, 2) }
    if ($den -eq 0 -or -not $Info.CapacityGB) { return $null }
    $slope = $num / $den   # GB per day
    [pscustomobject]@{
        PercentPerDay = [Math]::Round(100 * $slope / [double]$Info.CapacityGB, 2)
        DaysToFull    = if ($slope -lt -0.01) { [int][Math]::Floor([double]$Info.FreeGB / -$slope) } else { $null }
    }
}

function Add-VARepositoryTrendInfo {
    <# Adds Trend (Get-VARepositoryTrend) to repository info objects. #>
    param([object[]]$Infos, $State)
    if (-not $State) { $State = Read-VAState }
    foreach ($i in @($Infos | Where-Object { $_ })) {
        $i | Add-Member -NotePropertyName Trend -NotePropertyValue (Get-VARepositoryTrend -Info $i -State $State) -Force
    }
}
