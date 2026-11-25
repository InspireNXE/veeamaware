# Built-in target type "teams": renders reports as an Adaptive Card and posts it to a Microsoft Teams webhook.
#
# Create the URL in Teams with the Workflows app: channel "..." > Workflows > "Post to a channel when a webhook
# request is received". (Legacy Office 365 "Incoming Webhook" connector URLs take the same payload.)
#
# Target options:
#   url             the Workflows / incoming webhook URL (required)
#   timeoutSeconds  default 30
# Teams cannot @mention from a webhook without Entra IDs, so there is no "mentions" option.

$script:VATeamsMaxBytes = 26000   # Teams rejects messages over ~28 KB

function Format-VATeamsTime {
    <# Adaptive Card date functions: Teams shows the time in each reader's own time zone. #>
    param($Date, [string]$Style)
    if ($null -eq $Date) { return '—' }
    $iso = $Date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    if ($Style -eq 't') { "{{TIME($iso)}}" } else { "{{DATE($iso, SHORT)}} {{TIME($iso)}}" }
}

function Format-VATeamsParts { param([AllowNull()][object[]]$Parts) Format-VAParts $Parts -Time { param($d, $s) Format-VATeamsTime $d $s } }

function New-VATeamsText {
    param([AllowEmptyString()][string]$Text, [string]$Size, [string]$Weight, [string]$Color, [switch]$Subtle, [string]$Spacing, [switch]$Mono, [switch]$NoWrap)
    $b = [ordered]@{ type = 'TextBlock'; text = $Text; wrap = -not $NoWrap }
    if ($Size) { $b.size = $Size }
    if ($Weight) { $b.weight = $Weight }
    if ($Color) { $b.color = $Color }
    if ($Subtle) { $b.isSubtle = $true }
    if ($Spacing) { $b.spacing = $Spacing }
    if ($Mono) { $b.fontType = 'Monospace' }
    return $b
}

function Get-VATeamsStatusStyle {
    param([string]$Status)
    switch ($Status) {
        'success' { @{ Container = 'good'; Text = 'Good' } }
        'warning' { @{ Container = 'warning'; Text = 'Warning' } }
        'failed' { @{ Container = 'attention'; Text = 'Attention' } }
        'security' { @{ Container = 'accent'; Text = 'Accent' } }
        default { @{ Container = 'emphasis'; Text = 'Default' } }
    }
}

function Get-VATeamsRowColor {
    param([AllowNull()][string]$Result)
    switch -Regex ($Result) { '^Success' { 'Good' } '^Warning' { 'Warning' } '^Fail' { 'Attention' } default { 'Default' } }
}

function New-VATeamsRun {
    param([string]$Text, [string]$Color, [string]$Size, [string]$Weight, [switch]$Subtle, [switch]$Mono)
    $r = [ordered]@{ type = 'TextRun'; text = $Text }
    if ($Color -and $Color -ne 'Default') { $r.color = $Color }
    if ($Size) { $r.size = $Size }
    if ($Weight) { $r.weight = $Weight }
    if ($Subtle) { $r.isSubtle = $true }
    if ($Mono) { $r.fontType = 'Monospace' }
    return $r
}

function New-VATeamsStrip {
    <#
    History strip as flat coloured squares. Emoji squares (🟩) render as Teams' shaded Fluent emoji with
    rounded corners, so the strip is "■" text runs coloured per result instead, like the Discord ANSI strip.
    #>
    param([AllowEmptyCollection()][object[]]$Results, [string]$Text, [string]$Spacing = 'None', [switch]$Empty)
    $runs = [System.Collections.Generic.List[object]]::new()
    $prev = $null; $buf = ''
    foreach ($res in @($Results)) {
        $c = Get-VATeamsRowColor "$res"
        if ($null -ne $prev -and $c -ne $prev) { $runs.Add((New-VATeamsRun $buf -Color $prev -Subtle:($prev -eq 'Default'))); $buf = '' }
        $buf += '■'; $prev = $c
    }
    if ($buf) { $runs.Add((New-VATeamsRun $buf -Color $prev -Subtle:($prev -eq 'Default'))) }
    if ($Text) { $runs.Add((New-VATeamsRun " $Text" -Subtle)) }
    if (-not $runs.Count) { return $null }
    return [ordered]@{ type = 'RichTextBlock'; spacing = $Spacing; inlines = $runs.ToArray() }
}

function Get-VATeamsSpaceColor {
    param($Info)
    if ($Info.PercentFree -le 10) { 'Attention' } elseif ($Info.PercentFree -le 20) { 'Warning' } else { 'Good' }
}

function New-VATeamsRepository {
    <#
    A repository as name + "58% free · 3.09/5.36 TB", a coloured bar (filled = free space, as on Discord;
    green / amber at 20% / red at 10%) and the trend line. Returns card elements.
    #>
    param($Info, [string]$Spacing = 'Small', [int]$Blocks = 20)
    $name = "$(Get-VAProp $Info 'Name' 'Repository')"
    $offline = $Info.PSObject.Properties['Online'] -and -not $Info.Online
    if ($null -eq $Info.PercentFree) {
        return @(New-VATeamsText "**$name** · capacity not reported$(if ($offline) { ' · 🔌 offline' })" -Spacing $Spacing)
    }
    $pct = [Math]::Round($Info.PercentFree)
    $free = [int][Math]::Round($Blocks * $Info.PercentFree / 100)
    $color = Get-VATeamsSpaceColor $Info
    $out = [System.Collections.Generic.List[object]]::new()
    $out.Add([ordered]@{ type = 'ColumnSet'; spacing = $Spacing; columns = @(
                [ordered]@{ type = 'Column'; width = 'stretch'; items = @(New-VATeamsText "**$name**$(if ($offline) { ' · 🔌 offline' })") }
                [ordered]@{ type = 'Column'; width = 'auto'; items = @(New-VATeamsText "$pct% free · $(Format-VASpaceRatio $Info)" -Color $color -NoWrap) }
            )
        })
    $bar = @()
    if ($free -gt 0) { $bar += New-VATeamsRun ('▰' * $free) -Color $color -Mono }
    if ($free -lt $Blocks) { $bar += New-VATeamsRun ('▱' * ($Blocks - $free)) -Subtle -Mono }
    $out.Add([ordered]@{ type = 'RichTextBlock'; spacing = 'None'; inlines = $bar })
    $tr = Format-VARepositoryTrend $Info
    if ($tr) {
        $d = if ($Info.PSObject.Properties['Trend'] -and $Info.Trend) { $Info.Trend.DaysToFull }
        $tc = if ($null -ne $d -and $d -le 14) { 'Attention' } elseif ($null -ne $d -and $d -le 30) { 'Warning' } else { $null }
        $out.Add((New-VATeamsText $tr -Size Small -Spacing None -Color $tc -Subtle:(-not $tc)))
    }
    return $out.ToArray()
}

function ConvertTo-VATeamsCard {
    <#
    .SYNOPSIS
    Renders a report (see Report.ps1) as an Adaptive Card 1.4: a coloured status band (header, title, status
    line), quotes, a three-column stat grid, then each section. $MaxItems caps rows per section.
    #>
    param([Parameter(Mandatory)]$Report, [int]$MaxItems = 40)
    $r = $Report
    $style = Get-VATeamsStatusStyle $r.status
    $body = [System.Collections.Generic.List[object]]::new()

    $line = "$($r.icon) **$($r.label)**".Trim()
    # A history strip in the summary goes on its own line as coloured squares (see New-VATeamsStrip).
    $isStrip = { param($x) $x -is [System.Collections.IDictionary] -and $x.Contains('history') }
    $strips = @($r.summary | Where-Object { & $isStrip $_ })
    $sum = Format-VATeamsParts @($r.summary | Where-Object { -not (& $isStrip $_) })
    if ($sum) { $line += " · $sum" }
    $band = @(
        New-VATeamsText (Get-VAAuthorLine $r.header $r.server) -Size Small -Weight Bolder -Subtle
        New-VATeamsText $r.title -Size Large -Weight Bolder -Spacing None
        New-VATeamsText $line -Color $style.Text -Spacing Small
    )
    foreach ($s in $strips) { $band += New-VATeamsStrip $s['history'] -Text "$($s['text'])" -Spacing Small }
    if ($r.gauge -and $null -ne $r.gauge.PercentFree) { $band += New-VATeamsRepository $r.gauge }
    $body.Add([ordered]@{ type = 'Container'; style = $style.Container; bleed = $true; items = $band })

    if (@($r.quotes).Count) {
        # Capped like the section rows: a night where every job fails would otherwise go over Teams' size limit.
        $allQuotes = @($r.quotes)
        $q = @(foreach ($x in ($allQuotes | Select-Object -First $MaxItems)) {
            if ($x['title']) {
                $p = Format-VATeamsParts $x['parts']
                New-VATeamsText "$(if ($x['icon']) { "$($x['icon']) " })**$($x['title'])**$(if ($p) { " $p" })" -Spacing Small
                if ($x['text']) { New-VATeamsText "$($x['text'])" -Spacing None -Size $(if ($x['parts']) { 'Small' }) -Subtle:([bool]$x['parts']) }
            }
            else { New-VATeamsText "$(if ($x['icon']) { "$($x['icon']) " })$($x['text'])" -Spacing Small }
        })
        if ($allQuotes.Count -gt $MaxItems) { $q += New-VATeamsText "…and $($allQuotes.Count - $MaxItems) more" -Size Small -Subtle -Spacing Small }
        $body.Add([ordered]@{ type = 'Container'; style = 'emphasis'; items = @($q) })
    }

    $facts = @($r.facts)
    for ($i = 0; $i -lt $facts.Count; $i += 3) {
        $cols = foreach ($f in ($facts | Select-Object -Skip $i -First 3)) {
            [ordered]@{ type = 'Column'; width = 'stretch'; items = @(
                    New-VATeamsText $f['name'] -Size Small -Subtle
                    New-VATeamsText (Format-VATeamsParts @($f['value'])) -Weight Bolder -Spacing None
                )
            }
        }
        $body.Add([ordered]@{ type = 'ColumnSet'; columns = @($cols); spacing = $(if ($i) { 'Small' } else { 'Medium' }) })
    }

    foreach ($sec in @($r.sections)) {
        $title = "$($sec['icon']) $($sec['title'])".Trim()
        $body.Add((New-VATeamsText "**$title**" -Spacing Medium -Weight Bolder))
        switch ($sec['type']) {
            'objects' {
                $rows = @($sec['rows'])
                foreach ($row in ($rows | Select-Object -First $MaxItems)) {
                    $mark = switch -Regex ($row.status) { '^Success' { '✔' } '^Warning' { '▲' } '^Fail' { '✖' } default { '•' } }
                    $body.Add([ordered]@{ type = 'ColumnSet'; spacing = 'None'; columns = @(
                                [ordered]@{ type = 'Column'; width = 'auto'; items = @(New-VATeamsText $mark -Color (Get-VATeamsRowColor $row.status) -Weight Bolder -NoWrap) }
                                [ordered]@{ type = 'Column'; width = 'stretch'; items = @(New-VATeamsText "$($row.name)") }
                                [ordered]@{ type = 'Column'; width = 'auto'; items = @(New-VATeamsText "$($row.size)" -Subtle -NoWrap) }
                                [ordered]@{ type = 'Column'; width = 'auto'; items = @(New-VATeamsText "$($row.duration)" -Subtle -NoWrap) }
                            )
                        })
                    if ($row['message']) { $body.Add((New-VATeamsText "└ $($row['message'])" -Size Small -Subtle -Spacing None)) }
                }
                $more = [int]$sec['more'] + [Math]::Max(0, $rows.Count - $MaxItems)
                if ($more) { $body.Add((New-VATeamsText "…and $more more" -Size Small -Subtle -Spacing None)) }
                if ($sec['repository'] -and $null -ne $sec['repository'].PercentFree) {
                    foreach ($el in (New-VATeamsRepository $sec['repository'] -Spacing Medium)) { $body.Add($el) }
                }
            }
            'repositories' {
                foreach ($repo in @($sec['items'] | Select-Object -First $MaxItems)) {
                    foreach ($el in (New-VATeamsRepository $repo)) { $body.Add($el) }
                }
            }
            'history' {
                $rows = @($sec['rows'])
                foreach ($row in ($rows | Select-Object -First $MaxItems)) {
                    $runs = "$($row['runs']) run$(if ($row['runs'] -ne 1) { 's' })"
                    $body.Add([ordered]@{ type = 'ColumnSet'; spacing = 'None'; columns = @(
                                [ordered]@{ type = 'Column'; width = 'auto'; verticalContentAlignment = 'Center'; items = @(New-VATeamsStrip $row['history']) }
                                [ordered]@{ type = 'Column'; width = 'stretch'; items = @(New-VATeamsText "$($row['name'])$(if ($row['group'] -eq 'agents') { ' (agent)' })") }
                                [ordered]@{ type = 'Column'; width = 'auto'; items = @(New-VATeamsText $runs -Subtle -NoWrap) }
                                [ordered]@{ type = 'Column'; width = 'auto'; items = @(New-VATeamsText "$($row['size'])" -Subtle -NoWrap) }
                            )
                        })
                }
                if ($rows.Count -gt $MaxItems) { $body.Add((New-VATeamsText "…and $($rows.Count - $MaxItems) more" -Size Small -Subtle -Spacing None)) }
                if ($sec['rollup']) {
                    $ru = $sec['rollup']
                    $body.Add([ordered]@{ type = 'ColumnSet'; spacing = 'None'; columns = @(
                                [ordered]@{ type = 'Column'; width = 'auto'; verticalContentAlignment = 'Center'; items = @(New-VATeamsStrip $ru['history']) }
                                [ordered]@{ type = 'Column'; width = 'stretch'; items = @(New-VATeamsText "$($ru['count']) other jobs") }
                                [ordered]@{ type = 'Column'; width = 'auto'; items = @(New-VATeamsText 'all OK' -Color Good -NoWrap) }
                                [ordered]@{ type = 'Column'; width = 'auto'; items = @(New-VATeamsText "$($ru['size'])" -Subtle -NoWrap) }
                            )
                        })
                }
            }
            'text' { foreach ($l in @($sec['lines'])) { $body.Add((New-VATeamsText (Format-VATeamsParts @($l)) -Spacing None)) } }
            default {
                $items = @($sec['items'])
                foreach ($it in ($items | Select-Object -First $MaxItems)) {
                    $t = "$(Get-VAItemIcon $it) **$($it['name'])**"
                    $p = Format-VATeamsParts $it['parts']
                    if ($p) { $t += " · $p" }
                    $body.Add((New-VATeamsText $t -Spacing Small))
                    foreach ($c in @($it['children'])) {
                        $ct = "↳ $(Get-VAItemIcon $c) **$($c['name'])**"
                        if ($c['text'] -and "$($c['status'])" -notmatch '^Success') { $ct += " — $($c['text'])" }
                        $body.Add((New-VATeamsText $ct -Size Small -Spacing None))
                    }
                    if ([int]$it['more'] -gt 0) { $body.Add((New-VATeamsText "↳ …and $($it['more']) more" -Size Small -Subtle -Spacing None)) }
                }
                $more = [int]$sec['more'] + [Math]::Max(0, $items.Count - $MaxItems)
                if ($more) { $body.Add((New-VATeamsText "…and $more more" -Size Small -Subtle -Spacing None)) }
            }
        }
    }

    if ($r.note) { $body.Add((New-VATeamsText $r.note -Size Small -Subtle -Spacing Medium)) }
    $foot = Get-VAFooter
    $ts = ConvertTo-VADate $r.timestamp
    if ($ts) { $foot += " · $(Format-VATeamsTime $ts 'f')" }
    $body.Add((New-VATeamsText $foot -Size Small -Subtle -Spacing Medium))

    [ordered]@{
        '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
        type      = 'AdaptiveCard'
        version   = '1.4'
        msteams   = @{ width = 'Full' }
        body      = $body.ToArray()
    }
}

function New-VATeamsPayload {
    <# The webhook message, shrinking long sections until it fits Teams' size limit. #>
    param([Parameter(Mandatory)]$Report)
    foreach ($max in 40, 20, 10, 5, 2) {
        $msg = [ordered]@{
            type        = 'message'
            attachments = @([ordered]@{ contentType = 'application/vnd.microsoft.card.adaptive'; contentUrl = $null; content = (ConvertTo-VATeamsCard -Report $Report -MaxItems $max) })
        }
        $json = $msg | ConvertTo-Json -Depth 30 -Compress
        if ([System.Text.Encoding]::UTF8.GetByteCount($json) -le $script:VATeamsMaxBytes) { return $json }
    }
    return $json
}

function Send-VATeamsEvent {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$Event, $Context)
    $json = New-VATeamsPayload -Report $Event.report
    if ($Context -and $Context.WhatIf) { Write-Output $json; return }
    Invoke-VAHttpJson -Method POST -Uri $Target.url -Body $json -TimeoutSec ([int](Get-VATargetOption $Target 'timeoutSeconds' 30)) | Out-Null
}

Register-VATargetType -Type teams -Description 'Microsoft Teams channel (Workflows webhook, Adaptive Card)' `
    -Validate {
        param($Target, $Context)
        if ("$($Target.url)" -notmatch '^https://') { 'url must be the https:// webhook URL from the Teams Workflows app.' }
        elseif (Test-VAPlaceholderUrl "$($Target.url)") { 'url is still the example placeholder (replace-me); paste the real webhook URL.' }
    } `
    -Wants { param($Target, $Event) $null -ne $Event.report } `
    -Send { param($Target, $Event, $Context) Send-VATeamsEvent -Target $Target -Event $Event -Context $Context }
