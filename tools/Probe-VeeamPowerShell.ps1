#Requires -Version 7.2
<#
.SYNOPSIS
Read-only probe of what the local Veeam PowerShell module exposes on this server. Changes nothing.
Writes probe-output.txt next to this script; send that file (or its contents) to whoever is developing VeeamAware.
#>
$ErrorActionPreference = 'Continue'
$out = Join-Path $PSScriptRoot 'probe-output.txt'
$lines = [System.Collections.Generic.List[string]]::new()
function Section([string]$Name, [scriptblock]$Body) {
    $lines.Add(''); $lines.Add("===== $Name")
    try { $r = & $Body 2>&1 | Out-String -Width 250; $lines.Add($r.TrimEnd()) }
    catch { $lines.Add("ERROR: $($_.Exception.Message)") }
}
function Props($o) { if ($null -eq $o) { '(null)' } else { "[$($o.GetType().FullName)]"; $o | Get-Member -MemberType Property, NoteProperty | ForEach-Object Name | Sort-Object } }

Import-Module Veeam.Backup.PowerShell -DisableNameChecking -WarningAction SilentlyContinue
Section 'Versions' { "pwsh $($PSVersionTable.PSVersion)"; "module $((Get-Module Veeam.Backup.PowerShell).Version)"; "user $([Security.Principal.WindowsIdentity]::GetCurrent().Name)" }

$s = Get-VBRBackupSession | Sort-Object EndTimeUTC -Descending | Select-Object -First 1
Section 'Backup session types (count per JobType, all history)' { Get-VBRBackupSession | Group-Object { "$($_.JobType)" } | Select-Object Count, Name | Format-Table -AutoSize }
Section 'Session: Result/State/JobType/Info.Reason' { $s | Format-List JobName, Id, JobId, Result, State, JobType, JobTypeString, IsRetryMode, IsManuallyStopped, CreationTimeUTC, EndTimeUTC; $s.Info | Format-List Reason, Result, State, Failures, Warnings }
Section 'Session.Progress.BottleneckInfo' { $s.Progress.BottleneckInfo | Format-List * }
Section 'Session.BackupStats' { $s.BackupStats | Format-List * }
Section 'Session.Info properties' { Props $s.Info }
Section 'Session log (last 12 records)' { $s.Logger.GetLog().UpdatedRecords | Select-Object -Last 12 | Format-Table Status, Title -AutoSize -Wrap }
Section 'Session log record properties' { Props ($s.Logger.GetLog().UpdatedRecords | Select-Object -First 1) }
Section 'Get-VBRSession -Id (documented object)' { Get-VBRSession -Id $s.Id | Format-List * }

$t = Get-VBRTaskSession -Session $s | Select-Object -First 1
Section 'Task session properties' { Props $t }
Section 'Task.Progress' { $t.Progress | Format-List * }
Section 'Task.Progress.BottleneckInfo' { $t.Progress.BottleneckInfo | Format-List * }
Section 'Task.Info' { $t.Info | Format-List * }
Section 'Task log (last 8)' { $t.Logger.GetLog().UpdatedRecords | Select-Object -Last 8 | Format-Table Status, Title -AutoSize -Wrap }

$a = Get-VBRComputerBackupJobSession | Sort-Object CreationTime -Descending | Select-Object -First 1
Section 'Agent jobs' { Get-VBRComputerBackupJob | Format-Table Name, Id, Mode, Type, OSPlatform -AutoSize }
Section 'Agent session properties' { Props $a }
Section 'Agent session via Get-VBRBackupSession -Id' { $b = Get-VBRBackupSession -Id $a.Id; Props $b; $b | Format-List JobName, Result, JobType, Platform }
Section 'Agent session via Get-VBRSession -Id' { Get-VBRSession -Id $a.Id | Format-List * }
Section 'Agent task sessions (per machine)' {
    $x = try { Get-VBRTaskSession -Session (Get-VBRBackupSession -Id $a.Id) } catch { "Get-VBRTaskSession(backup session) failed: $($_.Exception.Message)" }
    $x | Select-Object -First 3 | Format-List Name, Status, @{n = 'Reason'; e = { $_.Info.Reason } }, @{n = 'Transferred'; e = { $_.Progress.TransferedSize } }
}
Section 'Agent policy sessions? (sessions of all agent jobs, last 24h)' {
    Get-VBRComputerBackupJobSession | Where-Object { $_.CreationTime -gt (Get-Date).AddDays(-1) } | Group-Object JobId | Select-Object Count, Name | Format-Table -AutoSize
}

Section 'Repositories' {
    foreach ($r in @(Get-VBRBackupRepository) + @(Get-VBRBackupRepository -ScaleOut -WarningAction SilentlyContinue)) {
        "--- $($r.Name) [$($r.GetType().Name)] Type=$($r.Type) Id=$($r.Id)"
        try { $c = $r.GetContainer(); $c | Format-List CachedTotalSpace, CachedFreeSpace } catch { "GetContainer: $($_.Exception.Message)" }
        try { $r.Info | Format-List CachedTotalSpace, CachedFreeSpace } catch { }
    }
}
Section 'Repository-related cmdlets' { Get-Command -Module Veeam.Backup.PowerShell -Name *Repository*, *StorageInfo* | ForEach-Object Name | Sort-Object }

Section 'Malware cmdlets' { Get-Command -Module Veeam.Backup.PowerShell -Name *Malware* | ForEach-Object Name }
Section 'Malware events (2 newest)' { Get-VBRMalwareDetectionEvent | Select-Object -Last 2 | Format-List * }
Section 'Security/approval cmdlets' { Get-Command -Module Veeam.Backup.PowerShell -Name *SecurityCompliance*, *Authorization*, *FourEyes*, *Approval* | ForEach-Object Name }
Section 'Analyzer results' { Get-VBRSecurityComplianceAnalyzerResults | Select-Object -First 3 | Format-List * }

Section 'Other job families' {
    foreach ($c in 'Get-VBRBackupCopyJob', 'Get-VBRUnstructuredBackupJob', 'Get-VBRTapeJob', 'Get-VBRSureBackupJob') {
        try { "$c : $(@(& $c -WarningAction SilentlyContinue).Count)" } catch { "$c : ERROR $($_.Exception.Message)" }
    }
}

$lines | Set-Content -Path $out -Encoding utf8
Write-Host "Wrote $out ($((Get-Item $out).Length) bytes)."
