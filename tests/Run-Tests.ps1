#Requires -Version 7.2
<#
.SYNOPSIS
Offline tests for VeeamAware (no VBR server or Discord needed). Exit code = number of failures.

Set $env:VEEAMAWARE_TEST_WEBHOOK to a scratch Discord webhook to also post the generated sample messages.
#>
param([switch]$ShowPayloads)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\VeeamAware.psm1') -Force
. (Join-Path $PSScriptRoot 'MockData.ps1')

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "veeamaware-tests-$PID"
New-Item -ItemType Directory $tmp -Force | Out-Null
$script:failures = 0
$script:passes = 0

function It([string]$Name, [scriptblock]$Test) {
    try { & $Test; $script:passes++; Write-Host "  [pass] $Name" -ForegroundColor Green }
    catch { $script:failures++; Write-Host "  [FAIL] $Name`n         $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert([bool]$Condition, [string]$Message = 'assertion failed') { if (-not $Condition) { throw $Message } }
function Assert-Eq($Actual, $Expected) { if ("$Actual" -ne "$Expected") { throw "expected '$Expected' but got '$Actual'" } }

function Assert-DiscordLimits($Embeds) {
    $batches = Group-VAEmbeds $Embeds
    foreach ($b in $batches) {
        Assert ($b.Count -le 10) "batch has $($b.Count) embeds"
        $total = ($b | ForEach-Object { Measure-VAEmbed $_ } | Measure-Object -Sum).Sum
        Assert ($total -le 6000) "batch has $total characters"
        foreach ($e in $b) {
            if ($e.Contains('title')) { Assert ($e.title.Length -le 256) 'title too long' }
            if ($e.Contains('description')) { Assert ($e.description.Length -le 4096) 'description too long' }
            if ($e.Contains('fields')) {
                Assert (@($e.fields).Count -le 25) 'too many fields'
                foreach ($f in $e.fields) {
                    Assert ($f.value.Length -le 1024) "field '$($f.name)' is $($f.value.Length) chars"
                    Assert (-not [string]::IsNullOrWhiteSpace($f.value)) "field '$($f.name)' is empty (Discord rejects this)"
                }
            }
        }
    }
    return $batches
}

$samples = [System.Collections.Generic.List[object]]::new()
$config = New-MockConfig

Write-Host 'Formatting'
It 'formats sizes in binary units' { Assert-Eq (Format-VASize 0) '0 B'; Assert-Eq (Format-VASize 1536) '1.5 KB'; Assert-Eq (Format-VASize (40GB)) '40 GB'; Assert-Eq (Format-VASize $null) '—' }
It 'formats durations' { Assert-Eq (Format-VADuration '00:12:41') '12m 41s'; Assert-Eq (Format-VADuration '1.02:03:04') '1d 2h 3m'; Assert-Eq (Format-VADuration 'PT1H5M') '1h 5m' }
It 'ignores default 0001-01-01 dates' { Assert ($null -eq (ConvertTo-VADate '0001-01-01T00:00:00Z')) }
It 'renders Discord timestamps' { Assert-Eq (Format-VADiscordTime '2026-11-05T08:00:00Z' 'R') '<t:1793865600:R>' }
It 'escapes markdown in names' { Assert-Eq (Protect-VAMarkdown 'web_01*') 'web\_01\*' }
It 'classifies agent sessions' {
    Assert (Test-VAAgentSession ([pscustomobject]@{ sessionType = 'AgentBackup' }))
    Assert (Test-VAAgentSession ([pscustomobject]@{ sessionType = 'AgentPolicy' }))
    Assert (-not (Test-VAAgentSession ([pscustomobject]@{ sessionType = 'BackupJob' })))
    Assert (Test-VAAgentSession ([pscustomobject]@{ sessionType = 'Custom' }) @('Custom'))
}

Write-Host 'Config'
It 'merges partial config over defaults' {
    $p = Join-Path $tmp 'c.json'
    '{"discord":{"webhookUrl":"https://discord.com/api/webhooks/1/a-b"},"notifications":{"maxObjects":5},"_comment":"x"}' | Set-Content $p
    $c = Get-VAConfig -Path $p
    Assert-Eq $c.notifications.maxObjects 5; Assert-Eq $c.notifications.objectDetail 'all'; Assert-Eq $c.vbr.port 443
    Assert-Eq @($c.routing.rules).Count 2; Assert-Eq "$(@($c.digests)[0].name)" 'daily'
}
It 'migrates pre-release settings to routing rules and a daily digest' {
    $p = Join-Path $tmp 'legacy.json'
    @'
{"discord":{"webhookUrl":"https://discord.com/api/webhooks/1/a-b"},
 "notifications":{"onSuccess":false,"onWarning":true,"onFailure":true,"excludeJobs":["Test*"],"objectDetail":"problems"},
 "agents":{"mode":"digest","immediateOnWarning":true,"extraSessionTypes":[]},
 "digest":{"enabled":true,"time":"07:30","includeOtherJobs":false,"includeRepositories":true,"includeSecurity":true},
 "watch":{"agentFailures":true}}
'@ | Set-Content $p
    $c = Get-VAConfig -Path $p
    Assert-Eq (Get-VARoute $c 'Test-1' 'BackupJob' 'Failed').Mode 'off'
    Assert-Eq (Get-VARoute $c 'Laptop' 'AgentBackup' 'Success').Mode 'digest'
    Assert-Eq (Get-VARoute $c 'Laptop' 'AgentBackup' 'Warning').Mode 'immediate'
    Assert-Eq (Get-VARoute $c 'Prod' 'BackupJob' 'Success').Mode 'off'       # onSuccess=false
    Assert-Eq (Get-VARoute $c 'Prod' 'BackupJob' 'Failed').Mode 'immediate'
    $d = @($c.digests)[0]
    Assert-Eq "$($d.schedule.at)" '07:30'; Assert (@($d.sections) -notcontains 'jobs') 'includeOtherJobs=false drops the jobs section'
    Assert $c.watch.missedSessions 'agentFailures -> missedSessions'
    Assert-Eq $c.notifications.objectDetail 'problems'                       # untouched settings survive
}
It 'routing: first matching rule wins, by name, type and exclusions' {
    $c = New-MockConfig
    $c.routing = [ordered]@{ rules = @(
            [ordered]@{ name = 'quiet'; match = @{ jobs = @('Lab-*'); exclude = @('Lab-Important') }; success = 'off'; warning = 'off'; failure = 'digest' }
            [ordered]@{ name = 'agents'; match = @{ jobTypes = @('Agent Backup') }; success = 'digest'; warning = 'both'; failure = 'immediate' }
        ) }
    Assert-Eq (Get-VARoute $c 'Lab-1' 'BackupJob' 'Success').Mode 'off'
    Assert-Eq (Get-VARoute $c 'Lab-1' 'BackupJob' 'Failed').Mode 'digest'
    Assert-Eq (Get-VARoute $c 'Lab-Important' 'BackupJob' 'Success').Mode 'immediate'   # excluded -> falls through to default
    Assert-Eq (Get-VARoute $c 'PC-1' 'AgentBackup' 'Warning').Mode 'both'                # friendly type name matches
    Assert-Eq (Get-VARoute $c 'PC-1' 'AgentBackup' 'None').Rule 'agents'
}
It 'rejects bad routing and digest settings' {
    $c = New-MockConfig
    $c.routing = @{ rules = @(@{ match = @{ jobs = @('*') }; success = 'sometimes' }) }
    $c.digests = @(
        @{ name = 'a'; schedule = @{ every = 'month'; at = '25:00' }; targets = @('nope'); sections = @('agents', 'weather') }
        @{ name = 'a' }
    )
    $errs = @(Test-VAConfig $c)
    foreach ($want in 'success must be', 'every must be', 'HH:mm', "target 'nope'", "section 'weather'", "Duplicate digest name 'a'") {
        Assert (@($errs | Where-Object { $_ -like "*$want*" }).Count -gt 0) "missing error '$want' in: $($errs -join '; ')"
    }
}
It 'digest schedule: baseline, due, not due, weekly, outage cap' {
    $daily = @{ name = 'd'; schedule = @{ every = 'day'; at = '08:00' } }
    $local = [datetimeoffset]::new([datetime]::Today.AddHours(9), [System.TimeZoneInfo]::Local.GetUtcOffset([datetime]::Today.AddHours(9)))
    $now = $local.ToUniversalTime()
    Assert (Get-VADigestDue $daily $null $now).Baseline 'never run -> baseline only'
    $r = Get-VADigestDue $daily $now.AddHours(-20) $now
    Assert $r.Due 'last ran before today 08:00 -> due'; Assert-Eq $r.From $now.AddHours(-20)
    Assert (-not (Get-VADigestDue $daily $now.AddMinutes(-30) $now).Due) 'already ran after 08:00'
    $r = Get-VADigestDue $daily $now.AddDays(-5) $now
    Assert-Eq ([int]($r.To - $r.From).TotalHours) 24                        # long outage capped to one period
    $weekly = @{ name = 'w'; schedule = @{ every = 'week'; day = "$($local.DayOfWeek)"; at = '08:00' } }
    Assert (Get-VADigestDue $weekly $now.AddDays(-3) $now).Due 'weekly digest due on its day after 08:00'
    $other = @{ name = 'w'; schedule = @{ every = 'week'; day = "$($local.AddDays(1).DayOfWeek)"; at = '08:00' } }
    Assert (-not (Get-VADigestDue $other $now.AddDays(-2) $now).Due) 'weekly digest not due before its day'
}
It 'digest content and job filters' {
    $s = [pscustomobject]@{ name = 'Prod-SQL'; sessionType = 'BackupJob' }
    $all = @{ content = 'all'; jobs = @{ include = @('*'); exclude = @() } }
    $routed = @{ content = 'routed'; jobs = @{ include = @('*') } }
    $prodOnly = @{ content = 'all'; jobs = @{ include = @('Prod-*'); exclude = @('*-SQL') } }
    Assert (Test-VADigestWantsSession $all $s @{ Mode = 'immediate' }) 'all includes immediate sessions'
    Assert (-not (Test-VADigestWantsSession $all $s @{ Mode = 'off' })) 'off is never digested'
    Assert (-not (Test-VADigestWantsSession $routed $s @{ Mode = 'immediate' })) 'routed skips immediate'
    Assert (Test-VADigestWantsSession $routed $s @{ Mode = 'both' }) 'routed includes both'
    Assert (-not (Test-VADigestWantsSession $prodOnly $s @{ Mode = 'digest' })) 'exclude wins over include'
}
It 'rejects a bad webhook and remote server with skipCertificateCheck' {
    $c = New-MockConfig; $c.discord.webhookUrl = 'https://example.com/hook'; $c.vbr.server = 'vbr01.corp.local'
    $errs = @(Test-VAConfig $c)
    Assert ($errs.Count -eq 2) "got $($errs.Count) errors: $($errs -join '; ')"
}
It 'example config is valid apart from its placeholder URLs' {
    Get-VAConfig -Path (Join-Path $root 'config\config.example.json') -AllowNoTargets | Out-Null
    $w = @(Get-VAConfigWarnings)
    Assert ($w.Count -gt 0) 'placeholders not flagged'
    Assert (-not @($w | Where-Object { $_ -notlike '*placeholder*' }).Count) ($w -join '; ')
}
It 'a broken target is set aside instead of stopping everything' {
    $p = Join-Path $tmp 'broken-target.json'
    @'
{"discord":{"webhookUrl":"https://discord.com/api/webhooks/1/a-b"},
 "targets":[{"type":"webhook","name":"hook","url":"http://hooks.corp.example/x","tokenFile":"secrets\\none.json"},
            {"type":"nosuchtype","name":"odd"},
            {"type":"teams","name":"teams","url":"https://example.webhook.office.com/x","enabled":false}],
 "digests":[{"name":"daily","targets":["discord","teams","gone"]}]}
'@ | Set-Content $p
    $c = Get-VAConfig -Path $p
    Assert-Eq (@(Get-VATargets $c | ForEach-Object name) -join ',') 'discord'
    $w = @(Get-VAConfigWarnings)
    foreach ($want in "Target 'hook': url must use https://", "Target 'odd': unknown type", "target 'gone' is not configured") {
        Assert (@($w | Where-Object { $_ -like "*$want*" }).Count -eq 1) "missing warning '$want' in: $($w -join '; ')"
    }
    Assert (-not @($w | Where-Object { $_ -like "*target 'teams'*" }).Count) 'a disabled target named by a digest is fine'
    Assert-Eq (@(Resolve-VADigestTargets -Config $c -Digest @($c.digests)[0]) -join ',') 'discord'
}
It 'nothing usable left is still an error, with the reasons' {
    $p = Join-Path $tmp 'no-target.json'
    '{"targets":[{"type":"nosuchtype","name":"odd"}]}' | Set-Content $p
    $msg = try { Get-VAConfig -Path $p | Out-Null; '' } catch { $_.Exception.Message }
    Assert ($msg -like '*No notification target*' -and $msg -like '*unknown type*') $msg
}
It 'values that cannot work fall back to the default' {
    $p = Join-Path $tmp 'bad-values.json'
    '{"discord":{"webhookUrl":"https://discord.com/api/webhooks/1/a-b"},"logging":{"level":"Verbose"},"watch":{"intervalMinutes":"often"},"notifications":{"sessionWaitMinutes":"20"}}' | Set-Content $p
    $c = Get-VAConfig -Path $p
    Assert-Eq $c.logging.level 'Info'; Assert-Eq $c.watch.intervalMinutes 5; Assert-Eq $c.notifications.sessionWaitMinutes '20'
    Assert-Eq @(Get-VAConfigWarnings).Count 2
}
It 'the top-level discord block can be switched off' {
    $c = New-MockConfig; $c.discord['enabled'] = $false
    Assert (-not @(Get-VATargets $c | Where-Object name -eq 'discord').Count) 'disabled block still sends'
}
It 'only real mention strings are used' { Assert-Eq (Get-VAMentionContent $config 'Failure') '<@111111111111111111>' }
It 'routing rules add their own mentions' {
    $c = New-MockConfig
    $c.routing.rules = @([ordered]@{ name = 'sql'; match = [ordered]@{ jobs = @('SQL*') }; success = 'immediate'; warning = 'immediate'; failure = 'immediate'
            mentions = [ordered]@{ onFailure = @('<@&222222222222222222>', 'not-a-mention') } })
    $sum = Get-VASessionSummary -Session (New-MockSession -Name 'SQL-01' -Result 'Failed') -TaskSessions @()
    $e = New-VASessionEvent -Config $c -Summary $sum
    Assert-Eq (@($e.mentionExtra) -join ',') '<@&222222222222222222>,not-a-mention'
    Assert-Eq (Get-VAMentionContent $config 'Failure' -Extra $e.mentionExtra) '<@111111111111111111> <@&222222222222222222>'
    Assert ((ConvertTo-VAEventJson $e) -notmatch 'mentionExtra') 'internal field stays out of the webhook body'
    $ok = New-VASessionEvent -Config $c -Summary (Get-VASessionSummary -Session (New-MockSession -Name 'SQL-01' -Result 'Success') -TaskSessions @())
    Assert-Eq @($ok.mentionExtra).Count 0
}

Write-Host 'Credential + state'
It 'round-trips the DPAPI credential' {
    $p = Join-Path $tmp 'cred.json'
    Save-VACredential -Credential ([pscredential]::new('.\veeamaware', (ConvertTo-SecureString 'S3cret!pass' -AsPlainText -Force))) -Path $p
    Assert (-not ((Get-Content -Raw $p) -match 'S3cret')) 'password stored in clear text'
    $c = Get-VACredential $p
    Assert-Eq $c.UserName '.\veeamaware'; Assert-Eq $c.GetNetworkCredential().Password 'S3cret!pass'
}
It 'claims a session exactly once' {
    Set-VAStatePath (Join-Path $tmp 'state.json')
    $id = [guid]::NewGuid().ToString()
    Assert (Add-VANotifiedSession $id); Assert (-not (Add-VANotifiedSession $id)); Assert (Test-VASessionNotified $id)
    Remove-VANotifiedSession $id; Assert (-not (Test-VASessionNotified $id))
}
It 'claims are safe across concurrent processes' {
    $statePath = Join-Path $tmp 'race.json'
    $id = [guid]::NewGuid().ToString()
    $mod = Join-Path $root 'src\VeeamAware.psm1'
    $jobs = 1..6 | ForEach-Object {
        Start-ThreadJob -ArgumentList $mod, $statePath, $id {
            param($m, $s, $i)
            Import-Module $m -Force; Set-VAStatePath $s; Add-VANotifiedSession $i
        }
    }
    $results = @($jobs | Receive-Job -Wait -AutoRemoveJob)
    Assert-Eq (@($results | Where-Object { $_ -eq $true }).Count) 1
}

Write-Host 'Session report'
$session = New-MockSession -Name 'Prod VMs' -Result 'Warning' -Message '1 of 4 VMs processed with warnings'
$tasks = @(
    New-MockTask 'sql-01' 'Success' 120
    New-MockTask 'sql-02' 'Warning' 80 'Changed block tracking cannot be enabled: snapshot exists'
    New-MockTask 'web_01*' 'Failed' 20 'Failed to connect to guest agent. Error: The RPC server is unavailable.'
    New-MockTask 'dc-01' 'Success' 60
)
$summary = Get-VASessionSummary -Session $session -TaskSessions $tasks -Log (New-MockLog)
It 'sums task stats' { Assert-Eq (Format-VASize $summary.Processed) '280 GB'; Assert ($summary.Rate -gt 0) }
It 'reads the bottleneck from the log' { Assert-Eq $summary.Bottleneck 'Source' }
It 'collects warning/error log lines' { Assert-Eq $summary.ProblemLog.Count 2 }
It 'builds an embed within Discord limits' {
    $c = New-MockConfig; $c.notifications.objectDetail = 'problems'
    $e = New-VASessionEmbeds -Config $c -Summary $summary
    Assert-DiscordLimits $e | Out-Null
    Assert ($e[0].color -eq 0xF0B232) 'warning colour'
    Assert ($e[0].author.name -match '^BACKUP JOB · ') 'author line'
    Assert-Eq $e[0].thumbnail.url 'attachment://status-warning.png'
    Assert ($e[0].description -match '\*\*WARNING\*\*') 'status word'
    Assert ($e[0].description -match '> \*\*web\\_01\\\*\*\*') 'issue quote names the object, markdown escaped'
    $objects = $e[0].fields | Where-Object name -like 'Objects*'
    Assert ($objects.value -match 'web_01\*') 'object table shows the raw name (code block)'
    Assert ($objects.value -notmatch 'dc-01') 'successful object listed in problems mode'
    Assert ($objects.value -match '^```ansi') 'ANSI block'
    $samples.Add(@{ Content = ''; Embeds = $e })
}
It 'success report: six stats, all objects, repository bar' {
    $ok = Get-VASessionSummary -Session (New-MockSession -Name 'Web' -Result 'Success') -TaskSessions @(New-MockTask 'web-01'; New-MockTask 'web-02')
    $ok | Add-Member -NotePropertyName Repository -NotePropertyValue (Get-VARepositoryInfo (New-MockRepo 'NAS' 5000 2900)) -Force
    $e = New-VASessionEmbeds -Config $config -Summary $ok
    Assert-DiscordLimits $e | Out-Null
    Assert-Eq $e[0].title 'Web'
    Assert (@($e[0].fields | Where-Object inline).Count -ge 3) 'stat grid'
    $obj = ($e[0].fields | Where-Object name -like 'Objects*')
    Assert-Eq $obj.name 'Objects · 2/2 OK'
    Assert ($obj.value -match '58% · 2\.83/4\.88 TB') 'repository bar on success'
    $repoRow = ($obj.value -split "`n" | Where-Object { $_ -like 'repo*' }) -replace "$([char]27)\[[\d;]*m", ''
    Assert ($repoRow.Length -le 38) "repository row fits beside the badge ($($repoRow.Length) chars)"
    # Worst cases: every unit, totals just under the next unit, 0%, 100% and odd fractions.
    foreach ($capGB in 0.5, 9.99, 10, 99.9, 100, 999, 1023.9, 1024, 10240, 102399, 1048575, 10485760) {
        foreach ($pct in 0, 0.4, 7.77, 50, 99.6, 100) {
            $row = Format-VARepositoryBar (Get-VARepositoryInfo (New-MockRepo 'x' $capGB ($capGB * $pct / 100))) $false
            Assert ($row.Length -le 38) "row too long for $capGB GB at $pct%: '$row' ($($row.Length))"
        }
    }
    $samples.Add(@{ Content = ''; Embeds = $e })
}
It 'failure report: history fields, no repository bar' {
    $f = Get-VASessionSummary -Session (New-MockSession -Name 'Prod' -Result 'Failed') -TaskSessions @(New-MockTask 'sql-01' 'Failed' 10 'Disk full')
    $now = [datetimeoffset]::UtcNow
    $h = @(
        [pscustomobject]@{ id = 'h1'; result = 'Failed'; endTime = $now.AddDays(-1) }
        [pscustomobject]@{ id = 'h2'; result = 'Failed'; endTime = $now.AddDays(-2) }
        [pscustomobject]@{ id = 'h3'; result = 'Success'; endTime = $now.AddDays(-3) }
    )
    Add-VAHistoryContext -Summary $f -History $h | Out-Null
    Assert-Eq $f.FailStreak 3; Assert-Eq ($f.Recent -join ',') 'Success,Failed,Failed,Failed'
    $e = New-VASessionEmbeds -Config $config -Summary $f
    $fact = { param($name) ($e[0].fields | Where-Object name -eq $name).value }
    $line = ($e[0].description -split "`n")[0]
    Assert ($line -match '🟩🟥🟥🟥') "the status line carries the strip like every other job card: $line"
    Assert ($line -match '3rd failure in a row') "streak beside the strip: $line"
    Assert (-not ($e[0].fields | Where-Object name -in 'Recent runs', 'In a row')) 'no history facts'
    Assert ((($e[0].fields | Where-Object name -eq 'Last success').value) -match '^<t:\d+:R>$') 'last success time'
    Assert ($e[0].description -match 'Disk full') 'error quoted'
    Assert-Eq $e[0].thumbnail.url 'attachment://status-failed.png'
}
$agentFailLog = @(   # WS-EXAMPLE-01 after the VBR 13.1 upgrade, as Veeam logged it
    [pscustomobject]@{ id = 1; status = 'Succeeded'; title = 'Job started at 11/6/2026 11:32:49 PM' }
    [pscustomobject]@{ id = 2; status = 'Succeeded'; title = 'Backup agent WS-EXAMPLE-01.corp.example requires upgrade' }
    [pscustomobject]@{ id = 3; status = 'Warning'; title = 'Server 192.0.2.20 has an outdated Data Mover service version.' }
    [pscustomobject]@{ id = 4; status = 'Failed'; title = 'Processing WS-EXAMPLE-01.corp.example Error: Failed to connect to agent at 192.0.2.20. Rescan the machine and try again.' }
    [pscustomobject]@{ id = 5; status = 'Failed'; title = 'Job finished with error at 11/6/2026 11:33:37 PM' }
)
$agentFailTask = [pscustomobject]@{ id = 't1'; name = 'WS-EXAMPLE-01.corp.example'; state = 'Stopped'; objectId = 'a1b2c3d4'
    result = [pscustomobject]@{ result = 'Failed'; message = 'Task failed. Error: Failed to connect to agent at 192.0.2.20. Rescan the machine and try again.' } }
It 'agent failure: the log line that explains it is quoted before the symptom' {
    $f = Get-VASessionSummary -Session (New-MockSession -Name 'WS-EXAMPLE-01' -Type 'AgentBackup' -Result 'Failed') -TaskSessions @($agentFailTask) -Log $agentFailLog
    Assert-Eq $f.Hints.Count 2
    Assert-Eq $f.Tasks[0].ObjectId 'a1b2c3d4'
    $d = (New-VASessionEmbeds -Config $config -Summary $f)[0].description
    $cause = $d.IndexOf('requires upgrade'); $symptom = $d.IndexOf('Failed to connect')
    Assert ($cause -ge 0 -and $symptom -gt $cause) $d
}
It 'agent failure: the protection group status says what to do' {
    $f = Get-VASessionSummary -Session (New-MockSession -Name 'WS-EXAMPLE-01' -Type 'AgentBackup' -Result 'Failed') -TaskSessions @($agentFailTask) -Log $agentFailLog
    $f.Agents = @([pscustomobject]@{ objectId = 'a1b2c3d4'; name = '192.0.2.20'; protectionGroup = 'Manually Added'; state = 'Online'
            agentStatus = 'UpgradeAvailable'; agentVersion = '13.1.1.700'; rebootRequired = $false })
    # Laid out like every other card: issue on the status line, version as a fact, fix as the note.
    $e = (New-VASessionEmbeds -Config $config -Summary $f)[0]
    $d = $e.description
    Assert ($d -notmatch 'out of date') 'the status line keeps its usual parts'
    Assert ($d -match '\n-# Upgrade the agent from the console: Inventory → Physical Infrastructure → Manually Added, right-click the computer → Upgrade\.$') $d
    Assert ($d -match '> \*\*WS-EXAMPLE-01.corp.example\*\*\n> Task failed') 'the error stays the quote'
    Assert ($d -notmatch 'requires upgrade') 'log hints are left out when the agent status already explains it'
    Assert-Eq (($e.fields | Where-Object name -eq 'Agent').value) '13.1.1.700 · out of date'
    $two = @($f.Agents[0], ([pscustomobject]@{ name = 'b'; agentStatus = 'UpgradeAvailable'; agentVersion = '13.1.1.700' }))
    Assert-Eq @(@(Get-VAAgentIssues $two) | Group-Object Issue).Count 1
    $f.Agents = $two
    Assert-Eq (((New-VASessionEmbeds -Config $config -Summary $f)[0].fields | Where-Object name -eq 'Agents').value) '2 out of date'
    Assert-Eq @(Get-VAAgentIssues @([pscustomobject]@{ name = 'ok'; state = 'Online'; agentStatus = 'Installed'; agentVersion = '13'; rebootRequired = $false })).Count 0
    Assert-Eq (Get-VAAgentIssues @([pscustomobject]@{ name = 'r'; state = 'Online'; agentStatus = 'Installed'; agentVersion = '13'; rebootRequired = $true })).Issue 'reboot pending'
}
It 'object rows fit beside the status badge' {
    $rows = @(
        [ordered]@{ status = 'Failed'; name = 'WS-EXAMPLE-01.corp.example'; size = '0 B'; duration = '' }
        [ordered]@{ status = 'Success'; name = 'a-much-longer-server-name.example.internal'; size = '12.4 GB'; duration = '1h 02m' }
    )
    foreach ($l in (Format-VAObjectTable -Rows $rows -Ansi $false)) { Assert ($l.Length -le 38) "too wide ($($l.Length)): $l" }
    $one = @(Format-VAObjectTable -Rows @($rows[0]) -Ansi $false)
    Assert-Eq $one[0] '✖ WS-EXAMPLE-01.corp.example  0 B'
}
It 'compares with the usual run and reports recovery' {
    $now = [datetimeoffset]::UtcNow
    $ok = Get-VASessionSummary -Session (New-MockSession -Name 'Web' -Result 'Success') -TaskSessions @(New-MockTask 'web-01' 'Success' 600)
    $h = @(
        [pscustomobject]@{ id = 'a'; result = 'Failed'; startTime = $now.AddHours(-26); endTime = $now.AddHours(-25) }
        foreach ($i in 2..6) { [pscustomobject]@{ id = "s$i"; result = 'Success'; startTime = $now.AddDays(-$i).AddMinutes(-10); endTime = $now.AddDays(-$i); transferredBytes = 10GB } }
    )
    Add-VAHistoryContext -Summary $ok -History $h | Out-Null
    Assert $ok.Recovered 'recovered'; Assert-Eq $ok.UsualTransferred (10GB)
    $e = New-VASessionEmbeds -Config $config -Summary $ok
    Assert ($e[0].description -match '\*\*RECOVERED\*\*') 'recovered label'
    Assert ($e[0].description -match 'down\s\d') 'down time'
    Assert ((($e[0].fields | Where-Object name -eq 'Transferred').value) -match '▲ \d+(\.\d)?× usual') 'transfer jump flagged'
    Assert ((($e[0].fields | Where-Object name -eq 'Duration').value) -match 'usual 10m|× usual') 'usual duration'
    Assert-Eq (Format-VAUsualDelta (11GB) (10GB) 3 256MB) ''
}
It 'repository trend from daily readings' {
    $sp = Join-Path $tmp 'trend-state.json'; Set-VAStatePath $sp
    $info = Get-VARepositoryInfo (New-MockRepo 'NAS' 1000 200)
    foreach ($d in 0..6) { Add-VARepositoryReadings -Infos @([pscustomobject]@{ Id = $info.Id; FreeGB = 200 + 10 * (6 - $d); CapacityGB = 1000; PercentFree = 20 }) -At ([datetimeoffset]::UtcNow.AddDays($d - 6)) }
    $tr = Get-VARepositoryTrend -Info $info
    Assert-Eq $tr.DaysToFull 20; Assert-Eq $tr.PercentPerDay -1
    Assert-Eq (Format-VARepositoryTrend ([pscustomobject]@{ Trend = $tr })) '−1%/day · full in ~20 days'
    Assert-Eq @((Read-VAState).repositorySpace[$info.Id]).Count 7
}
It 'badges and ANSI can be turned off' {
    $c = New-MockConfig; $c.discord.statusBadges = $false; $c.discord.ansiColors = $false
    $e = New-VASessionEmbeds -Config $c -Summary $summary
    Assert (-not $e[0].Contains('thumbnail')) 'no thumbnail'
    Assert ($e[0].title -match '^⚠️ ') 'emoji in title when there is no badge'
    Assert ((($e[0].fields | Where-Object name -like 'Objects*').value) -notmatch [char]27) 'no escape codes'
}
It 'badge images are attached to the message' {
    $files = Get-VADiscordAttachments @((New-VAEmbed -Title 'x' -ThumbnailUrl 'attachment://status-success.png'))
    Assert-Eq $files.Count 1
    Assert (Test-Path $files[0]) 'badge file shipped'
    $body = New-VADiscordBody -Json '{"embeds":[]}' -Files $files
    Assert ($body -is [System.Net.Http.MultipartFormDataContent]) 'multipart when attaching'
}
It 'survives a session with no tasks, logs or stats' {
    $bare = [pscustomobject]@{ id = 'x'; name = 'Empty'; sessionType = 'SureBackup'; state = 'Stopped'; result = [pscustomobject]@{ result = 'Failed' } }
    $e = New-VASessionEmbeds -Config $config -Summary (Get-VASessionSummary -Session $bare)
    Assert-DiscordLimits $e | Out-Null
}
It 'truncates huge object lists' {
    $c = New-MockConfig; $c.notifications.objectDetail = 'all'; $c.notifications.maxObjects = 500
    $many = 1..400 | ForEach-Object { New-MockTask "vm-$_-with-a-rather-long-name" 'Failed' 1 ('Something went badly wrong ' * 8) }
    $e = New-VASessionEmbeds -Config $c -Summary (Get-VASessionSummary -Session $session -TaskSessions $many)
    Assert-DiscordLimits $e | Out-Null
}

Write-Host 'Alerts'
It 'repository levels and embed' {
    $rc = $config.watch.repositories
    Assert-Eq (Get-VARepositoryLevel (Get-VARepositoryInfo (New-MockRepo 'a' 1000 500)) $rc) 'ok'
    Assert-Eq (Get-VARepositoryLevel (Get-VARepositoryInfo (New-MockRepo 'b' 1000 120)) $rc) 'warning'
    Assert-Eq (Get-VARepositoryLevel (Get-VARepositoryInfo (New-MockRepo 'c' 1000 30)) $rc) 'critical'
    Assert-Eq (Get-VARepositoryLevel (Get-VARepositoryInfo (New-MockRepo 'd' 1000 900 $false)) $rc) 'offline'
    Assert-Eq (Get-VARepositoryLevel (Get-VARepositoryInfo ([pscustomobject]@{ id = 'e'; name = 'S3' })) $rc) 'ok'
    $e = New-VARepositoryEmbed -Info (Get-VARepositoryInfo (New-MockRepo 'Primary ReFS' 20000 900)) -Level 'critical' -PreviousLevel 'warning'
    Assert-DiscordLimits @($e) | Out-Null
    $samples.Add(@{ Content = ''; Embeds = @($e) })
}
It 'malware embed' {
    $ev = [pscustomobject]@{ id = 7; type = 'EncryptedData'; severity = 'Suspicious'; state = 'Created'; source = 'InlineScan'
        detectionTimeUtc = [datetimeoffset]::UtcNow.ToString('o'); machine = [pscustomobject]@{ displayName = 'fs-01' }; details = 'Encrypted files detected: 1,432' }
    $e = New-VAMalwareEmbed $ev
    Assert-DiscordLimits @($e) | Out-Null
    Assert ($e.title -match 'fs-01')
    $samples.Add(@{ Content = ''; Embeds = @($e) })
}
It 'analyzer and four-eyes embeds' {
    $e1 = New-VAAnalyzerEmbed -NewViolations @([pscustomobject]@{ id = 'a'; bestPractice = 'MFA is enabled for backup console'; status = 'Violation' }) -TotalViolations 3 -LastRun ([pscustomobject]@{ endTime = [datetimeoffset]::UtcNow.ToString('o') })
    $e2 = New-VAAuthorizationEmbed ([pscustomobject]@{ id = 'r1'; name = 'Delete backup'; state = 'Pending'; initiatedBy = 'CORP\\alice'; creationTime = [datetimeoffset]::UtcNow.ToString('o') })
    Assert-DiscordLimits @($e1, $e2) | Out-Null
}
It 'analyzer findings read as plain problems' {
    Assert-Eq (Get-VAAnalyzerFinding ([pscustomobject]@{ id = 'FirewallEnabled'; bestPractice = 'Firewall Enabled' })) 'Windows Firewall is off'
    Assert-Eq (Get-VAAnalyzerFinding ([pscustomobject]@{ id = 'x'; bestPractice = 'LLMNR disabled' })) 'LLMNR is enabled'
    Assert-Eq (Get-VAAnalyzerFinding ([pscustomobject]@{ id = 'OsMfaTlsCheckRequired' })) 'Not met: OS MFA TLS Check Required'
    Assert-Eq (Get-VAAnalyzerFinding ([pscustomobject]@{ id = 'NewCheck'; bestPractice = 'Some new check' })) 'Not met: Some new check'
    $v = @([pscustomobject]@{ id = 'NetBiosDisabled'; bestPractice = 'Net Bios Disabled'; status = 'Violation' })
    $open = New-VAAnalyzerReport -NewViolations $v -TotalViolations 1 -LastRun $null -AllOpen
    Assert ($open.label -eq '1 OPEN FINDING') "label: $($open.label)"
    Assert ((New-VAAnalyzerReport -NewViolations $v -TotalViolations 4 -LastRun $null).label -eq '1 NEW FINDING') 'new label'
    $evt = New-VAAnalyzerAlertEvent -NewViolations $v -AllViolations $v -LastRun $null -AllOpen
    Assert ($evt.markdown -notmatch '\(new\)') 'all-open event marks nothing as new'
}

Write-Host 'Digest'
It 'builds a digest with agents, jobs, repos and malware' {
    $agents = foreach ($i in 1..30) {
        $r = if ($i % 11 -eq 0) { 'Failed' } elseif ($i % 7 -eq 0) { 'Warning' } else { 'Success' }
        $s = New-MockSession -Name ("Laptops policy {0}" -f ($i % 3)) -Type 'AgentPolicy' -Result $r -MinutesAgo ($i * 30)
        $t = 1..8 | ForEach-Object { New-MockTask "LT-$i-$_" $(if ($_ -eq 3 -and $r -ne 'Success') { $r } else { 'Success' }) 15 'Network path not found' }
        Get-VASessionSummary -Session $s -TaskSessions $t
    }
    $other = 1..40 | ForEach-Object { New-MockSession -Name "Job $($_ % 12)" -Type $(if ($_ % 2) { 'BackupJob' } else { 'BackupCopyJob' }) -Result $(if ($_ -eq 5) { 'Failed' } else { 'Success' }) -MinutesAgo ($_ * 20) }
    $repos = @((New-MockRepo 'Primary ReFS' 20000 2500), (New-MockRepo 'Hardened Linux' 50000 31000), (New-MockRepo 'Old NAS' 4000 100 $false))
    $mw = @([pscustomobject]@{ id = 1; type = 'EncryptedData'; machine = [pscustomobject]@{ displayName = 'fs-01' }; detectionTimeUtc = [datetimeoffset]::UtcNow.ToString('o') })
    $e = New-VADigestEmbeds -Config $config -From ([datetimeoffset]::UtcNow.AddHours(-24)) -To ([datetimeoffset]::UtcNow) `
        -AgentSummaries @($agents) -OtherSessions @($other) -Repositories @($repos | ForEach-Object { Get-VARepositoryInfo $_ }) -MalwareEvents $mw -AnalyzerViolations 2
    $batches = Assert-DiscordLimits $e
    Assert ($e[0].description -match '\*\*FAILED\*\*') 'overall status should be Failed'
    Assert-Eq $e[0].thumbnail.url 'attachment://status-failed.png'
    Assert ((($e | ForEach-Object { $_.description }) -join "`n") -match 'LT-11-3') 'failed machine listed'
    $samples.Add(@{ Content = ''; Embeds = $e })
}
It 'digest leads with what needs attention and collapses healthy jobs' {
    $to = [datetimeoffset](Get-Date).Date.AddHours(12)   # local midday: "30 minutes ago" stays today
    $other = @(1..6 | ForEach-Object { New-MockSession -Name "Job $_" -Result 'Success' -MinutesAgo 60 -Now $to })
    $other += New-MockSession -Name 'Prod' -Result 'Failed' -MinutesAgo 30 -Now $to
    $hist = @(1..3 | ForEach-Object { $s = New-MockSession -Name 'Prod' -Result 'Failed' -MinutesAgo (1440 * $_) -Now $to; $s.id = "old$_"; $s })
    $hist += & { $s = New-MockSession -Name 'Prod' -Result 'Success' -MinutesAgo (1440 * 4) -Now $to; $s.id = 'old4'; $s }
    $r = New-VADigestReport -Config $config -From $to.AddDays(-1) -To $to -OtherSessions $other -HistorySessions $hist -AnalyzerViolations 20 -PreviousAnalyzerViolations 19
    Assert-Eq $r.title '1 job needs attention'; Assert-Eq $r.status 'failed'
    Assert ((Format-VAParts $r.quotes[0].parts) -match 'failed 4 runs in a row') "streak: $(Format-VAParts $r.quotes[0].parts)"
    $h = $r.sections | Where-Object { $_.type -eq 'history' }
    Assert-Eq @($h.rows).Count 1; Assert-Eq $h.rollup.count 6
    Assert-Eq ($h.rows[0].history -join ',') 'None,None,Success,Failed,Failed,Failed,Failed'
    Assert ((($r.sections | Where-Object { $_.type -eq 'text' }).lines -join ' ') -match '1 new analyzer finding \(20 open\)') 'analyzer delta'
    $e = ConvertTo-VADiscordEmbeds $r
    Assert-Eq @($e).Count 1
    Assert-DiscordLimits $e | Out-Null
    $ok = New-VADigestReport -Config $config -From $to.AddDays(-1) -To $to -OtherSessions @($other | Select-Object -First 6)
    Assert-Eq $ok.title 'All 6 sessions succeeded'; Assert-Eq $ok.label 'HEALTHY'
}
It 'digest with nothing to report' {
    $e = New-VADigestEmbeds -Config $config -From ([datetimeoffset]::UtcNow.AddHours(-24)) -To ([datetimeoffset]::UtcNow)
    Assert-DiscordLimits $e | Out-Null
}
It 'digest: an agent job whose last run failed before any machine ran is failed, not recovered' {
    $to = [datetimeoffset](Get-Date).Date.AddHours(12)
    $good = New-MockSession -Name 'Laptops' -Type 'AgentPolicy' -Result 'Success' -MinutesAgo 300 -Now $to; $good.id = 'a1'
    $bad = New-MockSession -Name 'Laptops' -Type 'AgentPolicy' -Result 'Failed' -MinutesAgo 30 -Now $to; $bad.id = 'a2'
    $agents = @(
        (Get-VASessionSummary -Session $good -TaskSessions @((New-MockTask 'LT-1' 'Success' 5), (New-MockTask 'LT-2' 'Success' 5)))
        (Get-VASessionSummary -Session $bad -TaskSessions @())
    )
    $r = New-VADigestReport -Config $config -From $to.AddDays(-1) -To $to -AgentSummaries $agents
    Assert-Eq $r.status 'failed'
    Assert ((Format-VAParts $r.quotes[0].parts) -notmatch 'recovered') "parts: $(Format-VAParts $r.quotes[0].parts)"
}
It 'digest: many failures still fit Teams and say how many were left out on Discord' {
    $to = [datetimeoffset](Get-Date).Date.AddHours(12)
    $other = @(1..60 | ForEach-Object { $s = New-MockSession -Name ("Job {0:d2} with a fairly long name" -f $_) -Result 'Failed' -MinutesAgo 30 -Now $to
            $s.result.message = 'Unable to allocate processing resources. Error: repository is unavailable, the share cannot be reached ' * 3; $s })
    $healthy = @(1..60 | ForEach-Object { New-MockSession -Name ("Healthy job {0:d2}" -f $_) -Result 'Success' -MinutesAgo 60 -Now $to })
    $r = New-VADigestReport -Config $config -From $to.AddDays(-1) -To $to -OtherSessions @($other + $healthy)
    $json = New-VATeamsPayload -Report $r
    Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 26000) "Teams payload is $([Text.Encoding]::UTF8.GetByteCount($json)) bytes"
    Assert ($json -match 'and \d+ more') 'Teams does not say how many quotes were left out'
    $e = ConvertTo-VADiscordEmbeds $r
    Assert-DiscordLimits $e | Out-Null
    Assert ($e[0].description -match '…and \d+ more') 'Discord quotes cut without a count'
}
It 'Discord tables say how many lines were left out' {
    $lines = @(1..200 | ForEach-Object { "row $_ " + ('x' * 20) })
    $f = @(New-VACodeFields -Name 'Jobs' -Lines $lines -Ansi $false)
    Assert-Eq $f.Count 3
    Assert ($f[2].value -match 'and \d+ more lines not shown') $f[2].value
    foreach ($x in $f) { Assert ($x.value.Length -le 1024) "field is $($x.value.Length) chars" }
}

Write-Host 'REST client'
It 'follows pagination' {
    & (Get-Module VeeamAware) {
        $script:calls = 0
        function script:Invoke-VARest { param($Path, $Query) $script:calls++
            $start = [int]$Query.skip; $n = [Math]::Max(0, [Math]::Min([int]$Query.limit, 450 - $start))
            [pscustomobject]@{ data = @(for ($i = 0; $i -lt $n; $i++) { [pscustomobject]@{ id = $start + $i } }); pagination = [pscustomobject]@{ total = 450 } } }
        $items = Get-VARestList -Path '/api/v1/sessions'
        if ($items.Count -ne 450 -or $script:calls -ne 3) { throw "got $($items.Count) items in $script:calls calls" }
    }
}
It 'WhatIf payload is valid JSON with mentions only on the first message' {
    $e = $samples[$samples.Count - 1].Embeds
    $json = @(Send-VADiscord -Config $config -Embeds $e -Content '<@111111111111111111>' -WhatIf | Where-Object { $_ -like '{*' })
    Assert ($json.Count -ge 1)
    $first = $json[0] | ConvertFrom-Json
    Assert-Eq $first.content '<@111111111111111111>'
    foreach ($j in $json | Select-Object -Skip 1) { Assert (-not ($j | ConvertFrom-Json).PSObject.Properties['content']) 'content repeated' }
    if ($ShowPayloads) { $json | ForEach-Object { Write-Host $_ } }
}

Import-Module (Join-Path $root 'src\VeeamAware.psm1') -Force   # drop the REST mock
Set-VAStatePath (Join-Path $tmp 'targets-state.json')

Write-Host 'Targets'
$sigPath = Join-Path $tmp 'sig.json'
Save-VASecret -Secret (ConvertTo-SecureString 'shh' -AsPlainText -Force) -Path $sigPath
$tc = New-MockConfig
$tc.targets = @(
    [pscustomobject]@{ type = 'webhook'; name = 'hook'; url = 'https://hooks.example.com/veeam'; minSeverity = 'warning'; signingSecretFile = $sigPath }
)

It 'discord shorthand plus targets validate' {
    $errs = @(Test-VAConfig $tc); Assert ($errs.Count -eq 0) ($errs -join '; ')
    Assert-Eq ((Get-VATargets $tc | ForEach-Object name) -join ',') 'discord,hook'
}
It 'rejects an unknown target type' {
    $bad = New-MockConfig
    $bad.targets = @([pscustomobject]@{ type = 'pager'; name = 'x' })
    Assert (@(Test-VAConfig $bad | Where-Object { $_ -like '*unknown type*' }).Count -eq 1) 'unknown type accepted'
}

$failSummary = Get-VASessionSummary -Session (New-MockSession -Name 'Prod VMs' -Result 'Failed') -TaskSessions @(New-MockTask 'sql-01' 'Failed' 10 'Disk full') -Log (New-MockLog)
$failSummary.JobId = '11111111-2222-3333-4444-555555555555'
$okSummary = Get-VASessionSummary -Session (New-MockSession -Name 'Prod VMs' -Result 'Success') -TaskSessions @(New-MockTask 'sql-01')
$okSummary.JobId = $failSummary.JobId
$failEvt = New-VASessionEvent -Config $tc -Summary $failSummary
$okEvt = New-VASessionEvent -Config $tc -Summary $okSummary

It 'sends to several Discord channels, each with its own mentions and thread' {
    $mc = New-MockConfig
    $mc.targets = @([pscustomobject]@{ type = 'discord'; name = 'ops'; webhookUrl = 'https://discord.com/api/webhooks/222222222222222222/opsTOKEN'
            threadId = '333333333333333333'; username = 'Backup Ops'; mentions = [pscustomobject]@{ onFailure = @('<@&444444444444444444>') } })
    $errs = @(Test-VAConfig $mc); Assert ($errs.Count -eq 0) ($errs -join '; ')
    $ts = @(Get-VATargets $mc)
    Assert-Eq (($ts | ForEach-Object name) -join ',') 'discord,ops'   # the top-level block is not dropped
    $main = (@(Send-VATargetEvent -Config $mc -Target $ts[0] -Event $failEvt -WhatIf) | Where-Object { $_ -like '{*' } | Select-Object -First 1) | ConvertFrom-Json
    $ops = (@(Send-VATargetEvent -Config $mc -Target $ts[1] -Event $failEvt -WhatIf) | Where-Object { $_ -like '{*' } | Select-Object -First 1) | ConvertFrom-Json
    Assert-Eq $main.content '<@111111111111111111>'
    Assert-Eq $ops.content '<@&444444444444444444>'
    Assert-Eq $ops.username 'Backup Ops'
}
It 'skips the top-level Discord block once it is moved into targets' {
    $mc = New-MockConfig
    $mc.targets = @([pscustomobject]@{ type = 'discord'; name = 'main'; webhookUrl = $mc.discord.webhookUrl })
    Assert-Eq ((Get-VATargets $mc | ForEach-Object name) -join ',') 'main'
}
It 'explains a clash with the top-level Discord name' {
    $mc = New-MockConfig
    $mc.targets = @([pscustomobject]@{ type = 'discord'; name = 'discord'; webhookUrl = 'https://discord.com/api/webhooks/222222222222222222/other' })
    Assert (@(Test-VAConfig $mc | Where-Object { $_ -like '*give the other Discord target its own name*' }).Count -eq 1) 'no clash message'
}

It 'targets filter by severity, resolution and deferral; digests bypass minSeverity' {
    $t = @{}; foreach ($x in (Get-VATargets $tc)) { $t[$x.name] = $x }
    Assert (Test-VATargetWants $tc $t.discord $failEvt) 'discord wants failure'
    Assert (Test-VATargetWants $tc $t.discord $okEvt) 'discord wants success'
    Assert (Test-VATargetWants $tc $t.hook $okEvt) 'webhook gets resolutions'
    $warnOnly = New-VASessionEvent -Config $tc -Summary (Get-VASessionSummary -Session (New-MockSession -Name 'X' -Result 'Success'))
    $warnOnly.resolved = $false
    Assert (-not (Test-VATargetWants $tc $t.hook $warnOnly)) 'webhook minSeverity=warning drops plain successes'
    $deferred = New-VASessionEvent -Config $tc -Summary $okSummary -Deferred
    Assert (-not (Test-VATargetWants $tc $t.discord $deferred)) 'discord skips digest-only sessions'
    $t.hook.includeDeferred = $true
    Assert (Test-VATargetWants $tc $t.hook $deferred) 'includeDeferred receives them'
    $digest = New-VADigestEvent -Report (New-VAReport -Header 'x' -Title 'x') -From ([datetimeoffset]::UtcNow.AddDays(-1)) -To ([datetimeoffset]::UtcNow)
    Assert (Test-VATargetWants $tc $t.hook $digest) 'digest reaches a warning-only webhook it was addressed to'
    Assert-Eq ((Resolve-VADigestTargets $tc @{ targets = @('hook') }) -join ',') 'hook'
    Assert-Eq ((Resolve-VADigestTargets $tc @{ targets = @('*') }) -join ',') 'discord,hook'
}
It 'webhook body is the public schema with a valid HMAC' {
    & (Get-Module VeeamAware) {
        $script:captured = $null
        function script:Invoke-VAHttpJson { param($Method, $Uri, $Headers, $Body, $TimeoutSec, $Attempts) $script:captured = @{ Headers = $Headers; Body = $Body } }
    }
    $t = Get-VATargets $tc | Where-Object name -eq 'hook'
    Send-VAWebhookEvent -Target $t -Event $failEvt
    $c = & (Get-Module VeeamAware) { $script:captured }
    $doc = $c.Body | ConvertFrom-Json
    Assert-Eq $doc.schema 'veeamaware.event/v1'; Assert-Eq $doc.kind 'session'; Assert-Eq $doc.severity 'critical'
    Assert (-not $doc.PSObject.Properties['discord']) 'discord rendering leaked into webhook body'
    Assert-Eq $doc.details.objects[0].name 'sql-01'
    $h = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes('shh'))
    $ts = $c.Headers['X-VeeamAware-Timestamp']
    Assert ($ts -match '^\d{10}$' -and [math]::Abs([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$ts) -lt 60) "timestamp: $ts"
    $expected = 'sha256=' + [Convert]::ToHexString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes("$ts.$($c.Body)"))).ToLowerInvariant()
    Assert-Eq $c.Headers['X-VeeamAware-Signature'] $expected
}
It 'webhook secrets need https, except on the local network' {
    $v = (Get-VATargetType 'webhook').Validate
    $bad = @(& $v ([ordered]@{ type = 'webhook'; name = 'x'; url = 'http://hooks.example.com/in'; tokenFile = 'secrets\none.json' }) $null)
    Assert (@($bad | Where-Object { $_ -match 'https' }).Count) 'public http with a token is refused'
    foreach ($u in 'http://localhost:5678/x', 'http://192.168.1.20/x', 'http://10.0.0.5/x', 'http://172.20.1.1/x', 'http://n8n/x', 'http://n8n.local/x') {
        $r = @(& $v ([ordered]@{ type = 'webhook'; name = 'x'; url = $u; signingSecretFile = 'secrets\none.json' }) $null)
        Assert (-not @($r | Where-Object { $_ -match 'https' }).Count) "$u should be allowed"
    }
    $plain = @(& $v ([ordered]@{ type = 'webhook'; name = 'x'; url = 'http://hooks.example.com/in' }) $null)
    Assert (-not @($plain | Where-Object { $_ -match 'https' }).Count) 'http without secrets is allowed'
    $opt = @(& $v ([ordered]@{ type = 'webhook'; name = 'x'; url = 'http://hooks.corp.example/in'; tokenFile = 'secrets\none.json'; allowHttp = $true }) $null)
    Assert (-not @($opt | Where-Object { $_ -match 'https' }).Count) 'allowHttp lets it through'
    foreach ($u in 'http://[::1]/x', 'http://[fd12:3456::5]/x', 'http://[fe80::1]/x') { Assert (Test-VALocalUrl $u) "$u is local" }
    foreach ($u in 'http://[2001:db8::1]/x', 'http://192.0.2.10/x', 'http://hooks.corp.example/x') { Assert (-not (Test-VALocalUrl $u)) "$u is not local" }
}
It 'one failing target does not block the others' {
    & (Get-Module VeeamAware) {
        function script:Send-VADiscordEvent { param($Target, $Event, [switch]$WhatIf) throw 'discord down' }
        function script:Send-VAWebhookEvent { param($Target, $Event, $Context) }
    }
    Assert-Eq (Send-VAEvent -Config $tc -Event $failEvt) 1
}
It 'state migrates the pre-release digest marker' {
    $p = Join-Path $tmp 'legacy-state.json'
    '{"version":1,"lastDigestUtc":"2026-11-05T15:00:00Z","notifiedSessions":["x"]}' | Set-Content $p
    Set-VAStatePath $p
    $s = Read-VAState
    Assert-Eq $s.digests['daily'] '2026-11-05T15:00:00Z'
    Assert (-not $s.Contains('lastDigestUtc')) 'old marker kept'
    Set-VAStatePath (Join-Path $tmp 'targets-state.json')
}

Import-Module (Join-Path $root 'src\VeeamAware.psm1') -Force

Write-Host 'Target types and renderers'
$digestArgs = @{
    Config = $config; From = [datetimeoffset]::UtcNow.AddHours(-24); To = [datetimeoffset]::UtcNow
    AgentSummaries = @(Get-VASessionSummary -Session (New-MockSession -Name 'Laptops' -Type 'AgentPolicy' -Result 'Failed') -TaskSessions @(New-MockTask 'LT-1' 'Failed' 5 'Network path not found'))
    OtherSessions = @(New-MockSession -Name 'Prod VMs' -Result 'Success'); Repositories = @(Get-VARepositoryInfo (New-MockRepo 'NAS' 5000 2900))
}
It 'built-in types are registered' {
    Assert-Eq ((Get-VATargetType | ForEach-Object Type | Sort-Object) -join ',') 'discord,teams,webhook'
    Assert (-not @(Get-VAPluginErrors).Count) 'plugin load errors'
}
It 'unknown types name the available ones' {
    $bad = New-MockConfig; $bad.targets = @([pscustomobject]@{ type = 'pager'; name = 'x' })
    Assert (@(Test-VAConfig $bad | Where-Object { $_ -like '*available: discord, teams, webhook*' }).Count -eq 1) 'no type list'
}
It 'teams card: status band, local times, stays under the size limit' {
    $tt = [ordered]@{ type = 'teams'; name = 'teams'; url = 'https://example.webhook.office.com/x' }
    $tcfg = New-MockConfig; $tcfg.targets = @($tt)
    Assert (-not @(Test-VAConfig $tcfg).Count) ((Test-VAConfig $tcfg) -join '; ')
    $json = @(Send-VATargetEvent -Config $tcfg -Target $tt -Event $failEvt -WhatIf) -join ''
    $msg = $json | ConvertFrom-Json
    $card = $msg.attachments[0].content
    Assert-Eq $msg.attachments[0].contentType 'application/vnd.microsoft.card.adaptive'
    Assert-Eq $card.version '1.4'; Assert-Eq $card.body[0].style 'attention'
    Assert ($json -match '\{\{TIME\(\d{4}-\d\d-\d\dT[\d:]+Z\)\}\}') 'times use Adaptive Card TIME()'
    Assert ($json -match 'Disk full') 'error shown'
    $many = 1..400 | ForEach-Object { New-MockTask "vm-$_-with-a-rather-long-name" 'Failed' 1 ('Something went badly wrong ' * 8) }
    $c = New-MockConfig; $c.notifications.objectDetail = 'all'; $c.notifications.maxObjects = 500
    $big = New-VATeamsPayload -Report (New-VASessionReport -Config $c -Summary (Get-VASessionSummary -Session $session -TaskSessions $many))
    Assert ([Text.Encoding]::UTF8.GetByteCount($big) -le 28000) "teams payload is $([Text.Encoding]::UTF8.GetByteCount($big)) bytes"
    $d = New-VATeamsPayload -Report (New-VADigestReport @digestArgs) | ConvertFrom-Json
    $dj = $d.attachments[0].content.body | ConvertTo-Json -Depth 30
    Assert ($dj -match 'LT-1') 'digest lists the failed machine'
    # Flat coloured squares and a coloured bar, not Fluent emoji or plain monospace text.
    Assert ($dj -notmatch '🟩|🟥|🟨|⬛') 'no emoji squares'
    Assert ($dj -match '"RichTextBlock"') 'strips are rich text'
    Assert ($dj -match '"text":\s*"▰+"') 'repository bar is a coloured run'
}
It 'webhook body carries the neutral report, not routing hints' {
    & (Get-Module VeeamAware) { function script:Invoke-VAHttpJson { param($Method, $Uri, $Headers, $Body, $TimeoutSec, $Attempts) $script:captured = @{ Body = $Body } } }
    Send-VAWebhookEvent -Target ([ordered]@{ type = 'webhook'; name = 'h'; url = 'https://x.example/h' }) -Event $failEvt
    $doc = (& (Get-Module VeeamAware) { $script:captured }).Body | ConvertFrom-Json
    Assert-Eq $doc.report.schema 'veeamaware.report/v1'; Assert-Eq $doc.report.status 'failed'
    Assert-Eq $doc.report.sections[0].type 'objects'
    Assert (-not $doc.PSObject.Properties['mention']) 'mention leaked'
}
It 'plain-text rendering' {
    $txt = ConvertTo-VAPlainText -Report (New-VADigestReport @digestArgs)
    Assert ($txt -match '(?m)^Jobs · last 7 days$') 'section title'; Assert ($txt -match 'LT-1: Network path not found') 'machine detail'
    Assert ($txt -match '(?m)^1 job needs attention$') "headline: $txt"
    Assert ($txt -match 'NAS: 58% free') 'repository'
    Assert ($txt -notmatch '<t:|\{\{') 'no Discord or Teams markup'
}
It 'loads a plugin from VEEAMAWARE_PLUGIN_PATH and routes events to it' {
    $pdir = Join-Path $tmp 'plugins'; New-Item -ItemType Directory $pdir -Force | Out-Null
    Copy-Item (Join-Path $root 'docs\examples\textfile-target.ps1') $pdir
    $env:VEEAMAWARE_PLUGIN_PATH = $pdir
    try {
        Import-Module (Join-Path $root 'src\VeeamAware.psm1') -Force
        Assert ($null -ne (Get-VATargetType textfile)) 'textfile type not registered'
        $out = Join-Path $tmp 'notify.txt'
        $pc = New-MockConfig; $pc.discord.webhookUrl = ''
        $pc.targets = @([pscustomobject]@{ type = 'textfile'; name = 'file'; path = $out; minSeverity = 'warning' })
        Assert (-not @(Test-VAConfig $pc).Count) ((Test-VAConfig $pc) -join '; ')
        Assert-Eq (Send-VAEvent -Config $pc -Event (New-VASessionEvent -Config $pc -Summary $failSummary)) 1
        Assert ((Get-Content $out -Raw) -match 'Prod VMs') 'report written'
        $pc.targets = @([pscustomobject]@{ type = 'textfile'; name = 'file' })
        Assert (@(Test-VAConfig $pc | Where-Object { $_ -like "*'file': path is required*" }).Count -eq 1) 'plugin validation not run'
    }
    finally { Remove-Item Env:VEEAMAWARE_PLUGIN_PATH; Import-Module (Join-Path $root 'src\VeeamAware.psm1') -Force }
}

Write-Host 'PowerShell data source'
. (Join-Path $PSScriptRoot 'MockVeeam.ps1')
& (Get-Module VeeamAware) {
    $p = Get-VAPSProfile -ModuleVersion ([version]'13.1.0.411')
    $script:VAPS = @{ Profile = $p.Profile; Files = $p.Files; ModuleVersion = [version]'13.1.0.411' }
    $script:VASource = 'powershell'
}
It 'selects and merges versioned profiles' {
    $dir = Join-Path $tmp 'profiles'; New-Item -ItemType Directory $dir -Force | Out-Null
    Copy-Item (Join-Path $root 'src\Profiles\PowerShell\13.0.psd1') $dir
    "@{ Progress = @{ Transferred = @('NewTransferred@bytes') }; Cmdlets = @{ MalwareEvents = 'Get-NewMalware' } }" | Set-Content (Join-Path $dir '14.0.psd1')
    $p13 = & (Get-Module VeeamAware) { param($d) Get-VAPSProfile -ModuleVersion ([version]'13.1.0.411') -Directory $d } $dir
    $p14 = & (Get-Module VeeamAware) { param($d) Get-VAPSProfile -ModuleVersion ([version]'14.0.1.5') -Directory $d } $dir
    Assert-Eq ($p13.Files -join ',') '13.0.psd1'
    Assert-Eq ($p14.Files -join ',') '13.0.psd1,14.0.psd1'
    Assert-Eq ($p14.Profile.Progress.Transferred -join ',') 'NewTransferred@bytes'
    Assert-Eq ($p14.Profile.Progress.Processed -join ',') 'ProcessedSize@bytes'   # inherited from 13.0
    Assert-Eq $p14.Profile.Cmdlets.MalwareEvents 'Get-NewMalware'
    Assert-Eq $p14.Profile.Cmdlets.TaskSessions 'Get-VBRTaskSession'
}
It 'maps a CBackupSession like the REST model' {
    $s = Get-VASession $MockVmSession.Id
    Assert-Eq $s.name 'SRV-DC01'; Assert-Eq $s.sessionType 'BackupJob'; Assert-Eq $s.result.result 'Success'
    # From Progress.StartTimeUtc, not Veeam's mislabelled CreationTimeUTC.
    Assert-Eq $s.creationTime ([datetimeoffset]$MockVmSession.Progress.StartTimeUtc).ToString('o')
    Assert-Eq $s.progress.bottleneck 'Target'; Assert-Eq $s.progress.transferredSize 3892121072
}
It 'builds a report with session totals, dedupe and compression' {
    $sum = Get-VASessionSummary -Session (Get-VASession $MockVmSession.Id) -TaskSessions @(Get-VATaskSessions $MockVmSession.Id) -Log @(Get-VASessionLog $MockVmSession.Id)
    Assert-Eq (Format-VASize $sum.Processed) '252 GB'; Assert-Eq (Format-VASize $sum.Transferred) '3.62 GB'
    Assert-Eq $sum.Bottleneck 'Target'; Assert-Eq $sum.Dedupe 1.3; Assert-Eq $sum.Compression 3
    Assert-Eq (Format-VADuration $sum.Duration) '25m 33s'
    Assert-Eq $sum.Tasks[0].Name 'SRV-DC01'
    Assert-Eq @($sum.ProblemLog).Count 1   # the EWarning record
    $e = New-VASessionEmbeds -Config $config -Summary $sum
    Assert-DiscordLimits $e | Out-Null
    Assert (($e[0].fields | Where-Object name -eq 'Bottleneck').value -eq 'Target') 'bottleneck field'
    if ($sum.Result -match '^Success') { Assert (($e[0].fields | Where-Object name -eq 'Compression').value -eq '3×') 'compression field' }
    $samples.Add(@{ Content = ''; Embeds = $e })
}
It 'adds job history and repository context' {
    $sum = Get-VASessionSummary -Session (Get-VASession $MockVmSession.Id) -TaskSessions @(Get-VATaskSessions $MockVmSession.Id)
    $h = @(Get-VAJobHistory -JobId "$($MockVmSession.JobId)")
    Assert-Eq $h.Count 1; Assert-Eq "$($h[0].id)" "$($MockVmSession.Id)"
    $sum.Result = 'Success'
    $ctx = Add-VASessionContext -Summary $sum
    Assert-Eq $ctx.Repository.Name 'nas-01'   # single repository: used without a job mapping
    $sum.Result = 'Failed'
    $ctx = Add-VASessionContext -Summary $sum
    Assert $ctx.HistoryKnown 'history read'
    Assert-Eq $ctx.FailStreak 1; Assert ($null -eq $ctx.LastSuccess) 'only run is this one'
}
It 'agent sessions resolve and are classified as agent' {
    $s = Get-VALatestJobSession $MockAgentSession.JobId
    Assert-Eq $s.sessionType 'AgentBackup'; Assert (Test-VAAgentSession $s)
    $sum = Get-VASessionSummary -Session $s -TaskSessions @(Get-VATaskSessions $s.id)
    Assert ($null -eq $sum.Transferred) 'agent Transferred is not tracked by Veeam and must show as no data, not 0 B'
    Assert-Eq (Format-VASize $sum.BackupSize) '1.5 GB'   # from this session's restore point, not yesterday's
    Assert-Eq $sum.Compression 2; Assert-Eq (Format-VASize $sum.Processed) '1.95 TB'
}
It 'lists recent sessions from both VM and agent cmdlets without duplicates' {
    $all = @(Get-VASessions -EndedAfter ([datetimeoffset]::UtcNow.AddDays(-2)))
    Assert-Eq $all.Count 2
}
It 'builds history-only agent sessions from the thin record, named after the newest full one' {
    $older = [pscustomobject]@{ Id = [guid]::NewGuid(); JobId = $MockAgentThin.JobId; Name = 'x'; Result = 'Failed'; State = 'Stopped'
        CreationTime = $MockAgentThin.CreationTime.AddDays(-2); EndTime = $MockAgentThin.EndTime.AddDays(-2) }
    $saved = ${function:global:Get-VBRComputerBackupJobSession}
    try {
        ${function:global:Get-VBRComputerBackupJobSession} = { [CmdletBinding()] param() $older; $MockAgentThin }.GetNewClosure()
        $all = @(Get-VASessions -EndedAfter ([datetimeoffset]::UtcNow.AddDays(-7)) -DetailAfter ([datetimeoffset]::UtcNow.AddDays(-1)))
        $thin = @($all | Where-Object { "$($_.id)" -eq "$($older.Id)" })
        Assert-Eq $thin.Count 1
        Assert ([bool]$thin[0].PSObject.Properties['thin'])
        Assert-Eq $thin[0].name 'WS-ACCT-01'; Assert-Eq $thin[0].result.result 'Failed'
        Assert (Test-VAAgentSession $thin[0]); Assert (Test-VAReportableSession $thin[0])
        $full = @($all | Where-Object { "$($_.id)" -eq "$($MockAgentThin.Id)" })
        Assert (-not $full[0].PSObject.Properties['thin'])
    }
    finally { ${function:global:Get-VBRComputerBackupJobSession} = $saved }
}
It 'reads repository space from container size objects' {
    $r = @(Get-VARepositoryStates)
    Assert-Eq $r[0].name 'nas-01'; Assert-Eq $r[0].capacityGB ([Math]::Round(5896045584384 / 1GB, 2)); Assert-Eq $r[0].freeGB ([Math]::Round(3424637059072 / 1GB, 2))
    Assert-Eq (Get-VARepositoryLevel (Get-VARepositoryInfo $r[0]) $config.watch.repositories) 'ok'
}
It 'analyzer results get stable ids and a run signature' {
    $bp = @(Get-VAAnalyzerBestPractices)
    Assert-Eq $bp[0].id 'MfaEnabledInBackupConsole'; Assert-Eq $bp[0].bestPractice 'Mfa Enabled In Backup Console'
    $r1 = (Get-VAAnalyzerLastRun).id; $r2 = (Get-VAAnalyzerLastRun).id
    Assert-Eq $r1 $r2
}
It 'unsupported features are skipped quietly' {
    $x = Test-VARestOptional -What 'authorization events' { Get-VAAuthorizationEvents }
    Assert ($null -eq $x)
}

Write-Host 'Installer target setup'
$exampleJson = { Get-Content -Raw (Join-Path $root 'config\config.example.json') | ConvertFrom-Json }
It 'example config lists no targets until one is added' {
    $j = & $exampleJson
    Assert-Eq @(Get-VASetupTargets $j).Count 0   # placeholder Discord URL and disabled examples don't count
}
It 'adds two Discord channels, Teams and a webhook, and the result validates' {
    $j = & $exampleJson; $j.discord.webhookUrl = ''
    Assert-Eq (Add-VASetupTarget -Json $j -Type discord -Url 'https://discord.com/api/webhooks/1/aaa') 'discord'
    Assert-Eq (Add-VASetupTarget -Json $j -Type discord -Url 'https://discord.com/api/webhooks/2/bbb' -MinSeverity critical) 'discord-2'
    Assert-Eq (Add-VASetupTarget -Json $j -Type teams -Url 'https://prod.logic.azure.com/workflows/x' -MinSeverity warning) 'teams'
    Assert-Eq (Add-VASetupTarget -Json $j -Type webhook -Name n8n -Url 'https://n8n.example.com/h' -Options @{ headers = @{ 'X-Env' = 'lab' } }) 'n8n'
    Assert-Eq $j.discord.webhookUrl 'https://discord.com/api/webhooks/1/aaa'   # first one fills the top-level block
    Assert-Eq ((Get-VASetupTargets $j | ForEach-Object Name) -join ',') 'discord,discord-2,teams,n8n'
    Assert-Eq @($j.targets | Where-Object name -eq 'teams').Count 1            # replaced the disabled example
    $tmpCfg = Join-Path $tmp 'setup-config.json'
    $j | ConvertTo-Json -Depth 20 | Set-Content $tmpCfg -Encoding utf8NoBOM
    $c = Get-VAConfig -Path $tmpCfg
    Assert-Eq ((Get-VATargets $c | ForEach-Object name) -join ',') 'discord,discord-2,teams,n8n'
    Import-Module (Join-Path $root 'src\VeeamAware.psm1') -Force   # Get-VAConfig above changed the active config
}
It 'rejects bad URLs, duplicate names and duplicate URLs' {
    $j = & $exampleJson; $j.discord.webhookUrl = ''
    Add-VASetupTarget -Json $j -Type discord -Url 'https://discord.com/api/webhooks/1/aaa' | Out-Null
    Assert ((Test-VASetupTarget $j discord x 'https://example.com/hook') -match "doesn't look like") 'bad discord url'
    Assert ((Test-VASetupTarget $j teams discord 'https://x.example/y') -match 'already exists') 'dup name'
    Assert ((Test-VASetupTarget $j discord other 'https://discord.com/api/webhooks/1/aaa') -match 'already posts') 'dup url'
}
It 'removes targets from the block and from the list' {
    $j = & $exampleJson; $j.discord.webhookUrl = ''
    Add-VASetupTarget -Json $j -Type discord -Url 'https://discord.com/api/webhooks/1/aaa' | Out-Null
    Add-VASetupTarget -Json $j -Type teams -Url 'https://prod.logic.azure.com/workflows/x' | Out-Null
    Remove-VASetupTarget -Json $j -Name discord; Remove-VASetupTarget -Json $j -Name teams
    Assert-Eq @(Get-VASetupTargets $j).Count 0
}
It 'sets Discord mentions and digest targets from the installer' {
    $j = & $exampleJson; $j.discord.webhookUrl = ''
    Add-VASetupTarget -Json $j -Type discord -Url 'https://discord.com/api/webhooks/1/aaa' | Out-Null
    Add-VASetupTarget -Json $j -Type discord -Url 'https://discord.com/api/webhooks/2/bbb' | Out-Null
    Add-VASetupTarget -Json $j -Type teams -Url 'https://prod.logic.azure.com/workflows/x' | Out-Null
    Assert (Test-VAMentionText '<@&123> @here, <@456>') 'valid mentions'
    Assert (-not (Test-VAMentionText '@ops')) 'plain names are not mentions'
    Set-VASetupMentions -Json $j -Name discord -Kinds Failure, Security -Mentions @('<@&123>')
    Set-VASetupMentions -Json $j -Name discord-2 -Kinds Failure -Mentions @('@here')
    Assert-Eq ((Get-VASetupMentions $j discord Security) -join ',') '<@&123>'
    Assert-Eq ((Get-VASetupMentions $j discord-2 Failure) -join ',') '@here'
    $threw = $false; try { Set-VASetupMentions -Json $j -Name teams -Kinds Failure -Mentions @('@here') } catch { $threw = $true }
    Assert $threw 'teams has no mentions'
    $d = Get-VASetupDigest $j
    Set-VASetupDigestTargets -Digest $d -Names @('discord-2', 'teams') -All @('discord', 'discord-2', 'teams')
    Assert-Eq (@($d.targets) -join ',') 'discord-2,teams'
    Set-VASetupDigestTargets -Digest $d -Names @('discord', 'discord-2', 'teams') -All @('discord', 'discord-2', 'teams')
    Assert-Eq (@($d.targets) -join ',') '*'
    Set-VASetupDigestTargets -Digest $d -Names @('teams') -All @('discord', 'discord-2', 'teams')
    Remove-VASetupTarget -Json $j -Name teams
    Assert-Eq (@($d.targets) -join ',') '*'   # its only target was removed: back to all
}
It 'reads -Target specs' {
    $t = ConvertFrom-VATargetSpec 'teams:ops@warning=https://x.example/y'
    Assert-Eq "$($t.Type)|$($t.Name)|$($t.MinSeverity)|$($t.Url)" 'teams|ops|warning|https://x.example/y'
    Assert-Eq (ConvertFrom-VATargetSpec 'discord=https://d/1').MinSeverity 'info'
    Assert-Eq (Format-VAMaskedUrl 'https://discord.com/api/webhooks/1/secret') 'https://discord.com/…'
}

Write-Host 'Installer settings menu'
It 'reads current values with defaults, writes only what changes' {
    $j = [pscustomobject]@{ watch = [pscustomobject]@{ intervalMinutes = 10 } }
    Assert-Eq (Get-VASetupValue $j 'watch.intervalMinutes') 10
    Assert-Eq (Get-VASetupValue $j 'watch.health.repeatEveryMinutes') 60   # default
    Set-VASetupValue $j 'watch.health.repeatEveryMinutes' 120
    Set-VASetupValue $j 'watch.health.sessions.enabled' $false
    Assert-Eq (Get-VASetupValue $j 'watch.health.repeatEveryMinutes') 120
    Assert-Eq (Get-VASetupValue $j 'watch.health.firstAlertAfterMinutes') 15   # untouched keys keep their defaults
    $out = $j | ConvertTo-Json -Depth 10 -Compress
    Assert-Eq $out '{"watch":{"intervalMinutes":10,"health":{"repeatEveryMinutes":120,"sessions":{"enabled":false}}}}'
    # a re-read sees the saved values as the new defaults
    $j2 = $out | ConvertFrom-Json
    Assert-Eq (Get-VASetupValue $j2 'watch.health.sessions.enabled') $false
    Assert-Eq (Get-VASetupValue $j2 'watch.health.sessions.minHours') 2
}
It 'agent routing modes read and write the agent rule' {
    $j = & $exampleJson
    Assert-Eq (Get-VASetupAgentMode $j) 'failures'
    Set-VASetupAgentMode $j 'all'
    Assert-Eq (Get-VASetupAgentMode $j) 'all'
    Assert-Eq @($j.routing.rules).Count 2   # replaced in place, not added
    $r = Get-VASessionRoute -Config (Merge-VAConfig (Get-VADefaultConfig) ($j | ConvertTo-Json -Depth 20 | ConvertFrom-Json)) `
        -Session ([pscustomobject]@{ name = 'WS-ACCT-01'; sessionType = 'AgentBackup'; result = [pscustomobject]@{ result = 'Success' } })
    Assert-Eq $r.Mode 'immediate'
    $bare = [pscustomobject]@{ routing = [pscustomobject]@{ rules = @([pscustomobject]@{ name = 'all'; match = [pscustomobject]@{ jobs = @('*') }; success = 'immediate'; warning = 'immediate'; failure = 'immediate' }) } }
    Assert ($null -eq (Get-VASetupAgentMode $bare))
    Set-VASetupAgentMode $bare 'digest'
    Assert-Eq @($bare.routing.rules).Count 2
    Assert-Eq (@($bare.routing.rules)[0].failure) 'digest'   # added first, so it wins over the catch-all
}
It 'menu summary shows the current settings' {
    $j = & $exampleJson
    $j.discord.webhookUrl = 'https://discord.com/api/webhooks/1/aaa'
    Set-VASetupValue $j 'watch.health.repeatEveryMinutes' 0
    $s = Get-VASetupSummary $j
    Assert-Eq $s.targets.Value 'discord'
    Assert-Eq $s.health.Value 'on, alert after 15 min, repeat never'
    Assert-Eq $s.digest.Value "'daily' daily at 08:00"
    Assert-Eq $s.agents.Value 'failures right away, the rest in the digest'
    # Every value fits beside its label on an 80-column console.
    foreach ($v in $s.Values) { Assert ((6 + 12 + 2 + "$($v.Value)".Length) -le 79) "too wide: $($v.Value)" }
    Assert-Eq $s.watch.Value 'every 5 min'
    Set-VASetupValue $j 'watch.health.enabled' $false
    Assert-Eq (Get-VASetupSummary $j).health.Value 'off'
    Assert-Eq (Format-VAMinutes 120) '2 h'; Assert-Eq (Format-VAMinutes 1440) '1 d'; Assert-Eq (Format-VAMinutes 45) '45 min'
}

Write-Host 'Health'
$t0 = [datetimeoffset]'2026-11-06T10:00:00Z'
$svcCfg = (New-MockConfig).watch.health.services
$hsCfg = (New-MockConfig).watch.health
function New-Svc([string]$Name, [string]$Status) { [pscustomobject]@{ Name = $Name; DisplayName = "Veeam $Name"; Status = $Status; StartType = 'Automatic' } }
function New-RunSession([string]$Id, [double]$HoursAgo, [string]$Type = 'BackupJob', [string]$State = 'Working', $Pct = 40, $Now = $t0) {
    [pscustomobject]@{ id = $Id; jobId = "job-$Id"; name = "Job $Id"; sessionType = $Type; state = $State; endTime = $null
        creationTime = $Now.AddHours(-$HoursAgo).ToString('o'); progress = [pscustomobject]@{ progressPercent = $Pct; processedSize = 1GB; transferredSize = 1MB } }
}

It 'service alert waits for the grace period, sends once, then recovers' {
    $h = New-VAHealthState
    $down = @((New-Svc 'VeeamBackupSvc' 'Stopped'), (New-Svc 'VeeamBrokerSvc' 'Running'))
    Assert-Eq (Update-VAServiceHealth $svcCfg $down $h $t0).Events.Count 0
    Assert-Eq (Update-VAServiceHealth $svcCfg $down $h $t0.AddMinutes(10)).Events.Count 0
    $r = Update-VAServiceHealth $svcCfg $down $h $t0.AddMinutes(16)
    Assert-Eq $r.Events.Count 1
    $e = $r.Events[0]
    Assert-Eq "$($e.kind)|$($e.severity)|$($e.resolved)" 'health|critical|False'
    Assert ($e.fingerprint -match '/health/services$') $e.fingerprint
    Assert ($e.title -match 'not running') $e.title
    Assert-Eq (Update-VAServiceHealth $svcCfg $down $h $t0.AddMinutes(21)).Events.Count 0
    $up = @((New-Svc 'VeeamBackupSvc' 'Running'), (New-Svc 'VeeamBrokerSvc' 'Running'))
    $r = Update-VAServiceHealth $svcCfg $up $h $t0.AddMinutes(26)
    Assert-Eq $r.Events.Count 1
    Assert-Eq "$($r.Events[0].severity)|$($r.Events[0].resolved)" 'success|True'
    Assert-Eq @($h.servicesAlerted).Count 0
    Assert-Eq (Update-VAServiceHealth $svcCfg $up $h $t0.AddMinutes(31)).Events.Count 0
}
It 'a service that restarts within the grace period sends nothing' {
    $h = New-VAHealthState
    Update-VAServiceHealth $svcCfg @(New-Svc 'VeeamBackupSvc' 'StartPending') $h $t0 | Out-Null
    Assert-Eq (Update-VAServiceHealth $svcCfg @(New-Svc 'VeeamBackupSvc' 'Running') $h $t0.AddMinutes(5)).Events.Count 0
    Assert-Eq (Update-VAServiceHealth $svcCfg @(New-Svc 'VeeamBackupSvc' 'Stopped') $h $t0.AddMinutes(10)).Events.Count 0
    Assert-Eq "$($h.serviceDownSince['VeeamBackupSvc'])" '2026-11-06T10:10:00Z'   # timer restarted
}
It 'a second service going down updates the alert' {
    $h = New-VAHealthState
    Update-VAServiceHealth $svcCfg @(New-Svc 'A' 'Stopped') $h $t0 | Out-Null
    Assert-Eq (Update-VAServiceHealth $svcCfg @(New-Svc 'A' 'Stopped') $h $t0.AddMinutes(15)).Events.Count 1
    Update-VAServiceHealth $svcCfg @((New-Svc 'A' 'Stopped'), (New-Svc 'B' 'Stopped')) $h $t0.AddMinutes(20) | Out-Null
    $r = Update-VAServiceHealth $svcCfg @((New-Svc 'A' 'Stopped'), (New-Svc 'B' 'Stopped')) $h $t0.AddMinutes(35)
    Assert-Eq $r.Events.Count 1
    Assert-Eq @($r.Events[0].details.services).Count 2
    Assert-Eq (@($r.Events[0].details.new) -join ',') 'B'
    # one recovers, one still down: no "recovered" yet
    Assert-Eq (Update-VAServiceHealth $svcCfg @((New-Svc 'A' 'Running'), (New-Svc 'B' 'Stopped')) $h $t0.AddMinutes(40)).Events.Count 0
    Assert-Eq (@($h.servicesAlerted) -join ',') 'A,B'   # same outage until everything is back
    $r = Update-VAServiceHealth $svcCfg @((New-Svc 'A' 'Running'), (New-Svc 'B' 'Running')) $h $t0.AddMinutes(45)
    Assert-Eq (@($r.Events[0].details.recovered) -join ',') 'A,B'
}
It 'reminders repeat while a service stays down; recovery waits for back up for' {
    $tm = [pscustomobject]@{ FirstAlertAfter = 15; RepeatEvery = 60; BackUpFor = 5 }
    $h = New-VAHealthState
    $down = @(New-Svc 'VeeamBackupSvc' 'Stopped'); $up = @(New-Svc 'VeeamBackupSvc' 'Running')
    Update-VAServiceHealth $svcCfg $down $h $t0 -Timing $tm | Out-Null
    Assert-Eq (Update-VAServiceHealth $svcCfg $down $h $t0.AddMinutes(15) -Timing $tm).Events.Count 1
    Assert-Eq (Update-VAServiceHealth $svcCfg $down $h $t0.AddMinutes(70) -Timing $tm).Events.Count 0   # 55 min since the alert
    $r = Update-VAServiceHealth $svcCfg $down $h $t0.AddMinutes(75) -Timing $tm
    Assert-Eq $r.Events.Count 1
    Assert-Eq $r.Events[0].details.reminder 1
    Assert ($r.Events[0].title -match 'reminder 1') $r.Events[0].title
    Assert-Eq $r.Events[0].report.label 'STILL STOPPED'
    Assert-Eq (Update-VAServiceHealth $svcCfg $down $h $t0.AddMinutes(135) -Timing $tm).Events[0].details.reminder 2
    # back up, but only for 3 minutes before relapsing: no recovery, no new alert, same outage
    Assert-Eq (Update-VAServiceHealth $svcCfg $up $h $t0.AddMinutes(140) -Timing $tm).Events.Count 0
    Assert-Eq (Update-VAServiceHealth $svcCfg $down $h $t0.AddMinutes(143) -Timing $tm).Events.Count 0
    Assert-Eq (Update-VAServiceHealth $svcCfg $up $h $t0.AddMinutes(150) -Timing $tm).Events.Count 0
    $r = Update-VAServiceHealth $svcCfg $up $h $t0.AddMinutes(155) -Timing $tm
    Assert-Eq "$($r.Events.Count)|$($r.Events[0].resolved)" '1|True'
    Assert-Eq "$($h.servicesReminders)|$($h.servicesAlertedAt)|$(@($h.servicesAlerted).Count)" '0||0'
    # repeat 0 = alert once
    $once = [pscustomobject]@{ FirstAlertAfter = 15; RepeatEvery = 0; BackUpFor = 0 }
    $h = New-VAHealthState
    Update-VAServiceHealth $svcCfg $down $h $t0 -Timing $once | Out-Null
    Update-VAServiceHealth $svcCfg $down $h $t0.AddMinutes(15) -Timing $once | Out-Null
    Assert-Eq (Update-VAServiceHealth $svcCfg $down $h $t0.AddHours(10) -Timing $once).Events.Count 0
}
It 'an outage alerted by an older version still gets reminders' {
    $tm = [pscustomobject]@{ FirstAlertAfter = 15; RepeatEvery = 60; BackUpFor = 5 }
    $h = New-VAHealthState
    $h.servicesAlerted = @('VeeamPl9Svc'); $h.serviceDownSince['VeeamPl9Svc'] = '2026-11-06T09:00:00Z'   # no servicesAlertedAt
    $down = @(New-Svc 'VeeamPl9Svc' 'Stopped')
    Assert-Eq (Update-VAServiceHealth $svcCfg $down $h $t0 -Timing $tm).Events.Count 0
    Assert-Eq "$($h.servicesAlertedAt)" '2026-11-06T10:00:00Z'
    Assert-Eq (Update-VAServiceHealth $svcCfg $down $h $t0.AddMinutes(60) -Timing $tm).Events[0].details.reminder 1
}
It 'service cards use the job-report layout' {
    $h = New-VAHealthState
    $svc = New-Svc 'VeeamPl9Svc' 'Stopped'
    $why = { param($s, $since) [pscustomobject]@{ Text = "The $($s.DisplayName) service terminated unexpectedly." } }
    Update-VAServiceHealth $svcCfg @($svc) $h $t0 -StopReason $why | Out-Null
    $rep = (Update-VAServiceHealth $svcCfg @($svc) $h $t0.AddMinutes(15) -StopReason $why).Events[0].report
    Assert-Eq "$($rep.header)|$($rep.title)|$($rep.label)|$($rep.icon)" 'Veeam service|Veeam VeeamPl9Svc|STOPPED|❌'
    Assert ($rep.quotes[0].text -match 'terminated unexpectedly') 'stop reason quoted'
    Assert-Eq (@($rep.facts | ForEach-Object { $_.name }) -join ',') 'Service,State,Start type'
    Assert ($rep.summary[0].Contains('time')) 'since is a time part (rendered in local time)'
    Assert-Eq $rep.summary[1] 'down 15m'
    # several: a table, like a job's objects
    $two = New-VAServiceAlertEvent -Down @($svc, (New-Svc 'VeeamCatalogSvc' 'Stopped')) -Since $h.serviceDownSince -Now $t0.AddMinutes(20)
    Assert-Eq "$($two.report.title)|$($two.report.sections[0].type)|$(@($two.report.sections[0].rows).Count)" '2 Veeam services|objects|2'
    # recovery shows how long it was down
    $r = Update-VAServiceHealth $svcCfg @(New-Svc 'VeeamPl9Svc' 'Running') $h $t0.AddMinutes(45)
    Assert-Eq "$($r.Events[0].report.label)|$($r.Events[0].report.summary[-1])" 'RUNNING AGAIN|down 45m'
}
It 'timings: shared under watch.health, overridable per check, graceMinutes still read' {
    $hcfg = (New-MockConfig).watch.health
    $tm = Get-VAHealthTiming $hcfg 'services'
    Assert-Eq "$($tm.FirstAlertAfter)|$($tm.RepeatEvery)|$($tm.BackUpFor)" '15|60|5'
    $hcfg.sessions.repeatEveryMinutes = 240
    Assert-Eq (Get-VAHealthTiming $hcfg 'sessions').RepeatEvery 240
    $hcfg.services.graceMinutes = 10
    Assert-Eq (Get-VAHealthTiming $hcfg 'services').FirstAlertAfter 10
}
It 'stuck sessions and watcher failures send reminders' {
    $tm = [pscustomobject]@{ FirstAlertAfter = 0; RepeatEvery = 60; BackUpFor = 0 }
    $h = New-VAHealthState
    $s = New-RunSession 'r' 13
    Assert-Eq (Update-VAStuckSessions $stuckCfg @($s) $h $t0 -Timing $tm).Events.Count 1
    Assert-Eq (Update-VAStuckSessions $stuckCfg @($s) $h $t0.AddMinutes(30) -Timing $tm).Events.Count 0
    $r = Update-VAStuckSessions $stuckCfg @($s) $h $t0.AddMinutes(60) -Timing $tm
    Assert-Eq "$($r.Events.Count)|$($r.Events[0].details.reminder)" '1|1'
    Assert ($r.Events[0].title -match 'still appears stuck') $r.Events[0].title
    $wc = (New-MockConfig).watch.health.watcher
    $h = New-VAHealthState
    foreach ($m in 0, 5, 10) { Update-VAWatcherHealth $wc $h $t0.AddMinutes($m) -Failed -ErrorMessage 'x' -Timing $tm | Out-Null }
    Assert $h.watchAlerted
    Assert-Eq (Update-VAWatcherHealth $wc $h $t0.AddMinutes(40) -Failed -ErrorMessage 'x' -Timing $tm).Events.Count 0
    $r = Update-VAWatcherHealth $wc $h $t0.AddMinutes(70) -Failed -ErrorMessage 'x' -Timing $tm
    Assert-Eq "$($r.Events.Count)|$($r.Events[0].details.reminder)" '1|1'
}
It 'quiet periods hold service alerts and restart the timers' {
    $h = New-VAHealthState
    $down = @(New-Svc 'VeeamBackupSvc' 'Stopped')
    Update-VAServiceHealth $svcCfg $down $h $t0 | Out-Null
    Assert-Eq (Update-VAServiceHealth $svcCfg $down $h $t0.AddMinutes(20) -Quiet).Events.Count 0
    Assert-Eq (Update-VAServiceHealth $svcCfg $down $h $t0.AddMinutes(30)).Events.Count 0   # 10 min since the quiet run
    Assert-Eq (Update-VAServiceHealth $svcCfg $down $h $t0.AddMinutes(36)).Events.Count 1
}
It 'detects an upgrade from an installer process and settles afterwards' {
    $h = New-VAHealthState; $h.vbrVersion = '13.1.0.411'
    $sig = [pscustomobject]@{ Installers = @('Veeam.Backup.Setup.exe (42)'); MsiInProgress = $false; Version = '13.1.0.411' }
    $q = Update-VAQuietState $hsCfg $sig $h $t0 $true
    Assert $q.Quiet; Assert ($q.Reason -match 'upgrade in progress') $q.Reason
    $done = [pscustomobject]@{ Installers = @(); MsiInProgress = $false; Version = '13.1.1.100' }
    $q = Update-VAQuietState $hsCfg $done $h $t0.AddMinutes(40) $false
    Assert $q.Quiet 'quiet after the version changed'
    Assert-Eq $q.Events.Count 1
    Assert-Eq "$($q.Events[0].kind)|$($q.Events[0].severity)" 'health|info'
    Assert ($q.Events[0].title -match '13\.1\.1\.100') $q.Events[0].title
    Assert-Eq $h.vbrVersion '13.1.1.100'
    $q = Update-VAQuietState $hsCfg $done $h $t0.AddMinutes(75) $false
    Assert (-not $q.Quiet) "still quiet: $($q.Reason)"
    Assert-Eq $q.Events.Count 0
}
It 'Windows Installer activity counts only while Veeam services are down' {
    $sig = [pscustomobject]@{ Installers = @(); MsiInProgress = $true; Version = $null }
    Assert (-not (Update-VAQuietState $hsCfg $sig (New-VAHealthState) $t0 $false).Quiet)
    Assert ((Update-VAQuietState $hsCfg $sig (New-VAHealthState) $t0 $true).Quiet)
}
It 'an installer signal that never goes away stops pausing alerts' {
    $h = New-VAHealthState; $h.upgradeSince = '2026-11-06T03:00:00Z'
    $sig = [pscustomobject]@{ Installers = @('VeeamSetupHelper.exe (7)'); MsiInProgress = $false; Version = $null }
    Assert (-not (Update-VAQuietState $hsCfg $sig $h $t0 $false).Quiet)
}
It 'a whole upgrade, run by run like the watcher, sends no service alert' {
    # 5-minute watcher, first alert after 5 min (the threshold for the live test). Setup wizard first, then
    # installer stages with gaps between them, a run that sees no signal at all, then services back.
    $tm = [pscustomobject]@{ FirstAlertAfter = 5; RepeatEvery = 60; BackUpFor = 5 }
    $h = New-VAHealthState; $h.vbrVersion = '13.1.0.411'
    $sig = { param($inst, $msi, $svc, $ver = '13.1.0.411') [pscustomobject]@{ Installers = @($inst | Where-Object { $_ }); MsiInProgress = $msi; MsiService = $svc; Version = $ver } }
    $up = @(New-Svc 'VeeamBackupSvc' 'Running'), (New-Svc 'VeeamMountSvc' 'Running')
    $down = @(New-Svc 'VeeamBackupSvc' 'Stopped'), (New-Svc 'VeeamMountSvc' 'Stopped')
    $late = @(New-Svc 'VeeamBackupSvc' 'Running'), (New-Svc 'VeeamMountSvc' 'Stopped')
    $runs = @(
        ,@(0, (& $sig $null $false $false), $up, $false)
        ,@(5, (& $sig 'Setup.exe (10)' $false $false), $up, $true)               # wizard open (Veeam-signed, from the ISO)
        ,@(10, (& $sig 'Setup.exe (10)' $true $true), $down, $true)
        ,@(15, (& $sig 'Setup.exe (10)' $true $true), $down, $true)
        ,@(20, (& $sig $null $false $true), $down, $true)                         # between stages: only msiserver up
        ,@(25, (& $sig $null $false $false $null), $down, $false)                 # nothing visible, exe mid-replace
        ,@(30, (& $sig 'Setup.exe (10)' $true $true $null), $down, $true)
        ,@(35, (& $sig $null $false $false '13.1.1.100'), $late, $false)          # done; one service still starting
        ,@(40, (& $sig $null $false $false '13.1.1.100'), $up, $false)
        ,@(45, (& $sig $null $false $false '13.1.1.100'), $up, $false)
    )
    $sent = @()
    foreach ($r in $runs) {
        $now = $t0.AddMinutes($r[0]); $svcs = $r[2]
        $q = Update-VAQuietState $hsCfg $r[1] $h $now ([bool]@($svcs | Where-Object Status -ne 'Running').Count)
        if ($q.Upgrading -ne $r[3]) { throw "upgrading at +$($r[0]): $($q.Upgrading)" }
        $sent += @($q.Events) + @((Update-VAServiceHealth $svcCfg $svcs $h $now -Quiet:$q.Quiet -Timing $tm).Events)
    }
    Assert-Eq (@($sent | ForEach-Object { $_.status }) -join ',') 'Updated'
    Assert-Eq "$($h.upgradeSince)" ''
    # A service that never comes back is reported once the settle period is over.
    $q = Update-VAQuietState $hsCfg (& $sig $null $false $false '13.1.1.100') $h $t0.AddMinutes(70) $true
    Assert (-not $q.Quiet) $q.Reason
    Update-VAServiceHealth $svcCfg $late $h $t0.AddMinutes(70) -Timing $tm | Out-Null
    $r = Update-VAServiceHealth $svcCfg $late $h $t0.AddMinutes(75) -Timing $tm
    Assert-Eq (@($r.Events | ForEach-Object status) -join ',') 'ServiceDown'
}
It 'Windows Installer service running counts only while services are down' {
    $sig = [pscustomobject]@{ Installers = @(); MsiInProgress = $false; MsiService = $true; Version = $null }
    Assert (-not (Update-VAQuietState $hsCfg $sig (New-VAHealthState) $t0 $false).Quiet)
    $q = Update-VAQuietState $hsCfg $sig (New-VAHealthState) $t0 $true
    Assert ($q.Quiet -and $q.Upgrading)
}
It 'settling after an upgrade is quiet but lets the watcher read VBR' {
    $h = New-VAHealthState; $h.quietUntil = '2026-11-06T10:20:00Z'
    $q = Update-VAQuietState $hsCfg ([pscustomobject]@{ Installers = @(); MsiInProgress = $false; MsiService = $false; Version = $null }) $h $t0 $false
    Assert ($q.Quiet -and -not $q.Upgrading) "$($q.Quiet) $($q.Upgrading)"
}
It 'no "watcher not running" alert during or just after an upgrade' {
    $c = New-MockConfig
    $st = [ordered]@{ lastWatchUtc = $t0.AddHours(-2).ToString('o'); health = New-VAHealthState }
    $st.health.upgradeSince = $t0.AddMinutes(-90).ToString('o')
    Assert ($null -eq (Get-VAWatcherStaleEvent -Config $c -State $st -Now $t0)) 'during'
    $st.health.upgradeSince = $null; $st.health.quietUntil = $t0.AddMinutes(10).ToString('o')
    Assert ($null -eq (Get-VAWatcherStaleEvent -Config $c -State $st -Now $t0)) 'settling'
}
It 'maintenance mode is quiet until it ends' {
    $h = New-VAHealthState; $h.maintenanceUntil = '2026-11-06T11:00:00Z'; $h.maintenanceReason = 'patching'
    $q = Update-VAQuietState $hsCfg $null $h $t0 $false
    Assert $q.Quiet; Assert ($q.Reason -match 'patching') $q.Reason
    Assert (-not (Update-VAQuietState $hsCfg $null $h $t0.AddHours(2) $false).Quiet)
}

$stuckCfg = (New-MockConfig).watch.health.sessions
It 'stuck sessions: usual run time, minimum, no history, exclusions' {
    $script:calls = 0
    $typ = { param($s) $script:calls++; switch ($s.id) { 'fast' { [timespan]::FromMinutes(30) } 'slow' { [timespan]::FromHours(2) } default { $null } } }
    $sessions = @(
        (New-RunSession 'fast' 3)                              # 3 h, usually 30 min: limit max(2 h, 1.5 h) -> stuck
        (New-RunSession 'slow' 3)                              # 3 h, usually 2 h: limit 6 h -> fine
        (New-RunSession 'nohist' 3)                            # 3 h, no history: limit 12 h -> fine
        (New-RunSession 'young' 1)                             # under minHours: history not even asked
        (New-RunSession 'copy' 30 'BackupCopyJob')             # backup copy: excluded
        (New-RunSession 'idle' 30 'BackupJob' 'Idle')          # waiting: excluded
    )
    $h = New-VAHealthState
    $r = Update-VAStuckSessions $stuckCfg $sessions $h $t0 -TypicalDuration $typ
    Assert-Eq (@($r.Events | ForEach-Object { $_.details.sessionId }) -join ',') 'fast'
    Assert-Eq $script:calls 3
    $e = $r.Events[0]
    Assert-Eq "$($e.kind)|$($e.severity)" 'health|warning'
    Assert ($e.fingerprint -match '/job/job-fast$') "same fingerprint as the job's report: $($e.fingerprint)"
    # next run: no repeat, history not asked again
    $r = Update-VAStuckSessions $stuckCfg $sessions $h $t0.AddMinutes(5) -TypicalDuration $typ
    Assert-Eq $r.Events.Count 0; Assert-Eq $script:calls 3
    # no history: stuck after 12 h
    $late = @(New-RunSession 'nohist' 12.5)
    $r = Update-VAStuckSessions $stuckCfg $late (New-VAHealthState) $t0 -TypicalDuration $typ
    Assert-Eq $r.Events.Count 1
}
It 'stuck sessions: a per-job limit applies as given, below minHours too' {
    $cfg = (New-MockConfig).watch.health.sessions
    $s = New-RunSession 'quick' 0.1
    $cfg.jobs = @([ordered]@{ job = $s.name; hours = 0.05 })
    Assert-Eq (Update-VAStuckSessions $cfg @($s) (New-VAHealthState) $t0).Events.Count 1
    $other = New-RunSession 'other' 0.1
    Assert-Eq (Update-VAStuckSessions $cfg @($other) (New-VAHealthState) $t0).Events.Count 0
}
It 'stuck sessions: no progress for noProgressMinutes' {
    $h = New-VAHealthState
    $s = New-RunSession 'stall' 0.5 -Pct 55
    Assert-Eq (Update-VAStuckSessions $stuckCfg @($s) $h $t0).Events.Count 0
    $s2 = New-RunSession 'stall' 0.5 -Pct 60 -Now $t0.AddHours(2)   # moved: timer restarts
    $s2.creationTime = $s.creationTime
    Assert-Eq (Update-VAStuckSessions $stuckCfg @($s2) $h $t0.AddHours(2)).Events.Count 0
    $r = Update-VAStuckSessions $stuckCfg @($s2) $h $t0.AddHours(6.1)
    Assert-Eq $r.Events.Count 1
    Assert-Eq $r.Events[0].details.reason 'stalled'
    # finished: forgotten
    Update-VAStuckSessions $stuckCfg @() $h $t0.AddHours(7) | Out-Null
    Assert-Eq @($h.stuckAlerted).Count 0; Assert-Eq $h.sessionProgress.Count 0
}
It 'stuck sessions: per-job limits' {
    $c = (New-MockConfig).watch.health.sessions
    $c.jobs = @([pscustomobject]@{ job = 'Job big*'; hours = 24 })
    $typ = { param($s) [timespan]::FromMinutes(10) }
    Assert-Eq (Update-VAStuckSessions $c @(New-RunSession 'big1' 20) (New-VAHealthState) $t0 -TypicalDuration $typ).Events.Count 0
    Assert-Eq (Update-VAStuckSessions $c @(New-RunSession 'small' 20) (New-VAHealthState) $t0 -TypicalDuration $typ).Events.Count 1
}
It 'watcher failures alert after three in a row, once, and recover' {
    $wc = (New-MockConfig).watch.health.watcher
    $h = New-VAHealthState
    Assert-Eq (Update-VAWatcherHealth $wc $h $t0 -Failed -ErrorMessage 'boom').Events.Count 0
    Assert-Eq (Update-VAWatcherHealth $wc $h $t0.AddMinutes(5) -Failed -ErrorMessage 'boom' -Quiet).Events.Count 0   # not counted
    Assert-Eq $h.watchFailures 1
    Assert-Eq (Update-VAWatcherHealth $wc $h $t0.AddMinutes(10) -Failed -ErrorMessage 'boom').Events.Count 0
    $r = Update-VAWatcherHealth $wc $h $t0.AddMinutes(15) -Failed -ErrorMessage 'Cannot connect'
    Assert-Eq $r.Events.Count 1; Assert ($r.Events[0].text -match 'Cannot connect')
    Assert-Eq (Update-VAWatcherHealth $wc $h $t0.AddMinutes(20) -Failed -ErrorMessage 'x').Events.Count 0
    $r = Update-VAWatcherHealth $wc $h $t0.AddMinutes(25)
    Assert-Eq "$($r.Events.Count)|$($r.Events[0].resolved)" '1|True'
    Assert-Eq $h.watchFailures 0
    Assert-Eq (Update-VAWatcherHealth $wc $h $t0.AddMinutes(30)).Events.Count 0
}
It 'flapping: one card instead of every change, then one when it settles' {
    $f0 = [datetimeoffset]::new(2026, 11, 6, 10, 0, 0, [timespan]::Zero)
    $fs = Get-VAFlapSettings (New-MockConfig)
    Assert-Eq "$($fs.Changes)|$($fs.Within)|$($fs.Settle)" '4|60|30'
    $flaps = [ordered]@{}
    $svc = [pscustomobject]@{ Name = 'VeeamBackupSvc'; DisplayName = 'Veeam Backup Service'; Status = 'Stopped'; StartType = 'Automatic' }
    $down = { New-VAServiceAlertEvent -Down @($svc) -New @($svc) -Since @{ VeeamBackupSvc = (Get-VAIso $f0) } -Now $f0 }
    $up = { New-VAServiceAlertEvent -Recovered @('VeeamBackupSvc') -Services @($svc) -OutageSince (Get-VAIso $f0) -Now $f0 }
    $sent = @()
    for ($i = 0; $i -lt 8; $i++) {
        $e = if ($i % 2) { & $up } else { & $down }
        $sent += @(Invoke-VAFlapGate -Event $e -Flaps $flaps -Settings $fs -Now $f0.AddMinutes($i * 5))
    }
    # down, up, down pass; the 4th change becomes the flapping card; the rest are held
    Assert-Eq $sent.Count 4
    Assert-Eq "$($sent[3].status)|$($sent[3].report.label)" 'Flapping|FLAPPING'
    Assert-Eq @($sent | Where-Object { $_.status -eq 'Flapping' }).Count 1
    $fp = $sent[0].fingerprint
    Assert $flaps[$fp].flapping 'marked flapping'
    # a reminder while flapping is held too
    $rem = New-VAServiceAlertEvent -Down @($svc) -Since @{ VeeamBackupSvc = (Get-VAIso $f0) } -Reminder 1 -Now $f0
    Assert-Eq @(Invoke-VAFlapGate -Event $rem -Flaps $flaps -Settings $fs -Now $f0.AddMinutes(40)).Count 0
    # not yet settled 20 min after the last change (35 min)...
    Assert-Eq @(Get-VAFlapSettledEvents -Flaps $flaps -Settings $fs -Now $f0.AddMinutes(55)).Count 0
    # the reminder says it's down again, so settling now would report a problem; it comes back up at 41 min
    Assert-Eq @(Invoke-VAFlapGate -Event (& $up) -Flaps $flaps -Settings $fs -Now $f0.AddMinutes(41)).Count 0
    Assert-Eq @(Get-VAFlapSettledEvents -Flaps $flaps -Settings $fs -Now $f0.AddMinutes(66)).Count 0
    # ...settled 30 min after that last change, and it ended up running: settled OK
    $s = @(Get-VAFlapSettledEvents -Flaps $flaps -Settings $fs -Now $f0.AddMinutes(72))
    Assert-Eq "$($s.Count)|$($s[0].resolved)|$($s[0].report.label)" '1|True|SETTLED · OK'
    # a settled card that can't be delivered stays due; once delivered the entry goes
    Assert-Eq (Send-VAFlapSettled -Flaps $flaps -Settings $fs -Now $f0.AddMinutes(72) -Send { throw 'targets down' }) 0
    Assert $flaps.Contains($fp) 'kept for a retry'
    $got = [System.Collections.Generic.List[object]]::new()
    Assert-Eq (Send-VAFlapSettled -Flaps $flaps -Settings $fs -Now $f0.AddMinutes(77) -Send { param($e) $got.Add($e) }) 1
    Assert (-not $flaps.Contains($fp)) 'entry cleared'
    # one that ends up down settles as a problem
    $flaps2 = [ordered]@{}
    for ($i = 0; $i -lt 5; $i++) { $null = Invoke-VAFlapGate -Event $(if ($i % 2) { & $up } else { & $down }) -Flaps $flaps2 -Settings $fs -Now $f0.AddMinutes($i) }
    $s = @(Get-VAFlapSettledEvents -Flaps $flaps2 -Settings $fs -Now $f0.AddMinutes(40))
    Assert-Eq "$($s[0].resolved)|$($s[0].severity)|$($s[0].report.label)" 'False|critical|SETTLED · STILL A PROBLEM'
    # stuck sessions and other kinds pass straight through
    $other = New-VAEvent -Kind session -Severity critical -Title 'x' -Fingerprint 'job|1'
    Assert-Eq @(Invoke-VAFlapGate -Event $other -Flaps $flaps -Settings $fs -Now $f0).Count 1
    # disabled: everything passes
    $off = [pscustomobject]@{ Enabled = $false; Changes = 1; Within = 60; Settle = 30 }
    Assert-Eq @(Invoke-VAFlapGate -Event (& $down) -Flaps ([ordered]@{}) -Settings $off -Now $f0).Count 1
}
It 'flapping: an alert that fails to send is not a change' {
    $f0 = [datetimeoffset]::new(2026, 11, 6, 10, 0, 0, [timespan]::Zero)
    $fs = Get-VAFlapSettings (New-MockConfig)
    $flaps = [ordered]@{}
    $svc = [pscustomobject]@{ Name = 'VeeamBackupSvc'; DisplayName = 'Veeam Backup Service'; Status = 'Stopped'; StartType = 'Automatic' }
    $down = New-VAServiceAlertEvent -Down @($svc) -New @($svc) -Since @{ VeeamBackupSvc = (Get-VAIso $f0) } -Now $f0
    # the service stays down while Discord is unreachable for six runs: every attempt fails...
    for ($i = 0; $i -lt 6; $i++) {
        $threw = $false
        try { Send-VAFlapGated -Event $down -Flaps $flaps -Settings $fs -Now $f0.AddMinutes($i * 5) -Send { throw 'discord down' } } catch { $threw = $true }
        Assert $threw 'the failure reaches the caller (so it retries)'
    }
    Assert (-not $flaps.Contains($down.fingerprint)) 'failed sends left no trace'
    # ...and when Discord is back, the real alert goes out, not a "flapping" card
    $got = [System.Collections.Generic.List[object]]::new()
    Send-VAFlapGated -Event $down -Flaps $flaps -Settings $fs -Now $f0.AddMinutes(30) -Send { param($e) $got.Add($e) }
    Assert-Eq "$($got.Count)|$($got[0].status)" '1|ServiceDown'
}
It 'masks webhook secrets in errors' {
    Assert-Eq (Format-VASafeUrl 'https://prod-1.westus.logic.azure.com:443/workflows/abc/triggers/manual/paths/invoke?api-version=1&sig=SECRET') 'https://prod-1.westus.logic.azure.com:443/…'
    Assert-Eq (Format-VASafeUrl 'https://localhost:9419/api/v1/sessions?limit=1') 'https://localhost:9419/api/v1/sessions'
    Assert-Eq (Hide-VAUrlSecret 'POST https://hooks.example/x/TOKEN failed' 'https://hooks.example/x/TOKEN') 'POST https://hooks.example/… failed'
    Assert-Eq (Format-VASafeUrl 'https://user:12345@hooks.example/x/TOKEN') 'https://hooks.example/…'
    Assert-Eq (Format-VASafeUrl 'http://[2001:db8::1]:8080/x/TOKEN') 'http://[2001:db8::1]:8080/…'
    Assert-Eq (Format-VASafeUrl 'https://[::1]:9419/api/v1/x') 'https://[::1]:9419/api/v1/x'
}
It 'sample and preview cards are marked and page nobody' {
    $evt = New-VAWatcherAlertEvent -Failures 3 -Since '2026-11-06T10:00:00Z' -LastError 'x' -LastGood '2026-11-06T09:55:00Z' -Now ([datetimeoffset]'2026-11-06T10:15:00Z')
    $evt.mention = 'Failure'; $evt['mentionExtra'] = @('<@&222222222222222222>')
    $fp = $evt.fingerprint
    $evt = Set-VASampleEvent $evt -Label Preview
    Assert ($evt.report.title.StartsWith('[Preview] ')) "card title: $($evt.report.title)"
    Assert ($evt.title.StartsWith('[Preview] ')) 'event title'
    Assert ($null -eq $evt.mention -and -not $evt.Contains('mentionExtra')) 'mentions kept'
    Assert-Eq $evt.fingerprint "sample:$fp"
    Assert ((ConvertTo-VADiscordEmbeds $evt.report)[0].title.Contains('[Preview]')) 'not on the Discord card'
}
It 'analyzer all clear has a card' {
    $e = New-VAAnalyzerAlertEvent -NewViolations @() -AllViolations @() -LastRun ([pscustomobject]@{ endTime = '2026-11-06T10:00:00Z' })
    Assert-Eq "$($e.resolved)|$($e.report.label)|$($e.report.status)" 'True|ALL CLEAR|success'
}
It 'digest schedule keeps local time across a clock change' {
    $tz = [TimeZoneInfo]::FindSystemTimeZoneById('GMT Standard Time')   # London: BST ends 2026-10-25 02:00
    $d = [pscustomobject]@{ name = 'daily'; schedule = [pscustomobject]@{ every = 'day'; at = '08:00' } }
    # Sunday 01:30 BST is 00:30Z, before Sunday's 08:00: the last occurrence is Saturday 08:00 BST = 07:00Z
    Assert-Eq (Get-VADigestOccurrence -Digest $d -Now ([datetimeoffset]'2026-10-25T00:30:00Z') -TimeZone $tz).ToString('u') '2026-10-24 07:00:00Z'
    # after the change (GMT), Sunday 08:00 is 08:00Z
    Assert-Eq (Get-VADigestOccurrence -Digest $d -Now ([datetimeoffset]'2026-10-25T09:00:00Z') -TimeZone $tz).ToString('u') '2026-10-25 08:00:00Z'
    $w = [pscustomobject]@{ name = 'weekly'; schedule = [pscustomobject]@{ every = 'week'; day = 'Saturday'; at = '08:00' } }
    Assert-Eq (Get-VADigestOccurrence -Digest $w -Now ([datetimeoffset]'2026-10-26T12:00:00Z') -TimeZone $tz).ToString('u') '2026-10-24 07:00:00Z'
    # the run that went out Saturday 08:00 BST counts: no second digest early Sunday
    $due = Get-VADigestDue -Digest $d -LastRun '2026-10-24T07:05:00Z' -Now ([datetimeoffset]'2026-10-25T01:10:00Z') -TimeZone $tz
    Assert (-not $due.Due) 'not due again after the clocks go back'
}
It 'splits a Discord embed over 6000 characters' {
    $fields = 1..12 | ForEach-Object { @{ name = "Field $_"; value = ('x' * 1000) } }
    $big = [ordered]@{ color = 1; title = 'Big'; description = ('d' * 3000); fields = @($fields) }
    $parts = @(Split-VAOversizedEmbed $big)
    Assert ($parts.Count -ge 3) "split into $($parts.Count)"
    foreach ($p in $parts) { Assert ((Measure-VAEmbed $p) -le 6000) "part is $(Measure-VAEmbed $p) chars" }
    Assert-Eq (@($parts | ForEach-Object { @($_.fields).Count } | Measure-Object -Sum).Sum) 12
    Assert-Eq $parts[0].title 'Big'
    Assert-DiscordLimits @($big) | Out-Null
}
It 'a long Discord report that fails partway is not posted twice' {
    $cfg = @{ discord = @{ webhookUrl = 'https://discord.com/api/webhooks/1/aaa' } }
    $embeds = @(1..3 | ForEach-Object { [ordered]@{ color = 1; title = "Part $_"; description = ('x' * 4000) } })   # 3 messages
    # second message fails: no throw, a note follows, nothing is reposted
    $posts = [System.Collections.Generic.List[string]]::new()
    $n = 0
    Send-VADiscord -Config $cfg -Embeds $embeds -Post { param($u, $j, $f) $script:n++; if ($script:n -eq 2) { throw 'HTTP 500' }; $posts.Add($j) }
    Assert-Eq $posts.Count 2
    Assert ($posts[0] -match 'Part 1') 'first part posted'
    Assert ($posts[1] -match 'could not be sent' -and $posts[1] -match '2 more parts') "note: $($posts[1])"
    # first message fails: throws, so the caller retries the whole report
    $threw = $false
    try { Send-VADiscord -Config $cfg -Embeds $embeds -Post { throw 'HTTP 500' } } catch { $threw = $true }
    Assert $threw 'nothing posted yet: safe to retry'
    # a single message that works
    $one = [System.Collections.Generic.List[string]]::new()
    Send-VADiscord -Config $cfg -Embeds @($embeds[0]) -Post { param($u, $j, $f) $one.Add($j) }
    Assert-Eq $one.Count 1
}
It 'flapping state survives a save and reload' {
    $p = Join-Path $tmp 'flap-state.json'; Set-VAStatePath $p
    Update-VAState { param($s) $s.flapping['health|services'] = [ordered]@{ changes = @('2026-11-06T10:00:00Z'); flapping = $true; since = '2026-11-06T10:00:00Z'; last = [ordered]@{ title = 't'; resolved = $false } } } | Out-Null
    $f = (Read-VAState).flapping['health|services']
    Assert-Eq "$($f['changes'][0])|$($f['flapping'])|$($f['since'])" '2026-11-06T10:00:00Z|True|2026-11-06T10:00:00Z'
}
It 'health state survives a save and reload' {
    $p = Join-Path $tmp 'health-state.json'; Set-VAStatePath $p
    Update-VAState { param($s) $s.health.serviceDownSince['VeeamBackupSvc'] = '2026-11-06T10:00:00Z'; $s.health.servicesAlerted = @('VeeamBackupSvc')
        $s.health.sessionProgress['x'] = [ordered]@{ p = '1|2|3'; at = '2026-11-06T09:00:00Z'; t = 1800 }; $s.health.watchFailures = 2 } | Out-Null
    $h = (Read-VAState).health
    Assert-Eq $h.serviceDownSince['VeeamBackupSvc'] '2026-11-06T10:00:00Z'
    Assert-Eq $h.sessionProgress['x']['at'] '2026-11-06T09:00:00Z'
    Assert-Eq "$($h.servicesAlerted)|$($h.watchFailures)" 'VeeamBackupSvc|2'
    # the watcher's save leaves maintenance alone
    Set-VAMaintenance -Until $t0.AddHours(1) -Reason 'patching' | Out-Null
    $h.watchFailures = 0; Save-VAHealthState $h
    $h2 = (Read-VAState).health
    Assert-Eq "$($h2.maintenanceReason)|$($h2.watchFailures)" 'patching|0'
    Set-VAMaintenance -Off | Out-Null
    Assert ($null -eq (Read-VAState).health.maintenanceUntil)
}
It 'digest health note and stale-watcher alert' {
    $st = New-VAState
    Assert ($null -eq (Get-VAHealthNote -State $st -Now $t0))
    $st.lastWatchUtc = $t0.AddMinutes(-3).ToString('o')
    $st.health.servicesAlerted = @('VeeamBackupSvc')
    Assert ((Get-VAHealthNote -State $st -Now $t0) -match 'VeeamBackupSvc')
    $c = New-MockConfig
    Assert ($null -eq (Get-VAWatcherStaleEvent -Config $c -State $st -Now $t0))
    $st.lastWatchUtc = $t0.AddHours(-2).ToString('o')
    $e = Get-VAWatcherStaleEvent -Config $c -State $st -Now $t0
    Assert ($e -and $e.kind -eq 'health') 'stale event'
    Assert ((Get-VAHealthNote -State $st -Now $t0) -match 'last completed 2h') (Get-VAHealthNote -State $st -Now $t0)
    $st.health.staleAlertedAt = $t0.AddHours(-1).ToString('o')
    Assert ($null -eq (Get-VAWatcherStaleEvent -Config $c -State $st -Now $t0)) 'once a day'
}
It 'health events render for Discord, Teams and plain text' {
    $h = New-VAHealthState
    Update-VAServiceHealth $svcCfg @(New-Svc 'VeeamBackupSvc' 'Stopped') $h $t0 | Out-Null
    $evts = @(
        (Update-VAServiceHealth $svcCfg @(New-Svc 'VeeamBackupSvc' 'Stopped') $h $t0.AddMinutes(20)).Events
        (Update-VAStuckSessions $stuckCfg @(New-RunSession 'r' 13) (New-VAHealthState) $t0).Events
        (New-VAWatcherAlertEvent -Failures 3 -Since $t0.ToString('o') -LastError 'Cannot connect to the local Veeam backup server')
        (New-VAVersionChangeEvent -From '13.1.0.411' -To '13.1.1.100')
    )
    Assert-Eq $evts.Count 4
    $o = Get-VADiscordRenderOptions (New-MockConfig)
    foreach ($ev in $evts) {
        $e = ConvertTo-VADiscordEmbeds $ev.report @o
        Assert-DiscordLimits @($e) | Out-Null
        $samples.Add(@{ Content = ''; Embeds = @($e) })
        New-VATeamsPayload -Report $ev.report | ConvertFrom-Json | Out-Null
        Assert ((ConvertTo-VAPlainText -Report $ev.report).Length -gt 10)
        ConvertTo-VAEventJson $ev | ConvertFrom-Json | Out-Null
    }
}
It 'config defaults include the health block' {
    $c = New-MockConfig
    Assert-Eq "$($c.watch.health.firstAlertAfterMinutes)|$($c.watch.health.repeatEveryMinutes)|$($c.watch.health.backUpForMinutes)" '15|60|5'
    Assert (@($c.watch.health.services.required) -contains 'VeeamBackupSvc')
    Assert-Eq $c.watch.health.watcher.failureAlertAfter 3
}

Write-Host 'Updates'
It 'orders versions, pre-releases before their release' {
    Assert-Eq (Compare-VAVersion 'v0.3.0' '0.2.9') 1
    Assert-Eq (Compare-VAVersion '0.3.0-preview.1' '0.3.0') -1
    Assert-Eq (Compare-VAVersion '0.3.0-preview.10' '0.3.0-preview.2') 1
    Assert-Eq (Compare-VAVersion 'v1.0' '1.0.0') 0
    Assert ($null -eq (ConvertTo-VASemVer 'nightly'))
}
It 'picks the newest release per channel' {
    $rel = @(
        [pscustomobject]@{ tag_name = 'v0.3.0'; prerelease = $false; draft = $false }
        [pscustomobject]@{ tag_name = 'v0.4.0-preview.2'; prerelease = $true; draft = $false }
        [pscustomobject]@{ tag_name = 'v0.5.0'; prerelease = $false; draft = $true }
        [pscustomobject]@{ tag_name = 'docs-update'; prerelease = $false; draft = $false }
    )
    Assert-Eq (Select-VARelease $rel 'stable').tag_name 'v0.3.0'
    Assert-Eq (Select-VARelease $rel 'preview').tag_name 'v0.4.0-preview.2'
    $rel += [pscustomobject]@{ tag_name = 'v0.4.0'; prerelease = $false; draft = $false }
    Assert-Eq (Select-VARelease $rel 'preview').tag_name 'v0.4.0'   # preview users get the stable release too
}
It 'update check never throws and reports a missing repository' {
    $c = New-MockConfig; $c.update.repository = 'not a repo'
    $u = Get-VAUpdateInfo -Config $c -Force
    Assert (-not $u.Available); Assert ("$($u.Error)" -match 'repository')
}

Import-Module (Join-Path $root 'src\VeeamAware.psm1') -Force

if ($env:VEEAMAWARE_TEST_WEBHOOK) {
    Write-Host 'Live Discord'
    $live = New-MockConfig; $live.discord.webhookUrl = $env:VEEAMAWARE_TEST_WEBHOOK; $live.discord.mentions.onFailure = @()
    It 'posts sample messages to the test webhook' { foreach ($s in $samples) { Send-VADiscord -Config $live -Embeds $s.Embeds } }
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`n$($script:passes) passed, $($script:failures) failed"
exit $script:failures
