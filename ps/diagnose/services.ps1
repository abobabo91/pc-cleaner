# Diagnose: enumerate all services + label with default categorization from data/.
# Read-only. No admin needed. Emits JSON to stdout.
#
# Usage:
#   .\ps\diagnose\services.ps1 > out.json

param(
    [string]$DataDir = (Join-Path $PSScriptRoot '..\..\data')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')

$tripwireJson  = Join-Path $DataDir 'services_tripwire.json'
$safeJson      = Join-Path $DataDir 'services_disable_safe.json'

$tripwire = (Get-Content $tripwireJson  -Raw | ConvertFrom-Json).services
$safe     = (Get-Content $safeJson      -Raw | ConvertFrom-Json).categories

# Build a lookup: service name -> { verdict, reason, backs, category }
# Tripwire schema is either legacy (string reason) or new (object with reason + backs).
$defaults = @{}
foreach ($p in $tripwire.PSObject.Properties) {
    if ($p.Value -is [string]) {
        $defaults[$p.Name] = @{ verdict = 'KEEP-TRIPWIRE'; reason = $p.Value; backs = @(); category = 'tripwire' }
    } else {
        $defaults[$p.Name] = @{
            verdict  = 'KEEP-TRIPWIRE'
            reason   = $p.Value.reason
            backs    = @($p.Value.backs)
            category = 'tripwire'
        }
    }
}
foreach ($cat in $safe.PSObject.Properties) {
    $catName    = $cat.Name
    $catData    = $cat.Value
    if ($catName -eq '_comment') { continue }
    foreach ($svc in $catData.services.PSObject.Properties) {
        # Don't let disable_safe silently override a tripwire entry (belt-and-suspenders).
        if ($defaults.ContainsKey($svc.Name) -and $defaults[$svc.Name].verdict -eq 'KEEP-TRIPWIRE') { continue }
        $defaults[$svc.Name] = @{
            verdict  = 'DISABLE-SAFE'
            reason   = "$catName - $($svc.Value)"
            backs    = @()
            category = $catName
        }
    }
}

# Enumerate live services
$all = Get-CimInstance Win32_Service

$rows = foreach ($s in $all) {
    $d = $defaults[$s.Name]
    if (-not $d) {
        # Fall back to whatever hints we can from the running state
        $d = @{ verdict = 'UNCLASSIFIED'; reason = ''; category = 'other' }
    }
    [PSCustomObject]@{
        Name         = $s.Name
        DisplayName  = $s.DisplayName
        StartMode    = $s.StartMode
        State        = $s.State
        Description  = $s.Description
        PathName     = $s.PathName
        StartName    = $s.StartName
        Verdict      = $d.verdict
        Reason       = $d.reason
        Backs        = $d.backs
        Category     = $d.category
    }
}

$summary = @{
    total       = $rows.Count
    byVerdict   = ($rows | Group-Object Verdict | ForEach-Object { @{ $_.Name = $_.Count } })
    byStartMode = ($rows | Group-Object StartMode | ForEach-Object { @{ $_.Name = $_.Count } })
    byState     = ($rows | Group-Object State | ForEach-Object { @{ $_.Name = $_.Count } })
}

[PSCustomObject]@{
    profile  = Get-MachineProfile
    summary  = $summary
    services = $rows
} | ConvertTo-Json -Depth 6
