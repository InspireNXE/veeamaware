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
    if ($Text -notmatch '^v?(\d+)\.(\d+)(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?$') { return $null }
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
try {
    $zip = Join-Path $work 'release.zip'
    Invoke-WebRequest -Uri $zipUrl -OutFile $zip -Headers @{ 'User-Agent' = 'VeeamAware-installer' } -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath (Join-Path $work 'x')
    $src = Get-ChildItem (Join-Path $work 'x') -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'Install-VeeamAware.ps1') } | Select-Object -First 1
    if (-not $src) { throw "The download from $zipUrl doesn't look like a VeeamAware release." }
    $src = $src.FullName

    # 3. Copy, keeping the user's files ---------------------------------------------------------------------
    # Pause the watcher so it doesn't load a half-copied module.
    $watchTask = Get-ScheduledTask -TaskPath '\VeeamAware\' -TaskName 'VeeamAware Watch' -ErrorAction SilentlyContinue
    if ($watchTask) { $watchTask | Disable-ScheduledTask | Out-Null; Stop-ScheduledTask -TaskPath '\VeeamAware\' -TaskName 'VeeamAware Watch' -ErrorAction SilentlyContinue }

    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null }
    $rc = @('/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:2', '/W:2')
    robocopy $src $Path /XF '.gitignore' '.gitattributes' @rc | Out-Null                          # top-level files
    if ($LASTEXITCODE -ge 8) { throw "Copy failed (robocopy $LASTEXITCODE)" }
    foreach ($dir in 'src', 'assets', 'docs', 'tests', 'tools') {                                    # ours: mirror
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
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

# 4. Configure under PowerShell 7 -------------------------------------------------------------------------
$installArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Path 'Install-VeeamAware.ps1'))
if ($channelGiven) { $installArgs += @('-Channel', $Channel) }
if ($Update) { $installArgs += '-Update' }
$installArgs += $InstallerArguments
& $pwsh @installArgs
$code = $LASTEXITCODE
if ($watchTask -and $code) { $watchTask | Enable-ScheduledTask | Out-Null }   # the installer re-enables it on success
if ($code) { throw "Install-VeeamAware.ps1 exited with $code" }
