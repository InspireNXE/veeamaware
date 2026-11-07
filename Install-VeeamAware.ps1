#Requires -Version 7.2
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Configures VeeamAware on a Windows VBR v13 server. Safe to re-run.

.DESCRIPTION
install.ps1 (the one-line bootstrap) runs this for you. Run it by hand from the VeeamAware folder to change
settings later. It:
  1. creates config\config.json from config.example.json the first time and walks you through it:
     notification targets (any number of Discord channels, Teams channels and JSON webhooks), health
     alerts (first alert after, repeat every, back up for), the digest schedule and agent job reports.
     A re-run shows a menu of every setting with its current value; each prompt defaults to what is set,
     so Enter keeps it. Watcher interval, data source, updates and the post-job hook are in the menu too.
  2. limits config\, secrets\, state\, logs\ and plugins\ to SYSTEM and Administrators,
  3. stores a VBR REST credential, only with -UseRest (licensed editions; Community Edition reads data
     through the Veeam PowerShell module and needs no credential),
  4. checks it can read VBR and sends a "connected" message to each target,
  5. registers the "VeeamAware Watch" scheduled task (runs as SYSTEM; it also runs the digests).

An existing config\config.json and secrets\ are kept.

.EXAMPLE
.\Install-VeeamAware.ps1                                  # guided: targets, check, scheduled task
.\Install-VeeamAware.ps1 -Target discord=https://discord.com/api/webhooks/..., teams:ops@warning=https://... -NoPrompt
.\Install-VeeamAware.ps1 -UseRest                         # licensed edition: store a REST API account
.\Install-VeeamAware.ps1 -Channel preview                 # receive preview releases from Update-VeeamAware.ps1
#>
[CmdletBinding()]
param(
    [string[]]$Target,        # type[:name][@severity]=url, repeatable (discord | teams | webhook)
    [string]$WebhookUrl,      # same as -Target discord=<url>
    [switch]$NoPrompt,        # never ask; use parameters and the existing config only
    [switch]$UseRest,
    [pscredential]$RestCredential,
    [ValidateSet('', 'stable', 'preview')][string]$Channel = '',
    [switch]$Update,          # non-interactive re-run after an update: no prompts, no test message
    [switch]$SkipTest,
    [switch]$SkipTasks,
    [switch]$RegisterJobs
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Import-Module (Join-Path $root 'src\VeeamAware.psm1') -Force
$configPath = Join-Path $root 'config\config.json'
$version = Get-VAVersion
Write-Host ''
Write-Host "VeeamAware $version" -NoNewline -ForegroundColor White
Write-Host "  $root" -ForegroundColor DarkGray

# 1. Config -------------------------------------------------------------------------------------------------
$new = -not (Test-Path $configPath)
if ($new) {
    Copy-Item (Join-Path $root 'config\config.example.json') $configPath
    Write-VADone "Created $configPath"
}
$json = Get-Content -Raw $configPath | ConvertFrom-Json
$jsonBefore = $json | ConvertTo-Json -Depth 20
$changed = $false
$targetsChanged = $false
$interactive = -not ($NoPrompt -or $Update) -and [Environment]::UserInteractive

# The example's placeholder Discord URL would otherwise count as a (broken) target.
if ((Get-VAProp $json 'discord') -and "$(Get-VAProp $json 'discord.webhookUrl')" -and (Test-VAPlaceholderUrl $json.discord.webhookUrl)) {
    $json.discord.webhookUrl = ''; $changed = $true
}

# Targets from parameters.
# Through "pwsh -File" (the bootstrap) a list arrives as one comma-joined string, so split before each "type=".
$specs = @($Target | Where-Object { $_ } | ForEach-Object { $_ -split '\s*,\s*(?=[a-z]+(?::[\w.-]+)?(?:@[a-z]+)?=)' }) + @(if ($WebhookUrl) { "discord=$WebhookUrl" })
foreach ($s in $specs) {
    $t = ConvertFrom-VATargetSpec $s
    $name = if ($t.Name) { $t.Name } else { Get-VAFreeTargetName $json $t.Type }
    $existing = @(Get-VASetupTargets $json | Where-Object { $_.Name -eq $name -or $_.Url.TrimEnd('/') -eq $t.Url.TrimEnd('/') })
    if ($existing) { Write-VAHint "Target '$($existing[0].Name)' already set up; -Target $($t.Type)=… skipped."; continue }
    $added = Add-VASetupTarget -Json $json -Type $t.Type -Name $name -Url $t.Url -MinSeverity $t.MinSeverity
    Write-VADone "Added $($t.Type) target '$added'."; $changed = $true
}

# Guided setup. A first install walks through the main settings; a re-run shows a menu of everything with the
# current values, and every prompt defaults to what is set now (Enter keeps it). Colours: src\Setup.ps1
# "Installer console style".
$sevShort = @{ info = 'everything'; warning = 'warnings and failures'; critical = 'failures only' }
function Show-Targets {
    $list = @(Get-VASetupTargets $json)
    if (-not $list) { Write-VAHint 'No notification targets yet.'; return $list }
    for ($i = 0; $i -lt $list.Count; $i++) {
        Write-Host ('  {0,3}  ' -f ($i + 1)) -NoNewline -ForegroundColor Cyan
        Write-Host ('{0,-12} ' -f $list[$i].Name) -NoNewline
        Write-Host ('{0,-8} ' -f $list[$i].Type) -NoNewline -ForegroundColor DarkGray
        Write-Host ('{0,-28} ' -f (Limit-VAText (Format-VAMaskedUrl $list[$i].Url) 28)) -NoNewline -ForegroundColor DarkGray
        Write-Host $sevShort[$list[$i].MinSeverity] -ForegroundColor Green
    }
    return $list
}
function Read-Choice([string]$Prompt, [string[]]$Allowed, [string]$Default, [string]$Note) {
    while ($true) {
        $a = Read-VAInput $Prompt.Trim() $Default $Note
        if (-not $a -and $Default) { return $Default }
        if ($Allowed -contains $a.ToLowerInvariant()) { return $a.ToLowerInvariant() }
        Write-VAWarn "Please answer one of: $($Allowed -join ', ')"
    }
}
function Read-YesNo([string]$Prompt, [bool]$Current, [string]$Note) {
    (Read-Choice $Prompt @('y', 'n') $(if ($Current) { 'y' } else { 'n' }) $(if ($Note) { "$Note; y/n" } else { 'y/n' })) -eq 'y'
}
function Read-Number([string]$Prompt, [int]$Current, [int]$Min = 0, [int]$Max = 100000, [string]$Note) {
    while ($true) {
        $a = Read-VAInput $Prompt.Trim() "$Current" $Note
        if (-not $a) { return $Current }
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge $Min -and $n -le $Max) { return $n }
        Write-VAWarn "A whole number from $Min to $Max, please."
    }
}
function Read-Text([string]$Prompt, [string]$Current, [string]$Pattern, [string]$Hint, [string]$Note) {
    while ($true) {
        $a = Read-VAInput $Prompt.Trim() $Current $Note
        if (-not $a) { return $Current }
        if ($a -match $Pattern) { return $a }
        Write-VAWarn $Hint
    }
}
function Read-NewTarget {
    $types = @((Get-VASetupTypes).Keys)
    Write-Host ''
    for ($i = 0; $i -lt $types.Count; $i++) { Write-VAOption ($i + 1) (Get-VASetupTypes)[$types[$i]].Label }
    $type = $types[[int](Read-Choice 'Type' @(1..$types.Count | ForEach-Object { "$_" }) '1') - 1]
    $spec = (Get-VASetupTypes)[$type]
    Write-VAHint $spec.Hint
    while ($true) {
        $url = Read-VAInput 'URL' '' 'blank to cancel'
        if (-not $url) { return }
        $problem = Test-VASetupTarget -Json $json -Type $type -Name (Get-VAFreeTargetName $json $type) -Url $url
        if (-not $problem) { break }
        Write-VAWarn $problem
    }
    $default = Get-VAFreeTargetName $json $type
    while ($true) {
        $name = Read-VAInput 'Name' $default; if (-not $name) { $name = $default }
        $problem = Test-VASetupTarget -Json $json -Type $type -Name $name -Url $url
        if (-not $problem) { break }
        Write-VAWarn $problem
    }
    Write-Host ''
    $sevs = @((Get-VASetupSeverities).Keys)
    for ($i = 0; $i -lt $sevs.Count; $i++) { Write-VAOption ($i + 1) (Get-VASetupSeverities)[$sevs[$i]] }
    $sev = $sevs[[int](Read-Choice 'Send' @('1', '2', '3') '1') - 1]
    $options = @{}
    if ($type -eq 'webhook') {
        foreach ($s in @(@{ Key = 'tokenFile'; Prompt = 'Bearer token'; File = "$name-token.json" }, @{ Key = 'signingSecretFile'; Prompt = 'HMAC signing secret'; File = "$name-hmac.json" })) {
            Write-Host "  $($s.Prompt)" -NoNewline; Write-Host ' (blank for none)' -NoNewline -ForegroundColor DarkGray; Write-Host ': ' -NoNewline
            $secret = Read-Host -AsSecureString
            if ($secret.Length) {
                Save-VASecret -Secret $secret -Path (Resolve-VAPath "secrets\$($s.File)")
                $options[$s.Key] = "secrets\$($s.File)"
            }
        }
    }
    $added = Add-VASetupTarget -Json $json -Type $type -Name $name -Url $url -MinSeverity $sev -Options $options
    Write-VADone "Added '$added'."
    return $added
}

function Edit-Targets {
    Write-VAHeading 'Notification targets'
    Write-VAHint 'Where alerts and digests go: Discord channels, Teams channels, JSON webhooks.'
    while ($true) {
        Write-Host ''
        $list = @(Show-Targets)
        Write-Host ''
        if (-not $list) { $choice = Read-Choice 'Add a target now' @('y', 'n') 'y' 'n = set up later; y/n' }
        else {
            Write-VAOption 'a' 'add another'
            Write-VAOption 'r' 'remove one'
            Write-VAOption 'd' 'done'
            $choice = Read-Choice 'Choice' @('a', 'r', 'd') 'd'
        }
        if ($choice -in 'n', 'd') { return }
        if ($choice -in 'y', 'a') { Read-NewTarget | Out-Null; continue }
        $n = Read-Choice 'Remove which number' @(1..$list.Count | ForEach-Object { "$_" }) ''
        Remove-VASetupTarget -Json $json -Name $list[[int]$n - 1].Name
        Write-VADone "Removed '$($list[[int]$n - 1].Name)'."
    }
}

function Edit-Health {
    Write-VAHeading 'Health alerts'
    Write-VAHint 'Veeam services stopped, jobs that appear stuck, the watcher failing. They pause while Veeam upgrades and during maintenance mode (Set-VeeamAwareMaintenance.ps1).'
    Write-Host ''
    $h = Get-VASetupValue $json 'watch.health'
    $on = Read-YesNo 'Send health alerts' ([bool](Get-VAProp $h 'enabled' $true))
    Set-VASetupValue $json 'watch.health.enabled' $on
    if (-not $on) { return }
    $tm = Get-VAHealthTiming $h 'services'
    $first = Read-Number 'First alert after a service stops' ([int]$tm.FirstAlertAfter) 1 1440 'minutes; hides restarts'
    $repeat = Read-Number 'Repeat while still down, every' ([int]$tm.RepeatEvery) 0 10080 'minutes; 0 = once'
    $back = Read-Number 'Say "running again" once up for' ([int]$tm.BackUpFor) 0 1440 'minutes; 0 = right away'
    Set-VASetupValue $json 'watch.health.firstAlertAfterMinutes' $first
    Set-VASetupValue $json 'watch.health.repeatEveryMinutes' $repeat
    Set-VASetupValue $json 'watch.health.backUpForMinutes' $back
    # Per-check values would quietly override the answers above; the menu sets them for every check.
    foreach ($check in 'services', 'sessions', 'watcher') {
        $o = Get-VAProp $json "watch.health.$check"
        if ($o) { foreach ($k in 'graceMinutes', 'firstAlertAfterMinutes', 'repeatEveryMinutes', 'backUpForMinutes') { if ($o.PSObject.Properties[$k]) { $o.PSObject.Properties.Remove($k) } } }
    }
    $stuck = Read-YesNo 'Alert on jobs that appear stuck' ([bool](Get-VAProp $h 'sessions.enabled' $true)) '3x usual run time, or no progress for 4 h'
    Set-VASetupValue $json 'watch.health.sessions.enabled' $stuck
    $after = Read-Number 'Alert when the watcher fails' ([int](Get-VAProp $h 'watcher.failureAlertAfter' 3)) 0 100 'runs in a row; 0 = never'
    Set-VASetupValue $json 'watch.health.watcher.failureAlertAfter' $after
}

function Edit-Digest {
    $d = Get-VASetupDigest $json
    Write-VAHeading "Digest '$($d.name)'"
    Write-VAHint "Every job's recent runs, what needs attention, storage and security in one message."
    Write-Host ''
    $on = Read-YesNo "Send the '$($d.name)' digest" ([bool](Get-VAProp $d 'enabled' $true))
    $d | Add-Member enabled $on -Force
    if (-not $on) { return }
    if (-not (Get-VAProp $d 'schedule')) { $d | Add-Member schedule ([pscustomobject]@{}) -Force }
    $every = Read-Choice 'How often' @('d', 'w') $(if ("$(Get-VAProp $d 'schedule.every' 'day')" -eq 'week') { 'w' } else { 'd' }) 'd = daily, w = weekly'
    $d.schedule | Add-Member every $(if ($every -eq 'w') { 'week' } else { 'day' }) -Force
    if ($every -eq 'w') {
        $days = @([System.Enum]::GetNames([System.DayOfWeek]))
        $day = Read-Text 'On which day' "$(Get-VAProp $d 'schedule.day' 'Monday')" "^(?i)($($days -join '|'))$" "One of: $($days -join ', ')"
        $d.schedule | Add-Member day ((Get-Culture).TextInfo.ToTitleCase($day.ToLowerInvariant())) -Force
    }
    $at = Read-Text 'At' "$(Get-VAProp $d 'schedule.at' '08:00')" '^([01]\d|2[0-3]):[0-5]\d$' 'Use 24-hour HH:mm, e.g. 08:00' 'HH:mm, server time'
    $d.schedule | Add-Member at $at -Force
}

function Edit-Agents {
    Write-VAHeading 'Agent job reports'
    Write-VAHint 'Veeam Agent jobs back up workstations and servers, often many times a day. How should their results arrive?'
    Write-Host ''
    $modes = @((Get-VAAgentModes).Keys)
    $cur = Get-VASetupAgentMode $json
    for ($i = 0; $i -lt $modes.Count; $i++) { Write-VAOption ($i + 1) (Get-VAAgentModes)[$modes[$i]].Label -Current:($modes[$i] -eq $cur) }
    $default = if ($cur -and $modes -contains $cur) { "$($modes.IndexOf($cur) + 1)" } elseif ($cur) { '' } else { '1' }
    if ($cur -eq 'custom') { Write-VAHint 'Your routing rule for agents is custom; Enter keeps it.' }
    $a = Read-VAInput 'Choice' $default
    if (-not $a) { $a = $default }
    if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $modes.Count) { Set-VASetupAgentMode $json $modes[[int]$a - 1] }
}

function Edit-Watch {
    Write-VAHeading 'Watcher'
    Write-VAHint 'The scheduled task that finds agent sessions, malware, repository and health problems and sends the digests.'
    Write-Host ''
    $n = Read-Number 'Run every' ([int](Get-VASetupValue $json 'watch.intervalMinutes' 5)) 1 60 'minutes'
    Set-VASetupValue $json 'watch.intervalMinutes' $n
}

function Edit-Source {
    Write-VAHeading 'Data source'
    Write-Host ''
    $keys = 'auto', 'powershell', 'rest'
    $cur = "$(Get-VASetupValue $json 'vbr.dataSource' 'auto')"
    Write-VAOption 1 'auto' 'REST when an account is stored, else PowerShell' -Current:($cur -eq 'auto') -Width 10
    Write-VAOption 2 'powershell' 'the Veeam PowerShell module (Community Edition)' -Current:($cur -eq 'powershell') -Width 10
    Write-VAOption 3 'rest' 'the REST API with a stored VBR account (licensed)' -Current:($cur -eq 'rest') -Width 10
    $c = Read-Choice 'Choice' @('1', '2', '3') "$([Math]::Max(0, $keys.IndexOf($cur)) + 1)"
    $src = $keys[[int]$c - 1]
    Set-VASetupValue $json 'vbr.dataSource' $src
    if ($src -ne 'powershell' -and -not (Test-Path (Resolve-VAPath "$(Get-VASetupValue $json 'vbr.credentialFile' 'secrets\vbr-credential.json')"))) {
        if ($src -eq 'rest' -or (Read-YesNo 'Store a VBR account for the REST API now' $false)) { $script:UseRest = $true }
    }
}

function Edit-Updates {
    Write-VAHeading 'Updates'
    Write-VAHint 'Update-VeeamAware.ps1 installs new releases; the digest can mention them.'
    Write-Host ''
    $ch = Read-Choice 'Channel' @('stable', 'preview') "$(Get-VASetupValue $json 'update.channel' 'stable')" 'stable = full releases, preview = pre-releases too'
    Set-VASetupValue $json 'update.channel' $ch
    Set-VASetupValue $json 'update.notify' (Read-YesNo 'Mention new releases in the digest' ([bool](Get-VASetupValue $json 'update.notify' $true)))
}

function Edit-Hooks {
    Write-VAHeading 'Post-job hook'
    Write-VAHint 'Sends a job''s report the moment it ends. Without it the watcher reports finished jobs within a few minutes.'
    $reg = Join-Path $root 'Register-VeeamAwareJob.ps1'
    try {
        & $reg
        Write-Host ''
        Write-VAOption 'a' 'attach the hook to the pending jobs'
        Write-VAOption 'r' 'remove it from every job'
        Write-VAOption 'n' 'leave as is'
        $c = Read-Choice 'Choice' @('a', 'r', 'n') 'n'
        if ($c -eq 'a') { & $reg -Apply }
        elseif ($c -eq 'r') { & $reg -Remove -Apply }
    }
    catch { Write-VAWarn "Could not read the VBR jobs: $($_.Exception.Message)" }
}

if ($interactive) {
    $targetsBefore = (@(Get-VASetupTargets $json) | ForEach-Object { "$($_.Name)=$($_.Url)" }) -join ';'
    if ($new) {
        Edit-Targets; Edit-Health; Edit-Digest; Edit-Agents
        Write-Host ''
        Write-VAHint 'Watcher interval, data source and updates use their defaults. Run .\Install-VeeamAware.ps1 again to change any setting.'
    }
    else {
        $edit = [ordered]@{ targets = { Edit-Targets }; health = { Edit-Health }; digest = { Edit-Digest }; agents = { Edit-Agents }
            watch = { Edit-Watch }; source = { Edit-Source }; updates = { Edit-Updates }; hooks = { Edit-Hooks } }
        while ($true) {
            $summary = Get-VASetupSummary $json
            $keys = @($summary.Keys)
            Write-VAHeading 'Settings'
            Write-Host ''
            Write-VASetupMenu $summary
            Write-Host ''
            $a = Read-VAInput 'Change which' '' 'number, or Enter to save and finish'
            if (-not $a) { break }
            if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $keys.Count) { & $edit[$keys[[int]$a - 1]] }
            else { Write-VAWarn "A number from 1 to $($keys.Count), or Enter." }
        }
    }
    $targetsChanged = $targetsBefore -ne ((@(Get-VASetupTargets $json) | ForEach-Object { "$($_.Name)=$($_.Url)" }) -join ';')
}
if ($Channel) {
    if (-not $json.PSObject.Properties['update']) { $json | Add-Member update ([pscustomobject]@{}) }
    if ("$(Get-VAProp $json 'update.channel' 'stable')" -ne $Channel -or $new) {
        $json.update | Add-Member channel $Channel -Force
        $changed = $true
    }
}
if ($UseRest -and "$(Get-VAProp $json 'vbr.dataSource' 'auto')" -eq 'powershell') {
    $json.vbr.dataSource = 'auto'; $changed = $true
}
Write-VAHeading 'Finishing'
$jsonAfter = $json | ConvertTo-Json -Depth 20
if ($changed -or $jsonAfter -ne $jsonBefore) {
    $jsonAfter | Set-Content $configPath -Encoding utf8NoBOM
    Write-VADone "Saved $configPath"
}
else { Write-VAHint 'Settings unchanged.' }
$config = Get-VAConfig -Path $configPath -AllowNoTargets
foreach ($m in @(Get-VAConfigMigrations)) { Write-VAHint "Config: $m" }

# 2. Folders and permissions --------------------------------------------------------------------------------
foreach ($dir in 'config', 'secrets', 'state', 'logs', 'plugins') {
    $path = Join-Path $root $dir
    if (-not (Test-Path $path)) { New-Item -ItemType Directory $path | Out-Null }
    # SYSTEM + Administrators only: config holds webhook URLs, secrets hold tokens and the REST credential,
    # and plugins run as SYSTEM, so nobody else may add code there.
    & icacls.exe $path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE) { Write-VAWarn "icacls failed on $path (exit $LASTEXITCODE)" }
}

# 3. REST credential (licensed editions only) ---------------------------------------------------------------
$credPath = Resolve-VAPath $config.vbr.credentialFile
if ($UseRest -or $RestCredential) {
    if (-not $RestCredential) {
        Write-VAHint 'VBR account for the REST API. A dedicated account with the "Veeam Backup Viewer" role covers job reports; malware and analyzer events may need more (see docs\configuration.md, "Data sources").'
        $RestCredential = Get-Credential -Message 'VBR REST API account (DOMAIN\user or .\user)'
    }
    Save-VACredential -Credential $RestCredential -Path $credPath
    Write-VADone "Saved the encrypted REST credential to $credPath"
}

# 4. Check ------------------------------------------------------------------------------------------------
if ($interactive -and -not $new -and -not $SkipTest) {
    $SkipTest = -not (Read-YesNo 'Check VBR access and send a test message' $targetsChanged 'to each target')
}
if (-not $SkipTest -and -not $Update) {
    $connArgs = @{ Config = $config }; if ($RestCredential) { $connArgs.Credential = $RestCredential }
    Connect-VASource @connArgs
    try {
        $sourceText = Get-VASourceDescription
        $recent = @(Test-VARestOptional -What 'recent sessions' { Get-VASessions -EndedAfter ([datetimeoffset]::UtcNow.AddDays(-1)) }) | Where-Object { $_ }
    }
    finally { Disconnect-VASource }
    Write-VADone "Reading VBR through $sourceText. $($recent.Count) session(s) in the last 24 hours."
    if (@(Get-VATargets $config).Count) { & (Join-Path $root 'Test-VeeamAwareTarget.ps1') -ConfigPath $configPath -SourceText $sourceText }
    else { Write-VAWarn 'No targets configured yet: run .\Install-VeeamAware.ps1 again and add one, then .\Test-VeeamAwareTarget.ps1.' }
}

# 5. Scheduled task -----------------------------------------------------------------------------------------
if (-not $SkipTasks) {
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -StartWhenAvailable
    $action = New-ScheduledTaskAction -Execute $pwsh -WorkingDirectory $root `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $root 'Invoke-VeeamAwareWatch.ps1')`""
    $minutes = [Math]::Max(1, [int](Get-VAProp $config 'watch.intervalMinutes' 5))
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes $minutes)
    Register-ScheduledTask -TaskName 'VeeamAware Watch' -TaskPath '\VeeamAware\' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Enable-ScheduledTask -TaskPath '\VeeamAware\' -TaskName 'VeeamAware Watch' | Out-Null
    Write-VADone "Scheduled task \VeeamAware\VeeamAware Watch: every $minutes min (also sends the digests)."

    # Pre-release builds had a separate digest task; the watcher runs digests now, so the old task would send them twice.
    if (Get-ScheduledTask -TaskPath '\VeeamAware\' -TaskName 'VeeamAware Digest' -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskPath '\VeeamAware\' -TaskName 'VeeamAware Digest' -Confirm:$false
        Write-VADone 'Removed the old "VeeamAware Digest" task (the watcher sends digests now).'
    }
    # First pass records existing malware events and analyzer results as a baseline instead of posting them.
    Start-ScheduledTask -TaskPath '\VeeamAware\' -TaskName 'VeeamAware Watch' -ErrorAction SilentlyContinue
}

# 6. Jobs ---------------------------------------------------------------------------------------------------
if ($RegisterJobs) { & (Join-Path $root 'Register-VeeamAwareJob.ps1') }
elseif ($interactive -and $new) {
    Write-Host ''
    if (Read-YesNo 'Attach the post-job hook to your jobs now' $true 'reports arrive the moment a job ends; shows the list first') { Edit-Hooks }
    else { Write-VAHint 'Later: .\Install-VeeamAware.ps1 → "Post-job hook", or .\Register-VeeamAwareJob.ps1. The watcher still reports finished jobs within a few minutes.' }
}
elseif (-not $Update -and -not $interactive) {
    Write-VAHeading 'Next'
    Write-VAHint 'Attach the post-job hook so reports arrive the moment a job ends (without it the watcher reports them within a few minutes):'
    Write-Host "    cd $root" -ForegroundColor Cyan
    Write-Host '    .\Register-VeeamAwareJob.ps1          ' -NoNewline -ForegroundColor Cyan; Write-Host '# review' -ForegroundColor DarkGray
    Write-Host '    .\Register-VeeamAwareJob.ps1 -Apply   ' -NoNewline -ForegroundColor Cyan; Write-Host '# attach' -ForegroundColor DarkGray
}
