# Apply: install Windows SDK Debuggers (if requested), copy dumps to user location,
# run kd.exe !analyze -v on each, extract failing driver, write crash_linked_drivers.json
# for the drivers module to consume.
# REQUIRES ADMIN (to install SDK + read C:\Windows\Minidump).

param(
    [Parameter(Mandatory=$true)][string]$Plan,
    [string]$SnapshotDir
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')
Assert-Admin

if (-not $SnapshotDir) { $SnapshotDir = New-SnapshotDir -Module 'crashdumps' }
$log = Join-Path $SnapshotDir 'apply.log'
"===== crashdumps apply started $(Get-Date -Format o) =====" | Out-File $log -Encoding UTF8

$planData = Get-Content $Plan -Raw | ConvertFrom-Json
$dataDir = Join-Path $PSScriptRoot '..\..\data'

# 1. Install SDK Debuggers if needed
$sdkKd = "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\kd.exe"
if ($planData.installSDK -and -not (Test-Path $sdkKd)) {
    Write-Log $log 'INSTALL' "Installing Windows SDK Debuggers"
    $sdkUrls = Join-Path $dataDir 'sdk_urls.json'
    $url = if (Test-Path $sdkUrls) {
        (Get-Content $sdkUrls -Raw | ConvertFrom-Json).url
    } else { 'https://go.microsoft.com/fwlink/?linkid=2286561' }
    $args = if (Test-Path $sdkUrls) {
        (Get-Content $sdkUrls -Raw | ConvertFrom-Json).silentInstallArgs
    } else { '/features OptionId.WindowsDesktopDebuggers /quiet /norestart /ceip off' }
    $installer = Join-Path $env:TEMP 'winsdksetup.exe'
    try {
        Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -ErrorAction Stop
        $p = Start-Process -FilePath $installer -ArgumentList $args -Wait -PassThru
        Write-Log $log 'INSTALL' "SDK installer exit: $($p.ExitCode)"
    } catch {
        Write-Log $log 'ERR' "SDK download/install failed: $($_.Exception.Message)"
        # Fallback: winget
        try {
            winget install --id Microsoft.WindowsSDK --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-File $log -Append
        } catch { Write-Log $log 'ERR' "winget fallback failed too" }
    }
}

if (-not (Test-Path $sdkKd)) {
    Write-Log $log 'ABORT' "kd.exe not present at $sdkKd - cannot analyze"
    return
}

# 2. Copy minidumps to user-readable location
$dumpDir = Join-Path $SnapshotDir 'dumps'
New-Item -ItemType Directory -Path $dumpDir -Force | Out-Null
$dumps = @(Get-ChildItem 'C:\Windows\Minidump\*.dmp' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First ($planData.maxDumps ?? 10))
foreach ($d in $dumps) {
    try {
        Copy-Item -Path $d.FullName -Destination $dumpDir -Force -ErrorAction Stop
    } catch {
        Write-Log $log 'ERR' "copy $($d.Name): $($_.Exception.Message)"
    }
}
Write-Log $log 'COPY' "$($dumps.Count) minidumps copied to $dumpDir"

# 3. Run kd -z !analyze -v on each; extract failing driver name
$symcache = Join-Path $SnapshotDir 'symcache'
New-Item -ItemType Directory -Path $symcache -Force | Out-Null
$env:_NT_SYMBOL_PATH = "srv*$symcache*https://msdl.microsoft.com/download/symbols"

$knownDrivers = @{}
$knownDriversFile = Join-Path $dataDir 'known_drivers.json'
if (Test-Path $knownDriversFile) {
    $kd = Get-Content $knownDriversFile -Raw | ConvertFrom-Json
    foreach ($p in $kd.drivers.PSObject.Properties) { $knownDrivers[$p.Name] = $p.Value }
}
$bugCheckCodes = @{}
$bugCheckFile = Join-Path $dataDir 'bugcheck_codes.json'
if (Test-Path $bugCheckFile) {
    $bc = Get-Content $bugCheckFile -Raw | ConvertFrom-Json
    foreach ($e in $bc.codes) { $bugCheckCodes[$e.code] = $e }
}

$analysisResults = New-Object System.Collections.Generic.List[object]
$logDir = Join-Path $SnapshotDir 'analysis-logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

foreach ($d in Get-ChildItem "$dumpDir\*.dmp") {
    Write-Log $log 'ANALYZE' $d.Name
    $kdLog = Join-Path $logDir "$($d.BaseName).log"
    Start-Process -FilePath $sdkKd -ArgumentList "-z", "`"$($d.FullName)`"", "-logo", "`"$kdLog`"", "-c", "`"!analyze -v; q`"" -NoNewWindow -Wait | Out-Null
    if (-not (Test-Path $kdLog)) { continue }
    $content = Get-Content $kdLog -Raw
    $bugCheck = if ($content -match 'BUGCHECK_CODE:\s*([0-9A-Fa-f]+)') { '0x' + $Matches[1].ToUpper() } else { $null }
    $moduleName = if ($content -match 'MODULE_NAME:\s*(\S+)') { $Matches[1] } else { $null }
    $imageName = if ($content -match 'IMAGE_NAME:\s*(\S+)') { $Matches[1] } else { $null }
    $bucket = if ($content -match 'FAILURE_BUCKET_ID:\s*(\S+)') { $Matches[1] } else { $null }

    $ownerInfo = $null
    if ($moduleName -and $knownDrivers.ContainsKey($moduleName)) {
        $ownerInfo = $knownDrivers[$moduleName]
    }
    $bugCheckInfo = if ($bugCheck -and $bugCheckCodes.ContainsKey($bugCheck)) { $bugCheckCodes[$bugCheck] } else { $null }

    $analysisResults.Add([PSCustomObject]@{
        Dump         = $d.Name
        BugCheck     = $bugCheck
        BugCheckName = if ($bugCheckInfo) { $bugCheckInfo.name } else { $null }
        Module       = $moduleName
        Image        = $imageName
        Owner        = $ownerInfo
        Bucket       = $bucket
    })
}

# 4. Emit crash_linked_drivers.json in snapshot ROOT so drivers module can find it
$snapshotRoot = Split-Path $SnapshotDir -Parent
$linkedDriversFile = Join-Path $snapshotRoot 'crash_linked_drivers.json'
$drivers = $analysisResults | Group-Object Module | ForEach-Object {
    [PSCustomObject]@{
        Module = $_.Name
        CrashCount = $_.Count
        Owner = ($_.Group | Select-Object -First 1 -ExpandProperty Owner)
        BugChecks = @($_.Group.BugCheck | Sort-Object -Unique)
    }
} | Sort-Object CrashCount -Descending
$drivers | ConvertTo-Json -Depth 4 | Set-Content $linkedDriversFile -Encoding UTF8
Write-Log $log 'LINK' "Wrote $linkedDriversFile"

# 5. Summary
$results = Join-Path $SnapshotDir 'results.json'
$analysisResults | ConvertTo-Json -Depth 4 | Set-Content $results -Encoding UTF8

$revertScript = Join-Path $SnapshotDir 'revert.ps1'
Set-Content -Path $revertScript -Value "# crashdumps: no destructive changes; nothing to revert.`n# SDK install (if performed) can be removed via Apps & features > Windows Software Development Kit.`n" -Encoding UTF8

"===== crashdumps apply done $(Get-Date -Format o) =====" | Add-Content -Path $log
Write-Host "Results  : $results"
Write-Host "Linked   : $linkedDriversFile"
Write-Host "kd logs  : $logDir"
