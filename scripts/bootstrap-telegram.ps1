[CmdletBinding()]
param(
    [switch]$EnableCursorHook
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptRoot '..')).Path
$configExamplePath = Join-Path $repoRoot 'config\telegram.settings.example.json'
$configPath = Join-Path $repoRoot 'config\telegram.settings.json'
$installWatcherPath = (Resolve-Path (Join-Path $scriptRoot 'install-codex-watcher.ps1')).Path
$installCursorHookPath = (Resolve-Path (Join-Path $scriptRoot 'install-cursor-hook.ps1')).Path
$powershellPath = Join-Path $PSHOME 'powershell.exe'

function Ensure-ConfigFile {
    if (Test-Path $configPath) {
        return
    }

    if (-not (Test-Path $configExamplePath)) {
        throw "No se encontro el archivo de ejemplo en '$configExamplePath'."
    }

    Copy-Item -Path $configExamplePath -Destination $configPath -Force
    throw "Se creo '$configPath'. Editalo con tu botToken y chatId, y vuelve a ejecutar este script."
}

function Get-Config {
    return (Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Test-PlaceholderValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $true
    }

    return ($Value -like 'PON_AQUI_*')
}

Ensure-ConfigFile
$config = Get-Config

if (Test-PlaceholderValue -Value ([string]$config.botToken)) {
    throw "Configura 'botToken' en '$configPath' antes de activar el proyecto."
}

if (Test-PlaceholderValue -Value ([string]$config.chatId)) {
    throw "Configura 'chatId' en '$configPath' antes de activar el proyecto."
}

& $powershellPath -NoProfile -ExecutionPolicy Bypass -File $installWatcherPath

if ($EnableCursorHook) {
    & $powershellPath -NoProfile -ExecutionPolicy Bypass -File $installCursorHookPath
}

Write-Output ''
Write-Output 'Proyecto activado.'
Write-Output 'Comandos utiles en Telegram: /status, /chats, /codex <mensaje>, /cursor <mensaje>'
if (-not $EnableCursorHook) {
    Write-Output 'Si tambien quieres notificaciones de Cursor, ejecuta este script con -EnableCursorHook.'
}
