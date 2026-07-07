# Orchestrator helper — runs every module's diagnose script in parallel,
# reads the machine profile + every data/*.json rule file, and emits ONE
# consolidated evidence.json for Claude to reason over.
#
# This exists so Claude doesn't have to invoke each diagnose script as a
# separate Bash call — that's slow (each call has overhead) and error-prone
# (any failed call breaks the reasoning flow). One-shot: run this, read the
# output, build the plan.
#
# Does NOT do reasoning. Doesn't build plan.json files. Doesn't decide what
# to disable. That's Claude's job with the module docs as the rulebook.
#
# Read-only. No admin needed for the collection itself (individual diagnose
# scripts declare their own admin needs).
#
# Usage:
#   .\ps\orchestrate\collect_evidence.ps1 -SnapshotDir <path> [-Modules services,bloat,...]
#
# Emits: <SnapshotDir>\evidence.json

param(
    [Parameter(Mandatory=$true)][string]$SnapshotDir,
    [string[]]$Modules = @('profile','services','startup','bloat','privacy','explorer','storage'),
    [switch]$IncludeOptional
)

$ErrorActionPreference = 'Continue'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent  # -> pc-cleaner/
$dataDir = Join-Path $root 'data'
$diagnoseDir = Join-Path $root 'ps\diagnose'

if (-not (Test-Path $SnapshotDir)) { New-Item -ItemType Directory -Path $SnapshotDir -Force | Out-Null }

if ($IncludeOptional) {
    $Modules = @($Modules) + @('power','network','defender','crashdumps','tray-taskbar','unused-apps')
    $Modules = $Modules | Select-Object -Unique
}

Write-Host "Collecting evidence for $($Modules.Count) module(s)..." -ForegroundColor Cyan

# Run diagnose scripts in parallel via Start-Job. Each writes its JSON to
# a per-module file so we don't have to serialize stdout parsing.
$jobs = @{}
foreach ($m in $Modules) {
    $script = Join-Path $diagnoseDir "$m.ps1"
    if (-not (Test-Path $script)) {
        Write-Host "  skip $m (no diagnose script)" -ForegroundColor DarkYellow
        continue
    }
    $outFile = Join-Path $SnapshotDir "diagnose_$m.json"
    $jobs[$m] = Start-Job -ArgumentList $script, $outFile -ScriptBlock {
        param($s, $o)
        try {
            $result = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $s 2>$null
            $result | Set-Content -Path $o -Encoding UTF8
            return @{ ok = $true; file = $o }
        } catch {
            return @{ ok = $false; error = $_.Exception.Message }
        }
    }
}

# Wait for all with a total-run timeout of 120s (each diagnose targets <10s)
$deadline = (Get-Date).AddSeconds(120)
$moduleResults = @{}
foreach ($m in $jobs.Keys) {
    $remaining = ($deadline - (Get-Date)).TotalSeconds
    if ($remaining -lt 1) { $remaining = 1 }
    $done = $jobs[$m] | Wait-Job -Timeout $remaining
    if (-not $done) {
        $jobs[$m] | Stop-Job
        $moduleResults[$m] = @{ status = 'TIMEOUT' }
        Write-Host "  TIMEOUT $m" -ForegroundColor Red
        continue
    }
    $r = Receive-Job $jobs[$m]
    Remove-Job $jobs[$m]
    if ($r.ok -and (Test-Path $r.file)) {
        try {
            $raw = Get-Content -Path $r.file -Raw
            $moduleResults[$m] = @{
                status  = 'OK'
                file    = $r.file
                summary = try { ($raw | ConvertFrom-Json).summary } catch { $null }
            }
            Write-Host "  ok $m" -ForegroundColor Green
        } catch {
            $moduleResults[$m] = @{ status = 'PARSE-FAIL'; file = $r.file; error = $_.Exception.Message }
            Write-Host "  parse-fail $m" -ForegroundColor DarkYellow
        }
    } else {
        $moduleResults[$m] = @{ status = 'FAIL'; error = $r.error }
        Write-Host "  FAIL $m - $($r.error)" -ForegroundColor Red
    }
}

# Read every data/*.json rule file so Claude can walk inference rules
# without a second read pass.
$dataFiles = Get-ChildItem -Path $dataDir -Filter '*.json' -File | Sort-Object Name
$dataIndex = @{}
foreach ($f in $dataFiles) {
    try {
        $content = Get-Content -Path $f.FullName -Raw
        $dataIndex[$f.BaseName] = @{
            path  = $f.FullName
            bytes = $f.Length
            head  = $content.Substring(0, [Math]::Min(200, $content.Length))
        }
    } catch { }
}

# Machine profile — canonical source is the profile diagnose output
$profilePath = Join-Path $SnapshotDir 'diagnose_profile.json'
$machineProfile = $null
if (Test-Path $profilePath) {
    try { $machineProfile = Get-Content $profilePath -Raw | ConvertFrom-Json } catch {}
}

# Consolidated evidence blob
$evidence = [ordered]@{
    generatedAt = (Get-Date).ToString('o')
    snapshotDir = $SnapshotDir
    modulesRun  = $Modules
    machineProfile = $machineProfile
    modules     = $moduleResults
    dataFiles   = $dataIndex
    priorities  = @(
        '1. Tripwire (data/services_tripwire.json) - always wins',
        '2. Hardware detection (Get-PnpDevice, WMI)',
        '3. Activity checklist ticks (data/activity_checklist.json + user answers)',
        '4. Forensic signals (UserAssist, Prefetch) - override UNticked boxes only',
        '5. Module inference rules (skill/modules/*.md) - fallback',
        'Default when everything silent: KEEP.'
    )
    nextSteps = @(
        'Ask user the 2 baseline questions if not already answered.',
        'Ask user the activity checklist (data/activity_checklist.json).',
        'Build per-module plan.json files with confirmed:true on all ask-gated entries whose checklist ticks or inference rules resolved them.',
        'Present the unified plan preview (see skill/SKILL.md).',
        'Ask Apply/Change/Cancel.',
        'On Apply: invoke each ps/apply/<module>.ps1 in module order.',
        'Run ps/verify/smoke.ps1 after.'
    )
}

$outPath = Join-Path $SnapshotDir 'evidence.json'
$evidence | ConvertTo-Json -Depth 8 | Set-Content -Path $outPath -Encoding UTF8

Write-Host ""
Write-Host "Evidence collected in $outPath" -ForegroundColor Cyan
Write-Host "  Modules ok:    $(@($moduleResults.Values | Where-Object { $_.status -eq 'OK' }).Count)" -ForegroundColor Green
Write-Host "  Modules fail:  $(@($moduleResults.Values | Where-Object { $_.status -ne 'OK' }).Count)" -ForegroundColor Yellow
Write-Host "  Data files:    $($dataIndex.Count)" -ForegroundColor Gray
Write-Host ""
Write-Host "Claude: read $outPath and proceed with the plan build per SKILL.md." -ForegroundColor Cyan
