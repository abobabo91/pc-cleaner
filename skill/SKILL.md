---
name: pc-cleaner
description: Audit and clean a Windows PC — disable bloat services, kill autostart cruft, uninstall unused apps, fix known laptop-platform performance issues (Ryzen 6000 sleep, Realtek WiFi driver stale-ness, PCIe ASPM), tune privacy defaults. Use when the user asks to "clean the PC", "make Windows faster", "audit services", or a specific module by name (`/pc-cleaner services`, `/pc-cleaner power`, etc.).
---

# pc-cleaner

## Guiding principles

1. **Snapshot before every apply.** No exceptions. Every module writes its own snapshot to `%USERPROFILE%\Desktop\pc-cleaner-snapshots\<ISO-timestamp>\<module>\`. Every apply produces a `revert.ps1` in that folder.
2. **Ask only when the decision is genuinely ambiguous.** If a category is unambiguously safe or unambiguously required for THIS machine, apply / skip without asking. Batch the real MAYBEs into ≤4 multi-select questions per module using AskUserQuestion.
3. **Machine-aware first.** Before any module runs, gather machine profile (see `ps/diagnose/profile.ps1`). Warnings and defaults branch on:
   - Laptop vs desktop
   - CPU vendor + generation (Ryzen 6000/7000 have Modern Standby issues; Intel 11th+ do too)
   - Discrete GPU present
   - WiFi/BT chip vendor + PCI subsystem vendor mismatch (combo-card OEM-vs-subsystem drift)
   - Windows edition (Home vs Pro affects gpsvc + BitLocker recommendations)
4. **Explain every decision** in the run log. `[APPLY] <what> — reason: <why>`. No mystery meat.
5. **Never touch tripwire services.** See `data/services_tripwire.json`. If a user tries to force disable one, explain the risk and refuse without a `--iknowwhatimdoing` flag.

## Modules

Each module in `skill/modules/<name>.md` has its own detailed instructions. Top-level orchestration:

- `/pc-cleaner` → run all modules in order, gathering all questions up front, then a single apply pass.
- `/pc-cleaner <module>` → run one module.
- `/pc-cleaner revert <timestamp>` → point at a snapshot folder and undo.

Order for the full run:
1. `benchmark` (before)
2. `profile` (detect machine)
3. `services`
4. `startup`
5. `power`
6. `drivers`
7. `network`
8. `defender`
9. `privacy`
10. `explorer`
11. `bloat`
12. `unused-apps`
13. `ninite-personalized`
14. `storage`
15. `tray-taskbar`
16. `crashdumps` (opt-in — installs SDK Debuggers, ~200 MB)
17. `benchmark` (after — show diff)

## PowerShell contract

Every module uses two script types under `ps/`:

- `diagnose/<module>.ps1` — read-only. Prints structured JSON to stdout. No admin needed. Exit 0 always if it ran.
- `apply/<module>.ps1` — takes `-Plan <path-to-JSON>` and `-SnapshotDir <path>`. Requires admin (elevate via `Start-Process -Verb RunAs` if not already elevated). Logs to `$SnapshotDir\apply.log`.

Claude's role:
1. Run the `diagnose` script for the module.
2. Parse the JSON.
3. Categorize each item (using both the diagnose script's hints and Claude's own knowledge + machine profile).
4. Ask user any real MAYBEs (batched, multi-select) via AskUserQuestion.
5. Emit an apply plan JSON.
6. Call the `apply` script.
7. Show the user the run log.

## Snapshot layout

```
~/Desktop/pc-cleaner-snapshots/2026-07-04T18-30-05/
├── profile.json                    # machine profile at snapshot time
├── services/
│   ├── snapshot.csv                # Get-Service before change
│   ├── plan.json                   # what we're about to do
│   ├── apply.log
│   └── revert.ps1
├── power/
│   ├── plan-active.pow             # powercfg /export
│   ├── plan.json
│   ├── apply.log
│   └── revert.ps1
└── ...
```

## When invoked

If the user typed `/pc-cleaner` with no arg → run the whole flow.
If they typed a subcommand → route to that module's `.md`.
If it's a natural-language intent that matches ("clean my PC", "make it faster", "why is Windows slow") → confirm scope (all modules? or just the one they hinted at?) then run.

Print a one-line intro naming what's about to happen: `pc-cleaner — running services, startup, power, drivers, bloat (skipping crashdumps unless you say --dumps).`

## Not in scope

- **Do NOT touch Windows Defender's real-time protection.** Only add path exclusions for dev folders.
- **Do NOT flash BIOS / firmware.** Ever. Point the user at Lenovo Vantage / vendor tool.
- **Do NOT auto-install any app.** `ninite-personalized` suggests; user runs.
- **Do NOT touch Group Policy / gpsvc.** Login lockout risk.
- **Do NOT modify network adapter settings without cycling the adapter afterward.** Silent config drift causes hard-to-debug bugs.
