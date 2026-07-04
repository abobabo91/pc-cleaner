# Diagnose: emit machine profile as JSON.
# Read-only. No admin. Every other module reads this first.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')

$profile = Get-MachineProfile

# Enrich: enumerate WLAN chip + subsystem for OEM-mismatch detection
try {
    $wlan = Get-PnpDevice -Class Net -Status OK -ErrorAction Stop | Where-Object {
        $_.FriendlyName -match 'Wi.?Fi|Wireless|802\.11|MediaTek|Realtek|Intel.*AX|Killer|Broadcom' -and
        $_.FriendlyName -notmatch 'Direct|Miniport|Virtual|Loopback|Kernel|Native'
    } | Select-Object -First 1
    if ($wlan) {
        $hwIds = (($wlan | Get-PnpDeviceProperty -KeyName DEVPKEY_Device_HardwareIds).Data | Out-String)
        $ven = if ($hwIds -match 'VEN_([0-9A-Fa-f]{4})') { $Matches[1].ToUpper() } else { $null }
        $dev = if ($hwIds -match 'DEV_([0-9A-Fa-f]{4})') { $Matches[1].ToUpper() } else { $null }
        $sub = if ($hwIds -match 'SUBSYS_([0-9A-Fa-f]{8})') { $Matches[1].ToUpper() } else { $null }
        $subVendor = if ($sub) { $sub.Substring(4,4) } else { $null }
        $profile | Add-Member -MemberType NoteProperty -Name WLAN -Value ([PSCustomObject]@{
            Name           = $wlan.FriendlyName
            VendorId       = $ven
            DeviceId       = $dev
            Subsystem      = $sub
            SubsystemVendor= $subVendor
            SubsystemVendorName = switch ($subVendor) { '103C' {'HP'}; '17AA' {'Lenovo'}; '1028' {'Dell'}; '1043' {'ASUS'}; '1462' {'MSI'}; '1458' {'Gigabyte'}; '10DE' {'NVIDIA'}; '8086' {'Intel'}; '10EC' {'Realtek'}; default { 'Unknown' } }
        })
    }
} catch {}

# WHEA errors in last 30 days - signal for driver issues
try {
    $whea = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=(Get-Date).AddDays(-30)} -ErrorAction SilentlyContinue).Count
    $profile | Add-Member -MemberType NoteProperty -Name WHEAErrors30d -Value $whea
} catch {
    $profile | Add-Member -MemberType NoteProperty -Name WHEAErrors30d -Value $null
}

# Recent BSODs / minidumps (existence only, no reading - that's crashdumps module)
try {
    $dumps = @(Get-ChildItem C:\Windows\Minidump\*.dmp -ErrorAction SilentlyContinue).Count
    $profile | Add-Member -MemberType NoteProperty -Name MinidumpCount -Value $dumps
} catch {
    $profile | Add-Member -MemberType NoteProperty -Name MinidumpCount -Value 0
}

$profile | ConvertTo-Json -Depth 4
