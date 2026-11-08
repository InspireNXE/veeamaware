# Logging, formatting and small helpers shared by every VeeamAware script.

$script:VALogFile = $null
$script:VALogLevel = 'Info'
$script:VALevels = @{ Debug = 0; Info = 1; Warning = 2; Error = 3 }

function Get-VAVersion { $script:VAVersion }
function Get-VARoot { $script:VARoot }

function Initialize-VALog {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Level = 'Info',
        [int]$RetentionDays = 14,
        [string]$Directory = (Join-Path $script:VARoot 'logs')
    )
    if (-not (Test-Path $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $script:VALogLevel = if ($script:VALevels.ContainsKey($Level)) { $Level } else { 'Info' }
    $script:VALogFile = Join-Path $Directory ('{0}-{1:yyyyMMdd}.log' -f $Name, (Get-Date))
    if ($RetentionDays -gt 0) {
        $cutoff = (Get-Date).AddDays(-$RetentionDays)
        Get-ChildItem -Path $Directory -Filter '*.log' -File -ErrorAction SilentlyContinue |
            Where-Object LastWriteTime -lt $cutoff |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

function Write-VALog {
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')][string]$Level = 'Info'
    )
    if ($script:VALevels[$Level] -lt $script:VALevels[$script:VALogLevel]) { return }
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff} [{1,-7}] [{2}] {3}' -f (Get-Date), $Level, $PID, $Message
    if ($script:VALogFile) {
        # Several workers can write the same daily file at once; retry briefly on sharing violations.
        for ($i = 0; $i -lt 5; $i++) {
            try { [System.IO.File]::AppendAllText($script:VALogFile, $line + [Environment]::NewLine); break }
            catch [System.IO.IOException] { Start-Sleep -Milliseconds (50 * ($i + 1)) }
        }
    }
    Write-Information $line -InformationAction Continue
}

function Get-VAProp {
    <#
    .SYNOPSIS
    Null-safe property lookup that walks a dotted path ("result.result") on objects or hashtables.
    The REST models differ slightly between 1.3 revisions, so every read goes through this.
    #>
    param([AllowNull()]$Object, [Parameter(Mandatory)][string]$Path, $Default = $null)
    $current = $Object
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $Default }
        if ($current -is [System.Collections.IDictionary]) {
            $current = if ($current.Contains($segment)) { $current[$segment] } else { $null }
        }
        else {
            $p = $current.PSObject.Properties[$segment]
            $current = if ($p) { $p.Value } else { $null }
        }
    }
    if ($null -eq $current) { return $Default }
    return $current
}

function ConvertTo-VADate {
    <# Parses REST timestamps; returns $null for empty/default (0001-01-01) values. #>
    param([AllowNull()]$Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    $dto = [datetimeoffset]::MinValue
    if ($Value -is [datetime]) { $dto = [datetimeoffset]$Value }
    elseif ($Value -is [datetimeoffset]) { $dto = $Value }
    elseif (-not [datetimeoffset]::TryParse("$Value", [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dto)) { return $null }
    if ($dto.Year -le 1900) { return $null }
    return $dto.ToUniversalTime()
}

function ConvertTo-VATimeSpan {
    <# Accepts a TimeSpan, a "d.hh:mm:ss" string, an ISO-8601 duration or a number of seconds. #>
    param([AllowNull()]$Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [timespan]) { return $Value }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return [timespan]::FromSeconds($Value) }
    $ts = [timespan]::Zero
    if ([timespan]::TryParse("$Value", [cultureinfo]::InvariantCulture, [ref]$ts)) { return $ts }
    try { return [System.Xml.XmlConvert]::ToTimeSpan("$Value") } catch { return $null }
}

function Format-VASize {
    param([AllowNull()]$Bytes)
    if ($null -eq $Bytes) { return '—' }
    $b = [double]$Bytes
    if ($b -lt 0) { return '—' }
    $units = 'B', 'KB', 'MB', 'GB', 'TB', 'PB'
    $i = 0
    while ($b -ge 1024 -and $i -lt $units.Count - 1) { $b /= 1024; $i++ }
    $fmt = if ($i -eq 0) { '{0:0} {1}' } elseif ($b -ge 100) { '{0:0} {1}' } else { '{0:0.##} {1}' }
    return ($fmt -f $b, $units[$i]).Replace(',', '.')
}

function Format-VARate {
    param([AllowNull()]$BytesPerSecond)
    if ($null -eq $BytesPerSecond -or [double]$BytesPerSecond -le 0) { return '—' }
    return '{0}/s' -f (Format-VASize $BytesPerSecond)
}

function Format-VADuration {
    param([AllowNull()]$Value)
    $ts = ConvertTo-VATimeSpan $Value
    if ($null -eq $ts) { return '—' }
    if ($ts.TotalSeconds -lt 1) { return '0s' }
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($ts.Days) { $parts.Add("$($ts.Days)d") }
    if ($ts.Hours) { $parts.Add("$($ts.Hours)h") }
    if ($ts.Minutes) { $parts.Add("$($ts.Minutes)m") }
    if ($ts.Seconds -and $ts.TotalHours -lt 1) { $parts.Add("$($ts.Seconds)s") }
    return ($parts -join ' ')
}

function Format-VADiscordTime {
    <# Discord's client-side timestamp markup (<t:unix:style>), rendered in each reader's timezone. #>
    param([AllowNull()]$Date, [ValidateSet('t', 'T', 'd', 'D', 'f', 'F', 'R')][string]$Style = 'f')
    $d = ConvertTo-VADate $Date
    if ($null -eq $d) { return '—' }
    return '<t:{0}:{1}>' -f $d.ToUnixTimeSeconds(), $Style
}

function Limit-VAText {
    param([AllowNull()][string]$Text, [Parameter(Mandatory)][int]$Max)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, [Math]::Max(0, $Max - 1)) + '…'
}

function Protect-VAMarkdown {
    <# Escapes Discord markdown so object names like "web_01*" render literally. #>
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return [regex]::Replace($Text, '([\\`*_~|])', '\$1')
}

function Get-VAStatusInfo {
    param([AllowNull()][string]$Result)
    switch -Regex ($Result) {
        # Colours match the status badges (assets\status-*.png) and Discord's own green/yellow/red.
        '^Success'   { return @{ Name = 'Success'; Emoji = '✅'; Color = 0x23A55A } }
        '^Warning'   { return @{ Name = 'Warning'; Emoji = '⚠️'; Color = 0xF0B232 } }
        '^Fail'      { return @{ Name = 'Failed';  Emoji = '❌'; Color = 0xF23F43 } }
        default      { return @{ Name = if ($Result) { $Result } else { 'Unknown' }; Emoji = '⚪'; Color = 0x80848E } }
    }
}

function Test-VAAgentSession {
    <# True for Veeam Agent backup jobs and agent policies (computer backup). #>
    param([AllowNull()]$Session, [string[]]$ExtraTypes = @())
    $type = "$(Get-VAProp $Session 'sessionType')"
    if ($ExtraTypes -contains $type) { return $true }
    return $type -match 'Agent|EndPoint|Computer'
}

function Get-VAFriendlyType {
    param([AllowNull()][string]$SessionType)
    $map = @{
        BackupJob = 'Backup'; ReplicaJob = 'Replication'; BackupCopyJob = 'Backup Copy'
        AgentBackup = 'Agent Backup'; AgentPolicy = 'Agent Policy'; EndpointBackup = 'Agent Backup'
        FileBackup = 'File Share Backup'; FileBackupCopy = 'File Share Backup Copy'
        ObjectStorageBackup = 'Object Storage Backup'; UnstructuredBackup = 'Unstructured Data Backup'
        BackupToTape = 'Backup to Tape'; FileToTape = 'File to Tape'; SureBackup = 'SureBackup'
        ConfigurationBackup = 'Configuration Backup'; MalwareDetection = 'Malware Scan'
        SecurityComplianceAnalyzer = 'Security & Compliance Analyzer'
    }
    if ($SessionType -and $map.ContainsKey($SessionType)) { return $map[$SessionType] }
    if (-not $SessionType) { return 'Job' }
    # Fall back to splitting PascalCase: "CloudDirectorBackup" -> "Cloud Director Backup".
    return ([regex]::Replace($SessionType, '(?<=[a-z])(?=[A-Z])', ' '))
}

function Get-VAAnalyzerFinding {
    <#
    Plain wording for a Security & Compliance Analyzer check that isn't met. VBR names each check after the
    state it wants ("FirewallEnabled"), so a bare name next to a cross reads backwards; this says what's wrong
    ("Windows Firewall is off"). Matches the PowerShell type name or the REST display name. Unknown checks get
    "Not met: <name>".
    #>
    param($Practice)
    $map = @{
        remotedesktopservicedisabled        = 'Remote Desktop (RDP) is enabled'
        remoteregistrydisabled              = 'Remote Registry service is running'
        winrmservicedisabled                = 'WinRM (Windows Remote Management) is running'
        firewallenabled                     = 'Windows Firewall is off'
        mfaenabledinbackupconsole           = 'MFA is not required for the backup console'
        immutableorofflinemediapresence     = 'No immutable or offline copy of backups'
        lossprotectionenabled               = 'Encryption password loss protection is off'
        containbackupcopies                 = 'No backup copy jobs (second copy of backups)'
        manuallinuxhostauthentication       = 'Linux host fingerprints are trusted automatically'
        viproxytrafficencrypted             = 'VMware host-to-proxy traffic (Network mode) is not encrypted'
        csmbsigningandencryptionenabled     = 'SMB signing and encryption are off'
        webproxyautodiscoverydisabled       = 'Web Proxy Auto-Discovery (WPAD) is enabled'
        windowsscripthostdisabled           = 'Windows Script Host is enabled'
        llmnrdisabled                       = 'LLMNR is enabled'
        passwordsrotation                   = 'Passwords have not been rotated recently'
        credentialspasswordscomplexityrules = 'Stored passwords do not meet complexity rules'
        credentialsguardconfigured          = 'Credential Guard is not configured'
        lsassprotectedprocess               = 'LSASS is not running as a protected process'
        netbiosdisabled                     = 'NetBIOS over TCP/IP is enabled'
    }
    $id = "$(Get-VAProp $Practice 'id' '')"
    $name = "$(Get-VAProp $Practice 'bestPractice' (Get-VAProp $Practice 'name' ''))"
    foreach ($k in $id, $name) {
        $norm = ($k -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
        if ($norm -and $map.ContainsKey($norm)) { return $map[$norm] }
    }
    $raw = if ($name) { $name } elseif ($id) { $id } else { return 'Not met: unnamed check' }
    if ($raw -notmatch '\s') {
        # PascalCase with acronyms: "LLMNRDisabled" -> "LLMNR Disabled", "MfaEnabled" -> "MFA Enabled".
        $raw = [regex]::Replace($raw, '(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])', ' ')
        $raw = [regex]::Replace($raw, '\b(Mfa|Smb|Ssh|Os|Vi|Lsass|Llmnr|Wpad|Tls|Rdp|Sql)\b', { $args[0].Value.ToUpperInvariant() })
    }
    "Not met: $raw"
}

function Invoke-VAWithMutex {
    <# Serialises access to shared state across concurrent worker processes. #>
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock, [string]$Name = 'Global\VeeamAware-State', [int]$TimeoutSeconds = 60)
    $mutex = [System.Threading.Mutex]::new($false, $Name)
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne([timespan]::FromSeconds($TimeoutSeconds)) }
        catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw "Timed out waiting for mutex $Name" }
        & $ScriptBlock
    }
    finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
