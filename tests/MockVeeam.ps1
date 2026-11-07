# Fake Veeam cmdlets/objects for the PowerShell data source, modelled on real output from VBR 13.1.0.411
# (tools\Probe-VeeamPowerShell.ps1). Defined as global functions so the VeeamAware module can call them.

# Veeam.Framework.Numeric.DataSize is a struct (ValueType) with InBytes and a "5.36 TB (5896045584384)" ToString.
if (-not ('MockVeeam.DataSize' -as [type])) {
    Add-Type -TypeDefinition @'
namespace MockVeeam {
    public struct DataSize {
        private readonly long _b;
        public DataSize(long b) { _b = b; }
        public long InBytes { get { return _b; } }
        public double InTerabytes { get { return _b / 1099511627776.0; } }
        public override string ToString() { return string.Format("{0:0.00} TB ({1})", InTerabytes, _b); }
    }
}
'@
}

function New-MockProgress([long]$Processed, [long]$Read, [long]$Transferred, [timespan]$Duration, [datetime]$StartUtc, [string]$Bottleneck = 'Target') {
    [pscustomobject]@{
        ProcessedSize = $Processed; ReadSize = $Read; TransferedSize = $Transferred; AvgSpeed = [long]244419612
        Duration = $Duration; Percents = 100
        StartTimeUtc = [datetime]::SpecifyKind($StartUtc, 'Utc'); StopTimeUtc = [datetime]::SpecifyKind($StartUtc + $Duration, 'Utc')
        BottleneckInfo = [pscustomobject]@{ Bottleneck = $Bottleneck; Source = 32; Proxy = 39; Network = 17; Target = 87 }
    }
}

function New-MockLogger([object[]]$Records) {
    $l = [pscustomobject]@{ Records = $Records }
    $l | Add-Member -MemberType ScriptMethod -Name GetLog -Value { [pscustomobject]@{ UpdatedRecords = $this.Records } }
    $l
}

$startUtc = [datetime]::SpecifyKind([datetime]::UtcNow.Date.AddHours(-16).AddSeconds(12), 'Utc')   # "yesterday 08:00:12 UTC"
$global:MockVmSession = [pscustomobject]@{
    Id = [guid]'00000000-0000-4000-8000-000000000101'; JobId = [guid]'00000000-0000-4000-8000-000000000102'
    JobName = 'SRV-DC01'; Name = 'SRV-DC01'; Result = 'Success'; State = 'Stopped'; JobType = 'Backup'; IsRetryMode = $false; IsManuallyStopped = $false
    Description = ''; Platform = 'EVmware'
    CreationTime = $startUtc.ToLocalTime(); EndTime = ($startUtc + [timespan]'00:25:33.283').ToLocalTime()
    CreationTimeUTC = [datetime]::SpecifyKind($startUtc.ToLocalTime(), 'Unspecified')   # Veeam's mislabelled value
    Progress = New-MockProgress 270582939648 12241076224 3892121072 ([timespan]'00:25:33.2831450') $startUtc
    BackupStats = [pscustomobject]@{ BackupSize = [long]3922419712; DataSize = [long]14874229461; DedupRatio = 78; CompressRatio = 33 }
    Logger = New-MockLogger @(
        [pscustomobject]@{ OrdinalId = 1; Status = 'ESucceeded'; Title = 'Job started'; Description = ''; StartTime = $startUtc.ToLocalTime() }
        [pscustomobject]@{ OrdinalId = 2; Status = 'EWarning'; Title = 'Changed block tracking reset for Hard disk 2'; Description = ''; StartTime = $startUtc.ToLocalTime() }
        [pscustomobject]@{ OrdinalId = 3; Status = 'ESucceeded'; Title = 'Primary bottleneck: Target'; Description = ''; StartTime = $startUtc.ToLocalTime() }
    )
}
$agentStart = $startUtc.AddHours(8)
$global:MockAgentSession = [pscustomobject]@{
    Id = [guid]'00000000-0000-4000-8000-000000000201'; JobId = [guid]'00000000-0000-4000-8000-000000000202'
    JobName = 'WS-ACCT-01'; Name = 'WS-ACCT-01'; Result = 'Success'; State = 'Stopped'; JobType = 'EpAgentBackup'; Platform = 'EEndPoint'
    IsRetryMode = $false; IsManuallyStopped = $false; Description = ''
    CreationTime = $agentStart.ToLocalTime(); EndTime = $agentStart.AddMinutes(6).ToLocalTime()
    Progress = New-MockProgress 2145319161856 0 0 ([timespan]'00:06:17.048') $agentStart 'NotDefined'   # real agent sessions: Read/Transferred = 0
    BackupStats = [pscustomobject]@{ BackupSize = [long]0; DataSize = [long]0; DedupRatio = 0; CompressRatio = 0 }
    Logger = New-MockLogger @()
}
$global:MockAgentThin = [pscustomobject]@{ Id = $MockAgentSession.Id; JobId = $MockAgentSession.JobId; Name = 'WS-ACCT-01'
    CreationTime = $MockAgentSession.CreationTime; EndTime = $MockAgentSession.EndTime; Result = 'Success'; State = 'Stopped' }

function global:Get-VBRBackupSession {
    [CmdletBinding()] param($Id, [switch]$ScaleOut)
    if ($Id) { return @($MockVmSession, $MockAgentSession) | Where-Object { "$($_.Id)" -eq "$Id" } }
    $MockVmSession   # the plain list does not include agent sessions (as on the real server)
}
function global:Get-VBRComputerBackupJobSession { [CmdletBinding()] param() $MockAgentThin }
function global:Get-VBRTaskSession {
    [CmdletBinding()] param($Session)
    $isAgent = "$($Session.JobType)" -eq 'EpAgentBackup'
    [pscustomobject]@{
        Id = [guid]::NewGuid(); Name = $Session.JobName; Status = 'Success'
        Info = [pscustomobject]@{ Reason = ''; ObjectName = $Session.JobName; Status = 'Success' }
        ObjectPlatform = 'EVmware'
        Progress = if ($isAgent) { New-MockProgress 0 0 0 ([timespan]'00:06:00') $agentStart 'NotDefined' }
                   else { New-MockProgress 270582939648 12241076224 3892121072 ([timespan]'00:02:23.95') $startUtc 'NotDefined' }
    }
}
function global:Get-VBRBackupRepository {
    [CmdletBinding()] param([switch]$ScaleOut)
    if ($ScaleOut) { return }
    $r = [pscustomobject]@{ Id = [guid]'00000000-0000-4000-8000-000000000301'; Name = 'nas-01'; Type = 'CifsShare' }
    $r | Add-Member -MemberType ScriptMethod -Name GetContainer -Value {
        [pscustomobject]@{ CachedTotalSpace = [MockVeeam.DataSize]::new(5896045584384); CachedFreeSpace = [MockVeeam.DataSize]::new(3424637059072) }
    }
    $r
}
function global:Get-VBRRepositoryExtent { [CmdletBinding()] param($Repository) }
function global:Get-VBRMalwareDetectionEvent { [CmdletBinding()] param() }
function global:Get-VBRSecurityComplianceAnalyzerResults {
    [CmdletBinding()] param()
    # The real cmdlet writes VBRBestPracticeInfo[] as ONE pipeline object.
    $rows = [object[]]@(
        [pscustomobject]@{ Id = [guid]::NewGuid(); Type = 'MfaEnabledInBackupConsole'; Status = 'Violation'; Note = '' }
        [pscustomobject]@{ Id = [guid]::NewGuid(); Type = 'EmailNotificationsEnabled'; Status = 'Ok'; Note = '' }
    )
    Write-Output -NoEnumerate $rows
}

function global:Get-VBRBackup { [CmdletBinding()] param() [pscustomobject]@{ Id = [guid]'00000000-0000-4000-8000-000000000401'; Name = 'WS-ACCT-01'; JobId = $MockAgentSession.JobId; JobType = 'EpAgentBackup' } }
function global:Get-VBRRestorePoint {
    [CmdletBinding()] param($Backup)
    foreach ($offset in -60, 1) {   # yesterday's point (outside the window) and this session's point
        $p = [pscustomobject]@{ Name = '192.0.2.10'; CreationTime = $MockAgentSession.CreationTime.AddMinutes($offset); Type = 'Increment'; Offset = $offset }
        $p | Add-Member -MemberType ScriptMethod -Name GetStorage -Value {
            $size = if ($this.Offset -eq 1) { [long]1610612736 } else { [long]999 }
            [pscustomobject]@{ Stats = [pscustomobject]@{ BackupSize = $size; DataSize = [long]8589934592; DedupRatio = 90; CompressRatio = 50 } }
        }
        $p
    }
}