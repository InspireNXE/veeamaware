# PowerShell data source: reads VBR through the local Veeam.Backup.PowerShell module (v13+, PowerShell 7).
#
# Used when the REST API is not licensed (Community Edition answers every REST data call with 400
# "License restrictions apply.") or when no REST credential is configured. No stored credential is needed:
# the module connects to the local backup server as the Windows account running the script.
#
# Version independence: this file contains NO Veeam property or cmdlet names. They live in versioned profiles
# under src\Profiles\PowerShell\<major>.<minor>.psd1 (see 13.0.psd1 for the format), selected by the installed
# module version. Every function returns objects shaped like the REST 1.3 models, so the rest of VeeamAware
# does not care which data source produced them.

$script:VAPS = $null   # @{ Profile; ProfileFiles; ModuleVersion }

# ---- Profile loading -----------------------------------------------------------------------------------

function Merge-VAProfile {
    param([System.Collections.IDictionary]$Base, [System.Collections.IDictionary]$Override)
    foreach ($k in $Override.Keys) {
        if ($Base.Contains($k) -and $Base[$k] -is [System.Collections.IDictionary] -and $Override[$k] -is [System.Collections.IDictionary]) {
            Merge-VAProfile $Base[$k] $Override[$k] | Out-Null
        }
        else { $Base[$k] = $Override[$k] }
    }
    return $Base
}

function Get-VAPSProfile {
    <#
    .SYNOPSIS
    Builds the effective profile for a module version: every <major>.<minor>.psd1 at or below that version,
    merged in ascending order, then the optional site override file.
    #>
    param([Parameter(Mandatory)][version]$ModuleVersion, [string]$OverridePath,
        [string]$Directory = (Join-Path $PSScriptRoot 'Profiles\PowerShell'))
    $files = @(Get-ChildItem -Path $Directory -Filter '*.psd1' -File | ForEach-Object {
            $v = $null
            if ([version]::TryParse($_.BaseName, [ref]$v)) { [pscustomobject]@{ Version = $v; Path = $_.FullName } }
        } | Sort-Object Version)
    if (-not $files) { throw "No PowerShell data-source profiles found in $Directory." }
    $mv = [version]::new($ModuleVersion.Major, [Math]::Max(0, $ModuleVersion.Minor))
    $chosen = @($files | Where-Object { $_.Version -le $mv })
    if (-not $chosen) {
        Write-VALog "Veeam module $ModuleVersion is older than every profile; using $($files[0].Version) (unsupported)." -Level Warning
        $chosen = @($files[0])
    }
    $profile = @{}
    foreach ($f in $chosen) { Merge-VAProfile $profile (Import-PowerShellDataFile -Path $f.Path) | Out-Null }
    $used = @($chosen | ForEach-Object { Split-Path -Leaf $_.Path })
    if ($OverridePath) {
        $full = Resolve-VAPath $OverridePath
        Merge-VAProfile $profile (Import-PowerShellDataFile -Path $full) | Out-Null
        $used += $full
    }
    if ($files[-1].Version.Major -lt $ModuleVersion.Major) {
        Write-VALog "Veeam module $ModuleVersion is newer than the newest profile ($($files[-1].Version)); values may be missing. Add a $($ModuleVersion.Major).0.psd1 profile." -Level Warning
    }
    return @{ Profile = $profile; Files = $used }
}

function Get-VAPSInfo { $script:VAPS }

# ---- Field resolution ----------------------------------------------------------------------------------

function ConvertFrom-VAPSTime {
    param($Value, [DateTimeKind]$AssumeKind)
    if ($null -eq $Value -or $Value -isnot [datetime] -or $Value.Year -le 1900) { return $null }
    $d = if ($Value.Kind -eq [DateTimeKind]::Unspecified -or $Value.Kind -ne $AssumeKind) { [datetime]::SpecifyKind($Value, $AssumeKind) } else { $Value }
    return ([datetimeoffset]$d.ToUniversalTime()).ToString('o')
}

function ConvertTo-VAPSBytes {
    param($Value)
    if ($null -eq $Value) { return $null }
    $v = if ($Value -is [psobject]) { $Value.PSObject.BaseObject } else { $Value }
    # Veeam's DataSize is a struct (so also a ValueType): read InBytes before trying a numeric cast.
    foreach ($p in 'InBytes', 'Bytes') { $x = Get-VAProp $v $p; if ($null -ne $x -and $x -is [ValueType]) { try { return [double]$x } catch { } } }
    if ($v -is [ValueType] -and $v -isnot [bool] -and $v -isnot [datetime]) { try { return [double]$v } catch { } }
    # Size objects format themselves as "5.36 TB (5896045584384)"; call ToString() on the wrapper so
    # overrides are honoured.
    $text = try { $Value.ToString() } catch { "$v" }
    if ($text -match '\((\d+)\)') { return [double]$Matches[1] }
    if ($text -match '^\d+(\.\d+)?$') { return [double]$text }
    return $null
}

function Get-VAPSField {
    <# Resolves a profile field spec (list of "Path[@converter]") against an object. #>
    param($Object, $Spec, $Default = $null)
    if ($null -eq $Object -or $null -eq $Spec) { return $Default }
    foreach ($candidate in @($Spec)) {
        if (-not $candidate) { continue }
        $path, $conv = "$candidate".Split('@', 2)
        $raw = Get-VAProp $Object $path
        if ($null -eq $raw -or "$raw" -eq '') { continue }
        $val = switch ($conv) {
            'utc' { ConvertFrom-VAPSTime $raw ([DateTimeKind]::Utc) }
            'local' { ConvertFrom-VAPSTime $raw ([DateTimeKind]::Local) }
            'bytes' { ConvertTo-VAPSBytes $raw }
            'timespan' { if ($raw -is [timespan]) { $raw.ToString() } else { "$raw" } }
            'status' { $s = "$raw"; if ($s -cmatch '^E[A-Z]') { $s.Substring(1) } else { $s } }
            'bool' { [bool]$raw }
            default { $raw }
        }
        if ($null -ne $val -and "$val" -ne '') { return $val }
    }
    return $Default
}

function Get-VAPSCmdlet {
    <# Returns the profile's cmdlet name for a role, or throws NotSupported when the profile has none / it is missing. #>
    param([Parameter(Mandatory)][string]$Role)
    $name = "$($script:VAPS.Profile.Cmdlets[$Role])"
    if (-not $name -or -not (Get-Command $name -ErrorAction SilentlyContinue)) {
        $ex = [System.NotSupportedException]::new("'$Role' is not available through the Veeam PowerShell module on this server$(if ($name) { " ($name not found)" }).")
        $ex.Data['NotSupported'] = $true
        throw $ex
    }
    return $name
}

function Invoke-VAPSCmdlet {
    param([Parameter(Mandatory)][string]$Role, [hashtable]$Arguments = @{})
    $name = Get-VAPSCmdlet $Role
    # Some cmdlets (e.g. Get-VBRSecurityComplianceAnalyzerResults) write their results as one array
    # object; unroll so callers always get one pipeline item per Veeam object.
    & $name @Arguments -WarningAction SilentlyContinue | ForEach-Object { $_ }
}

# ---- Connection ----------------------------------------------------------------------------------------

function Connect-VAPowerShell {
    param($Config)
    $mod = Get-Module Veeam.Backup.PowerShell
    if (-not $mod) {
        try { $mod = Import-Module Veeam.Backup.PowerShell -DisableNameChecking -WarningAction SilentlyContinue -ErrorAction Stop -PassThru }
        catch { throw "The Veeam PowerShell module could not be loaded (run VeeamAware on the backup server, in PowerShell 7): $($_.Exception.Message)" }
    }
    $override = if ($Config) { Get-VAProp $Config 'vbr.powershellProfile' '' } else { '' }
    $p = Get-VAPSProfile -ModuleVersion $mod.Version -OverridePath $override
    $script:VAPS = @{ Profile = $p.Profile; Files = $p.Files; ModuleVersion = $mod.Version }
    try { Invoke-VAPSCmdlet LocalServer @{ Type = 'Local'; ErrorAction = 'Stop' } | Out-Null }
    catch {
        try { Connect-VBRServer -ErrorAction Stop }
        catch { throw "Cannot connect to the local Veeam backup server through PowerShell: $($_.Exception.Message)" }
    }
    Write-VALog "Data source: Veeam PowerShell module $($mod.Version), profile $($p.Files -join ' + ')" -Level Debug
}

# ---- Converters to REST-shaped objects -----------------------------------------------------------------

function ConvertTo-VAPSProgress {
    param($Progress)
    if ($null -eq $Progress) { return $null }
    $f = $script:VAPS.Profile.Progress
    $bn = "$(Get-VAPSField $Progress $f.Bottleneck '')"
    if ($script:VAPS.Profile.IgnoredBottlenecks -contains $bn) { $bn = '' }
    [pscustomobject]@{
        processedSize   = Get-VAPSField $Progress $f.Processed
        readSize        = Get-VAPSField $Progress $f.Read
        transferredSize = Get-VAPSField $Progress $f.Transferred
        processingRate  = Get-VAPSField $Progress $f.Rate
        bottleneck      = $bn
        duration        = Get-VAPSField $Progress $f.Duration
        progressPercent = Get-VAPSField $Progress $f.Percent
    }
}

function ConvertTo-VAPSSession {
    param([Parameter(Mandatory)]$Session)
    $p = $script:VAPS.Profile
    $f = $p.Session
    $jobType = "$(Get-VAPSField $Session $f.JobType '')"
    $state = "$(Get-VAPSField $Session $f.State '')"
    $statsObj = Get-VAPSField $Session $f.BackupStats
    $sf = $p.BackupStats
    if ($p.RestorePoint -and @($p.RestorePoint.UseForJobTypes) -contains $jobType -and -not (Get-VAPSField $statsObj $sf.BackupSize) -and $state -eq 'Stopped') {
        $rpStats = Get-VAPSRestorePointStats -Session $Session
        if ($rpStats) { $statsObj = $rpStats }
    }
    [pscustomobject]@{
        id           = "$(Get-VAPSField $Session $f.Id)"
        jobId        = "$(Get-VAPSField $Session $f.JobId)"
        name         = "$(Get-VAPSField $Session $f.Name 'Unknown job')"
        sessionType  = if ($p.JobTypeMap.ContainsKey($jobType)) { $p.JobTypeMap[$jobType] } elseif ($jobType) { $jobType } else { 'Job' }
        state        = $state
        creationTime = Get-VAPSField $Session $f.Start
        endTime      = if ($state -eq 'Stopped') { Get-VAPSField $Session $f.End } else { $null }
        isRetry      = [bool](Get-VAPSField $Session $f.IsRetry $false)
        platform     = "$(Get-VAPSField $Session $f.Platform '')"
        result       = [pscustomobject]@{
            result     = "$(Get-VAPSField $Session $f.Result 'None')"
            message    = "$(Get-VAPSField $Session $f.Message '')".Trim()
            isCanceled = [bool](Get-VAPSField $Session $f.Canceled $false)
        }
        progress     = ConvertTo-VAPSProgress (Get-VAPSField $Session $f.Progress)
        backupStats  = if ($statsObj) {
            [pscustomobject]@{
                backupSize    = Get-VAPSField $statsObj $sf.BackupSize
                dataSize      = Get-VAPSField $statsObj $sf.DataSize
                dedupRatio    = Get-VAPSField $statsObj $sf.DedupRatio
                compressRatio = Get-VAPSField $statsObj $sf.CompressRatio
            }
        } else { $null }
        source       = 'powershell'
    }
}

function Get-VAPSRestorePointStats {
    <#
    Backup-file statistics of the restore point a session created: the newest restore point of the job's
    backup whose creation time falls inside the session window. Backups and restore-point lists are cached
    per process, because the digest asks for every agent session of the day.
    #>
    param([Parameter(Mandatory)]$Session)
    $rp = $script:VAPS.Profile.RestorePoint
    $sf = $script:VAPS.Profile.Session
    if (-not $script:VAPS.Contains('BackupCache')) { $script:VAPS.BackupCache = @{}; $script:VAPS.PointCache = @{} }
    try {
        $jobId = "$(Get-VAPSField $Session $sf.JobId)"
        $start = ConvertTo-VADate (Get-VAPSField $Session $sf.Start)
        $end = ConvertTo-VADate (Get-VAPSField $Session $sf.End)
        if (-not $jobId -or -not $start) { return $null }
        if (-not $script:VAPS.BackupCache.ContainsKey('all')) {
            $script:VAPS.BackupCache.all = @(& (Get-VAPSCmdletName $rp.BackupCmdlet) -WarningAction SilentlyContinue)
        }
        $backup = $script:VAPS.BackupCache.all | Where-Object { "$(Get-VAPSField $_ $rp.BackupJobId)" -eq $jobId } | Select-Object -First 1
        if (-not $backup) { return $null }
        $key = "$($backup.Id)"
        if (-not $script:VAPS.PointCache.ContainsKey($key)) {
            $script:VAPS.PointCache[$key] = @(& (Get-VAPSCmdletName $rp.PointCmdlet) -Backup $backup -WarningAction SilentlyContinue)
        }
        $until = if ($end) { $end.AddMinutes(5) } else { $start.AddDays(1) }
        $point = $script:VAPS.PointCache[$key] | Where-Object {
            $c = ConvertTo-VADate (Get-VAPSField $_ $rp.Created); $c -and $c -ge $start.AddMinutes(-1) -and $c -le $until
        } | Sort-Object { ConvertTo-VADate (Get-VAPSField $_ $rp.Created) } -Descending | Select-Object -First 1
        if (-not $point) { return $null }
        $storage = $point.($rp.StorageMethod)()
        return Get-VAPSField $storage $rp.Stats
    }
    catch {
        Write-VALog "Restore point stats unavailable: $($_.Exception.Message)" -Level Debug
        return $null
    }
}

function Get-VAPSCmdletName {
    param([string]$Name)
    if (-not $Name -or -not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "Cmdlet '$Name' not available." }
    return $Name
}

function Get-VAPSRawSession {
    param([Parameter(Mandatory)][string]$Id)
    # Finished sessions don't change, so keep them for the rest of the process: the digest otherwise looks
    # each agent session up twice (once for the session, once for its task sessions).
    if (-not $script:VAPS.Contains('RawCache')) { $script:VAPS.RawCache = @{} }
    if ($script:VAPS.RawCache.ContainsKey($Id)) { return $script:VAPS.RawCache[$Id] }
    $s = @(Invoke-VAPSCmdlet BackupSessions @{ Id = $Id; ErrorAction = 'SilentlyContinue' }) | Select-Object -First 1
    if ($s -and "$(Get-VAPSField $s $script:VAPS.Profile.Session.State '')" -eq 'Stopped') { $script:VAPS.RawCache[$Id] = $s }
    if (-not $s) {
        $ex = [System.Exception]::new("Session $Id not found through the Veeam PowerShell module.")
        $ex.Data['StatusCode'] = 404
        throw $ex
    }
    return $s
}

# ---- Data-source functions (same contracts as the REST wrappers) ---------------------------------------

function Get-VAPSSession { param([Parameter(Mandatory)][string]$Id) ConvertTo-VAPSSession (Get-VAPSRawSession $Id) }

function Get-VAPSLatestJobSession {
    param([Parameter(Mandatory)][string]$JobId, [switch]$Completed)
    $af = $script:VAPS.Profile.AgentSession
    $sf = $script:VAPS.Profile.Session
    # The thin agent-session list can say "Stopped" while the full session is still open (e.g. a post-job
    # script is running), so "completed" is judged on the full, converted session: walk back up to 5 runs.
    $agents = @(@(try { Invoke-VAPSCmdlet AgentSessions @{ ErrorAction = 'SilentlyContinue' } } catch { }) |
            Where-Object { "$(Get-VAPSField $_ $af.JobId)" -eq $JobId } |
            Sort-Object { Get-VAPSField $_ $af.Created } -Descending | Select-Object -First $(if ($Completed) { 5 } else { 1 }))
    foreach ($a in $agents) {
        $full = Get-VAPSSession "$(Get-VAPSField $a $af.Id)"
        if (-not $Completed -or ($full.state -eq 'Stopped' -and $full.endTime)) { return $full }
        Write-VALog "Skipping unfinished session $($full.id) (state '$($full.state)', no end time yet)" -Level Debug
    }
    if ($agents) { return $null }
    $candidates = @(@(Invoke-VAPSCmdlet BackupSessions) | Where-Object { "$(Get-VAPSField $_ $sf.JobId)" -eq $JobId } |
            Sort-Object { Get-VAPSField $_ $sf.Start } -Descending | Select-Object -First $(if ($Completed) { 5 } else { 1 }))
    foreach ($c in $candidates) {
        $full = ConvertTo-VAPSSession $c
        if (-not $Completed -or ($full.state -eq 'Stopped' -and $full.endTime)) { return $full }
    }
    return $null
}

function Get-VAPSSessions {
    <# Sessions that ended after $EndedAfter (plus running ones), across VM/copy jobs and agent jobs. #>
    param([datetimeoffset]$EndedAfter, [datetimeoffset]$DetailAfter)
    if (-not $EndedAfter) { $EndedAfter = [datetimeoffset]::UtcNow.AddDays(-1) }
    $seen = @{}
    $out = [System.Collections.Generic.List[object]]::new()
    $sf = $script:VAPS.Profile.Session
    foreach ($raw in @(Invoke-VAPSCmdlet BackupSessions)) {
        # Cheap pre-filter on the raw end time before converting the whole object.
        $end = ConvertTo-VADate (Get-VAPSField $raw $sf.End)
        $state = "$(Get-VAPSField $raw $sf.State '')"
        if ($state -eq 'Stopped' -and $end -and $end -lt $EndedAfter) { continue }
        $s = ConvertTo-VAPSSession $raw
        $seen[$s.id] = $true
        $out.Add($s)
    }
    $af = $script:VAPS.Profile.AgentSession
    $agents = @(try { Invoke-VAPSCmdlet AgentSessions @{ ErrorAction = 'SilentlyContinue' } } catch { Write-VALog "Agent sessions unavailable: $($_.Exception.Message)" -Level Debug })
    # Each full agent session costs a Get-VBRBackupSession -Id lookup (~0.5 s). Sessions that finished before
    # $DetailAfter only feed the history strips, which need the result and times, so those are built from the
    # thin agent record, with name and type taken from a full session of the same job. Newest first, so each
    # job's first (full) session is the template for its older ones.
    $template = @{}
    $agents = @($agents | Sort-Object { ConvertTo-VADate (Get-VAPSField $_ $af.Created) } -Descending)
    foreach ($a in $agents) {
        $id = "$(Get-VAPSField $a $af.Id)"
        $end = ConvertTo-VADate (Get-VAPSField $a $af.End)
        if (-not $id -or $seen.ContainsKey($id) -or ($end -and $end -lt $EndedAfter)) { continue }
        $jobId = "$(Get-VAPSField $a $af.JobId)"
        $result = "$(Get-VAPSField $a $af.Result '')"
        $tpl = $template[$jobId]
        if ($DetailAfter -and $end -and $end -lt $DetailAfter -and $tpl -and $result -and $result -ne 'None') {
            $out.Add([pscustomobject]@{
                    id = $id; jobId = $jobId; name = $tpl.name; sessionType = $tpl.sessionType; state = 'Stopped'
                    creationTime = Get-VAPSField $a $af.Created; endTime = Get-VAPSField $a $af.End; isRetry = $false
                    platform = $tpl.platform; result = [pscustomobject]@{ result = $result; message = ''; isCanceled = $false }
                    progress = $null; backupStats = $null; source = 'powershell'; thin = $true
                })
            continue
        }
        try {
            $full = Get-VAPSSession $id
            if ($jobId -and -not $tpl) { $template[$jobId] = $full }
            $out.Add($full)
        }
        catch { Write-VALog "Agent session $id unreadable: $($_.Exception.Message)" -Level Debug }
    }
    return @($out | Sort-Object { $_.creationTime })
}

function Get-VAPSJobHistory {
    param([Parameter(Mandatory)][string]$JobId, [int]$Count = 20)
    $sf = $script:VAPS.Profile.Session
    $af = $script:VAPS.Profile.AgentSession
    $agents = @(@(try { Invoke-VAPSCmdlet AgentSessions @{ ErrorAction = 'SilentlyContinue' } } catch { }) |
            Where-Object { "$(Get-VAPSField $_ $af.JobId)" -eq $JobId -and (Get-VAPSField $_ $af.End) } |
            Sort-Object { ConvertTo-VADate (Get-VAPSField $_ $af.Created) } -Descending | Select-Object -First $Count)
    if ($agents) {
        foreach ($a in $agents) {
            $id = "$(Get-VAPSField $a $af.Id)"
            $result = "$(Get-VAPSField $a $af.Result '')"
            $end = Get-VAPSField $a $af.End
            if (-not $result -or $result -eq 'None') {
                $full = try { Get-VAPSSession $id } catch { $null }
                if (-not $full) { continue }
                $result = "$($full.result.result)"; $end = $full.endTime
            }
            [pscustomobject]@{ id = $id; result = $result; endTime = $end; startTime = Get-VAPSField $a $af.Created; transferredBytes = $null }
        }
        return
    }
    @(Invoke-VAPSCmdlet BackupSessions) |
        Where-Object { "$(Get-VAPSField $_ $sf.JobId)" -eq $JobId -and "$(Get-VAPSField $_ $sf.State '')" -eq 'Stopped' } |
        Sort-Object { ConvertTo-VADate (Get-VAPSField $_ $sf.Start) } -Descending | Select-Object -First $Count |
        ForEach-Object {
            $prog = Get-VAPSField $_ $sf.Progress
            [pscustomobject]@{ id = "$(Get-VAPSField $_ $sf.Id)"; result = "$(Get-VAPSField $_ $sf.Result 'None')"; endTime = Get-VAPSField $_ $sf.End
                startTime = Get-VAPSField $_ $sf.Start; transferredBytes = Get-VAPSField $prog $script:VAPS.Profile.Progress.Transferred }
        }
}

function Get-VAPSJobRepositoryId {
    param([Parameter(Mandatory)][string]$JobId)
    $jf = $script:VAPS.Profile.Job
    foreach ($cmd in @($jf.Cmdlets)) {
        if (-not $cmd -or -not (Get-Command $cmd -ErrorAction SilentlyContinue)) { continue }
        $job = @(& $cmd -WarningAction SilentlyContinue -ErrorAction SilentlyContinue) |
            Where-Object { "$(Get-VAPSField $_ $jf.Id)" -eq $JobId } | Select-Object -First 1
        if (-not $job) { continue }
        $id = "$(Get-VAPSField $job $jf.RepositoryId '')"
        if (-not $id -and $jf.RepositoryMethod) {
            $repo = try { $job.($jf.RepositoryMethod)() } catch { $null }
            $id = "$(Get-VAProp $repo 'Id' '')"
        }
        if ($id -and $id -ne '00000000-0000-0000-0000-000000000000') { return $id }
    }
    return ''
}

function Get-VAPSTaskSessions {
    param([Parameter(Mandatory)][string]$SessionId)
    $s = Get-VAPSRawSession $SessionId
    $f = $script:VAPS.Profile.Task
    foreach ($t in @(Invoke-VAPSCmdlet TaskSessions @{ Session = $s })) {
        $status = "$(Get-VAPSField $t $f.Status 'None')"
        [pscustomobject]@{
            id       = "$(Get-VAPSField $t $f.Id)"
            name     = "$(Get-VAPSField $t $f.Name '(unnamed)')"
            state    = if ($status -in 'InProgress', 'Pending') { 'Working' } else { 'Stopped' }
            result   = [pscustomobject]@{ result = $status; message = "$(Get-VAPSField $t $f.Reason '')".Trim() }
            progress = ConvertTo-VAPSProgress (Get-VAPSField $t $f.Progress)
            platform = "$(Get-VAPSField $t $f.Platform '')"
        }
    }
}

function Get-VAPSSessionLog {
    param([Parameter(Mandatory)][string]$SessionId)
    $p = $script:VAPS.Profile
    $logger = Get-VAPSField (Get-VAPSRawSession $SessionId) $p.Session.Logger
    if (-not $logger) { return }
    $log = try { $logger.($p.Log.Method)() } catch { Write-VALog "Session log unavailable: $($_.Exception.Message)" -Level Debug; $null }
    foreach ($r in @(Get-VAProp $log $p.Log.Records @())) {
        [pscustomobject]@{
            id          = Get-VAPSField $r $p.LogRecord.Id
            status      = "$(Get-VAPSField $r $p.LogRecord.Status '')"
            title       = "$(Get-VAPSField $r $p.LogRecord.Title '')"
            description = "$(Get-VAPSField $r $p.LogRecord.Description '')"
            startTime   = Get-VAPSField $r $p.LogRecord.Start
        }
    }
}

function Get-VAPSRepositoryStates {
    $f = $script:VAPS.Profile.Repository
    $space = {
        param($r)
        $c = try { $r.($f.ContainerMethod)() } catch { $null }
        @{ total = Get-VAPSField $c $f.Total; free = Get-VAPSField $c $f.Free }
    }
    $toState = {
        param($r, $total, $free, $type)
        [pscustomobject]@{
            id         = "$(Get-VAPSField $r $f.Id)"
            name       = "$(Get-VAPSField $r $f.Name '')"
            type       = $type
            capacityGB = if ($total) { [Math]::Round($total / 1GB, 2) } else { 0 }
            freeGB     = if ($null -ne $free) { [Math]::Round($free / 1GB, 2) } else { 0 }
            isOnline   = -not [bool](Get-VAPSField $r $f.Unavailable $false)
        }
    }
    foreach ($r in @(Invoke-VAPSCmdlet Repositories)) {
        $sp = & $space $r
        & $toState $r $sp.total $sp.free "$(Get-VAPSField $r $f.Type '')"
    }
    foreach ($so in @(try { Invoke-VAPSCmdlet Repositories @{ ScaleOut = $true; ErrorAction = 'SilentlyContinue' } } catch { })) {
        $total = 0.0; $free = 0.0
        foreach ($e in @(try { Invoke-VAPSCmdlet RepositoryExtent @{ Repository = $so; ErrorAction = 'SilentlyContinue' } } catch { })) {
            $sp = & $space (Get-VAPSField $e $f.ExtentRepository)
            if ($sp.total) { $total += $sp.total; $free += [double]$sp.free }
        }
        & $toState $so $total $free 'ScaleOut'
    }
}

function Get-VAPSMalwareEvents {
    $f = $script:VAPS.Profile.Malware
    foreach ($e in @(Invoke-VAPSCmdlet MalwareEvents)) {
        [pscustomobject]@{
            id               = "$(Get-VAPSField $e $f.Id)"
            type             = "$(Get-VAPSField $e $f.Type 'Unknown')"
            severity         = "$(Get-VAPSField $e $f.Severity '')"
            state            = "$(Get-VAPSField $e $f.State '')"
            source           = "$(Get-VAPSField $e $f.Source '')"
            details          = "$(Get-VAPSField $e $f.Details '')"
            machine          = [pscustomobject]@{ displayName = "$(Get-VAPSField $e $f.Machine 'Unknown machine')" }
            detectionTimeUtc = Get-VAPSField $e $f.Time
        }
    }
}

function Get-VAPSAnalyzerBestPractices {
    $f = $script:VAPS.Profile.Analyzer
    foreach ($r in @(Invoke-VAPSCmdlet AnalyzerResults)) {
        $type = "$(Get-VAPSField $r $f.Type '')"
        [pscustomobject]@{
            id           = $type   # stable across runs; the result Id may change per run
            bestPractice = Get-VAFriendlyType $type
            status       = "$(Get-VAPSField $r $f.Status '')"
            note         = "$(Get-VAPSField $r $f.Note '')"
        }
    }
}

function Get-VAPSAnalyzerLastRun {
    # No "last run" cmdlet: a run is identified by its result set, so any change counts as a new run.
    $rows = @(Get-VAPSAnalyzerBestPractices)
    if (-not $rows) { return $null }
    $sig = ($rows | Sort-Object id | ForEach-Object { "$($_.id)=$($_.status)" }) -join ';'
    $sha = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($sig))
    [pscustomobject]@{ id = [Convert]::ToHexString($sha).Substring(0, 16); endTime = [datetimeoffset]::UtcNow.ToString('o') }
}

function Get-VAPSAuthorizationEvents { Invoke-VAPSCmdlet AuthorizationEvents }
