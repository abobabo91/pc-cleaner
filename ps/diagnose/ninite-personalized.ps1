# Diagnose: detect user's role from installed apps + suggest missing companions.
# Read-only. No admin. Non-destructive — outputs winget commands to copy-paste.

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')

$dataDir = Join-Path $PSScriptRoot '..\..\data'
$roleSignalsFile = Join-Path $dataDir 'role_signals.json'
$bundlesFile     = Join-Path $dataDir 'ninite_bundles.json'

if (-not (Test-Path $roleSignalsFile) -or -not (Test-Path $bundlesFile)) {
    [PSCustomObject]@{ error = "role_signals.json or ninite_bundles.json missing"; expected = @($roleSignalsFile, $bundlesFile) } | ConvertTo-Json
    exit 0
}

$signals = (Get-Content $roleSignalsFile -Raw | ConvertFrom-Json).roles
$bundles = (Get-Content $bundlesFile -Raw | ConvertFrom-Json).bundles

# Gather installed apps: winget list + UWP + running processes + folder markers
$installed = @{}

# 1. winget
try {
    $wg = winget list --accept-source-agreements 2>&1 | Out-String
    foreach ($line in ($wg -split "`n")) {
        if ($line -match '^\s*(.+?)\s{2,}([A-Za-z0-9\.\-_]+)\s') {
            $installed[$Matches[2].Trim().ToLower()] = $true
        }
    }
} catch {}

# 2. Running processes
try {
    Get-Process | ForEach-Object { $installed["proc:$($_.Name.ToLower())"] = $true }
} catch {}

# 3. Folder markers
$folderMarkers = @(
    "$env:USERPROFILE\Desktop\github",
    "$env:USERPROFILE\Documents\GitHub",
    "$env:USERPROFILE\source\repos",
    "C:\Program Files (x86)\Steam\steamapps",
    "C:\Program Files\Adobe",
    "$env:APPDATA\JetBrains"
)
foreach ($f in $folderMarkers) {
    if (Test-Path $f -ErrorAction SilentlyContinue) { $installed["folder:$f"] = $true }
}

# Score each role
$scores = @{}
foreach ($role in $signals) {
    $s = 0; $matches = @()
    foreach ($sig in $role.signals) {
        $hit = $false
        switch ($sig.type) {
            'winget' { if ($installed.ContainsKey($sig.pattern.ToLower())) { $hit = $true } }
            'process' { if ($installed.ContainsKey("proc:$($sig.pattern -replace '\.exe$','' | ForEach-Object { $_.ToLower() })")) { $hit = $true } }
            'folder' {
                $expanded = [Environment]::ExpandEnvironmentVariables($sig.pattern)
                if ($installed.ContainsKey("folder:$expanded")) { $hit = $true }
            }
        }
        if ($hit) {
            $s += $sig.weight
            $matches += $sig.pattern
        }
    }
    $scores[$role.role] = @{ Score = $s; Signals = $matches }
}

# Detected roles: any with score >= 3 (arbitrary threshold, tweak in data)
$detectedRoles = @($scores.Keys | Where-Object { $scores[$_].Score -ge 3 })
if ($detectedRoles.Count -eq 0) { $detectedRoles = @('office') }   # generic fallback

# Suggestions: from bundles that match detected roles - always include 'always_useful'
$rolesToSuggest = $detectedRoles + @('always_useful') | Sort-Object -Unique
$suggestions = @()
foreach ($r in $rolesToSuggest) {
    if ($bundles.PSObject.Properties.Name -contains $r) {
        foreach ($id in $bundles.$r) {
            $isInstalled = $installed.ContainsKey($id.ToLower())
            $suggestions += [PSCustomObject]@{
                Role         = $r
                WingetId     = $id
                AlreadyHave  = $isInstalled
                Install      = if ($isInstalled) { '' } else { "winget install --id $id --silent --accept-source-agreements --accept-package-agreements" }
            }
        }
    }
}
$suggestions = $suggestions | Where-Object { -not $_.AlreadyHave }

[PSCustomObject]@{
    profile         = Get-MachineProfile
    detectedRoles   = $detectedRoles
    roleScores      = $scores
    suggestions     = $suggestions
    suggestionCount = $suggestions.Count
    installCommands = ($suggestions | Select-Object -ExpandProperty Install) -join "`n"
} | ConvertTo-Json -Depth 6
