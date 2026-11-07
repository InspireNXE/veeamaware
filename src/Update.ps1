# Release channel and update checks against GitHub releases.
#
#   stable   newest release that is not marked "pre-release"
#   preview  newest release of any kind (pre-releases included), so preview users also get stable fixes
#
# Tags are semantic versions with an optional "v": v0.3.0, v0.4.0-preview.1. The module version in
# VeeamAware.psm1 is the installed version. install.ps1 (the bootstrap) carries its own copy of the release
# lookup, because it runs before any of this is on disk.

function ConvertTo-VASemVer {
    <# "v1.2.3-preview.4" -> @{ Version = [version]1.2.3; Pre = 'preview.4' } or $null. #>
    param([string]$Text)
    if ("$Text" -notmatch '^\s*v?(\d+)\.(\d+)(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+\S*)?\s*$') { return $null }
    $patch = if ($Matches[3]) { [int]$Matches[3] } else { 0 }
    [pscustomobject]@{ Version = [version]::new([int]$Matches[1], [int]$Matches[2], $patch); Pre = "$($Matches[4])" }
}

function Compare-VAVersion {
    <# -1 / 0 / 1 like [string]::Compare. A pre-release sorts before its release (0.3.0-preview.1 < 0.3.0). #>
    param([Parameter(Mandatory)][string]$A, [Parameter(Mandatory)][string]$B)
    $x = ConvertTo-VASemVer $A; $y = ConvertTo-VASemVer $B
    if (-not $x -or -not $y) { throw "Not a version: '$(if (-not $x) { $A } else { $B })'" }
    $c = $x.Version.CompareTo($y.Version)
    if ($c) { return [Math]::Sign($c) }
    if ($x.Pre -eq $y.Pre) { return 0 }
    if (-not $x.Pre) { return 1 }
    if (-not $y.Pre) { return -1 }
    # Dot-separated identifiers: numbers compare numerically, everything else as text.
    $p = $x.Pre.Split('.'); $q = $y.Pre.Split('.')
    for ($i = 0; $i -lt [Math]::Max($p.Count, $q.Count); $i++) {
        if ($i -ge $p.Count) { return -1 }
        if ($i -ge $q.Count) { return 1 }
        $m = 0; $n = 0
        $c = if ([int]::TryParse($p[$i], [ref]$m) -and [int]::TryParse($q[$i], [ref]$n)) { $m.CompareTo($n) } else { [string]::CompareOrdinal($p[$i], $q[$i]) }
        if ($c) { return [Math]::Sign($c) }
    }
    return 0
}

function Get-VAUpdateSettings {
    param($Config)
    $channel = "$(Get-VAProp $Config 'update.channel' 'stable')".ToLowerInvariant()
    if ($channel -notin 'stable', 'preview') { Write-VALog "update.channel '$channel' is not stable/preview; using stable." -Level Warning; $channel = 'stable' }
    $repo = "$(Get-VAProp $Config 'update.repository' '')"
    if (-not $repo) { $repo = $script:VARepository }
    [pscustomobject]@{ Channel = $channel; Repository = $repo; Notify = [bool](Get-VAProp $Config 'update.notify' $true) }
}

function Select-VARelease {
    <# Picks the newest release for a channel from GitHub's /releases list (drafts and non-version tags ignored). #>
    param([object[]]$Releases, [ValidateSet('stable', 'preview')][string]$Channel = 'stable')
    $best = $null
    foreach ($r in @($Releases)) {
        if (-not $r -or $r.draft -or -not (ConvertTo-VASemVer $r.tag_name)) { continue }
        if ($Channel -eq 'stable' -and ($r.prerelease -or (ConvertTo-VASemVer $r.tag_name).Pre)) { continue }
        if (-not $best -or (Compare-VAVersion $r.tag_name $best.tag_name) -gt 0) { $best = $r }
    }
    return $best
}

function Get-VAUpdateInfo {
    <#
    Is a newer release available on the configured channel? Results are kept in state for 12 hours, so the
    digest doesn't ask GitHub on every run (-Force skips that). Never throws: on any error, Available is
    $false and Error says why.
    #>
    param([Parameter(Mandatory)]$Config, [switch]$Force)
    $s = Get-VAUpdateSettings $Config
    $current = Get-VAVersion
    $info = [ordered]@{ Current = $current; Channel = $s.Channel; Repository = $s.Repository; Latest = $null; Tag = $null
        Url = $null; ZipUrl = $null; Prerelease = $false; Available = $false; Error = $null; CheckedUtc = $null }
    if (-not $s.Repository -or $s.Repository -notmatch '^[\w.-]+/[\w.-]+$') { $info.Error = 'update.repository is not set'; return [pscustomobject]$info }

    $cache = $null
    if (-not $Force) {
        $st = Read-VAState
        $cache = $st['update']
        $fresh = $cache -and "$($cache['channel'])" -eq $s.Channel -and "$($cache['repository'])" -eq $s.Repository -and
            ($t = ConvertTo-VADate $cache['checkedUtc']) -and ([datetimeoffset]::UtcNow - $t).TotalHours -lt 12
        if (-not $fresh) { $cache = $null }
    }
    if (-not $cache) {
        try {
            $list = Invoke-RestMethod -Uri "https://api.github.com/repos/$($s.Repository)/releases?per_page=30" -TimeoutSec 20 `
                -Headers @{ 'User-Agent' = (Get-VAUserAgent); Accept = 'application/vnd.github+json' }
            $r = Select-VARelease -Releases @($list) -Channel $s.Channel
            $cache = [ordered]@{ channel = $s.Channel; repository = $s.Repository; checkedUtc = [datetimeoffset]::UtcNow.ToString('o')
                tag = $(if ($r) { $r.tag_name }); url = $(if ($r) { $r.html_url }); zip = $(if ($r) { $r.zipball_url }); prerelease = [bool]$(if ($r) { $r.prerelease }) }
            Update-VAState { param($st) $st['update'] = $cache } | Out-Null
        }
        catch { $info.Error = "release check failed: $($_.Exception.Message)"; return [pscustomobject]$info }
    }
    if ($cache['tag']) {
        $info.Tag = "$($cache['tag'])"; $info.Latest = $info.Tag -replace '^v', ''; $info.Url = $cache['url']; $info.ZipUrl = $cache['zip']
        $info.Prerelease = [bool]$cache['prerelease']; $info.CheckedUtc = $cache['checkedUtc']
        $info.Available = (Compare-VAVersion $info.Latest $current) -gt 0
    }
    else { $info.Error = "no $($s.Channel) release published yet" }
    return [pscustomobject]$info
}
