# Diagnose: find dev toolchain cache paths that exist on this machine + scan for git repos
# to propose adding as Defender exclusions.
# Read-only. Reads Defender preferences (no admin needed for read).

param(
    [string]$DataDir = (Join-Path $PSScriptRoot '..\..\data')
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')

# Current Defender state + exclusions
$mp = @{}
try {
    $s = Get-MpComputerStatus -ErrorAction Stop
    $mp.RealTimeProtection = $s.RealTimeProtectionEnabled
    $mp.AntivirusEnabled   = $s.AntivirusEnabled
    $mp.SignatureAge       = $s.AntivirusSignatureAge
} catch { $mp.Error = $_.Exception.Message }

$existingExclusions = @()
try {
    $pref = Get-MpPreference -ErrorAction Stop
    $existingExclusions = @($pref.ExclusionPath)
} catch {}

# Dev cache paths that exist
$devCachePaths = @()
$dcPathsFile = Join-Path $DataDir 'dev_cache_paths.json'
if (Test-Path $dcPathsFile) {
    $dc = Get-Content $dcPathsFile -Raw | ConvertFrom-Json
    foreach ($entry in $dc.paths) {
        $expanded = [Environment]::ExpandEnvironmentVariables($entry.path)
        # Handle wildcards in path
        $matches = @()
        if ($expanded -match '\*') {
            try {
                $matches = @(Get-Item $expanded -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty FullName)
            } catch {}
        } else {
            if (Test-Path $expanded -ErrorAction SilentlyContinue) { $matches = @($expanded) }
        }
        foreach ($m in $matches) {
            $alreadyExcluded = $existingExclusions -contains $m
            $sizeMB = 0
            try {
                if ((Get-Item $m) -is [System.IO.DirectoryInfo]) {
                    $sizeMB = [math]::Round((Get-ChildItem $m -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB, 1)
                }
            } catch {}
            $devCachePaths += [PSCustomObject]@{
                Name             = $entry.name
                Path             = $m
                Languages        = $entry.languages
                Rationale        = $entry.rationale
                SizeMB           = $sizeMB
                AlreadyExcluded  = $alreadyExcluded
            }
        }
    }
}

# Git repo roots
$repoRoots = @()
$rrFile = Join-Path $DataDir 'repo_scan_roots.json'
if (Test-Path $rrFile) {
    $rr = Get-Content $rrFile -Raw | ConvertFrom-Json
    foreach ($root in $rr.roots) {
        $expanded = [Environment]::ExpandEnvironmentVariables($root)
        if (Test-Path $expanded -ErrorAction SilentlyContinue) {
            # Count .git dirs beneath (max depth 4 to avoid deep traversal)
            $gitCount = 0
            try {
                $gitCount = (Get-ChildItem $expanded -Directory -Recurse -Depth 4 -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq '.git' }).Count
            } catch {}
            $repoRoots += [PSCustomObject]@{
                Path           = $expanded
                GitRepoCount   = $gitCount
                AlreadyExcluded = $existingExclusions -contains $expanded
            }
        }
    }
}

[PSCustomObject]@{
    profile             = Get-MachineProfile
    defender            = $mp
    existingExclusions  = $existingExclusions
    devCachePaths       = $devCachePaths
    devCachePathsTotalMB = [math]::Round(($devCachePaths | Measure-Object SizeMB -Sum).Sum, 1)
    repoScanRoots       = $repoRoots
    proposedNewCount    = @($devCachePaths | Where-Object { -not $_.AlreadyExcluded }).Count + @($repoRoots | Where-Object { $_.GitRepoCount -gt 0 -and -not $_.AlreadyExcluded }).Count
} | ConvertTo-Json -Depth 6
