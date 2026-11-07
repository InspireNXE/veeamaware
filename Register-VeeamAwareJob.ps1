#Requires -Version 7.2
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Attaches the VeeamAware post-job hook to VBR jobs, or prints the command line to paste in the console.

.DESCRIPTION
Uses the v13 Veeam PowerShell module (PowerShell 7 only). Without -Apply it only lists jobs and the exact
post-job command for each, so you can review first.

Jobs listed by Get-VBRJob (VM backup, replication, backup copy, file copy...) are updated with
Get-VBRJobOptions / Set-VBRJobOptions. Other job types (agent jobs, unstructured data, tape, SureBackup) are
listed with the command to paste manually under Job settings > Storage/Advanced > Scripts, because their
script-option cmdlets differ per type. Agent failures are still caught by the watcher within a few minutes
even without the hook.

-Remove detaches the hook again (only a post-job script that runs VeeamAware.ps1; other scripts are left
alone). Uninstall-VeeamAware.ps1 uses it.

.EXAMPLE
pwsh -File .\Register-VeeamAwareJob.ps1                      # review
pwsh -File .\Register-VeeamAwareJob.ps1 -Apply -Name 'Prod*' # attach to matching jobs
pwsh -File .\Register-VeeamAwareJob.ps1 -Remove -Apply       # detach from every job
#>
[CmdletBinding()]
param(
    [string[]]$Name = @('*'),
    [switch]$Apply,
    [switch]$Overwrite,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
Import-Module Veeam.Backup.PowerShell -DisableNameChecking -WarningAction SilentlyContinue
Connect-VBRServer -ErrorAction SilentlyContinue   # local server; no-op if already connected

$pwsh = Join-Path $PSHOME 'pwsh.exe'
$hook = Join-Path $PSScriptRoot 'VeeamAware.ps1'
function Get-HookCommand([guid]$JobId) { "`"$pwsh`" -NoProfile -ExecutionPolicy Bypass -File `"$hook`" -JobId $JobId" }
$match = { param($n) @($Name | Where-Object { $n -like $_ }).Count -gt 0 }

$rows = [System.Collections.Generic.List[object]]::new()

# Get-VBRJob is deprecated for agent jobs in v13; those are handled by Get-VBRComputerBackupJob below.
foreach ($job in (Get-VBRJob -WarningAction SilentlyContinue | Where-Object { "$($_.JobType)" -notmatch 'EpAgent' -and (& $match $_.Name) })) {
    $cmd = Get-HookCommand $job.Id
    $opts = Get-VBRJobOptions -Job $job
    $current = $opts.JobScriptCommand.PostScriptCommandLine
    $status = 'pending'
    if ($Remove) {
        # Any VeeamAware hook, wherever it was installed from.
        if ("$current" -match 'VeeamAware\.ps1') {
            $status = 'to remove'
            if ($Apply) {
                $opts.JobScriptCommand.PostScriptEnabled = $false
                $opts.JobScriptCommand.PostScriptCommandLine = ''
                Set-VBRJobOptions -Job $job -Options $opts | Out-Null
                $status = 'removed'
            }
        }
        else { $status = if ($current) { 'other script (left alone)' } else { 'not attached' } }
    }
    elseif ($opts.JobScriptCommand.PostScriptEnabled -and $current -eq $cmd) { $status = 'already set' }
    elseif ($opts.JobScriptCommand.PostScriptEnabled -and $current -and -not $Overwrite) { $status = 'has other script (use -Overwrite)' }
    elseif ($Apply) {
        $opts.JobScriptCommand.PostScriptEnabled = $true
        $opts.JobScriptCommand.PostScriptCommandLine = $cmd
        Set-VBRJobOptions -Job $job -Options $opts | Out-Null
        $status = 'attached'
    }
    $rows.Add([pscustomobject]@{ Job = $job.Name; Type = "$($job.JobType)"; Status = $status; Command = $cmd })
}

$manual = @()
foreach ($getter in 'Get-VBRComputerBackupJob', 'Get-VBRUnstructuredBackupJob', 'Get-VBRTapeJob', 'Get-VBRSureBackupJob') {
    if (-not (Get-Command $getter -ErrorAction SilentlyContinue)) { continue }
    try { $manual += @(& $getter -WarningAction SilentlyContinue | Where-Object { & $match $_.Name }) } catch { }
}
foreach ($job in $manual) {
    $rows.Add([pscustomobject]@{ Job = $job.Name; Type = $job.GetType().Name; Status = $(if ($Remove) { 'manual (check by hand)' } else { 'manual' }); Command = Get-HookCommand $job.Id })
}

$rows | Format-Table Job, Type, Status -AutoSize
$manualRows = @($rows | Where-Object Status -like 'manual*')
if ($Remove) {
    if ($manualRows) {
        Write-Host "These job types keep their script setting per job. If you added the VeeamAware hook to them, remove it under"
        Write-Host "Job settings > Advanced > Scripts:"
        $manualRows | ForEach-Object { Write-Host "  $($_.Job) ($($_.Type))" }
    }
    if (-not $Apply) { Write-Host "`nNothing changed. Re-run with -Remove -Apply to detach the hook from the 'to remove' jobs." }
    return
}
if ($manualRows) {
    Write-Host "Paste these into Job settings > Advanced > Scripts > 'Run the following script after the job':"
    $manualRows | ForEach-Object { Write-Host "  [$($_.Job)]`n    $($_.Command)" }
}
if (-not $Apply) { Write-Host "`nNothing changed. Re-run with -Apply to attach the hook to the 'pending' jobs." }
