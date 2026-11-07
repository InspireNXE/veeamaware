# Target setup for Install-VeeamAware.ps1: reads and edits the targets in a parsed config.json (the object
# from ConvertFrom-Json), so the installer's prompts stay thin and the editing logic is testable.
#
# The first Discord target named "discord" lives in the top-level "discord" block (so discord.* settings in
# the README apply to it); every other target goes in "targets". Disabled entries (the shipped examples) are
# not listed, and adding a target with the same name replaces such an entry.

$script:VASetupTypes = [ordered]@{
    discord = @{ Label = 'Discord channel'; Hint = 'Channel settings > Integrations > Webhooks > New Webhook > Copy Webhook URL'
        Pattern = '^https://(?:(?:ptb|canary)\.)?discord(?:app)?\.com/api/webhooks/\d+/[\w-]+$'; Example = 'https://discord.com/api/webhooks/<id>/<token>' }
    teams   = @{ Label = 'Microsoft Teams channel'; Hint = 'Channel ... > Workflows > "Post to a channel when a webhook request is received"'
        Pattern = '^https://\S+$'; Example = 'https://...' }
    webhook = @{ Label = 'Generic JSON webhook (n8n, Home Assistant, your own API)'; Hint = 'Receives veeamaware.event/v1 JSON by POST'
        Pattern = '^https?://\S+$'; Example = 'https://n8n.example.com/webhook/veeam' }
}
$script:VASetupSeverities = [ordered]@{ info = 'Everything (successes too)'; warning = 'Warnings and failures'; critical = 'Failures only' }

function Test-VAPlaceholderUrl { param([AllowNull()][string]$Url) "$Url" -notmatch '^https?://' -or "$Url" -match 'replace-me' }

function Format-VAMaskedUrl {
    <# "https://discord.com/…" — enough to recognise a target without printing the token. #>
    param([string]$Url)
    if ("$Url" -match '^(https?://[^/?#]+)') { "$($Matches[1])/…" } else { '(not set)' }
}

function Get-VASetupTargets {
    <# The enabled targets in a parsed config: Name, Type, Url, MinSeverity, InBlock (top-level discord). #>
    param([Parameter(Mandatory)]$Json)
    $d = Get-VAProp $Json 'discord'
    if ($d -and -not (Test-VAPlaceholderUrl (Get-VAProp $d 'webhookUrl'))) {
        [pscustomobject]@{ Name = 'discord'; Type = 'discord'; Url = "$($d.webhookUrl)"; MinSeverity = "$(Get-VAProp $d 'minSeverity' 'info')"; InBlock = $true }
    }
    foreach ($t in @(Get-VAProp $Json 'targets' @())) {
        if (-not $t -or -not (Get-VAProp $t 'enabled' $true)) { continue }
        $url = "$(Get-VAProp $t 'url' (Get-VAProp $t 'webhookUrl' ''))"
        [pscustomobject]@{ Name = "$($t.name)"; Type = "$($t.type)"; Url = $url; MinSeverity = "$(Get-VAProp $t 'minSeverity' 'info')"; InBlock = $false }
    }
}

function Get-VAFreeTargetName {
    <# "discord", then "discord-2", "discord-3"... skipping names already in use. #>
    param([Parameter(Mandatory)]$Json, [Parameter(Mandatory)][string]$Base)
    $used = @(Get-VASetupTargets $Json | ForEach-Object Name)
    if ($used -notcontains $Base) { return $Base }
    for ($i = 2; ; $i++) { if ($used -notcontains "$Base-$i") { return "$Base-$i" } }
}

function Test-VASetupTarget {
    <# Problems with a target about to be added (empty = fine). #>
    param([Parameter(Mandatory)]$Json, [string]$Type, [string]$Name, [string]$Url)
    if (-not $script:VASetupTypes.Contains($Type)) { return "Unknown type '$Type' (use $($script:VASetupTypes.Keys -join ', '))." }
    $spec = $script:VASetupTypes[$Type]
    if ("$Url".Trim() -notmatch $spec.Pattern) { return "That doesn't look like a $($spec.Label) URL ($($spec.Example))." }
    if ("$Name" -notmatch '^[A-Za-z0-9][\w.-]*$') { return 'Names use letters, digits, dot, dash and underscore.' }
    if (@(Get-VASetupTargets $Json | Where-Object Name -eq $Name).Count) { return "A target named '$Name' already exists." }
    $dup = @(Get-VASetupTargets $Json | Where-Object { $_.Url.TrimEnd('/') -eq "$Url".Trim().TrimEnd('/') })
    if ($dup.Count) { return "Target '$($dup[0].Name)' already posts to that URL." }
}

function Add-VASetupTarget {
    <# Adds a target to the parsed config. Extra options (tokenFile...) come in $Options. Returns its name. #>
    param([Parameter(Mandatory)]$Json, [Parameter(Mandatory)][string]$Type, [string]$Name, [Parameter(Mandatory)][string]$Url,
        [ValidateSet('info', 'warning', 'critical')][string]$MinSeverity = 'info', [hashtable]$Options = @{})
    if (-not $Name) { $Name = Get-VAFreeTargetName $Json $Type }
    $problem = Test-VASetupTarget -Json $Json -Type $Type -Name $Name -Url $Url
    if ($problem) { throw $problem }
    $Url = $Url.Trim()

    # The first Discord target named "discord" fills the top-level block (keeping its mentions etc.).
    $d = Get-VAProp $Json 'discord'
    if ($Type -eq 'discord' -and $Name -eq 'discord' -and (-not $d -or (Test-VAPlaceholderUrl (Get-VAProp $d 'webhookUrl')))) {
        if (-not $d) { $Json | Add-Member discord ([pscustomobject]@{}); $d = $Json.discord }
        $d | Add-Member webhookUrl $Url -Force
        if ($MinSeverity -ne 'info') { $d | Add-Member minSeverity $MinSeverity -Force }
        elseif ($d.PSObject.Properties['minSeverity']) { $d.PSObject.Properties.Remove('minSeverity') }
        return $Name
    }

    $entry = [ordered]@{ type = $Type; name = $Name; enabled = $true }
    if ($Type -eq 'discord') { $entry.webhookUrl = $Url } else { $entry.url = $Url }
    $entry.minSeverity = $MinSeverity
    foreach ($k in $Options.Keys) { $entry[$k] = $Options[$k] }
    # A disabled entry with this name (one of the shipped examples) is replaced rather than duplicated.
    $list = @(@(Get-VAProp $Json 'targets' @()) | Where-Object { $_ -and "$($_.name)" -ne $Name })
    $list += [pscustomobject]$entry
    $Json | Add-Member targets $list -Force
    return $Name
}

function Remove-VASetupTarget {
    param([Parameter(Mandatory)]$Json, [Parameter(Mandatory)][string]$Name)
    $t = @(Get-VASetupTargets $Json | Where-Object Name -eq $Name)
    if (-not $t) { throw "No target named '$Name'." }
    if ($t[0].InBlock) { $Json.discord.webhookUrl = ''; return }
    $Json | Add-Member targets @(@(Get-VAProp $Json 'targets' @()) | Where-Object { $_ -and "$($_.name)" -ne $Name }) -Force
}

function ConvertFrom-VATargetSpec {
    <# "-Target" values: "discord=https://...", "teams:ops=https://...", "webhook:n8n@warning=https://...". #>
    param([Parameter(Mandatory)][string]$Spec)
    if ($Spec -notmatch '^\s*(?<type>[a-z]+)(?::(?<name>[\w.-]+))?(?:@(?<sev>info|warning|critical))?\s*=\s*(?<url>\S+)\s*$') {
        throw "Can't read -Target '$Spec'. Use type[:name][@severity]=url, e.g. teams:ops@warning=https://..."
    }
    [pscustomobject]@{ Type = $Matches['type']; Name = "$($Matches['name'])"; MinSeverity = $(if ($Matches['sev']) { $Matches['sev'] } else { 'info' }); Url = $Matches['url'] }
}

function Get-VASetupTypes { $script:VASetupTypes }
function Get-VASetupSeverities { $script:VASetupSeverities }

# ---- Settings (installer menu) -------------------------------------------------------------------------------
#
# The installer edits config.json in place: values are read from the effective config (defaults + file), so a
# prompt's default is whatever is set now, and only the keys the user changes are written to the file.

function Get-VASetupValue {
    <# The effective value of a dotted path: config.json's value, else VeeamAware's default. #>
    param([Parameter(Mandatory)]$Json, [Parameter(Mandatory)][string]$Path, $Default = $null)
    $copy = $Json | ConvertTo-Json -Depth 20 | ConvertFrom-Json   # Merge-VAConfig changes what it is given
    $effective = Merge-VAConfig (Get-VADefaultConfig) $copy
    Get-VAProp $effective $Path $Default
}

function Set-VASetupValue {
    <# Sets a dotted path in the parsed config.json, creating the objects on the way. #>
    param([Parameter(Mandatory)]$Json, [Parameter(Mandatory)][string]$Path, [AllowNull()]$Value)
    $parts = $Path.Split('.')
    $o = $Json
    foreach ($p in $parts[0..($parts.Count - 2)]) {
        $next = $o.PSObject.Properties[$p]
        if (-not $next -or $next.Value -isnot [System.Management.Automation.PSCustomObject]) {
            $o | Add-Member -NotePropertyName $p -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        $o = $o.$p
    }
    $o | Add-Member -NotePropertyName $parts[-1] -NotePropertyValue $Value -Force
}

function Get-VASetupDigest {
    <# The first digest in config.json (the one the installer edits), creating "daily" when there is none. #>
    param([Parameter(Mandatory)]$Json)
    $list = @(Get-VAProp $Json 'digests' @())
    if (-not $list) {
        $d = [pscustomobject]@{ name = 'daily'; enabled = $true; schedule = [pscustomobject]@{ every = 'day'; at = '08:00' }; targets = @('*') }
        $Json | Add-Member digests @($d) -Force
        return $d
    }
    return $list[0]
}

$script:VAAgentModes = [ordered]@{
    failures = @{ Label = 'Failures right away, everything else in the digest'; Short = 'failures right away, the rest in the digest'; success = 'digest'; warning = 'digest'; failure = 'immediate' }
    problems = @{ Label = 'Warnings and failures right away, successes in the digest'; Short = 'warnings and failures right away'; success = 'digest'; warning = 'immediate'; failure = 'immediate' }
    all      = @{ Label = 'Every run right away'; Short = 'every run right away'; success = 'immediate'; warning = 'immediate'; failure = 'immediate' }
    digest   = @{ Label = 'Digest only'; Short = 'digest only'; success = 'digest'; warning = 'digest'; failure = 'digest' }
}
function Get-VAAgentModes { $script:VAAgentModes }

function Get-VASetupAgentMode {
    <# How agent job results are routed now: a key of Get-VAAgentModes, 'custom' or $null (no agent rule). #>
    param([Parameter(Mandatory)]$Json)
    $rules = @(Get-VASetupValue $Json 'routing.rules' @())
    $r = $rules | Where-Object { @(Get-VAProp $_ 'match.jobTypes' @()) -contains 'AgentBackup' } | Select-Object -First 1
    if (-not $r) { return $null }
    foreach ($k in $script:VAAgentModes.Keys) {
        $m = $script:VAAgentModes[$k]
        if ("$(Get-VAProp $r 'success')" -eq $m.success -and "$(Get-VAProp $r 'warning')" -eq $m.warning -and "$(Get-VAProp $r 'failure')" -eq $m.failure) { return $k }
    }
    'custom'
}

function Set-VASetupAgentMode {
    <# Points the agent routing rule at a mode, adding the rule (first) when config.json has none. #>
    param([Parameter(Mandatory)]$Json, [Parameter(Mandatory)][string]$Mode)
    $m = $script:VAAgentModes[$Mode]; if (-not $m) { throw "Unknown agent mode '$Mode'." }
    $rules = @(Get-VASetupValue $Json 'routing.rules' @())
    $r = $rules | Where-Object { @(Get-VAProp $_ 'match.jobTypes' @()) -contains 'AgentBackup' } | Select-Object -First 1
    if (-not $r) {
        $r = [pscustomobject]@{ name = 'Veeam Agents'; match = [pscustomobject]@{ jobTypes = @('AgentBackup', 'AgentPolicy') } }
        $rules = @($r) + $rules
    }
    foreach ($k in 'success', 'warning', 'failure') { $r | Add-Member -NotePropertyName $k -NotePropertyValue $m[$k] -Force }
    $r | Add-Member -NotePropertyName name -NotePropertyValue "Veeam Agents: $($m.Label.ToLowerInvariant())" -Force
    Set-VASetupValue $Json 'routing.rules' @($rules)
}

function Format-VAMinutes {
    param([int]$Minutes)
    if ($Minutes -le 0) { return 'never' }
    if ($Minutes % 1440 -eq 0) { return "$($Minutes / 1440) d" }
    if ($Minutes % 60 -eq 0) { return "$($Minutes / 60) h" }
    "$Minutes min"
}

function Get-VASetupSummary {
    <# The installer menu: one line per settings group, showing what is set now. #>
    param([Parameter(Mandatory)]$Json)
    $targets = @(Get-VASetupTargets $Json)
    $h = Get-VASetupValue $Json 'watch.health'
    $health = if (-not (Get-VAProp $h 'enabled' $true)) { 'off' } else {
        $tm = Get-VAHealthTiming $h 'services'
        "on, alert after $(Format-VAMinutes $tm.FirstAlertAfter), repeat $(if ($tm.RepeatEvery -gt 0) { "every $(Format-VAMinutes $tm.RepeatEvery)" } else { 'never' })$(if (-not (Get-VAProp $h 'sessions.enabled' $true)) { ', stuck jobs off' })"
    }
    $d = @(Get-VASetupValue $Json 'digests' @()) | Select-Object -First 1
    $digest = if (-not $d) { 'none' } elseif (-not (Get-VAProp $d 'enabled' $true)) { "'$($d.name)' off" } else {
        $when = if ("$(Get-VAProp $d 'schedule.every' 'day')" -eq 'week') { "$(Get-VAProp $d 'schedule.day' 'Monday')s" } else { 'daily' }
        "'$($d.name)' $when at $(Get-VAProp $d 'schedule.at' '08:00')"
    }
    $agent = Get-VASetupAgentMode $Json
    [ordered]@{
        targets = @{ Label = 'Targets'; Value = $(if ($targets) { ($targets | ForEach-Object Name) -join ', ' } else { 'none' }) }
        health  = @{ Label = 'Health alerts'; Value = $health }
        digest  = @{ Label = 'Digest'; Value = $digest }
        agents  = @{ Label = 'Agent jobs'; Value = $(if ($agent -and $script:VAAgentModes.Contains($agent)) { $script:VAAgentModes[$agent].Short } elseif ($agent) { 'custom routing rule' } else { 'every run right away' }) }
        watch   = @{ Label = 'Watcher'; Value = "every $(Format-VAMinutes ([int](Get-VASetupValue $Json 'watch.intervalMinutes' 5)))" }
        source  = @{ Label = 'Data source'; Value = "$(Get-VASetupValue $Json 'vbr.dataSource' 'auto')" }
        updates = @{ Label = 'Updates'; Value = "$(Get-VASetupValue $Json 'update.channel' 'stable') channel$(if (-not (Get-VASetupValue $Json 'update.notify' $true)) { ', no digest note' })" }
        hooks   = @{ Label = 'Post-job hook'; Value = 'review, attach or remove' }
    }
}

# Installer console style. One palette everywhere, so the eye learns it once:
#   heading   white title on a dark-cyan rule      hint      dark grey (what a setting does)
#   key       cyan (what you type: 1, 2, a, r)     value     green (what is set now, the default)
#   done      green                                warning   yellow
function Get-VAConsoleWidth {
    $w = try { [int]$Host.UI.RawUI.WindowSize.Width } catch { 0 }
    if ($w -lt 40) { 100 } else { $w }
}
function Write-VAHeading([string]$Text) {
    $w = [Math]::Min(80, (Get-VAConsoleWidth) - 1)
    $rule = [string][char]0x2500   # box-drawing line; built here so the file's encoding cannot garble it
    Write-Host ''
    Write-Host ($rule * 2 + ' ') -NoNewline -ForegroundColor DarkCyan
    Write-Host $Text -NoNewline -ForegroundColor White
    Write-Host (' ' + ($rule * [Math]::Max(3, $w - $Text.Length - 4))) -ForegroundColor DarkCyan
}
function Write-VAHint([string]$Text) { foreach ($l in (Split-VAConsoleText $Text 2)) { Write-Host $l -ForegroundColor DarkGray } }
function Write-VADone([string]$Text) { Write-Host "  $Text" -ForegroundColor Green }
function Write-VAWarn([string]$Text) { Write-Host "  $Text" -ForegroundColor Yellow }
function Split-VAConsoleText([string]$Text, [int]$Indent = 2) {
    # Word-wraps to the console, every line indented, so text never runs back to the left edge.
    $room = [Math]::Max(20, (Get-VAConsoleWidth) - $Indent - 1)
    $lines = [System.Collections.Generic.List[string]]::new(); $line = ''
    foreach ($word in ($Text -split ' ')) {
        if ($line -and ($line.Length + 1 + $word.Length) -gt $room) { $lines.Add($line); $line = $word }
        else { $line = if ($line) { "$line $word" } else { $word } }
    }
    $lines.Add($line)
    $lines | ForEach-Object { (' ' * $Indent) + $_ }
}
function Write-VAOption([string]$Key, [string]$Text, [string]$Note, [switch]$Current, [int]$Width = 0) {
    <#
    One choice in a list: key in cyan, text (padded to -Width so notes line up), optional dim note. The choice
    that is set now is green and ends in "(current)".
    #>
    Write-Host ('  {0,3}  ' -f $Key) -NoNewline -ForegroundColor Cyan
    $fg = if ($Current) { 'Green' } else { 'Gray' }
    Write-Host $(if ($Note) { $Text.PadRight($Width) } else { $Text }) -NoNewline -ForegroundColor $fg
    if ($Note) { Write-Host "  $Note" -NoNewline -ForegroundColor DarkGray }
    if ($Current) { Write-Host '  (current)' -NoNewline -ForegroundColor Green }
    Write-Host ''
}
function Read-VAInput([string]$Prompt, [string]$Default, [string]$Note) {
    <# "  Prompt (note) [default]: " with the default in green; returns the trimmed answer ('' = Enter). #>
    Write-Host "  $Prompt" -NoNewline
    if ($Note) { Write-Host " ($Note)" -NoNewline -ForegroundColor DarkGray }
    if ("$Default" -ne '') { Write-Host ' [' -NoNewline; Write-Host $Default -NoNewline -ForegroundColor Green; Write-Host ']' -NoNewline }
    Write-Host ': ' -NoNewline
    "$(Read-Host)".Trim()
}

function Write-VASetupMenu {
    <#
    Prints the installer menu: number in cyan, label, value in green. A value too long for the console wraps
    under the value column instead of back to the left edge.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Summary)
    $width = Get-VAConsoleWidth
    $labelWidth = [Math]::Max(12, (@($Summary.Values | ForEach-Object { "$($_.Label)".Length }) | Measure-Object -Maximum).Maximum)
    $indent = 7 + $labelWidth + 2
    $room = [Math]::Max(20, $width - $indent - 1)
    $i = 0
    foreach ($k in $Summary.Keys) {
        $i++
        $lines = [System.Collections.Generic.List[string]]::new(); $line = ''
        foreach ($word in ("$($Summary[$k].Value)" -split ' ')) {
            if ($line -and ($line.Length + 1 + $word.Length) -gt $room) { $lines.Add($line); $line = $word }
            else { $line = if ($line) { "$line $word" } else { $word } }
        }
        $lines.Add($line)
        Write-Host ('  {0,3}  ' -f $i) -NoNewline -ForegroundColor Cyan
        Write-Host ("{0,-$labelWidth}  " -f $Summary[$k].Label) -NoNewline
        Write-Host $lines[0] -ForegroundColor Green
        foreach ($l in @($lines | Select-Object -Skip 1)) { Write-Host ((' ' * $indent) + $l) -ForegroundColor Green }
    }
}
