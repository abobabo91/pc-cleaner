# Shared helpers used by every pc-cleaner module.

function New-SnapshotDir {
    param(
        [string]$Module,
        [string]$Root = "$env:USERPROFILE\Desktop\pc-cleaner-snapshots"
    )
    if (-not $script:PCCleaner_RunTimestamp) {
        $script:PCCleaner_RunTimestamp = Get-Date -Format 'yyyy-MM-ddTHH-mm-ss'
    }
    $dir = Join-Path $Root $script:PCCleaner_RunTimestamp
    $dir = Join-Path $dir $Module
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $dir
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-Admin)) {
        throw "This step requires administrator. Re-run the module elevated."
    }
}

function Write-Log {
    param([string]$Path, [string]$Level, [string]$Message)
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Add-Content -Path $Path -Value $line -Encoding UTF8
    Write-Host $line
}

function Get-MachineProfile {
    $cs   = Get-CimInstance Win32_ComputerSystem
    $cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS
    $os   = Get-CimInstance Win32_OperatingSystem
    $bat  = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
            Select-Object Name, DriverVersion
    $sleep = @{}
    (powercfg /a) -split "`n" | ForEach-Object {
        if ($_ -match 'Standby \((S\d|S0[^)]*)\)') { $sleep[$Matches[1]] = $_.Trim() }
    }

    # WLAN chip + subsystem (for OEM-mismatch detection, combo-card checks, driver hunt)
    $wlan = $null
    try {
        $wlanDev = Get-PnpDevice -Class Net -Status OK -ErrorAction Stop | Where-Object {
            $_.FriendlyName -match 'Wi.?Fi|Wireless|802\.11|MediaTek|Realtek|Intel.*AX|Killer|Broadcom' -and
            $_.FriendlyName -notmatch 'Direct|Miniport|Virtual|Loopback|Kernel|Native'
        } | Select-Object -First 1
        if ($wlanDev) {
            $hwIds = (($wlanDev | Get-PnpDeviceProperty -KeyName DEVPKEY_Device_HardwareIds).Data | Out-String)
            $ven = if ($hwIds -match 'VEN_([0-9A-Fa-f]{4})')     { $Matches[1].ToUpper() } else { $null }
            $dev = if ($hwIds -match 'DEV_([0-9A-Fa-f]{4})')     { $Matches[1].ToUpper() } else { $null }
            $sub = if ($hwIds -match 'SUBSYS_([0-9A-Fa-f]{8})')  { $Matches[1].ToUpper() } else { $null }
            $subVen = if ($sub) { $sub.Substring(4,4) } else { $null }
            $wlan = [PSCustomObject]@{
                Name                = $wlanDev.FriendlyName
                VendorId            = $ven
                DeviceId            = $dev
                Subsystem           = $sub
                SubsystemVendor     = $subVen
                SubsystemVendorName = switch ($subVen) { '103C' {'HP'}; '17AA' {'Lenovo'}; '1028' {'Dell'}; '1043' {'ASUS'}; '1462' {'MSI'}; '1458' {'Gigabyte'}; '10DE' {'NVIDIA'}; '8086' {'Intel'}; '10EC' {'Realtek'}; '14E4' {'Broadcom'}; '168C' {'Qualcomm'}; '14C3' {'MediaTek'}; default { 'Unknown' } }
            }
        }
    } catch {}

    [PSCustomObject]@{
        Timestamp   = (Get-Date).ToString('o')
        Machine     = $cs.Manufacturer + ' ' + $cs.Model
        IsLaptop    = [bool]$bat
        CPU         = $cpu.Name.Trim()
        CPUVendor   = if ($cpu.Name -match 'AMD|Ryzen') { 'AMD' } elseif ($cpu.Name -match 'Intel') { 'Intel' } else { 'Other' }
        RyzenGen    = if ($cpu.Name -match 'Ryzen.*(\d)\d{3}') { [int]$Matches[1] } else { $null }
        BIOSVersion = $bios.SMBIOSBIOSVersion
        BIOSDate    = $bios.ReleaseDate
        OS          = $os.Caption
        OSBuild     = $os.BuildNumber
        GPUs        = @($gpus)
        SleepStates = $sleep
        WLAN        = $wlan
        UserName    = $env:USERNAME
    }
}

function ConvertTo-Json2 {
    # Simple wrapper — ConvertTo-Json with sensible defaults for our JSON files.
    param([Parameter(ValueFromPipeline)]$Input, [int]$Depth = 6)
    process { $Input | ConvertTo-Json -Depth $Depth }
}
