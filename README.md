# pc-cleaner

Claude Code skill that audits, categorizes, and cleans a Windows PC. Public / shareable. Windows 11 focus.

## What it does

Runs a machine-aware audit of everything that slows down a Windows PC, categorizes each finding as **KEEP** / **KEEP-FOR-YOU** / **DISABLE-SAFE** / **MAYBE**, applies the safe cleanups automatically, asks you targeted questions only for the genuinely ambiguous ones, and produces a full revert path for every action.

## How you use it

```
> /pc-cleaner
```

in Claude Code (Windows). By default this runs the **CORE** modules — universally beneficial, low-risk cleanups that make sense on any Windows 11 machine.

To include one or more optional modules:

```
> /pc-cleaner --include power,drivers,defender
```

To run just one module:

```
> /pc-cleaner services
```

To undo a previous run:

```
> /pc-cleaner revert 2026-07-04T18-30-05
```

## Modules

### CORE — runs by default

| Module | Purpose |
|---|---|
| `profile` | Detect machine: mfg/model, CPU (vendor + gen), GPUs, WLAN chip + subsystem, battery, OS build, sleep states. Everything else branches off this. |
| `benchmark` | Boot time, running services, RAM baseline, autostart count. Runs at start and end; produces before/after diff. |
| `services` | Audit 300+ Windows services. Disable safe bloat, ask about MAYBEs (batched), enable useful ones (ssh-agent). Curated tripwire list refuses risky disables. |
| `startup` | Registry Run keys (all hives) + Startup folders + user Task Scheduler entries. Kill autostart bloat. Preserves your actively-used app launchers. |
| `bloat` | winget uninstall of Xbox, Cortana, Copilot, News, Weather, LinkedIn, People, Skype, Feedback Hub, Get Started, Tips, Solitaire. Ask before removing Photos, Groove, or anything that has data. |
| `privacy` | Telemetry off, ad ID off, activity history off, targeted ads, Explorer ads (SubscribedContent), Edge tracking prevention, Copilot key off, search web off. |
| `explorer` | Win11 right-click classic menu, Widgets remove, Search box → icon only, taskbar align left, file extensions visible. Non-destructive UI de-annoyance. |
| `storage` | %TEMP% + LocalAppData\Temp cleanup, Windows.old, DISM /cleanup-image /startcomponentcleanup /resetbase, Storage Sense on with sensible defaults, Delivery Optimization cache purge. |

### OPTIONAL — opt-in per module

| Module | Purpose | When to include |
|---|---|---|
| `power` | PCIe ASPM off, hibernate config, lid = do nothing, WLAN driver LPS off. Fixes Ryzen 6000+ Modern Standby crashes and combo-card BT range. | Laptop, or you've had unexplained sleep-related crashes. |
| `network` | Remove SMBv1 (default: yes), DoH config, optional DNS override (Cloudflare / Quad9), disable NetBIOS over TCP. | You care about network security / privacy tuning. |
| `drivers` | Detect stale drivers, OEM-vs-subsystem-vendor mismatch (e.g. Lenovo laptop with HP-vendored WiFi card). Find matching SoftPaqs from HP / Dell / Lenovo / Realtek. | You suspect a driver problem, or run this yearly to catch stale WiFi/BT/GPU. |
| `defender` | Add path exclusions for dev toolchains (WSL2 vhdx, node_modules, .git, pnpm-store, cargo, gradle, etc.). RTP stays on. | You're a developer and Defender is slowing your builds. |
| `crashdumps` | Install Windows SDK Debuggers (~200MB), cache MS symbols, `!analyze -v` the last N minidumps, rank failing drivers. | You have or recently had BSODs. |
| `tray-taskbar` | Enumerate tray icons + pinned taskbar apps, ask which to hide/unpin. | You want a cleaner tray/taskbar. Preference-heavy. |
| `ninite-personalized` | Detect your role (dev / creative / gamer / office) from installed apps. Suggest missing companions. Never auto-installs — outputs `winget install` commands to copy-paste. | You want smart suggestions for what to install. |
| `unused-apps` | Read Prefetch + UserAssist to find installed apps not launched in 90+ days AND > 100MB. Propose uninstall per app. | You want to reclaim disk from forgotten installs. |

## Principles

1. **Never guess with permanent consequences.** Every apply step writes a snapshot first. Revert is one command.
2. **Ask only when necessary.** If it's obviously safe or obviously required for this machine, we act. Questions are for genuine forks. Batched to ≤4 grouped multi-selects per module.
3. **Explain every decision.** Every applied change shows up in the run log with a one-line reason.
4. **Machine-aware.** The `profile` module runs first. All subsequent modules branch on it: laptop-only settings skipped on desktops, Ryzen-specific fixes skipped on Intel, combo-card fixes skipped when a discrete WLAN chip is present.
5. **Public-friendly.** No hardcoded assumptions about the author's setup. Works on any Windows 11 machine.

## Safety

Every module snapshots what it's about to change to `~/Desktop/pc-cleaner-snapshots/<timestamp>/<module>/`:

- Services: `Get-Service | Export-Csv`
- Registry: `.reg` export of every key touched
- Power: `powercfg /export` of the active plan
- Startup: JSON dump of Run keys + Startup folder + tasks
- Bloat uninstalls: list of package IDs + winget install commands to re-add
- Storage: what got deleted, sizes, and where DISM ran

Each module ships with a generated `revert.ps1` per run.

## Structure

```
pc-cleaner/
├── README.md
├── knowledge_base/              # Findings dumped as we build
├── skill/
│   ├── SKILL.md                 # Top-level Claude Code skill instructions + orchestration
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

Early. `services` module extracted from real cleanup work on a Lenovo Slim 7 ProX 14ARH7 (Ryzen 6900HS) — see `knowledge_base/session_2026-07-04_lenovo_slim7prox.md`. Other module docs in place; PS scripts being added stage by stage.
