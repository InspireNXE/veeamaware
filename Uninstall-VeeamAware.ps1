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
        # Windows can't delete a folder that is any process's current directory. Step this session out of it
        # (a script shares its caller's location, so this moves the caller's prompt too) and start the
        # deleting process somewhere else.
        $outside = $env:SystemDrive + '\'
        $here = (Get-Location).ProviderPath
        $moved = $false
        if ($here -and ($here.TrimEnd('\') + '\').StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            Set-Location $outside; $moved = $true
        }
        # Set-Location doesn't change the process's own working directory, which also holds the folder.
        if (([Environment]::CurrentDirectory.TrimEnd('\') + '\').StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            [Environment]::CurrentDirectory = $outside
        }
        # This script lives in the folder; delete it from a separate process once this one has exited, and keep
        # trying for a minute in case something else (Explorer, another window) still holds it.
        $q = $root -replace "'", "''"
        $cmd = "Start-Sleep -Seconds 3; for (`$i = 0; `$i -lt 30 -and (Test-Path -LiteralPath '$q'); `$i++) { " +
        "Remove-Item -LiteralPath '$q' -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path -LiteralPath '$q') { Start-Sleep -Seconds 2 } }"
        Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -WorkingDirectory $outside -WindowStyle Hidden `
            -ArgumentList '-NoProfile', '-NonInteractive', '-Command', $cmd
        if ($moved) { Write-Host "Moved this window to $outside so the folder can be deleted." }
        Write-Host "Deleting $root in a few seconds. If it's still there after a minute, close any window or Explorer tab open in it and delete it by hand."
    }
}
else {
    Write-Host "Kept $root (config, secrets, state, logs). Delete it, or re-run with -RemoveFiles, to remove everything."
}
Write-Host 'VeeamAware is uninstalled.'
