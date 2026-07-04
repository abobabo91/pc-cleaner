---
name: pc-cleaner
description: Audit and clean a Windows PC. Disable bloat services, kill autostart cruft, uninstall unused apps, tune privacy defaults, and (opt-in) fix laptop-platform performance issues (Ryzen 6000 sleep, Realtek WiFi driver stale-ness, PCIe ASPM). Use when the user asks to "clean the PC", "make Windows faster", "audit services", or invokes a specific module by name.
---

# pc-cleaner

## Invocation forms

| User types | Behavior |
|---|---|
| `/pc-cleaner` | Run all CORE modules in order. Ask about OPTIONAL ones once, at the start. |
| `/pc-cleaner all` | Run every module, CORE + OPTIONAL. Still asks about destructive things. |
| `/pc-cleaner <module>` | Run one module. Skips the OPTIONAL prompt. |
| `/pc-cleaner --include a,b,c` | CORE + explicitly-listed optionals. |
| `/pc-cleaner --exclude a,b` | CORE minus the listed modules. |
| `/pc-cleaner revert <timestamp>` | Undo everything in that snapshot folder. |
| `/pc-cleaner dry-run` | Diagnose everything, ask questions, show the plan — do NOT apply. |

If the user asked in natural language ("clean my PC", "make it faster") without specifying, run the default CORE flow.

## Guiding principles

1. **Snapshot before every apply.** No exceptions. Every module writes its own snapshot to `%USERPROFILE%\Desktop\pc-cleaner-snapshots\<ISO-timestamp>\<module>\`. Every apply produces a `revert.ps1` in that folder.
2. **Ask only when the decision is genuinely ambiguous.** If a category is unambiguously safe or unambiguously required for THIS machine, apply / skip without asking. Batch real MAYBEs into ≤4 grouped multi-select questions per module using AskUserQuestion. Front-load: gather all module questions once at the start of a full run, don't interrupt mid-flow.
3. **Machine-aware first.** `profile` runs before everything. Every subsequent module branches on the profile. Warnings and defaults are targeted to real risk on this specific machine.
4. **Explain every decision** in the run log. `[APPLY] <what> — reason: <why>`. No mystery meat.
5. **Never touch tripwire services / settings.** See `data/services_tripwire.json`. If a user tries to force one via a flag, explain the risk and refuse without `--iknowwhatimdoing`.
6. **Additive optional modules only apply if opted in.** The user's iPhone doesn't get their apps rearranged because they said "clean my PC".
7. **All user-facing questions must be plain English, informal.** Never use technical names in what the user reads. Describe things from the user's perspective ("Do you share files from this computer so other people on your WiFi can access them?"), not the technical name ("Enable SMB server?"). If a term is unavoidable, add a parenthetical explanation ("this is very rare", "used by only a few games"). No jargon: no `MDM`, `S3`, `HKCU`, `SubsystemVendor`, `LPS flags`, `Prefetch`, `stornvme`, etc. in the question text itself.

Good vs bad examples:

| Bad (technical) | Good (plain English) |
|---|---|
| "Enable SMB server?" | "Do you share files from this computer with other devices on your WiFi?" |
| "IPv6 tunneling needed (Teredo)?" | "Do you play online games or use apps that specifically need IPv6? (very rare — say no if unsure)" |
| "Windows Hello / biometric?" | "Do you unlock this laptop with your face or fingerprint?" |
| "Modern Standby wake events?" | "When you close the lid, do you want the laptop to keep checking email and updating in the background?" |
| "Enable ssh-agent?" | "Do you use Git or SSH from the command line? (this makes the passphrase remembered so you don't retype it)" |
| "WSearch (Windows indexed search)?" | "Do you use the Start menu to search for files and open them?" |
| "OneDrive sync?" | "Do you use OneDrive — even occasionally?" |
| "Miracast / DLNA / SSDP?" | "Do you ever cast your screen wirelessly to a TV, or play music to a wireless speaker?" |

## Module tiers

**CORE** (default flow):

1. `profile` — detect machine
2. `benchmark` — before-baseline
3. `services`
4. `startup`
5. `bloat` — UWP uninstalls
6. `privacy` — registry telemetry off
7. `explorer` — UI de-annoyance
8. `storage` — temp cleanup, DISM
9. `benchmark` — after-diff

**OPTIONAL** (opt-in via `--include` or the up-front prompt):

- `power` — laptop-only default; skipped on desktops.
- `network` — SMBv1 removal is the strong default; DoH / DNS override / NetBIOS are asked.
- `drivers` — advanced. Cross-vendor SoftPaq hunt for stale WiFi/BT/GPU drivers.
- `defender` — dev-toolchain path exclusions. Ask before applying.
- `crashdumps` — installs ~200 MB SDK Debuggers. Only if last N days have any minidumps, or user asks.
- `tray-taskbar` — preference-heavy. Only if user explicitly opts in.
- `ninite-personalized` — role-aware app suggestions. Non-destructive — outputs a copy-paste list.
- `unused-apps` — Prefetch-based dormant-app finder. Non-destructive proposals.

## Top-level orchestration flow

```
1. Parse invocation. Determine module list.
2. Confirm scope in one line: "Running: services, startup, bloat, privacy, explorer, storage. Skipping: crashdumps."
3. Run `profile` diagnose. Cache machine profile for the whole run.
4. If full run: ask ONE up-front question — "Which OPTIONAL modules should I include?" (multi-select).
5. Run `benchmark` (before).
6. For each module in order:
   a. Run its `diagnose` script → JSON.
   b. Read the module's .md doc for its categorization + question rules.
   c. Categorize items using: (1) data files, (2) machine profile, (3) Claude reasoning.
   d. Ask the module's grouped MAYBE questions.
   e. Build plan JSON.
   f. Call `apply` script (elevated). Log everything.
7. Run `benchmark` (after). Show diff table.
8. Emit final summary: what was applied, what was skipped, snapshot folder, one-command revert.
```

## PowerShell contract

Every module uses two script types under `ps/`:

- `diagnose/<module>.ps1` — read-only. Prints structured JSON to stdout. No admin needed. Exit 0 always if it ran.
- `apply/<module>.ps1` — takes `-Plan <path-to-JSON>` and `-SnapshotDir <path>`. Requires admin (elevate via `Start-Process -Verb RunAs` if not already elevated). Logs to `$SnapshotDir\apply.log`. Emits `$SnapshotDir\revert.ps1`.

Shared helpers in `ps/_lib/common.ps1`:
- `New-SnapshotDir -Module <name>` — returns and creates the module's snapshot dir under the current run's timestamp.
- `Test-Admin` / `Assert-Admin`.
- `Write-Log $path $level $message`.
- `Get-MachineProfile` — returns the machine profile object.

## Claude's role

1. Read the module's `.md` doc to know the flow.
2. Run its `diagnose` script.
3. Do the reasoning: which items are KEEP / KEEP-FOR-YOU / DISABLE-SAFE / MAYBE for THIS machine? Use the machine profile from step 3 of orchestration + data files + running-app cross-reference.
4. Emit the module's `plan.json`.
5. Call the module's `apply` script.
6. Show the user the log.

## Snapshot layout

```
~/Desktop/pc-cleaner-snapshots/2026-07-04T18-30-05/
├── profile.json                    # machine profile at snapshot time
├── run.log                         # top-level orchestration log
├── benchmark-before.json
├── benchmark-after.json
├── services/
│   ├── snapshot.csv
│   ├── plan.json
│   ├── apply.log
│   └── revert.ps1
├── startup/
│   ├── snapshot.json
│   ├── plan.json
│   ├── apply.log
│   └── revert.ps1
└── ...
```

## When invoked

Print a one-line intro naming what's about to happen:

```
pc-cleaner — CORE run on Lenovo Slim 7 ProX 14ARH7 (Ryzen 6, laptop, Win11 22631).
Modules: services, startup, bloat, privacy, explorer, storage.
Optional included: power, drivers.
```

Then execute the orchestration flow above.

## Cross-module contracts

These are shared invariants the orchestrator owns so no individual module has to know about the others.

### 1. profile.flags — the single source of truth

`ps/diagnose/profile.ps1` emits `profile.flags` — a boolean map every other module reads.
Defined flags (extend only when adding a module):

- `isLaptop` — has battery
- `isRyzen6kPlus` — Ryzen 6000+ (Modern Standby unreliable, WLAN LPS matters)
- `isIntelIce11Plus` — Intel 11th gen+ (also modern-standby-only)
- `hasDGPU` — discrete GPU present in addition to iGPU
- `wlanOEMMismatch` — machine OEM ≠ WLAN card subsystem OEM (blocks OEM driver updates)
- `hasCombo8822CE` / `hasCombo8852BE` — combo cards where WLAN LPS affects BT
- `recentBSODs` — any minidumps in last 30 days (triggers `crashdumps` prompt)
- `hasWHEAErrors` — WHEA-Logger events in last 30 days (real hardware issue)
- `isDomainJoined` — extra services stay KEEP
- `hasDefenderRTP` — Defender still active

Modules must NOT recompute these; they read from `profile.json`.

### 2. Explorer restart is deferred to end of run

`explorer`, `tray-taskbar`, and some `bloat` UWP removals want `Stop-Process explorer` + auto-restart to see the change. Do NOT restart Explorer inside each module — set `pendingExplorerRestart = true` in the run state and let the top-level orchestrator do it once at the end. Otherwise you get 3+ Explorer flickers per run.

### 3. WLAN adapter cycle is batched

`power`, `network`, and `drivers` may all touch WLAN driver registry values. Do NOT `Restart-NetAdapter` inside each module. Set `pendingWLANCycle = true` and let the orchestrator do one restart at the end. Losing WiFi mid-run is worse than losing it once at the end.

### 4. Storage vs unused-apps: Prefetch ordering

`unused-apps` reads `C:\Windows\Prefetch\*.pf` to compute last-launched times. `storage` may propose Prefetch cleanup. If both run in the same session, `unused-apps` MUST run first, and `storage` MUST skip Prefetch cleanup for that session. This is a runtime coordination in the orchestrator, not a module default.

### 5. AskUserQuestion budget

Individual modules cap at ≤4 grouped multi-select questions. But 15 modules × 4 = 60 total is not acceptable. The orchestrator enforces:

- **Full CORE run**: ≤10 total questions across all modules. Modules must skip low-value questions when running as part of a full flow.
- **Full CORE + selected OPTIONALs**: +2 per opted-in optional module max.
- **Single module invoked directly**: module's full quota.
- **`quick` mode** (add `/pc-cleaner quick`): CORE only, zero questions. All MAYBEs decided as "leave alone".

Front-load: gather all questions once at the start of the run, do the whole apply pass unattended.

### 6. Shared crash → driver linkage

`crashdumps` produces `crash_linked_drivers.json` (drivers that appeared in `!analyze -v` MODULE_NAME output). `drivers` reads that file and prioritizes updating those drivers first. Path: `<snapshotRoot>/crash_linked_drivers.json` — shared across modules in the same run.

## Not in scope

- **Do NOT touch Windows Defender's real-time protection.** Only add path exclusions for dev folders in the `defender` module, and only if user opts in.
- **Do NOT flash BIOS / firmware.** Ever. Point the user at Lenovo Vantage / vendor tool.
- **Do NOT auto-install any app.** `ninite-personalized` suggests; user runs.
- **Do NOT touch Group Policy / gpsvc.** Login lockout risk.
- **Do NOT modify network adapter settings without cycling the adapter afterward.** Silent config drift causes hard-to-debug bugs.
- **Do NOT run OPTIONAL modules the user didn't include.** Additive by explicit choice only.
