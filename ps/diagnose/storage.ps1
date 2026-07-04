# Diagnose: enumerate storage cleanup candidates from data/storage_sources.json.
# Read-only. No admin needed. Emits JSON with size estimates.

param(
    [string]$DataDir = (Join-Path $PSScriptRoot '..\..\data')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')

$sourcesFile = Join-Path $DataDir 'storage_sources.json'
if (-not (Test-Path $sourcesFile)) {
    [PSCustomObject]@{ error = "storage_sources.json not found"; expected = $sourcesFile } | ConvertTo-Json
    exit 0
}
$data = Get-Content $sourcesFile -Raw | ConvertFrom-Json

function Get-DirSizeMB {
    param([string]$Path, [string]$Filter = '*', [int]$MinAgeDays = 0)
    try {
        if (-not (Test-Path -Path $Path -ErrorAction SilentlyContinue)) { return 0 }
    } catch { return 0 }
    $cutoff = if ($MinAgeDays -gt 0) { (Get-Date).AddDays(-$MinAgeDays) } else { $null }
    try {
        $total = 0
        Get-ChildItem -Path $Path -File -Filter $Filter -Recurse -ErrorAction SilentlyContinue -Force |
            Where-Object { -not $cutoff -or $_.LastWriteTime -lt $cutoff } |
            ForEach-Object { $total += $_.Length }
        [math]::Round($total / 1MB, 1)
    } catch { 0 }
}
function Test-PathSafe {
    param([string]$Path)
    try { return [bool](Test-Path -Path $Path -ErrorAction SilentlyContinue) } catch { return $false }
}

# Disk info
$drives = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 } | ForEach-Object {
    [PSCustomObject]@{
        DeviceID   = $_.DeviceID
        SizeGB     = [math]::Round($_.Size/1GB, 1)
        FreeGB     = [math]::Round($_.FreeSpace/1GB, 1)
        UsedPct    = [math]::Round((($_.Size - $_.FreeSpace) / $_.Size) * 100, 1)
    }
}

# Enumerate each cleanup source with size estimate
$sources = foreach ($src in $data.sources) {
    $expandedPath = [Environment]::ExpandEnvironmentVariables($src.path)
    $sizeMB = Get-DirSizeMB -Path $expandedPath -Filter ($src.filter | ForEach-Object { $_ }) -MinAgeDays ($src.minAgeDays | ForEach-Object { $_ })
    [PSCustomObject]@{
        Name             = $src.name
        Description      = $src.description
        Path             = $expandedPath
        Filter           = $src.filter
        MinAgeDays       = $src.minAgeDays
        RiskLevel        = $src.riskLevel
        Exists           = Test-PathSafe $expandedPath
        SizeMB           = $sizeMB
        ReclaimEstimateMB = $src.reclaimEstimate
    }
}

# Storage Sense current state
$storageSense = @{}
try {
    $ss = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' -ErrorAction SilentlyContinue
    if ($ss) {
        $storageSense.Enabled = ($ss.01 -eq 1)
        $storageSense.RunFrequency = $ss.'2048'    # 0=every low disk, 1=daily, 7=weekly, 30=monthly
    }
} catch {}

# Component store size (WinSxS) - takes a few seconds via DISM, so skip in diagnose; storage doc says analyze on demand
[PSCustomObject]@{
    profile        = Get-MachineProfile
    drives         = $drives
    sources        = $sources
    storageSense   = $storageSense
    totalReclaimMB = [math]::Round(($sources | Measure-Object SizeMB -Sum).Sum, 1)
} | ConvertTo-Json -Depth 6
