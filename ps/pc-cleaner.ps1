# pc-cleaner orchestrator entry point.
# Called by Claude from the skill. Handles snapshot dir setup, diagnose->apply pipeline,
# elevation delegation, and end-of-run finalize (deferred Explorer restart, WLAN cycle).
#
# Sub-commands:
#   start                       -> mkdir snapshot dir for this run, print its path
#   profile                     -> emit machine profile JSON (also saves to snapshot dir if -SnapshotDir given)
#   diagnose <module>           -> run ps\diagnose\<module>.ps1, save to <snapshot>/<module>/diagnose.json, print path
#   apply <module> <plan>       -> run ps\apply\<module>.ps1 -Plan <plan> -SnapshotDir <snapshot>/<module>; elevates if needed
#   finalize                    -> read run-state.json, restart Explorer + cycle WLAN if flagged
#   revert <snapshot>           -> run every module's revert.ps1 in the snapshot dir (order: reverse of apply)
#   list-modules                -> print all modules that have diagnose scripts
#
# Usage:
#   .\pc-cleaner.ps1 start
#   .\pc-cleaner.ps1 profile -SnapshotDir <path>
#   .\pc-cleaner.ps1 diagnose services -SnapshotDir <path>
#   .\pc-cleaner.ps1 apply services -Plan <path\to\plan.json> -SnapshotDir <path>
#   .\pc-cleaner.ps1 finalize -SnapshotDir <path>
#   .\pc-cleaner.ps1 revert -SnapshotDir <path>

param(
    [Parameter(Position=0)][string]$Command,
    [Parameter(Position=1)][string]$Module,
    [Parameter(Position=2)][string]$Plan,
    [string]$SnapshotDir
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib\common.ps1')

$Root = Split-Path $PSScriptRoot -Parent

function Start-Run {
    if (-not $SnapshotDir) {
        $SnapshotDir = Join-Path "$env:USERPROFILE\Desktop\pc-cleaner-snapshots" (Get-Date -Format 'yyyy-MM-ddTHH-mm-ss')
    }
    New-Item -ItemType Directory -Path $SnapshotDir -Force | Out-Null
    # Initialize empty run state
    @{
        started              = (Get-Date).ToString('o')
        pendingExplorerRestart = $false
        pendingWLANCycle     = $false
        modulesApplied       = @()
    } | ConvertTo-Json | Set-Content (Join-Path $SnapshotDir 'run-state.json') -Encoding UTF8
    Write-Output $SnapshotDir
}

function Invoke-DiagnoseModule {
    param([string]$Name)
    $script = Join-Path $PSScriptRoot "diagnose\$Name.ps1"
    if (-not (Test-Path $script)) { throw "No diagnose script: $script" }
    $json = powershell.exe -NoProfile -File $script
    if ($SnapshotDir) {
        $modDir = Join-Path $SnapshotDir $Name
        if (-not (Test-Path $modDir)) { New-Item -ItemType Directory -Path $modDir -Force | Out-Null }
        $out = Join-Path $modDir 'diagnose.json'
        $json | Set-Content $out -Encoding UTF8
        Write-Output $out
    } else {
        Write-Output $json
    }
}

function Invoke-ApplyModule {
    param([string]$Name, [string]$PlanPath)
    $script = Join-Path $PSScriptRoot "apply\$Name.ps1"
    if (-not (Test-Path $script)) { throw "No apply script: $script" }
    if (-not (Test-Path $PlanPath)) { throw "Plan not found: $PlanPath" }
    if (-not $SnapshotDir) { throw "-SnapshotDir is required for apply" }
    $modDir = Join-Path $SnapshotDir $Name
    if (-not (Test-Path $modDir)) { New-Item -ItemType Directory -Path $modDir -Force | Out-Null }
    # Elevate if not already
    if (Test-Admin) {
        & powershell.exe -NoProfile -File $script -Plan $PlanPath -SnapshotDir $modDir
    } else {
        Write-Host "[orchestrator] Elevating for $Name..."
        $p = Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File",$script,"-Plan",$PlanPath,"-SnapshotDir",$modDir -Wait -PassThru
        Write-Host "[orchestrator] Elevated exit: $($p.ExitCode)"
    }
    # Mark module applied
    $runStateFile = Join-Path $SnapshotDir 'run-state.json'
    $runState = Get-Content $runStateFile -Raw | ConvertFrom-Json
    $runState.modulesApplied = @($runState.modulesApplied + $Name)
    $runState | ConvertTo-Json | Set-Content $runStateFile -Encoding UTF8
}

function Complete-Run {
    if (-not $SnapshotDir) { throw "-SnapshotDir is required for finalize" }
    $runStateFile = Join-Path $SnapshotDir 'run-state.json'
    if (-not (Test-Path $runStateFile)) { throw "run-state.json missing in $SnapshotDir" }
    $runState = Get-Content $runStateFile -Raw | ConvertFrom-Json
    if ($runState.pendingExplorerRestart) {
        Write-Host "[finalize] Restarting Explorer..."
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep 1
        # Explorer usually auto-restarts; belt-and-suspenders:
        Start-Process explorer
    }
    if ($runState.pendingWLANCycle) {
        Write-Host "[finalize] Restarting WLAN adapter..."
        Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11' -and $_.Status -eq 'Up' } |
            ForEach-Object { Restart-NetAdapter -Name $_.Name -Confirm:$false }
    }
    Write-Host "[finalize] Run complete. Snapshot: $SnapshotDir"
    Write-Host "[finalize] Modules applied: $($runState.modulesApplied -join ', ')"
}

function Invoke-Revert {
    if (-not $SnapshotDir) { throw "-SnapshotDir is required for revert" }
    if (-not (Test-Path $SnapshotDir)) { throw "Snapshot not found: $SnapshotDir" }
    $runStateFile = Join-Path $SnapshotDir 'run-state.json'
    $modules = @()
    if (Test-Path $runStateFile) {
        $rs = Get-Content $runStateFile -Raw | ConvertFrom-Json
        $modules = $rs.modulesApplied
        [array]::Reverse($modules)
    } else {
        # Discover modules from subdirs
        $modules = Get-ChildItem $SnapshotDir -Directory | Select-Object -ExpandProperty Name
    }
    foreach ($m in $modules) {
        $revert = Join-Path $SnapshotDir "$m\revert.ps1"
        if (Test-Path $revert) {
            Write-Host "[revert] $m"
            if (Test-Admin) {
                & powershell.exe -NoProfile -File $revert
            } else {
                Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile","-File",$revert -Wait
            }
        } else {
            Write-Host "[revert] $m - no revert.ps1 found, skipping"
        }
    }
}

function List-Modules {
    Get-ChildItem (Join-Path $PSScriptRoot 'diagnose') -Filter *.ps1 | ForEach-Object {
        $name = $_.BaseName
        $hasApply = Test-Path (Join-Path $PSScriptRoot "apply\$name.ps1")
        [PSCustomObject]@{
            Module      = $name
            HasDiagnose = $true
            HasApply    = $hasApply
        }
    } | Format-Table -AutoSize
}

switch -Regex ($Command) {
    '^start$'          { Start-Run }
    '^profile$'        { Invoke-DiagnoseModule -Name 'profile' }
    '^diagnose$'       { Invoke-DiagnoseModule -Name $Module }
    '^apply$'          { Invoke-ApplyModule -Name $Module -PlanPath $Plan }
    '^finalize$'       { Complete-Run }
    '^revert$'         { Invoke-Revert }
    '^list-modules$'   { List-Modules }
    default {
        Write-Host "Usage: .\pc-cleaner.ps1 <start|profile|diagnose|apply|finalize|revert|list-modules>"
        Write-Host "See top of file for full parameter reference."
    }
}
