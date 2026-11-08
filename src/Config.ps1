# Configuration loading (defaults merged with config\config.json) and the encrypted REST credential.

function Get-VADefaultConfig {
    [ordered]@{
        discord       = [ordered]@{
            webhookUrl  = ''
            threadId    = ''           # optional: post into a thread / forum post of the webhook's channel
            username    = 'VeeamAware'
            avatarUrl   = ''
            statusBadges = $true       # upload a small status image as each report's thumbnail
            ansiColors   = $true       # colour the object table (Discord desktop/web; mobile shows it uncoloured)
            mentions   = [ordered]@{   # Discord mention strings, e.g. "<@123456789>" (user) or "<@&987654321>" (role)
                onFailure  = @()
                onWarning  = @()
                onSuccess  = @()
                onSecurity = @()        # malware, analyzer violations, four-eyes requests
            }
        }
        targets       = @()   # extra targets: discord | webhook (see docs\targets.md)
        vbr           = [ordered]@{
            dataSource           = 'auto'      # auto | rest | powershell (Community Edition: powershell)
            powershellProfile    = ''          # optional site override merged over src\Profiles\PowerShell\*.psd1
            server               = 'localhost'
            port                 = 443         # 13.1+ serves REST on 443; use 9419 on 13.0.x
            apiVersions          = @('1.3-rev2', '1.3-rev1', '1.3-rev0')  # tried in order until one is accepted
            skipCertificateCheck = $true       # VBR ships a self-signed certificate; keep server=localhost when true
            credentialFile       = 'secrets\vbr-credential.json'
            timeoutSeconds       = 60
        }
        # What happens to each finished job session. Rules are checked in order; the first whose "match" fits
        # the job decides, per result, one of: immediate | digest | both | off. See docs\configuration.md, "Routing".
        routing       = [ordered]@{
            rules = @(
                [ordered]@{
                    name    = 'Veeam Agents: failures now, the rest in the digest'
                    match   = [ordered]@{ jobTypes = @('AgentBackup', 'AgentPolicy') }
                    success = 'digest'; warning = 'digest'; failure = 'immediate'
                }
                [ordered]@{
                    name    = 'Everything else: report every run'
                    match   = [ordered]@{ jobs = @('*') }
                    success = 'immediate'; warning = 'immediate'; failure = 'immediate'
                }
            )
        }
        # Scheduled summaries. Each digest has its own schedule, job filter, sections and targets.
        digests       = @(
            [ordered]@{
                name          = 'daily'
                enabled       = $true
                schedule      = [ordered]@{ every = 'day'; at = '08:00' }   # every: day | week (then also day = 'Monday')
                targets       = @('*')                                    # target names, or * for all
                jobs          = [ordered]@{ include = @('*'); exclude = @(); jobTypes = @() }
                content       = 'all'          # all = every session; routed = only sessions routed to digest/both
                sections      = @('agents', 'jobs', 'repositories', 'security')
                skipWhenEmpty = $false
            }
        )
        notifications = [ordered]@{
            objectDetail       = 'all'        # all | problems | none
            maxObjects         = 15
            maxLogLines        = 6
            sessionWaitMinutes = 45            # how long the worker waits for the session to finish
        }
        watch         = [ordered]@{
            enabled              = $true
            intervalMinutes      = 5
            missedSessions       = $true      # report sessions no post-job hook reported (agent policies, jobs without the hook)
            malware              = $true
            securityAnalyzer     = $true
            authorizationRequests = $true
            repositories         = [ordered]@{
                enabled               = $true
                warnPercentFree       = 15
                criticalPercentFree   = 5
                notifyRecovery        = $true
                exclude               = @()
            }
            # Something that keeps going wrong and coming back (services, watcher, repositories): after
            # "changes" alerts/recoveries within withinMinutes, one "flapping" card instead of each change, then
            # one "settled" card once it has stayed the same for settleMinutes. See src\Flapping.ps1.
            flapping             = [ordered]@{
                enabled       = $true
                changes       = 4
                withinMinutes = 60
                settleMinutes = 30
            }
            # Server health (src\Health.ps1). Quiet while Veeam is upgrading or maintenance mode is on.
            # Alert timing (see src\Health.ps1); each check can override any of the three.
            health               = [ordered]@{
                enabled                = $true
                firstAlertAfterMinutes = 15      # a service must be down this long before the first alert
                repeatEveryMinutes     = 60      # reminder while a problem lasts (0 = alert once)
                backUpForMinutes       = 5       # a recovery must hold this long before "recovered"
                services = [ordered]@{
                    enabled        = $true
                    include        = @('Veeam*', 'postgresql*', 'MSSQL$VEEAMSQL*')   # name or display name; automatic start only
                    exclude        = @()
                    required       = @('VeeamBackupSvc')   # always checked; "Missing" when not installed
                    notifyRecovery = $true
                }
                sessions = [ordered]@{
                    enabled           = $true
                    minHours          = 2        # never "stuck" before this
                    usualFactor       = 3        # stuck after 3x the job's typical run time...
                    hours             = 12       # ...or after this when the job has no history
                    noProgressMinutes = 240      # or no progress at all for this long (0 = off)
                    excludeTypes      = @('BackupCopyJob', 'FileBackupCopy')   # keep a session open all the time
                    excludeStates     = @('Idle')
                    excludeJobs       = @()
                    jobs              = @()      # fixed limits: [{ "job": "Big*", "hours": 24 }]
                }
                watcher  = [ordered]@{
                    failureAlertAfter = 3        # failed watcher runs in a row before an alert (0 = off)
                    notifyRecovery    = $true
                }
                upgrade  = [ordered]@{
                    enabled             = $true
                    quietMinutes        = 30     # stay quiet this long after an upgrade ends / VBR's version changes
                    maxHours            = 6      # an "installer" seen longer than this no longer pauses alerts
                    notifyVersionChange = $true
                    processNames        = @('*Veeam*Setup*', '*Veeam*Upgrade*')
                }
            }
        }
        logging       = [ordered]@{
            level         = 'Info'
            retentionDays = 14
        }
        # Updates come from GitHub releases. stable = full releases only; preview = pre-releases too.
        update        = [ordered]@{
            channel    = 'stable'
            notify     = $true        # the digest mentions a newer release on the channel
            repository = ''           # owner/repo; empty = the project's own repository
        }
    }
}

function Merge-VAConfig {
    param($Base, $Override)
    if ($null -eq $Override) { return $Base }
    foreach ($prop in $Override.PSObject.Properties) {
        if ($prop.Name -like '_*') { continue }  # "_comment" keys in the example file
        $existing = if ($Base.Contains($prop.Name)) { $Base[$prop.Name] } else { $null }
        if ($existing -is [System.Collections.IDictionary] -and $prop.Value -is [System.Management.Automation.PSCustomObject]) {
            $Base[$prop.Name] = Merge-VAConfig $existing $prop.Value
        }
        else {
            $Base[$prop.Name] = $prop.Value
        }
    }
    return $Base
}

function Get-VAConfig {
    # -AllowNoTargets: the installer loads the config before any target is set up ("set up later").
    param([string]$Path = (Join-Path $script:VARoot 'config\config.json'), [switch]$AllowNoTargets)
    $config = Get-VADefaultConfig
    if (Test-Path $Path) {
        $json = Get-Content -Raw -Path $Path | ConvertFrom-Json
        $script:VAConfigMigrations = Convert-VALegacyConfig $json   # pre-release settings -> routing/digests (in memory)
        $config = Merge-VAConfig $config $json
    }
    elseif ($Path) {
        throw "Config file not found: $Path. Run Install-VeeamAware.ps1 or copy config\config.example.json."
    }
    $errors = @(Test-VAConfig $config | Where-Object { -not ($AllowNoTargets -and $_ -like 'No notification target configured*') })
    if ($errors) { throw ("Invalid configuration:`n - " + ($errors -join "`n - ")) }
    $script:VAActiveConfig = $config   # display settings (badges, ANSI) for embed builders that take no -Config
    return $config
}

function Get-VAConfigMigrations {
    <# What the last Get-VAConfig translated from older config layouts (in memory; the file is unchanged). #>
    if (Get-Variable -Name VAConfigMigrations -Scope Script -ErrorAction SilentlyContinue) { @($script:VAConfigMigrations | Where-Object { $_ }) }
}

function Test-VAConfig {
    param([Parameter(Mandatory)]$Config)
    $errors = [System.Collections.Generic.List[string]]::new()
    if ($Config.discord.webhookUrl -and "$($Config.discord.webhookUrl)" -notmatch '^https://') {
        $errors.Add('discord.webhookUrl must be a Discord webhook URL (https://discord.com/api/webhooks/<id>/<token>), or empty.')
    }
    foreach ($e in (Test-VATargetConfig $Config)) { $errors.Add($e) }
    if ($Config.notifications.objectDetail -notin 'all', 'problems', 'none') { $errors.Add('notifications.objectDetail must be all, problems or none.') }
    if ("$($Config.vbr.dataSource)" -notin 'auto', 'rest', 'powershell') { $errors.Add('vbr.dataSource must be auto, rest or powershell.') }
    foreach ($e in (Test-VARoutingConfig $Config)) { $errors.Add($e) }
    $r = $Config.watch.repositories
    if ([double]$r.criticalPercentFree -gt [double]$r.warnPercentFree) { $errors.Add('watch.repositories.criticalPercentFree must not exceed warnPercentFree.') }
    if ($Config.vbr.skipCertificateCheck -and $Config.vbr.server -notin 'localhost', '127.0.0.1', '::1', $env:COMPUTERNAME) {
        $errors.Add('vbr.skipCertificateCheck is only allowed when vbr.server is the local machine.')
    }
    return $errors
}

function Resolve-VAPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $script:VARoot $Path)
}

# The REST credential is encrypted with DPAPI (LocalMachine scope) because the post-job script runs as the
# Veeam Backup Service account (Local System by default) while the installer runs as an administrator.
# The installer restricts the secrets folder ACL to SYSTEM and Administrators.
$script:VAEntropy = [System.Text.Encoding]::UTF8.GetBytes('VeeamAware/vbr-credential/v1')

function Save-VASecret {
    <# Stores a single secret string (webhook token, API key, signing secret) with the same DPAPI protection. #>
    param([Parameter(Mandatory)][securestring]$Secret, [Parameter(Mandatory)][string]$Path, [string]$Label = 'secret')
    Save-VACredential -Credential ([pscredential]::new($Label, $Secret)) -Path $Path
}

function Get-VASecret {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-VACredential (Resolve-VAPath $Path)).GetNetworkCredential().Password
}

function Save-VACredential {
    param([Parameter(Mandatory)][pscredential]$Credential, [Parameter(Mandatory)][string]$Path)
    $plain = [System.Text.Encoding]::UTF8.GetBytes($Credential.GetNetworkCredential().Password)
    try {
        $cipher = [System.Security.Cryptography.ProtectedData]::Protect($plain, $script:VAEntropy, 'LocalMachine')
    }
    finally { [Array]::Clear($plain, 0, $plain.Length) }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [ordered]@{ username = $Credential.UserName; password = [Convert]::ToBase64String($cipher); scope = 'LocalMachine' } |
        ConvertTo-Json | Set-Content -Path $Path -Encoding utf8NoBOM
}

function Get-VACredential {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "REST credential file not found: $Path. Run Install-VeeamAware.ps1 -UseRest to store one (licensed editions only)." }
    $data = Get-Content -Raw $Path | ConvertFrom-Json
    $plain = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($data.password), $script:VAEntropy, 'LocalMachine')
    try {
        $secure = [System.Text.Encoding]::UTF8.GetString($plain) | ConvertTo-SecureString -AsPlainText -Force
    }
    finally { [Array]::Clear($plain, 0, $plain.Length) }
    return [pscredential]::new($data.username, $secure)
}
