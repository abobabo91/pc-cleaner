# Diagnose: find installed apps that haven't been launched recently, cross-referenced
# with install size. Uses UserAssist (ROT13-encoded launch counters) primarily; Prefetch
# as fallback. Applies a "never propose" allowlist from data/unused_apps_never.json.
#
# Read-only. No admin needed.

param(
    [int]$MinDaysUnused = 90,
    [int]$MinSizeMB    = 100,
    [string]$DataDir   = (Join-Path $PSScriptRoot '..\..\data')
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')

# Load never-propose list
$neverList = @()
$neverFile = Join-Path $DataDir 'unused_apps_never.json'
if (Test-Path $neverFile) {
    $nl = Get-Content $neverFile -Raw | ConvertFrom-Json
    $neverList = @($nl.entries | ForEach-Object { $_.pattern })
}

# ROT13 helper for UserAssist decoding
function Convert-Rot13 {
    param([string]$s)
    if (-not $s) { return $s }
    ($s.ToCharArray() | ForEach-Object {
        $c = [int][char]$_
        if ($c -ge 65 -and $c -le 90)     { [char]((($c - 65 + 13) % 26) + 65) }
        elseif ($c -ge 97 -and $c -le 122) { [char]((($c - 97 + 13) % 26) + 97) }
        else { [char]$c }
    }) -join ''
}

# Enumerate installed apps from Uninstall registry
$uninstall = @()
$hives = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
)
foreach ($h in $hives) {
    if (-not (Test-Path $h)) { continue }
    Get-ChildItem $h | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p.DisplayName -and -not $p.SystemComponent -and $p.DisplayName -notmatch '^KB\d+') {
            $uninstall += [PSCustomObject]@{
                DisplayName    = $p.DisplayName
                DisplayVersion = $p.DisplayVersion
                Publisher      = $p.Publisher
                InstallLocation = $p.InstallLocation
                InstallDate    = $p.InstallDate
                EstSizeKB      = $p.EstimatedSize
                UninstallString = $p.UninstallString
                QuietUninstallString = $p.QuietUninstallString
            }
        }
    }
}

# Deduplicate by DisplayName
$uninstall = $uninstall | Sort-Object DisplayName -Unique

# UserAssist: parse HKCU\...\CountersGuid → binary blob per encoded exe name
$now = Get-Date
$assistPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist'
$assistData = @{}   # decodedPath -> lastRunTime
if (Test-Path $assistPath) {
    Get-ChildItem $assistPath | ForEach-Object {
        $countKey = Join-Path $_.PSPath 'Count'
        if (Test-Path $countKey) {
            $props = Get-ItemProperty $countKey -ErrorAction SilentlyContinue
            $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                $name = Convert-Rot13 $_.Name
                $val = $_.Value
                # Newer format: bytes 60-67 are FILETIME (little-endian)
                if ($val -is [byte[]] -and $val.Length -ge 68) {
                    try {
                        $ft = [BitConverter]::ToInt64($val, 60)
                        if ($ft -gt 0) {
                            $dt = [DateTime]::FromFileTime($ft)
                            if ($dt -gt (Get-Date '2000-01-01')) {
                                if (-not $assistData.ContainsKey($name) -or $assistData[$name] -lt $dt) {
                                    $assistData[$name] = $dt
                                }
                            }
                        }
                    } catch {}
                }
            }
        }
    }
}

# Match Uninstall entries with UserAssist
$candidates = foreach ($u in $uninstall) {
    $sizeMB = if ($u.EstSizeKB) { [math]::Round($u.EstSizeKB / 1024, 1) } else { 0 }
    if ($sizeMB -lt $MinSizeMB) { continue }

    # Skip never-list
    $skip = $false
    foreach ($p in $neverList) { if ($u.DisplayName -match [regex]::Escape($p)) { $skip = $true; break } }
    if ($skip) { continue }

    # Find best-match lastRun from UserAssist by executable path
    $lastRun = $null
    if ($u.InstallLocation) {
        foreach ($k in $assistData.Keys) {
            if ($k -like "*$($u.InstallLocation)*") {
                if (-not $lastRun -or $assistData[$k] -gt $lastRun) { $lastRun = $assistData[$k] }
            }
        }
    }
    # Fallback: match by display name in path
    if (-not $lastRun -and $u.DisplayName) {
        foreach ($k in $assistData.Keys) {
            if ($k -match [regex]::Escape($u.DisplayName)) {
                if (-not $lastRun -or $assistData[$k] -gt $lastRun) { $lastRun = $assistData[$k] }
            }
        }
    }

    $daysSince = if ($lastRun) { [int]($now - $lastRun).TotalDays } else { $null }
    $unused = ($null -eq $lastRun) -or ($daysSince -gt $MinDaysUnused)

    if ($unused) {
        [PSCustomObject]@{
            DisplayName    = $u.DisplayName
            Publisher      = $u.Publisher
            SizeMB         = $sizeMB
            LastRun        = if ($lastRun) { $lastRun.ToString('yyyy-MM-dd') } else { $null }
            DaysSinceLastRun = $daysSince
            NeverLaunched  = ($null -eq $lastRun)
            UninstallString = $u.UninstallString
            QuietUninstall  = $u.QuietUninstallString
        }
    }
}
$candidates = $candidates | Sort-Object SizeMB -Descending

[PSCustomObject]@{
    profile          = Get-MachineProfile
    minDaysUnused    = $MinDaysUnused
    minSizeMB        = $MinSizeMB
    totalInstalled   = $uninstall.Count
    unusedCandidates = $candidates
    unusedCount      = $candidates.Count
    reclaimableMB    = ($candidates | Measure-Object SizeMB -Sum).Sum
} | ConvertTo-Json -Depth 6
