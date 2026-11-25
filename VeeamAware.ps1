#Requires -Version 7.2
<#
.SYNOPSIS
VeeamAware post-job hook. Set as the job's "Run the following script after the job" command:

    "C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File "C:\VeeamAware\VeeamAware.ps1" -JobId <job-guid>

.DESCRIPTION
VBR waits for post-job scripts and keeps the session open while they run, so this hook does as little as
possible: it works out the job/session IDs, starts Invoke-VeeamAwareSession.ps1 as a detached process and
exits 0 straight away. It never returns a failure code, so a notification problem can never fail a backup job.

IDs come from, in order: the -JobId/-SessionId parameters, then GUIDs on the parent (Veeam) process command
line. The worker falls back to the job's latest session when no session ID is known.
#>
[CmdletBinding()]
param(
    [string]$JobId,
    [string]$SessionId
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$logDir = Join-Path $root 'logs'

function Write-HookLog([string]$Message) {
    try {
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $line = '{0:yyyy-MM-dd HH:mm:ss.fff} [hook] [{1}] {2}' -f (Get-Date), $PID, $Message
        [System.IO.File]::AppendAllText((Join-Path $logDir ('hook-{0:yyyyMMdd}.log' -f (Get-Date))), $line + [Environment]::NewLine)
    }
    catch { }
}

try {
    $guid = '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'
    if (-not $SessionId -or -not $JobId) {
        # The Veeam process that runs post-job scripts carries the job and session GUIDs on its command line.
        # Undocumented, so it is only a hint: the worker verifies both IDs against VBR.
        $parentId = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$parentId" -ErrorAction SilentlyContinue
        $ids = @()
        if ($parent -and $parent.CommandLine) {
            $ids = @([regex]::Matches($parent.CommandLine, $guid) | ForEach-Object Value | Select-Object -Unique)
        }
        Write-HookLog "Parent $parentId ($($parent.Name)) has $($ids.Count) GUID(s) on its command line"
        if ($JobId) {
            if (-not $SessionId) { $SessionId = $ids | Where-Object { $_ -ne $JobId } | Select-Object -First 1 }
        }
        elseif ($ids.Count -ge 2) { $JobId = $ids[0]; if (-not $SessionId) { $SessionId = $ids[1] } }
        elseif ($ids.Count -eq 1) { $JobId = $ids[0] }
    }

    if (-not $JobId -and -not $SessionId) {
        Write-HookLog 'No job or session ID available; add -JobId <guid> to the post-job command. Nothing sent.'
        exit 0
    }

    $worker = Join-Path $root 'Invoke-VeeamAwareSession.ps1'
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$worker`"")
    if ($JobId) { $argList += @('-JobId', $JobId) }
    if ($SessionId) { $argList += @('-SessionId', $SessionId) }
    $p = Start-Process -FilePath $pwsh -ArgumentList $argList -WindowStyle Hidden -PassThru
    Write-HookLog "Started worker PID $($p.Id) for job $JobId session $SessionId"
}
catch {
    Write-HookLog "Hook error: $($_.Exception.Message)"
}
exit 0
