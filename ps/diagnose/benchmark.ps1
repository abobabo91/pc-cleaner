# Diagnose: quick performance baseline snapshot. Emits JSON.
# Read-only. No admin needed. Run twice: once before cleanup, once after.
# The `benchmark` module in the skill reads both and shows the diff.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')

# Boot time (last successful boot)
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$uptimeMinutes = [math]::Round(((Get-Date) - $boot).TotalMinutes, 1)

# Approximate boot duration from Diagnostics-Performance log (event 100 = boot took X ms)
$bootDurationMs = $null
try {
    $ev = Get-WinEvent -LogName 'Microsoft-Windows-Diagnostics-Performance/Operational' -MaxEvents 5 -ErrorAction Stop |
        Where-Object { $_.Id -eq 100 } | Select-Object -First 1
    if ($ev) {
        $xml = [xml]$ev.ToXml()
        $bootDurationMs = [int]($xml.Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' } | Select-Object -First 1).'#text'
    }
} catch {}

# Service counts
$svc = Get-Service
$svcTotal    = $svc.Count
$svcRunning  = @($svc | Where-Object Status -eq 'Running').Count
$svcAuto     = @($svc | Where-Object StartType -eq 'Automatic').Count
$svcDisabled = @($svc | Where-Object StartType -eq 'Disabled').Count

# Autostart count (call diagnose/startup.ps1 for consistency)
$startupJson = & (Join-Path $PSScriptRoot 'startup.ps1') | ConvertFrom-Json
$autostartEnabled  = @($startupJson.entries | Where-Object Enabled).Count
$autostartDisabled = @($startupJson.entries | Where-Object { -not $_.Enabled }).Count

# RAM
$mem = Get-CimInstance Win32_OperatingSystem
$ramTotalMB = [math]::Round($mem.TotalVisibleMemorySize / 1024)
$ramFreeMB  = [math]::Round($mem.FreePhysicalMemory / 1024)
$ramUsedMB  = $ramTotalMB - $ramFreeMB
$ramUsedPct = [math]::Round(($ramUsedMB / $ramTotalMB) * 100, 1)

# UWP package count
$uwpCount = 0
try { $uwpCount = @(Get-AppxPackage).Count } catch {}

# Windows Defender scan state
$defState = $null
try {
    $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($mp) { $defState = @{
        RealTime  = $mp.RealTimeProtectionEnabled
        LastScan  = $mp.QuickScanEndTime
        SigsAge   = $mp.AntivirusSignatureAge
    } }
} catch {}

[PSCustomObject]@{
    Timestamp        = (Get-Date).ToString('o')
    LastBootUpTime   = $boot.ToString('o')
    UptimeMinutes    = $uptimeMinutes
    BootDurationMs   = $bootDurationMs
    Services = @{
        Total    = $svcTotal
        Running  = $svcRunning
        Auto     = $svcAuto
        Disabled = $svcDisabled
    }
    Autostart = @{
        Enabled  = $autostartEnabled
        Disabled = $autostartDisabled
    }
    RAM = @{
        TotalMB   = $ramTotalMB
        UsedMB    = $ramUsedMB
        FreeMB    = $ramFreeMB
        UsedPct   = $ramUsedPct
    }
    UWPPackages      = $uwpCount
    Defender         = $defState
} | ConvertTo-Json -Depth 4
