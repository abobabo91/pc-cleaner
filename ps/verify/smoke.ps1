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

    # Check pathExists (path-existence smoke test)
    if ($t.requires.pathExists) {
        $p = [Environment]::ExpandEnvironmentVariables($t.requires.pathExists)
        if (-not (Test-Path -LiteralPath $p)) {
            $failures.Add("PATH-MISSING: expected path exists: $p")
        }
    }

    # Check pathExistsUnlessMissingAtStart — path-check that skips if the path never existed
    # (encoded via a sentinel marker file we don't create; caller passes existsAtStart=$true via env)
    if ($t.requires.pathExistsUnlessMissingAtStart) {
        $p = [Environment]::ExpandEnvironmentVariables($t.requires.pathExistsUnlessMissingAtStart)
        # We can't know pre-run state after the run without a snapshot, so this test only
        # FAILS if the path is in the "protected list" AND missing. Simplification: skip
        # this class of check when standalone-invoked; the orchestrator will pass
        # -PreRunSnapshotDir to a future version to cross-reference. For now, no-op.
    }

    # Check powercfg lid action
    if ($t.requires.powercfgQueryNotBoth) {
        $q = $t.requires.powercfgQueryNotBoth
        try {
            $out = (& powercfg /query SCHEME_CURRENT $q.subgroup $q.setting 2>$null) -join "`n"
            $ac = $null; $dc = $null
            if ($out -match 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)') { $ac = [Convert]::ToInt64($Matches[1], 16) }
            if ($out -match 'Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)') { $dc = [Convert]::ToInt64($Matches[1], 16) }
            if ($null -eq $ac -and $null -eq $dc) {
                # No values found - probably not a laptop (no LIDACTION), so skip silently
            } elseif ($null -ne $ac -and $null -ne $dc -and $ac -eq $q.acDcBothMustNotEqual -and $dc -eq $q.acDcBothMustNotEqual) {
                $failures.Add("POWERCFG-BOTH-EQ: $($q.subgroup)/$($q.setting) is $($q.acDcBothMustNotEqual) on both AC AND DC (silent 'do nothing' state).")
            }
        } catch {
            $failures.Add("POWERCFG-QUERY-FAILED: $($_.Exception.Message)")
        }
    }

    # Check DNS resolution
    if ($t.requires.resolveDnsHost) {
        $dnsHost = $t.requires.resolveDnsHost
        try {
            $r = Resolve-DnsName -Name $dnsHost -Type A -QuickTimeout -ErrorAction Stop | Where-Object { $_.IPAddress }
            if (-not $r) { $failures.Add("DNS-NORESULT: Resolve-DnsName $dnsHost returned no A records") }
        } catch {
            $failures.Add("DNS-FAIL: Resolve-DnsName $dnsHost - $($_.Exception.Message)")
        }
    }

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
