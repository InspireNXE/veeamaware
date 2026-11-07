# Data-source selection and dispatch.
#
#   vbr.dataSource = "auto"        REST if a credential file exists and the REST API serves data (licensed
#                                   editions); otherwise the Veeam PowerShell module. (default)
#                  = "rest"        always REST (needs vbr.credentialFile; not available on Community Edition)
#                  = "powershell"  always the local Veeam PowerShell module (no stored credential)
#
# Callers only use the source-neutral functions below; adding another source means adding one more branch
# per function, without touching the worker, watcher, digest or targets.

$script:VASource = $null

function Get-VASourceName { $script:VASource }

function Connect-VASource {
    param([Parameter(Mandatory)]$Config, [pscredential]$Credential)
    $mode = "$(Get-VAProp $Config 'vbr.dataSource' 'auto')".ToLowerInvariant()
    $credFile = Resolve-VAPath (Get-VAProp $Config 'vbr.credentialFile' 'secrets\vbr-credential.json')
    switch ($mode) {
        'powershell' { Connect-VAPowerShell -Config $Config; $script:VASource = 'powershell'; return }
        'rest' { Connect-VARest -Config $Config -Credential $Credential; $script:VASource = 'rest'; return }
    }
    if ($Credential -or (Test-Path $credFile)) {
        try {
            Connect-VARest -Config $Config -Credential $Credential
            # Signing in works on every edition; data calls are what licensing blocks, so probe one.
            Invoke-VARest -Path '/api/v1/sessions' -Query @{ limit = 1 } | Out-Null
            $script:VASource = 'rest'
            return
        }
        catch {
            Write-VALog "REST API not usable ($($_.Exception.Message)); falling back to the Veeam PowerShell module." -Level Info
            Disconnect-VARest
        }
    }
    Connect-VAPowerShell -Config $Config
    $script:VASource = 'powershell'
}

function Disconnect-VASource {
    if ($script:VASource -eq 'rest') { Disconnect-VARest }
    $script:VASource = $null
}

function Invoke-VASource {
    param([Parameter(Mandatory)][string]$Name, [hashtable]$Arguments = @{})
    if (-not $script:VASource) { throw 'No data source connected. Call Connect-VASource first.' }
    $impl = if ($script:VASource -eq 'powershell') { "Get-VAPS$Name" } else { "Get-VARest$Name" }
    & $impl @Arguments
}

function Get-VASession { param([Parameter(Mandatory)][string]$Id) Invoke-VASource Session @{ Id = $Id } }
function Get-VALatestJobSession {
    param([Parameter(Mandatory)][string]$JobId, [switch]$Completed)
    Invoke-VASource LatestJobSession @{ JobId = $JobId; Completed = $Completed }
}
function Get-VASessions {
    <# $DetailAfter: sessions that ended earlier may come back without progress/backup stats (history-only use). #>
    param([datetimeoffset]$EndedAfter, [datetimeoffset]$DetailAfter)
    $a = @{ EndedAfter = $EndedAfter }
    if ($DetailAfter -and $script:VASource -eq 'powershell') { $a.DetailAfter = $DetailAfter }
    Invoke-VASource Sessions $a
}
function Get-VATaskSessions { param([Parameter(Mandatory)][string]$SessionId) Invoke-VASource TaskSessions @{ SessionId = $SessionId } }
function Get-VASessionLog { param([Parameter(Mandatory)][string]$SessionId) Invoke-VASource SessionLog @{ SessionId = $SessionId } }
function Get-VAJobHistory {
    <# The job's most recent finished sessions, newest first: { id, result, startTime, endTime, transferredBytes (null when unknown) }. #>
    param([Parameter(Mandatory)][string]$JobId, [int]$Count = 20)
    Invoke-VASource JobHistory @{ JobId = $JobId; Count = $Count }
}
function Get-VAJobRepositoryId { param([Parameter(Mandatory)][string]$JobId) Invoke-VASource JobRepositoryId @{ JobId = $JobId } }
function Get-VARepositoryStates { Invoke-VASource RepositoryStates }
function Get-VAMalwareEvents { Invoke-VASource MalwareEvents }
function Get-VAAuthorizationEvents { Invoke-VASource AuthorizationEvents }
function Get-VAAnalyzerLastRun { Invoke-VASource AnalyzerLastRun }
function Get-VAAnalyzerBestPractices { Invoke-VASource AnalyzerBestPractices }

function Get-VASourceDescription {
    switch ($script:VASource) {
        'rest' { "VBR REST API $(Get-VARestApiVersion)" }
        'powershell' { $i = Get-VAPSInfo; "Veeam PowerShell module $($i.ModuleVersion) (profile $($i.Files -join ' + '))" }
        default { 'not connected' }
    }
}
