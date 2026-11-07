# Writing a target type

A target type is one PowerShell file that tells VeeamAware how to deliver a notification somewhere: a chat
app, a pager, a ticketing system, a log. The built-in types (`discord`, `teams`, `webhook`) in `src\Targets\`
are written the same way, so they double as examples.

## Where the file goes

| Location | Loaded | Use for |
|---|---|---|
| `src\Targets\*.ps1` | always | types shipped with VeeamAware |
| `plugins\targets\*.ps1` | always, after the built-ins | your own types. A plugin with a built-in's name replaces it. |
| folders in `$env:VEEAMAWARE_PLUGIN_PATH` (`;`-separated) | when set | developing a plugin without copying it each time |

Files load in name order. A file that throws while loading is skipped. The error is reported by
`Test-VeeamAwareTarget.ps1 -ListTypes` and by config validation, so a broken plugin never stops the others.

## The smallest plugin

```powershell
function Send-VAPagerEvent {
    param($Target, $Event, $Context)
    $body = @{ summary = $Event.title; severity = $Event.severity; dedupKey = $Event.fingerprint } | ConvertTo-Json
    if ($Context.WhatIf) { Write-Output $body; return }
    Invoke-VAHttpJson -Method POST -Uri $Target.url -Body $body | Out-Null
}

Register-VATargetType -Type pager -Description 'My paging service' `
    -Validate { param($Target, $Context) if ("$($Target.url)" -notmatch '^https://') { 'url must start with https://.' } } `
    -Send { param($Target, $Event, $Context) Send-VAPagerEvent -Target $Target -Event $Event -Context $Context }
```

The matching config entry:

```json
{ "type": "pager", "name": "on-call", "url": "https://pager.example.com/v1/alerts", "minSeverity": "critical" }
```

A complete, testable example is [examples/textfile-target.ps1](examples/textfile-target.ps1).

## `Register-VATargetType`

| Parameter | Signature | Purpose |
|---|---|---|
| `-Type` | lower-case name | The value of `"type"` in config |
| `-Send` | `param($Target, $Event, $Context)` | **Required.** Deliver the event; throw on failure. When `$Context.WhatIf` is set, write the payload to the output and send nothing. |
| `-Validate` | `param($Target, $Context)` | Return one string per config problem. The target's name is prefixed for you. |
| `-Wants` | `param($Target, $Event)` | Return `$false` to skip an event the common filters let through. Chat types skip events with no `report`. |
| `-Test` | `param($Target, $Context)` | Custom check for `Test-VeeamAwareTarget.ps1`. Without it, the check sends a `test` event through `-Send`. |
| `-Description` | text | Shown by `-ListTypes` |

Common filters (`enabled`, `minSeverity`, `kinds`, `includeResolved`, `includeDeferred`) are applied before
`-Wants`, so your type doesn't handle them. Delivery failures are logged, and one failing target never blocks
the others.

- **`$Target`** is the config entry as an ordered hashtable. Read optional settings with
  `Get-VATargetOption $Target 'name' <default>`.
- **`$Context`** has `Config` (the whole loaded config), `WhatIf`, `Server`, `Version` and `Root`.
- **`$Event`** is a `veeamaware.event/v1` hashtable. See the next section.

Define helpers as functions with a `-VA` in their name (`Send-VAPagerEvent`). The module exports `*-VA*`, so
you can call them from a console while you debug.

## The event

| Key | Contents |
|---|---|
| `kind` | `session`, `malware`, `repository`, `analyzer`, `authorization`, `health`, `digest` or `test` |
| `severity` | `info`, `success`, `warning` or `critical` |
| `title`, `text`, `markdown` | Ready-made summaries for targets that only need a line or a paragraph |
| `fingerprint` | Stable key for "the same problem" (one per job, per repository…). Use it to update or close one incident instead of opening a new one every run. |
| `resolved` | `true` when this event clears an earlier problem with the same fingerprint |
| `details` | Raw figures for the kind: session ID, objects, sizes, repository space… |
| `report` | The neutral layout to render (below). It can be `$null` when there is nothing to show, for example an analyzer run that found nothing new. |
| `mention` | `Failure`, `Warning`, `Success` or `Security`: which mention list a chat target should use |

## The report: render it your way

Every chat-style notification has one `report` (`veeamaware.report/v1`). Discord turns it into embeds, Teams
into an Adaptive Card, and `ConvertTo-VAPlainText` into plain text. Render the parts your medium can show.

```
header    "Backup job"            ->  small caps line; add report.server
title     "Prod VMs"              ->  the subject
status    success | warning | failed | info | security   (colour; color has it as "#RRGGBB")
icon, label, summary              ->  status line: "✅ SUCCESS · 19:00 → 19:04 · 4m 12s"
quotes    [{ icon?, title?, parts?, text }]               ->  what went wrong / needs attention
gauge     one repository (alerts)                         ->  capacity bar
facts     [{ name, value }]                               ->  stat grid
sections  objects | history | repositories | text | list ->  tables and lists
note      small print
timestamp ISO-8601
```

Section shapes:

- **`objects`**: `rows` of `{ status, name, size, duration, message }`, a `more` count of rows left out, and an
  optional `repository`.
- **`list`**: `items` of `{ status, icon?, name, parts, children: [{ status, name, text }], more }`.
- **`history`**: `rows` of `{ status, name, history, runs, size, duration, group }`, where `history` is one result per day (oldest first, `None` = no run) and `group` is `jobs` or `agents`. An optional `rollup` `{ count, history, size }` stands for healthy jobs folded into one row.
- **`repositories`**: `items` of repositories `{ Name, PercentFree, FreeGB, CapacityGB, Online, Trend? }`. `Format-VARepositoryTrend` turns `Trend` into text such as "−0.4%/day · full in ~9 days".
- **`text`**: `lines`, each a part or a list of parts.

Row and item statuses are Veeam results (`Success`, `Warning`, `Failed`, `None`). `Get-VAStatusInfo` and
`Get-VAItemIcon` map them to a name, emoji and colour.

**Parts.** `summary`, item `parts` and fact `value`s are lists of parts. A part is a string,
`{ time, style, prefix? }`, `{ from, to, fromStyle, toStyle }` or `{ history, text? }` (a run-history strip; `Format-VAHistoryStrip` draws it as emoji, ANSI or plain characters). The styles are `t` (time), `f` (date and time)
and `R` (relative). Join parts with `Format-VAParts`, passing your own time formatter:

```powershell
Format-VAParts $report.summary -Time { param($date, $style) $date.ToLocalTime().ToString('g') }
```

Without `-Time`, times print as UTC.

## Helpers you can rely on

| Function | Use |
|---|---|
| `Invoke-VAHttpJson -Method -Uri [-Headers] [-Body] [-TimeoutSec]` | JSON request with retries on 429, 5xx and network errors |
| `Get-VASecret <file>` | Read a DPAPI secret saved with `Set-VeeamAwareSecret.ps1` (tokens, passwords) |
| `Get-VAHmacSha256 -Key -Data` | Sign a body |
| `Write-VALog <text> -Level Info\|Warning\|Error\|Debug` | VeeamAware's log |
| `ConvertTo-VAEventJson`, `ConvertTo-VAPlainText` | Ready-made renderings |
| `Format-VAParts`, `Format-VASize`, `Format-VADuration`, `Format-VASpaceRatio`, `Limit-VAText` | Formatting |
| `Resolve-VAPath` | Make a path relative to the VeeamAware folder absolute |

Put secrets in DPAPI files, never in `config.json`:

```powershell
.\Set-VeeamAwareSecret.ps1 -Path secrets\pager-token.json   # prompts for the value
```

Then reference the file as `"tokenFile": "secrets\\pager-token.json"`.

## Testing

```powershell
$env:VEEAMAWARE_PLUGIN_PATH = 'C:\dev\my-plugin'
.\Test-VeeamAwareTarget.ps1 -ListTypes                     # is it loaded?
.\Test-VeeamAwareTarget.ps1 -Target on-call -WhatIf        # what would it send?
.\Test-VeeamAwareTarget.ps1 -Target on-call                # send the test event
.\Invoke-VeeamAwareSession.ps1 -JobId <guid> -Target on-call -Force -WhatIf   # a real job's report, not sent
```

To render a report without a server, use the mocks the test suite uses:

```powershell
Import-Module .\src\VeeamAware.psm1 -Force; . .\tests\MockData.ps1
$s = Get-VASessionSummary -Session (New-MockSession -Name 'Prod VMs' -Result 'Failed') -TaskSessions @(New-MockTask 'sql-01' 'Failed' 10 'Disk full')
$evt = New-VASessionEvent -Config (New-MockConfig) -Summary $s
Send-VAPagerEvent -Target @{ url = 'https://example.invalid' } -Event $evt -Context ([pscustomobject]@{ WhatIf = $true })
```

## Sketch: Slack

This is untested; contributions are welcome. A Slack incoming webhook takes Block Kit JSON:

```powershell
function ConvertTo-VASlackBlocks {
    param($Report)
    $time = { param($d, $s) "<!date^$($d.ToUnixTimeSeconds())^{time}|$($d.ToString('u'))>" }
    $status = "$($Report.icon) *$($Report.label)* · $(Format-VAParts $Report.summary -Time $time)"
    $blocks = @(
        @{ type = 'context'; elements = @(@{ type = 'mrkdwn'; text = (Get-VAAuthorLine $Report.header $Report.server) }) }
        @{ type = 'header'; text = @{ type = 'plain_text'; text = $Report.title } }
        @{ type = 'section'; text = @{ type = 'mrkdwn'; text = $status } }
    )
    if ($Report.facts) {
        $blocks += @{ type = 'section'; fields = @($Report.facts | Select-Object -First 10 | ForEach-Object {
            @{ type = 'mrkdwn'; text = "*$($_['name'])*`n$(Format-VAParts @($_['value']) -Time $time)" } }) }
    }
    # ...quotes, sections and note in the same way
    @{ text = "$($Report.title): $($Report.label)"; blocks = $blocks }
}
```

Send it with `Invoke-VAHttpJson -Method POST -Uri $Target.url -Body ($payload | ConvertTo-Json -Depth 20)`.
