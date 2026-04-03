[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$watcherPath = (Resolve-Path (Join-Path $scriptRoot 'watch-codex-sessions.ps1')).Path
$starterPath = (Resolve-Path (Join-Path $scriptRoot 'start-codex-watcher.ps1')).Path
$powershellPath = Join-Path $PSHOME 'powershell.exe'
$runRegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runEntryName = 'CodexTelegramWatcher'
$runCommand = '"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}"' -f $powershellPath, $starterPath
$startupDirectory = [Environment]::GetFolderPath('Startup')
$startupLauncherPath = Join-Path $startupDirectory 'Codex Telegram Watcher.vbs'

function Install-StartupLauncher {
    $escapedStarterPath = $starterPath.Replace('"', '""')
    $launcherContent = @"
' Codex Telegram Watcher launcher
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$escapedStarterPath""", 0, False
"@

    Set-Content -Path $startupLauncherPath -Value $launcherContent -Encoding Unicode
}

function Install-RunEntry {
    if (-not (Test-Path $runRegistryPath)) {
        New-Item -Path $runRegistryPath -Force | Out-Null
    }

    New-ItemProperty -Path $runRegistryPath -Name $runEntryName -PropertyType String -Value $runCommand -Force | Out-Null
}

$installedMode = $null

try {
    Install-RunEntry
    if (Test-Path $startupLauncherPath) {
        Remove-Item -Path $startupLauncherPath -Force
    }
    $installedMode = 'run-registry'
}
catch {
    Install-StartupLauncher
    $installedMode = 'startup-folder'
}

& $powershellPath -NoProfile -ExecutionPolicy Bypass -File $starterPath | Out-Null

if ($installedMode -eq 'run-registry') {
    Write-Output "Watcher de Codex instalado como aplicacion de arranque en '$runRegistryPath\\$runEntryName'."
}
else {
    Write-Output "Watcher de Codex instalado con fallback en la carpeta de Inicio en '$startupLauncherPath'."
}

Write-Output 'Se inició una instancia en segundo plano para esta sesión.'
Write-Output 'Si reinicias Windows, volverá a arrancar solo.'
