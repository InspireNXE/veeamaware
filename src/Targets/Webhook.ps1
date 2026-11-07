# Built-in target type "webhook": POSTs every event as JSON (schema veeamaware.event/v1) to any URL.
#
# Target options:
#   url                http(s) endpoint (required)
#   method             POST (default) or PUT
#   headers            extra headers, e.g. { "X-Team": "infra" }
#   tokenFile          DPAPI secret file (Set-VeeamAwareSecret.ps1) sent as "Authorization: Bearer <token>"
#   signingSecretFile  DPAPI secret file used to sign the body (X-VeeamAware-Signature: sha256=<hex HMAC>)
#   timeoutSeconds     default 30
#
# Headers on every request: X-VeeamAware-Event: <kind>, X-VeeamAware-Delivery: <event id>.

function Send-VAWebhookEvent {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$Event, $Context)
    $body = ConvertTo-VAEventJson $Event
    $headers = [ordered]@{ 'X-VeeamAware-Event' = $Event.kind; 'X-VeeamAware-Delivery' = $Event.id }
    $extra = Get-VATargetOption $Target 'headers' $null
    if ($extra) { foreach ($k in $extra.Keys) { $headers[$k] = "$($extra[$k])" } }
    if (Get-VATargetOption $Target 'tokenFile' $null) { $headers.Authorization = "Bearer $(Get-VASecret $Target.tokenFile)" }
    if (Get-VATargetOption $Target 'signingSecretFile' $null) {
        $headers['X-VeeamAware-Signature'] = 'sha256=' + (Get-VAHmacSha256 -Key (Get-VASecret $Target.signingSecretFile) -Data $body)
    }
    if ($Context -and $Context.WhatIf) { Write-Output $body; return }
    Invoke-VAHttpJson -Method (Get-VATargetOption $Target 'method' 'POST') -Uri $Target.url -Headers $headers -Body $body `
        -TimeoutSec ([int](Get-VATargetOption $Target 'timeoutSeconds' 30)) | Out-Null
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
        if ("$(Get-VATargetOption $Target 'method' 'POST')" -notin 'POST', 'PUT') { 'method must be POST or PUT.' }
        foreach ($k in 'tokenFile', 'signingSecretFile') {
            $f = Get-VATargetOption $Target $k $null
            if ($f -and -not (Test-Path -LiteralPath (Resolve-VAPath $f))) { "$k '$f' does not exist (create it with Set-VeeamAwareSecret.ps1)." }
        }
    } `
    -Send { param($Target, $Event, $Context) Send-VAWebhookEvent -Target $Target -Event $Event -Context $Context }
