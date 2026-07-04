# Diagnose: enumerate current tray icon promotion state + pinned taskbar apps.
# Read-only. No admin. The pin blob is undocumented so this is best-effort.

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')

# 1. Tray icon promotion (which are always visible vs hidden)
# The blob at HKCU\...\NotifyIconSettings tracks each icon's IsPromoted state.
$trayIcons = @()
$key = 'HKCU:\Control Panel\NotifyIconSettings'
if (Test-Path $key) {
    Get-ChildItem $key | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath
        $trayIcons += [PSCustomObject]@{
            ExecutablePath = $p.ExecutablePath
            IsPromoted     = [bool]$p.IsPromoted
            LastPromoted   = if ($p.LastPromotedTime) { $p.LastPromotedTime } else { $null }
            ToolTip        = $p.Tooltip
        }
    }
}

# 2. Pinned taskbar apps (Windows 11 modern pin store)
# The pinned list lives in ImplicitAppShortcuts + FavoritesResolve, formats change between builds.
# Best-effort read: enumerate shortcuts under user's Taskbar\PinnedItems folder.
$pinnedFolder = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
$pinnedApps = @()
if (Test-Path $pinnedFolder) {
    Get-ChildItem $pinnedFolder -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $sc = $shell.CreateShortcut($_.FullName)
            $pinnedApps += [PSCustomObject]@{
                LinkName   = $_.BaseName
                Target     = $sc.TargetPath
                Args       = $sc.Arguments
            }
        } catch {}
    }
}

# 3. Cross-reference with known "default pin" list (agent-written; may not exist yet)
$dataDir = Join-Path $PSScriptRoot '..\..\data'
$defaultPinsFile = Join-Path $dataDir 'taskbar_default_pins.json'
$defaultPins = @()
if (Test-Path $defaultPinsFile) {
    $defaultPins = (Get-Content $defaultPinsFile -Raw | ConvertFrom-Json).defaultPins
}
foreach ($app in $pinnedApps) {
    $app | Add-Member -MemberType NoteProperty -Name IsOEMDefault -Value ([bool]($defaultPins -contains $app.LinkName)) -Force
}

# 4. Known tray categorization
$knownTrayFile = Join-Path $dataDir 'known_tray_apps.json'
$knownTray = $null
if (Test-Path $knownTrayFile) { $knownTray = Get-Content $knownTrayFile -Raw | ConvertFrom-Json }

foreach ($t in $trayIcons) {
    $verdict = 'UNCLASSIFIED'
    if ($knownTray) {
        $exeName = if ($t.ExecutablePath) { [IO.Path]::GetFileName($t.ExecutablePath) } else { $null }
        if ($exeName) {
            if ($knownTray.'keep-visible-usually' -and $knownTray.'keep-visible-usually'.PSObject.Properties.Name -contains $exeName) { $verdict = 'KEEP' }
            elseif ($knownTray.'hide-often' -and $knownTray.'hide-often'.PSObject.Properties.Name -contains $exeName) { $verdict = 'HIDE-OFTEN' }
            elseif ($knownTray.'decide-per-user' -and $knownTray.'decide-per-user'.PSObject.Properties.Name -contains $exeName) { $verdict = 'ASK' }
        }
    }
    $t | Add-Member -MemberType NoteProperty -Name Verdict -Value $verdict -Force
}

[PSCustomObject]@{
    profile        = Get-MachineProfile
    trayIcons      = $trayIcons
    trayCount      = $trayIcons.Count
    trayPromoted   = @($trayIcons | Where-Object IsPromoted).Count
    pinnedApps     = $pinnedApps
    pinnedCount    = $pinnedApps.Count
    pinnedOEMDefaults = @($pinnedApps | Where-Object IsOEMDefault).Count
} | ConvertTo-Json -Depth 6
