# Diagnose: enumerate installed UWP / Store apps + cross-reference with data/bloat_uwp.json.
# Read-only. No admin needed. Emits JSON to stdout.

param(
    [string]$DataDir = (Join-Path $PSScriptRoot '..\..\data')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')

$bloat = (Get-Content (Join-Path $DataDir 'bloat_uwp.json') -Raw | ConvertFrom-Json)

function Get-BloatVerdict {
    param([string]$Name)
    foreach ($p in $bloat.safe.PSObject.Properties)  { if ($Name -like "$($p.Name)*") { return @{ verdict='DISABLE-SAFE'; reason=$p.Value; category='safe'  } } }
    foreach ($p in $bloat.ask.PSObject.Properties)   { if ($Name -like "$($p.Name)*") { return @{ verdict='MAYBE';        reason=$p.Value; category='ask'   } } }
    foreach ($p in $bloat.never.PSObject.Properties) {
        $pat = $p.Name -replace '\.\*$',''
        if ($Name -like "$pat*") { return @{ verdict='KEEP'; reason=$p.Value; category='never' } }
    }
    return @{ verdict='UNCLASSIFIED'; reason=''; category='other' }
}

$packages = Get-AppxPackage -ErrorAction SilentlyContinue |
    Where-Object { -not $_.IsFramework -and $_.SignatureKind -ne 'System' -or $_.Publisher -match 'Microsoft|Realtek|Nvidia|AMD|Lenovo' } |
    ForEach-Object {
        $v = Get-BloatVerdict -Name $_.Name
        [PSCustomObject]@{
            Name         = $_.Name
            FullPackage  = $_.PackageFullName
            Publisher    = ($_.Publisher -replace '^CN=([^,]+).*','$1')
            Architecture = $_.Architecture
            InstallLoc   = $_.InstallLocation
            Verdict      = $v.verdict
            Reason       = $v.reason
            Category     = $v.category
        }
    }

# Winget packages that aren't UWP but are on our bloat list too (e.g. some OEM installers)
$wingetList = @()
try {
    $wg = winget list --accept-source-agreements 2>&1 | Out-String
    $wingetList = $wg -split "`n" | Where-Object { $_ -match '^\S' -and $_ -notmatch '^Name\s+Id' -and $_.Trim().Length -gt 20 }
} catch {}

$summary = @{
    total         = $packages.Count
    byVerdict     = ($packages | Group-Object Verdict | ForEach-Object { @{ $_.Name = $_.Count } })
    safeCount     = @($packages | Where-Object Verdict -eq 'DISABLE-SAFE').Count
    askCount      = @($packages | Where-Object Verdict -eq 'MAYBE').Count
}

[PSCustomObject]@{
    profile     = Get-MachineProfile
    summary     = $summary
    packages    = $packages
    wingetTotal = $wingetList.Count
} | ConvertTo-Json -Depth 6
