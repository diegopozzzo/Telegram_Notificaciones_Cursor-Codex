[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$watcherPath = (Resolve-Path (Join-Path $scriptRoot 'watch-codex-sessions.ps1')).Path
$powershellPath = Join-Path $PSHOME 'powershell.exe'
$mutexName = 'Global\CodexTelegramWatcher'

function Test-WatcherMutex {
    $mutex = $null

    try {
        $mutex = [System.Threading.Mutex]::OpenExisting($mutexName)
        return $true
    }
    catch [System.Threading.WaitHandleCannotBeOpenedException] {
        return $false
    }
    finally {
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

function Get-RunningWatcherProcess {
    $escapedPath = [Regex]::Escape($watcherPath)

    return @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object {
            $_.CommandLine -match '-File' -and
            $_.CommandLine -match $escapedPath
        })
}

$running = Get-RunningWatcherProcess
if ((Test-WatcherMutex) -or $running.Count -gt 0) {
    Write-Output 'Watcher de Codex ya estaba activo.'
    if ($running.Count -gt 0) {
        $running | Select-Object ProcessId,CommandLine | Format-List | Out-String | Write-Output
    }
    exit 0
}

Start-Process -FilePath $powershellPath -ArgumentList @(
    '-NoProfile',
    '-WindowStyle', 'Hidden',
    '-ExecutionPolicy', 'Bypass',
    '-File', $watcherPath
) -WindowStyle Hidden

for ($attempt = 0; $attempt -lt 10; $attempt++) {
    Start-Sleep -Seconds 1
    $running = Get-RunningWatcherProcess
    if ((Test-WatcherMutex) -or $running.Count -gt 0) {
        Write-Output 'Watcher de Codex iniciado.'
        if ($running.Count -gt 0) {
            $running | Select-Object ProcessId,CommandLine | Format-List | Out-String | Write-Output
        }
        exit 0
    }
}

throw 'No se pudo iniciar el watcher de Codex.'
