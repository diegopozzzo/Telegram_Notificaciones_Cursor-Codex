[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$notifierPath = (Resolve-Path (Join-Path $scriptRoot 'notify-cursor-stop.ps1')).Path
$cursorDirectory = Join-Path $HOME '.cursor'
$hooksPath = Join-Path $cursorDirectory 'hooks.json'
$backupPath = Join-Path $cursorDirectory ("hooks.backup.{0}.json" -f (Get-Date -Format 'yyyyMMddHHmmss'))
$hookCommand = 'powershell -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $notifierPath

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

if (-not (Test-Path $cursorDirectory)) {
    New-Item -ItemType Directory -Force -Path $cursorDirectory | Out-Null
}

if (Test-Path $hooksPath) {
    $existingContent = Get-Content -Path $hooksPath -Raw -Encoding UTF8
    $hooksConfig = ConvertTo-NativeObject -InputObject ($existingContent | ConvertFrom-Json)
    Copy-Item -Path $hooksPath -Destination $backupPath -Force
}
else {
    $hooksConfig = [ordered]@{
        version = 1
        hooks   = [ordered]@{}
    }
}

if (-not $hooksConfig.Contains('version')) {
    $hooksConfig['version'] = 1
}

if (-not $hooksConfig.Contains('hooks')) {
    $hooksConfig['hooks'] = [ordered]@{}
}

$stopHooks = @()
if ($hooksConfig.hooks.Contains('stop')) {
    $stopHooks = @($hooksConfig.hooks.stop)
}

$existingHook = $null
foreach ($hook in $stopHooks) {
    if ($hook.command -eq $hookCommand) {
        $existingHook = $hook
        break
    }
}

if ($null -eq $existingHook) {
    $stopHooks += [ordered]@{
        command = $hookCommand
        timeout = 20
    }
}

$hooksConfig.hooks['stop'] = $stopHooks

$json = $hooksConfig | ConvertTo-Json -Depth 12
Set-Content -Path $hooksPath -Value $json -Encoding UTF8

Write-Output "Hook instalado en $hooksPath"
if (Test-Path $backupPath) {
    Write-Output "Backup creado en $backupPath"
}
