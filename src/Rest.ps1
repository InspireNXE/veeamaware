# Minimal client for the Veeam Backup & Replication v13 REST API (1.3-revN).
# Docs: https://helpcenter.veeam.com/references/vbr/13/rest/1.3-rev2/tag/SectionOverview

$script:VARest = $null

function Connect-VARest {
    param([Parameter(Mandatory)]$Config, [pscredential]$Credential)
    $vbr = $Config.vbr
    if (-not $Credential) { $Credential = Get-VACredential (Resolve-VAPath $vbr.credentialFile) }
    $base = 'https://{0}:{1}' -f $vbr.server, $vbr.port
    $lastError = $null
    foreach ($apiVersion in @($vbr.apiVersions)) {
        try {
            $body = @{
                grant_type = 'password'
                username   = $Credential.UserName
                password   = $Credential.GetNetworkCredential().Password
            }
            $params = @{
                Method               = 'Post'
                Uri                  = "$base/api/oauth2/token"
                Headers              = @{ 'x-api-version' = $apiVersion; Accept = 'application/json' }
                ContentType          = 'application/x-www-form-urlencoded'
                Body                 = $body
                TimeoutSec           = $vbr.timeoutSeconds
                SkipCertificateCheck = [bool]$vbr.skipCertificateCheck
            }
            $token = Invoke-RestMethod @params
            $script:VARest = @{
                Base         = $base
                ApiVersion   = $apiVersion
                AccessToken  = $token.access_token
                RefreshToken = $token.refresh_token
                ExpiresUtc   = [datetime]::UtcNow.AddSeconds([Math]::Max(60, [int]$token.expires_in - 60))
                Config       = $vbr
            }
            Write-VALog "Connected to VBR REST API at $base (x-api-version $apiVersion)" -Level Debug
            return
        }
        catch {
            $lastError = $_
            $status = Get-VAHttpStatus $_
            # 400 typically means this server does not know the requested x-api-version; try the next one.
            if ($status -eq 400) { Write-VALog "API version $apiVersion rejected, trying next" -Level Debug; continue }
            if ($status -eq 401) { throw "VBR REST login failed for '$($Credential.UserName)': check the credential and that the account has a VBR role." }
            throw "Cannot reach VBR REST API at ${base}: $($_.Exception.Message)"
        }
    }
    throw "VBR REST API at $base rejected every configured x-api-version ($(@($vbr.apiVersions) -join ', ')). Last error: $lastError"
}

function Get-VARestApiVersion { if ($script:VARest) { $script:VARest.ApiVersion } }

function Disconnect-VARest {
    if (-not $script:VARest) { return }
    try { Invoke-VARest -Method Post -Path '/api/oauth2/logout' | Out-Null } catch { }
    $script:VARest = $null
}

function Get-VAHttpStatus {
    param($ErrorRecord)
    $resp = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($resp -and $resp.Value -and $resp.Value.PSObject.Properties['StatusCode']) { return [int]$resp.Value.StatusCode }
    return $null
}

function Update-VARestToken {
    $r = $script:VARest
    try {
        $token = Invoke-RestMethod -Method Post -Uri "$($r.Base)/api/oauth2/token" `
            -Headers @{ 'x-api-version' = $r.ApiVersion } -ContentType 'application/x-www-form-urlencoded' `
            -Body @{ grant_type = 'refresh_token'; refresh_token = $r.RefreshToken } `
            -TimeoutSec $r.Config.timeoutSeconds -SkipCertificateCheck:([bool]$r.Config.skipCertificateCheck)
        $r.AccessToken = $token.access_token
        $r.RefreshToken = $token.refresh_token
        $r.ExpiresUtc = [datetime]::UtcNow.AddSeconds([Math]::Max(60, [int]$token.expires_in - 60))
    }
    catch {
        throw "Refreshing the VBR REST token failed: $($_.Exception.Message)"
    }
}

function Invoke-VARest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query,
        [ValidateSet('Get', 'Post', 'Put', 'Delete')][string]$Method = 'Get',
        $Body
    )
    if (-not $script:VARest) { throw 'Not connected to the VBR REST API. Call Connect-VARest first.' }
    if ([datetime]::UtcNow -ge $script:VARest.ExpiresUtc) { Update-VARestToken }
    $uri = $script:VARest.Base + $Path
    if ($Query -and $Query.Count) {
        $pairs = foreach ($k in $Query.Keys) {
            if ($null -eq $Query[$k] -or "$($Query[$k])" -eq '') { continue }
            $v = $Query[$k]
            if ($v -is [datetime] -or $v -is [datetimeoffset]) { $v = ([datetimeoffset]$v).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
            '{0}={1}' -f [uri]::EscapeDataString($k), [uri]::EscapeDataString("$v")
        }
        if ($pairs) { $uri += '?' + ($pairs -join '&') }
    }
    for ($attempt = 1; ; $attempt++) {
        $params = @{
            Method               = $Method
            Uri                  = $uri
            Headers              = @{
                'x-api-version' = $script:VARest.ApiVersion
                Authorization   = "Bearer $($script:VARest.AccessToken)"
                Accept          = 'application/json'
            }
            TimeoutSec           = $script:VARest.Config.timeoutSeconds
            SkipCertificateCheck = [bool]$script:VARest.Config.skipCertificateCheck
        }
        if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress); $params.ContentType = 'application/json' }
        try {
            Write-VALog "REST $Method $Path" -Level Debug
            return Invoke-RestMethod @params
        }
        catch {
            $status = Get-VAHttpStatus $_
            if ($status -eq 401 -and $attempt -eq 1) { Update-VARestToken; continue }
            if (($status -in 429, 500, 502, 503, 504 -or $null -eq $status) -and $attempt -lt 3) {
                Start-Sleep -Seconds (2 * $attempt); continue
            }
            # Veeam puts the useful part (errorCode/message) in the response body; include it.
            $detail = "$($_.ErrorDetails.Message)".Trim()
            if (-not $detail) { $detail = $_.Exception.Message }
            $shownUri = if ($uri.Length -gt $script:VARest.Base.Length) { $uri.Substring($script:VARest.Base.Length) } else { $Path }
            $ex = [System.Exception]::new("REST $Method $shownUri failed ($status): $(Limit-VAText $detail 600)", $_.Exception)
            $ex.Data['StatusCode'] = $status
            throw $ex
        }
    }
}

function Get-VARestList {
    <# Follows skip/limit pagination of list endpoints and returns the flattened "data" items. #>
    param([Parameter(Mandatory)][string]$Path, [hashtable]$Query = @{}, [int]$PageSize = 200, [int]$MaxItems = 5000)
    $skip = 0
    $items = [System.Collections.Generic.List[object]]::new()
    while ($true) {
        $q = @{} + $Query
        $q.skip = $skip
        $q.limit = $PageSize
        $page = Invoke-VARest -Path $Path -Query $q
        # Some endpoints (logs) return "records" instead of "data".
        $data = @(Get-VAProp $page 'data' (Get-VAProp $page 'records' @()))
        foreach ($d in $data) { $items.Add($d) }
        $total = Get-VAProp $page 'pagination.total' (Get-VAProp $page 'totalRecords')
        $skip += $data.Count
        if ($data.Count -lt $PageSize -or $items.Count -ge $MaxItems) { break }
        if ($null -ne $total -and $skip -ge [int]$total) { break }
    }
    return $items.ToArray()   # unrolled so callers can pipe it; wrap in @() when a count is needed
}

function Test-VARestOptional {
    <# Runs a REST call that may be unavailable for this role/build; returns $null and logs instead of failing. #>
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock, [Parameter(Mandatory)][string]$What)
    try { return & $ScriptBlock }
    catch {
        if ($_.Exception.Data['NotSupported']) { Write-VALog "Skipping ${What}: $($_.Exception.Message)" -Level Debug; return $null }
        $status = $_.Exception.Data['StatusCode']
        $hint = switch ($status) {
            403 { ' (the VeeamAware account lacks a role that can read this)' }
            404 { ' (not available on this VBR build)' }
            default { '' }
        }
        Write-VALog "Skipping ${What}: $($_.Exception.Message)$hint" -Level Warning
        return $null
    }
}

# ---- REST implementations of the data-source functions (dispatched from Source.ps1) --------------------

function Get-VARestSession { param([Parameter(Mandatory)][string]$Id) Invoke-VARest -Path "/api/v1/sessions/$Id" }

function Get-VARestLatestJobSession {
    param([Parameter(Mandatory)][string]$JobId, [switch]$Completed)
    $q = @{ jobIdFilter = $JobId; orderColumn = 'CreationTime'; orderAsc = 'false'; limit = 1 }
    if ($Completed) { $q.stateFilter = 'Stopped' }
    $page = Invoke-VARest -Path '/api/v1/sessions' -Query $q
    return @(Get-VAProp $page 'data' @()) | Select-Object -First 1
}

function Get-VARestSessions {
    param([datetimeoffset]$EndedAfter)
    $q = @{ orderColumn = 'CreationTime'; orderAsc = 'true' }
    if ($EndedAfter) { $q.endedAfterFilter = $EndedAfter }
    Get-VARestList -Path '/api/v1/sessions' -Query $q
}

function Get-VARestJobHistory {
    param([Parameter(Mandatory)][string]$JobId, [int]$Count = 20)
    $q = @{ jobIdFilter = $JobId; stateFilter = 'Stopped'; orderColumn = 'CreationTime'; orderAsc = 'false'; limit = $Count }
    foreach ($s in @(Get-VAProp (Invoke-VARest -Path '/api/v1/sessions' -Query $q) 'data' @())) {
        [pscustomobject]@{ id = "$($s.id)"; result = "$(Get-VAProp $s 'result.result' 'None')"; endTime = Get-VAProp $s 'endTime'; startTime = Get-VAProp $s 'creationTime'; transferredBytes = $null }
    }
}

function Get-VARestJobRepositoryId {
    param([Parameter(Mandatory)][string]$JobId)
    $job = Invoke-VARest -Path "/api/v1/jobs/$JobId"
    "$(Get-VAProp $job 'storage.backupRepositoryId' (Get-VAProp $job 'storage.backupRepository.id' ''))"
}

function Get-VARestTaskSessions { param([Parameter(Mandatory)][string]$SessionId) Get-VARestList -Path "/api/v1/sessions/$SessionId/taskSessions" }
function Get-VARestSessionLog { param([Parameter(Mandatory)][string]$SessionId) Get-VARestList -Path "/api/v1/sessions/$SessionId/logs" -PageSize 500 }
function Get-VARestRepositoryStates { Get-VARestList -Path '/api/v1/backupInfrastructure/repositories/states' }
function Get-VARestMalwareEvents { Get-VARestList -Path '/api/v1/malwareDetection/events' -MaxItems 1000 }
function Get-VARestAuthorizationEvents { Get-VARestList -Path '/api/v1/authorization/events' -MaxItems 500 }
function Get-VARestAnalyzerLastRun { Invoke-VARest -Path '/api/v1/securityAnalyzer/lastRun' }
function Get-VARestAnalyzerBestPractices { Get-VARestList -Path '/api/v1/securityAnalyzer/bestPractices' }
