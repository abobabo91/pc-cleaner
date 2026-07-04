# Diagnose: check current state of every registry key in data/privacy_keys.json.
# Read-only. No admin needed. Emits JSON to stdout.

param(
    [string]$DataDir = (Join-Path $PSScriptRoot '..\..\data')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')

$data = (Get-Content (Join-Path $DataDir 'privacy_keys.json') -Raw | ConvertFrom-Json)

$rows = foreach ($k in $data.keys) {
    $current = $null
    $pathExists = Test-Path $k.path
    if ($pathExists) {
        $item = Get-ItemProperty -Path $k.path -Name $k.name -ErrorAction SilentlyContinue
        if ($item) { $current = $item.$($k.name) }
    }
    $needsChange = ($current -ne $k.value)
    [PSCustomObject]@{
        Category    = $k.category
        Path        = $k.path
        Name        = $k.name
        TargetValue = $k.value
        Current     = $current
        PathExists  = $pathExists
        NeedsChange = $needsChange
        Note        = $k.note
    }
}

$summary = @{
    total       = $rows.Count
    needsChange = @($rows | Where-Object NeedsChange).Count
    byCategory  = ($rows | Group-Object Category | ForEach-Object { @{ $_.Name = $_.Count } })
}

[PSCustomObject]@{
    profile       = Get-MachineProfile
    summary       = $summary
    keys          = $rows
    applySilently = $data.notes.apply_silently
    askUser       = $data.notes.ask_user
} | ConvertTo-Json -Depth 6
