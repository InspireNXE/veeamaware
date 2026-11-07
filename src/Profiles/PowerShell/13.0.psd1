# VeeamAware PowerShell data-source profile: base for Veeam Backup & Replication 13.x.
# Verified on VBR 13.1.0.411 (module 13.1.0.411, PowerShell 7.6.3).
#
# HOW VERSIONING WORKS
#   Profiles are named <major>.<minor>.psd1. At runtime every profile whose version is <= the installed
#   Veeam.Backup.PowerShell module version is merged in ascending order (later files override earlier ones;
#   hashtables merge key by key, arrays replace). To support a new build, add e.g. 13.2.psd1 or 14.0.psd1 with
#   only the keys that changed. A site can also merge a local file via config "vbr.powershellProfile".
#
# FIELD SPECS
#   Each field is a list of candidate property paths, tried in order; the first non-empty value wins.
#   A path can end in a converter:
#     @utc / @local  DateTime known to be UTC / local (normalised to UTC ISO-8601)
#     @bytes         number of bytes (also accepts size objects like "5.36 TB (5896045584384)")
#     @timespan      TimeSpan -> "d.hh:mm:ss"
#     @status        log status enum ("ESucceeded" -> "Succeeded")
#     @bool          boolean
@{
    Cmdlets           = @{
        BackupSessions   = 'Get-VBRBackupSession'            # full CBackupSession objects (VM/copy jobs; -Id also resolves agent sessions)
        AgentSessions    = 'Get-VBRComputerBackupJobSession' # agent job sessions (thin VBRSession objects)
        TaskSessions     = 'Get-VBRTaskSession'              # -Session <CBackupSession>
        Repositories     = 'Get-VBRBackupRepository'         # also called with -ScaleOut
        RepositoryExtent = 'Get-VBRRepositoryExtent'         # -Repository <scale-out repository>
        MalwareEvents    = 'Get-VBRMalwareDetectionEvent'
        AnalyzerResults  = 'Get-VBRSecurityComplianceAnalyzerResults'
        AuthorizationEvents = ''                             # no cmdlet for four-eyes requests in 13.x
        LocalServer      = 'Get-VBRServer'                   # -Type Local, used as a connectivity check
        ProtectionGroups = 'Get-VBRProtectionGroup'
        DiscoveredComputers = 'Get-VBRDiscoveredComputer'    # -ProtectionGroup <group>: agent version and status
    }

    # Veeam JobType -> VeeamAware session type (same vocabulary as the REST API's sessionType).
    JobTypeMap        = @{
        Backup = 'BackupJob'; Replica = 'ReplicaJob'; BackupSync = 'BackupCopyJob'; BackupCopy = 'BackupCopyJob'
        SimpleBackupCopyPolicy = 'BackupCopyJob'; SimpleBackupCopyWorker = 'BackupCopyJob'
        EpAgentBackup = 'AgentBackup'; EpAgentPolicy = 'AgentPolicy'; EpAgentManagement = 'AgentPolicy'
        NasBackup = 'FileBackup'; NasBackupCopy = 'FileBackupCopy'; ObjectStorageBackup = 'ObjectStorageBackup'
        VmTapeBackup = 'BackupToTape'; FileTapeBackup = 'FileToTape'; SureBackup = 'SureBackup'; ConfBackup = 'ConfigurationBackup'
    }

    IgnoredBottlenecks = @('NotDefined', 'None', 'Unknown', '')

    Session           = @{
        Id          = @('Id')
        JobId       = @('JobId')
        Name        = @('JobName', 'Name')
        JobType     = @('JobType')
        State       = @('State')
        Result      = @('Result')
        Message     = @('Description', 'Info.Description')
        IsRetry     = @('IsRetryMode@bool')
        Canceled    = @('IsManuallyStopped@bool')
        Platform    = @('Platform')
        # CreationTimeUTC is NOT UTC on 13.1 (it equals local time); Progress.StartTimeUtc is.
        Start       = @('Progress.StartTimeUtc@utc', 'CreationTime@local')
        End         = @('Progress.StopTimeUtc@utc', 'EndTime@local')
        Progress    = @('Progress')
        BackupStats = @('BackupStats')
        Logger      = @('Logger')
    }

    Progress          = @{
        Processed   = @('ProcessedSize@bytes')
        Read        = @('ReadSize@bytes')
        Transferred = @('TransferedSize@bytes', 'TransferredSize@bytes')   # Veeam's spelling first
        Rate        = @('AvgSpeed@bytes')
        Bottleneck  = @('BottleneckInfo.Bottleneck')
        Duration    = @('Duration@timespan')
        Percent     = @('Percents')
    }

    BackupStats       = @{
        BackupSize    = @('BackupSize@bytes')
        DataSize      = @('DataSize@bytes')
        DedupRatio    = @('DedupRatio')       # percent of original: 78 -> 1.28x
        CompressRatio = @('CompressRatio')    # percent of original: 33 -> 3.0x
    }

    Task              = @{
        Id       = @('Id', 'Info.Id')
        Name     = @('Name', 'Info.ObjectName')
        Status   = @('Status', 'Info.Status')
        Reason   = @('Info.Reason')
        Progress = @('Progress', 'Info.Progress')
        Platform = @('ObjectPlatform', 'Info.ObjectPlatform')
        ObjectId = @('ObjectId', 'Info.ObjectId')   # agent tasks: matches the discovered computer's ObjectId
    }

    # Get-VBRDiscoveredComputer: a computer in a protection group and the state of its Veeam Agent.
    Computer          = @{
        ObjectId       = @('ObjectId')
        Name           = @('Name')
        State          = @('State')            # Online / Offline
        AgentStatus    = @('AgentStatus')      # Installed / UpgradeAvailable / NotInstalled ...
        AgentVersion   = @('AgentVersion')
        RebootRequired = @('RebootRequired@bool')
    }

    Log               = @{
        Method  = 'GetLog'           # $session.Logger.GetLog()
        Records = 'UpdatedRecords'   # .UpdatedRecords
    }

    LogRecord         = @{
        Id          = @('OrdinalId')
        Status      = @('Status@status')
        Title       = @('Title')
        Description = @('Description')
        Start       = @('StartTime@local')
    }

    AgentSession      = @{
        Id      = @('Id')
        JobId   = @('JobId')
        End     = @('EndTime@local')
        Created = @('CreationTime@local')
        Result  = @('Result')                 # not verified; history falls back to the full session when empty
    }

    # Job -> target repository, for the repository line on success reports. Not verified yet; when nothing
    # resolves and the server has a single repository, that one is used.
    Job               = @{
        Cmdlets          = @('Get-VBRJob', 'Get-VBRComputerBackupJob')
        Id               = @('Id')
        RepositoryMethod = 'GetTargetRepository'
        RepositoryId     = @('Info.TargetRepositoryId', 'BackupRepository.Id', 'TargetRepositoryId', 'Repository.Id')
    }

    # Agent sessions record ReadSize/TransferedSize = 0 and an empty BackupStats; the real numbers live on the
    # restore point the session created: (Get-VBRRestorePoint).GetStorage().Stats. Verified on 13.1.0.411.
    RestorePoint      = @{
        BackupCmdlet  = 'Get-VBRBackup'          # backups, matched to the session by JobId
        BackupJobId   = @('JobId')
        PointCmdlet   = 'Get-VBRRestorePoint'    # -Backup <backup>
        Created       = @('CreationTime@local')
        StorageMethod = 'GetStorage'
        Stats         = @('Stats')               # CBackupStats: BackupSize / DataSize / DedupRatio / CompressRatio
        # Only consulted when the session's own BackupStats.BackupSize is 0/missing.
        UseForJobTypes = @('EpAgentBackup', 'EpAgentPolicy', 'EpAgentManagement')
    }

    Repository        = @{
        Id              = @('Id')
        Name            = @('Name')
        Type            = @('Type')
        ContainerMethod = 'GetContainer'
        Total           = @('CachedTotalSpace@bytes')   # on the container object
        Free            = @('CachedFreeSpace@bytes')
        Unavailable     = @('IsUnavailable@bool')
        ExtentRepository = @('Repository')               # extent -> its backing repository
    }

    # Not verified yet (no events existed on the reference server); candidates cover the likely names.
    Malware           = @{
        Id       = @('Id')
        Type     = @('Type', 'EventType')
        Severity = @('Severity')
        State    = @('State', 'Status')
        Source   = @('Source', 'Engine')
        Details  = @('Details', 'Description')
        Machine  = @('Machine.Name', 'Machine.DisplayName', 'MachineName', 'ObjectName', 'Machine')
        Time     = @('DetectionTimeUtc@utc', 'DetectionTime@local', 'CreationTime@local')
    }

    Analyzer          = @{
        Type   = @('Type')
        Status = @('Status')
        Note   = @('Note')
    }
}
