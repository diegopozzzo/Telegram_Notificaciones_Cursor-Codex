[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ThreadId,

    [string]$MessageBase64,

    [int]$TimeoutMinutes = 30
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptRoot '..')).Path
$logDirectory = Join-Path $repoRoot 'logs'
$logPath = Join-Path $logDirectory 'codex-telegram-bridge.log'
$fallbackLogPath = Join-Path $logDirectory 'codex-telegram-bridge-fallback.log'
$codexCommand = (Get-Command codex -ErrorAction Stop).Source
$logMutexName = 'Global\CodexTelegramBridgeLog'
$safeThreadId = ($ThreadId -replace '[^A-Za-z0-9]', '_')
$threadMutexName = "Global\CodexTelegramBridgeThread_$safeThreadId"
$utf8Encoding = [System.Text.UTF8Encoding]::new($false)
$script:BridgeObservedTurnStarted = $false
$script:BridgeObservedTurnCompleted = $false
$script:BridgeObservedFinalMessage = $false

function Append-LogLine {
    param(
        [string]$Path,
        [string]$Line
    )

    [System.IO.File]::AppendAllText($Path, "$Line`r`n", $utf8Encoding)
}

function Write-Log {
    param([string]$Message)

    if (-not (Test-Path $logDirectory)) {
        New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    }

    $mutex = $null
    $mutexAcquired = $false

    try {
        $mutex = New-Object System.Threading.Mutex($false, $logMutexName)
        $mutexAcquired = $mutex.WaitOne(5000, $false)

        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $line = "[$timestamp] $Message"

        for ($attempt = 0; $attempt -lt 5; $attempt++) {
            try {
                Append-LogLine -Path $logPath -Line $line
                return
            }
            catch {
                Start-Sleep -Milliseconds 150
            }
        }

        try {
            Append-LogLine -Path $fallbackLogPath -Line $line
        }
        catch {
        }
    }
    finally {
        if ($mutexAcquired -and $null -ne $mutex) {
            $mutex.ReleaseMutex() | Out-Null
        }

        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

function Get-MessageText {
    if (-not [string]::IsNullOrWhiteSpace($MessageBase64)) {
        try {
            $bytes = [Convert]::FromBase64String($MessageBase64)
            return [System.Text.Encoding]::UTF8.GetString($bytes)
        }
        catch {
            throw "No se pudo decodificar MessageBase64: $($_.Exception.Message)"
        }
    }

    throw 'Se requiere MessageBase64.'
}

function Get-PreviewText {
    param(
        [string]$Text,
        [int]$MaxLength = 160
    )

    $normalized = ($Text -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return ''
    }

    if ($normalized.Length -le $MaxLength) {
        return $normalized
    }

    return $normalized.Substring(0, $MaxLength - 3) + '...'
}

function Get-WorkspaceAliasPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    $aliasRoot = Join-Path $env:LOCALAPPDATA 'CodexBridgeWorkspaces'
    if (-not (Test-Path $aliasRoot)) {
        New-Item -ItemType Directory -Force -Path $aliasRoot | Out-Null
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Path))
    }
    finally {
        $sha256.Dispose()
    }

    $hashText = [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
    $aliasPath = Join-Path $aliasRoot ("workspace-" + $hashText.Substring(0, 12))

    if (-not (Test-Path $aliasPath)) {
        New-Item -ItemType Junction -Path $aliasPath -Target $Path | Out-Null
        Write-Log "Workspace alias created for bridge: $aliasPath -> $Path"
    }

    return $aliasPath
}

function Handle-StdoutLine {
    param(
        [string]$ThreadId,
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return
    }

    try {
        $event = $Line | ConvertFrom-Json
    }
    catch {
        Write-Log "stdout: $(Get-PreviewText -Text $Line -MaxLength 220)"
        return
    }

    $eventType = [string]$event.type
    switch ($eventType) {
        'thread.started' {
            $startedThreadId = [string]$event.thread_id
            if (-not [string]::IsNullOrWhiteSpace($startedThreadId)) {
                Write-Log "Thread '$startedThreadId' resumed for Telegram bridge."
            }
        }
        'turn.started' {
            $script:BridgeObservedTurnStarted = $true
            Write-Log "Turn started for thread '$ThreadId'."
        }
        'item.started' {
            $item = $event.item
            if ([string]$item.type -eq 'command_execution') {
                $commandPreview = Get-PreviewText -Text ([string]$item.command) -MaxLength 220
                Write-Log "Command started for thread '$ThreadId': $commandPreview"
            }
        }
        'item.completed' {
            $item = $event.item
            switch ([string]$item.type) {
                'command_execution' {
                    $commandPreview = Get-PreviewText -Text ([string]$item.command) -MaxLength 160
                    Write-Log "Command completed for thread '$ThreadId' with exit code $($item.exit_code): $commandPreview"
                }
                'agent_message' {
                    $messagePreview = Get-PreviewText -Text ([string]$item.text) -MaxLength 220
                    if (-not [string]::IsNullOrWhiteSpace($messagePreview)) {
                        Write-Log "Agent message preview for thread '$ThreadId': $messagePreview"
                    }
                }
            }
        }
        'turn.completed' {
            $script:BridgeObservedTurnCompleted = $true
            Write-Log "Turn completed for thread '$ThreadId'."
        }
    }
}

$messageText = Get-MessageText
$messagePreview = Get-PreviewText -Text $messageText -MaxLength 120
$messageHash = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ThreadId)).TrimEnd('=').Replace('+', '_').Replace('/', '-')
$promptPath = Join-Path $logDirectory ("bridge-prompt-$messageHash.txt")
$stdoutPath = Join-Path $logDirectory ("bridge-stdout-$messageHash.jsonl")
$stderrPath = Join-Path $logDirectory ("bridge-stderr-$messageHash.log")
$outputPath = Join-Path $logDirectory ("bridge-last-message-$ThreadId.txt")
$bridgeWorkspacePath = Get-WorkspaceAliasPath -Path $repoRoot
$threadMutex = $null
$threadMutexAcquired = $false
$cleanupArtifacts = $false

try {
    if (-not (Test-Path $logDirectory)) {
        New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    }

    $threadMutex = New-Object System.Threading.Mutex($false, $threadMutexName)
    $threadMutexAcquired = $threadMutex.WaitOne(0, $false)
    if (-not $threadMutexAcquired) {
        Write-Log "Bridge skipped for thread '$ThreadId' because another bridge is already active."
        exit 2
    }

    Set-Content -Path $promptPath -Value $messageText -Encoding UTF8
    Set-Content -Path $stdoutPath -Value '' -Encoding UTF8
    Set-Content -Path $stderrPath -Value '' -Encoding UTF8
    if (Test-Path $outputPath) {
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Bridge starting for thread '$ThreadId'. Message preview: $messagePreview"

    Push-Location $repoRoot
    try {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        Get-Content -Path $promptPath -Raw -Encoding UTF8 |
            & $codexCommand exec -C $bridgeWorkspacePath resume $ThreadId - --json --dangerously-bypass-approvals-and-sandbox -o $outputPath 1> $stdoutPath 2> $stderrPath
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Pop-Location
    }

    if (Test-Path $stdoutPath) {
        foreach ($line in (Get-Content -Path $stdoutPath -Encoding UTF8)) {
            Handle-StdoutLine -ThreadId $ThreadId -Line $line
        }
    }

    if (Test-Path $stderrPath) {
        foreach ($line in (Get-Content -Path $stderrPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            Write-Log "stderr: $(Get-PreviewText -Text $line -MaxLength 220)"
        }
    }

    if ($exitCode -ne 0) {
        throw "Codex exec finalizo con ExitCode=$exitCode."
    }

    if (Test-Path $outputPath) {
        $finalMessage = Get-Content -Path $outputPath -Raw -Encoding UTF8
        $finalPreview = Get-PreviewText -Text $finalMessage -MaxLength 220
        if (-not [string]::IsNullOrWhiteSpace($finalPreview)) {
            $script:BridgeObservedFinalMessage = $true
            Write-Log "Final response preview for thread '$ThreadId': $finalPreview"
        }
    }

    if (-not $script:BridgeObservedTurnStarted -and -not $script:BridgeObservedFinalMessage) {
        throw 'Codex exec finalizo sin crear un turno ni una respuesta final.'
    }

    Write-Log "Bridge finished successfully for thread '$ThreadId'. Timeout budget was $TimeoutMinutes minute(s)."
    $cleanupArtifacts = $true
}
catch {
    $stderrPreview = ''
    if (Test-Path $stderrPath) {
        $stderrTail = Get-Content -Path $stderrPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 8
        if ($stderrTail) {
            $stderrPreview = Get-PreviewText -Text ($stderrTail -join ' ') -MaxLength 220
        }
    }

    $artifactSummary = "stdout=$stdoutPath; stderr=$stderrPath; prompt=$promptPath"
    if ([string]::IsNullOrWhiteSpace($stderrPreview)) {
        Write-Log "Bridge error for thread '$ThreadId': $($_.Exception.Message). Artefactos preservados en $artifactSummary"
    }
    else {
        Write-Log "Bridge error for thread '$ThreadId': $($_.Exception.Message). stderr: $stderrPreview. Artefactos preservados en $artifactSummary"
    }
    throw
}
finally {
    if ($cleanupArtifacts) {
        foreach ($tempPath in @($promptPath, $stdoutPath, $stderrPath)) {
            if (Test-Path $tempPath) {
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($threadMutexAcquired -and $null -ne $threadMutex) {
        $threadMutex.ReleaseMutex() | Out-Null
    }

    if ($null -ne $threadMutex) {
        $threadMutex.Dispose()
    }
}
