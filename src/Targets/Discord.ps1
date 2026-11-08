# Built-in target type "discord": renders reports as Discord embeds and posts them to a channel webhook.
#
# Target options (also accepted in the top-level "discord" block, which is shorthand for a target named "discord"):
#   webhookUrl     https://discord.com/api/webhooks/<id>/<token>            (required)
#   threadId       post into a thread of a forum/text channel
#   username, avatarUrl
#   mentions       { onFailure: ["<@&role>"], onWarning: [], onSuccess: [], onSecurity: [] }
#   statusBadges   attach the coloured status badge as the thumbnail (default true)
#   ansiColors     colour the object table with ```ansi blocks (default true)
#
# Limits: https://discord.com/developers/docs/resources/message#embed-object-embed-limits

$script:VADiscordLimits = @{
    Title = 256; Description = 4096; Fields = 25; FieldName = 256; FieldValue = 1024
    Footer = 2048; Author = 256; EmbedsPerMessage = 10; CharsPerMessage = 6000; Content = 2000
}

# ---- Embed primitives -----------------------------------------------------------------------------------

function New-VAEmbed {
    param(
        [string]$Title,
        [string]$Description,
        [int]$Color = 0x95A5A6,
        [object[]]$Fields = @(),
        [string]$Footer,
        $Timestamp,
        [string]$Url,
        [string]$ThumbnailUrl,
        [string]$Author
    )
    $l = $script:VADiscordLimits
    $embed = [ordered]@{ color = $Color }
    if ($Author) { $embed.author = @{ name = Limit-VAText $Author $l.Author } }
    if ($Title) { $embed.title = Limit-VAText $Title $l.Title }
    if ($Url) { $embed.url = $Url }
    if ($Description) { $embed.description = Limit-VAText $Description $l.Description }
    $f = @($Fields | Where-Object { $_ -and $_.value } | Select-Object -First $l.Fields | ForEach-Object {
            [ordered]@{
                name   = Limit-VAText ([string]$_.name) $l.FieldName
                value  = Limit-VAText ([string]$_.value) $l.FieldValue
                inline = [bool]$_.inline
            }
        })
    if ($f.Count) { $embed.fields = $f }
    if ($Footer) { $embed.footer = @{ text = Limit-VAText $Footer $l.Footer } }
    $ts = ConvertTo-VADate $Timestamp
    if ($ts) { $embed.timestamp = $ts.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
    if ($ThumbnailUrl) { $embed.thumbnail = @{ url = $ThumbnailUrl } }
    return $embed
}

function New-VAField {
    param([Parameter(Mandatory)][string]$Name, [AllowNull()][AllowEmptyString()][string]$Value, [switch]$Inline)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    [ordered]@{ name = $Name; value = $Value; inline = [bool]$Inline }
}

function Split-VALinesToChunks {
    <# Packs lines into chunks no longer than $Max characters (for field values / descriptions). #>
    param([string[]]$Lines, [Parameter(Mandatory)][int]$Max)
    $chunks = [System.Collections.Generic.List[string]]::new()
    $sb = [System.Text.StringBuilder]::new()
    foreach ($line in $Lines) {
        $line = Limit-VAText $line $Max
        if ($sb.Length -and ($sb.Length + 1 + $line.Length) -gt $Max) { $chunks.Add($sb.ToString()); [void]$sb.Clear() }
        if ($sb.Length) { [void]$sb.Append("`n") }
        [void]$sb.Append($line)
    }
    if ($sb.Length) { $chunks.Add($sb.ToString()) }
    return , $chunks.ToArray()
}

function Measure-VAEmbed {
    param($Embed)
    $n = 0
    foreach ($k in 'title', 'description') { if ($Embed.Contains($k)) { $n += "$($Embed[$k])".Length } }
    if ($Embed.Contains('author')) { $n += "$($Embed.author.name)".Length }
    if ($Embed.Contains('footer')) { $n += "$($Embed.footer.text)".Length }
    if ($Embed.Contains('fields')) { foreach ($f in $Embed.fields) { $n += "$($f.name)".Length + "$($f.value)".Length } }
    return $n
}

function Group-VAEmbeds {
    <# Splits embeds into batches that respect Discord's 10-embed and 6000-character per-message limits. #>
    param([object[]]$Embeds)
    $l = $script:VADiscordLimits
    $batches = [System.Collections.Generic.List[object]]::new()
    $current = [System.Collections.Generic.List[object]]::new()
    $chars = 0
    foreach ($e in $Embeds) {
        $size = Measure-VAEmbed $e
        if ($current.Count -and ($current.Count -ge $l.EmbedsPerMessage -or ($chars + $size) -gt $l.CharsPerMessage)) {
            $batches.Add($current.ToArray()); $current.Clear(); $chars = 0
        }
        $current.Add($e); $chars += $size
    }
    if ($current.Count) { $batches.Add($current.ToArray()) }
    return , $batches.ToArray()
}

# ---- Formatting ---------------------------------------------------------------------------------------------

function Get-VABadgeUrl {
    <# Thumbnail for the embed (uploaded with the message), or $null when badges are off. #>
    param($Config, [Parameter(Mandatory)][ValidateSet('success', 'warning', 'failed', 'info', 'security')][string]$Kind)
    if (-not $Config) { $Config = $script:VAActiveConfig }
    if ($Config -and -not (Get-VAProp $Config 'discord.statusBadges' $true)) { return $null }
    "attachment://status-$Kind.png"
}

function Format-VAAnsi {
    <# Wraps text in a Discord ```ansi colour code (green/yellow/red/gray) when ANSI colouring is enabled. #>
    param([string]$Text, [ValidateSet('green', 'yellow', 'red', 'gray', 'white')][string]$Color, [bool]$Enabled)
    if (-not $Enabled -or -not $Text) { return $Text }
    $code = @{ gray = 30; red = 31; green = 32; yellow = 33; white = 37 }[$Color]
    "$([char]27)[2;${code}m$Text$([char]27)[0m"
}

function Format-VACodeBlock {
    param([string[]]$Lines, [bool]$Ansi)
    $lang = if ($Ansi) { 'ansi' } else { '' }
    "``````$lang`n$($Lines -join "`n")`n``````"
}

function Format-VADiscordParts {
    param([AllowNull()][object[]]$Parts)
    Format-VAParts $Parts -Time { param($d, $s) Format-VADiscordTime $d $s }
}

function Format-VAObjectTable {
    <#
    Object rows for the ```ansi block: status mark, name, transferred, duration, columns aligned. Each line
    stays within $Width columns (the status badge narrows the embed; a longer line wraps its last column onto
    its own line): size and duration columns are as wide as their widest value, empty ones are left out, and
    the name gets the rest.
    #>
    param([object[]]$Rows, [bool]$Ansi, [int]$More = 0, [int]$Width = 38)
    $rows = @($Rows)
    if (-not $rows) { return @() }
    $colW = { param($key) [int](@($rows | ForEach-Object { "$($_[$key])".Length }) + 0 | Measure-Object -Maximum).Maximum }
    $sizeW = & $colW 'size'; $durW = & $colW 'duration'
    $room = $Width - 2 - $(if ($sizeW) { 2 + $sizeW } else { 0 }) - $(if ($durW) { 2 + $durW } else { 0 })
    $longest = [int](@($rows | ForEach-Object { "$($_.name)".Length }) | Measure-Object -Maximum).Maximum
    $w = [Math]::Max(10, [Math]::Min($longest, $room))
    $lines = foreach ($t in $rows) {
        $mark, $color = switch -Regex ($t.status) {
            '^Success' { '✔', 'green' } '^Warning' { '▲', 'yellow' } '^Fail' { '✖', 'red' } default { '•', 'gray' }
        }
        $nm = "$($t.name)"
        $name = if ($nm.Length -gt $w) { $nm.Substring(0, $w - 1) + '…' } else { $nm.PadRight($w) }
        $line = "$(Format-VAAnsi $mark $color $Ansi) $(Format-VAAnsi $name 'white' $Ansi)"
        if ($sizeW) { $line += '  ' + "$($t.size)".PadLeft($sizeW) }
        if ($durW) { $line += '  ' + "$($t.duration)".PadLeft($durW) }
        $line.TrimEnd()
    }
    if ($More -gt 0) { $lines = @($lines) + (Format-VAAnsi "  …and $More more" 'gray' $Ansi) }
    return @($lines)
}

function Format-VARepositoryBar {
    <# One code-block line: "repo ▰▰▰▰▰▰▱▱▱▱ 58% · 3.11/5.36 TB". #>
    param($Info, [bool]$Ansi)
    if (-not $Info -or $null -eq $Info.PercentFree) { return $null }
    $used = [int][Math]::Round(10 * (100 - $Info.PercentFree) / 100)
    if ($used -ge 10 -and $Info.PercentFree -gt 0) { $used = 9 }   # some space left shows one red block, like Teams
    $color = if ($Info.PercentFree -le 10) { 'red' } elseif ($Info.PercentFree -le 20) { 'yellow' } else { 'green' }
    $bar = (Format-VAAnsi ('▰' * (10 - $used)) $color $Ansi) + (Format-VAAnsi ('▱' * $used) 'gray' $Ansi)
    # Kept under ~38 columns: the badge thumbnail narrows the embed and a wrapped bar is hard to read.
    "repo $bar $([Math]::Round($Info.PercentFree))% · $(Format-VASpaceRatio $Info)"
}

function Format-VARepositoryLine {
    param($Info)
    $gb = { param($v) Format-VASize ([double]$v * 1GB) }
    if ($null -eq $Info.PercentFree) { return "**$(Protect-VAMarkdown $Info.Name)** · capacity not reported" }
    $usedBlocks = [int][Math]::Round(10 * (100 - $Info.PercentFree) / 100)
    $bar = ('▰' * $usedBlocks) + ('▱' * (10 - $usedBlocks))
    $state = if (-not $Info.Online) { ' · 🔌 offline' } else { '' }
    "**$(Protect-VAMarkdown $Info.Name)** $bar $($Info.PercentFree)% free ($(& $gb $Info.FreeGB) of $(& $gb $Info.CapacityGB))$state"
}

function Get-VATrendColor {
    <# Red when the repository fills within 14 days, yellow within 30, else gray. #>
    param($Info)
    $d = if ($Info -and $Info.PSObject.Properties['Trend'] -and $Info.Trend) { $Info.Trend.DaysToFull }
    if ($null -ne $d -and $d -le 14) { 'red' } elseif ($null -ne $d -and $d -le 30) { 'yellow' } else { 'gray' }
}

function Format-VAHistoryTable {
    <# Rows of a "history" section: coloured day strip, job name, runs, size, duration; agents under a divider. #>
    param([Parameter(Mandatory)]$Section, [bool]$Ansi, [int]$MaxWidth = 46)
    $rows = @($Section['rows'])
    $roll = $Section['rollup']
    $max = { param($vals, $min) [Math]::Max($min, [int](@($vals | ForEach-Object { "$_".Length }) + 0 | Measure-Object -Maximum).Maximum) }
    # Every column is as wide as its widest value; the name column gets what is left of $MaxWidth (about the
    # widest line a Discord embed with the badge thumbnail shows unwrapped). Long names are cut with "…".
    $stripW = [int](@($rows | ForEach-Object { @($_['history']).Count }) + 0 | Measure-Object -Maximum).Maximum
    $digits = & $max @($rows | ForEach-Object { $_['runs'] }) 1
    $runsW = $digits + 5
    $sizeW = & $max (@($rows | ForEach-Object { $_['size'] }) + @(if ($roll) { $roll['size'] })) 1
    $durW = & $max @($rows | ForEach-Object { $_['duration'] }) 0
    $fixed = $stripW + 1 + 1 + $runsW + 1 + $sizeW + $(if ($durW) { 1 + $durW } else { 0 })
    $longest = & $max (@($rows | ForEach-Object { $_['name'] }) + @(if ($roll) { "$($roll['count']) others" })) 4
    $w = [Math]::Min($longest, [Math]::Max(8, $MaxWidth - $fixed))
    $strip = { param($h) if ($Ansi) { Format-VAHistoryStrip $h 'ansi' } else { Format-VAHistoryStrip $h 'text' } }
    $fit = { param($n) $n = "$n"; if ($n.Length -gt $w) { $n.Substring(0, $w - 1) + '…' } else { $n.PadRight($w) } }
    $group = $null
    foreach ($r in $rows) {
        if ($group -and $r['group'] -ne $group) {
            $label = "─ $($r['group']) "
            Format-VAAnsi ($label + '─' * [Math]::Max(3, $fixed + $w - $label.Length)) 'gray' $Ansi
        }
        $group = $r['group']
        # Runs: count right-aligned, then "run"/"runs" left-aligned, so "1 run" and "2 runs" line up.
        $runs = "$("$($r['runs'])".PadLeft($digits)) $(if ($r['runs'] -ne 1) { 'runs' } else { 'run ' })"
        $line = "$(& $strip $r['history']) $(& $fit $r['name']) $runs $("$($r['size'])".PadLeft($sizeW))"
        if ($durW) { $line += " $("$($r['duration'])".PadLeft($durW))" }
        $line.TrimEnd()
    }
    if ($roll) {
        "$(& $strip $roll['history']) $(& $fit "$($roll['count']) others") $(Format-VAAnsi ('all OK'.PadRight($runsW)) 'green' $Ansi) $("$($roll['size'])".PadLeft($sizeW))".TrimEnd()
    }
}

# ---- Report -> embeds ---------------------------------------------------------------------------------------

function ConvertTo-VADiscordEmbeds {
    <#
    .SYNOPSIS
    Renders a report (see Report.ps1). One main embed: header as author, title, status line, quotes and note in
    the description, facts as an inline stat grid, "objects" sections as aligned code-block fields. Each "list"
    or "repositories" section follows as its own embed. The footer goes on the last embed.
    #>
    param([Parameter(Mandatory)]$Report, [bool]$Ansi = $true, [bool]$Badges = $true)
    $r = $Report
    $l = $script:VADiscordLimits
    $embeds = [System.Collections.Generic.List[object]]::new()

    $head = "$($r.icon) **$($r.label)**".Trim()
    $sum = Format-VADiscordParts $r.summary
    if ($sum) { $head += " · $sum" }
    $gauge = if ($r.gauge) { $bar = Format-VARepositoryBar $r.gauge $Ansi; if ($bar) { "`n" + (Format-VACodeBlock @($bar) $Ansi) } } else { '' }
    $note = if ($r.note) { "`n`n-# $($r.note)" } else { '' }
    $quoteLines = @(foreach ($q in $r.quotes) {
            if ($q['title']) {
                $l1 = "> $(if ($q['icon']) { "$($q['icon']) " })**$(Protect-VAMarkdown $q['title'])**"
                $p = Format-VADiscordParts $q['parts']
                if ($p) { $l1 += " $p" }
                if ($q['text']) { "$l1`n> $(if ($q['parts']) { '-# ' })$($q['text'])" } else { $l1 }
            }
            elseif ($q['icon']) { "> $($q['icon']) $($q['text'])" }
            else { "> $($q['text'])" }
        })
    $desc = $head
    if ($quoteLines) {
        $budget = $l.Description - $head.Length - "$gauge".Length - $note.Length - 4
        $desc += "`n`n" + (Split-VALinesToChunks $quoteLines ([Math]::Max(200, $budget)))[0]
    }
    $desc += "$gauge$note"

    $fields = @($r.facts | ForEach-Object { New-VAField $_['name'] (Format-VADiscordParts @($_['value'])) -Inline } | Where-Object { $_ })
    foreach ($sec in @($r.sections | Where-Object { $_['type'] -eq 'objects' })) {
        $lines = @(Format-VAObjectTable -Rows @($sec['rows']) -Ansi $Ansi -More ([int]$sec['more']))
        $repoLine = Format-VARepositoryBar $sec['repository'] $Ansi
        if ($repoLine) {
            if ($lines) { $lines += Format-VAAnsi ('─' * 34) 'gray' $Ansi }
            $lines += $repoLine
            $trend = Format-VARepositoryTrend $sec['repository']
            if ($trend) { $lines += Format-VAAnsi "     $trend" (Get-VATrendColor $sec['repository']) $Ansi }
        }
        if (-not $lines) { continue }
        # A field holds 1024 characters including the fence; spill extra rows into continuation fields.
        $chunks = Split-VALinesToChunks $lines 1000
        for ($i = 0; $i -lt [Math]::Min($chunks.Count, 3); $i++) {
            $fields += New-VAField $(if ($i) { "$($sec['title']) (cont.)" } else { $sec['title'] }) (Format-VACodeBlock ($chunks[$i] -split "`n") $Ansi)
        }
    }

    foreach ($sec in @($r.sections | Where-Object { $_['type'] -in 'history', 'repositories', 'text' })) {
        $lines = switch ($sec['type']) {
            'history' { @(Format-VAHistoryTable -Section $sec -Ansi $Ansi) }
            'repositories' {
                @(foreach ($repo in $sec['items']) {
                        $nm = Limit-VAText "$($repo.Name)" 34
                        if ($null -eq $repo.PercentFree) { "$nm · capacity not reported"; continue }
                        $line = (Format-VARepositoryBar $repo $Ansi) -replace '^repo ', ''
                        if (-not $repo.Online) { $line += ' · offline' }
                        $nm; "  $line"
                        $trend = Format-VARepositoryTrend $repo
                        if ($trend) { Format-VAAnsi "  $trend" (Get-VATrendColor $repo) $Ansi }
                    })
            }
            'text' { @($sec['lines'] | ForEach-Object { Format-VADiscordParts @($_) }) }
        }
        if (-not $lines) { continue }
        $name = "$($sec['icon']) $($sec['title'])".Trim()
        if ($sec['type'] -eq 'text') { $fields += New-VAField $name (($lines -join "`n") | ForEach-Object { Limit-VAText $_ 1024 }); continue }
        $chunks = Split-VALinesToChunks $lines 1000
        for ($i = 0; $i -lt [Math]::Min($chunks.Count, 3); $i++) {
            $fields += New-VAField $(if ($i) { "$name (cont.)" } else { $name }) (Format-VACodeBlock ($chunks[$i] -split "`n") $Ansi)
        }
    }

    $badge = if ($Badges) { "attachment://status-$($r.status).png" }
    $title = if ($badge -or -not $r.icon) { $r.title } else { "$($r.icon) $($r.title)" }
    $embeds.Add((New-VAEmbed -Author (Get-VAAuthorLine $r.header $r.server) -Title $title -Description $desc `
                -Color (ConvertFrom-VAHexColor $r.color) -ThumbnailUrl $badge -Fields $fields -Timestamp $r.timestamp))

    foreach ($sec in @($r.sections | Where-Object { $_['type'] -eq 'list' })) {
        $lines = @(foreach ($it in $sec['items']) {
                    $line = "$(Get-VAItemIcon $it) **$(Protect-VAMarkdown $it['name'])**"
                    $p = Format-VADiscordParts $it['parts']
                    if ($p) { $line += " · $p" }
                    $line
                    foreach ($c in @($it['children'])) {
                        $cl = "   $(Get-VAItemIcon $c) **$(Protect-VAMarkdown $c['name'])**"
                        if ($c['text'] -and "$($c['status'])" -notmatch '^Success') { $cl += "`n   └ $($c['text'])" }
                        $cl
                    }
                    if ([int]$it['more'] -gt 0) { "   …and $($it['more']) more" }
                })
        if ([int]$sec['more'] -gt 0) { $lines += "-# …and $($sec['more']) more" }
        if (-not $lines) { continue }
        $name = "$($sec['icon']) $($sec['title'])".Trim()
        $chunks = Split-VALinesToChunks $lines 4000
        $color = ConvertFrom-VAHexColor $sec['color'] 0x5865F2
        $max = $chunks.Count
        for ($i = 0; $i -lt $max; $i++) {
            $embeds.Add((New-VAEmbed -Title $(if ($i) { "$name (cont.)" } else { $name }) -Description $chunks[$i] -Color $color))
        }
    }

    $embeds[$embeds.Count - 1].footer = @{ text = Get-VAFooter }
    return , $embeds.ToArray()
}

# Report-specific shortcuts (used by the tests and handy for previews): build the report and render it with the
# options of the top-level "discord" block.
function Get-VADiscordRenderOptions {
    param($Config)
    if (-not $Config) { $Config = $script:VAActiveConfig }
    @{ Ansi = [bool](Get-VAProp $Config 'discord.ansiColors' $true); Badges = [bool](Get-VAProp $Config 'discord.statusBadges' $true) }
}
function New-VASessionEmbeds { param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Summary) $o = Get-VADiscordRenderOptions $Config; ConvertTo-VADiscordEmbeds (New-VASessionReport -Config $Config -Summary $Summary) @o }
function New-VAMalwareEmbed { param([Parameter(Mandatory)]$Event) $o = Get-VADiscordRenderOptions; (ConvertTo-VADiscordEmbeds (New-VAMalwareReport $Event) @o)[0] }
function New-VARepositoryEmbed { param([Parameter(Mandatory)]$Info, [Parameter(Mandatory)][string]$Level, [string]$PreviousLevel = 'ok') $o = Get-VADiscordRenderOptions; (ConvertTo-VADiscordEmbeds (New-VARepositoryReport -Info $Info -Level $Level -PreviousLevel $PreviousLevel) @o)[0] }
function New-VAAnalyzerEmbed { param([object[]]$NewViolations, [int]$TotalViolations, $LastRun) $o = Get-VADiscordRenderOptions; (ConvertTo-VADiscordEmbeds (New-VAAnalyzerReport -NewViolations $NewViolations -TotalViolations $TotalViolations -LastRun $LastRun) @o)[0] }
function New-VAAuthorizationEmbed { param([Parameter(Mandatory)]$Event) $o = Get-VADiscordRenderOptions; (ConvertTo-VADiscordEmbeds (New-VAAuthorizationReport $Event) @o)[0] }
function New-VADigestEmbeds {
    param([Parameter(Mandatory)]$Config, $Digest, [Parameter(Mandatory)][datetimeoffset]$From, [Parameter(Mandatory)][datetimeoffset]$To,
        [object[]]$AgentSummaries = @(), [object[]]$OtherSessions = @(), [object[]]$Repositories = @(), [object[]]$MalwareEvents = @(), [int]$AnalyzerViolations = -1)
    $o = Get-VADiscordRenderOptions $Config
    ConvertTo-VADiscordEmbeds (New-VADigestReport @PSBoundParameters) @o
}

# ---- Delivery -----------------------------------------------------------------------------------------------

function Get-VAMentionContent {
    <# The target's mention list for this kind plus any extra (a routing rule's), valid and de-duplicated. #>
    param($Config, [ValidateSet('Failure', 'Warning', 'Success', 'Security')][string]$Kind, [string[]]$Extra = @())
    $list = @(@(Get-VAProp $Config "discord.mentions.on$Kind" @()) + @($Extra)) |
        Where-Object { "$_" -match '^<@[!&]?\d+>$|^@(everyone|here)$' } | Select-Object -Unique
    return ($list -join ' ')
}

function Send-VADiscord {
    <#
    .SYNOPSIS
    Posts one or more embeds to the configured webhook. Mentions (if any) are attached to the first message only.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][object[]]$Embeds,
        [string]$Content,
        [switch]$WhatIf
    )
    # Every setting but webhookUrl is optional: a Discord entry in "targets" may set only what it needs.
    $d = Get-VAProp $Config 'discord'
    $uri = "$(Get-VAProp $d 'webhookUrl')?wait=true"
    $thread = "$(Get-VAProp $d 'threadId' '')"
    if ($thread) { $uri += "&thread_id=$thread" }
    $username = "$(Get-VAProp $d 'username' '')"
    $avatar = "$(Get-VAProp $d 'avatarUrl' '')"
    $first = $true
    foreach ($batch in (Group-VAEmbeds $Embeds)) {
        $payload = [ordered]@{
            username         = if ($username) { $username } else { 'VeeamAware' }
            embeds           = @($batch)
            allowed_mentions = @{ parse = @('users', 'roles', 'everyone') }
        }
        if ($avatar) { $payload.avatar_url = $avatar }
        if ($first -and $Content) { $payload.content = Limit-VAText $Content $script:VADiscordLimits.Content }
        $files = Get-VADiscordAttachments $batch
        $json = $payload | ConvertTo-Json -Depth 12 -Compress
        if ($WhatIf) {
            Write-Output $json
            if ($files.Count) { Write-Output "(attachments: $(($files | ForEach-Object { Split-Path $_ -Leaf }) -join ', '))" }
            $first = $false; continue
        }
        Send-VADiscordRaw -Uri $uri -Json $json -Files $files
        $first = $false
    }
}

function Get-VADiscordAttachments {
    <#
    Embeds reference bundled images as "attachment://<file>" (the status badge thumbnail). Returns the local
    files to upload with the message; a badge whose file is missing is dropped from the embed instead.
    #>
    param([object[]]$Embeds)
    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $Embeds) {
        foreach ($slot in 'thumbnail', 'image') {
            if (-not $e.Contains($slot)) { continue }
            $url = "$($e[$slot].url)"
            if ($url -notmatch '^attachment://([\w.-]+)$') { continue }
            $path = Resolve-VAPath "assets\$($Matches[1])"
            if (Test-Path -LiteralPath $path) { if (-not $files.Contains($path)) { $files.Add($path) } }
            else { $e.Remove($slot); Write-VALog "Badge image missing (copy the assets folder): $path" -Level Warning }
        }
    }
    return , $files.ToArray()
}

function New-VADiscordBody {
    <# JSON body, or multipart/form-data (payload_json + files[n]) when images are attached. Built per attempt. #>
    param([Parameter(Mandatory)][string]$Json, [string[]]$Files = @())
    if (-not $Files.Count) { return [System.Text.Encoding]::UTF8.GetBytes($Json) }
    $form = [System.Net.Http.MultipartFormDataContent]::new()
    $part = [System.Net.Http.StringContent]::new($Json, [System.Text.Encoding]::UTF8, 'application/json')
    $form.Add($part, 'payload_json')
    for ($i = 0; $i -lt $Files.Count; $i++) {
        $img = [System.Net.Http.ByteArrayContent]::new([System.IO.File]::ReadAllBytes($Files[$i]))
        $img.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('image/png')
        $form.Add($img, "files[$i]", (Split-Path $Files[$i] -Leaf))
    }
    return , $form   # the comma stops PowerShell enumerating the form into its parts
}

function Send-VADiscordRaw {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$Json, [string[]]$Files = @())
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            $body = New-VADiscordBody -Json $Json -Files $Files
            $ct = if ($Files.Count) { $null } else { 'application/json; charset=utf-8' }
            $req = @{
                Method = 'Post'; Uri = $Uri; Body = $body; TimeoutSec = 30; SkipHttpErrorCheck = $true
                UserAgent = Get-VAUserAgent
            }
            if ($ct) { $req.ContentType = $ct }
            $resp = Invoke-WebRequest @req
        }
        catch {
            Write-VALog "Discord request error (attempt $attempt): $($_.Exception.Message)" -Level Warning
            Start-Sleep -Seconds (2 * $attempt); continue
        }
        $code = [int]$resp.StatusCode
        if ($code -ge 200 -and $code -lt 300) {
            Write-VALog "Discord accepted message ($code, $($bytes.Length) bytes)" -Level Debug
            # Back off pre-emptively when this bucket is exhausted.
            $remaining = "$($resp.Headers['X-RateLimit-Remaining'])"
            $reset = "$($resp.Headers['X-RateLimit-Reset-After'])"
            if ($remaining -eq '0' -and $reset) { Start-Sleep -Milliseconds ([int]([double]$reset * 1000) + 100) }
            return
        }
        if ($code -eq 429) {
            $retry = 1.0
            try { $retry = [double](($resp.Content | ConvertFrom-Json).retry_after) } catch { }
            Write-VALog "Discord rate limited, retrying in $retry s" -Level Warning
            Start-Sleep -Milliseconds ([int]($retry * 1000) + 250)
            continue
        }
        if ($code -ge 500) { Start-Sleep -Seconds (2 * $attempt); continue }
        # 4xx other than 429 will not succeed on retry (bad webhook, invalid payload).
        throw "Discord rejected the message ($code): $(Limit-VAText $resp.Content 500)"
    }
    throw 'Discord did not accept the message after 5 attempts.'
}

function Send-VADiscordEvent {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$Event, $Context)
    $cfg = if ($Context) { $Context.Config } else { $script:VAActiveConfig }
    $ansi = [bool](Get-VATargetOption $Target 'ansiColors' (Get-VAProp $cfg 'discord.ansiColors' $true))
    $badges = [bool](Get-VATargetOption $Target 'statusBadges' (Get-VAProp $cfg 'discord.statusBadges' $true))
    $embeds = ConvertTo-VADiscordEmbeds -Report $Event.report -Ansi $ansi -Badges $badges
    $t = @{ discord = $Target }
    $extra = if ($Event.Contains('mentionExtra')) { @($Event.mentionExtra) } else { @() }
    $content = if ($Event.mention) { Get-VAMentionContent $t $Event.mention -Extra $extra } else { '' }
    Send-VADiscord -Config $t -Embeds $embeds -Content $content -WhatIf:([bool]($Context -and $Context.WhatIf))
}

Register-VATargetType -Type discord -Description 'Discord channel webhook (embeds with status badges)' `
    -Validate {
        param($Target, $Context)
        if ("$(Get-VAProp $Target 'webhookUrl' '')" -notmatch '^https://(?:(?:ptb|canary)\.)?discord(?:app)?\.com/api/webhooks/\d+/[\w-]+$') {
            'webhookUrl must be a Discord webhook URL (https://discord.com/api/webhooks/<id>/<token>).'
        }
        if ($Target.Contains('threadId') -and $Target.threadId -and "$($Target.threadId)" -notmatch '^\d+$') { 'threadId must be numeric.' }
    } `
    -Wants { param($Target, $Event) $null -ne $Event.report } `
    -Send { param($Target, $Event, $Context) Send-VADiscordEvent -Target $Target -Event $Event -Context $Context }
