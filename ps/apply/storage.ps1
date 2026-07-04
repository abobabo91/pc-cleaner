# Apply: delete storage cleanup targets from a plan JSON. Runs DISM if requested.
# HKCU tweaks don't need admin; DISM /online + %windir%\Temp cleanup do.

param(
    [Parameter(Mandatory=$true)][string]$Plan,
    [string]$SnapshotDir
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')

if (-not $SnapshotDir) { $SnapshotDir = New-SnapshotDir -Module 'storage' }
$log = Join-Path $SnapshotDir 'apply.log'
"===== storage apply started $(Get-Date -Format o) =====" | Out-File $log -Encoding UTF8

$planData = Get-Content $Plan -Raw | ConvertFrom-Json
$sources  = @($planData.sources)      # list of source objects with Path/Filter/MinAgeDays
$runDism  = [bool]$planData.runDism
$enableStorageSense = [bool]$planData.enableStorageSense

# Snapshot: sizes before
$snap = Join-Path $SnapshotDir 'snapshot.json'
$before = foreach ($src in $sources) {
    $expandedPath = [Environment]::ExpandEnvironmentVariables($src.path)
    [PSCustomObject]@{
        Name = $src.name; Path = $expandedPath
        SizeBeforeMB = if (Test-Path $expandedPath) {
            try { [math]::Round((Get-ChildItem -Path $expandedPath -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB, 1) } catch { 0 }
        } else { 0 }
    }
}
$before | ConvertTo-Json | Set-Content $snap -Encoding UTF8

$totalDeletedMB = 0
foreach ($src in $sources) {
    $expandedPath = [Environment]::ExpandEnvironmentVariables($src.path)
    if (-not (Test-Path $expandedPath)) {
        Write-Log $log 'SKIP' "$($src.name) - path not found: $expandedPath"
        continue
    }
    if ($expandedPath -like 'HKLM:*' -and -not (Test-Admin)) {
        Write-Log $log 'SKIP-ADMIN' "$($src.name) - needs admin"
        continue
    }
    $filter = if ($src.filter) { $src.filter } else { '*' }
    $cutoff = if ($src.minAgeDays -gt 0) { (Get-Date).AddDays(-$src.minAgeDays) } else { $null }
    $deletedMB = 0
    try {
        Get-ChildItem -Path $expandedPath -File -Filter $filter -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $cutoff -or $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                $sz = $_.Length
                try {
                    Remove-Item -Path $_.FullName -Force -ErrorAction Stop
                    $deletedMB += ($sz / 1MB)
                } catch { }
            }
        # Then delete empty subdirs
        Get-ChildItem -Path $expandedPath -Directory -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not (Get-ChildItem -Path $_.FullName -Force -ErrorAction SilentlyContinue) } |
            Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        Write-Log $log 'APPLY' "$($src.name): deleted $([math]::Round($deletedMB,1)) MB"
        $totalDeletedMB += $deletedMB
    } catch {
        Write-Log $log 'ERR' "$($src.name): $($_.Exception.Message)"
    }
}

if ($runDism) {
    if (Test-Admin) {
        Write-Log $log 'DISM' "Running DISM /online /cleanup-image /startcomponentcleanup /resetbase (can take 5-15 min)"
        $dismOut = & dism /online /cleanup-image /startcomponentcleanup /resetbase 2>&1
        Write-Log $log 'DISM' "Exit: $LASTEXITCODE"
        $dismOut | Out-File (Join-Path $SnapshotDir 'dism.log') -Encoding UTF8
    } else {
        Write-Log $log 'SKIP-ADMIN' "DISM not run - session not elevated"
    }
}

if ($enableStorageSense) {
    New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' -Force | Out-Null
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' -Name '01' -Value 1 -Type DWord
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' -Name '2048' -Value 30 -Type DWord   # monthly
    Write-Log $log 'APPLY' "Storage Sense enabled, run monthly"
}

# Revert = nothing (deletions are irreversible; just note the sizes freed)
$revertScript = Join-Path $SnapshotDir 'revert.ps1'
$revertText = @"
# storage cleanup: DELETIONS ARE IRREVERSIBLE. This file exists for consistency only.
# Freed approximately $([math]::Round($totalDeletedMB,1)) MB across these sources:
"@
foreach ($src in $sources) { $revertText += "`n#   $($src.name): $([Environment]::ExpandEnvironmentVariables($src.path))" }
Set-Content -Path $revertScript -Value $revertText -Encoding UTF8

"===== storage apply done: $([math]::Round($totalDeletedMB,1)) MB freed =====" | Add-Content -Path $log
Write-Host "Freed: $([math]::Round($totalDeletedMB,1)) MB"
Write-Host "Log  : $log"
