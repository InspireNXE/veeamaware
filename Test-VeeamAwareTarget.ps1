#Requires -Version 7.2
<#
.SYNOPSIS
Checks every configured target (or the named ones) without creating real alerts.

Chat targets (discord, teams) get a "VeeamAware is connected" card; webhooks get a kind="test" event
(schema veeamaware.event/v1). Plugin types may run their own check. -WhatIf prints the payloads instead.
-ListTypes shows the target types that are installed.

Exit code = number of targets that failed.
#>
[CmdletBinding()]
param([string]$ConfigPath, [string[]]$Target, [string]$SourceText, [switch]$WhatIf, [switch]$ListTypes)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\VeeamAware.psm1') -Force

if ($ListTypes) {
    Get-VATargetType | ForEach-Object { [pscustomobject]@{ Type = $_.Type; Description = $_.Description; Source = $_.Source } } | Format-Table -AutoSize
    foreach ($e in Get-VAPluginErrors) { Write-Host "[fail] plugin $e" -ForegroundColor Red }
    exit @(Get-VAPluginErrors).Count
}

$cfgArgs = @{}; if ($ConfigPath) { $cfgArgs.Path = $ConfigPath }
$config = Get-VAConfig @cfgArgs
foreach ($w in @(Get-VAConfigWarnings)) { Write-Host "[warn] $w" -ForegroundColor Yellow }
$failed = 0
$chosen = @(Get-VATargets $config | Where-Object { -not $Target -or $Target -contains $_.name })
$unknown = @($Target | Where-Object { $_ -and $_ -notin @(Get-VATargets $config | ForEach-Object { "$($_.name)" }) })
foreach ($u in $unknown) { Write-Host "  No enabled target named '$u'." -ForegroundColor Red; $failed++ }
if (-not $chosen.Count -and -not $unknown.Count) { Write-Host '  No targets to test.' -ForegroundColor Yellow }

foreach ($t in $chosen) {
    try {
        $out = @(Test-VATarget -Config $config -Target $t -SourceText $SourceText -WhatIf:$WhatIf)
        if ($WhatIf) { Write-Host "----- $($t.type) target '$($t.name)' would receive:"; $out | ForEach-Object { Write-Host $_ } }
        if ($WhatIf) { Write-Host "  Built a test message for $($t.type) target '$($t.name)' (WhatIf: nothing sent)." -ForegroundColor Green }
        else { Write-Host "  Sent a test message to $($t.type) target '$($t.name)'." -ForegroundColor Green }
    }
    catch {
        $failed++
        Write-Host "  Could not reach $($t.type) target '$($t.name)': $($_.Exception.Message)" -ForegroundColor Red
    }
}
exit $failed
