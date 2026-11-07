# Example target plugin: appends a plain-text copy of every report to a file.
#
# Install: copy this file to plugins\targets\ and add a target to config\config.json:
#   { "type": "textfile", "name": "audit-log", "path": "logs\\notifications.txt", "minSeverity": "warning" }
# Check it: .\Test-VeeamAwareTarget.ps1 -Target audit-log
#
# See docs\writing-a-target.md for the hooks and the report layout.

function Send-VATextFileEvent {
    param($Target, $Event, $Context)
    $text = "===== $($Event.occurredAt) [$($Event.severity)] $($Event.kind)`n"
    $text += if ($Event.report) { ConvertTo-VAPlainText -Report $Event.report } else { $Event.text }
    if ($Context.WhatIf) { Write-Output $text; return }
    $path = Resolve-VAPath $Target.path
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Add-Content -LiteralPath $path -Value $text -Encoding utf8
}

Register-VATargetType -Type textfile -Description 'Appends a plain-text copy of each report to a file (example plugin)' `
    -Validate {
        param($Target, $Context)
        if (-not "$($Target['path'])") { 'path is required (absolute, or relative to the VeeamAware folder).' }
    } `
    -Send { param($Target, $Event, $Context) Send-VATextFileEvent -Target $Target -Event $Event -Context $Context }
