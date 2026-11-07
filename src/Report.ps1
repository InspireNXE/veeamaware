# Target-neutral reports. Every notification is described once as a report (what to show, in what order);
# each target type renders it its own way: Discord embeds, a Teams Adaptive Card, plain text...
#
# Report schema "veeamaware.report/v1" (also sent to generic webhooks as event.report):
#   header    what kind of report ("Backup job", "Repository"); renderers usually add the server name
#   server    the VBR server that sent it
#   title     the subject (job, machine or repository name)
#   status    success | warning | failed | info | security     (drives colour and badge)
#   color     "#RRGGBB" for the status
#   icon      emoji for the status line;  label  the status word ("SUCCESS", "LOW ON SPACE")
#   summary   parts that follow the label on the status line (see "Parts" below)
#   quotes    what went wrong: [{ title?, icon?, text }]
#   gauge     one repository shown under the status line (alerts): { Name, PercentFree, FreeGB, CapacityGB, Online }
#   note      small print under everything else
#   facts     the stat grid: [{ name, value }]  (value is a part or a list of parts)
#   sections  [{ type, title, icon?, color?, ... }]
#               objects       rows [{ status, name, size, duration }], more, repository?  (an aligned table)
#               list          items [{ status, icon?, name, parts, children [{ status, name, text }], more }]
#               repositories  items [repository]
#   timestamp ISO-8601 time the report is about
#
# Parts: a string, { time, style, prefix? } or { from, to, fromStyle, toStyle }. Styles: t (time), f (date and
# time), R (relative). Renderers format times for their medium; Format-VAParts does the joining.
# Statuses inside rows and items are Veeam results (Success, Warning, Failed, None); Get-VAStatusInfo maps them.

function Get-VAFooter {
    <# The server name lives in each report's header line, so the footer is just the version. #>
    param([string]$Extra)
    $f = "VeeamAware v$script:VAVersion"
    if ($Extra) { $f += " · $Extra" }
    return $f
}

function Get-VAAuthorLine {
    <# Small capitals line above every title: what kind of report this is, and which server sent it. #>
    param([Parameter(Mandatory)][string]$Kind, [string]$Server = $env:COMPUTERNAME)
    "$($Kind.ToUpperInvariant()) · $Server"
}

function Get-VAReportStatus {
    <# Veeam result -> report status (also the badge name). #>
    param([AllowNull()][string]$Result)
    switch -Regex ($Result) { '^Success' { 'success' } '^Warning' { 'warning' } '^Fail' { 'failed' } default { 'info' } }
}

function Get-VAMentionKind {
    param([string]$Result)
    switch -Regex ($Result) { '^Fail' { 'Failure' } '^Warning' { 'Warning' } '^Success' { 'Success' } default { $null } }
}

function ConvertTo-VAHexColor { param([int]$Color) '#{0:X6}' -f $Color }
function ConvertFrom-VAHexColor {
    param([AllowNull()][string]$Color, [int]$Default = 0x95A5A6)
    if ("$Color" -match '^#?([0-9A-Fa-f]{6})$') { return [Convert]::ToInt32($Matches[1], 16) }
    return $Default
}

function ConvertTo-VAIsoTime {
    param([AllowNull()]$Date)
    $d = ConvertTo-VADate $Date
    if ($null -eq $d) { return $null }
    $d.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}

# ---- Parts ----------------------------------------------------------------------------------------------

function New-VATimePart {
    param([AllowNull()]$Date, [ValidateSet('t', 'f', 'R')][string]$Style = 'f', [string]$Prefix)
    $iso = ConvertTo-VAIsoTime $Date
    if (-not $iso) { return $null }
    $p = [ordered]@{ time = $iso; style = $Style }
    if ($Prefix) { $p.prefix = $Prefix }
    return $p
}

function New-VARangePart {
    param([AllowNull()]$From, [AllowNull()]$To, [ValidateSet('t', 'f')][string]$FromStyle = 't', [ValidateSet('t', 'f')][string]$ToStyle = 't')
    $f = ConvertTo-VAIsoTime $From; $t = ConvertTo-VAIsoTime $To
    if (-not $f -or -not $t) { return $null }
    [ordered]@{ from = $f; to = $t; fromStyle = $FromStyle; toStyle = $ToStyle }
}

function New-VAHistoryPart {
    <# A run-history strip: Veeam results oldest -> newest ($null = no run that day), then optional text. #>
    param([AllowEmptyCollection()][object[]]$Results, [string]$Text)
    if (-not @($Results).Count) { return $null }
    $p = [ordered]@{ history = @($Results | ForEach-Object { if ($_) { "$_" } else { $null } }) }
    if ($Text) { $p.text = $Text }
    return $p
}

function Format-VAHistoryStrip {
    <# emoji: 🟩🟨🟥⬛ (Discord/Teams text)   ansi: coloured ■ for Discord code blocks   text: ✔▲✖· #>
    param([AllowEmptyCollection()][object[]]$Results, [ValidateSet('emoji', 'ansi', 'text')][string]$Style = 'emoji')
    if ($Style -eq 'ansi') {
        # One colour code per run of equal results, not per square: Discord counts the escape codes towards
        # the 1024-character field limit, and per-square codes made a 10-job table spill into a second field.
        $sb = [System.Text.StringBuilder]::new(); $prev = -1
        foreach ($r in @($Results)) {
            $k = switch -Regex ("$r") { '^Success' { 0 } '^Warning' { 1 } '^Fail' { 2 } default { 3 } }
            if ($k -ne $prev) {
                if ($prev -ge 0) { [void]$sb.Append("$([char]27)[0m") }
                [void]$sb.Append("$([char]27)[2;$(@(32, 33, 31, 30)[$k])m"); $prev = $k
            }
            [void]$sb.Append(@('■', '■', '■', '·')[$k])
        }
        if ($prev -ge 0) { [void]$sb.Append("$([char]27)[0m") }
        return $sb.ToString()
    }
    $out = foreach ($r in @($Results)) {
        $k = switch -Regex ("$r") { '^Success' { 0 } '^Warning' { 1 } '^Fail' { 2 } default { 3 } }
        switch ($Style) {
            'emoji' { @('🟩', '🟨', '🟥', '⬛')[$k] }
            'text' { @('✔', '▲', '✖', '·')[$k] }
            'ansi' { $c = @(32, 33, 31, 30)[$k]; "$([char]27)[2;${c}m$(@('■', '■', '■', '·')[$k])$([char]27)[0m" }
        }
    }
    return (@($out) -join '')
}

function Format-VAPart {
    <#
    One part as text. $Time formats a time: param([datetimeoffset]$Date, [string]$Style). $History formats a
    strip: param([string[]]$Results) (default: emoji squares).
    #>
    param($Part, [scriptblock]$Time, [scriptblock]$History)
    if ($null -eq $Part) { return $null }
    if (-not $Time) { $Time = { param($d, $s) if ($s -eq 't') { $d.ToString('HH:mm') + ' UTC' } else { $d.ToString('yyyy-MM-dd HH:mm') + ' UTC' } } }
    if (-not $History) { $History = { param($r) Format-VAHistoryStrip $r 'emoji' } }
    if ($Part -is [System.Collections.IDictionary]) {
        if ($Part.Contains('history')) { return ("$(& $History $Part['history']) $($Part['text'])").Trim() }
        if ($Part.Contains('from')) {
            return "$(& $Time (ConvertTo-VADate $Part['from']) $Part['fromStyle']) → $(& $Time (ConvertTo-VADate $Part['to']) $Part['toStyle'])"
        }
        if ($Part.Contains('time')) { return "$($Part['prefix'])$(& $Time (ConvertTo-VADate $Part['time']) $Part['style'])" }
        if ($Part.Contains('text')) { return "$($Part['text'])" }
    }
    return "$Part"
}

function Format-VAParts {
    param([AllowNull()][object[]]$Parts, [scriptblock]$Time, [string]$Separator = ' · ', [scriptblock]$History)
    if ($null -eq $Parts) { return '' }
    $out = foreach ($p in $Parts) { $t = Format-VAPart $p $Time $History; if ($t) { $t } }
    return (@($out) -join $Separator)
}

function Get-VAItemIcon {
    <# The emoji for a list item or row: its own icon, else the one for its Veeam result. #>
    param($Item)
    if ($Item -is [System.Collections.IDictionary] -and $Item['icon']) { return $Item['icon'] }
    (Get-VAStatusInfo $Item['status']).Emoji
}

function Format-VASpaceRatio {
    <# "3.11/5.36 TB": free and total in the total's unit, free with as few digits as stay readable. #>
    param($Info)
    $total = Format-VASize ([double]$Info.CapacityGB * 1GB)
    $unit = ($total -split ' ')[-1]
    $div = @{ B = 1; KB = 1KB; MB = 1MB; GB = 1GB; TB = 1TB; PB = 1PB }[$unit]
    $f = [double]$Info.FreeGB * 1GB / $div
    $free = ($(if ($f -ge 100) { '{0:0}' } elseif ($f -ge 10) { '{0:0.#}' } else { '{0:0.##}' }) -f $f).Replace(',', '.')
    "$free/$total"
}

# ---- Report construction ----------------------------------------------------------------------------------

function New-VAReport {
    param(
        [Parameter(Mandatory)][string]$Header,
        [Parameter(Mandatory)][string]$Title,
        [ValidateSet('success', 'warning', 'failed', 'info', 'security')][string]$Status = 'info',
        [string]$Icon,
        [string]$Label,
        [int]$Color = -1,
        [object[]]$Summary = @(),
        [object[]]$Quotes = @(),
        $Gauge,
        [string]$Note,
        [object[]]$Facts = @(),
        [object[]]$Sections = @(),
        $Timestamp
    )
    if ($Color -lt 0) {
        $Color = switch ($Status) { 'success' { 0x23A55A } 'warning' { 0xF0B232 } 'failed' { 0xF23F43 } 'security' { 0x9B59B6 } default { 0x5865F2 } }
    }
    $ts = ConvertTo-VAIsoTime $Timestamp
    [ordered]@{
        schema    = 'veeamaware.report/v1'
        header    = $Header
        server    = $env:COMPUTERNAME
        title     = $Title
        status    = $Status
        color     = ConvertTo-VAHexColor $Color
        icon      = $Icon
        label     = $Label
        summary   = @($Summary | Where-Object { $null -ne $_ -and "$_" -ne '' })
        quotes    = @($Quotes | Where-Object { $_ })
        gauge     = $Gauge
        note      = $Note
        facts     = @($Facts | Where-Object { $_ })
        sections  = @($Sections | Where-Object { $_ })
        timestamp = if ($ts) { $ts } else { ConvertTo-VAIsoTime ([datetimeoffset]::UtcNow) }
    }
}

function New-VAFact {
    <# A stat-grid entry, or $null when there is nothing to show (renderers never see empty facts). #>
    param([Parameter(Mandatory)][string]$Name, [AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return $null }
    [ordered]@{ name = $Name; value = $Value }
}

function ConvertTo-VAPlainText {
    <#
    .SYNOPSIS
    Renders a report as plain text (UTC times, no markup), for targets such as SMS, e-mail or log files.
    #>
    param([Parameter(Mandatory)]$Report, [int]$MaxItems = 25)
    $r = $Report
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine((Get-VAAuthorLine $r.header $r.server))
    [void]$sb.AppendLine($r.title)
    $line = "$($r.label)"
    $hs = { param($h) Format-VAHistoryStrip $h 'text' }
    $sum = Format-VAParts $r.summary -History $hs
    if ($sum) { $line += " · $sum" }
    [void]$sb.AppendLine($line)
    foreach ($q in $r.quotes) {
        $head = (@($q['title']; (Format-VAParts $q['parts'])) | Where-Object { $_ }) -join ' '
        [void]$sb.AppendLine("  > $((@($head; $q['text']) | Where-Object { $_ }) -join ': ')")
    }
    if ($r.gauge -and $null -ne $r.gauge.PercentFree) { [void]$sb.AppendLine("  $($r.gauge.Name): $([Math]::Round($r.gauge.PercentFree))% free ($(Format-VASpaceRatio $r.gauge))") }
    foreach ($f in $r.facts) { [void]$sb.AppendLine("  $($f['name']): $(Format-VAParts @($f['value']))") }
    foreach ($sec in $r.sections) {
        [void]$sb.AppendLine().AppendLine("$($sec['title'])")
        $rows = switch ($sec['type']) {
            'objects' { @($sec['rows'] | ForEach-Object { "  [$($_['status'])] $($_['name'])$(if ($_['size']) { " · $($_['size'])" })$(if ($_['message']) { " — $($_['message'])" })" }) }
            'repositories' { @($sec['items'] | ForEach-Object { "  $($_.Name): $(if ($null -ne $_.PercentFree) { "$([Math]::Round($_.PercentFree))% free ($(Format-VASpaceRatio $_))" } else { 'capacity not reported' })$(if ($tr = Format-VARepositoryTrend $_) { " · $tr" })" }) }
            'history' {
                @($sec['rows'] | ForEach-Object { "  $(Format-VAHistoryStrip $_['history'] 'text') $($_['name']) · $($_['runs']) run(s)$(if ($_['size']) { " · $($_['size'])" })" })
                if ($sec['rollup']) { "  $(Format-VAHistoryStrip $sec['rollup']['history'] 'text') $($sec['rollup']['count']) other jobs · all OK" }
            }
            'text' { @($sec['lines'] | ForEach-Object { "  $(Format-VAParts @($_))" }) }
            default {
                @(foreach ($it in $sec['items']) {
                        "  [$($it['status'])] $($it['name'])$(if ($p = Format-VAParts $it['parts']) { " · $p" })"
                        foreach ($c in @($it['children'])) { "    [$($c['status'])] $($c['name'])$(if ($c['text']) { " — $($c['text'])" })" }
                    })
            }
        }
        foreach ($x in ($rows | Select-Object -First $MaxItems)) { [void]$sb.AppendLine($x) }
        $more = [int]$sec['more'] + [Math]::Max(0, @($rows).Count - $MaxItems)
        if ($more) { [void]$sb.AppendLine("  …and $more more") }
        if ($sec['type'] -eq 'objects' -and $sec['repository']) { [void]$sb.AppendLine("  Repository $($sec['repository'].Name): $([Math]::Round($sec['repository'].PercentFree))% free ($(Format-VASpaceRatio $sec['repository']))") }
    }
    if ($r.note) { [void]$sb.AppendLine().AppendLine($r.note) }
    return ($sb.ToString() -replace "`r`n", "`n").TrimEnd()
}

# ---- Session data -------------------------------------------------------------------------------------------

function Get-VASessionSummary {
    <# Collapses a session, its task sessions and its log into one flat object used by the report builders. #>
    param([Parameter(Mandatory)]$Session, [object[]]$TaskSessions = @(), [object[]]$Log = @())
    $start = ConvertTo-VADate (Get-VAProp $Session 'creationTime')
    $end = ConvertTo-VADate (Get-VAProp $Session 'endTime')
    $duration = if ($start -and $end) { $end - $start } else { $null }

    $tasks = foreach ($t in $TaskSessions) {
        $p = Get-VAProp $t 'progress'
        [pscustomobject]@{
            Name        = "$(Get-VAProp $t 'name' (Get-VAProp $t 'objectName' '(unnamed)'))"
            Result      = "$(Get-VAProp $t 'result.result' (Get-VAProp $t 'result' 'None'))"
            Message     = "$(Get-VAProp $t 'result.message' '')".Trim()
            Processed   = Get-VAProp $p 'processedSize'
            Read        = Get-VAProp $p 'readSize'
            Transferred = Get-VAProp $p 'transferredSize'
            Rate        = Get-VAProp $p 'processingRate'
            Bottleneck  = "$(Get-VAProp $p 'bottleneck' '')"
            Duration    = ConvertTo-VATimeSpan (Get-VAProp $p 'duration')
        }
    }
    $tasks = @($tasks)

    # Session-level totals win when the data source provides them (PowerShell does; per-object figures can be
    # zero for agent jobs). Otherwise sum the objects (REST).
    $sp = Get-VAProp $Session 'progress'
    $sum = {
        param($prop, $sessionProp)
        $own = Get-VAProp $sp $sessionProp
        if ($null -ne $own -and [double]$own -gt 0) { return [double]$own }
        $vals = @($tasks | ForEach-Object { $_.$prop } | Where-Object { $null -ne $_ })
        # Note: "if ($vals)" would be false for @(0); test the count. All-zero sums report as "no data",
        # because Veeam leaves these at 0 when it does not track them (agent jobs).
        if ($vals.Count) { $t = ($vals | Measure-Object -Sum).Sum; if ($t -gt 0) { $t } else { $null } } else { $null }
    }
    $processed = & $sum 'Processed' 'processedSize'
    $rate = Get-VAProp $sp 'processingRate'
    if (-not $rate -and $processed -and $duration -and $duration.TotalSeconds -gt 0) { $rate = $processed / $duration.TotalSeconds }
    $stats = Get-VAProp $Session 'backupStats'
    $ratio = { param($pct) if ($pct -and [double]$pct -gt 0 -and [double]$pct -lt 100) { [Math]::Round(100 / [double]$pct, 1) } else { $null } }

    # "Primary bottleneck: Source" is written to the session log; fall back to the most common task bottleneck.
    $bottleneck = $null
    foreach ($r in $Log) {
        if ("$(Get-VAProp $r 'title')" -match 'Primary bottleneck:\s*(\S.*)$') { $bottleneck = $Matches[1].Trim() }
    }
    if (-not $bottleneck) { $b = "$(Get-VAProp $sp 'bottleneck' '')"; if ($b) { $bottleneck = $b } }
    if (-not $bottleneck) {
        $bottleneck = $tasks | Where-Object { $_.Bottleneck -and $_.Bottleneck -ne 'None' } |
            Group-Object Bottleneck | Sort-Object Count -Descending | Select-Object -First 1 -ExpandProperty Name
    }

    $problemLog = @($Log | Where-Object { "$(Get-VAProp $_ 'status')" -match 'Warning|Fail|Error' } | ForEach-Object {
            [pscustomobject]@{ Status = "$(Get-VAProp $_ 'status')"; Title = "$(Get-VAProp $_ 'title')".Trim() }
        } | Where-Object Title)

    [pscustomobject]@{
        Id          = "$(Get-VAProp $Session 'id')"
        JobId       = "$(Get-VAProp $Session 'jobId')"
        Name        = "$(Get-VAProp $Session 'name' 'Unknown job')"
        Type        = "$(Get-VAProp $Session 'sessionType')"
        TypeName    = Get-VAFriendlyType (Get-VAProp $Session 'sessionType')
        Result      = "$(Get-VAProp $Session 'result.result' 'None')"
        Message     = "$(Get-VAProp $Session 'result.message' '')".Trim()
        Canceled    = [bool](Get-VAProp $Session 'result.isCanceled' $false)
        Retry       = [bool](Get-VAProp $Session 'isRetry' $false)
        Start       = $start
        End         = $end
        Duration    = $duration
        Processed   = $processed
        Read        = & $sum 'Read' 'readSize'
        Transferred = & $sum 'Transferred' 'transferredSize'
        Rate        = $rate
        BackupSize  = Get-VAProp $stats 'backupSize'
        Dedupe      = & $ratio (Get-VAProp $stats 'dedupRatio')
        Compression = & $ratio (Get-VAProp $stats 'compressRatio')
        Bottleneck  = $bottleneck
        Tasks       = $tasks
        ProblemLog  = $problemLog
    }
}

function Add-VASessionContext {
    <#
    .SYNOPSIS
    Adds what a report needs beyond the session itself, all optional (a lookup that fails is just left out):
      problems -> LastSuccess (end time of the job's previous successful run) and FailStreak (runs in a row,
                  this one included, that did not succeed)
      success  -> Repository (Get-VARepositoryInfo of the job's target repository)
    #>
    param([Parameter(Mandatory)]$Summary)
    $s = $Summary
    $hasJob = $s.JobId -and $s.JobId -ne '00000000-0000-0000-0000-000000000000'
    $raw = if ($hasJob) { Test-VARestOptional -What 'job history' { @(Get-VAJobHistory -JobId $s.JobId -Count 30) } }
    Add-VAHistoryContext -Summary $s -History $raw | Out-Null
    $repos = @(Test-VARestOptional -What 'repository states' { Get-VARepositoryStates }) | Where-Object { $_ }
    if (-not $repos) { return $s }
    $repoId = if ($hasJob) { Test-VARestOptional -What 'job repository' { Get-VAJobRepositoryId -JobId $s.JobId } } else { '' }
    $repo = if ($repoId) { $repos | Where-Object { "$($_.id)" -eq "$repoId" } | Select-Object -First 1 }
    if (-not $repo -and $repos.Count -eq 1) { $repo = $repos[0] }   # single-repository servers need no mapping
    if ($repo) {
        $info = Get-VARepositoryInfo $repo
        try { Add-VARepositoryTrendInfo -Infos @($info) } catch { Write-VALog "Repository trend unavailable: $($_.Exception.Message)" -Level Debug }
        $s.Repository = $info
    }
    return $s
}

function Add-VAHistoryContext {
    <#
    Adds history-derived facts to a summary from Get-VAJobHistory output ($null = unknown):
      HistoryKnown, Recent (last 7 results incl. this run, oldest first), FailStreak, LastSuccess,
      Recovered + DownFor (this success ends a run of failures), UsualTransferred / UsualDuration (medians of
      recent successful runs; $null with fewer than 3).
    #>
    param([Parameter(Mandatory)]$Summary, [AllowNull()][object[]]$History)
    $s = $Summary
    foreach ($n in 'LastSuccess', 'DownFor', 'UsualTransferred', 'UsualDuration', 'Repository') { if (-not $s.PSObject.Properties[$n]) { $s | Add-Member -NotePropertyName $n -NotePropertyValue $null -Force } }
    $s | Add-Member -NotePropertyName FailStreak -NotePropertyValue 0 -Force
    $s | Add-Member -NotePropertyName HistoryKnown -NotePropertyValue $false -Force
    $s | Add-Member -NotePropertyName Recovered -NotePropertyValue $false -Force
    $s | Add-Member -NotePropertyName Recent -NotePropertyValue @() -Force
    if ($null -eq $History) { return $s }
    $s.HistoryKnown = $true
    $hist = @($History | Where-Object { $_ -and "$($_.id)" -ne $s.Id })   # newest first
    $prior = @($hist | Select-Object -First 6 | ForEach-Object { "$($_.result)" })
    [array]::Reverse($prior)
    $s.Recent = @($prior) + @($s.Result)

    $streak = if ($s.Result -match '^Fail') { 1 } else { 0 }
    $counting = $streak -gt 0
    $firstBad = $null
    foreach ($h in $hist) {
        if ("$($h.result)" -match '^Success') { $s.LastSuccess = ConvertTo-VADate $h.endTime; break }
        $firstBad = $h
        if ($counting -and "$($h.result)" -match '^Fail') { $streak++ } else { $counting = $false }
    }
    $s.FailStreak = $streak
    if ($s.Result -match '^Success' -and $firstBad) {
        $s.Recovered = $true
        $since = ConvertTo-VADate $firstBad.endTime
        if ($since -and $s.End) { $s.DownFor = $s.End - $since }
    }

    $ok = @($hist | Where-Object { "$($_.result)" -match '^Success' } | Select-Object -First 10)
    $median = { param($v) $v = @($v | Sort-Object); if ($v.Count -lt 3) { $null } else { $v[[int][Math]::Floor($v.Count / 2)] } }
    $s.UsualTransferred = & $median @($ok | ForEach-Object { Get-VAProp $_ 'transferredBytes' } | Where-Object { $_ -and [double]$_ -gt 0 } | ForEach-Object { [double]$_ })
    $s.UsualDuration = & $median @($ok | ForEach-Object {
            $a = ConvertTo-VADate (Get-VAProp $_ 'startTime'); $b = ConvertTo-VADate (Get-VAProp $_ 'endTime')
            if ($a -and $b -and $b -gt $a) { ($b - $a).TotalSeconds }
        })
    return $s
}

function Format-VAOrdinal { param([int]$N) $suf = if ($N % 100 -in 11..13) { 'th' } else { @('th', 'st', 'nd', 'rd', 'th', 'th', 'th', 'th', 'th', 'th')[$N % 10] }; "$N$suf" }

function Format-VAUsualDelta {
    <# "▲ 6× usual" / "▼ 15% of usual" when the value is far from usual, else $null. #>
    param([double]$Value, [AllowNull()]$Usual, [double]$Ratio = 3, [double]$MinDiff = 0)
    if ($null -eq $Usual -or [double]$Usual -le 0 -or $Value -le 0) { return $null }
    $r = $Value / [double]$Usual
    if ([Math]::Abs($Value - [double]$Usual) -lt $MinDiff) { return $null }
    if ($r -ge $Ratio) { return "▲ $([Math]::Round($r, $(if ($r -lt 10) { 1 } else { 0 })))× usual" }
    if ($r -le 1 / $Ratio) { return "▼ $([Math]::Round(100 * $r))% of usual" }
    return $null
}

function Format-VARepositoryTrend {
    <# "−0.4%/day · full in ~9 days" from Info.Trend, or $null. #>
    param($Info)
    $t = if ($Info -and $Info.PSObject.Properties['Trend']) { $Info.Trend }
    if (-not $t) { return $null }
    $pct = [double]$t.PercentPerDay
    $bits = @(if ([Math]::Abs($pct) -ge 0.05) { "$(if ($pct -lt 0) { '−' } else { '+' })$([Math]::Abs($pct).ToString('0.#', [cultureinfo]::InvariantCulture))%/day" } else { 'steady' })
    if ($null -ne $t.DaysToFull -and $t.DaysToFull -le 90) { $bits += "full in ~$($t.DaysToFull) day$(if ($t.DaysToFull -ne 1) { 's' })" }
    return ($bits -join ' · ')
}

function Get-VARepositoryInfo {
    param([Parameter(Mandatory)]$Repo)
    $cap = [double](Get-VAProp $Repo 'capacityGB' 0)
    $free = [double](Get-VAProp $Repo 'freeGB' 0)
    $used = Get-VAProp $Repo 'usedSpaceGB'
    $online = Get-VAProp $Repo 'isOnline' (Get-VAProp $Repo 'isAvailable' $true)
    [pscustomobject]@{
        Id          = "$(Get-VAProp $Repo 'id')"
        Name        = "$(Get-VAProp $Repo 'name' 'Unnamed repository')"
        Type        = "$(Get-VAProp $Repo 'type' '')"
        CapacityGB  = $cap
        FreeGB      = $free
        UsedGB      = if ($null -ne $used) { [double]$used } else { $cap - $free }
        PercentFree = if ($cap -gt 0) { [Math]::Round(100 * $free / $cap, 1) } else { $null }
        Online      = [bool]$online
    }
}

function Get-VARepositoryLevel {
    param([Parameter(Mandatory)]$Info, [Parameter(Mandatory)]$RepoConfig)
    if (-not $Info.Online) { return 'offline' }
    if ($null -eq $Info.PercentFree) { return 'ok' }   # object storage / unknown capacity
    if ($Info.PercentFree -le [double]$RepoConfig.criticalPercentFree) { return 'critical' }
    if ($Info.PercentFree -le [double]$RepoConfig.warnPercentFree) { return 'warning' }
    return 'ok'
}

# ---- Report builders ----------------------------------------------------------------------------------------

function New-VASessionReport {
    <#
    .SYNOPSIS
    The per-job report. Same shape for every result so the eye always lands in the same place:
      header (job type) / title (job) / status line / what went wrong / stats / objects
    Stats depend on the result: success shows the six throughput figures, a warning the three that explain it,
    a failure the job's recent history (last success, failures in a row).
    #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Summary)
    $s = $Summary
    $st = Get-VAStatusInfo $s.Result
    $n = $Config.notifications
    $isOk = $s.Result -match '^Success'
    $isFail = $s.Result -match '^Fail'
    $problems = @($s.Tasks | Where-Object Result -notmatch '^Success')

    $recovered = [bool](Get-VAProp $s 'Recovered' $false)
    $recent = @(Get-VAProp $s 'Recent' @())
    $streak = [int](Get-VAProp $s 'FailStreak' 0)
    $stripText = if ($isFail -and $streak -ge 2) { "$(Format-VAOrdinal $streak) failure in a row" }
    elseif ($recovered -and (Get-VAProp $s 'DownFor')) { "down $(Format-VADuration $s.DownFor)" }
    elseif ($recent.Count -gt 1) { "last $($recent.Count) runs" }
    $summary = @(
        if ($s.Start -and $s.End) { New-VARangePart $s.Start $s.End } elseif ($s.Start) { New-VATimePart $s.Start 't' 'started ' }
        if ($s.Duration) { Format-VADuration $s.Duration }
        if ($recent.Count -gt 1) { New-VAHistoryPart $recent $stripText }
        if ($problems.Count -and $s.Tasks.Count) { "$($problems.Count) of $($s.Tasks.Count) objects" }
        if ($s.Canceled) { 'stopped by user' }
        if ($s.Retry) { 'retry' }
    )

    # What went wrong: object errors first, else the session log's warnings/errors, else the session message.
    $quotes = [System.Collections.Generic.List[object]]::new()
    $note = $null
    if (-not $isOk) {
        $withMsg = @($problems | Where-Object Message)
        foreach ($t in ($withMsg | Select-Object -First 3)) {
            $quotes.Add([ordered]@{ title = $t.Name; text = Limit-VAText ($t.Message -replace '\s+', ' ') 400 })
        }
        if (-not $quotes.Count -and $s.ProblemLog.Count -and [int]$n.maxLogLines -gt 0) {
            foreach ($l in ($s.ProblemLog | Select-Object -Last ([int]$n.maxLogLines))) {
                $quotes.Add([ordered]@{ icon = $(if ($l.Status -match 'Warning') { '⚠️' } else { '❌' }); text = Limit-VAText ($l.Title -replace '\s+', ' ') 200 })
            }
        }
        if (-not $quotes.Count -and $s.Message) { $quotes.Add([ordered]@{ text = Limit-VAText ($s.Message -replace '\s+', ' ') 600 }) }
        if ($withMsg.Count -gt 3) { $note = "…and $($withMsg.Count - 3) more object(s) with messages below" }
    }

    $size = { param($v) if ($v -gt 0) { Format-VASize $v } }
    # Transferred and duration are compared with the job's usual successful run: a sudden jump in changed
    # data is worth a look (mass encryption shows up this way), and so is a run that took far longer.
    $xfer = if ($s.Transferred -gt 0) {
        @((Format-VASize $s.Transferred); (Format-VAUsualDelta $s.Transferred (Get-VAProp $s 'UsualTransferred') 3 256MB))
    }
    $usualDur = Get-VAProp $s 'UsualDuration'
    $dur = if ($s.Duration) {
        $delta = Format-VAUsualDelta $s.Duration.TotalSeconds $usualDur 2 300
        @((Format-VADuration $s.Duration); $(if ($delta) { $delta } elseif ($usualDur) { "usual $(Format-VADuration ([timespan]::FromSeconds($usualDur)))" }))
    }
    $facts = if ($isOk) {
        @(
            New-VAFact 'Transferred' $xfer
            New-VAFact 'Duration' $dur
            New-VAFact 'Speed' $(if ($s.Rate -gt 0) { Format-VARate $s.Rate })
            New-VAFact 'Processed' (& $size $s.Processed)
            if ($s.Compression) { New-VAFact 'Compression' "$($s.Compression)×" } else { New-VAFact 'Dedupe' $(if ($s.Dedupe) { "$($s.Dedupe)×" }) }
            New-VAFact 'Bottleneck' $s.Bottleneck
        )
    }
    elseif ($isFail) {
        $known = [bool](Get-VAProp $s 'HistoryKnown' $false)
        @(
            New-VAFact 'Last success' $(if (Get-VAProp $s 'LastSuccess') { New-VATimePart $s.LastSuccess 'R' } elseif ($known) { 'none in recent runs' })
            New-VAFact 'Transferred' $xfer
        )
    }
    else {
        @(
            New-VAFact 'Processed' (& $size $s.Processed)
            New-VAFact 'Transferred' $xfer
            New-VAFact 'Bottleneck' $s.Bottleneck
        )
    }

    # Objects (and, on success, the target repository) in one table section.
    $shown = @(switch ($n.objectDetail) { 'all' { $s.Tasks } 'problems' { $problems } })
    $max = [Math]::Max(1, [int]$n.maxObjects)
    $rows = @($shown | Select-Object -First $max | ForEach-Object {
            [ordered]@{
                status   = $_.Result
                name     = $_.Name
                size     = if ($_.Transferred -gt 0) { Format-VASize $_.Transferred } elseif ($_.Result -match '^Fail') { '0 B' } else { '' }   # 0 = not tracked (agents)
                duration = if ($_.Duration) { Format-VADuration $_.Duration } else { '' }
                message  = if ($_.Result -notmatch '^Success' -and $_.Message) { Limit-VAText ($_.Message -replace '\s+', ' ') 300 } else { $null }
            }
        })
    # The repository shows on success, and on any result when it is low on space (the likely cause).
    $repo = Get-VAProp $s 'Repository'
    if ($repo -and $null -eq $repo.PercentFree) { $repo = $null }
    if ($repo -and -not $isOk) {
        $rc = Get-VAProp $Config 'watch.repositories'
        $low = $rc -and (Get-VARepositoryLevel $repo $rc) -ne 'ok'
        $soon = $repo.PSObject.Properties['Trend'] -and $repo.Trend -and $null -ne $repo.Trend.DaysToFull -and $repo.Trend.DaysToFull -le 14
        if (-not ($low -or $soon)) { $repo = $null }
    }
    $sections = @()
    if ($rows.Count -or $repo) {
        $ok = $s.Tasks.Count - $problems.Count
        $label = if (-not $rows.Count) { 'Repository' } elseif ($s.Tasks.Count) { "Objects · $ok/$($s.Tasks.Count) OK" } else { 'Objects' }
        $sections += [ordered]@{ type = 'objects'; title = $label; rows = $rows; more = [Math]::Max(0, $shown.Count - $rows.Count); repository = $repo }
    }

    New-VAReport -Header "$($s.TypeName) job" -Title $s.Name -Status (Get-VAReportStatus $s.Result) -Icon $st.Emoji `
        -Label $(if ($recovered) { 'RECOVERED' } else { $st.Name.ToUpperInvariant() }) -Color $st.Color -Summary $summary -Quotes $quotes.ToArray() -Note $note `
        -Facts $facts -Sections $sections -Timestamp $(if ($s.End) { $s.End } else { [datetimeoffset]::UtcNow })
}

function New-VAMalwareReport {
    param([Parameter(Mandatory)]$Event)
    $machine = "$(Get-VAProp $Event 'machine.displayName' (Get-VAProp $Event 'machine.name' (Get-VAProp $Event 'machineName' 'Unknown machine')))"
    $detected = Get-VAProp $Event 'detectionTimeUtc' (Get-VAProp $Event 'detectionTime' (Get-VAProp $Event 'creationTime'))
    $details = "$(Get-VAProp $Event 'details' '')" -replace '\s+', ' '
    New-VAReport -Header 'Security alert' -Title $machine -Status security -Icon '🦠' -Label 'MALWARE DETECTED' `
        -Summary @(New-VATimePart $detected 'f') -Quotes @(if ($details) { [ordered]@{ text = Limit-VAText $details 900 } }) `
        -Note 'Review it under Inventory → Malware Detection before restoring from affected restore points.' `
        -Facts @(
            New-VAFact 'Type' (Get-VAFriendlyType "$(Get-VAProp $Event 'type' 'Unknown')")
            New-VAFact 'Severity' "$(Get-VAProp $Event 'severity' '')"
            New-VAFact 'Source' "$(Get-VAProp $Event 'source' (Get-VAProp $Event 'engine' ''))"
            New-VAFact 'State' "$(Get-VAProp $Event 'state' '')"
        ) -Timestamp $detected
}

function New-VARepositoryReport {
    param([Parameter(Mandatory)]$Info, [Parameter(Mandatory)][string]$Level, [string]$PreviousLevel = 'ok')
    $m = @{
        critical = @{ Icon = '❌'; Word = 'CRITICALLY LOW'; Status = 'failed' }
        warning  = @{ Icon = '⚠️'; Word = 'LOW ON SPACE'; Status = 'warning' }
        offline  = @{ Icon = '🔌'; Word = 'OFFLINE'; Status = 'failed' }
        ok       = @{ Icon = '✅'; Word = 'RECOVERED'; Status = 'success' }
    }[$Level]
    $known = $null -ne $Info.PercentFree
    New-VAReport -Header 'Repository' -Title $Info.Name -Status $m.Status -Icon $m.Icon -Label $m.Word `
        -Summary @("was $PreviousLevel"; (Format-VARepositoryTrend $Info)) -Gauge $(if ($known) { $Info }) -Note $(if (-not $known) { 'Capacity not reported for this repository.' }) `
        -Facts @(New-VAFact 'Type' $Info.Type) -Timestamp ([datetimeoffset]::UtcNow)
}

function New-VAAnalyzerReport {
    param([object[]]$NewViolations, [int]$TotalViolations, $LastRun)
    $c = @($NewViolations).Count
    New-VAReport -Header 'Security & Compliance Analyzer' -Title 'Best-practice violations' -Status security -Icon '🛡️' `
        -Label "$c NEW VIOLATION$(if ($c -ne 1) { 'S' })" -Summary @("$TotalViolations in total") `
        -Quotes @($NewViolations | ForEach-Object { [ordered]@{ icon = '❌'; text = Limit-VAText "$(Get-VAProp $_ 'bestPractice' (Get-VAProp $_ 'name' 'Unnamed check'))" 200 } }) `
        -Facts @(New-VAFact 'Run finished' (New-VATimePart (Get-VAProp $LastRun 'endTime' (Get-VAProp $LastRun 'creationTime')) 'R')) `
        -Timestamp ([datetimeoffset]::UtcNow)
}

function New-VAAuthorizationReport {
    param([Parameter(Mandatory)]$Event)
    $details = "$(Get-VAProp $Event 'description' (Get-VAProp $Event 'details' ''))" -replace '\s+', ' '
    New-VAReport -Header 'Four-eyes approval' -Title "$(Get-VAProp $Event 'name' (Get-VAProp $Event 'operation' 'Protected operation'))" `
        -Status info -Icon '🔐' -Label 'WAITING FOR APPROVAL' `
        -Summary @(New-VATimePart (Get-VAProp $Event 'creationTime' (Get-VAProp $Event 'createdTime')) 'R' 'requested ') `
        -Quotes @(if ($details) { [ordered]@{ text = Limit-VAText $details 900 } }) `
        -Note 'A second administrator must approve or reject it in the VBR console.' `
        -Facts @(
            New-VAFact 'Requested by' "$(Get-VAProp $Event 'initiatedBy' (Get-VAProp $Event 'createdBy' (Get-VAProp $Event 'userName' '')))"
            New-VAFact 'State' "$(Get-VAProp $Event 'state' '')"
            New-VAFact 'Expires' (New-VATimePart (Get-VAProp $Event 'expirationTime') 'R')
        ) -Timestamp ([datetimeoffset]::UtcNow)
}

function New-VATestReport {
    param([string]$SourceText)
    New-VAReport -Header 'Setup' -Title 'VeeamAware is connected' -Status success -Icon '✅' -Label 'CONNECTED' `
        -Summary @("reports from $env:COMPUTERNAME will appear here") -Note $(if ($SourceText) { "Data source: $SourceText" }) `
        -Timestamp ([datetimeoffset]::UtcNow)
}

function Get-VASum { param([object[]]$Items, [string]$Property) $t = 0.0; foreach ($i in @($Items)) { if ($i -and $null -ne $i.$Property) { $t += [double]$i.$Property } }; $t }

function New-VADigestReport {
    <#
    .SYNOPSIS
    One digest, problems first:
      title     what happened ("All 57 sessions succeeded", "2 jobs and 1 repository need attention")
      quotes    needs attention: failing / warning / recovered jobs, low repositories, malware events
      history   one row per job with a strip of the last $HistoryDays days; on a bad day the healthy jobs
                collapse into one "N other jobs" row
      storage   repositories with their bar and trend
      security  analyzer findings (compared with the previous digest) and malware events
    $AgentSummaries are Get-VASessionSummary objects (with tasks) for agent sessions in the window; $OtherSessions
    are raw sessions for every other job type in the window; $HistorySessions are raw sessions of the last
    $HistoryDays days (for the strips). Sections the digest leaves out arrive empty.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        $Digest,
        [Parameter(Mandatory)][datetimeoffset]$From,
        [Parameter(Mandatory)][datetimeoffset]$To,
        [object[]]$AgentSummaries = @(),
        [object[]]$OtherSessions = @(),
        [object[]]$Repositories = @(),
        [object[]]$MalwareEvents = @(),
        [int]$AnalyzerViolations = -1,
        [int]$PreviousAnalyzerViolations = -1,
        [object[]]$HistorySessions = @(),
        [int]$HistoryDays = 7
    )
    $rc = Get-VAProp $Config 'watch.repositories'
    $digestName = "$(Get-VAProp $Digest 'name' 'daily')"
    $kind = if ($digestName -match 'digest$') { $digestName } else { "$digestName digest" }

    # One record per session in the window.
    $runs = @(
        foreach ($a in $AgentSummaries) {
            [pscustomobject]@{ Id = $a.Id; Job = $a.Name; Agent = $true; Result = $a.Result; Start = $a.Start; End = $a.End
                Bytes = $(if ($a.BackupSize -gt 0) { [double]$a.BackupSize } elseif ($a.Transferred -gt 0) { [double]$a.Transferred } else { 0 })
                Duration = $a.Duration; Message = $a.Message; Tasks = @($a.Tasks) }
        }
        foreach ($o in $OtherSessions) {
            $st = ConvertTo-VADate (Get-VAProp $o 'creationTime'); $en = ConvertTo-VADate (Get-VAProp $o 'endTime')
            [pscustomobject]@{ Id = "$(Get-VAProp $o 'id')"; Job = "$(Get-VAProp $o 'name')"; Agent = $false; Result = "$(Get-VAProp $o 'result.result' 'None')"
                Start = $st; End = $en; Bytes = [double](Get-VAProp $o 'progress.transferredSize' 0)
                Duration = $(if ($st -and $en) { $en - $st }); Message = "$(Get-VAProp $o 'result.message' '')".Trim(); Tasks = @() }
        }
    )

    # Every known result per job (window + history), for the strips, failure streaks and last success.
    $hist = @{}
    $remember = {
        param($job, $id, $res, $end)
        if (-not $job -or -not $end) { return }
        if (-not $hist.ContainsKey($job)) { $hist[$job] = [System.Collections.Generic.Dictionary[string, object]]::new() }
        $hist[$job]["$id"] = [pscustomobject]@{ Result = "$res"; End = $end }
    }
    foreach ($h in $HistorySessions) { & $remember "$(Get-VAProp $h 'name')" "$(Get-VAProp $h 'id')" "$(Get-VAProp $h 'result.result' 'None')" (ConvertTo-VADate (Get-VAProp $h 'endTime')) }
    foreach ($r in $runs) { & $remember $r.Job $r.Id $r.Result $r.End }
    $today = $To.ToLocalTime().Date
    $days = @(for ($i = $HistoryDays - 1; $i -ge 0; $i--) { $today.AddDays(-$i) })
    $worst = {
        param([string[]]$r)
        if (@($r | Where-Object { $_ -match '^Fail' })) { 'Failed' } elseif (@($r | Where-Object { $_ -match '^Warning' })) { 'Warning' }
        elseif (@($r | Where-Object { $_ -match '^Success' })) { 'Success' } else { 'None' }
    }
    $stripOf = {
        param($job)
        $all = if ($hist.ContainsKey($job)) { @($hist[$job].Values) } else { @() }
        foreach ($d in $days) { & $worst @($all | Where-Object { $_.End.ToLocalTime().Date -eq $d } | ForEach-Object Result) }
    }

    $jobs = @(foreach ($g in ($runs | Group-Object Job)) {
            $rs = @($g.Group | Sort-Object End)
            $last = $rs[-1]
            $bad = @($rs | Where-Object { $_.Result -notmatch '^Success' })
            $machines = @(); $machinesBad = @()
            if ($last.Agent) {
                # A machine's state is its latest result in the window: failed overnight then fine = recovered.
                $machines = @(@(foreach ($r in $rs) { foreach ($t in $r.Tasks) { [pscustomobject]@{ T = $t; When = $r.Start } } }) |
                        Group-Object { $_.T.Name } | ForEach-Object { @($_.Group | Sort-Object When)[-1].T })
                $machinesBad = @($machines | Where-Object { $_.Result -notmatch '^Success' } | Sort-Object { if ($_.Result -match '^Fail') { 0 } else { 1 } }, Name)
            }
            $state = if ($machines.Count) {
                if (@($machinesBad | Where-Object Result -match '^Fail')) { 'Failed' } elseif ($machinesBad) { 'Warning' } elseif ($bad) { 'Recovered' } else { 'Success' }
            }
            else { if ($last.Result -match '^Fail') { 'Failed' } elseif ($last.Result -match '^Warning') { 'Warning' } elseif ($bad) { 'Recovered' } else { 'Success' } }
            $known = if ($hist.ContainsKey($g.Name)) { @($hist[$g.Name].Values | Sort-Object End -Descending) } else { @() }
            $streak = 0
            foreach ($k in $known) { if ($k.Result -match '^Fail') { $streak++ } else { break } }
            $okRun = @($known | Where-Object { $_.Result -match '^Success' } | Select-Object -First 1)
            [pscustomobject]@{
                Name = $g.Name; Agent = $last.Agent; Runs = $rs; Last = $last; Bad = $bad; State = $state
                Machines = $machines; MachinesBad = $machinesBad; Streak = $streak; LastOk = $(if ($okRun) { $okRun[0].End })
                Bytes = (Get-VASum $rs Bytes); Strip = @(& $stripOf $g.Name)
            }
        })

    # ---- Needs attention ----
    $quotes = [System.Collections.Generic.List[object]]::new()
    $order = @{ Failed = 0; Warning = 1; Recovered = 2 }
    $machineText = { param($list) (@($list | Select-Object -First 3 | ForEach-Object { "$($_.Name)$(if ($_.Message) { ": $(Limit-VAText ($_.Message -replace '\s+', ' ') 120)" })" }) -join ' · ') }
    foreach ($j in @($jobs | Where-Object State -ne 'Success' | Sort-Object { $order[$_.State] }, Name)) {
        $m = $j.Machines.Count
        $parts = switch ($j.State) {
            'Failed' {
                if ($m) { "$($j.MachinesBad.Count) of $m machine$(if ($m -ne 1) { 's' }) failing" }
                elseif ($j.Streak -ge 2) { "failed $($j.Streak) runs in a row" } else { 'failed' }
                if ($j.LastOk) { New-VATimePart $j.LastOk 'R' 'last success ' } else { "no success in $HistoryDays days" }
            }
            'Warning' { if ($m) { "$($j.MachinesBad.Count) of $m machine$(if ($m -ne 1) { 's' }) with warnings" } else { 'warning on the last run' } }
            'Recovered' { "$($j.Bad.Count) of $($j.Runs.Count) run$(if ($j.Runs.Count -ne 1) { 's' }) had issues, now recovered" }
        }
        $text = if ($j.MachinesBad) { & $machineText $j.MachinesBad }
        elseif ($j.State -eq 'Recovered' -and $j.Agent) { & $machineText @($j.Bad | ForEach-Object { $_.Tasks } | Where-Object { $_.Result -notmatch '^Success' }) }
        else { $msg = @($j.Bad | Where-Object Message | Select-Object -Last 1 | ForEach-Object Message); if ($msg) { Limit-VAText ($msg[0] -replace '\s+', ' ') 300 } }
        $quotes.Add([ordered]@{ icon = @{ Failed = '❌'; Warning = '⚠️'; Recovered = '🔁' }[$j.State]; title = $j.Name; parts = @($parts); text = $text })
    }
    $badRepos = 0; $critical = $false
    foreach ($repo in $Repositories) {
        $level = if ($rc) { Get-VARepositoryLevel $repo $rc } else { 'ok' }
        $t = if ($repo.PSObject.Properties['Trend']) { $repo.Trend }
        $soon = $t -and $null -ne $t.DaysToFull -and $t.DaysToFull -le 14
        if ($level -eq 'ok' -and -not $soon) { continue }
        $badRepos++
        if ($level -in 'critical', 'offline') { $critical = $true }
        $parts = @(
            if ($level -eq 'offline') { 'offline' } elseif ($null -ne $repo.PercentFree) { "$([Math]::Round($repo.PercentFree))% free" }
            if ($soon) { "full in about $($t.DaysToFull) day$(if ($t.DaysToFull -ne 1) { 's' }) at this rate" }
        )
        $quotes.Add([ordered]@{ icon = $(if ($level -in 'critical', 'offline') { '❌' } else { '⚠️' }); title = $repo.Name; parts = $parts })
    }
    foreach ($e in @($MalwareEvents | Select-Object -First 5)) {
        $quotes.Add([ordered]@{ icon = '🦠'; title = "$(Get-VAProp $e 'machine.displayName' (Get-VAProp $e 'machineName' 'Unknown'))"
                parts = @("malware: $(Get-VAFriendlyType "$(Get-VAProp $e 'type')")"; New-VATimePart (Get-VAProp $e 'detectionTimeUtc' (Get-VAProp $e 'creationTime')) 'f') })
    }
    if ($MalwareEvents.Count -gt 5) { $quotes.Add([ordered]@{ icon = '🦠'; text = "…and $($MalwareEvents.Count - 5) more malware events" }) }

    # ---- Headline ----
    $results = @($runs | ForEach-Object Result)
    $cOk = @($results | Where-Object { $_ -match '^Success' }).Count
    $cWarn = @($results | Where-Object { $_ -match '^Warning' }).Count
    $cFail = @($results | Where-Object { $_ -match '^Fail' }).Count
    $badJobs = @($jobs | Where-Object State -ne 'Success').Count
    $plural = { param($n, $one, $many) "$n $(if ($n -eq 1) { $one } else { $many })" }
    $things = @(
        if ($badJobs) { & $plural $badJobs 'job' 'jobs' }
        if ($badRepos) { & $plural $badRepos 'repository' 'repositories' }
        if ($MalwareEvents.Count) { & $plural $MalwareEvents.Count 'malware event' 'malware events' }
    )
    $total = $badJobs + $badRepos + $MalwareEvents.Count
    $title = if ($things.Count) {
        $list = if ($things.Count -gt 1) { ($things[0..($things.Count - 2)] -join ', ') + ' and ' + $things[-1] } else { $things[0] }
        "$list $(if ($total -eq 1) { 'needs' } else { 'need' }) attention"
    }
    elseif ($results.Count) { "All $(& $plural $results.Count 'session' 'sessions') succeeded" } else { 'No sessions ran' }
    $failedNow = @($jobs | Where-Object State -eq 'Failed').Count -or $MalwareEvents.Count -or $critical
    $status = if ($failedNow) { 'failed' } elseif ($things.Count) { 'warning' } elseif ($results.Count) { 'success' } else { 'info' }
    $icon, $label = switch ($status) { 'failed' { '❌', 'FAILED' } 'warning' { '⚠️', 'WARNING' } 'success' { '✅', 'HEALTHY' } default { '⚪', 'NO SESSIONS' } }
    $moved = Get-VASum $runs Bytes
    $summary = @(
        New-VARangePart $From $To 'f' 'f'
        if ($things.Count) {
            if ($cOk) { "$cOk ok" }
            if ($cWarn) { & $plural $cWarn 'warning' 'warnings' }
            if ($cFail) { "$cFail failed" }
        }
        else {
            if ($jobs.Count) { & $plural $jobs.Count 'job' 'jobs' }
            if ($moved -gt 0) { "$(Format-VASize $moved) moved" }
        }
    )

    # ---- Sections ----
    $sections = [System.Collections.Generic.List[object]]::new()
    if ($jobs.Count) {
        $healthy = @($jobs | Where-Object State -eq 'Success')
        $collapse = $things.Count -and $healthy.Count -gt 3
        $shown = if ($collapse) { @($jobs | Where-Object State -ne 'Success') } else { $jobs }
        $rows = @($shown | Sort-Object { [int]$_.Agent }, Name | ForEach-Object {
                [ordered]@{
                    status   = $_.Last.Result; name = $_.Name; history = $_.Strip; runs = $_.Runs.Count
                    size     = if ($_.Bytes -gt 0) { Format-VASize $_.Bytes } else { '' }
                    duration = if (-not $_.Agent -and $_.Last.Duration) { Format-VADuration $_.Last.Duration } else { '' }
                    group    = if ($_.Agent) { 'agents' } else { 'jobs' }
                }
            })
        $rollup = $null
        if ($collapse) {
            $merged = @(for ($i = 0; $i -lt $days.Count; $i++) { & $worst @($healthy | ForEach-Object { $_.Strip[$i] }) })
            $hb = Get-VASum $healthy Bytes
            $rollup = [ordered]@{ count = $healthy.Count; history = $merged; size = $(if ($hb -gt 0) { Format-VASize $hb } else { '' }) }
        }
        $sections.Add([ordered]@{ type = 'history'; title = "Jobs · last $HistoryDays days"; rows = $rows; rollup = $rollup })
    }
    if ($Repositories.Count) {
        $sections.Add([ordered]@{ type = 'repositories'; title = 'Storage'
                items = @($Repositories | Sort-Object { if ($null -eq $_.PercentFree) { 101 } else { $_.PercentFree } }) })
    }
    if ($AnalyzerViolations -ge 0 -or $MalwareEvents.Count) {
        $prev = $PreviousAnalyzerViolations
        $lines = @(
            if ($AnalyzerViolations -ge 0) {
                if ($prev -ge 0 -and $AnalyzerViolations -gt $prev) { "⚠️ $(& $plural ($AnalyzerViolations - $prev) 'new analyzer finding' 'new analyzer findings') ($AnalyzerViolations open)" }
                elseif ($prev -ge 0 -and $AnalyzerViolations -lt $prev) { "🛡️ $AnalyzerViolations analyzer findings open, $($prev - $AnalyzerViolations) fixed" }
                elseif ($prev -ge 0) { "🛡️ $AnalyzerViolations analyzer findings open, no change" }
                else { "🛡️ $AnalyzerViolations analyzer findings open" }
            }
            if ($MalwareEvents.Count) { "🦠 $(& $plural $MalwareEvents.Count 'malware event' 'malware events')" } else { '🦠 no malware events' }
        )
        $sections.Add([ordered]@{ type = 'text'; title = 'Security'; lines = $lines })
    }

    New-VAReport -Header $kind -Title $title -Status $status -Icon $icon -Label $label -Summary $summary `
        -Quotes $quotes.ToArray() -Sections $sections.ToArray() -Timestamp $To
}
