# Diagnose: check power / sleep / WLAN low-power state.
# Read-only. No admin needed for read. Emits JSON.

param(
    [string]$DataDir = (Join-Path $PSScriptRoot '..\..\data')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')

$profile = Get-MachineProfile

# powercfg readings for current active scheme
function Get-PowerSetting {
    param([string]$Subgroup, [string]$Setting)
    try {
        $out = (& powercfg /query SCHEME_CURRENT $Subgroup $Setting 2>&1) -join "`n"
        $ac = if ($out -match 'Current AC Power Setting Index:\s*0x([0-9A-Fa-f]+)') { [Convert]::ToInt64($Matches[1], 16) } else { $null }
        $dc = if ($out -match 'Current DC Power Setting Index:\s*0x([0-9A-Fa-f]+)') { [Convert]::ToInt64($Matches[1], 16) } else { $null }
        [PSCustomObject]@{ AC = $ac; DC = $dc }
    } catch { [PSCustomObject]@{ AC = $null; DC = $null } }
}

$power = @{
    PCIeASPM          = Get-PowerSetting SUB_PCIEXPRESS ASPM
    LidAction         = Get-PowerSetting SUB_BUTTONS 5ca83367-6e45-459f-a27b-476b1d01c936
    StandbyIdle       = Get-PowerSetting SUB_SLEEP STANDBYIDLE
    HibernateIdle     = Get-PowerSetting SUB_SLEEP HIBERNATEIDLE
    ProcThrottleMin   = Get-PowerSetting SUB_PROCESSOR PROCTHROTTLEMIN
    ProcThrottleMax   = Get-PowerSetting SUB_PROCESSOR PROCTHROTTLEMAX
}

# WLAN driver-level LPS keys (if combo card present)
$wlanLPS = @{}
$comboFile = Join-Path $DataDir 'combo_cards.json'
$flagsFile = Join-Path $DataDir 'wlan_lps_flags.json'
$isCombo = $false
if ((Test-Path $comboFile) -and (Test-Path $flagsFile)) {
    $combo = Get-Content $comboFile -Raw | ConvertFrom-Json
    $flags = Get-Content $flagsFile -Raw | ConvertFrom-Json
    if ($profile.WLAN -and $profile.WLAN.DeviceId) {
        $devFull = "DEV_$($profile.WLAN.DeviceId)"
        foreach ($c in $combo.cards) {
            if ($c.devIdPattern -and $devFull -match $c.devIdPattern) { $isCombo = $true; break }
        }
    }
    if ($isCombo) {
        # Find the WLAN driver class registry key
        $classPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
        $wlanClassKey = Get-ChildItem $classPath -ErrorAction SilentlyContinue | Where-Object {
            $mid = (Get-ItemProperty $_.PSPath -Name MatchingDeviceId -ErrorAction SilentlyContinue).MatchingDeviceId
            $mid -match "ven_$($profile.WLAN.VendorId.ToLower())&dev_$($profile.WLAN.DeviceId.ToLower())"
        } | Select-Object -First 1
        if ($wlanClassKey) {
            $props = Get-ItemProperty $wlanClassKey.PSPath
            foreach ($f in $flags.flags) {
                $current = $props.$($f.name)
                $wlanLPS[$f.name] = @{
                    Current = $current
                    Target  = $f.targetValue
                    Needs   = ($current -ne $f.targetValue)
                }
            }
            $wlanLPS['_classKeyPath'] = $wlanClassKey.PSPath.ToString()
        }
    }
}

# Modern Standby state - section-tracking parser
$sleepStates = @{ ModernStandby = $false; HibernateAvailable = $false; S3Available = $false }
try {
    $inAvailable = $false
    foreach ($line in (powercfg /a)) {
        if ($line -match 'The following sleep states are available') { $inAvailable = $true;  continue }
        if ($line -match 'The following sleep states are not available') { $inAvailable = $false; continue }
        if ($inAvailable) {
            if ($line -match 'Standby \(S0 Low Power Idle\)') { $sleepStates.ModernStandby = $true }
            if ($line -match '^\s*Hibernate\s*$')             { $sleepStates.HibernateAvailable = $true }
            if ($line -match '^\s*Standby \(S3\)')            { $sleepStates.S3Available = $true }
        }
    }
} catch {}

[PSCustomObject]@{
    profile        = $profile
    powercfg       = $power
    sleepStates    = $sleepStates
    isComboCard    = $isCombo
    wlanLPS        = $wlanLPS
} | ConvertTo-Json -Depth 6
