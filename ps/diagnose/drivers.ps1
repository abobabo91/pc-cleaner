# Diagnose: hunt for stale + OEM-mismatched + crash-linked drivers.
# Read-only. No admin. Cross-references data/known_bad_drivers.json + snapshot's
# crash_linked_drivers.json (from crashdumps module, if it ran earlier).

param(
    [string]$DataDir = (Join-Path $PSScriptRoot '..\..\data'),
    [string]$SnapshotRoot = $null   # If set, look for crash_linked_drivers.json here
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')

$profile = Get-MachineProfile

# Load reference data
$knownBad = @{}
$kbFile = Join-Path $DataDir 'known_bad_drivers.json'
if (Test-Path $kbFile) {
    $kb = Get-Content $kbFile -Raw | ConvertFrom-Json
    foreach ($d in $kb.drivers) { $knownBad[$d.driverFile.ToLower()] = $d }
}

# Load crash linkage (if present)
$crashLinked = @{}
if ($SnapshotRoot -and (Test-Path (Join-Path $SnapshotRoot 'crash_linked_drivers.json'))) {
    $cl = Get-Content (Join-Path $SnapshotRoot 'crash_linked_drivers.json') -Raw | ConvertFrom-Json
    foreach ($e in $cl) { $crashLinked[$e.Module.ToLower()] = $e }
}

# 1. Enumerate all PnP devices with driver info; flag by age and mismatch
$staleDays = 730   # 2 years
$now = Get-Date

$critical = @('Net','Display','SCSIAdapter','System','Bluetooth','MEDIA','USB','Audio')
$devices = Get-PnpDevice -Status OK -ErrorAction SilentlyContinue |
    Where-Object { $_.Class -in $critical }

$rows = foreach ($d in $devices) {
    $props = $d | Get-PnpDeviceProperty -KeyName DEVPKEY_Device_DriverVersion, DEVPKEY_Device_DriverDate, DEVPKEY_Device_DriverProvider, DEVPKEY_Device_DriverInfPath -ErrorAction SilentlyContinue
    $ver  = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_DriverVersion').Data
    $date = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_DriverDate').Data
    $prov = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_DriverProvider').Data
    $inf  = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_DriverInfPath').Data

    # Microsoft's placeholder date (2006-06-21) means "use the driver version instead of date"
    $isMSPlaceholder = $date -and $date.Year -eq 2006 -and $date.Month -eq 6 -and $date.Day -eq 21
    $stale = if ($isMSPlaceholder) { $false } else { $date -and ($now - $date).Days -gt $staleDays }
    $ageDays = if ($date) { ($now - $date).Days } else { $null }

    # Flag known-bad
    $sysFile = if ($d.InstanceId -match 'VEN_[0-9A-F]{4}&DEV_([0-9A-F]{4})') { $Matches[1] } else { $null }
    $badMatch = $null
    foreach ($k in $knownBad.Keys) {
        # Simplified: match driverProvider or matching family
        if ($inf -match $k -or $d.FriendlyName -match $k) { $badMatch = $knownBad[$k]; break }
    }

    [PSCustomObject]@{
        Class          = $d.Class
        FriendlyName   = $d.FriendlyName
        Version        = $ver
        Date           = if ($date) { $date.ToString('yyyy-MM-dd') } else { $null }
        AgeDays        = $ageDays
        Provider       = $prov
        InfPath        = $inf
        Stale          = $stale
        MSPlaceholder  = $isMSPlaceholder
        KnownBad       = ($null -ne $badMatch)
        BadRule        = $badMatch
    }
}

# 2. WLAN OEM mismatch (already computed in profile) — surface separately
$wlanMismatch = $null
if ($profile.WLAN -and $profile.WLAN.SubsystemVendorName -and $profile.WLAN.SubsystemVendorName -ne 'Unknown') {
    $machineOEM = ($profile.Machine -split ' ')[0]   # 'LENOVO', 'HP', 'DELL', ...
    $subOEM = $profile.WLAN.SubsystemVendorName.ToUpper()
    if ($machineOEM -notmatch $subOEM -and $subOEM -notmatch $machineOEM) {
        $wlanMismatch = @{
            MachineOEM         = $machineOEM
            SubsystemOEM       = $subOEM
            WLANName           = $profile.WLAN.Name
            Recommendation     = "Machine OEM ($machineOEM) does not match WLAN subsystem vendor ($subOEM). $machineOEM's driver catalog may skip this card. Look at $subOEM's SoftPaqs / driver page instead."
        }
    }
}

# 3. Cross-reference stale + known-bad + crash-linked
$flagged = $rows | Where-Object { $_.Stale -or $_.KnownBad }
$topSuspects = @()
foreach ($r in $flagged) {
    $inCrashLog = $false; $crashCount = 0
    foreach ($k in $crashLinked.Keys) {
        if ($r.FriendlyName -match $k -or ($r.InfPath -and $r.InfPath -match $k)) {
            $inCrashLog = $true; $crashCount = $crashLinked[$k].CrashCount; break
        }
    }
    $topSuspects += [PSCustomObject]@{
        FriendlyName  = $r.FriendlyName
        Class         = $r.Class
        Version       = $r.Version
        AgeDays       = $r.AgeDays
        Stale         = $r.Stale
        KnownBad      = $r.KnownBad
        CrashLinked   = $inCrashLog
        CrashCount    = $crashCount
        Score         = ($(if($r.Stale){1}else{0}) + $(if($r.KnownBad){3}else{0}) + $crashCount * 2)
    }
}
$topSuspects = $topSuspects | Sort-Object Score -Descending

[PSCustomObject]@{
    profile        = $profile
    totalDevices   = $devices.Count
    driverRows     = $rows
    wlanMismatch   = $wlanMismatch
    flaggedCount   = $flagged.Count
    topSuspects    = $topSuspects
    crashLinkageAvailable = ($crashLinked.Count -gt 0)
} | ConvertTo-Json -Depth 6
