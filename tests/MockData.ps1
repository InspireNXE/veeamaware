# Mock REST payloads shaped like VBR 13 REST (1.3-rev2) responses. Field names follow the public reference;
# a few optional fields are deliberately left out to exercise the null-safe readers.

function New-MockSession {
    param([string]$Name = 'Prod VMs', [string]$Type = 'BackupJob', [string]$Result = 'Success', [int]$MinutesAgo = 10, [string]$Message = '')
    [pscustomobject]@{
        id           = [guid]::NewGuid().ToString()
        jobId        = [guid]::NewGuid().ToString()
        name         = $Name
        sessionType  = $Type
        state        = 'Stopped'
        creationTime = [datetimeoffset]::UtcNow.AddMinutes(-$MinutesAgo - 37).ToString('o')
        endTime      = [datetimeoffset]::UtcNow.AddMinutes(-$MinutesAgo).ToString('o')
        result       = [pscustomobject]@{ result = $Result; message = $Message; isCanceled = $false }
        progressPercent = 100
    }
}

function New-MockTask {
    param([string]$Name, [string]$Result = 'Success', [double]$GB = 40, [string]$Message = '')
    [pscustomobject]@{
        id       = [guid]::NewGuid().ToString()
        name     = $Name
        state    = 'Stopped'
        result   = [pscustomobject]@{ result = $Result; message = $Message }
        progress = [pscustomobject]@{
            processedSize   = [long]($GB * 1GB)
            readSize        = [long]($GB * 0.6 * 1GB)
            transferredSize = [long]($GB * 0.21 * 1GB)
            processingRate  = [long](310MB)
            bottleneck      = 'Source'
            duration        = '00:12:41'
        }
    }
}

function New-MockLog {
    @(
        [pscustomobject]@{ id = 1; status = 'Succeeded'; title = 'Job started at 05/11/2026 02:00:04' }
        [pscustomobject]@{ id = 2; status = 'Succeeded'; title = 'Load: Source 82% > Proxy 31% > Network 12% > Target 9%' }
        [pscustomobject]@{ id = 3; status = 'Succeeded'; title = 'Primary bottleneck: Source' }
        [pscustomobject]@{ id = 4; status = 'Warning'; title = 'Changed block tracking cannot be enabled for sql-02: snapshot exists' }
        [pscustomobject]@{ id = 5; status = 'Failed'; title = 'Error: Failed to connect to guest agent on web_01*' }
    )
}

function New-MockRepo {
    param([string]$Name, [double]$CapGB, [double]$FreeGB, [bool]$Online = $true)
    [pscustomobject]@{ id = [guid]::NewGuid().ToString(); name = $Name; type = 'WinLocal'; capacityGB = $CapGB; freeGB = $FreeGB; usedSpaceGB = $CapGB - $FreeGB; isOnline = $Online }
}

function New-MockConfig {
    $c = Get-VADefaultConfig
    $c.discord.webhookUrl = 'https://discord.com/api/webhooks/123456789012345678/abcDEF_ghi-jkl'
    $c.discord.mentions.onFailure = @('<@111111111111111111>', 'not-a-mention')
    return $c
}
