[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConversationId,

    [string]$MessageText,

    [string]$MessageBase64,

    [switch]$OpenInCursor
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptRoot '..')).Path
$logDirectory = Join-Path $repoRoot 'logs'
$logPath = Join-Path $logDirectory 'cursor-telegram-bridge.log'
$cursorChatsPath = Join-Path $logDirectory 'cursor-chats.json'
$cursorExe = (Get-Command cursor -ErrorAction Stop).Source

function Write-Log {
    param([string]$Message)

    if (-not (Test-Path $logDirectory)) {
        New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    [System.IO.File]::AppendAllText($logPath, "[$timestamp] $Message`r`n", [System.Text.Encoding]::UTF8)
}

function Get-MessageText {
    if (-not [string]::IsNullOrWhiteSpace($MessageText)) {
        return $MessageText
    }

    if (-not [string]::IsNullOrWhiteSpace($MessageBase64)) {
        try {
            $bytes = [Convert]::FromBase64String($MessageBase64)
            return [System.Text.Encoding]::UTF8.GetString($bytes)
        }
        catch {
            throw "No se pudo decodificar MessageBase64: $($_.Exception.Message)"
        }
    }

    throw 'Se requiere MessageText o MessageBase64.'
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
        Write-Log "Cursor chats invalid: $($_.Exception.Message)"
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

function Test-ValidPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $invalidChars = [System.IO.Path]::GetInvalidPathChars()
    if ($Path.IndexOfAny($invalidChars) -ge 0) {
        return $false
    }

    return $true
}

$message = Get-MessageText
$map = Load-CursorChatMap
if (-not $map.Contains($ConversationId)) {
    throw "No se encontro la conversacion '$ConversationId'."
}

$chat = $map[$ConversationId]
$workspaceRoots = @()
if ($null -ne $chat) {
    $rootsValue = $chat.workspaceRoots
    if ($rootsValue -is [string]) {
        $workspaceRoots = @($rootsValue)
    }
    elseif ($null -ne $rootsValue) {
        $workspaceRoots = @($rootsValue)
    }
}

$normalizedRoots = @()
foreach ($root in $workspaceRoots) {
    $normalized = Normalize-WorkspaceRoot -Root ([string]$root)
    if (-not [string]::IsNullOrWhiteSpace($normalized)) {
        $normalizedRoots += $normalized
    }
}

$targetRoot = ''
foreach ($root in $normalizedRoots) {
    if (-not (Test-ValidPath -Path $root)) {
        continue
    }

    if (Test-Path -LiteralPath $root) {
        $targetRoot = $root
        break
    }
}

if ([string]::IsNullOrWhiteSpace($targetRoot)) {
    $targetRoot = $repoRoot
}

$inboxDir = Join-Path $targetRoot '.cursor-telegram'
if (-not (Test-Path $inboxDir)) {
    New-Item -ItemType Directory -Force -Path $inboxDir | Out-Null
}

$fileName = "telegram-reply-$ConversationId.txt"
$targetPath = Join-Path $inboxDir $fileName
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$payload = "[$timestamp] $message`r`n"
[System.IO.File]::AppendAllText($targetPath, $payload, [System.Text.Encoding]::UTF8)

Write-Log "Cursor message stored at $targetPath for conversation '$ConversationId'."

if ($OpenInCursor) {
    try {
        Start-Process -FilePath $cursorExe -ArgumentList @('-r', $targetPath) -WindowStyle Hidden | Out-Null
        Write-Log "Cursor opened $targetPath."
    }
    catch {
        Write-Log "Cursor open failed: $($_.Exception.Message)"
    }
}
