#Requires -Version 7.2
<#
.SYNOPSIS
Read-only probe for the health checks. Changes nothing. Writes probe-health-output.txt next to this script.

Shows which services the health check watches (and all Veeam-looking services, so the defaults can be
checked), the upgrade signals as VeeamAware sees them now, VBR's version, and the running sessions with the
state, type and progress the stuck-session check uses. Run it once normally, and once while a Veeam upgrade
is running if you can, to confirm the upgrade signals.
#>
param([switch]$NoVbr)   # -NoVbr: skip the VBR session sections, so Veeam's module is not loaded (use during an upgrade)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $PSScriptRoot 'probe-health-output.txt'
$lines = [System.Collections.Generic.List[string]]::new()
function Section([string]$Name, [scriptblock]$Body) {
    $lines.Add(''); $lines.Add("===== $Name")
    try { $lines.Add((& $Body 2>&1 | Out-String -Width 250).TrimEnd()) } catch { $lines.Add("ERROR: $($_.Exception.Message)") }
}
Import-Module (Join-Path $root 'src\VeeamAware.psm1') -Force
$config = Get-VAConfig
$hs = $config.watch.health

Section 'All services named or displayed like Veeam / PostgreSQL / SQL' {
    Get-Service | Where-Object { $_.Name -match 'veeam|postgres|mssql' -or $_.DisplayName -match 'veeam|postgres' } |
        Sort-Object Name | Format-Table Name, DisplayName, Status, StartType -AutoSize
}
Section 'Watched by the health check (config watch.health.services)' { Get-VAServiceSnapshot $hs.services | Format-Table -AutoSize }
Section 'Upgrade signals' { Get-VAUpgradeSignals $hs.upgrade | Format-List }
Section 'Processes with Veeam in the name, path or command line' {
    Get-CimInstance Win32_Process | Where-Object { "$($_.Name) $($_.ExecutablePath) $($_.CommandLine)" -match 'veeam' } |
        Sort-Object Name | Format-Table ProcessId, Name, @{ n = 'CommandLine'; e = { "$($_.CommandLine)".Substring(0, [Math]::Min(150, "$($_.CommandLine)".Length)) } } -AutoSize
}
Section 'Windows Installer InProgress key' { Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress' }
Section 'VBR registry (version values)' {
    Get-ItemProperty 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication' -ErrorAction SilentlyContinue |
        Select-Object * -ExcludeProperty PS* | Format-List
}
Section 'Health state' { (Read-VAState).health | ConvertTo-Json -Depth 5 }

Section 'Windows Installer service' { "$((Get-Service msiserver -ErrorAction SilentlyContinue).Status)" }
Section 'Setup-like or CD/ISO processes (name, company, path)' {
    $cd = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | ForEach-Object DeviceID)
    Get-CimInstance Win32_Process | Where-Object { $p = $_; $p.ExecutablePath -and ($p.Name -match 'setup|install|upgrade|wizard|msiexec' -or @($cd | Where-Object { $_ -and $p.ExecutablePath -like "$_\*" }).Count) } |
        ForEach-Object { [pscustomobject]@{ Id = $_.ProcessId; Name = $_.Name; Company = try { (Get-Item -LiteralPath $_.ExecutablePath).VersionInfo.CompanyName } catch { '' }; Path = $_.ExecutablePath } } |
        Format-Table -AutoSize
}

if ($NoVbr) { $lines | Set-Content -Path $out -Encoding utf8; Write-Host "Wrote $out (VBR sections skipped)"; return }
try {
    Connect-VASource -Config $config
    Section 'Running sessions (state, type, progress)' {
        Get-VASessions -EndedAfter ([datetimeoffset]::UtcNow.AddHours(-1)) | Where-Object { "$($_.state)" -ne 'Stopped' } |
            Format-Table name, sessionType, state, creationTime, @{ n = 'pct'; e = { Get-VAProp $_ 'progress.progressPercent' } },
            @{ n = 'processed'; e = { Format-VASize (Get-VAProp $_ 'progress.processedSize') } } -AutoSize
    }
    Section 'Session states seen in the last 7 days' {
        Get-VASessions -EndedAfter ([datetimeoffset]::UtcNow.AddDays(-7)) -DetailAfter ([datetimeoffset]::UtcNow) |
            Group-Object sessionType, state | Sort-Object Name | Format-Table Count, Name -AutoSize
    }
}
catch { $lines.Add("ERROR connecting: $($_.Exception.Message)") }
finally { Disconnect-VASource }

$lines | Set-Content -Path $out -Encoding utf8
Write-Host "Wrote $out"
