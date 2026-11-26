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

A job that already has a post-job script of its own (enabled or not) is left alone unless you add -Overwrite.
The script it replaces is saved in state\replaced-post-job-scripts.json, and -Remove puts it back.

-Remove detaches the hook again (only a post-job command that runs VeeamAware.ps1 itself; other scripts,
including ones that merely have VeeamAware in their name, are left alone). Uninstall-VeeamAware.ps1 uses it.

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
# Local server. VBR 13 throws when this session is already connected (the installer's VBR check leaves it
# connected), and -ErrorAction can't silence that, so ignore just that error.
try { Connect-VBRServer -ErrorAction Stop }
catch { if ($_.Exception.Message -notmatch 'already connected') { throw } }

$pwsh = Join-Path $PSHOME 'pwsh.exe'
$hook = Join-Path $PSScriptRoot 'VeeamAware.ps1'
function Get-HookCommand([guid]$JobId) { "`"$pwsh`" -NoProfile -ExecutionPolicy Bypass -File `"$hook`" -JobId $JobId" }
$match = { param($n) @($Name | Where-Object { $n -like $_ }).Count -gt 0 }
# A VeeamAware hook from any install folder or version: PowerShell running ...\VeeamAware.ps1 and nothing else
# (an optional -JobId). Notify-VeeamAware.ps1 or a wrapper that also does other things is someone else's.
$isHook = { param($c) "$c" -match '^\s*"?[^"]*(pwsh|powershell)(\.exe)?"?\s(.*\s)?-File\s+"?[^"]*[\\/]VeeamAware\.ps1"?(\s+-JobId\s+[0-9a-fA-F-]{36})?\s*$' }

# Post-job scripts -Overwrite replaced, by job id, so -Remove can put them back.
$savedPath = Join-Path $PSScriptRoot 'state\replaced-post-job-scripts.json'
$saved = [ordered]@{}
if (Test-Path -LiteralPath $savedPath) { foreach ($p in (Get-Content -Raw -LiteralPath $savedPath | ConvertFrom-Json).PSObject.Properties) { $saved[$p.Name] = $p.Value } }
$savedChanged = $false

function Set-VAPostScript($Job, $Opts, [bool]$Enabled, [string]$Command) {
    <#
    Sets a job's post-job script and checks that VBR kept it. Backup copy jobs (SimpleBackupCopyPolicy in v12+)
    ignore Set-VBRJobOptions without an error, so they go through Set-VBRBackupCopyJob -ScriptOptions instead,
    keeping their pre-job script and how often the scripts run.
    #>
    if ("$($Job.JobType)" -match 'BackupCopyPolicy') {
        $bcj = @(Get-VBRBackupCopyJob -WarningAction SilentlyContinue | Where-Object { "$($_.Id)" -eq "$($Job.Id)" }) | Select-Object -First 1
        if (-not $bcj) { $bcj = @(Get-VBRBackupCopyJob -WarningAction SilentlyContinue | Where-Object { $_.Name -eq $Job.Name }) | Select-Object -First 1 }
        if (-not $bcj) { throw 'Get-VBRBackupCopyJob does not list this job.' }
        $js = $Opts.JobScriptCommand
        $p = @{ PostScriptEnabled = $Enabled; PreScriptEnabled = [bool]$js.PreScriptEnabled }
        if ($Command) { $p.PostCommand = $Command }
        if ("$($js.PreScriptCommandLine)") { $p.PreCommand = "$($js.PreScriptCommandLine)" }
        $when = @{}
        if ($js.Periodicity) { $when.Periodicity = "$($js.Periodicity)" }
        if ($js.Frequency) { $when.Frequency = [uint32]$js.Frequency }
        if (@($js.Days).Count) { $when.Day = @($js.Days) }
        # Carry over how often the scripts run; if this VBR names those settings differently, use its defaults.
        $so = try { New-VBRJobScriptOptions @p @when -ErrorAction Stop } catch { New-VBRJobScriptOptions @p -ErrorAction Stop }
        Set-VBRBackupCopyJob -Job $bcj -ScriptOptions $so -ErrorAction Stop | Out-Null
    }
    else {
        $Opts.JobScriptCommand.PostScriptEnabled = $Enabled
        $Opts.JobScriptCommand.PostScriptCommandLine = $Command
        Set-VBRJobOptions -Job $Job -Options $Opts | Out-Null
    }
    $fresh = @(Get-VBRJob -WarningAction SilentlyContinue | Where-Object { $_.Id -eq $Job.Id }) | Select-Object -First 1
    $now = if ($fresh) { (Get-VBRJobOptions -Job $fresh).JobScriptCommand } else { $null }
    # Detaching with nothing to put back only needs the script turned off; VBR may keep the old text.
    $kept = if (-not $Enabled -and -not $Command) { -not [bool]$now.PostScriptEnabled }
            else { "$($now.PostScriptCommandLine)" -eq $Command -and [bool]$now.PostScriptEnabled -eq $Enabled }
    if ($now -and -not $kept) {
        throw "VBR did not keep the change (post-job script is still '$($now.PostScriptCommandLine)')."
    }
}

$rows = [System.Collections.Generic.List[object]]::new()

# Get-VBRJob is deprecated for agent jobs in v13; those are handled by Get-VBRComputerBackupJob below.
foreach ($job in (Get-VBRJob -WarningAction SilentlyContinue | Where-Object { "$($_.JobType)" -notmatch 'EpAgent' -and (& $match $_.Name) })) {
    $cmd = Get-HookCommand $job.Id
    $id = "$($job.Id)"
    try {
        $opts = Get-VBRJobOptions -Job $job
        $current = "$($opts.JobScriptCommand.PostScriptCommandLine)"
        $enabled = [bool]$opts.JobScriptCommand.PostScriptEnabled
        $ours = & $isHook $current
        $status = 'pending'
        if ($Remove) {
            if ($ours) {
                $status = if ($saved.Contains($id)) { 'to remove (puts back your script)' } else { 'to remove' }
                if ($Apply) {
                    if ($saved.Contains($id)) { Set-VAPostScript $job $opts ([bool]$saved[$id].enabled) "$($saved[$id].command)" }
                    else { Set-VAPostScript $job $opts $false '' }
                    $status = if ($saved.Contains($id)) { 'removed (your script is back)' } else { 'removed' }
                    if ($saved.Contains($id)) { $saved.Remove($id); $savedChanged = $true }
                }
            }
            else { $status = if ($current) { 'other script (left alone)' } else { 'not attached' } }
        }
        elseif ($ours -and $enabled -and $current -eq $cmd) { $status = 'already set' }
        elseif ($current -and -not $ours -and -not $Overwrite) {
            $status = if ($enabled) { 'has other script (use -Overwrite)' } else { 'has a disabled script (use -Overwrite)' }
        }
        elseif ($Apply) {
            Set-VAPostScript $job $opts $true $cmd
            if ($current -and -not $ours) { $saved[$id] = [ordered]@{ job = $job.Name; enabled = $enabled; command = $current }; $savedChanged = $true }
            $status = if ($ours) { 'updated' } elseif ($current) { 'attached (your script saved)' } else { 'attached' }
        }
        elseif ($ours) { $status = 'pending (update the hook)' }
    }
    catch { $status = "failed: $($_.Exception.Message)" }
    $rows.Add([pscustomobject]@{ Job = $job.Name; Type = "$($job.JobType)"; Status = $status; Command = $cmd })
}
if ($savedChanged) {
    $dir = Split-Path -Parent $savedPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $saved | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $savedPath -Encoding utf8NoBOM
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
