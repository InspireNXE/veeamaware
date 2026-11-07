# Target registry and router: delivers events to every configured target that wants them.
#
# Target types are modules that call Register-VATargetType. Built-in ones live in src\Targets\ (discord, teams,
# webhook); add your own by dropping a .ps1 into plugins\targets\ (see docs\writing-a-target.md).
#
# Targets come from config "targets": [...]. Each entry has a "type", a unique "name", its type's options and
# these common filters:
#   minSeverity      info | warning | critical   (default: info; resolutions always pass when includeResolved)
#   kinds            list of event kinds, or ["*"] (default)
#   includeResolved  send "problem cleared" events (default true)
#   includeDeferred  also receive sessions routed to the digest only, as they finish (default false)
#   enabled          default true
# The top-level "discord" block is shorthand for a Discord target named "discord".
# Digests go to the targets listed in each digest's "targets", regardless of minSeverity.

$script:VATargetTypes = [ordered]@{}
$script:VAPluginErrors = [System.Collections.Generic.List[string]]::new()

function Register-VATargetType {
    <#
    .SYNOPSIS
    Registers a target type. Scriptblocks:
      Send      param($Target, $Event, $Context)  deliver; throw on failure. With $Context.WhatIf, write the payload
                                                   to the output instead of sending it.
      Validate  param($Target, $Context)          return one string per problem (optional)
      Wants     param($Target, $Event)            return $false to skip an event the common filters allowed (optional)
      Test      param($Target, $Context)          connectivity check for Test-VeeamAwareTarget.ps1 (optional;
                                                   the default sends a "VeeamAware is connected" test event)
    $Target is the config entry as an ordered hashtable; $Event is a veeamaware.event/v1 hashtable (its .report
    is the neutral layout to render); $Context has Config, WhatIf, Server, Version and Root.
    #>
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]*$')][string]$Type,
        [Parameter(Mandatory)][scriptblock]$Send,
        [scriptblock]$Validate,
        [scriptblock]$Wants,
        [scriptblock]$Test,
        [string]$Description
    )
    $source = $MyInvocation.ScriptName
    if ($script:VATargetTypes.Contains($Type)) { Write-Verbose "Target type '$Type' from $source replaces the one from $($script:VATargetTypes[$Type].Source)" }
    $script:VATargetTypes[$Type] = [pscustomobject]@{
        Type = $Type; Description = $Description; Send = $Send; Validate = $Validate; Wants = $Wants; Test = $Test; Source = $source
    }
}

function Get-VATargetType {
    param([string]$Type)
    if ($Type) { if ($script:VATargetTypes.Contains($Type)) { return $script:VATargetTypes[$Type] } return $null }
    return @($script:VATargetTypes.Values)
}

function Get-VATargetModuleFiles {
    <#
    Target type modules in load order: src\Targets\*.ps1, then plugins\targets\*.ps1 (a plugin may replace a
    built-in type of the same name), then any folders in $env:VEEAMAWARE_PLUGIN_PATH (';'-separated, for
    developing a plugin). VeeamAware.psm1 dot-sources them. Plugins run as the Veeam service account, so keep
    plugins\ writable by administrators only.
    #>
    $dirs = @((Join-Path $PSScriptRoot 'Targets'), (Join-Path $script:VARoot 'plugins\targets'))
    if ($env:VEEAMAWARE_PLUGIN_PATH) { $dirs += @($env:VEEAMAWARE_PLUGIN_PATH -split ';' | Where-Object { $_ }) }
    foreach ($dir in $dirs) {
        if (Test-Path -LiteralPath $dir) { Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File | Sort-Object Name }
    }
}

function Get-VAPluginErrors { $script:VAPluginErrors.ToArray() }

function New-VATargetContext {
    param($Config, [switch]$WhatIf)
    if (-not $Config) { $Config = $script:VAActiveConfig }
    [pscustomobject]@{ Config = $Config; WhatIf = [bool]$WhatIf; Server = $env:COMPUTERNAME; Version = $script:VAVersion; Root = $script:VARoot }
}

function Get-VATargets {
    param([Parameter(Mandatory)]$Config)
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($t in @(Get-VAProp $Config 'targets' @())) {
        if (-not $t) { continue }
        $h = if ($t -is [System.Collections.IDictionary]) { $t } else { ConvertTo-VAHashtable $t }
        if ($h.Contains('enabled') -and -not $h.enabled) { continue }
        $list.Add($h)
    }
    # The top-level "discord" block is the target named "discord", alongside any Discord entries in "targets"
    # (one per channel). It is skipped only when a "targets" entry posts to the same webhook and thread, i.e.
    # it was moved there and the old block left behind, which would otherwise post everything twice.
    $legacy = Get-VAProp $Config 'discord'
    $same = {
        param($t) $t.type -eq 'discord' -and "$(Get-VAProp $t 'webhookUrl')".TrimEnd('/') -eq "$(Get-VAProp $legacy 'webhookUrl')".TrimEnd('/') -and
        "$(Get-VAProp $t 'threadId')" -eq "$(Get-VAProp $legacy 'threadId')"
    }
    if ($legacy -and "$(Get-VAProp $legacy 'webhookUrl')" -match '^https://' -and -not @($list | Where-Object { & $same $_ })) {
        $d = ConvertTo-VAHashtable $legacy
        $d.type = 'discord'; $d.name = 'discord'
        $list.Insert(0, $d)
    }
    return $list.ToArray()   # unrolled so callers can pipe it; wrap in @() when a count is needed
}

function ConvertTo-VAHashtable {
    param($Object)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}; foreach ($k in $Object.Keys) { $h[$k] = ConvertTo-VAHashtable $Object[$k] }; return $h
    }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}; foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = ConvertTo-VAHashtable $p.Value }; return $h
    }
    if ($Object -is [array]) { return , @($Object | ForEach-Object { ConvertTo-VAHashtable $_ }) }
    return $Object
}

function Get-VATargetOption {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)][string]$Name, $Default)
    if ($Target.Contains($Name) -and $null -ne $Target[$Name] -and "$($Target[$Name])" -ne '') { return $Target[$Name] }
    return $Default
}

function Test-VATargetConfig {
    param([Parameter(Mandatory)]$Config)
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $script:VAPluginErrors) { $errors.Add("Target plugin failed to load: $e") }
    $targets = @(Get-VATargets $Config)
    if (-not $targets.Count) { $errors.Add('No notification target configured: set discord.webhookUrl or add an entry to "targets".') }
    $names = @{}
    $ctx = New-VATargetContext -Config $Config
    foreach ($t in $targets) {
        $n = "$($t.name)"
        if (-not $n) { $errors.Add("A target of type '$($t.type)' has no name."); continue }
        if ($names.ContainsKey($n)) {
            $errors.Add("Duplicate target name '$n'.$(if ($n -eq 'discord') { ' The top-level "discord" block is the target named "discord"; give the other Discord target its own name.' })")
        }
        $names[$n] = $true
        if ("$(Get-VATargetOption $t 'minSeverity' 'info')" -notin 'info', 'success', 'warning', 'critical') { $errors.Add("Target '$n': minSeverity must be info, warning or critical.") }
        $type = Get-VATargetType "$($t.type)"
        if (-not $type) {
            $known = (Get-VATargetType | ForEach-Object Type) -join ', '
            $errors.Add("Target '$n': unknown type '$($t.type)' (available: $known)."); continue
        }
        if ($type.Validate) {
            try { foreach ($msg in @(& $type.Validate $t $ctx)) { if ($msg) { $errors.Add("Target '$n': $msg") } } }
            catch { $errors.Add("Target '$n': validation failed: $($_.Exception.Message)") }
        }
    }
    return $errors
}

function Test-VATargetWants {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$Event)
    $kinds = @(Get-VATargetOption $Target 'kinds' @('*'))
    if ($kinds -notcontains '*' -and $kinds -notcontains $Event.kind) { return $false }
    $type = Get-VATargetType "$($Target.type)"
    if (-not $type) { return $false }
    if ($type.Wants -and -not (& $type.Wants $Target $Event)) { return $false }
    if ($Event.kind -in 'digest', 'test') { return $true }   # the digest's own "targets" list already chose this target
    if ($Event.deferred -and -not (Get-VATargetOption $Target 'includeDeferred' $false)) { return $false }
    if ($Event.resolved) { return [bool](Get-VATargetOption $Target 'includeResolved' $true) }
    return (Get-VASeverityRank $Event.severity) -ge (Get-VASeverityRank (Get-VATargetOption $Target 'minSeverity' 'info'))
}

function Send-VATargetEvent {
    <# Delivers one event to one target through its type's Send hook. Returns what the hook wrote (WhatIf payloads). #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$Event, [switch]$WhatIf)
    $type = Get-VATargetType "$($Target.type)"
    if (-not $type) { throw "unknown target type '$($Target.type)'" }
    & $type.Send $Target $Event (New-VATargetContext -Config $Config -WhatIf:$WhatIf)
}

function Send-VAEvent {
    <#
    .SYNOPSIS
    Sends one event to every interested target. A failing target is logged and does not stop the others.
    Returns the number of targets that accepted it; throws only if every interested target failed.
    #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Event, [string[]]$OnlyTargets, [switch]$WhatIf)
    $wanted = @(Get-VATargets $Config | Where-Object {
            (-not $OnlyTargets -or $OnlyTargets -contains $_.name) -and (Test-VATargetWants -Config $Config -Target $_ -Event $Event)
        })
    if (-not $wanted.Count) { Write-VALog "No target wants $($Event.kind) event '$($Event.title)'" -Level Debug; return 0 }
    $ok = 0
    $errors = @()
    foreach ($t in $wanted) {
        try {
            # Collect sender output (WhatIf payloads) so it never leaks into this function's return value.
            $output = @(Send-VATargetEvent -Config $Config -Target $t -Event $Event -WhatIf:$WhatIf)
            $ok++
            if ($WhatIf) {
                Write-Host "----- WhatIf: $($t.type) target '$($t.name)' would receive:"
                $output | ForEach-Object { Write-Host $_ }
            }
            else { Write-VALog "Delivered $($Event.kind) event '$($Event.title)' to $($t.type) target '$($t.name)'" }
        }
        catch {
            $errors += "$($t.name): $($_.Exception.Message)"
            Write-VALog "Target '$($t.name)' failed for '$($Event.title)': $($_.Exception.Message)" -Level Error
        }
    }
    if ($ok -eq 0) { throw ('All targets failed: ' + ($errors -join ' | ')) }
    return $ok
}

function Test-VATarget {
    <# Connectivity check for one target: its type's Test hook, or a "VeeamAware is connected" test event. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Target, [string]$SourceText, [switch]$WhatIf)
    $type = Get-VATargetType "$($Target.type)"
    if (-not $type) { throw "unknown target type '$($Target.type)'" }
    $ctx = New-VATargetContext -Config $Config -WhatIf:$WhatIf
    if ($type.Test) { return (& $type.Test $Target $ctx) }
    $evt = New-VAEvent -Kind test -Severity info -Title 'VeeamAware test' -Text "Test event from VeeamAware on $env:COMPUTERNAME." `
        -Report (New-VATestReport -SourceText $SourceText)
    & $type.Send $Target $evt $ctx
}

# ---- HTTP helper for target types ------------------------------------------------------------------------

function Get-VAUserAgent { "VeeamAware/$script:VAVersion PowerShell/$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)" }

function Invoke-VAHttpJson {
    <# JSON request with retries on 429/5xx/network errors. Returns the parsed response body (or $null). #>
    param([Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Uri, [System.Collections.IDictionary]$Headers = @{},
        [string]$Body, [int]$TimeoutSec = 30, [int]$Attempts = 4)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $params = @{ Method = $Method; Uri = $Uri; Headers = $Headers; TimeoutSec = $TimeoutSec; SkipHttpErrorCheck = $true; UserAgent = Get-VAUserAgent }
        if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
            $params.Body = [System.Text.Encoding]::UTF8.GetBytes($Body); $params.ContentType = 'application/json; charset=utf-8'
        }
        try { $resp = Invoke-WebRequest @params }
        catch {
            if ($attempt -eq $Attempts) { throw "Request to $Uri failed: $($_.Exception.Message)" }
            Start-Sleep -Seconds (2 * $attempt); continue
        }
        $code = [int]$resp.StatusCode
        if ($code -ge 200 -and $code -lt 300) {
            if ([string]::IsNullOrWhiteSpace($resp.Content)) { return $null }
            try { return ($resp.Content | ConvertFrom-Json) } catch { return $resp.Content }
        }
        if (($code -eq 429 -or $code -ge 500) -and $attempt -lt $Attempts) {
            $wait = 2 * $attempt
            $ra = "$($resp.Headers['Retry-After'])"
            if ($ra -match '^\d+$') { $wait = [Math]::Min(60, [int]$ra) }
            Start-Sleep -Seconds $wait; continue
        }
        $ex = [System.Exception]::new("$Method $Uri returned $code`: $(Limit-VAText "$($resp.Content)" 500)")
        $ex.Data['StatusCode'] = $code
        throw $ex
    }
}
