#Requires -Version 7.2
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Removes VeeamAware: the post-job hook from VBR jobs, the scheduled tasks, and (with -RemoveFiles) the folder.

.DESCRIPTION
Without -RemoveFiles the install folder stays, including config\, secrets\, state\ and logs\, so a reinstall
picks up where it left off. -RemoveFiles deletes the whole folder after a confirmation prompt (skip the prompt
with -Confirm:$false).

Agent, file-share, tape and SureBackup jobs keep their script settings per job; the script lists them so you
can check them by hand.

.EXAMPLE
pwsh -File C:\VeeamAware\Uninstall-VeeamAware.ps1                # hooks and tasks; keep the folder
pwsh -File C:\VeeamAware\Uninstall-VeeamAware.ps1 -RemoveFiles   # everything
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch]$RemoveFiles,
    [switch]$KeepHooks
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# 1. Post-job hooks --------------------------------------------------------------------------------------
if (-not $KeepHooks) {
    Write-Host 'Removing the post-job hook from VBR jobs...'
    try { & (Join-Path $root 'Register-VeeamAwareJob.ps1') -Remove -Apply }
    catch { Write-Warning "Could not update the jobs ($($_.Exception.Message)). Remove the hook by hand: Job → Edit → Advanced → Scripts." }
}

# 2. Scheduled tasks ---------------------------------------------------------------------------------------
foreach ($task in @(Get-ScheduledTask -TaskPath '\VeeamAware\' -ErrorAction SilentlyContinue)) {
    Stop-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -Confirm:$false
    Write-Host "Removed scheduled task $($task.TaskPath)$($task.TaskName)"
}
try {
    $svc = New-Object -ComObject 'Schedule.Service'; $svc.Connect()
    $svc.GetFolder('\').DeleteFolder('VeeamAware', 0)
    Write-Host 'Removed the \VeeamAware\ task folder'
}
catch { }   # not there, or not empty

# 3. Files ---------------------------------------------------------------------------------------------------
if ($RemoveFiles) {
    if ($PSCmdlet.ShouldProcess($root, 'Delete the VeeamAware folder, including config, secrets, state and logs')) {
        # This script lives in the folder; delete it from a separate process once this one has exited.
        $cmd = "Start-Sleep -Seconds 3; Remove-Item -LiteralPath '$($root -replace "'", "''")' -Recurse -Force"
        Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList '-NoProfile', '-NonInteractive', '-Command', $cmd -WindowStyle Hidden
        Write-Host "Deleting $root in a few seconds."
    }
}
else {
    Write-Host "Kept $root (config, secrets, state, logs). Delete it, or re-run with -RemoveFiles, to remove everything."
}
Write-Host 'VeeamAware is uninstalled.'
