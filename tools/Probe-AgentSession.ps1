#Requires -Version 7.2
<#
.SYNOPSIS
Read-only probe of where a Veeam Agent session keeps its statistics. Changes nothing.
Writes probe-agent-output.txt next to this script.
#>
param([Parameter(Mandatory)][string]$JobName)   # an agent job's name
$ErrorActionPreference = 'Continue'
$out = Join-Path $PSScriptRoot 'probe-agent-output.txt'
$lines = [System.Collections.Generic.List[string]]::new()
function Section([string]$Name, [scriptblock]$Body) {
    $lines.Add(''); $lines.Add("===== $Name")
    try { $lines.Add((& $Body 2>&1 | Out-String -Width 250).TrimEnd()) } catch { $lines.Add("ERROR: $($_.Exception.Message)") }
}
Import-Module Veeam.Backup.PowerShell -DisableNameChecking -WarningAction SilentlyContinue
$job = Get-VBRComputerBackupJob -Name $JobName
$thin = Get-VBRComputerBackupJobSession | Where-Object { $_.JobId -eq $job.Id } | Sort-Object CreationTime -Descending | Select-Object -First 1
$s = Get-VBRBackupSession -Id $thin.Id
Section 'Session' { $s | Format-List JobName, Id, JobType, Platform, Result, State }
Section 'Session.Progress' { $s.Progress | Format-List * }
Section 'Session.Progress.BottleneckInfo' { $s.Progress.BottleneckInfo | Format-List * }
Section 'Session.BackupStats' { $s.BackupStats | Format-List * }
Section 'Session.Info sizes' { $s.Info | Format-List BackedUpSize, BackupTotalSize, CompletionPercentage, Progress }
Section 'Session.Info.Progress' { $s.Info.Progress | Format-List * }
Section 'Session.BaseProgress' { $s.BaseProgress | Format-List * }
Section 'Session.WorkDetails' { $s.WorkDetails | Format-List * }
Section 'Session log (all)' { $s.Logger.GetLog().UpdatedRecords | Format-Table Status, Title -AutoSize -Wrap }
$t = Get-VBRTaskSession -Session $s | Select-Object -First 1
Section 'Task.Progress' { $t.Progress | Format-List * }
Section 'Task.Progress.BottleneckInfo' { $t.Progress.BottleneckInfo | Format-List * }
Section 'Task.Info.WorkDetails' { $t.Info.WorkDetails | Format-List * }
Section 'Task log (all)' { $t.Logger.GetLog().UpdatedRecords | Format-Table Status, Title -AutoSize -Wrap }
Section 'Restore point / backup' {
    $b = Get-VBRBackup | Where-Object { $_.JobId -eq $job.Id } | Select-Object -First 1
    $b | Format-List Name, Id, JobType
    $rp = Get-VBRRestorePoint -Backup $b | Sort-Object CreationTime -Descending | Select-Object -First 1
    $rp | Format-List Name, CreationTime, Type, ApproxSize
    try { $st = $rp.GetStorage(); $st | Format-List FilePath, Stats } catch { "GetStorage: $($_.Exception.Message)" }
}
$lines | Set-Content -Path $out -Encoding utf8
Write-Host "Wrote $out ($((Get-Item $out).Length) bytes)."
