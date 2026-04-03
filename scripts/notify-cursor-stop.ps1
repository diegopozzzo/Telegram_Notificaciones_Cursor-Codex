[CmdletBinding()]
param(
    [switch]$Test,
    [string]$TestMessage,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptRoot '..')).Path
$configPath = Join-Path $repoRoot 'config\telegram.settings.json'
$logDirectory = Join-Path $repoRoot 'logs'
$logPath = Join-Path $logDirectory 'cursor-telegram-hook.log'
$cursorChatsPath = Join-Path $logDirectory 'cursor-chats.json'
$cursorTargetsPath = Join-Path $logDirectory 'cursor-notification-targets.json'

function Write-Log {
    param([string]$Message)

    if (-not (Test-Path $logDirectory)) {
        New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logPath -Value "[$timestamp] $Message" -Encoding UTF8
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    return $property.Value
}

function Get-BooleanValue {
    param(
        [object]$Object,
        [string]$Name,
        [bool]$Default
    )

    $value = Get-PropertyValue -Object $Object -Name $Name -Default $Default
    if ($value -is [bool]) {
        return $value
    }

    if ($value -is [string]) {
        switch ($value.Trim().ToLowerInvariant()) {
            'true' { return $true }
            'false' { return $false }
        }
    }

    return $Default
}

function Normalize-WorkspaceRoot {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) {
        return ''
    }

    $trimmed = $Root.Trim()
    if ($trimmed -match '^/([a-zA-Z]):/(.+)') {
        $drive = $Matches[1].ToUpperInvariant()
        $rest = $Matches[2] -replace '/', '\'
        return "${drive}:\$rest"
    }

    return ($trimmed -replace '/', '\')
}

function Load-CursorChatMap {
    if (-not (Test-Path $cursorChatsPath)) {
        return [ordered]@{}
    }

    try {
        $content = Get-Content -Path $cursorChatsPath -Raw -Encoding UTF8
        $data = $content | ConvertFrom-Json
    }
    catch {
        Write-Log "Cursor chat map invalid, recreating: $($_.Exception.Message)"
        return [ordered]@{}
    }

    if ($data -is [System.Collections.IDictionary]) {
        $map = [ordered]@{}
        foreach ($key in $data.Keys) {
            $map[$key] = $data[$key]
        }

        return $map
    }

    $map = [ordered]@{}
    foreach ($property in $data.PSObject.Properties) {
        $map[$property.Name] = $property.Value
    }

    return $map
}

function Save-CursorChat {
    param([object]$Payload)

    if ($null -eq $Payload) {
        return
    }

    $conversationId = [string](Get-PropertyValue -Object $Payload -Name 'conversation_id' -Default '')
    if ([string]::IsNullOrWhiteSpace($conversationId)) {
        return
    }

    $workspaceRoots = Get-PropertyValue -Object $Payload -Name 'workspace_roots' -Default @()
    if ($workspaceRoots -is [string]) {
        $workspaceRoots = @($workspaceRoots)
    }

    $normalizedRoots = @()
    foreach ($root in $workspaceRoots) {
        $normalized = Normalize-WorkspaceRoot -Root ([string]$root)
        if (-not [string]::IsNullOrWhiteSpace($normalized)) {
            $normalizedRoots += $normalized
        }
    }

    $projectName = ''
    if ($normalizedRoots.Count -gt 0) {
        $projectName = Split-Path -Path $normalizedRoots[0] -Leaf
    }

    if ([string]::IsNullOrWhiteSpace($projectName)) {
        $projectName = 'sin-proyecto'
    }

    $entry = [ordered]@{
        conversationId = $conversationId
        projectName    = $projectName
        workspaceRoots = $normalizedRoots
        transcriptPath = [string](Get-PropertyValue -Object $Payload -Name 'transcript_path' -Default '')
        lastSeenUtc    = (Get-Date).ToUniversalTime().ToString('o')
    }

    $map = Load-CursorChatMap
    $map[$conversationId] = $entry

    if (-not (Test-Path $logDirectory)) {
        New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    }

    $json = $map | ConvertTo-Json -Depth 8
    Set-Content -Path $cursorChatsPath -Value $json -Encoding UTF8
}

function Load-CursorNotificationTargets {
    if (-not (Test-Path $cursorTargetsPath)) {
        return [ordered]@{}
    }

    try {
        $content = Get-Content -Path $cursorTargetsPath -Raw -Encoding UTF8
        $data = $content | ConvertFrom-Json
    }
    catch {
        Write-Log "Cursor notification targets invalid, recreating: $($_.Exception.Message)"
        return [ordered]@{}
    }

    if ($data -is [System.Collections.IDictionary]) {
        $map = [ordered]@{}
        foreach ($key in $data.Keys) {
            $map[$key] = $data[$key]
        }

        return $map
    }

    $map = [ordered]@{}
    foreach ($property in $data.PSObject.Properties) {
        $map[$property.Name] = $property.Value
    }

    return $map
}

function Save-CursorNotificationTarget {
    param(
        [string]$MessageId,
        [string]$ConversationId,
        [string]$ProjectName
    )

    if ([string]::IsNullOrWhiteSpace($MessageId) -or [string]::IsNullOrWhiteSpace($ConversationId)) {
        return
    }

    $map = Load-CursorNotificationTargets
    $map[$MessageId] = [ordered]@{
        conversationId = $ConversationId
        projectName    = $ProjectName
        savedAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
    }

    if (-not (Test-Path $logDirectory)) {
        New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    }

    $json = $map | ConvertTo-Json -Depth 6
    Set-Content -Path $cursorTargetsPath -Value $json -Encoding UTF8
}

function Get-TelegramConfig {
    if (-not (Test-Path $configPath)) {
        Write-Log "Config file not found at $configPath"
        return $null
    }

    $config = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

    if (-not [string]::IsNullOrWhiteSpace($env:CURSOR_TELEGRAM_BOT_TOKEN)) {
        $config | Add-Member -NotePropertyName botToken -NotePropertyValue $env:CURSOR_TELEGRAM_BOT_TOKEN -Force
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CURSOR_TELEGRAM_CHAT_ID)) {
        $config | Add-Member -NotePropertyName chatId -NotePropertyValue $env:CURSOR_TELEGRAM_CHAT_ID -Force
    }

    return $config
}

function Read-HookPayload {
    if ($Test) {
        return [pscustomobject]@{
            conversation_id = 'manual-test'
            hook_event_name = 'stop'
            loop_count      = 0
            transcript_path = $null
        }
    }

    $rawInput = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($rawInput)) {
        $rawInput = ($input | Out-String)
    }

    if ([string]::IsNullOrWhiteSpace($rawInput)) {
        Write-Log 'No hook payload received on stdin'
        return $null
    }

    $rawInput = $rawInput.Trim()
    $lines = $rawInput -split "`r?`n"
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        if ($trimmed -eq '.') {
            continue
        }

        $objectIndex = $trimmed.IndexOf('{')
        $arrayIndex = $trimmed.IndexOf('[')
        $startIndex = -1
        if ($objectIndex -ge 0 -and $arrayIndex -ge 0) {
            $startIndex = [Math]::Min($objectIndex, $arrayIndex)
        }
        elseif ($objectIndex -ge 0) {
            $startIndex = $objectIndex
        }
        elseif ($arrayIndex -ge 0) {
            $startIndex = $arrayIndex
        }

        if ($startIndex -ge 0) {
            $trimmed = $trimmed.Substring($startIndex)
        }

        if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
            try {
                return $trimmed | ConvertFrom-Json
            }
            catch {
                Write-Log "Invalid hook payload JSON: $($_.Exception.Message)"
                return $null
            }
        }
    }

    Write-Log "Hook payload not JSON: $rawInput"
    return $null
}

function Get-LatestCursorStopReason {
    $logsRoot = Join-Path $env:APPDATA 'Cursor\logs'
    if (-not (Test-Path $logsRoot)) {
        return $null
    }

    $sessionDirectories = Get-ChildItem -Path $logsRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending |
        Select-Object -First 20

    $reasonPattern = 'Released wakelock id=.* reason="(?<reason>[^"]+)" composerId='

    foreach ($sessionDirectory in $sessionDirectories) {
        $rendererLogs = Get-ChildItem -Path $sessionDirectory.FullName -Filter 'renderer.log' -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime -Descending

        foreach ($rendererLog in $rendererLogs) {
            $lines = @(Get-Content -Path $rendererLog.FullName -Tail 250 -ErrorAction SilentlyContinue)
            for ($index = $lines.Count - 1; $index -ge 0; $index--) {
                if ($lines[$index] -match $reasonPattern) {
                    Write-Log "Detected Cursor stop reason '$($Matches.reason)' from $($rendererLog.FullName)"
                    return $Matches.reason
                }
            }
        }
    }

    return $null
}

function Resolve-NotificationState {
    param([object]$Payload)

    $reason = Get-LatestCursorStopReason
    switch ($reason) {
        'user-approval-requested' {
            return [pscustomobject]@{
                Status      = 'waiting'
                Label       = 'Cursor necesita tu respuesta'
                DebugReason = $reason
            }
        }
        'generation-ended' {
            return [pscustomobject]@{
                Status      = 'finished'
                Label       = 'Cursor termino la tarea'
                DebugReason = $reason
            }
        }
        default {
            return [pscustomobject]@{
                Status      = 'unknown'
                Label       = 'Cursor se detuvo'
                DebugReason = $reason
            }
        }
    }
}

function Should-SendNotification {
    param(
        [object]$Config,
        [object]$State
    )

    switch ($State.Status) {
        'waiting' { return (Get-BooleanValue -Object $Config -Name 'sendWaitingNotification' -Default $true) }
        'finished' { return (Get-BooleanValue -Object $Config -Name 'sendFinishedNotification' -Default $true) }
        default { return (Get-BooleanValue -Object $Config -Name 'sendUnknownStops' -Default $true) }
    }
}

function Build-NotificationMessage {
    param(
        [object]$Config,
        [object]$Payload,
        [object]$State
    )

    if ($Test) {
        if (-not [string]::IsNullOrWhiteSpace($TestMessage)) {
            return $TestMessage
        }

        return "Cursor: prueba de notificacion por Telegram"
    }

    $projectDirectory = if (-not [string]::IsNullOrWhiteSpace($env:CURSOR_PROJECT_DIR)) {
        $env:CURSOR_PROJECT_DIR
    }
    else {
        $repoRoot
    }

    $projectName = Split-Path -Path $projectDirectory -Leaf
    $conversationId = [string](Get-PropertyValue -Object $Payload -Name 'conversation_id' -Default 'sin-conversacion')
    $loopCount = Get-PropertyValue -Object $Payload -Name 'loop_count' -Default $null
    $messagePrefix = [string](Get-PropertyValue -Object $Config -Name 'messagePrefix' -Default 'Cursor')

    if ($conversationId.Length -gt 12) {
        $conversationId = $conversationId.Substring(0, 12)
    }

    $lines = @(
        "$($messagePrefix): $($State.Label)"
        "Proyecto: $projectName"
        "Hora: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Conversacion: $conversationId"
    )

    if ($null -ne $loopCount) {
        $lines += "Loop: $loopCount"
    }

    if ((Get-BooleanValue -Object $Config -Name 'includeDebugReason' -Default $true) -and
        -not [string]::IsNullOrWhiteSpace($State.DebugReason)) {
        $lines += "Motivo: $($State.DebugReason)"
    }

    return ($lines -join "`n")
}

function Send-TelegramMessage {
    param(
        [object]$Config,
        [string]$Message
    )

    if ($DryRun) {
        Write-Log "DRY RUN message: $Message"
        Write-Output $Message
        return $null
    }

    $botToken = [string](Get-PropertyValue -Object $Config -Name 'botToken' -Default '')
    $chatId = [string](Get-PropertyValue -Object $Config -Name 'chatId' -Default '')

    if ([string]::IsNullOrWhiteSpace($botToken) -or $botToken -like 'PON_AQUI_*') {
        Write-Log 'Telegram bot token is not configured'
        return
    }

    if ([string]::IsNullOrWhiteSpace($chatId) -or $chatId -like 'PON_AQUI_*') {
        Write-Log 'Telegram chat id is not configured'
        return
    }

    $uri = "https://api.telegram.org/bot$botToken/sendMessage"
    $body = @{
        chat_id = $chatId
        text    = $Message
    }

    return (Invoke-RestMethod -Method Post -Uri $uri -Body $body -ContentType 'application/x-www-form-urlencoded')
}

try {
    $config = Get-TelegramConfig
    if ($null -eq $config) {
        exit 0
    }

    if (-not (Get-BooleanValue -Object $config -Name 'enabled' -Default $true)) {
        Write-Log 'Notifications are disabled in config'
        exit 0
    }

    $payload = Read-HookPayload
    $payloadKeys = if ($null -eq $payload) { '(none)' } else { $payload.PSObject.Properties.Name -join ', ' }
    Write-Log "Hook payload keys: $payloadKeys"
    Save-CursorChat -Payload $payload

    $state = Resolve-NotificationState -Payload $payload
    if (-not (Should-SendNotification -Config $config -State $state)) {
        Write-Log "Notification skipped by config for state '$($state.Status)'"
        exit 0
    }

    $message = Build-NotificationMessage -Config $config -Payload $payload -State $state
    $response = Send-TelegramMessage -Config $config -Message $message
    if ($null -ne $response) {
        $messageId = [string](Get-PropertyValue -Object $response.result -Name 'message_id' -Default '')
        $conversationId = [string](Get-PropertyValue -Object $payload -Name 'conversation_id' -Default '')
        $projectName = 'sin-proyecto'
        $workspaceRoots = Get-PropertyValue -Object $payload -Name 'workspace_roots' -Default @()
        if ($workspaceRoots -is [string]) {
            $workspaceRoots = @($workspaceRoots)
        }
        foreach ($root in $workspaceRoots) {
            $normalized = Normalize-WorkspaceRoot -Root ([string]$root)
            if (-not [string]::IsNullOrWhiteSpace($normalized)) {
                $projectName = Split-Path -Path $normalized -Leaf
                break
            }
        }

        Save-CursorNotificationTarget -MessageId $messageId -ConversationId $conversationId -ProjectName $projectName
    }
    Write-Log "Notification handled for state '$($state.Status)'"
}
catch {
    Write-Log "Unhandled error: $($_.Exception.Message)"
    exit 0
}
