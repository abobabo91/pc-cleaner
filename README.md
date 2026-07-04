# pc-cleaner

Claude Code skill that audits, categorizes, and cleans a Windows PC. Public / shareable. Windows 11 focus.

## What it does

Runs a machine-aware audit of everything that slows down a Windows PC, categorizes each finding as **KEEP** / **KEEP-FOR-YOU** / **DISABLE-SAFE** / **MAYBE**, applies the safe cleanups automatically, asks you targeted questions only for the genuinely ambiguous ones, and produces a full revert path for every action.

## How you use it

```
> /pc-cleaner
```

in Claude Code (Windows). The skill drives the whole flow. You answer 5-10 questions total across the whole run, not per-service.

## Modules

Each is invocable individually (`/pc-cleaner services`) or all together (`/pc-cleaner all`).

| Module | Purpose |
|---|---|
| `services` | Audit 300+ Windows services. Disable safe bloat, ask about MAYBEs, enable useful ones (ssh-agent). |
| `startup` | Registry Run keys + Startup folder + user Task Scheduler entries. Kill autostart bloat. |
| `power` | PCIe ASPM off, Modern Standby diagnosis, hibernate config, lid/sleep behavior. Fixes Ryzen 6000 sleep crashes. |
| `drivers` | Detect stale + OEM-vs-generic + subsystem-ID-mismatched drivers. Find matching SoftPaq from HP/Dell/Realtek/Lenovo. |
| `bloat` | winget uninstall of the usual UWP suspects (Xbox, News, Weather, LinkedIn, People, Skype, Copilot) — user-approved list. |
| `unused-apps` | Scan installed apps for ones you never launch (Prefetch + registry last-used). Suggest uninstall with reason. |
| `ninite-personalized` | Detect your role from what's installed (dev / creator / gamer / office), suggest the small handful of companion apps you're likely missing. Never auto-install. |
| `privacy` | Telemetry off, ad ID off, activity history off, Explorer ads, Edge tracking, targeted ads. |
| `crashdumps` | Install SDK Debuggers, cache MS symbols, `!analyze -v` the last N minidumps, name failing drivers. |
| `network` | SMBv1 remove, WiFi driver LPS/power tuning, DoH config, optional DNS override. |
| `storage` | Temp cleanup, Storage Sense config, Windows.old, DISM `/cleanup-image`. |
| `explorer` | Win11 right-click classic menu, Widgets remove, Search tweaks, dark mode default. |
| `defender` | Add exclusions for dev folders (WSL, node_modules, .git, %LOCALAPPDATA%\pnpm-store etc) to speed builds. RTP stays on. |
| `tray-taskbar` | Enumerate tray icons + pinned taskbar apps, ask which to hide/unpin. Non-destructive. |
| `benchmark` | Boot time, running services count, RAM baseline, autostart count. Runs before and after; diffs. |

## Principles

1. **Never guess with permanent consequences.** Every apply step writes a snapshot first. Revert is one command.
2. **Ask only when necessary.** If it's obviously safe or obviously required, we act. Questions are for genuine forks.
3. **Explain every decision.** Every applied change shows up in the run log with a one-line reason.
4. **Machine-aware.** Detect laptop vs desktop, GPU vendor, WiFi chip, Ryzen 6000, discrete GPU present, etc. Warnings are targeted to real risk on this machine, not generic scare copy.
5. **Public-friendly.** No hardcoded assumptions about the author's setup. Works on any Windows 11 machine.

## Safety

Every module snapshots what it's about to change to `~/Desktop/pc-cleaner-snapshots/<timestamp>/`:

- Services: full `Export-Csv` of `Get-Service`
- Registry: `.reg` export of every key touched
- Power: `powercfg /export` of the active plan
- Startup: JSON dump of Run keys + Startup folder + tasks
- Winget uninstalls: list of package IDs removed

Each module ships with `revert.ps1` that consumes its own snapshot.

## Structure

```
pc-cleaner/
├── README.md
├── knowledge_base/              # Findings dumped as we build
├── skill/
│   ├── SKILL.md                 # Top-level Claude Code skill instructions
│   └── modules/*.md             # Per-module skill instructions
├── ps/
│   ├── _lib/                    # Shared PowerShell helpers (snapshot, elevation, logging)
│   ├── diagnose/*.ps1           # Read-only enumerators. Output JSON.
│   └── apply/*.ps1              # Change appliers. Take a plan file, log every action.
└── data/                        # Machine-agnostic curated lists (safe UWP bloat, telemetry keys, etc.)
```

The skill = Claude reasoning + orchestration.
The PowerShell = deterministic system access.
Data = editable curated lists.

## Requirements

- Windows 11 (22H2+)
- Claude Code CLI installed
- PowerShell 5.1 (built in) or 7+
- Admin rights (UAC prompt per action batch)

## Install (once shareable)

```powershell
git clone https://github.com/<you>/pc-cleaner ~/pc-cleaner
Copy-Item -Recurse "~/pc-cleaner/skill" "~/.claude/skills/pc-cleaner"
```

Then `/pc-cleaner` from anywhere in Claude Code.

## Status

Early. `services` module extracted from real cleanup work on a Lenovo Slim 7 ProX 14ARH7 (Ryzen 6900HS) — see `knowledge_base/session_2026-07-04_lenovo_slim7prox.md`. Other modules TBD.
