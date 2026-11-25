#Requires -Version 7.2
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Stores a target secret encrypted with DPAPI (machine scope) under secrets\.

.EXAMPLE
.\Set-VeeamAwareSecret.ps1 -Path secrets\n8n-token.json      # bearer token  -> webhook target "tokenFile"
.\Set-VeeamAwareSecret.ps1 -Path secrets\n8n-hmac.json       # HMAC secret   -> webhook target "signingSecretFile"
#>
param(
    [Parameter(Mandatory)][string]$Path,
    [switch]$Credential
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\VeeamAware.psm1') -Force
$full = Resolve-VAPath $Path
if ($Credential) {
    Save-VACredential -Credential (Get-Credential -Message 'Account VeeamAware signs in with') -Path $full
}
else {
    Save-VASecret -Secret (Read-Host -AsSecureString 'Secret value') -Path $full
}
Write-Host "Saved $full. Reference it from the webhook target as tokenFile / signingSecretFile: `"$($Path -replace '\\', '\\')`""
