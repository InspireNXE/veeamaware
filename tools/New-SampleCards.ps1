#Requires -Version 7.2
<#
.SYNOPSIS
Builds sample cards from made-up data with the real renderers: a successful job, a failed agent job, a
warning, a low repository, a malware detection, a stopped service and a digest. Reads nothing from VBR, sends
nothing unless -Send is given, and never changes state.json.

Without -Send it writes, per card, the Discord embeds and the Teams Adaptive Card as JSON, plus preview.html,
which draws them the way Discord and Teams lay them out. tools\New-ReadmeImages.ps1 screenshots that page for
the README.

.EXAMPLE
pwsh -File .\tools\New-SampleCards.ps1 -OutDir .\samples           # JSON + preview.html
pwsh -File .\tools\New-SampleCards.ps1 -Send                       # post every card to your targets
pwsh -File .\tools\New-SampleCards.ps1 -Send -Card failure -Target discord
#>
[CmdletBinding()]
param(
    [ValidateSet('success', 'failure', 'warning', 'repository', 'malware', 'service', 'digest')]
    [string[]]$Card = @('success', 'failure', 'warning', 'repository', 'malware', 'service', 'digest'),
    [string]$OutDir = (Join-Path $PSScriptRoot '..\samples'),
    [switch]$Send, [string[]]$Target, [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\VeeamAware.psm1') -Force
. (Join-Path $root 'tests\MockData.ps1')

# Every card names the server it came from: use a made-up one, never this machine's.
$realName = $env:COMPUTERNAME
$env:COMPUTERNAME = 'VBR-01'
try {
    $config = if ($Send) { $a = @{}; if ($ConfigPath) { $a.Path = $ConfigPath }; Get-VAConfig @a } else { Get-VADefaultConfig }
    if ($Send) { Initialize-VALog -Name 'samples' -Level $config.logging.level -RetentionDays $config.logging.retentionDays }

    # Times are pinned to this morning, local time, so the samples read the same every time they are rebuilt.
    $now = [datetimeoffset](Get-Date).Date.AddHours(8).AddMinutes(14)   # local, like the digest's day buckets
    $iso = { param([double]$minutesAgo) $now.AddMinutes(-$minutesAgo).ToString('o') }
    $history = {
        # Older runs, newest first, in the shape Add-VAHistoryContext reads.
        param([string[]]$Results, [double]$GB = 30, [int]$Minutes = 40)
        $i = 0
        foreach ($r in $Results) {
            $i++
            [pscustomobject]@{ id = "h$i"; result = $r; startTime = (& $iso ($i * 1440 + $Minutes)); endTime = (& $iso ($i * 1440))
                transferredBytes = [long]($GB * 1GB * (0.9 + 0.05 * ($i % 3))) }
        }
    }
    $task = {
        param([string]$Name, [string]$Result = 'Success', [double]$GB = 40, [string]$Message = '', [string]$Duration = '00:12:41', [string]$Bottleneck = 'Source')
        $t = New-MockTask $Name $Result $GB $Message
        $t.progress.duration = $Duration; $t.progress.bottleneck = $Bottleneck
        $t
    }
    $session = {
        param([string]$Name, [string]$Type, [string]$Result, [int]$MinutesAgo, [int]$Length, [string]$Message = '')
        $s = New-MockSession -Name $Name -Type $Type -Result $Result -MinutesAgo $MinutesAgo -Message $Message -Now $now
        $s.creationTime = (& $iso ($MinutesAgo + $Length))
        $s
    }

    $build = [ordered]@{
        success    = {
            $s = & $session 'Production VMs' 'BackupJob' 'Success' 14 46
            $tasks = @(
                & $task 'sql-01' 'Success' 412 '' '00:21:07' 'Source'
                & $task 'sql-02' 'Success' 388 '' '00:19:52' 'Source'
                & $task 'app-01' 'Success' 96 '' '00:06:13' 'Proxy'
                & $task 'dc-01' 'Success' 64 '' '00:04:40' 'Source'
                & $task 'web-01' 'Success' 58 '' '00:03:58' 'Network'
            )
            $f = Get-VASessionSummary -Session $s -TaskSessions $tasks -Log (New-MockLog | Where-Object status -eq 'Succeeded')
            Add-VAHistoryContext -Summary $f -History @(& $history @('Success', 'Success', 'Warning', 'Success', 'Success', 'Success') 210 44) | Out-Null
            $f.Repository = Get-VARepositoryInfo (New-MockRepo 'Primary ReFS' 20480 7270)
            New-VASessionEvent -Config $config -Summary $f
        }
        failure    = {
            $s = & $session 'WS-ACCT-02' 'AgentBackup' 'Failed' 9 37
            $s.result.message = 'Failed to connect to agent at 192.0.2.20.'
            $t = & $task 'WS-ACCT-02.corp.example' 'Failed' 0 'Task failed. Error: Failed to connect to agent at 192.0.2.20. Rescan the machine and try again.' '00:00:00'
            $t | Add-Member -NotePropertyName objectId -NotePropertyValue 'c0ffee01'
            $log = @(
                [pscustomobject]@{ id = 1; status = 'Succeeded'; title = 'Job started' }
                [pscustomobject]@{ id = 2; status = 'Succeeded'; title = 'Backup agent WS-ACCT-02.corp.example requires upgrade' }
                [pscustomobject]@{ id = 3; status = 'Failed'; title = 'Processing WS-ACCT-02.corp.example Error: Failed to connect to agent at 192.0.2.20.' }
            )
            $f = Get-VASessionSummary -Session $s -TaskSessions @($t) -Log $log
            Add-VAHistoryContext -Summary $f -History @(& $history @('Failed', 'Failed', 'Success', 'Success', 'Success', 'Success') 6 12) | Out-Null
            $f | Add-Member -NotePropertyName Agents -Force -NotePropertyValue @([pscustomobject]@{ objectId = 'c0ffee01'; name = '192.0.2.20'
                    protectionGroup = 'Manually Added'; state = 'Online'; agentStatus = 'UpgradeAvailable'; agentVersion = '13.1.0.411'; rebootRequired = $false })
            New-VASessionEvent -Config $config -Summary $f
        }
        warning    = {
            $s = & $session 'File servers' 'BackupJob' 'Warning' 31 52 '1 of 3 VMs processed with warnings'
            $tasks = @(
                & $task 'fs-01' 'Success' 640 '' '00:31:20' 'Source'
                & $task 'fs-02' 'Warning' 210 'Changed block tracking cannot be enabled: a snapshot already exists. Remove it and run the job again.' '00:14:02'
                & $task 'print-01' 'Success' 22 '' '00:02:11' 'Network'
            )
            $f = Get-VASessionSummary -Session $s -TaskSessions $tasks -Log @()
            Add-VAHistoryContext -Summary $f -History @(& $history @('Success', 'Success', 'Success', 'Success', 'Success', 'Success') 160 50) | Out-Null
            New-VASessionEvent -Config $config -Summary $f
        }
        repository = {
            $info = Get-VARepositoryInfo (New-MockRepo 'Hardened Linux' 51200 2350)
            New-VARepositoryAlertEvent -Info $info -Level 'critical' -PreviousLevel 'warning'
        }
        malware    = {
            New-VAMalwareAlertEvent ([pscustomobject]@{ id = 41; type = 'EncryptedData'; severity = 'Suspicious'; state = 'Created'; source = 'InlineScan'
                    detectionTimeUtc = (& $iso 6); machine = [pscustomobject]@{ displayName = 'fs-02' }; details = 'Encrypted files detected: 1,432' })
        }
        service    = {
            $svc = [pscustomobject]@{ Name = 'VeeamMountSvc'; DisplayName = 'Veeam Mount Service'; Status = 'Stopped'; StartType = 'Automatic' }
            $why = [pscustomobject]@{ Text = 'The Veeam Mount Service service terminated unexpectedly. It has done this 1 time(s).' }
            New-VAServiceAlertEvent -Down @($svc) -New @($svc) -Since @{ VeeamMountSvc = $now.AddMinutes(-17).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") } `
                -Reasons @{ VeeamMountSvc = $why } -Services @($svc) -Now $now
        }
        digest     = {
            $from = $now.AddHours(-24)
            $jobs = @(
                @{ n = 'Production VMs'; t = 'BackupJob'; r = @('Success', 'Success', 'Warning', 'Success', 'Success', 'Success', 'Success') }
                @{ n = 'File servers'; t = 'BackupJob'; r = @('Success', 'Success', 'Success', 'Success', 'Success', 'Success', 'Warning') }
                @{ n = 'Offsite copy'; t = 'BackupCopyJob'; r = @('Success', 'Success', 'Success', 'Success', 'Success', 'Success', 'Success') }
                @{ n = 'SQL logs'; t = 'BackupJob'; r = @('Success', 'Success', 'Success', 'Success', 'Success', 'Success', 'Success') }
                @{ n = 'WS-ACCT-02'; t = 'AgentBackup'; r = @('Success', 'Success', 'Success', 'Success', 'Failed', 'Failed', 'Failed') }
            )
            $hist = [System.Collections.Generic.List[object]]::new(); $window = [System.Collections.Generic.List[object]]::new()
            foreach ($j in $jobs) {
                $jobId = [guid]::NewGuid().ToString()
                for ($d = 0; $d -lt 7; $d++) {
                    $ago = (6 - $d) * 1440 + 360
                    $s = & $session $j.n $j.t $j.r[$d] $ago 40
                    $s.jobId = $jobId
                    $hist.Add($s); if ($d -eq 6) { $window.Add($s) }
                }
            }
            $repos = @((New-MockRepo 'Primary ReFS' 20480 7270), (New-MockRepo 'Hardened Linux' 51200 2350), (New-MockRepo 'Offsite S3' 0 0))
            $repos[2].capacityGB = $null; $repos[2].freeGB = $null
            $report = New-VADigestReport -Config $config -From $from -To $now -OtherSessions @($window) -HistorySessions @($hist) `
                -Repositories @($repos | ForEach-Object { Get-VARepositoryInfo $_ }) -AnalyzerViolations 1 -PreviousAnalyzerViolations 1
            $counts = @{ total = $window.Count; success = @($window | Where-Object { $_.result.result -eq 'Success' }).Count
                warning = @($window | Where-Object { $_.result.result -eq 'Warning' }).Count; failed = @($window | Where-Object { $_.result.result -eq 'Failed' }).Count }
            New-VADigestEvent -Report $report -From $from -To $now -Counts $counts -Name 'daily'
        }
    }

    $cards = [ordered]@{}
    foreach ($c in $Card) {
        $evt = & $build[$c]
        # Alerts stamp themselves with the real time; keep them on the samples' morning.
        if ($evt.report -and (ConvertTo-VADate $evt.report.timestamp) -gt $now) { $evt.report.timestamp = $now.ToString('o') }
        if ($Send) {
            $evt.title = "[Sample] $($evt.title)"
            $n = Send-VAEvent -Config $config -Event $evt -OnlyTargets $Target
            Write-Host ("{0,-11} -> {1} target(s)" -f $c, $n)
            continue
        }
        $cards[$c] = [ordered]@{
            discord = (ConvertTo-VADiscordEmbeds -Report $evt.report -Ansi $true -Badges $true)
            teams   = (New-VATeamsPayload -Report $evt.report | ConvertFrom-Json -Depth 50).attachments[0].content
        }
    }
    if ($Send) { return }

    New-Item -ItemType Directory $OutDir -Force | Out-Null
    $OutDir = (Resolve-Path $OutDir).Path
    foreach ($c in $cards.Keys) {
        $cards[$c].discord | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $OutDir "$c.discord.json") -Encoding utf8
        $cards[$c].teams | ConvertTo-Json -Depth 50 | Set-Content (Join-Path $OutDir "$c.teams.json") -Encoding utf8
    }
    # The preview page reads the badges from assets\ and the cards from this inline JSON (file:// can't fetch).
    $assets = ([uri](Join-Path $root 'assets\')).AbsoluteUri
    $data = $cards | ConvertTo-Json -Depth 60 -Compress
    $page = (Get-Content -Raw (Join-Path $PSScriptRoot 'card-preview.html')).Replace('/*CARDS*/null', $data).Replace('/*ASSETS*/""', "`"$assets`"").Replace('/*NOW*/Date.now()', "$($now.AddMinutes(1).ToUnixTimeMilliseconds())")
    $page | Set-Content (Join-Path $OutDir 'preview.html') -Encoding utf8
    Write-Host "Wrote $($cards.Count) card(s) to $OutDir (open preview.html)"
}
finally { $env:COMPUTERNAME = $realName }
