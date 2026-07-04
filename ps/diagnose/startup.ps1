# Diagnose: enumerate every autostart location.
# Read-only. No admin needed. Emits JSON to stdout.
#
# Sources scanned:
#   HKLM \SOFTWARE\Microsoft\Windows\CurrentVersion\Run
#   HKLM \SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce
#   HKLM \SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run
#   HKLM \SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce
#   HKCU \SOFTWARE\Microsoft\Windows\CurrentVersion\Run
#   HKCU \SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce
#   Startup folder (per user)
#   Startup folder (all users)
#   Task Scheduler: user tasks with logon/boot triggers
#   Startup Apps (Explorer StartupApproved keys - reveal disabled autostarts)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')

$rows = New-Object System.Collections.Generic.List[object]

# Registry Run keys
$runKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
)
foreach ($k in $runKeys) {
    if (Test-Path $k) {
        $props = Get-ItemProperty $k -ErrorAction SilentlyContinue
        if ($props) {
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -match '^PS' -or $p.Name -eq '(default)') { continue }
                $rows.Add([PSCustomObject]@{
                    Source   = 'registry-run'
                    Location = $k
                    Name     = $p.Name
                    Command  = [string]$p.Value
                    Enabled  = $true  # Registry entries are enabled unless StartupApproved says otherwise
                })
            }
        }
    }
}

# Startup folders
$startupFolders = @(
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
)
foreach ($f in $startupFolders) {
    if (Test-Path $f) {
        Get-ChildItem $f -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $rows.Add([PSCustomObject]@{
                Source   = 'startup-folder'
                Location = $f
                Name     = $_.Name
                Command  = $_.FullName
                Enabled  = $true
            })
        }
    }
}

# StartupApproved - reveals disabled autostarts (Task Manager's Startup tab uses this)
$approvedKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
)
$approvedMap = @{}
foreach ($k in $approvedKeys) {
    if (Test-Path $k) {
        $props = Get-ItemProperty $k -ErrorAction SilentlyContinue
        if ($props) {
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -match '^PS' -or $p.Name -eq '(default)') { continue }
                # Byte[0] = 02 (enabled) or 03 (disabled by user via Task Manager)
                $firstByte = if ($p.Value -is [byte[]] -and $p.Value.Length -gt 0) { $p.Value[0] } else { 2 }
                $approvedMap[$p.Name] = ($firstByte -eq 2)
            }
        }
    }
}
# Overlay: mark existing rows as disabled if StartupApproved says so
foreach ($r in $rows) {
    if ($approvedMap.ContainsKey($r.Name)) {
        $r.Enabled = $approvedMap[$r.Name]
    }
}

# Task Scheduler: user tasks with logon or boot triggers
try {
    $tasks = Get-ScheduledTask -ErrorAction Stop | Where-Object {
        $_.State -ne 'Disabled' -and
        $_.TaskPath -notmatch '^\\Microsoft\\' -and
        ($_.Triggers | Where-Object { $_.CimClass.CimClassName -in @('MSFT_TaskLogonTrigger','MSFT_TaskBootTrigger') })
    }
    foreach ($t in $tasks) {
        $act = ($t.Actions | Select-Object -First 1)
        $cmd = if ($act) { "$($act.Execute) $($act.Arguments)".Trim() } else { '' }
        $rows.Add([PSCustomObject]@{
            Source   = 'task-scheduler'
            Location = "$($t.TaskPath)$($t.TaskName)"
            Name     = $t.TaskName
            Command  = $cmd
            Enabled  = ($t.State -ne 'Disabled')
        })
    }
} catch {
    # Scheduled task cmdlets may not work in constrained language mode - skip silently
}

# Emit
$summary = @{
    total       = $rows.Count
    enabled     = @($rows | Where-Object Enabled).Count
    disabled    = @($rows | Where-Object { -not $_.Enabled }).Count
    bySource    = ($rows | Group-Object Source | ForEach-Object { @{ $_.Name = $_.Count } })
}

[PSCustomObject]@{
    profile = Get-MachineProfile
    summary = $summary
    entries = $rows
} | ConvertTo-Json -Depth 6
