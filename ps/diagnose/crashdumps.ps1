# Diagnose: enumerate minidumps + BSOD event log + check for SDK Debuggers.
# Read-only for the diagnose pass. Actual `kd -z` analysis runs in apply/crashdumps.ps1
# because it needs an admin copy of the .dmp files (System-owned ACLs).

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')

# 1. Minidump inventory
$dumps = @()
try {
    $dumps = @(Get-ChildItem 'C:\Windows\Minidump\*.dmp' -ErrorAction SilentlyContinue |
        Select-Object Name, @{n='SizeMB';e={[math]::Round($_.Length/1MB, 2)}}, LastWriteTime)
} catch {}

# 2. Bug-check events (WER System Error Reporting) - last 90 days
$bugChecks = @()
try {
    $bugChecks = @(Get-WinEvent -FilterHashtable @{
        LogName='System'; ID=1001;
        ProviderName='Microsoft-Windows-WER-SystemErrorReporting';
        StartTime=(Get-Date).AddDays(-90)
    } -ErrorAction SilentlyContinue | ForEach-Object {
        $code = $null; $params = @()
        if ($_.Message -match 'bugcheck was:\s*0x([0-9a-fA-F]+)') {
            $code = "0x" + $Matches[1].ToUpper().TrimStart('0').PadLeft(2, '0')
        }
        if ($_.Message -match '\(0x([0-9a-fA-F]+),\s*0x([0-9a-fA-F]+),\s*0x([0-9a-fA-F]+),\s*0x([0-9a-fA-F]+)\)') {
            $params = @('0x' + $Matches[1], '0x' + $Matches[2], '0x' + $Matches[3], '0x' + $Matches[4])
        }
        $dumpName = if ($_.Message -match 'Minidump\\([^.]+\.dmp)') { $Matches[1] } else { $null }
        [PSCustomObject]@{
            Time     = $_.TimeCreated.ToString('o')
            Code     = $code
            Params   = $params
            DumpName = $dumpName
        }
    })
} catch {}

# 3. Kernel-Power 41 events (unexpected shutdowns; some are hangs not BSODs)
$kernelPower41 = @()
try {
    $kernelPower41 = @(Get-WinEvent -FilterHashtable @{
        LogName='System'; ID=41;
        ProviderName='Microsoft-Windows-Kernel-Power';
        StartTime=(Get-Date).AddDays(-90)
    } -ErrorAction SilentlyContinue | ForEach-Object {
        [PSCustomObject]@{
            Time         = $_.TimeCreated.ToString('o')
            BugCheckCode = $_.Properties[2].Value
            IsHardHang   = ($_.Properties[2].Value -eq 0)   # 0 = no BSOD, just hard reset
        }
    })
} catch {}

# 4. Check for SDK Debuggers install
$sdkPaths = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\kd.exe",
    "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe"
)
$sdkInstalled = $sdkPaths | Where-Object { Test-Path $_ } | ForEach-Object { $_ }
$hasSDK = $sdkInstalled.Count -gt 0

# 5. WHEA errors (real hardware trouble, not driver)
$whea = @()
try {
    $whea = @(Get-WinEvent -FilterHashtable @{
        LogName='System';
        ProviderName='Microsoft-Windows-WHEA-Logger';
        StartTime=(Get-Date).AddDays(-90)
    } -ErrorAction SilentlyContinue | ForEach-Object {
        [PSCustomObject]@{
            Time  = $_.TimeCreated.ToString('o')
            Id    = $_.Id
            Level = $_.LevelDisplayName
        }
    })
} catch {}

[PSCustomObject]@{
    profile          = Get-MachineProfile
    dumps            = $dumps
    dumpCount        = $dumps.Count
    bugChecks        = $bugChecks
    bugCheckCount    = $bugChecks.Count
    kernelPower41    = $kernelPower41
    hardHangCount    = @($kernelPower41 | Where-Object IsHardHang).Count
    wheaErrors       = $whea
    wheaCount        = $whea.Count
    sdk = @{
        Installed = $hasSDK
        Paths     = $sdkInstalled
    }
    analysisReady    = ($hasSDK -and $dumps.Count -gt 0)
    installNeeded    = (-not $hasSDK -and ($dumps.Count -gt 0 -or $bugChecks.Count -gt 0))
} | ConvertTo-Json -Depth 6
