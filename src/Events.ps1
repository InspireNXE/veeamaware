# Target-neutral events. Every notification is built once as an event; each target decides whether it wants it
# and renders its report (see Report.ps1) its own way.
#
# Event schema "veeamaware.event/v1" (this is also the generic webhook body):
#   id, schema, kind, severity, status, title, text, markdown, fingerprint, resolved, deferred,
#   occurredAt, source{server,product,tool}, details{...}, report{...} (veeamaware.report/v1, may be null)
#
#   kind        session | malware | repository | analyzer | authorization | health | digest | test
#               (health: Veeam services down, sessions that appear stuck, the watcher failing, VBR updated)
#   severity    info | success | warning | critical
#   fingerprint stable key for "the same problem" (one per job, per repository...), so a receiver can update
#               one incident instead of opening a new one every run
#   resolved    true when this event clears an earlier problem with the same fingerprint
#   deferred    true for sessions routed to the digest only (sent now only to targets with includeDeferred)

$script:VASeverityRank = @{ info = 0; success = 0; warning = 1; critical = 2 }

function Get-VASeverityRank { param([string]$Severity) if ($script:VASeverityRank.ContainsKey("$Severity")) { $script:VASeverityRank[$Severity] } else { 0 } }

function New-VAEvent {
    param(
        [Parameter(Mandatory)][ValidateSet('session', 'malware', 'repository', 'analyzer', 'authorization', 'health', 'digest', 'test')][string]$Kind,
        [Parameter(Mandatory)][ValidateSet('info', 'success', 'warning', 'critical')][string]$Severity,
        [Parameter(Mandatory)][string]$Title,
        [string]$Status,
        [string]$Text,
        [string]$Markdown,
        [string]$Fingerprint,
        [switch]$Resolved,
        [switch]$Deferred,
        $OccurredAt,
        [System.Collections.IDictionary]$Details = [ordered]@{},
        $Report,
        [string]$Mention
    )
    $at = ConvertTo-VADate $OccurredAt
    if (-not $at) { $at = [datetimeoffset]::UtcNow }
    [ordered]@{
        schema      = 'veeamaware.event/v1'
        id          = [guid]::NewGuid().ToString()
        kind        = $Kind
        severity    = $Severity
        status      = if ($Status) { $Status } else { $Severity }
        title       = $Title
        text        = $Text
        markdown    = if ($Markdown) { $Markdown } else { $Text }
        fingerprint = $Fingerprint
        resolved    = [bool]$Resolved
        deferred    = [bool]$Deferred
        occurredAt  = $at.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        source      = [ordered]@{ server = $env:COMPUTERNAME; product = 'Veeam Backup & Replication'; tool = "VeeamAware $script:VAVersion" }
        details     = $Details
        report      = $Report
        mention     = $Mention   # Failure | Warning | Success | Security: which mention list a chat target uses
    }
}

function ConvertTo-VAEventJson {
    <# Public JSON form of an event (drops internal routing hints). #>
    param([Parameter(Mandatory)]$Event)
    $copy = [ordered]@{}
    foreach ($k in $Event.Keys) { if ($k -notin 'mention', 'mentionExtra') { $copy[$k] = $Event[$k] } }
    return ($copy | ConvertTo-Json -Depth 12 -Compress)
}

function Get-VAResultSeverity {
    param([string]$Result)
    switch -Regex ($Result) { '^Success' { 'success' } '^Warning' { 'warning' } '^Fail' { 'critical' } default { 'info' } }
}

function Get-VAFingerprint {
    param([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Key)
    return ('vbr/{0}/{1}/{2}' -f $env:COMPUTERNAME.ToLowerInvariant(), $Kind, $Key.ToLowerInvariant())
}

# ---- Builders ------------------------------------------------------------------------------------------

function New-VASessionEvent {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Summary, [switch]$Deferred)
    $s = $Summary
    $severity = Get-VAResultSeverity $s.Result
    $problems = @($s.Tasks | Where-Object Result -notmatch '^Success')

    $md = [System.Text.StringBuilder]::new()
    [void]$md.AppendLine("**$($s.TypeName)** job **$($s.Name)** finished with **$($s.Result)** on $env:COMPUTERNAME.")
    if ($s.Message) { [void]$md.AppendLine().AppendLine("> $($s.Message -replace "`n", "`n> ")") }
    [void]$md.AppendLine().AppendLine('| | |').AppendLine('|---|---|')
    foreach ($row in @(
            @('Started', $(if ($s.Start) { $s.Start.ToString('u') } else { '—' })), @('Ended', $(if ($s.End) { $s.End.ToString('u') } else { '—' })),
            @('Duration', (Format-VADuration $s.Duration)), @('Processed', (Format-VASize $s.Processed)),
            @('Transferred', (Format-VASize $s.Transferred)), @('Bottleneck', $(if ($s.Bottleneck) { $s.Bottleneck } else { '—' })),
            @('Objects', "$(@($s.Tasks).Count) total, $($problems.Count) with issues"), @('Session ID', "``$($s.Id)``"))) {
        [void]$md.AppendLine("| $($row[0]) | $($row[1]) |")
    }
    if ($problems) {
        [void]$md.AppendLine().AppendLine('**Objects with issues**')
        foreach ($t in ($problems | Select-Object -First 50)) {
            [void]$md.AppendLine("- **$($t.Name)**: $($t.Result)$(if ($t.Message) { " — $($t.Message -replace '\s+', ' ')" })")
        }
    }
    if ($s.ProblemLog) {
        [void]$md.AppendLine().AppendLine('**Session log (warnings/errors)**')
        foreach ($l in ($s.ProblemLog | Select-Object -Last 20)) { [void]$md.AppendLine("- [$($l.Status)] $($l.Title -replace '\s+', ' ')") }
    }

    $text = "$($s.TypeName) job '$($s.Name)' finished: $($s.Result)."
    if ($problems) { $text += " $($problems.Count) object(s) with issues: " + (($problems | Select-Object -First 10 | ForEach-Object Name) -join ', ') + '.' }
    if ($s.Message) { $text += " $($s.Message)" }

    $details = [ordered]@{
        sessionId = $s.Id; jobId = $s.JobId; jobName = $s.Name; jobType = $s.TypeName; sessionType = $s.Type
        result = $s.Result; message = $s.Message; canceled = $s.Canceled
        startedAt = if ($s.Start) { $s.Start.ToString('o') } else { $null }; endedAt = if ($s.End) { $s.End.ToString('o') } else { $null }
        durationSeconds = if ($s.Duration) { [int]$s.Duration.TotalSeconds } else { $null }
        processedBytes = $s.Processed; readBytes = $s.Read; transferredBytes = $s.Transferred
        rateBytesPerSecond = if ($s.Rate) { [long]$s.Rate } else { $null }; bottleneck = $s.Bottleneck
        backupSizeBytes = $s.BackupSize; dedupeRatio = $s.Dedupe; compressionRatio = $s.Compression
        objects = @($s.Tasks | ForEach-Object {
                [ordered]@{ name = $_.Name; result = $_.Result; message = $_.Message; transferredBytes = $_.Transferred
                    durationSeconds = if ($_.Duration) { [int]$_.Duration.TotalSeconds } else { $null } }
            })
        logIssues = @($s.ProblemLog | ForEach-Object { [ordered]@{ status = $_.Status; title = $_.Title } })
    }
    $key = if ($s.JobId -and $s.JobId -ne '00000000-0000-0000-0000-000000000000') { $s.JobId } else { $s.Name }
    $mention = Get-VAMentionKind $s.Result
    $route = Get-VARoute -Config $Config -JobName "$($s.Name)" -SessionType "$($s.Type)" -Result "$($s.Result)"
    $extra = if ($mention -and $route.Mentions) { @(Get-VAProp $route.Mentions "on$mention" @()) | Where-Object { $_ } } else { @() }
    $evt = New-VAEvent -Kind session -Severity $severity -Status $s.Result -Title "$($s.Name): $($s.Result)" -Text $text -Markdown $md.ToString() `
        -Fingerprint (Get-VAFingerprint 'job' $key) -Resolved:($severity -eq 'success') -Deferred:$Deferred -OccurredAt $s.End `
        -Details $details -Report (New-VASessionReport -Config $Config -Summary $s) -Mention $mention
    $evt.mentionExtra = @($extra)   # the routing rule's own mentions (Discord adds them to the target's)
    $evt
}

function New-VAMalwareAlertEvent {
    param([Parameter(Mandatory)]$MalwareEvent)
    $e = $MalwareEvent
    $machine = "$(Get-VAProp $e 'machine.displayName' (Get-VAProp $e 'machine.name' (Get-VAProp $e 'machineName' 'Unknown machine')))"
    $type = Get-VAFriendlyType "$(Get-VAProp $e 'type' 'Unknown')"
    $detected = Get-VAProp $e 'detectionTimeUtc' (Get-VAProp $e 'detectionTime' (Get-VAProp $e 'creationTime'))
    $detail = "$(Get-VAProp $e 'details' '')"
    $md = "VBR raised a **malware detection event** ($type) for **$machine** on $env:COMPUTERNAME.`n`n" +
    "- Severity: $(Get-VAProp $e 'severity' '—')`n- State: $(Get-VAProp $e 'state' '—')`n- Source: $(Get-VAProp $e 'source' (Get-VAProp $e 'engine' '—'))`n" +
    "- Detected: $((ConvertTo-VADate $detected).ToString('u'))`n- Event ID: ``$(Get-VAProp $e 'id')```n`n$detail`n`n" +
    'Review it under Inventory → Malware Detection before restoring from affected restore points.'
    New-VAEvent -Kind malware -Severity critical -Status 'Malware' -Title "Malware detection: $machine ($type)" `
        -Text "Malware detection event ($type) for $machine. $detail" -Markdown $md -Fingerprint (Get-VAFingerprint 'malware' $machine) `
        -OccurredAt $detected -Report (New-VAMalwareReport $e) -Mention Security `
        -Details ([ordered]@{ eventId = "$(Get-VAProp $e 'id')"; machine = $machine; type = "$(Get-VAProp $e 'type')"; severity = "$(Get-VAProp $e 'severity')"
            state = "$(Get-VAProp $e 'state')"; source = "$(Get-VAProp $e 'source')"; details = $detail; raw = $e })
}

function New-VARepositoryAlertEvent {
    param([Parameter(Mandatory)]$Info, [Parameter(Mandatory)][string]$Level, [string]$PreviousLevel = 'ok')
    $severity = switch ($Level) { 'ok' { 'success' } 'warning' { 'warning' } default { 'critical' } }
    $what = switch ($Level) { 'ok' { 'has recovered' } 'warning' { 'is low on space' } 'critical' { 'is critically low on space' } 'offline' { 'is offline' } }
    $free = if ($null -ne $Info.PercentFree) { "$($Info.PercentFree)% free ($(Format-VASize ($Info.FreeGB * 1GB)) of $(Format-VASize ($Info.CapacityGB * 1GB)))" } else { 'capacity not reported' }
    New-VAEvent -Kind repository -Severity $severity -Status $Level -Title "Repository $($Info.Name) $what" `
        -Text "Repository '$($Info.Name)' $what`: $free. Previous state: $PreviousLevel." `
        -Markdown "Backup repository **$($Info.Name)** ($($Info.Type)) on $env:COMPUTERNAME $what.`n`n- Space: $free`n- Online: $($Info.Online)`n- Previous state: $PreviousLevel" `
        -Fingerprint (Get-VAFingerprint 'repository' $Info.Id) -Resolved:($Level -eq 'ok') `
        -Report (New-VARepositoryReport -Info $Info -Level $Level -PreviousLevel $PreviousLevel) `
        -Mention $(switch ($Level) { 'warning' { 'Warning' } 'ok' { '' } default { 'Failure' } }) `
        -Details ([ordered]@{ repositoryId = $Info.Id; name = $Info.Name; type = $Info.Type; level = $Level; previousLevel = $PreviousLevel
            capacityGB = $Info.CapacityGB; freeGB = $Info.FreeGB; percentFree = $Info.PercentFree; online = $Info.Online })
}

function New-VAAnalyzerAlertEvent {
    param([object[]]$NewViolations, [object[]]$AllViolations, $LastRun, [switch]$AllOpen)
    $names = @($AllViolations | ForEach-Object { Get-VAAnalyzerFinding $_ })
    $newNames = if ($AllOpen) { @() } else { @($NewViolations | ForEach-Object { Get-VAAnalyzerFinding $_ }) }
    $resolved = $names.Count -eq 0
    $md = if ($resolved) { "The latest Security & Compliance Analyzer run on $env:COMPUTERNAME reports no violations." }
    else { "Security & Compliance Analyzer on $env:COMPUTERNAME reports **$($names.Count)** violation(s).`n`n" + (($names | ForEach-Object { $mark = if ($newNames -contains $_) { ' *(new)*' } else { '' }; "- $_$mark" }) -join "`n") }
    New-VAEvent -Kind analyzer -Severity $(if ($resolved) { 'success' } else { 'warning' }) -Status $(if ($resolved) { 'Passed' } else { 'Violations' }) `
        -Title $(if ($resolved) { 'Security & Compliance Analyzer: all checks passing' } else { "Security & Compliance Analyzer: $($names.Count) violation(s)" }) `
        -Text $(if ($resolved) { 'No analyzer violations.' } else { 'Violations: ' + ($names -join '; ') }) -Markdown $md `
        -Fingerprint (Get-VAFingerprint 'analyzer' 'best-practices') -Resolved:$resolved -Mention $(if ($resolved) { '' } else { 'Security' }) `
        -Report $(if ($NewViolations) { New-VAAnalyzerReport -NewViolations $NewViolations -TotalViolations $names.Count -LastRun $LastRun -AllOpen:$AllOpen }) `
        -Details ([ordered]@{ violations = $names; newViolations = $newNames; runEndedAt = "$(Get-VAProp $LastRun 'endTime')" })
}

function New-VAAuthorizationAlertEvent {
    param([Parameter(Mandatory)]$AuthEvent)
    $op = "$(Get-VAProp $AuthEvent 'name' (Get-VAProp $AuthEvent 'operation' 'operation'))"
    $by = "$(Get-VAProp $AuthEvent 'initiatedBy' (Get-VAProp $AuthEvent 'createdBy' (Get-VAProp $AuthEvent 'userName' 'unknown')))"
    New-VAEvent -Kind authorization -Severity warning -Status 'PendingApproval' -Title "Four-eyes approval requested: $op" `
        -Text "$by requested '$op'; it needs a second administrator's approval in the VBR console." `
        -Markdown "**$by** requested **$op** on $env:COMPUTERNAME. It is waiting for a second administrator to approve or reject it in the VBR console.`n`n$(Get-VAProp $AuthEvent 'description' '')" `
        -Fingerprint (Get-VAFingerprint 'authorization' "$(Get-VAProp $AuthEvent 'id')") -Report (New-VAAuthorizationReport $AuthEvent) -Mention Security `
        -Details ([ordered]@{ requestId = "$(Get-VAProp $AuthEvent 'id')"; operation = $op; requestedBy = $by; state = "$(Get-VAProp $AuthEvent 'state')"; raw = $AuthEvent })
}

function New-VADigestEvent {
    param([Parameter(Mandatory)]$Report, [Parameter(Mandatory)][datetimeoffset]$From, [Parameter(Mandatory)][datetimeoffset]$To,
        [hashtable]$Counts = @{}, [string]$Name = 'daily')
    $sev = if ($Counts['failed']) { 'critical' } elseif ($Counts['warning']) { 'warning' } else { 'success' }
    New-VAEvent -Kind digest -Severity $sev -Status 'Digest' -Title "Digest '$Name' for $env:COMPUTERNAME" `
        -Text "Sessions: $([int]$Counts['total']) (success $([int]$Counts['success']), warning $([int]$Counts['warning']), failed $([int]$Counts['failed']))." `
        -OccurredAt $To -Report $Report `
        -Details ([ordered]@{ digest = $Name; from = $From.ToString('o'); to = $To.ToString('o'); counts = $Counts })
}
