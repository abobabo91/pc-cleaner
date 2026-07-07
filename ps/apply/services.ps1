# Apply: disable services from a plan JSON. Snapshots first. Emits revert.ps1.
# REQUIRES ADMIN.
#
# Plan JSON shape:
#   {
#     "disable":       ["Spooler", "DiagTrack", ...],
#     "enableManual":  ["ssh-agent"],
#     "enableAuto":    []
#   }
#
# Tripwire enforcement: any name in data/services_tripwire.json is REFUSED
# regardless of what's in the plan, unless -IKnowWhatImDoing is passed.
# This is a defence-in-depth backstop for the Claude reasoning layer: even
# if the module doc / question flow gets confused and adds a tripwire name
# to plan.disable, we don't touch it. See 2026-07-07 BT pairing incident.

param(
    [Parameter(Mandatory=$true)][string]$Plan,
    [string]$SnapshotDir,
    [switch]$IKnowWhatImDoing
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')
Assert-Admin

if (-not $SnapshotDir) { $SnapshotDir = New-SnapshotDir -Module 'services' }
$log = Join-Path $SnapshotDir 'apply.log'
"===== services apply started $(Get-Date -Format o) =====" | Out-File $log -Encoding UTF8

# Load tripwire — accept both legacy (string reason) and new (object with reason+backs) schemas
$tripwireJson = Join-Path $PSScriptRoot '..\..\data\services_tripwire.json'
$tripwire = @{}
if (Test-Path $tripwireJson) {
    $tw = (Get-Content $tripwireJson -Raw | ConvertFrom-Json).services
    foreach ($p in $tw.PSObject.Properties) {
        if ($p.Value -is [string]) {
            $tripwire[$p.Name] = @{ reason = $p.Value; backs = @() }
        } else {
            $tripwire[$p.Name] = @{ reason = $p.Value.reason; backs = @($p.Value.backs) }
        }
    }
    Write-Log $log 'INFO' "Tripwire loaded: $($tripwire.Count) protected services"
} else {
    Write-Log $log 'WARN' "Tripwire file missing: $tripwireJson - no protection active"
}

# Snapshot
$snap = Join-Path $SnapshotDir 'snapshot.csv'
Get-Service | Select-Object Name, DisplayName, StartType, Status |
    Export-Csv -Path $snap -NoTypeInformation -Encoding UTF8
Write-Log $log 'SNAP' "Wrote $snap"

$planData = Get-Content $Plan -Raw | ConvertFrom-Json
$disable       = @($planData.disable)
$enableManual  = @($planData.enableManual)
$enableAuto    = @($planData.enableAuto)

# Tripwire enforcement
$blocked = New-Object System.Collections.Generic.List[string]
$disableFiltered = New-Object System.Collections.Generic.List[string]
foreach ($n in $disable) {
    if ($tripwire.ContainsKey($n) -and -not $IKnowWhatImDoing) {
        $backs = if ($tripwire[$n].backs.Count -gt 0) { " Backs: " + ($tripwire[$n].backs -join '; ') } else { '' }
        Write-Log $log 'BLOCK' "Refusing to disable tripwire service '$n'. Reason: $($tripwire[$n].reason).$backs"
        $blocked.Add($n)
    } else {
        $disableFiltered.Add($n)
    }
}
if ($blocked.Count -gt 0) {
    Write-Host ""
    Write-Host "REFUSED to disable $($blocked.Count) tripwire service(s):" -ForegroundColor Yellow
    foreach ($n in $blocked) {
        Write-Host ("  - {0}  ({1})" -f $n, $tripwire[$n].reason) -ForegroundColor Yellow
    }
    Write-Host "Override with -IKnowWhatImDoing (not recommended)." -ForegroundColor DarkGray
    Write-Host ""
}

$reverts = New-Object System.Collections.Generic.List[string]

foreach ($n in $disableFiltered) {
    try {
        $svc = Get-Service -Name $n -ErrorAction Stop
        $originalStartType = $svc.StartType
        if ($svc.Status -eq 'Running') {
            try { Stop-Service -Name $n -Force -ErrorAction Stop } catch {
                Write-Log $log 'WARN' "Could not stop $n : $($_.Exception.Message)"
            }
        }
        try {
            Set-Service -Name $n -StartupType Disabled -ErrorAction Stop
            Write-Log $log 'APPLY' "$n disabled (was $originalStartType)"
        } catch {
            # Fallback for per-user template services + protected keys: registry Start=4
            $regKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$($n -replace '_[a-f0-9]{4,6}$','')"
            if (Test-Path $regKey) {
                try {
                    Set-ItemProperty -Path $regKey -Name Start -Value 4 -Type DWord -ErrorAction Stop
                    Write-Log $log 'APPLY-REG' "$n disabled via registry ($regKey)"
                } catch {
                    Write-Log $log 'ERR' "$n : both Set-Service and registry failed. $($_.Exception.Message)"
                    continue
                }
            } else {
                Write-Log $log 'ERR' "$n : Set-Service failed and no fallback registry key found."
                continue
            }
        }
        $reverts.Add("Set-Service -Name '$n' -StartupType $originalStartType -ErrorAction SilentlyContinue")
    } catch {
        Write-Log $log 'ERR' "$n : $($_.Exception.Message)"
    }
}

foreach ($n in $enableManual) {
    try {
        $svc = Get-Service -Name $n -ErrorAction Stop
        $original = $svc.StartType
        Set-Service -Name $n -StartupType Manual -ErrorAction Stop
        try { Start-Service -Name $n -ErrorAction Stop } catch {}
        Write-Log $log 'APPLY' "$n set Manual + started (was $original)"
        $reverts.Add("Set-Service -Name '$n' -StartupType $original")
    } catch {
        Write-Log $log 'ERR' "$n enableManual : $($_.Exception.Message)"
    }
}

foreach ($n in $enableAuto) {
    try {
        $svc = Get-Service -Name $n -ErrorAction Stop
        $original = $svc.StartType
        Set-Service -Name $n -StartupType Automatic -ErrorAction Stop
        try { Start-Service -Name $n -ErrorAction Stop } catch {}
        Write-Log $log 'APPLY' "$n set Automatic + started (was $original)"
        $reverts.Add("Set-Service -Name '$n' -StartupType $original")
    } catch {
        Write-Log $log 'ERR' "$n enableAuto : $($_.Exception.Message)"
    }
}

# Emit revert script
$revertScript = Join-Path $SnapshotDir 'revert.ps1'
$header = "# Auto-generated by pc-cleaner. Restore services to their state before this apply.`n# Snapshot CSV: $snap`n`n"
$body = $reverts -join "`n"
Set-Content -Path $revertScript -Value ($header + $body) -Encoding UTF8

# Emit blocked-list for orchestrator + reports
if ($blocked.Count -gt 0) {
    $blockedJson = Join-Path $SnapshotDir 'blocked-tripwire.json'
    $blocked | ConvertTo-Json | Set-Content -Path $blockedJson -Encoding UTF8
}

"===== services apply done $(Get-Date -Format o) =====" | Add-Content -Path $log

# Post-apply UX smoke test — surface regressions immediately
$smokeScript = Join-Path $PSScriptRoot '..\verify\smoke.ps1'
if (Test-Path $smokeScript) {
    Write-Host ""
    Write-Host "Running UX smoke tests..." -ForegroundColor Cyan
    try {
        $smokeResults = & $smokeScript -Json | ConvertFrom-Json
        $smokeOutJson = Join-Path $SnapshotDir 'smoke-results.json'
        $smokeResults | ConvertTo-Json -Depth 6 | Set-Content -Path $smokeOutJson -Encoding UTF8
        $fails = @($smokeResults | Where-Object { $_.status -eq 'FAIL' })
        if ($fails.Count -gt 0) {
            Write-Host ""
            Write-Host "WARNING: $($fails.Count) UX smoke test(s) failed after services apply." -ForegroundColor Red
            foreach ($f in $fails) {
                Write-Host ("  [FAIL] {0}  --  {1}" -f $f.id, $f.flow) -ForegroundColor Red
                foreach ($why in $f.failures) { Write-Host "         $why" -ForegroundColor DarkYellow }
            }
            Write-Host ""
            Write-Host "The last apply may have broken these flows. Revert: powershell -File $revertScript" -ForegroundColor DarkGray
        } else {
            Write-Host "All UX smoke tests passed." -ForegroundColor Green
        }
    } catch {
        Write-Log $log 'WARN' "Smoke test runner failed: $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "Snapshot dir: $SnapshotDir"
Write-Host "Revert with : powershell -File $revertScript"
