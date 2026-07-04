# module: benchmark

Tier: CORE. Auto-runs twice: once as step 1 (baseline) and once as the final step (diff). No user prompts.

## Success criteria

At the end of a full pass the user has:
1. A `benchmark-before.json` and `benchmark-after.json` in the snapshot root.
2. A one-page diff table in the run log showing what actually improved (boot time, running services, RAM baseline, autostart count).
3. Honest reporting: if nothing measurably improved, say so.

## Flow

### 1. Diagnose (before)

Run `ps/diagnose/benchmark.ps1`. Emits JSON with these fields:

| Field | Source | Notes |
|---|---|---|
| `bootTimeSeconds` | Event ID 100 (source `Microsoft-Windows-Diagnostics-Performance/Operational`), `MainPathBootTime` from last boot | If Diagnostics-Performance log is disabled, fall back to Event 6013 uptime delta or `(Get-CimInstance Win32_OperatingSystem).LastBootUpTime` compared against Event 12 (kernel-boot) |
| `runningServicesCount` | `(Get-Service | Where State -eq Running).Count` | |
| `disabledServicesCount` | `(Get-Service | Where StartType -eq Disabled).Count` | |
| `autostartCount` | Registry Run + RunOnce (HKLM + HKCU, 32-bit + 64-bit), Startup folders (user + all-users), enabled scheduled tasks under `\` and `\Microsoft\Windows\` with LogonTrigger | Sum |
| `ramUsedMB`, `ramTotalMB` | `Get-CimInstance Win32_OperatingSystem` — TotalVisible/FreePhysical | Measure after `Start-Sleep 5` to let anything settle |
| `processCount` | `(Get-Process).Count` | |
| `handleCount`, `threadCount` | Sum across processes | |
| `pageFileMB` | `Win32_PageFileUsage.CurrentUsage` | |
| `diskFreeGB` | `Get-Volume C:` | |
| `powerPlanGuid`, `powerPlanName` | `powercfg /getactivescheme` | So the after-diff notices if the plan changed |

### 2. Persist as `benchmark-before.json`

Write to snapshot root. Also stash a small `<snapshotRoot>/benchmark-before.md` for easy human diff.

### 3. Other modules run

Benchmark waits until every other module has finished.

### 4. Diagnose (after)

Same script, second run. Persist as `benchmark-after.json`.

### 5. Diff and report

Compute a table:

| Metric | Before | After | Δ |
|---|---|---|---|
| Boot time | 42.3 s | (measured next boot) | — |
| Running services | 109 | 91 | -18 |
| Disabled services | 36 | 131 | +95 |
| Autostart entries | 27 | 14 | -13 |
| RAM used at idle | 6.1 GB | 5.4 GB | -0.7 GB |
| Processes | 187 | 162 | -25 |

Boot time cannot be re-measured without a reboot — flag it and tell the user "reboot, then run `/pc-cleaner benchmark` again to see the boot-time delta."

## Known gotchas

- `MainPathBootTime` needs `Microsoft-Windows-Diagnostics-Performance/Operational` enabled. It's on by default on Win11 Home/Pro but can be off on Enterprise-image machines. If empty, fall back to `LastBootUpTime` vs `Event 12` timestamp of the same boot — less precise but always available.
- RAM baseline is noisy. Sample 3 times 2 s apart and take the median. Even then, expect ±300 MB run-to-run.
- `Get-Process` inside PS 5.1 without elevation misses some system processes → handle/thread counts will be low compared to Task Manager. Note this in the JSON as `sampledElevated: bool` so before/after are comparable only if both were the same.
- Autostart count is deceptive: RunOnce entries auto-delete after firing. Compare only Run keys + Startup folder + LogonTrigger tasks; skip RunOnce.
- Windows re-enables some services on next boot via Trigger Start (Service Trigger Events). If the after-count of Disabled goes DOWN over a reboot, that's usually a trigger-started service, not a failure of your disable. Note this in the report.
- On S0ix laptops, "boot" from cold vs "resume from hibernate" show up as different Event 100s. Filter to the last cold boot (Event 27 kernel-boot with `BootType=0`).

## Curated defaults / Data files

None. Benchmark is pure measurement.

## Machine profile branches

- If `profile.flags.isLaptop=true`, additionally sample battery drain rate at idle over 60 s using two `powercfg /batteryreport` snapshots or `Win32_Battery.EstimatedChargeRemaining` delta. Report `idleDrainWattsEstimate`. Useful before/after `power` module to prove ASPM and USB selective suspend actually saved power.
- If `profile.flags.hasDiscreteGPU=true`, sample dGPU power state (D0/D3) via `powercfg /requests` and log whether the dGPU was awake at idle. If it stays awake at idle before but is asleep after, that's the win to headline.
- Desktop: skip battery drain, everything else runs identically.
