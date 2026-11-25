#Requires -Version 7.2
<#
.SYNOPSIS
Read-only probe: where VBR keeps the reason a Veeam Agent job failed. Changes nothing.
Writes probe-agent-failure-output.txt next to this script.

Dumps the job's latest failed session (every property, the full session log with descriptions), its task
sessions (reason, task log), the protection-group view of the job's computers (agent version and status),
and what VeeamAware currently builds from the session, so the gap between the two is visible.

.EXAMPLE
pwsh -File .\tools\Probe-AgentFailure.ps1 -JobName 'WS-EXAMPLE-01 Backup'
#>
param([Parameter(Mandatory)][string]$JobName, [int]$Days = 7)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $PSScriptRoot 'probe-agent-failure-output.txt'
$lines = [System.Collections.Generic.List[string]]::new()
function Section([string]$Name, [scriptblock]$Body) {
    $lines.Add(''); $lines.Add("===== $Name")
    try { $lines.Add((& $Body 2>&1 | Out-String -Width 300).TrimEnd()) } catch { $lines.Add("ERROR: $($_.Exception.Message)") }
}
Import-Module Veeam.Backup.PowerShell -DisableNameChecking -WarningAction SilentlyContinue

$job = Get-VBRComputerBackupJob -Name $JobName -ErrorAction SilentlyContinue
if (-not $job) { $job = Get-VBRJob -Name $JobName -WarningAction SilentlyContinue }
if (-not $job) { throw "No agent job named '$JobName'. Get-VBRComputerBackupJob lists them." }
Section 'Job' { $job | Format-List Name, Id, Mode, OSPlatform, Type, BackupType, ProtectionGroup* }

$cutoff = (Get-Date).AddDays(-$Days)
$thin = @(Get-VBRComputerBackupJobSession | Where-Object { $_.JobId -eq $job.Id -and $_.CreationTime -gt $cutoff } | Sort-Object CreationTime -Descending)
Section "Agent sessions, last $Days days" { $thin | Select-Object -First 15 | Format-Table CreationTime, EndTime, Result, State, Id -AutoSize }
$pick = @($thin | Where-Object { "$($_.Result)" -eq 'Failed' }) + @($thin | Where-Object { "$($_.Result)" -eq 'Warning' }) + $thin | Select-Object -First 1
if (-not $pick) { $lines.Add("No sessions in the last $Days days."); $lines | Set-Content $out -Encoding utf8; Write-Host "Wrote $out"; return }
Section 'Agent session (thin record), all properties' { $pick | Format-List * }

$s = Get-VBRBackupSession -Id $pick.Id
Section 'Backup session, all properties' { $s | Format-List * }
Section 'Backup session .Info' { $s.Info | Format-List * }
Section 'Session log: every record with description' {
    $s.Logger.GetLog().UpdatedRecords | Sort-Object StartTime | Format-List StartTime, Status, Title, Description
}

$tasks = @(Get-VBRTaskSession -Session $s)
Section "Task sessions ($($tasks.Count))" { $tasks | Format-List Name, Status, Id, @{ n = 'Info.Reason'; e = { $_.Info.Reason } }, @{ n = 'Info.Status'; e = { $_.Info.Status } } }
foreach ($t in $tasks) {
    Section "Task '$($t.Name)': all properties" { $t | Format-List * }
    Section "Task '$($t.Name)': log with descriptions" { $t.Logger.GetLog().UpdatedRecords | Sort-Object StartTime | Format-List StartTime, Status, Title, Description }
}

Section 'Protection groups and discovered computers (agent version / status)' {
    foreach ($pg in @(Get-VBRProtectionGroup)) {
        "--- $($pg.Name)"
        Get-VBRDiscoveredComputer -ProtectionGroup $pg -ErrorAction SilentlyContinue | Format-Table -AutoSize -Property *
    }
}
Section 'First discovered computer, every property' {
    $pg = @(Get-VBRProtectionGroup) | Select-Object -First 1
    Get-VBRDiscoveredComputer -ProtectionGroup $pg -ErrorAction SilentlyContinue | Select-Object -First 1 | Format-List *
}

Section 'What VeeamAware builds from this session' {
    Import-Module (Join-Path $root 'src\VeeamAware.psm1') -Force
    $config = Get-VAConfig
    Connect-VASource -Config $config
    try {
        $vs = @(Get-VASessions -EndedAfter ([datetimeoffset]$pick.CreationTime).AddMinutes(-1)) | Where-Object { "$($_.id)" -eq "$($pick.Id)" } | Select-Object -First 1
        if (-not $vs) { 'Session not returned by Get-VASessions' } else {
            $sum = Get-VASessionSummary -Session $vs -TaskSessions @(Get-VATaskSessions "$($pick.Id)") -Log @(Get-VASessionLog "$($pick.Id)")
            "Result:  $($sum.Result)"
            "Message: $($sum.Message)"
            'ProblemLog:'; $sum.ProblemLog | Format-Table Status, Title -AutoSize -Wrap
            'Tasks:'; $sum.Tasks | Format-Table Name, Result, Message -AutoSize -Wrap
        }
    }
    finally { Disconnect-VASource }
}

$lines | Set-Content -Path $out -Encoding utf8
Write-Host "Wrote $out ($((Get-Item $out).Length) bytes)."
