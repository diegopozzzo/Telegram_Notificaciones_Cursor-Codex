[CmdletBinding()]
param(
    [int]$PollIntervalSeconds = 3,
    [switch]$DryRun,
    [switch]$TestFinished,
    [switch]$TestWaiting
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptRoot '..')).Path
$configPath = Join-Path $repoRoot 'config\telegram.settings.json'
$logDirectory = Join-Path $repoRoot 'logs'
$logPath = Join-Path $logDirectory 'codex-telegram-watcher.log'
$statePath = Join-Path $logDirectory 'codex-watcher.state.json'
$cursorChatsPath = Join-Path $logDirectory 'cursor-chats.json'
$cursorTargetsPath = Join-Path $logDirectory 'cursor-notification-targets.json'
$codexSessionsRoot = Join-Path $HOME '.codex\sessions'
$mutexName = 'Global\CodexTelegramWatcher'
$powershellPath = Join-Path $PSHOME 'powershell.exe'
$bridgeScriptPath = (Resolve-Path (Join-Path $scriptRoot 'send-codex-thread-message.ps1')).Path
$cursorBridgeScriptPath = (Resolve-Path (Join-Path $scriptRoot 'send-cursor-message.ps1')).Path
$maxTrackedFiles = 80
$maxTrackedTurns = 400
$maxProcessedEvents = 400
$maxTrackedNotifications = 300
$maxActiveBridgeThreads = 40
$activeBridgeRetentionHours = 4

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

function Get-HashValue {
    param(
        [object]$Dictionary,
        [string]$Key,
        $Default = $null
    )

    if ($null -eq $Dictionary) {
        return $Default
    }

    if ($Dictionary -is [System.Collections.IDictionary]) {
        if ($Dictionary.Contains($Key)) {
            return $Dictionary[$Key]
        }

        return $Default
    }

    return (Get-PropertyValue -Object $Dictionary -Name $Key -Default $Default)
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

function ConvertTo-NativeObject {
    param([object]$InputObject)

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $table[$key] = ConvertTo-NativeObject -InputObject $InputObject[$key]
        }

        return $table
    }

    if ($InputObject -is [pscustomobject]) {
        $table = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $table[$property.Name] = ConvertTo-NativeObject -InputObject $property.Value
        }

        return $table
    }

    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ConvertTo-NativeObject -InputObject $item
        }

        return $items
    }

    return $InputObject
}

function Get-TelegramConfig {
    if (-not (Test-Path $configPath)) {
        Write-Log "Config file not found at $configPath"
        return $null
    }

    $config = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_TELEGRAM_BOT_TOKEN)) {
        $config | Add-Member -NotePropertyName botToken -NotePropertyValue $env:CODEX_TELEGRAM_BOT_TOKEN -Force
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:CURSOR_TELEGRAM_BOT_TOKEN)) {
        $config | Add-Member -NotePropertyName botToken -NotePropertyValue $env:CURSOR_TELEGRAM_BOT_TOKEN -Force
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_TELEGRAM_CHAT_ID)) {
        $config | Add-Member -NotePropertyName chatId -NotePropertyValue $env:CODEX_TELEGRAM_CHAT_ID -Force
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:CURSOR_TELEGRAM_CHAT_ID)) {
        $config | Add-Member -NotePropertyName chatId -NotePropertyValue $env:CURSOR_TELEGRAM_CHAT_ID -Force
    }

    return $config
}

function New-EmptyState {
    return [ordered]@{
        version             = 3
        files               = [ordered]@{}
        turnContexts        = [ordered]@{}
        processedEventIds   = [ordered]@{}
        notificationTargets = [ordered]@{}
        activeBridgeThreads = [ordered]@{}
        latestThread        = $null
        telegramOffset      = $null
    }
}

function Ensure-StateDefaults {
    param([object]$State)

    $State['version'] = 3

    if (-not $State.Contains('files')) {
        $State['files'] = [ordered]@{}
    }

    if (-not $State.Contains('turnContexts')) {
        $State['turnContexts'] = [ordered]@{}
    }

    if (-not $State.Contains('processedEventIds')) {
        $State['processedEventIds'] = [ordered]@{}
    }

    if (-not $State.Contains('notificationTargets')) {
        $State['notificationTargets'] = [ordered]@{}
    }

    if (-not $State.Contains('activeBridgeThreads')) {
        $State['activeBridgeThreads'] = [ordered]@{}
    }

    if (-not $State.Contains('latestThread')) {
        $State['latestThread'] = $null
    }

    if (-not $State.Contains('telegramOffset')) {
        $State['telegramOffset'] = $null
    }

    if (-not ($State.files -is [System.Collections.IDictionary])) {
        $State['files'] = [ordered]@{}
    }

    if (-not ($State.turnContexts -is [System.Collections.IDictionary])) {
        $State['turnContexts'] = [ordered]@{}
    }

    if (-not ($State.processedEventIds -is [System.Collections.IDictionary])) {
        $State['processedEventIds'] = [ordered]@{}
    }

    if (-not ($State.notificationTargets -is [System.Collections.IDictionary])) {
        $State['notificationTargets'] = [ordered]@{}
    }

    if (-not ($State.activeBridgeThreads -is [System.Collections.IDictionary])) {
        $State['activeBridgeThreads'] = [ordered]@{}
    }
}

function Load-State {
    if (-not (Test-Path $statePath)) {
        return (New-EmptyState)
    }

    try {
        $content = Get-Content -Path $statePath -Raw -Encoding UTF8
        $state = ConvertTo-NativeObject -InputObject ($content | ConvertFrom-Json)
    }
    catch {
        Write-Log "State load failed, recreating state: $($_.Exception.Message)"
        return (New-EmptyState)
    }

    Ensure-StateDefaults -State $state
    return $state
}

function Convert-ToSortableDate {
    param([string]$TimestampText)

    if ([string]::IsNullOrWhiteSpace($TimestampText)) {
        return [datetime]::MinValue
    }

    try {
        return ([datetimeoffset]::Parse($TimestampText)).UtcDateTime
    }
    catch {
    }

    try {
        return [datetime]::Parse($TimestampText)
    }
    catch {
        return [datetime]::MinValue
    }
}

function Trim-State {
    param([object]$State)

    $processedEntries = @()
    foreach ($key in $State.processedEventIds.Keys) {
        $processedEntries += [pscustomobject]@{
            Key       = $key
            SortValue = Convert-ToSortableDate -TimestampText ([string]$State.processedEventIds[$key])
        }
    }

    if ($processedEntries.Count -gt $maxProcessedEvents) {
        $trimmed = [ordered]@{}
        foreach ($entry in ($processedEntries | Sort-Object -Property SortValue -Descending | Select-Object -First $maxProcessedEvents)) {
            $trimmed[$entry.Key] = [string]$State.processedEventIds[$entry.Key]
        }

        $State.processedEventIds = $trimmed
    }

    $turnEntries = @()
    foreach ($key in $State.turnContexts.Keys) {
        $entry = $State.turnContexts[$key]
        $turnEntries += [pscustomobject]@{
            Key       = $key
            Value     = $entry
            SortValue = Convert-ToSortableDate -TimestampText ([string](Get-HashValue -Dictionary $entry -Key 'timestamp' -Default ''))
        }
    }

    if ($turnEntries.Count -gt $maxTrackedTurns) {
        $State.turnContexts = [ordered]@{}
        foreach ($entry in ($turnEntries | Sort-Object -Property SortValue -Descending | Select-Object -First $maxTrackedTurns)) {
            $State.turnContexts[$entry.Key] = $entry.Value
        }
    }

    $fileEntries = @()
    foreach ($key in $State.files.Keys) {
        $entry = $State.files[$key]
        $fileEntries += [pscustomobject]@{
            Key       = $key
            Value     = $entry
            SortValue = Convert-ToSortableDate -TimestampText ([string](Get-HashValue -Dictionary $entry -Key 'lastSeenUtc' -Default ''))
        }
    }

    if ($fileEntries.Count -gt $maxTrackedFiles) {
        $State.files = [ordered]@{}
        foreach ($entry in ($fileEntries | Sort-Object -Property SortValue -Descending | Select-Object -First $maxTrackedFiles)) {
            $State.files[$entry.Key] = $entry.Value
        }
    }

    $notificationEntries = @()
    foreach ($key in $State.notificationTargets.Keys) {
        $entry = $State.notificationTargets[$key]
        $notificationEntries += [pscustomobject]@{
            Key       = $key
            Value     = $entry
            SortValue = Convert-ToSortableDate -TimestampText ([string](Get-HashValue -Dictionary $entry -Key 'sentAt' -Default ''))
        }
    }

    if ($notificationEntries.Count -gt $maxTrackedNotifications) {
        $State.notificationTargets = [ordered]@{}
        foreach ($entry in ($notificationEntries | Sort-Object -Property SortValue -Descending | Select-Object -First $maxTrackedNotifications)) {
            $State.notificationTargets[$entry.Key] = $entry.Value
        }
    }

    $activeBridgeEntries = @()
    $activeBridgeCutoff = (Get-Date).ToUniversalTime().AddHours(-$activeBridgeRetentionHours)
    foreach ($key in $State.activeBridgeThreads.Keys) {
        $entry = $State.activeBridgeThreads[$key]
        $sortValue = Convert-ToSortableDate -TimestampText ([string](Get-HashValue -Dictionary $entry -Key 'startedAt' -Default ''))
        if ($sortValue -lt $activeBridgeCutoff) {
            continue
        }

        $activeBridgeEntries += [pscustomobject]@{
            Key       = $key
            Value     = $entry
            SortValue = $sortValue
        }
    }

    $State.activeBridgeThreads = [ordered]@{}
    foreach ($entry in ($activeBridgeEntries | Sort-Object -Property SortValue -Descending | Select-Object -First $maxActiveBridgeThreads)) {
        $State.activeBridgeThreads[$entry.Key] = $entry.Value
    }
}

function Save-State {
    param([object]$State)

    Trim-State -State $State

    if (-not (Test-Path $logDirectory)) {
        New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    }

    $json = $State | ConvertTo-Json -Depth 16

    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            Set-Content -Path $statePath -Value $json -Encoding UTF8
            return
        }
        catch {
            if ($attempt -eq 4) {
                throw
            }

            Start-Sleep -Milliseconds 250
        }
    }
}

function Get-ThreadIdFromFilePath {
    param([string]$FilePath)

    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    if ($fileName -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$') {
        return $Matches[1]
    }

    return ''
}

function Get-RecentSessionFiles {
    if (-not (Test-Path $codexSessionsRoot)) {
        return @()
    }

    return @(Get-ChildItem -Path $codexSessionsRoot -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending |
        Select-Object -First $maxTrackedFiles)
}

function Bootstrap-State {
    param([object]$State)

    $files = Get-RecentSessionFiles
    foreach ($file in $files) {
        if (-not $State.files.Contains($file.FullName)) {
            $State.files[$file.FullName] = [ordered]@{
                offset      = [long]$file.Length
                remainder   = ''
                lastSeenUtc = (Get-Date).ToUniversalTime().ToString('o')
                threadId    = (Get-ThreadIdFromFilePath -FilePath $file.FullName)
            }
        }
    }
}

function Ensure-TrackedFile {
    param(
        [object]$State,
        [System.IO.FileInfo]$File
    )

    if ($State.files.Contains($File.FullName)) {
        $State.files[$File.FullName]['lastSeenUtc'] = (Get-Date).ToUniversalTime().ToString('o')
        if ([string]::IsNullOrWhiteSpace([string](Get-HashValue -Dictionary $State.files[$File.FullName] -Key 'threadId' -Default ''))) {
            $State.files[$File.FullName]['threadId'] = Get-ThreadIdFromFilePath -FilePath $File.FullName
        }

        return
    }

    $State.files[$File.FullName] = [ordered]@{
        offset      = 0
        remainder   = ''
        lastSeenUtc = (Get-Date).ToUniversalTime().ToString('o')
        threadId    = (Get-ThreadIdFromFilePath -FilePath $File.FullName)
    }
}

function Read-AppendedContent {
    param(
        [string]$Path,
        [long]$Offset
    )

    $fileStream = $null
    $reader = $null

    try {
        $fileStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($Offset -gt $fileStream.Length) {
            $Offset = 0
        }

        $fileStream.Seek($Offset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $reader = New-Object System.IO.StreamReader($fileStream, [System.Text.Encoding]::UTF8, $true, 4096, $true)
        $text = $reader.ReadToEnd()
        $newOffset = $fileStream.Position

        return [pscustomobject]@{
            Text      = $text
            NewOffset = $newOffset
        }
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }

        if ($null -ne $fileStream) {
            $fileStream.Dispose()
        }
    }
}

function Split-JsonLines {
    param(
        [string]$Text,
        [string]$Remainder
    )

    $combined = '{0}{1}' -f $Remainder, $Text
    if ([string]::IsNullOrEmpty($combined)) {
        return [pscustomobject]@{
            Lines     = @()
            Remainder = ''
        }
    }

    $parts = $combined -split "`r?`n", -1
    if ($combined -match "(`r`n|`n)$") {
        return [pscustomobject]@{
            Lines     = @($parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            Remainder = ''
        }
    }

    if ($parts.Count -eq 1) {
        return [pscustomobject]@{
            Lines     = @()
            Remainder = $combined
        }
    }

    return [pscustomobject]@{
        Lines     = @($parts[0..($parts.Count - 2)] | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Remainder = $parts[-1]
    }
}

function Get-CodexPrefix {
    param([object]$Config)

    $prefix = [string](Get-PropertyValue -Object $Config -Name 'messagePrefix' -Default '')
    if ([string]::IsNullOrWhiteSpace($prefix) -or $prefix -eq 'Cursor') {
        return 'Codex'
    }

    return $prefix
}

function Get-CursorPrefix {
    param([object]$Config)

    $prefix = [string](Get-PropertyValue -Object $Config -Name 'messagePrefix' -Default 'Cursor')
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        return 'Cursor'
    }

    return $prefix
}

function Get-ProjectName {
    param([string]$ProjectDirectory)

    if ([string]::IsNullOrWhiteSpace($ProjectDirectory)) {
        return 'sin-proyecto'
    }

    return (Split-Path -Path $ProjectDirectory -Leaf)
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
        Write-Log "Cursor chat map invalid: $($_.Exception.Message)"
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

function Load-CursorNotificationTargets {
    if (-not (Test-Path $cursorTargetsPath)) {
        return [ordered]@{}
    }

    try {
        $content = Get-Content -Path $cursorTargetsPath -Raw -Encoding UTF8
        $data = $content | ConvertFrom-Json
    }
    catch {
        Write-Log "Cursor notification targets invalid: $($_.Exception.Message)"
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

function Normalize-CursorChat {
    param([object]$Chat)

    $conversationId = [string](Get-PropertyValue -Object $Chat -Name 'conversationId' -Default '')
    $projectName = [string](Get-PropertyValue -Object $Chat -Name 'projectName' -Default '')
    $workspaceRoots = Get-PropertyValue -Object $Chat -Name 'workspaceRoots' -Default @()
    $transcriptPath = [string](Get-PropertyValue -Object $Chat -Name 'transcriptPath' -Default '')
    $lastSeenUtc = [string](Get-PropertyValue -Object $Chat -Name 'lastSeenUtc' -Default '')

    if ($workspaceRoots -is [string]) {
        $workspaceRoots = @($workspaceRoots)
    }

    $workspaceRoot = ''
    if ($workspaceRoots.Count -gt 0) {
        $workspaceRoot = [string]$workspaceRoots[0]
    }

    if ([string]::IsNullOrWhiteSpace($projectName) -and -not [string]::IsNullOrWhiteSpace($workspaceRoot)) {
        $projectName = Split-Path -Path ($workspaceRoot -replace '/', '\') -Leaf
    }

    if ([string]::IsNullOrWhiteSpace($projectName)) {
        $projectName = 'sin-proyecto'
    }

    return [pscustomobject]@{
        conversationId = $conversationId
        projectName    = $projectName
        workspaceRoot  = $workspaceRoot
        transcriptPath = $transcriptPath
        lastSeenUtc    = $lastSeenUtc
    }
}

function Get-CursorChats {
    $map = Load-CursorChatMap
    if ($map.Keys.Count -eq 0) {
        return @()
    }

    $items = @()
    foreach ($key in $map.Keys) {
        $items += Normalize-CursorChat -Chat $map[$key]
    }

    return @($items | Sort-Object -Property @{ Expression = { Convert-ToSortableDate -TimestampText ([string]$_.lastSeenUtc) }; Descending = $true })
}

function Get-CodexChats {
    param([object]$State)

    $threads = [ordered]@{}
    foreach ($turnId in $State.turnContexts.Keys) {
        $context = $State.turnContexts[$turnId]
        $threadId = [string](Get-HashValue -Dictionary $context -Key 'threadId' -Default '')
        if ([string]::IsNullOrWhiteSpace($threadId)) {
            continue
        }

        $timestamp = [string](Get-HashValue -Dictionary $context -Key 'timestamp' -Default '')
        $projectDirectory = [string](Get-HashValue -Dictionary $context -Key 'cwd' -Default '')
        if (-not $threads.Contains($threadId)) {
            $threads[$threadId] = [ordered]@{
                threadId         = $threadId
                projectDirectory = $projectDirectory
                timestamp        = $timestamp
            }
            continue
        }

        $existing = $threads[$threadId]
        $existingTimestamp = Convert-ToSortableDate -TimestampText ([string](Get-HashValue -Dictionary $existing -Key 'timestamp' -Default ''))
        $candidateTimestamp = Convert-ToSortableDate -TimestampText $timestamp
        if ($candidateTimestamp -gt $existingTimestamp) {
            $existing['timestamp'] = $timestamp
            $existing['projectDirectory'] = $projectDirectory
        }
    }

    $items = @()
    foreach ($key in $threads.Keys) {
        $entry = $threads[$key]
        $items += [pscustomobject]@{
            threadId         = [string](Get-HashValue -Dictionary $entry -Key 'threadId' -Default '')
            projectDirectory = [string](Get-HashValue -Dictionary $entry -Key 'projectDirectory' -Default '')
            timestamp        = [string](Get-HashValue -Dictionary $entry -Key 'timestamp' -Default '')
        }
    }

    return @($items | Sort-Object -Property @{ Expression = { Convert-ToSortableDate -TimestampText ([string]$_.timestamp) }; Descending = $true })
}

function Build-ChatsListMessage {
    param(
        [object]$Config,
        [object]$State
    )

    $codexChats = Get-CodexChats -State $State
    $cursorChats = Get-CursorChats
    $lines = @('Chats disponibles:')

    if ($codexChats.Count -gt 0) {
        $lines += 'Codex:'
        for ($index = 0; $index -lt $codexChats.Count; $index++) {
            $entry = $codexChats[$index]
            $projectName = Get-ProjectName -ProjectDirectory ([string]$entry.projectDirectory)
            $threadId = [string]$entry.threadId
            $shortThreadId = if ([string]::IsNullOrWhiteSpace($threadId)) { 'sin-hilo' } elseif ($threadId.Length -gt 12) { $threadId.Substring(0, 12) } else { $threadId }
            $timestamp = Convert-ToLocalTimestamp -TimestampText ([string]$entry.timestamp)
            $lines += ("C{0}) {1} | hilo {2} | {3}" -f ($index + 1), $projectName, $shortThreadId, $timestamp)
        }
    }
    else {
        $lines += 'Codex: (sin chats)'
    }

    if ($cursorChats.Count -gt 0) {
        $lines += 'Cursor:'
        for ($index = 0; $index -lt $cursorChats.Count; $index++) {
            $entry = $cursorChats[$index]
            $projectName = [string]$entry.projectName
            $conversationId = [string]$entry.conversationId
            $shortConversationId = if ([string]::IsNullOrWhiteSpace($conversationId)) { 'sin-id' } elseif ($conversationId.Length -gt 12) { $conversationId.Substring(0, 12) } else { $conversationId }
            $timestamp = Convert-ToLocalTimestamp -TimestampText ([string]$entry.lastSeenUtc)
            $lines += ("U{0}) {1} | conversacion {2} | {3}" -f ($index + 1), $projectName, $shortConversationId, $timestamp)
        }
    }
    else {
        $lines += 'Cursor: (sin chats)'
    }

    $lines += 'Usa /codex C1 <mensaje> o /cursor U1 <mensaje>.'
    $lines += 'Si no indicas id: /codex <mensaje> usa el ultimo Codex y /cursor <mensaje> usa el ultimo Cursor.'

    return ($lines -join "`n")
}

function Convert-ToLocalTimestamp {
    param([string]$TimestampText)

    if ([string]::IsNullOrWhiteSpace($TimestampText)) {
        return (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    try {
        return ([datetimeoffset]::Parse($TimestampText)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
    }
    catch {
    }

    return (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
}

function Resolve-CodexCompletionState {
    param([string]$Message)

    if (-not [string]::IsNullOrWhiteSpace($Message) -and ($Message -match '[\?\u00BF]')) {
        return [pscustomobject]@{
            Status = 'waiting'
            Label  = 'Codex espera tu respuesta'
        }
    }

    return [pscustomobject]@{
        Status = 'finished'
        Label  = 'Codex termino la tarea'
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

function Split-TextForTelegram {
    param(
        [string]$Text,
        [int]$MaxLength = 3200
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $remaining = ($Text -replace "`r`n", "`n").Trim()
    $chunks = @()

    while ($remaining.Length -gt $MaxLength) {
        $breakIndex = $remaining.LastIndexOf("`n", $MaxLength - 1)
        if ($breakIndex -lt [Math]::Floor($MaxLength / 2)) {
            $breakIndex = $remaining.LastIndexOf(' ', $MaxLength - 1)
        }

        if ($breakIndex -lt [Math]::Floor($MaxLength / 2)) {
            $breakIndex = $MaxLength
        }

        $chunk = $remaining.Substring(0, $breakIndex).TrimEnd()
        if (-not [string]::IsNullOrWhiteSpace($chunk)) {
            $chunks += $chunk
        }

        $remaining = $remaining.Substring($breakIndex).TrimStart()
    }

    if (-not [string]::IsNullOrWhiteSpace($remaining)) {
        $chunks += $remaining
    }

    return ,$chunks
}

function Build-NotificationMessages {
    param(
        [object]$Config,
        [object]$Event,
        [object]$State,
        [string]$ProjectDirectory,
        [string]$ThreadId,
        [string]$TurnId,
        [string]$LastAgentMessage
    )

    $projectName = Get-ProjectName -ProjectDirectory $ProjectDirectory
    $shortThreadId = if ([string]::IsNullOrWhiteSpace($ThreadId)) { 'sin-hilo' } elseif ($ThreadId.Length -gt 12) { $ThreadId.Substring(0, 12) } else { $ThreadId }
    $shortTurnId = if ([string]::IsNullOrWhiteSpace($TurnId)) { 'sin-turno' } elseif ($TurnId.Length -gt 12) { $TurnId.Substring(0, 12) } else { $TurnId }

    $headerLines = @(
        "$(Get-CodexPrefix -Config $Config): $($State.Label)"
        "Proyecto: $projectName"
        "Hora: $(Convert-ToLocalTimestamp -TimestampText ([string]$Event.timestamp))"
        "Hilo: $shortThreadId"
        "Turno: $shortTurnId"
    )

    $bodyChunks = Split-TextForTelegram -Text $LastAgentMessage
    if ($bodyChunks.Count -eq 0) {
        return ,(($headerLines -join "`n"))
    }

    $messages = @()
    $totalChunks = $bodyChunks.Count
    $firstLabel = if ($totalChunks -eq 1) { 'Respuesta completa:' } else { "Respuesta completa (1/$totalChunks):" }
    $messages += (($headerLines + @('', $firstLabel, $bodyChunks[0])) -join "`n")

    for ($index = 1; $index -lt $totalChunks; $index++) {
        $messages += @(
            "$(Get-CodexPrefix -Config $Config): continuacion $($index + 1)/$totalChunks"
            "Proyecto: $projectName"
            "Hilo: $shortThreadId"
            ''
            $bodyChunks[$index]
        ) -join "`n"
    }

    return ,$messages
}

function Get-TelegramBotToken {
    param([object]$Config)

    $botToken = [string](Get-PropertyValue -Object $Config -Name 'botToken' -Default '')
    if ([string]::IsNullOrWhiteSpace($botToken) -or $botToken -like 'PON_AQUI_*') {
        return $null
    }

    return $botToken
}

function Get-TelegramChatId {
    param([object]$Config)

    $chatId = [string](Get-PropertyValue -Object $Config -Name 'chatId' -Default '')
    if ([string]::IsNullOrWhiteSpace($chatId) -or $chatId -like 'PON_AQUI_*') {
        return $null
    }

    return $chatId
}

function Invoke-TelegramApi {
    param(
        [object]$Config,
        [string]$Method,
        [hashtable]$Body
    )

    $botToken = Get-TelegramBotToken -Config $Config
    if ([string]::IsNullOrWhiteSpace($botToken)) {
        Write-Log "Telegram bot token is not configured for $Method"
        return $null
    }

    $uri = "https://api.telegram.org/bot$botToken/$Method"

    try {
        return Invoke-RestMethod -Method Post -Uri $uri -Body $Body -ContentType 'application/x-www-form-urlencoded'
    }
    catch {
        Write-Log "Telegram API call '$Method' failed: $($_.Exception.Message)"
        return $null
    }
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

    $chatId = Get-TelegramChatId -Config $Config
    if ([string]::IsNullOrWhiteSpace($chatId)) {
        Write-Log 'Telegram chat id is not configured'
        return $null
    }

    return Invoke-TelegramApi -Config $Config -Method 'sendMessage' -Body @{
        chat_id                  = $chatId
        text                     = $Message
        disable_web_page_preview = $true
    }
}

function Register-TelegramTarget {
    param(
        [object]$State,
        [object]$TelegramResponse,
        [string]$ThreadId,
        [string]$TurnId,
        [string]$ProjectDirectory
    )

    if ($null -eq $TelegramResponse) {
        return $false
    }

    $result = Get-PropertyValue -Object $TelegramResponse -Name 'result' -Default $null
    $messageId = [string](Get-PropertyValue -Object $result -Name 'message_id' -Default '')
    if ([string]::IsNullOrWhiteSpace($messageId)) {
        return $false
    }

    $State.notificationTargets[$messageId] = [ordered]@{
        threadId         = $ThreadId
        turnId           = $TurnId
        projectDirectory = $ProjectDirectory
        sentAt           = (Get-Date).ToUniversalTime().ToString('o')
    }

    return $true
}

function Update-LatestThread {
    param(
        [object]$State,
        [string]$ThreadId,
        [string]$TurnId,
        [string]$ProjectDirectory
    )

    if ([string]::IsNullOrWhiteSpace($ThreadId)) {
        return
    }

    $State.latestThread = [ordered]@{
        threadId         = $ThreadId
        turnId           = $TurnId
        projectDirectory = $ProjectDirectory
        updatedAt        = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Set-ActiveBridgeThread {
    param(
        [object]$State,
        [string]$ThreadId,
        [string]$ProjectDirectory,
        [string]$MessageText,
        [int]$BridgeProcessId
    )

    if ([string]::IsNullOrWhiteSpace($ThreadId)) {
        return
    }

    $preview = ($MessageText -replace '\s+', ' ').Trim()
    if ($preview.Length -gt 180) {
        $preview = $preview.Substring(0, 177) + '...'
    }

    $entry = [ordered]@{
        startedAt        = (Get-Date).ToUniversalTime().ToString('o')
        lastObservedAt   = (Get-Date).ToUniversalTime().ToString('o')
        projectDirectory = $ProjectDirectory
        messagePreview   = $preview
        turnId           = ''
    }

    if ($BridgeProcessId -gt 0) {
        $entry['bridgeProcessId'] = $BridgeProcessId
    }

    $State.activeBridgeThreads[$ThreadId] = $entry
}

function Clear-ActiveBridgeThread {
    param(
        [object]$State,
        [string]$ThreadId,
        [string]$TurnId = ''
    )

    if ([string]::IsNullOrWhiteSpace($ThreadId)) {
        return $false
    }

    if ($State.activeBridgeThreads.Contains($ThreadId)) {
        if (-not [string]::IsNullOrWhiteSpace($TurnId)) {
            $entry = $State.activeBridgeThreads[$ThreadId]
            $activeTurnId = [string](Get-HashValue -Dictionary $entry -Key 'turnId' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($activeTurnId) -and $activeTurnId -ne $TurnId) {
                return $false
            }
        }

        $State.activeBridgeThreads.Remove($ThreadId)
        return $true
    }

    return $false
}

function Bind-ActiveBridgeThreadTurn {
    param(
        [object]$State,
        [string]$ThreadId,
        [string]$TurnId,
        [string]$ObservedAt
    )

    if ([string]::IsNullOrWhiteSpace($ThreadId) -or [string]::IsNullOrWhiteSpace($TurnId)) {
        return $false
    }

    if (-not $State.activeBridgeThreads.Contains($ThreadId)) {
        return $false
    }

    $entry = $State.activeBridgeThreads[$ThreadId]
    $changed = $false
    $observedValue = $ObservedAt
    if ([string]::IsNullOrWhiteSpace($observedValue)) {
        $observedValue = (Get-Date).ToUniversalTime().ToString('o')
    }

    $currentTurnId = [string](Get-HashValue -Dictionary $entry -Key 'turnId' -Default '')
    if ($currentTurnId -ne $TurnId) {
        $entry['turnId'] = $TurnId
        $changed = $true
    }

    $currentObservedAt = [string](Get-HashValue -Dictionary $entry -Key 'lastObservedAt' -Default '')
    if ($currentObservedAt -ne $observedValue) {
        $entry['lastObservedAt'] = $observedValue
        $changed = $true
    }

    if ($entry.Contains('bridgeExitedAt')) {
        $entry.Remove('bridgeExitedAt')
        $changed = $true
    }

    return $changed
}

function Sync-ActiveBridgeThreads {
    param(
        [object]$State,
        [object]$Config
    )

    $changed = $false
    $nowUtc = (Get-Date).ToUniversalTime()

    foreach ($threadId in @($State.activeBridgeThreads.Keys)) {
        $entry = $State.activeBridgeThreads[$threadId]
        $startedAtText = [string](Get-HashValue -Dictionary $entry -Key 'startedAt' -Default '')
        $startedAtUtc = Convert-ToSortableDate -TimestampText $startedAtText
        $lastObservedAtText = [string](Get-HashValue -Dictionary $entry -Key 'lastObservedAt' -Default $startedAtText)
        $lastObservedAtUtc = Convert-ToSortableDate -TimestampText $lastObservedAtText
        $ageMinutes = ($nowUtc - $startedAtUtc).TotalMinutes
        $idleMinutes = ($nowUtc - $lastObservedAtUtc).TotalMinutes
        $projectDirectory = [string](Get-HashValue -Dictionary $entry -Key 'projectDirectory' -Default '')
        $bridgeProcessId = [int](Get-HashValue -Dictionary $entry -Key 'bridgeProcessId' -Default 0)
        $turnId = [string](Get-HashValue -Dictionary $entry -Key 'turnId' -Default '')

        $processAlive = $false
        if ($bridgeProcessId -gt 0) {
            try {
                $null = Get-Process -Id $bridgeProcessId -ErrorAction Stop
                $processAlive = $true
            }
            catch {
                $processAlive = $false
            }
        }

        if ($bridgeProcessId -gt 0 -and -not $processAlive -and -not $entry.Contains('bridgeExitedAt')) {
            $entry['bridgeExitedAt'] = $nowUtc.ToString('o')
            Write-Log "Bridge process $bridgeProcessId exited for thread '$threadId'. Waiting for Codex turn events."
            $changed = $true
        }

        $staleCutoffMinutes = 5
        $silentCleanupMinutes = 180
        $shouldNotify = $false
        $reason = ''

        if ([string]::IsNullOrWhiteSpace($turnId) -and $bridgeProcessId -gt 0 -and -not $processAlive -and $ageMinutes -ge $staleCutoffMinutes) {
            $shouldNotify = $true
            $reason = "bridge finalizo sin respuesta (PID $bridgeProcessId)"
        }
        elseif ([string]::IsNullOrWhiteSpace($turnId) -and $bridgeProcessId -le 0 -and $ageMinutes -ge $staleCutoffMinutes) {
            $shouldNotify = $true
            $reason = 'bridge finalizo sin respuesta'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($turnId) -and -not $processAlive -and $idleMinutes -ge $silentCleanupMinutes) {
            $State.activeBridgeThreads.Remove($threadId)
            Write-Log "Cleared stale bridge entry for thread '$threadId' after waiting $([Math]::Round($idleMinutes, 1)) minute(s) for turn '$turnId' without a terminal event."
            $changed = $true
            continue
        }

        if ($shouldNotify) {
            $response = Send-TelegramMessage -Config $Config -Message (Build-AbortedNotificationMessage -Config $Config -ProjectDirectory $projectDirectory -ThreadId $threadId -TurnId '' -Reason $reason)
            if (Register-TelegramTarget -State $State -TelegramResponse $response -ThreadId $threadId -TurnId '' -ProjectDirectory $projectDirectory) {
                $changed = $true
            }

            $State.activeBridgeThreads.Remove($threadId)
            Write-Log "Cleared stale bridge entry for thread '$threadId' (reason: $reason)"
            $changed = $true
        }
    }

    return $changed
}

function Send-TelegramMessagesAndTrack {
    param(
        [object]$Config,
        [object]$State,
        [string[]]$Messages,
        [string]$ThreadId,
        [string]$TurnId,
        [string]$ProjectDirectory
    )

    $changed = $false
    foreach ($message in $Messages) {
        $response = Send-TelegramMessage -Config $Config -Message $message
        if (Register-TelegramTarget -State $State -TelegramResponse $response -ThreadId $ThreadId -TurnId $TurnId -ProjectDirectory $ProjectDirectory) {
            $changed = $true
        }
    }

    Update-LatestThread -State $State -ThreadId $ThreadId -TurnId $TurnId -ProjectDirectory $ProjectDirectory
    return $changed
}

function Build-StatusMessage {
    param(
        [object]$Config,
        [object]$State
    )

    $prefix = Get-CodexPrefix -Config $Config
    $latestThread = Get-HashValue -Dictionary $State -Key 'latestThread' -Default $null
    $threadId = [string](Get-HashValue -Dictionary $latestThread -Key 'threadId' -Default '')
    $projectDirectory = [string](Get-HashValue -Dictionary $latestThread -Key 'projectDirectory' -Default '')
    $updatedAt = [string](Get-HashValue -Dictionary $latestThread -Key 'updatedAt' -Default '')

    $lines = @(
        "$prefix watcher activo"
        "Proyecto reciente: $(Get-ProjectName -ProjectDirectory $projectDirectory)"
    )

    if (-not [string]::IsNullOrWhiteSpace($threadId)) {
        $lines += "Hilo reciente: $threadId"
    }

    if (-not [string]::IsNullOrWhiteSpace($updatedAt)) {
        $lines += "Ultima actividad: $(Convert-ToLocalTimestamp -TimestampText $updatedAt)"
    }

    $activeCount = $State.activeBridgeThreads.Count
    if ($activeCount -gt 0) {
        $lines += "Hilos procesandose ahora: $activeCount"
    }

    $lines += 'Responde a una notificacion para contestar ese hilo.'
    $lines += 'Usa /codex <mensaje> para el hilo mas reciente de Codex.'
    $lines += 'Usa /cursor <mensaje> para la conversacion mas reciente de Cursor.'
    $lines += 'Usa /chats para listar los chats disponibles.'

    return ($lines -join "`n")
}

function Build-ReplyAcknowledgement {
    param(
        [object]$Config,
        [string]$ProjectDirectory,
        [string]$ThreadId,
        [string]$MessageText
    )

    $projectName = Get-ProjectName -ProjectDirectory $ProjectDirectory
    $shortThreadId = if ($ThreadId.Length -gt 12) { $ThreadId.Substring(0, 12) } else { $ThreadId }
    $preview = ($MessageText -replace '\s+', ' ').Trim()
    if ($preview.Length -gt 180) {
        $preview = $preview.Substring(0, 177) + '...'
    }

    return @(
        "$(Get-CodexPrefix -Config $Config): mensaje enviado"
        "Proyecto: $projectName"
        "Hilo: $shortThreadId"
        "Texto: $preview"
        'Te avisare por Telegram cuando Codex termine o si el turno se interrumpe.'
    ) -join "`n"
}

function Build-CursorReplyAcknowledgement {
    param(
        [object]$Config,
        [string]$ProjectName,
        [string]$ConversationId,
        [string]$MessageText
    )

    $shortConversationId = if ($ConversationId.Length -gt 12) { $ConversationId.Substring(0, 12) } else { $ConversationId }
    $preview = ($MessageText -replace '\s+', ' ').Trim()
    if ($preview.Length -gt 180) {
        $preview = $preview.Substring(0, 177) + '...'
    }

    return @(
        "$(Get-CursorPrefix -Config $Config): mensaje recibido"
        "Proyecto: $ProjectName"
        "Conversacion: $shortConversationId"
        "Texto: $preview"
        'Deje el mensaje en el inbox local para que lo veas en Cursor.'
    ) -join "`n"
}

function Build-ReplyRoutingError {
    param([object]$Config)

    return @(
        "$(Get-CodexPrefix -Config $Config): no pude enrutar tu mensaje"
        'Responde directamente a una notificacion del bot.'
        'O usa /codex <mensaje> para el hilo mas reciente de Codex.'
        'O usa /cursor <mensaje> para la conversacion mas reciente de Cursor.'
        'Usa /chats para listar los chats disponibles.'
    ) -join "`n"
}

function Build-ReplyBusyMessage {
    param(
        [object]$Config,
        [string]$ProjectDirectory,
        [string]$ThreadId
    )

    $projectName = Get-ProjectName -ProjectDirectory $ProjectDirectory
    $shortThreadId = if ([string]::IsNullOrWhiteSpace($ThreadId)) { 'sin-hilo' } elseif ($ThreadId.Length -gt 12) { $ThreadId.Substring(0, 12) } else { $ThreadId }

    return @(
        "$(Get-CodexPrefix -Config $Config): ese hilo sigue ocupado"
        "Proyecto: $projectName"
        "Hilo: $shortThreadId"
        'Espera a que llegue la respuesta actual antes de mandar otro mensaje a ese mismo hilo.'
    ) -join "`n"
}

function Build-AbortedNotificationMessage {
    param(
        [object]$Config,
        [string]$ProjectDirectory,
        [string]$ThreadId,
        [string]$TurnId,
        [string]$Reason
    )

    $projectName = Get-ProjectName -ProjectDirectory $ProjectDirectory
    $shortThreadId = if ([string]::IsNullOrWhiteSpace($ThreadId)) { 'sin-hilo' } elseif ($ThreadId.Length -gt 12) { $ThreadId.Substring(0, 12) } else { $ThreadId }
    $shortTurnId = if ([string]::IsNullOrWhiteSpace($TurnId)) { 'sin-turno' } elseif ($TurnId.Length -gt 12) { $TurnId.Substring(0, 12) } else { $TurnId }
    $reasonLabel = if ([string]::IsNullOrWhiteSpace($Reason)) { 'desconocido' } else { $Reason }

    return @(
        "$(Get-CodexPrefix -Config $Config): el turno se interrumpio"
        "Proyecto: $projectName"
        "Hilo: $shortThreadId"
        "Turno: $shortTurnId"
        "Motivo: $reasonLabel"
        'Puedes reenviar tu mensaje por Telegram cuando quieras.'
    ) -join "`n"
}

function Start-CodexBridgeProcess {
    param(
        [string]$ThreadId,
        [string]$MessageText
    )

    $messageBytes = [System.Text.Encoding]::UTF8.GetBytes($MessageText)
    $messageBase64 = [Convert]::ToBase64String($messageBytes)

    $process = Start-Process -FilePath $powershellPath -ArgumentList @(
        '-NoProfile',
        '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass',
        '-File', $bridgeScriptPath,
        '-ThreadId', $ThreadId,
        '-MessageBase64', $messageBase64
    ) -WindowStyle Hidden -WorkingDirectory $repoRoot -PassThru

    return $process.Id
}

function Start-CursorBridgeProcess {
    param(
        [string]$ConversationId,
        [string]$MessageText
    )

    $messageBytes = [System.Text.Encoding]::UTF8.GetBytes($MessageText)
    $messageBase64 = [Convert]::ToBase64String($messageBytes)

    $process = Start-Process -FilePath $powershellPath -ArgumentList @(
        '-NoProfile',
        '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass',
        '-File', $cursorBridgeScriptPath,
        '-ConversationId', $ConversationId,
        '-MessageBase64', $messageBase64,
        '-OpenInCursor'
    ) -WindowStyle Hidden -WorkingDirectory $repoRoot -PassThru

    return $process.Id
}

function Split-CommandArguments {
    param([string]$ArgumentsText)

    $argsText = $ArgumentsText.Trim()
    if ([string]::IsNullOrWhiteSpace($argsText)) {
        return [pscustomobject]@{ Token = ''; Remainder = '' }
    }

    $parts = $argsText -split '\s+', 2
    $token = $parts[0]
    $remainder = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    return [pscustomobject]@{ Token = $token; Remainder = $remainder }
}

function Test-CodexSelectorToken {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $false
    }

    if ($Token -match '^[cC]\d+$') {
        return $true
    }

    if ($Token -match '^[0-9a-fA-F]{8}') {
        return $true
    }

    return $false
}

function Test-CursorSelectorToken {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $false
    }

    if ($Token -match '^[uU]\d+$') {
        return $true
    }

    if ($Token -match '^[0-9a-fA-F]{8}') {
        return $true
    }

    return $false
}

function Resolve-CodexTarget {
    param(
        [object]$State,
        [string]$Token
    )

    $chats = Get-CodexChats -State $State
    if ($chats.Count -eq 0) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $chats[0]
    }

    if ($Token -match '^[cC](\d+)$') {
        $index = [int]$Matches[1] - 1
        if ($index -ge 0 -and $index -lt $chats.Count) {
            return $chats[$index]
        }
    }

    foreach ($entry in $chats) {
        if ($entry.threadId -like "$Token*") {
            return $entry
        }
    }

    return $null
}

function Resolve-CursorTarget {
    param([string]$Token)

    $chats = Get-CursorChats
    if ($chats.Count -eq 0) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $chats[0]
    }

    if ($Token -match '^[uU](\d+)$') {
        $index = [int]$Matches[1] - 1
        if ($index -ge 0 -and $index -lt $chats.Count) {
            return $chats[$index]
        }
    }

    foreach ($entry in $chats) {
        if ($entry.conversationId -like "$Token*") {
            return $entry
        }
    }

    return $null
}

function Resolve-CursorTargetFromReply {
    param([string]$MessageId)

    if ([string]::IsNullOrWhiteSpace($MessageId)) {
        return $null
    }

    $targets = Load-CursorNotificationTargets
    if (-not $targets.Contains($MessageId)) {
        return $null
    }

    $entry = $targets[$MessageId]
    return [pscustomobject]@{
        conversationId = [string](Get-PropertyValue -Object $entry -Name 'conversationId' -Default '')
        projectName    = [string](Get-PropertyValue -Object $entry -Name 'projectName' -Default 'sin-proyecto')
    }
}

function Get-TelegramReplyInstruction {
    param(
        [object]$State,
        [object]$Message
    )

    $text = [string](Get-PropertyValue -Object $Message -Name 'text' -Default '')
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $trimmedText = $text.Trim()
    if ($trimmedText -match '^/status(?:@\w+)?$') {
        return [pscustomobject]@{
            Kind = 'status'
        }
    }

    if ($trimmedText -match '^/chats(?:@\w+)?$') {
        return [pscustomobject]@{
            Kind = 'chats'
        }
    }

    if ($trimmedText -match '^/codex(?:@\w+)?$') {
        return [pscustomobject]@{
            Kind = 'chats'
        }
    }

    if ($trimmedText -match '^/codex(?:@\w+)?\s+([\s\S]+)$') {
        $argsText = $Matches[1].Trim()
        $split = Split-CommandArguments -ArgumentsText $argsText
        $targetToken = ''
        $messageText = $argsText
        if (Test-CodexSelectorToken -Token $split.Token -and -not [string]::IsNullOrWhiteSpace($split.Remainder)) {
            $targetToken = $split.Token
            $messageText = $split.Remainder
        }

        return [pscustomobject]@{
            Kind        = 'codex_message'
            Text        = $messageText
            TargetToken = $targetToken
            ThreadId         = ''
            ProjectDirectory = ''
            TurnId           = ''
        }
    }

    if ($trimmedText -match '^/cursor(?:@\w+)?$') {
        return [pscustomobject]@{
            Kind = 'chats'
        }
    }

    if ($trimmedText -match '^/cursor(?:@\w+)?\s+([\s\S]+)$') {
        $argsText = $Matches[1].Trim()
        $split = Split-CommandArguments -ArgumentsText $argsText
        $targetToken = ''
        $messageText = $argsText
        if (Test-CursorSelectorToken -Token $split.Token -and -not [string]::IsNullOrWhiteSpace($split.Remainder)) {
            $targetToken = $split.Token
            $messageText = $split.Remainder
        }

        return [pscustomobject]@{
            Kind        = 'cursor_message'
            Text        = $messageText
            TargetToken = $targetToken
        }
    }

    $replyToMessage = Get-PropertyValue -Object $Message -Name 'reply_to_message' -Default $null
    if ($null -ne $replyToMessage) {
        $replyMessageId = [string](Get-PropertyValue -Object $replyToMessage -Name 'message_id' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($replyMessageId) -and $State.notificationTargets.Contains($replyMessageId)) {
            $target = $State.notificationTargets[$replyMessageId]
            return [pscustomobject]@{
                Kind             = 'codex_message'
                Text             = $trimmedText
                ThreadId         = [string](Get-HashValue -Dictionary $target -Key 'threadId' -Default '')
                ProjectDirectory = [string](Get-HashValue -Dictionary $target -Key 'projectDirectory' -Default '')
                TurnId           = [string](Get-HashValue -Dictionary $target -Key 'turnId' -Default '')
            }
        }

        $cursorTarget = Resolve-CursorTargetFromReply -MessageId $replyMessageId
        if ($null -ne $cursorTarget) {
            return [pscustomobject]@{
                Kind           = 'cursor_message'
                Text           = $trimmedText
                ConversationId = [string]$cursorTarget.conversationId
                ProjectName    = [string]$cursorTarget.projectName
            }
        }
    }

    return $null
}

function Process-TelegramUpdate {
    param(
        [object]$State,
        [object]$Config,
        [object]$Update
    )

    $message = Get-PropertyValue -Object $Update -Name 'message' -Default $null
    if ($null -eq $message) {
        return $false
    }

    $from = Get-PropertyValue -Object $message -Name 'from' -Default $null
    if ((Get-BooleanValue -Object $from -Name 'is_bot' -Default $false)) {
        return $false
    }

    $chat = Get-PropertyValue -Object $message -Name 'chat' -Default $null
    $incomingChatId = [string](Get-PropertyValue -Object $chat -Name 'id' -Default '')
    $configuredChatId = Get-TelegramChatId -Config $Config
    if (-not [string]::IsNullOrWhiteSpace($configuredChatId) -and $incomingChatId -ne $configuredChatId) {
        return $false
    }

    $instruction = Get-TelegramReplyInstruction -State $State -Message $message
    if ($null -eq $instruction) {
        return $false
    }

    if ($instruction.Kind -eq 'status') {
        [void](Send-TelegramMessage -Config $Config -Message (Build-StatusMessage -Config $Config -State $State))
        return $false
    }

    if ($instruction.Kind -eq 'chats') {
        [void](Send-TelegramMessage -Config $Config -Message (Build-ChatsListMessage -Config $Config -State $State))
        return $false
    }

    if ($instruction.Kind -eq 'cursor_message') {
        if ([string]::IsNullOrWhiteSpace($instruction.Text)) {
            [void](Send-TelegramMessage -Config $Config -Message (Build-ReplyRoutingError -Config $Config))
            return $false
        }

        $conversationId = [string](Get-PropertyValue -Object $instruction -Name 'ConversationId' -Default '')
        $projectName = [string](Get-PropertyValue -Object $instruction -Name 'ProjectName' -Default '')
        if ([string]::IsNullOrWhiteSpace($conversationId)) {
            $target = Resolve-CursorTarget -Token ([string](Get-PropertyValue -Object $instruction -Name 'TargetToken' -Default ''))
            if ($null -eq $target) {
                [void](Send-TelegramMessage -Config $Config -Message 'Cursor: no encontre conversaciones disponibles. Usa /chats para verlas.')
                return $false
            }

            $conversationId = [string]$target.conversationId
            $projectName = [string]$target.projectName
        }

        try {
            $cursorBridgeId = Start-CursorBridgeProcess -ConversationId $conversationId -MessageText $instruction.Text
            [void](Send-TelegramMessage -Config $Config -Message (Build-CursorReplyAcknowledgement -Config $Config -ProjectName $projectName -ConversationId $conversationId -MessageText $instruction.Text))
            Write-Log "Telegram reply forwarded to Cursor conversation '$conversationId' using bridge PID $cursorBridgeId"
            return $true
        }
        catch {
            Write-Log "Failed to forward Cursor reply: $($_.Exception.Message)"
            [void](Send-TelegramMessage -Config $Config -Message 'Cursor: no pude enviar tu mensaje a la conversacion solicitada.')
            return $false
        }
    }

    if ($instruction.Kind -ne 'codex_message') {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($instruction.Text)) {
        [void](Send-TelegramMessage -Config $Config -Message (Build-ReplyRoutingError -Config $Config))
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($instruction.ThreadId)) {
        $target = Resolve-CodexTarget -State $State -Token ([string](Get-PropertyValue -Object $instruction -Name 'TargetToken' -Default ''))
        if ($null -eq $target) {
            [void](Send-TelegramMessage -Config $Config -Message (Build-ReplyRoutingError -Config $Config))
            return $false
        }

        $instruction.ThreadId = [string]$target.threadId
        $instruction.ProjectDirectory = [string]$target.projectDirectory
        $instruction.TurnId = ''
    }

    $activeBridge = Get-HashValue -Dictionary $State.activeBridgeThreads -Key $instruction.ThreadId -Default $null
    if ($null -ne $activeBridge) {
        $activeProjectDirectory = [string](Get-HashValue -Dictionary $activeBridge -Key 'projectDirectory' -Default $instruction.ProjectDirectory)
        [void](Send-TelegramMessage -Config $Config -Message (Build-ReplyBusyMessage -Config $Config -ProjectDirectory $activeProjectDirectory -ThreadId $instruction.ThreadId))
        Write-Log "Telegram reply deferred for thread '$($instruction.ThreadId)' because another bridge is already active"
        return $false
    }

    try {
        $bridgeProcessId = Start-CodexBridgeProcess -ThreadId $instruction.ThreadId -MessageText $instruction.Text
        Set-ActiveBridgeThread -State $State -ThreadId $instruction.ThreadId -ProjectDirectory $instruction.ProjectDirectory -MessageText $instruction.Text -BridgeProcessId $bridgeProcessId
        $ackResponse = Send-TelegramMessage -Config $Config -Message (Build-ReplyAcknowledgement -Config $Config -ProjectDirectory $instruction.ProjectDirectory -ThreadId $instruction.ThreadId -MessageText $instruction.Text)
        $changed = Register-TelegramTarget -State $State -TelegramResponse $ackResponse -ThreadId $instruction.ThreadId -TurnId $instruction.TurnId -ProjectDirectory $instruction.ProjectDirectory
        Update-LatestThread -State $State -ThreadId $instruction.ThreadId -TurnId $instruction.TurnId -ProjectDirectory $instruction.ProjectDirectory
        Write-Log "Telegram reply forwarded to thread '$($instruction.ThreadId)' using bridge PID $bridgeProcessId"
        return $true
    }
    catch {
        Write-Log "Failed to forward Telegram reply: $($_.Exception.Message)"
        [void](Clear-ActiveBridgeThread -State $State -ThreadId $instruction.ThreadId)
        [void](Send-TelegramMessage -Config $Config -Message 'Codex: no pude enviar tu mensaje al hilo solicitado.')
        return $false
    }
}

function Initialize-TelegramOffset {
    param(
        [object]$State,
        [object]$Config
    )

    if (-not (Get-BooleanValue -Object $Config -Name 'enableTelegramReplies' -Default $true)) {
        return $false
    }

    if ($null -ne $State.telegramOffset) {
        return $false
    }

    $response = Invoke-TelegramApi -Config $Config -Method 'getUpdates' -Body @{
        timeout         = 0
        allowed_updates = '["message"]'
    }

    if ($null -eq $response) {
        return $false
    }

    $updates = @()
    if ((Get-PropertyValue -Object $response -Name 'ok' -Default $false) -and $null -ne (Get-PropertyValue -Object $response -Name 'result' -Default $null)) {
        $updates = @($response.result)
    }

    if ($updates.Count -gt 0) {
        $maxUpdateId = ($updates | Measure-Object -Property update_id -Maximum).Maximum
        $State.telegramOffset = [int64]$maxUpdateId + 1
    }
    else {
        $State.telegramOffset = 0
    }

    Write-Log "Telegram offset initialized at $($State.telegramOffset)"
    return $true
}

function Process-TelegramUpdates {
    param(
        [object]$State,
        [object]$Config
    )

    if (-not (Get-BooleanValue -Object $Config -Name 'enableTelegramReplies' -Default $true)) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace((Get-TelegramBotToken -Config $Config))) {
        return $false
    }

    $changed = $false
    if (Initialize-TelegramOffset -State $State -Config $Config) {
        $changed = $true
    }

    $timeoutSeconds = [int](Get-PropertyValue -Object $Config -Name 'telegramPollTimeoutSeconds' -Default 1)
    if ($timeoutSeconds -lt 0) {
        $timeoutSeconds = 1
    }

    $response = Invoke-TelegramApi -Config $Config -Method 'getUpdates' -Body @{
        offset          = [string]$State.telegramOffset
        timeout         = $timeoutSeconds
        allowed_updates = '["message"]'
    }

    if ($null -eq $response) {
        return $changed
    }

    if (-not (Get-PropertyValue -Object $response -Name 'ok' -Default $false)) {
        return $changed
    }

    $updates = @($response.result)
    foreach ($update in $updates) {
        $updateId = [int64](Get-PropertyValue -Object $update -Name 'update_id' -Default 0)
        if ((Process-TelegramUpdate -State $State -Config $Config -Update $update)) {
            $changed = $true
        }

        $State.telegramOffset = $updateId + 1
        $changed = $true
    }

    return $changed
}

function Send-TestNotification {
    param(
        [object]$Config,
        [string]$Status
    )

    $label = if ($Status -eq 'waiting') { 'Codex espera tu respuesta' } else { 'Codex termino la tarea' }
    $sampleBody = @(
        'Esta es una prueba manual del watcher de Codex.'
        'Si la respuesta real es larga, ahora se enviara completa en varios mensajes de Telegram.'
        'Tambien puedes responderle al bot directamente desde Telegram para reactivar el hilo mas reciente.'
    ) -join "`n`n"

    $messages = Build-NotificationMessages -Config $Config -Event ([pscustomobject]@{ timestamp = (Get-Date).ToString('o') }) -State ([pscustomobject]@{ Label = $label }) -ProjectDirectory $repoRoot -ThreadId 'prueba-hilo-manual' -TurnId 'prueba-turno-manual' -LastAgentMessage $sampleBody
    [void](Send-TelegramMessagesAndTrack -Config $Config -State (New-EmptyState) -Messages $messages -ThreadId 'prueba-hilo-manual' -TurnId 'prueba-turno-manual' -ProjectDirectory $repoRoot)
    Write-Log "Manual test notification sent for state '$Status'"
}

function Process-CodexEntry {
    param(
        [object]$State,
        [object]$Config,
        [string]$FilePath,
        [object]$FileState,
        [object]$Entry
    )

    $changed = $false
    if ($null -eq $Entry) {
        return $changed
    }

    if ($Entry.type -eq 'session_meta') {
        $threadId = [string](Get-PropertyValue -Object $Entry.payload -Name 'id' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($threadId)) {
            $FileState['threadId'] = $threadId
            $changed = $true
        }

        return $changed
    }

    if ($Entry.type -eq 'turn_context') {
        $turnId = [string](Get-PropertyValue -Object $Entry.payload -Name 'turn_id' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($turnId)) {
            $threadId = [string](Get-HashValue -Dictionary $FileState -Key 'threadId' -Default (Get-ThreadIdFromFilePath -FilePath $FilePath))
            $State.turnContexts[$turnId] = [ordered]@{
                cwd       = [string](Get-PropertyValue -Object $Entry.payload -Name 'cwd' -Default '')
                timestamp = [string](Get-PropertyValue -Object $Entry -Name 'timestamp' -Default '')
                threadId  = $threadId
            }
            $changed = $true
        }

        return $changed
    }

    if ($Entry.type -ne 'event_msg') {
        return $changed
    }

    $eventType = [string](Get-PropertyValue -Object $Entry.payload -Name 'type' -Default '')
    if (($eventType -ne 'task_started') -and ($eventType -ne 'task_complete') -and ($eventType -ne 'turn_aborted')) {
        return $changed
    }

    $turnId = [string](Get-PropertyValue -Object $Entry.payload -Name 'turn_id' -Default '')
    if ([string]::IsNullOrWhiteSpace($turnId)) {
        return $changed
    }

    $threadId = [string](Get-HashValue -Dictionary $FileState -Key 'threadId' -Default (Get-ThreadIdFromFilePath -FilePath $FilePath))
    if ($eventType -eq 'task_started') {
        if (Bind-ActiveBridgeThreadTurn -State $State -ThreadId $threadId -TurnId $turnId -ObservedAt ([string]$Entry.timestamp)) {
            Write-Log "Bound active bridge thread '$threadId' to turn '$turnId'"
            return $true
        }

        return $changed
    }

    $eventId = '{0}|{1}|{2}|{3}' -f $FilePath, $eventType, $turnId, [string]$Entry.timestamp
    if ($State.processedEventIds.Contains($eventId)) {
        return $changed
    }

    $context = Get-HashValue -Dictionary $State.turnContexts -Key $turnId -Default $null
    $projectDirectory = [string](Get-HashValue -Dictionary $context -Key 'cwd' -Default '')
    $threadId = [string](Get-HashValue -Dictionary $context -Key 'threadId' -Default $threadId)

    switch ($eventType) {
        'task_complete' {
            $lastAgentMessage = [string](Get-PropertyValue -Object $Entry.payload -Name 'last_agent_message' -Default '')
            $notificationState = Resolve-CodexCompletionState -Message $lastAgentMessage
            [void](Clear-ActiveBridgeThread -State $State -ThreadId $threadId -TurnId $turnId)

            if (Should-SendNotification -Config $Config -State $notificationState) {
                $messages = Build-NotificationMessages -Config $Config -Event $Entry -State $notificationState -ProjectDirectory $projectDirectory -ThreadId $threadId -TurnId $turnId -LastAgentMessage $lastAgentMessage
                if (Send-TelegramMessagesAndTrack -Config $Config -State $State -Messages $messages -ThreadId $threadId -TurnId $turnId -ProjectDirectory $projectDirectory) {
                    $changed = $true
                }

                Write-Log "Notification handled for state '$($notificationState.Status)' and turn '$turnId'"
            }
            else {
                Write-Log "Notification skipped by config for state '$($notificationState.Status)' and turn '$turnId'"
            }
        }
        'turn_aborted' {
            $reason = [string](Get-PropertyValue -Object $Entry.payload -Name 'reason' -Default '')
            $hadActiveBridge = Clear-ActiveBridgeThread -State $State -ThreadId $threadId -TurnId $turnId
            if ($hadActiveBridge) {
                $response = Send-TelegramMessage -Config $Config -Message (Build-AbortedNotificationMessage -Config $Config -ProjectDirectory $projectDirectory -ThreadId $threadId -TurnId $turnId -Reason $reason)
                if (Register-TelegramTarget -State $State -TelegramResponse $response -ThreadId $threadId -TurnId $turnId -ProjectDirectory $projectDirectory) {
                    $changed = $true
                }

                Write-Log "Aborted bridge turn '$turnId' detected for thread '$threadId' with reason '$reason'"
            }
            else {
                Write-Log "Observed aborted turn '$turnId' for thread '$threadId' with reason '$reason'"
            }
        }
    }

    $State.processedEventIds[$eventId] = [string]$Entry.timestamp
    Update-LatestThread -State $State -ThreadId $threadId -TurnId $turnId -ProjectDirectory $projectDirectory
    $changed = $true
    return $changed
}

$mutex = $null
$mutexAcquired = $false

try {
    $config = Get-TelegramConfig
    if ($null -eq $config) {
        exit 0
    }

    if (-not (Get-BooleanValue -Object $config -Name 'enabled' -Default $true)) {
        Write-Log 'Notifications are disabled in config'
        exit 0
    }

    if ($TestFinished) {
        Send-TestNotification -Config $config -Status 'finished'
        exit 0
    }

    if ($TestWaiting) {
        Send-TestNotification -Config $config -Status 'waiting'
        exit 0
    }

    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $mutexAcquired = $mutex.WaitOne(0, $false)
    if (-not $mutexAcquired) {
        Write-Log 'Another Codex watcher instance is already running'
        exit 0
    }

    $state = Load-State
    Bootstrap-State -State $state
    Save-State -State $state
    Write-Log "Codex watcher started. Sessions root: $codexSessionsRoot"

    while ($true) {
        $stateChanged = $false
        $files = Get-RecentSessionFiles

        foreach ($file in $files) {
            Ensure-TrackedFile -State $state -File $file
            $fileState = $state.files[$file.FullName]
            $offset = [long](Get-HashValue -Dictionary $fileState -Key 'offset' -Default 0)
            $readResult = Read-AppendedContent -Path $file.FullName -Offset $offset
            $splitResult = Split-JsonLines -Text $readResult.Text -Remainder ([string](Get-HashValue -Dictionary $fileState -Key 'remainder' -Default ''))

            $fileState['offset'] = [long]$readResult.NewOffset
            $fileState['remainder'] = [string]$splitResult.Remainder
            $fileState['lastSeenUtc'] = (Get-Date).ToUniversalTime().ToString('o')
            $stateChanged = $true

            foreach ($line in $splitResult.Lines) {
                try {
                    $entry = $line | ConvertFrom-Json
                }
                catch {
                    Write-Log "Skipping invalid JSONL line from $($file.FullName): $($_.Exception.Message)"
                    continue
                }

                if (Process-CodexEntry -State $state -Config $config -FilePath $file.FullName -FileState $fileState -Entry $entry) {
                    $stateChanged = $true
                }
            }
        }

        if (Sync-ActiveBridgeThreads -State $state -Config $config) {
            $stateChanged = $true
        }

        if (Process-TelegramUpdates -State $state -Config $config) {
            $stateChanged = $true
        }

        if ($stateChanged) {
            Save-State -State $state
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }
}
catch {
    Write-Log "Unhandled error: $($_.Exception.Message)"
    exit 0
}
finally {
    if ($mutexAcquired -and $null -ne $mutex) {
        $mutex.ReleaseMutex() | Out-Null
    }

    if ($null -ne $mutex) {
        $mutex.Dispose()
    }
}
