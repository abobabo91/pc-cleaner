# Apply: power / sleep / WLAN LPS tweaks from a plan JSON.
# REQUIRES ADMIN for HKLM WLAN class-key writes.
# Signals pendingWLANCycle to orchestrator instead of restarting adapter inline.

param(
    [Parameter(Mandatory=$true)][string]$Plan,
    [string]$SnapshotDir,
    [switch]$IKnowWhatImDoing
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')

if (-not $SnapshotDir) { $SnapshotDir = New-SnapshotDir -Module 'power' }
$log = Join-Path $SnapshotDir 'apply.log'
"===== power apply started $(Get-Date -Format o) =====" | Out-File $log -Encoding UTF8

$planData = Get-Content $Plan -Raw | ConvertFrom-Json

# promptRequired enforcement — added 2026-07-07 after audit. Recipes flagged with
# promptRequired:true (lid_do_nothing, usb_selective_suspend_off) can only be
# applied when the plan entry has confirmed:true, meaning the orchestrator got
# an explicit user answer. Prevents silent lid-close-does-nothing surprises.
$recipesJson = Join-Path $PSScriptRoot '..\..\data\power_recipes.json'
$promptRequiredIds = @()
if (Test-Path $recipesJson) {
    $recipesData = Get-Content $recipesJson -Raw | ConvertFrom-Json
    $promptRequiredIds = @($recipesData.recipes | Where-Object { $_.promptRequired } | ForEach-Object { $_.id })
}
$blockedRecipes = New-Object System.Collections.Generic.List[string]

# powercfg: export active plan for revert
$powExport = Join-Path $SnapshotDir 'active-plan.pow'
$activeGuid = ((powercfg /getactivescheme) -match '\bGUID: ([a-f0-9-]+)') | Out-Null; $activeGuid = $Matches[1]
powercfg /export "`"$powExport`"" $activeGuid | Out-Null
Write-Log $log 'SNAP' "Active plan exported to $powExport"

$reverts = New-Object System.Collections.Generic.List[string]

# 1. powercfg tweaks
foreach ($t in @($planData.powercfg)) {
    $sub = $t.subgroup; $set = $t.setting

    # Enforce promptRequired
    if ($t.id -and ($promptRequiredIds -contains $t.id) -and -not $t.confirmed -and -not $IKnowWhatImDoing) {
        Write-Log $log 'BLOCK' "Recipe '$($t.id)' requires user confirmation (promptRequired:true in data/power_recipes.json). Set confirmed:true in the plan entry after asking the user, or pass -IKnowWhatImDoing."
        $blockedRecipes.Add($t.id)
        continue
    }

    try {
        # Capture originals
        $before = powercfg /query SCHEME_CURRENT $sub $set 2>$null
        $acBefore = if ($before -match 'Current AC Power Setting Index: 0x([0-9a-f]+)') { [Convert]::ToInt64($Matches[1], 16) } else { $null }
        $dcBefore = if ($before -match 'Current DC Power Setting Index: 0x([0-9a-f]+)') { [Convert]::ToInt64($Matches[1], 16) } else { $null }

        if ($t.acValue -ne $null) {
            powercfg /setacvalueindex SCHEME_CURRENT $sub $set $t.acValue | Out-Null
        }
        if ($t.dcValue -ne $null) {
            powercfg /setdcvalueindex SCHEME_CURRENT $sub $set $t.dcValue | Out-Null
        }
        powercfg /setactive SCHEME_CURRENT | Out-Null
        Write-Log $log 'APPLY' "$($t.description): AC=$($t.acValue) DC=$($t.dcValue) (was AC=$acBefore DC=$dcBefore)"

        if ($null -ne $acBefore) { $reverts.Add("powercfg /setacvalueindex SCHEME_CURRENT $sub $set $acBefore") }
        if ($null -ne $dcBefore) { $reverts.Add("powercfg /setdcvalueindex SCHEME_CURRENT $sub $set $dcBefore") }
    } catch {
        Write-Log $log 'ERR' "$($t.description): $($_.Exception.Message)"
    }
}

# 2. Hibernation on (if requested)
if ($planData.enableHibernate) {
    if (Test-Admin) {
        & powercfg /hibernate on 2>&1 | Out-Null
        Write-Log $log 'APPLY' "Hibernation enabled system-wide"
        $reverts.Add("# To disable hibernation: powercfg /hibernate off")
    } else {
        Write-Log $log 'SKIP-ADMIN' "powercfg /hibernate on - needs elevation"
    }
}

# 3. WLAN driver LPS keys (combo card BT range fix)
if ($planData.wlanLPS -and $planData.wlanLPS.classKeyPath -and (Test-Admin)) {
    $classPath = $planData.wlanLPS.classKeyPath
    foreach ($f in @($planData.wlanLPS.flags)) {
        try {
            $originalVal = (Get-ItemProperty -Path $classPath -Name $f.name -ErrorAction SilentlyContinue).$($f.name)
            Set-ItemProperty -Path $classPath -Name $f.name -Value $f.value -Type DWord -ErrorAction Stop
            Write-Log $log 'APPLY-WLAN' "$($f.name) = $($f.value)  (was $originalVal)"
            if ($null -ne $originalVal) {
                $reverts.Add("Set-ItemProperty -Path '$classPath' -Name '$($f.name)' -Value $originalVal -Type DWord")
            }
        } catch {
            Write-Log $log 'ERR' "WLAN $($f.name): $($_.Exception.Message)"
        }
    }
    # Signal to orchestrator
    $runStateFile = Join-Path (Split-Path $SnapshotDir -Parent) 'run-state.json'
    $runState = if (Test-Path $runStateFile) { Get-Content $runStateFile -Raw | ConvertFrom-Json } else { [PSCustomObject]@{} }
    $runState | Add-Member -MemberType NoteProperty -Name pendingWLANCycle -Value $true -Force
    $runState | ConvertTo-Json | Set-Content $runStateFile -Encoding UTF8
}

$revertScript = Join-Path $SnapshotDir 'revert.ps1'
$header = "# Auto-generated by pc-cleaner (power). Restore power settings + WLAN driver keys.`n# Full plan export: $powExport (import with 'powercfg /import <path>').`n`n"
Set-Content -Path $revertScript -Value ($header + ($reverts -join "`n")) -Encoding UTF8

if ($blockedRecipes.Count -gt 0) {
    $blockedJson = Join-Path $SnapshotDir 'blocked-prompt-required.json'
    $blockedRecipes | ConvertTo-Json | Set-Content -Path $blockedJson -Encoding UTF8
    Write-Host ""
    Write-Host "Skipped $($blockedRecipes.Count) recipe(s) missing user confirmation:" -ForegroundColor Yellow
    foreach ($id in $blockedRecipes) { Write-Host "  - $id" -ForegroundColor Yellow }
}

"===== power apply done $(Get-Date -Format o) =====" | Add-Content -Path $log
Write-Host "Snapshot: $SnapshotDir"
Write-Host "Revert  : $revertScript"
