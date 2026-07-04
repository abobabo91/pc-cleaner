# Diagnose: check Win11 explorer UI tweaks against target values.
# Read-only. No admin needed. Emits JSON to stdout.

param(
    [string]$DataDir = (Join-Path $PSScriptRoot '..\..\data')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')

$explorerKeys = Join-Path $DataDir 'explorer_keys.json'
$conflictsFile = Join-Path $DataDir 'explorer_conflicts.json'
if (-not (Test-Path $explorerKeys)) {
    [PSCustomObject]@{ error = "explorer_keys.json not found"; expected = $explorerKeys } | ConvertTo-Json
    exit 0
}
$data = Get-Content $explorerKeys -Raw | ConvertFrom-Json

# Detect conflicts (StartAllBack, ExplorerPatcher, etc.)
$conflicts = @()
if (Test-Path $conflictsFile) {
    $confData = Get-Content $conflictsFile -Raw | ConvertFrom-Json
    $installed = Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*, HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*, HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } | Select-Object -ExpandProperty DisplayName
    foreach ($appName in $confData.installedAppNames) {
        if ($installed -match [regex]::Escape($appName)) { $conflicts += $appName }
    }
    foreach ($procName in $confData.runningProcesses) {
        if (Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($procName)) -ErrorAction SilentlyContinue) {
            $conflicts += $procName
        }
    }
}

$rows = foreach ($k in $data.keys) {
    $current = $null
    $pathExists = Test-Path $k.path
    if ($pathExists) {
        $item = Get-ItemProperty -Path $k.path -Name $k.name -ErrorAction SilentlyContinue
        if ($item) { $current = $item.$($k.name) }
    }
    $needsChange = ($current -ne $k.value) -and ([string]$current -ne [string]$k.value)
    [PSCustomObject]@{
        Category    = $k.category
        Path        = $k.path
        Name        = $k.name
        TargetValue = $k.value
        Type        = $k.type
        Current     = $current
        PathExists  = $pathExists
        NeedsChange = $needsChange
        Note        = $k.note
    }
}

$summary = @{
    total          = $rows.Count
    needsChange    = @($rows | Where-Object NeedsChange).Count
    conflicts      = $conflicts
    conflictAction = if ($conflicts) { $confData.action } else { $null }
    byCategory     = ($rows | Group-Object Category | ForEach-Object { @{ $_.Name = $_.Count } })
}

[PSCustomObject]@{
    profile       = Get-MachineProfile
    summary       = $summary
    keys          = $rows
    applySilently = if ($data.notes) { $data.notes.apply_silently } else { @() }
    askUser       = if ($data.notes) { $data.notes.ask_user } else { @() }
} | ConvertTo-Json -Depth 6
