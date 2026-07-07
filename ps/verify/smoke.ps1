# UX smoke test runner. Called by the orchestrator after every module apply
# (and can be run standalone). Reads data/ux_smoke_tests.json, checks each
# test's requirements, prints a table of PASS/FAIL, and returns a JSON blob
# on stdout so the orchestrator can correlate a failure to the last change.
#
# Read-only. No admin needed.
#
# Usage:
#   .\ps\verify\smoke.ps1                          # runs all tests
#   .\ps\verify\smoke.ps1 -Test bt_pairing_wizard  # runs one test
#   .\ps\verify\smoke.ps1 -Json                    # JSON output only (for orchestrator)

param(
    [string]$DataDir = (Join-Path $PSScriptRoot '..\..\data'),
    [string]$Test,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$smokeJson = Join-Path $DataDir 'ux_smoke_tests.json'
if (-not (Test-Path $smokeJson)) {
    Write-Error "Smoke tests data file not found: $smokeJson"
    exit 2
}

$config = Get-Content $smokeJson -Raw | ConvertFrom-Json
$tests = $config.tests
if ($Test) { $tests = $tests | Where-Object { $_.id -eq $Test } }
if (-not $tests) { Write-Error "No matching tests."; exit 2 }

$results = New-Object System.Collections.Generic.List[object]

foreach ($t in $tests) {
    $failures = New-Object System.Collections.Generic.List[string]

    # Check servicesRunningOrManual
    if ($t.requires.servicesRunningOrManual) {
        foreach ($n in $t.requires.servicesRunningOrManual) {
            $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
            if (-not $svc) {
                # Some services are per-user template services (e.g. WpnUserService_bd465)
                $tmpl = Get-Service -Name "$n*" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($tmpl) { $svc = $tmpl }
            }
            if (-not $svc) {
                $failures.Add("MISSING: $n (service not found on this machine)")
                continue
            }
            if ($svc.StartType -eq 'Disabled') {
                $failures.Add("DISABLED: $($svc.Name) (StartType=Disabled, expected Manual/Automatic)")
            }
        }
    }

    # Check servicesNotDisabled (weaker check — only fail if explicitly Disabled)
    if ($t.requires.servicesNotDisabled) {
        foreach ($n in $t.requires.servicesNotDisabled) {
            $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
            if ($svc -and $svc.StartType -eq 'Disabled') {
                $failures.Add("DISABLED (soft-required): $($svc.Name)")
            }
        }
    }

    # Optional deep-link probe (process_check_after_deep_link)
    # UWP apps activate an existing process instead of spawning a new PID, so we can't
    # detect success by "new PID appeared". Instead: launch the URI, then just check
    # the process EXISTS (running or newly-started) within timeout. If Settings is
    # completely broken the process won't be there at all.
    if (-not $Json -and $t.probe.type -eq 'process_check_after_deep_link' -and $t.probe.uri) {
        $procName = $t.probe.expectedProcess
        try {
            Start-Process $t.probe.uri -ErrorAction SilentlyContinue
        } catch {
            $failures.Add("DEEP-LINK-LAUNCH-FAILED: $($t.probe.uri) - $($_.Exception.Message)")
        }
        $timeout = if ($t.probe.timeoutSeconds) { $t.probe.timeoutSeconds } else { 10 }
        $deadline = (Get-Date).AddSeconds($timeout)
        $seen = $false
        while ((Get-Date) -lt $deadline) {
            if (Get-Process -Name $procName -ErrorAction SilentlyContinue) { $seen = $true; break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $seen) {
            $failures.Add("DEEP-LINK-NO-PROCESS: launched $($t.probe.uri) but $procName is not running after ${timeout}s")
        }
    }

    $result = [PSCustomObject]@{
        id       = $t.id
        flow     = $t.flow
        status   = if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
        failures = $failures.ToArray()
        remedy   = if ($failures.Count -gt 0) { $t.onFailure } else { $null }
    }
    $results.Add($result)
}

if ($Json) {
    $results | ConvertTo-Json -Depth 6
} else {
    Write-Host ""
    Write-Host "===== UX smoke tests =====" -ForegroundColor Cyan
    foreach ($r in $results) {
        $color = if ($r.status -eq 'PASS') { 'Green' } else { 'Red' }
        Write-Host ("[{0}] {1}  --  {2}" -f $r.status, $r.id, $r.flow) -ForegroundColor $color
        if ($r.failures) {
            foreach ($f in $r.failures) { Write-Host "       $f" -ForegroundColor DarkYellow }
            Write-Host "       remedy: $($r.remedy)" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    $failCount = @($results | Where-Object { $_.status -eq 'FAIL' }).Count
    if ($failCount -gt 0) {
        Write-Host "$failCount smoke test(s) failed." -ForegroundColor Red
        exit 1
    } else {
        Write-Host "All smoke tests passed." -ForegroundColor Green
    }
}
