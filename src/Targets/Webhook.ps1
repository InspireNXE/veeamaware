# Built-in target type "webhook": POSTs every event as JSON (schema veeamaware.event/v1) to any URL.
#
# Target options:
#   url                http(s) endpoint (required)
#   method             POST (default) or PUT
#   headers            extra headers, e.g. { "X-Team": "infra" }
#   tokenFile          DPAPI secret file (Set-VeeamAwareSecret.ps1) sent as "Authorization: Bearer <token>"
#   signingSecretFile  DPAPI secret file used to sign each request (see below)
#   timeoutSeconds     default 30
#   allowHttp          true to allow plain http:// with a token or signing secret to a host that doesn't look local
#
# Headers on every request: X-VeeamAware-Event: <kind>, X-VeeamAware-Delivery: <event id>,
# X-VeeamAware-Timestamp: <unix seconds>. With signingSecretFile, X-VeeamAware-Signature: sha256=<hex HMAC-SHA256
# of "<timestamp>.<body>">; signing the timestamp lets a receiver refuse old (replayed) requests.
# A target with a token or signing secret must use https://, except on the local network or with allowHttp.

function Send-VAWebhookEvent {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$Event, $Context)
    $body = ConvertTo-VAEventJson $Event
    $ts = "$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    $headers = [ordered]@{ 'X-VeeamAware-Event' = $Event.kind; 'X-VeeamAware-Delivery' = $Event.id; 'X-VeeamAware-Timestamp' = $ts }
    $extra = Get-VATargetOption $Target 'headers' $null
    if ($extra) { foreach ($k in $extra.Keys) { $headers[$k] = "$($extra[$k])" } }
    if (Get-VATargetOption $Target 'tokenFile' $null) { $headers.Authorization = "Bearer $(Get-VASecret $Target.tokenFile)" }
    if (Get-VATargetOption $Target 'signingSecretFile' $null) {
        $headers['X-VeeamAware-Signature'] = 'sha256=' + (Get-VAHmacSha256 -Key (Get-VASecret $Target.signingSecretFile) -Data "$ts.$body")
    }
    if ($Context -and $Context.WhatIf) { Write-Output $body; return }
    Invoke-VAHttpJson -Method (Get-VATargetOption $Target 'method' 'POST') -Uri $Target.url -Headers $headers -Body $body `
        -TimeoutSec ([int](Get-VATargetOption $Target 'timeoutSeconds' 30)) | Out-Null
}

function Test-VALocalUrl {
    <#
    localhost, a private IPv4 address (10/8, 172.16/12, 192.168/16), a single-label name, a .local name, or an
    IPv6 loopback, unique-local (fc00::/7) or link-local (fe80::/10) address.
    #>
    param([string]$Url)
    if ("$Url" -notmatch '^https?://(?:[^/@?#]*@)?(?:\[(?<v6>[^\]]+)\]|(?<h>[^/:?#]+))') { return $false }
    if ($Matches['v6']) { return ($Matches['v6'].ToLowerInvariant() -match '^(::1$|f[cd][0-9a-f]{0,2}:|fe[89ab][0-9a-f]?:)') }
    $h = $Matches['h'].ToLowerInvariant()
    if ($h -eq 'localhost' -or $h -notmatch '\.' -or $h.EndsWith('.local')) { return $true }
    if ($h -match '^(\d+)\.(\d+)\.\d+\.\d+$') {
        $a = [int]$Matches[1]; $b = [int]$Matches[2]
        return ($a -eq 10 -or $a -eq 127 -or ($a -eq 192 -and $b -eq 168) -or ($a -eq 172 -and $b -ge 16 -and $b -le 31))
    }
    $false
}

function Get-VAHmacSha256 {
    <# Lower-case hex HMAC-SHA256 of a UTF-8 string. #>
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][AllowEmptyString()][string]$Data)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($Key))
    try { [Convert]::ToHexString($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Data))).ToLowerInvariant() }
    finally { $hmac.Dispose() }
}

Register-VATargetType -Type webhook -Description 'Generic JSON webhook (veeamaware.event/v1, optional HMAC signature)' `
    -Validate {
        param($Target, $Context)
        if ("$($Target.url)" -notmatch '^https?://') { 'url must start with http:// or https://.' }
        elseif ("$($Target.url)" -match '^http://' -and ((Get-VATargetOption $Target 'tokenFile' $null) -or (Get-VATargetOption $Target 'signingSecretFile' $null)) -and
            -not (Test-VALocalUrl "$($Target.url)") -and -not [bool](Get-VATargetOption $Target 'allowHttp' $false)) {
            'url must use https:// when tokenFile or signingSecretFile is set (plain http:// is only allowed on the local network; set "allowHttp": true to allow it anyway).'
        }
        if ("$(Get-VATargetOption $Target 'method' 'POST')" -notin 'POST', 'PUT') { 'method must be POST or PUT.' }
        foreach ($k in 'tokenFile', 'signingSecretFile') {
            $f = Get-VATargetOption $Target $k $null
            if ($f -and -not (Test-Path -LiteralPath (Resolve-VAPath $f))) { "$k '$f' does not exist (create it with Set-VeeamAwareSecret.ps1)." }
        }
    } `
    -Send { param($Target, $Event, $Context) Send-VAWebhookEvent -Target $Target -Event $Event -Context $Context }
