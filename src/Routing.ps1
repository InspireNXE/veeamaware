# Routing (what happens to each finished session) and digest scheduling.
#
# routing.rules: ordered list; the first rule whose "match" fits the job decides. Per result
# (success / warning / failure) a rule says:
#   immediate  post a report as soon as the session finishes
#   digest     no report now; the session appears in digests (content "routed" or "all")
#   both       report now and list it in digests
#   off        ignore the session entirely (no report, left out of every digest)
# A rule's "match" can use:
#   jobs      job-name wildcards, e.g. ["Prod*", "SQL-??"]                     (default: any job)
#   jobTypes  session types, e.g. ["AgentBackup", "BackupCopyJob"] or friendly
#             names like "Agent Backup"                                         (default: any type)
#   exclude   job-name wildcards this rule must not apply to
# A session no rule matches is reported immediately.

$script:VARouteModes = @('immediate', 'digest', 'both', 'off')
$script:VADigestSections = @('agents', 'jobs', 'repositories', 'security')

function ConvertTo-VAResultKey {
    <# Session result -> routing key. Anything that is not Success or Failed (None, canceled...) counts as a warning. #>
    param([AllowNull()][string]$Result)
    switch -Regex ($Result) { '^Success' { 'success' } '^Fail' { 'failure' } default { 'warning' } }
}

function Test-VAJobMatch {
    param($Match, [string]$JobName, [string]$SessionType)
    $jobs = @(Get-VAProp $Match 'jobs' @()) | Where-Object { $_ }
    $types = @(Get-VAProp $Match 'jobTypes' @()) | Where-Object { $_ }
    $exclude = @(Get-VAProp $Match 'exclude' @()) | Where-Object { $_ }
    if ($exclude | Where-Object { $JobName -like $_ }) { return $false }
    if ($jobs -and -not ($jobs | Where-Object { $JobName -like $_ })) { return $false }
    if ($types) {
        $friendly = Get-VAFriendlyType $SessionType
        if (-not ($types | Where-Object { $SessionType -like $_ -or $friendly -like $_ })) { return $false }
    }
    return $true
}

function Get-VARoute {
    <# Returns @{ Mode = immediate|digest|both|off; Rule = <rule name or 'default'> } for a session. #>
    param([Parameter(Mandatory)]$Config, [string]$JobName, [string]$SessionType, [string]$Result)
    $key = ConvertTo-VAResultKey $Result
    $i = 0
    foreach ($rule in @(Get-VAProp $Config 'routing.rules' @())) {
        $i++
        if (-not $rule) { continue }
        if (-not (Test-VAJobMatch (Get-VAProp $rule 'match' @{}) $JobName $SessionType)) { continue }
        $mode = "$(Get-VAProp $rule $key 'immediate')".ToLowerInvariant()
        return @{ Mode = $mode; Rule = "$(Get-VAProp $rule 'name' "rule $i")" }
    }
    return @{ Mode = 'immediate'; Rule = 'default' }
}

function Test-VAReportableSession {
    <# A finished job session (not an infrastructure/rescan/scan session without a job). #>
    param($Session)
    $empty = '00000000-0000-0000-0000-000000000000'
    return ($Session -and "$($Session.state)" -eq 'Stopped' -and $Session.jobId -and "$($Session.jobId)" -ne $empty -and
        "$($Session.sessionType)" -notmatch 'MalwareDetection|SecurityComplianceAnalyzer|Infrastructure|Rescan')
}

function Get-VASessionRoute {
    <# Get-VARoute for a session object (REST/PowerShell shape). #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Session)
    Get-VARoute -Config $Config -JobName "$(Get-VAProp $Session 'name')" -SessionType "$(Get-VAProp $Session 'sessionType')" `
        -Result "$(Get-VAProp $Session 'result.result')"
}

# ---- Digests -------------------------------------------------------------------------------------------

function Get-VADigests {
    param([Parameter(Mandatory)]$Config, [switch]$IncludeDisabled)
    @(Get-VAProp $Config 'digests' @()) | Where-Object { $_ -and ($IncludeDisabled -or (Get-VAProp $_ 'enabled' $true)) }
}

function Get-VADigestPeriod {
    param($Digest)
    if ("$(Get-VAProp $Digest 'schedule.every' 'day')" -eq 'week') { [timespan]::FromDays(7) } else { [timespan]::FromDays(1) }
}

function Get-VADigestOccurrence {
    <# The most recent scheduled time at or before $Now (local server time), as UTC. #>
    param([Parameter(Mandatory)]$Digest, [Parameter(Mandatory)][datetimeoffset]$Now)
    $at = [timespan]::ParseExact("$(Get-VAProp $Digest 'schedule.at' '08:00')", 'hh\:mm', [cultureinfo]::InvariantCulture)
    $local = $Now.ToLocalTime()
    $candidate = [datetimeoffset]::new($local.Date + $at, $local.Offset)
    if ("$(Get-VAProp $Digest 'schedule.every' 'day')" -eq 'week') {
        $day = [System.DayOfWeek]"$(Get-VAProp $Digest 'schedule.day' 'Monday')"
        $back = ([int]$candidate.DayOfWeek - [int]$day + 7) % 7
        $candidate = $candidate.AddDays(-$back)
        if ($candidate -gt $local) { $candidate = $candidate.AddDays(-7) }
    }
    elseif ($candidate -gt $local) { $candidate = $candidate.AddDays(-1) }
    return $candidate.ToUniversalTime()
}

function Get-VADigestDue {
    <#
    .SYNOPSIS
    Decides whether a digest should run now. $LastRun is when it last ran (state). Returns
    @{ Due; Baseline; From; To }. A digest that has never run is only baselined (nothing sent), so installing
    or adding a digest does not post immediately; the first real digest covers the time since then. A long
    outage is capped at two periods.
    #>
    param([Parameter(Mandatory)]$Digest, $LastRun, [Parameter(Mandatory)][datetimeoffset]$Now)
    $last = ConvertTo-VADate $LastRun
    if (-not $last) { return @{ Due = $false; Baseline = $true; From = $null; To = $Now } }
    $occurrence = Get-VADigestOccurrence -Digest $Digest -Now $Now
    if ($last -ge $occurrence) { return @{ Due = $false; Baseline = $false; From = $null; To = $Now } }
    $period = Get-VADigestPeriod $Digest
    $from = if (($Now - $last) -gt ($period + $period)) { $Now - $period } else { $last }
    return @{ Due = $true; Baseline = $false; From = $from; To = $Now }
}

function Test-VADigestWantsSession {
    <# Job filter + content setting of a digest. $Route is the session's routing decision. #>
    param([Parameter(Mandatory)]$Digest, [Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Route)
    if ($Route.Mode -eq 'off') { return $false }
    if ("$(Get-VAProp $Digest 'content' 'all')" -eq 'routed' -and $Route.Mode -notin 'digest', 'both') { return $false }
    $jobs = Get-VAProp $Digest 'jobs' @{}
    $match = @{ jobs = @(Get-VAProp $jobs 'include' @('*')); jobTypes = @(Get-VAProp $jobs 'jobTypes' @()); exclude = @(Get-VAProp $jobs 'exclude' @()) }
    return (Test-VAJobMatch $match "$(Get-VAProp $Session 'name')" "$(Get-VAProp $Session 'sessionType')")
}

function Resolve-VADigestTargets {
    <# Target names a digest goes to ("*" = every configured target). #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Digest)
    $all = @(Get-VATargets $Config | ForEach-Object { "$($_.name)" })
    $wanted = @(Get-VAProp $Digest 'targets' @('*'))
    if ($wanted -contains '*') { return $all }
    return @($all | Where-Object { $wanted -contains $_ })
}

# ---- Validation ----------------------------------------------------------------------------------------

function Test-VARoutingConfig {
    param([Parameter(Mandatory)]$Config)
    $errors = [System.Collections.Generic.List[string]]::new()
    $i = 0
    foreach ($rule in @(Get-VAProp $Config 'routing.rules' @())) {
        $i++
        $label = "routing.rules[$i]$(if (Get-VAProp $rule 'name') { " ('$(Get-VAProp $rule 'name')')" })"
        if (-not (Get-VAProp $rule 'match')) { $errors.Add("${label}: needs a ""match"" (use { ""jobs"": [""*""] } to match everything).") }
        foreach ($k in 'success', 'warning', 'failure') {
            $v = "$(Get-VAProp $rule $k 'immediate')".ToLowerInvariant()
            if ($v -notin $script:VARouteModes) { $errors.Add("${label}: $k must be one of $($script:VARouteModes -join ', ').") }
        }
    }
    $names = @{}
    $targets = @(Get-VATargets $Config | ForEach-Object { "$($_.name)" })
    $i = 0
    foreach ($d in @(Get-VADigests $Config -IncludeDisabled)) {
        $i++
        $n = "$(Get-VAProp $d 'name' '')"
        $label = if ($n) { "digest '$n'" } else { "digests[$i]" }
        if (-not $n) { $errors.Add("${label}: needs a name.") }
        elseif ($names.ContainsKey($n)) { $errors.Add("Duplicate digest name '$n'.") }
        else { $names[$n] = $true }
        $every = "$(Get-VAProp $d 'schedule.every' 'day')"
        if ($every -notin 'day', 'week') { $errors.Add("${label}: schedule.every must be day or week.") }
        if ("$(Get-VAProp $d 'schedule.at' '08:00')" -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { $errors.Add("${label}: schedule.at must be HH:mm (24h).") }
        if ($every -eq 'week' -and "$(Get-VAProp $d 'schedule.day' 'Monday')" -notin [enum]::GetNames([System.DayOfWeek])) {
            $errors.Add("${label}: schedule.day must be a weekday name such as Monday.")
        }
        if ("$(Get-VAProp $d 'content' 'all')" -notin 'all', 'routed') { $errors.Add("${label}: content must be all or routed.") }
        foreach ($s in @(Get-VAProp $d 'sections' $script:VADigestSections)) {
            if ($s -notin $script:VADigestSections) { $errors.Add("${label}: unknown section '$s' (use $($script:VADigestSections -join ', ')).") }
        }
        foreach ($t in @(Get-VAProp $d 'targets' @('*'))) {
            if ($t -ne '*' -and $targets -notcontains $t) { $errors.Add("${label}: target '$t' is not configured.") }
        }
    }
    return $errors
}

# ---- Migration from the 0.1 settings -------------------------------------------------------------------

function Convert-VALegacyConfig {
    <#
    .SYNOPSIS
    Rewrites pre-routing settings (notifications.onSuccess/onWarning/onFailure/excludeJobs, agents.*, digest.*)
    into routing.rules and digests, so an existing config.json keeps behaving the same. Works on the parsed
    JSON (PSCustomObject) before it is merged with the defaults. Returns the list of keys it migrated.
    #>
    param([Parameter(Mandatory)]$Json)
    $migrated = [System.Collections.Generic.List[string]]::new()
    $n = Get-VAProp $Json 'notifications'
    $agents = Get-VAProp $Json 'agents'
    $digest = Get-VAProp $Json 'digest'
    $legacyKeys = @('onSuccess', 'onWarning', 'onFailure', 'excludeJobs') | Where-Object { $n -and $n.PSObject.Properties[$_] }

    if (-not (Get-VAProp $Json 'routing') -and ($legacyKeys -or $agents)) {
        $flag = { param($name) if ($n -and $n.PSObject.Properties[$name]) { [bool]$n.$name } else { $true } }
        $now = { param($name) if (& $flag $name) { 'immediate' } else { 'off' } }
        $rules = [System.Collections.Generic.List[object]]::new()
        foreach ($p in @(Get-VAProp $n 'excludeJobs' @()) | Where-Object { $_ }) {
            $rules.Add([ordered]@{ name = "Excluded: $p"; match = [ordered]@{ jobs = @($p) }; success = 'off'; warning = 'off'; failure = 'off' })
        }
        $types = @('AgentBackup', 'AgentPolicy') + @(Get-VAProp $agents 'extraSessionTypes' @() | Where-Object { $_ })
        if ("$(Get-VAProp $agents 'mode' 'digest')" -eq 'digest') {
            $rules.Add([ordered]@{
                    name = 'Veeam Agents: failures now, the rest in the digest'; match = [ordered]@{ jobTypes = $types }
                    success = 'digest'; warning = $(if (Get-VAProp $agents 'immediateOnWarning' $false) { & $now 'onWarning' } else { 'digest' }); failure = & $now 'onFailure'
                })
        }
        $rules.Add([ordered]@{
                name = 'Everything else'; match = [ordered]@{ jobs = @('*') }
                success = & $now 'onSuccess'; warning = & $now 'onWarning'; failure = & $now 'onFailure'
            })
        $Json | Add-Member -NotePropertyName routing -NotePropertyValue ([pscustomobject]@{ rules = $rules.ToArray() }) -Force
        $migrated.Add('notifications.onSuccess/onWarning/onFailure/excludeJobs, agents -> routing.rules')
    }
    foreach ($k in $legacyKeys) { $n.PSObject.Properties.Remove($k) }
    if ($agents) { $Json.PSObject.Properties.Remove('agents') }

    if ($digest -and -not (Get-VAProp $Json 'digests')) {
        $sections = @('agents')
        if (Get-VAProp $digest 'includeOtherJobs' $true) { $sections += 'jobs' }
        if (Get-VAProp $digest 'includeRepositories' $true) { $sections += 'repositories' }
        if (Get-VAProp $digest 'includeSecurity' $true) { $sections += 'security' }
        $Json | Add-Member -NotePropertyName digests -Force -NotePropertyValue @([ordered]@{
                name = 'daily'; enabled = [bool](Get-VAProp $digest 'enabled' $true)
                schedule = [ordered]@{ every = 'day'; at = "$(Get-VAProp $digest 'time' '08:00')" }
                targets = @('*'); jobs = [ordered]@{ include = @('*'); exclude = @(); jobTypes = @() }
                content = 'all'; sections = $sections; skipWhenEmpty = $false
            })
        $migrated.Add('digest -> digests[daily]')
    }
    if ($digest) { $Json.PSObject.Properties.Remove('digest') }
    $watch = Get-VAProp $Json 'watch'
    if ($watch -and $watch.PSObject.Properties['agentFailures']) {
        $watch | Add-Member -NotePropertyName missedSessions -NotePropertyValue ([bool]$watch.agentFailures) -Force
        $watch.PSObject.Properties.Remove('agentFailures')
        $migrated.Add('watch.agentFailures -> watch.missedSessions')
    }
    return , $migrated.ToArray()
}
