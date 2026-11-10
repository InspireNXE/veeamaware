<#
.SYNOPSIS
Downloads a VeeamAware release from GitHub and installs or updates it. Safe to re-run.

.DESCRIPTION
One line, from an elevated PowerShell (Windows PowerShell 5.1 or PowerShell 7) on the VBR server:

    irm https://raw.githubusercontent.com/inspirenxe/veeamaware/main/install.ps1 | iex

With options (preview channel, another folder, a specific version):

    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/inspirenxe/veeamaware/main/install.ps1))) -Channel preview
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/inspirenxe/veeamaware/main/install.ps1))) -Tag v0.1.0

It picks the newest release on the channel (stable: full releases; preview: pre-releases too), copies it
into -Path and runs Install-VeeamAware.ps1 under PowerShell 7. config\config.json, secrets\, state\, logs\
and your plugins\ are never overwritten. Update-VeeamAware.ps1 runs this same script for updates.

Runs on Windows PowerShell 5.1 as well, so keep the syntax 5.1-compatible.
#>
[CmdletBinding()]
param(
    [string]$Path = 'C:\VeeamAware',
    [ValidateSet('', 'stable', 'preview')][string]$Channel = '',   # default: the installed copy's channel, else stable
    [string]$Tag,                         # a release tag (v0.1.0) or a branch name (main) instead of the newest release
    [string]$Repository = 'inspirenxe/veeamaware',
    [switch]$Update,                      # no prompts, no test message (used by Update-VeeamAware.ps1)
    [string[]]$InstallerArguments = @()
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar in 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this from an elevated PowerShell (Run as administrator).' }

$pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
if (-not (Test-Path $pwsh)) {
    $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($cmd) { $pwsh = $cmd.Source } else { throw 'PowerShell 7 not found. VBR 13 installs it; is this the backup server?' }
}
$headers = @{ 'User-Agent' = 'VeeamAware-installer'; Accept = 'application/vnd.github+json' }

# Re-running the one-liner keeps the channel an existing install is on; -Channel changes it.
$channelGiven = [bool]$Channel
if (-not $Channel) {
    $Channel = 'stable'
    $existing = Join-Path $Path 'config\config.json'
    if (Test-Path $existing) {
        try { $c = (Get-Content -Raw $existing | ConvertFrom-Json).update.channel; if ($c -in 'stable', 'preview') { $Channel = $c } } catch { }
    }
}

function Get-SemVer([string]$Text) {
    # Build metadata (+...) is allowed and ignored, as in src\Update.ps1.
    if ($Text -notmatch '^v?(\d+)\.(\d+)(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$') { return $null }
    $patch = 0; if ($Matches[3]) { $patch = [int]$Matches[3] }
    [pscustomobject]@{ Version = New-Object version ([int]$Matches[1]), ([int]$Matches[2]), $patch; Pre = [string]$Matches[4] }
}
function Compare-SemVer([string]$A, [string]$B) {
    # Same ordering as Compare-VAVersion in src\Update.ps1 (pre-releases sort before their release).
    $x = Get-SemVer $A; $y = Get-SemVer $B
    $c = $x.Version.CompareTo($y.Version); if ($c) { return [Math]::Sign($c) }
    if ($x.Pre -eq $y.Pre) { return 0 }; if (-not $x.Pre) { return 1 }; if (-not $y.Pre) { return -1 }
    $p = $x.Pre.Split('.'); $q = $y.Pre.Split('.')
    for ($i = 0; $i -lt [Math]::Max($p.Count, $q.Count); $i++) {
        if ($i -ge $p.Count) { return -1 }; if ($i -ge $q.Count) { return 1 }
        $m = 0; $n = 0
        if ([int]::TryParse($p[$i], [ref]$m) -and [int]::TryParse($q[$i], [ref]$n)) { $c = $m.CompareTo($n) } else { $c = [string]::CompareOrdinal($p[$i], $q[$i]) }
        if ($c) { return [Math]::Sign($c) }
    }
    return 0
}

# 1. Which version ------------------------------------------------------------------------------------------
if ($Tag) {
    if (Get-SemVer $Tag) { $zipUrl = "https://github.com/$Repository/archive/refs/tags/$Tag.zip"; $label = $Tag }
    else { $zipUrl = "https://github.com/$Repository/archive/refs/heads/$Tag.zip"; $label = "branch $Tag" }
}
else {
    # No @() here: Windows PowerShell 5.1 returns the JSON array as one object, and @() would nest it.
    $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases?per_page=30" -Headers $headers -UseBasicParsing
    $best = $null
    foreach ($r in $releases) {
        if ($r.draft -or -not (Get-SemVer $r.tag_name)) { continue }
        if ($Channel -eq 'stable' -and ($r.prerelease -or (Get-SemVer $r.tag_name).Pre)) { continue }
        if (-not $best -or (Compare-SemVer $r.tag_name $best.tag_name) -gt 0) { $best = $r }
    }
    if (-not $best) { throw "No $Channel release of $Repository yet. Use -Channel preview, or -Tag main for the development branch." }
    $zipUrl = "https://github.com/$Repository/archive/refs/tags/$($best.tag_name).zip"
    $label = "$($best.tag_name) ($Channel)"
}
Write-Host "VeeamAware $label -> $Path"

# 2. Download and unpack ------------------------------------------------------------------------------------
$work = Join-Path ([IO.Path]::GetTempPath()) ("veeamaware-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$watchTask = $null
$copied = $false
try {
    $zip = Join-Path $work 'release.zip'
    Invoke-WebRequest -Uri $zipUrl -OutFile $zip -Headers @{ 'User-Agent' = 'VeeamAware-installer' } -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath (Join-Path $work 'x')
    $src = Get-ChildItem (Join-Path $work 'x') -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'Install-VeeamAware.ps1') } | Select-Object -First 1
    if (-not $src) { throw "The download from $zipUrl doesn't look like a VeeamAware release." }
    $src = $src.FullName

    # 3. Copy, keeping the user's files ---------------------------------------------------------------------
    # Pause the watcher so it doesn't load a half-copied module. A task someone switched off stays off: it is
    # left alone here, and the installer is told (VEEAMAWARE_WATCH_PAUSED) which of the two it is.
    $watchTask = Get-ScheduledTask -TaskPath '\VeeamAware\' -TaskName 'VeeamAware Watch' -ErrorAction SilentlyContinue
    if ($watchTask -and "$($watchTask.State)" -eq 'Disabled') { $watchTask = $null }
    if ($watchTask) {
        $watchTask | Disable-ScheduledTask | Out-Null; Stop-ScheduledTask -TaskPath '\VeeamAware\' -TaskName 'VeeamAware Watch' -ErrorAction SilentlyContinue
        $env:VEEAMAWARE_WATCH_PAUSED = '1'
    }

    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null }
    # The watcher runs this code as SYSTEM, and C:\ lets any user modify new folders: lock the folder down
    # (SYSTEM and Administrators full, Users read) and take ownership before copying code into it.
    & icacls.exe $Path /setowner '*S-1-5-32-544' /C /Q | Out-Null
    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /C /Q | Out-Null
    if ($LASTEXITCODE) { throw "Could not set permissions on $Path (icacls $LASTEXITCODE)" }
    $rc = @('/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:2', '/W:2')
    # The module (src) is staged next to the old one and swapped in by renaming, so a copy that fails part-way
    # leaves the old module whole instead of half old, half new.
    $srcNew = Join-Path $Path 'src.new'; $srcOld = Join-Path $Path 'src.old'
    foreach ($d in $srcNew, $srcOld) { if (Test-Path $d) { Remove-Item $d -Recurse -Force } }
    robocopy (Join-Path $src 'src') $srcNew /MIR @rc | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copy of src failed (robocopy $LASTEXITCODE)" }
    robocopy $src $Path /XF '.gitignore' '.gitattributes' @rc | Out-Null                          # top-level files
    if ($LASTEXITCODE -ge 8) { throw "Copy failed (robocopy $LASTEXITCODE)" }
    if (Test-Path (Join-Path $Path 'src')) { Rename-Item (Join-Path $Path 'src') 'src.old' }
    Rename-Item $srcNew 'src'
    Remove-Item $srcOld -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($dir in 'assets', 'docs', 'tests', 'tools') {                                           # ours: mirror
        if (Test-Path (Join-Path $src $dir)) {
            robocopy (Join-Path $src $dir) (Join-Path $Path $dir) /MIR @rc | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "Copy of $dir failed (robocopy $LASTEXITCODE)" }
        }
    }
    foreach ($dir in 'config', 'plugins') {                                                          # yours: add only
        robocopy (Join-Path $src $dir) (Join-Path $Path $dir) /E /XC /XN /XO /XF 'config.json' @rc | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Copy of $dir failed (robocopy $LASTEXITCODE)" }
    }
    # The example config and plugin readme should follow the release even though the folders are "yours".
    Copy-Item (Join-Path $src 'config\config.example.json') (Join-Path $Path 'config\config.example.json') -Force
    Copy-Item (Join-Path $src 'plugins\targets\README.md') (Join-Path $Path 'plugins\targets\README.md') -Force -ErrorAction SilentlyContinue
    Get-ChildItem $Path -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' | Unblock-File
    $copied = $true
}
catch {
    if ((Test-Path (Join-Path $Path 'src.old')) -and -not (Test-Path (Join-Path $Path 'src'))) { Rename-Item (Join-Path $Path 'src.old') 'src' }
    Write-Warning "The update stopped part-way. Run it again to finish; the watcher keeps running meanwhile."
    throw
}
finally {
    # Don't leave monitoring switched off (a failure, or Ctrl+C, which skips catch): the watcher is what would
    # tell anyone something is wrong. On success the installer below turns it back on.
    if ($watchTask -and -not $copied) { $watchTask | Enable-ScheduledTask | Out-Null }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

# 4. Configure under PowerShell 7 -------------------------------------------------------------------------
$installArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Path 'Install-VeeamAware.ps1'))
if ($channelGiven) { $installArgs += @('-Channel', $Channel) }
if ($Update) { $installArgs += '-Update' }
$installArgs += $InstallerArguments
$code = $null
try {
    & $pwsh @installArgs
    $code = $LASTEXITCODE
}
finally {
    # The installer turns the watcher back on when it succeeds; on a failure or Ctrl+C, do it here.
    if ($watchTask -and $code -ne 0) { $watchTask | Enable-ScheduledTask | Out-Null }
    Remove-Item Env:\VEEAMAWARE_WATCH_PAUSED -ErrorAction SilentlyContinue
}
if ($code) { throw "Install-VeeamAware.ps1 exited with $code" }
