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
        UserName    = $env:USERNAME
    }
}

function ConvertTo-Json2 {
    # Simple wrapper — ConvertTo-Json with sensible defaults for our JSON files.
    param([Parameter(ValueFromPipeline)]$Input, [int]$Depth = 6)
    process { $Input | ConvertTo-Json -Depth $Depth }
}
