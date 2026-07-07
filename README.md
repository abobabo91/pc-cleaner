# pc-cleaner

**Make your Windows 11 PC faster and cleaner. Two quick questions, one preview list, one Apply button.**

Runs inside Claude Code. It looks at your PC, figures out what you use vs what you don't, and shows you a clear list before changing anything. You either say "apply", or you tell it what to skip in plain English.

---

## What it does for you

Removes the bloat that comes preinstalled with Windows — the Xbox apps, Cortana, Weather, News, Feedback Hub, Solitaire, Copilot ads in your Start menu — but **only the ones you actually don't use**. It figures that out by checking when you last opened each one.

Frees up disk space by deleting temporary files, browser caches, Discord/Slack/Zoom/VS Code caches. On a typical machine that's 500 MB to 5 GB back.

Turns off Windows tracking, ads, activity history.

Disables the apps that auto-start every time you turn on your computer but you never use.

Fixes Windows 11's most-complained-about annoyances (Widgets button, Copilot button, right-click menu) — but shows you the change first so you can skip anything you actually want.

For laptops with a known Bluetooth or crash problem, it can find the actual fix for your specific chip.

**You don't answer 20 questions.** You answer 2 quick profile questions ("what do you use this PC for" + "how techy are you"), then look at a list, then say Apply. Total interaction: about 30 seconds of your attention.

## For non-technical users — how to actually run it

You need two things installed once:
1. **Claude Code** — the AI coding assistant. [Download here](https://www.anthropic.com/claude-code) and sign in.
2. **The pc-cleaner skill** — this project. Two commands to install (copy-paste into any terminal):

```
git clone https://github.com/abobabo91/pc-cleaner "$env:USERPROFILE\pc-cleaner"
Copy-Item -Recurse "$env:USERPROFILE\pc-cleaner\skill" "$env:USERPROFILE\.claude\skills\pc-cleaner"
```

Once installed, every time you want to clean your PC:

1. **Close Claude Code** if it's already open.
2. **Right-click the Windows Start button** → click **Terminal (Admin)**. Click **Yes** on the security prompt.
3. In that admin Terminal, type `claude` and press Enter to launch Claude Code.
4. Type `/pc-cleaner` and press Enter.

That's it. Here's what happens:

1. **The tool asks 2 quick profile questions** — what you use your PC for, and how technical you are. Sets sensible defaults. ~10 seconds.
2. **You tick some checkboxes** — one page with 4 short lists about what you actually do on this computer:
   - "What do you use this laptop for?" — browsing, office, creation, gaming (tick all that apply)
   - "What do you connect to it?" — Bluetooth headphones, printer, phone, wireless cast
   - "Which of these apply to you?" — Microsoft account, OneDrive, Teams for work, Win+G screenshots
   - "How do you like Windows to feel?" — Start-menu search, dark mode, virtual desktops, Recall
   Total ~16 checkboxes. ~30 seconds.
3. **It looks at your PC** — cross-checks your ticks against launch history, installed apps, hardware presence. ~20 seconds silent.
4. **It shows you a list** — grouped as: apps you don't use, apps you DO use (kept), Windows features safe to turn off, features it will leave alone (with reasons), cleanup items, UI tweaks. Every "keep" reason cites your own ticks: *"Keeping Xbox Game Bar because you ticked 'I take screenshots with Win+G'"*.
5. **You look at the list and pick one:**
   - **Apply everything** — done in about a minute.
   - **Change something** — just type what to skip: "keep Skype" or "don't empty recycle bin". The list updates.
   - **Cancel** — nothing changes.

**Total interaction: about a minute of ticking + reading.** No mid-run interruptions. The tool asks about **3 things total** (profile / checklist / apply), each one a single screen.

## What if something goes wrong?

Every change gets saved to a folder on your Desktop called `pc-cleaner-snapshots`. To undo the whole last run, just type in Claude Code:

```
/pc-cleaner undo
```

That's it. It finds the most recent run and rolls everything back — apps get reinstalled, services get re-enabled, UI tweaks go back to how they were. About 30 seconds.

(Some things can't come back — temp files that were deleted are gone for good. That's normal for any cleanup tool. The tool tells you which items couldn't be reverted.)

If you want to undo an older run, run `/pc-cleaner undo` and pick from the list of runs it shows you.

## What it does NOT do

- It doesn't touch your files, photos, documents, or anything in `Documents` / `Pictures` / `Desktop`.
- It doesn't disable your antivirus (Windows Defender stays fully on).
- It doesn't install anything you don't specifically say yes to.
- It doesn't send data anywhere. Everything runs locally.
- It doesn't require you to reboot for most changes (a few settings do finalize after your next login).

---

# Technical section

Below this line is for developers and technical users who want to understand or extend pc-cleaner.

## Architecture

pc-cleaner is a **Claude Code skill**, meaning the actual intelligence lives in Claude at runtime — it reads a set of Markdown files (in `skill/modules/`) that describe what each module does, then uses PowerShell helper scripts (in `ps/`) to actually gather data and apply changes.

```
pc-cleaner/
├── README.md
├── knowledge_base/                 # design decisions, gotchas, project rules from real runs
├── skill/
│   ├── SKILL.md                    # top-level orchestration + principles + user profile intake
│   └── modules/                    # 16 module docs, one per capability
├── ps/
│   ├── _lib/common.ps1             # snapshot dir, elevation check, machine profile
│   ├── pc-cleaner.ps1              # orchestrator entry point
│   ├── diagnose/*.ps1              # 16 read-only enumerators (JSON out)
│   └── apply/*.ps1                 # 13 change-appliers (each with snapshot + revert)
└── data/                           # 47 curated JSON files (safe-disable lists, keys, etc.)
```

## Modules

### CORE (run by default)

- `profile` — detects machine: laptop, CPU vendor + generation, GPUs, WiFi chip + subsystem OEM (for driver hunt), sleep states, battery, BSOD count.
- `benchmark` — records boot time, RAM, service count, autostart count. Before/after diff.
- `services` — audits 300+ Windows services against `data/services_tripwire.json` (do not touch) and `data/services_disable_safe.json` (safe to disable across 10 categories: cellular_modem, enterprise_mdm, legacy_networking, smart_cards, telemetry, gaming, remote_desktop_host, printer_scanner, storage_spaces_backup, mixed_reality).
- `startup` — Registry Run keys (4 hives) + Startup folders + user Task Scheduler entries. Cross-references tripwire (OneDrive, Docker, password managers, security tools) and safe-disable (Adobe ARM Updater, iTunes helper, GoogleUpdate, CCleaner tray).
- `bloat` — UWP inventory against `data/bloat_uwp.json` (30+ safe removals + 13 ask + 15 never-touch). Handles system-provisioned apps by calling `Remove-AppxProvisionedPackage -Online` before `Remove-AppxPackage -AllUsers`.
- `privacy` — 25 registry keys across telemetry / ad ID / activity history / Explorer ads / Bing search / Copilot / Recall / Edge tracking / WiFi Sense / location.
- `explorer` — Win11 UI tweaks with runtime conflict detection (StartAllBack, ExplorerPatcher). Rule: **the seed machine's current state IS the recommended baseline for non-technical users** — module only proposes changes where the user's state differs from that baseline.
- `storage` — 46 cleanup sources including CCleaner-tier per-app caches (Chrome deep caches, Discord, Slack, Zoom, Teams, VS Code, Cursor, Notion, Adobe media cache), plus DNS flush, Windows Store cache reset, Windows Update leftover folders.

### OPTIONAL (opt-in via `--include`)

- `power` — PCIe ASPM off, hibernate config, lid = do nothing, WLAN driver LPS zeroed on combo cards (fixes Ryzen 6000 Modern Standby crashes + Bluetooth range on Realtek RTL8822CE / MediaTek MT7921).
- `network` — SMBv1 removal, LLMNR off, NetBIOS-over-TCP off, optional DoH, optional DNS override (Cloudflare / Quad9).
- `drivers` — stale + OEM-vs-subsystem-vendor mismatch detection (e.g. Lenovo laptop with HP-vendored WiFi card). Cross-refs `crash_linked_drivers.json` from crashdumps module. Downloads matching SoftPaqs (HP, Dell, Lenovo) but never auto-installs — user runs manually.
- `defender` — dev toolchain path exclusions (node_modules, pnpm-store, cargo, rustup, gradle, .m2, .nuget, WSL2 vhdx, Docker). RTP stays on.
- `crashdumps` — installs Windows SDK Debuggers via `winsdksetup.exe /features OptionId.WindowsDesktopDebuggers`, caches MS symbols, `kd -z !analyze -v` on last N minidumps, extracts MODULE_NAME + BUGCHECK_CODE, writes shared `crash_linked_drivers.json` for the drivers module.
- `tray-taskbar` — one question per pinned taskbar app + one per promoted tray icon. Backs up pins to allow reversal.
- `ninite-personalized` — role detection (dev / creative / gamer / office / student / modern-solo-dev) from installed apps + running processes + folder markers. Suggests companion apps from `data/ninite_bundles.json`. Never auto-installs — outputs `winget install` commands. Deliberately omits password manager recommendations. Adaptive: asks "how do you listen to music?" before deciding whether to suggest VLC / Audacity.
- `unused-apps` — UserAssist ROT13 decode + FILETIME extract for last-launched. Cross-refs installed apps ≥ 100 MB with ≥ 90 days idle. `data/unused_apps_never.json` allowlist skips security software, sync clients, VPN clients, password managers.

## Cross-module contracts (in `SKILL.md`)

- `profile.flags` is the single source of truth — no module recomputes it.
- Explorer restart is deferred to end-of-run (avoid 3+ flickers).
- WLAN adapter cycle is batched (avoid losing WiFi 3 times per run).
- Prefetch ordering: `unused-apps` runs before `storage`; `storage` skips Prefetch cleanup if `unused-apps` ran.
- `AskUserQuestion` budget: 10 total for full CORE run, +2 per opted-in OPTIONAL, 0 in `quick` mode.
- `crashdumps` writes → `drivers` reads via shared `crash_linked_drivers.json` in the snapshot root.

## Principles

1. **Snapshot before every apply.** Every module writes to `%USERPROFILE%\Desktop\pc-cleaner-snapshots\<ISO-timestamp>\<module>\` with `snapshot.<ext>`, `plan.json`, `apply.log`, `revert.ps1`.
2. **Ask only when the decision is genuinely ambiguous.** Everything else is decided by machine profile + running processes + installed apps.
3. **Conversational, one question at a time.** Each MAYBE gets its own Yes / No / "I'm not sure" question. "I'm not sure" triggers a deterministic PS inference rule.
4. **The seed machine's current state = recommended baseline for non-technical users.** UI preferences only get proposed if the user's state differs from the baseline.
5. **User-profile-driven.** Two intake questions at run start ("what do you use this for?" + "how technical are you?") set defaults for every module. A "clicker" user gets ~3 total questions; a "developer" gets ~15.
6. **Never touch tripwire services / settings.** Refuse without `--iknowwhatimdoing` for RPC, DCOM, PlugPlay, Power, EventLog, WMI, Group Policy Client, LSA, CryptSvc, Firewall, DNS client, DHCP client, Audio, Task Scheduler, etc. Full list in `data/services_tripwire.json`.
7. **All user-facing questions must be plain English.** No `SMB`, `MDM`, `HKCU`, `subsystem`, `LPS flags`, `Prefetch` in the visible question text.
8. **Check admin ONCE at run start.** If not elevated, tell the user to relaunch Claude Code as Administrator and stop. Do NOT try to elevate per-module — per-module UAC prompts are unreliable on multi-monitor / fullscreen setups.

## Data files

47 JSON files under `data/` cover services, autostarts, UWP apps, registry keys, driver sources, known-bad drivers, bug-check codes, Windows SDK URLs, tray icons, taskbar defaults, Ninite bundles, role signals, dev cache paths, dev toolchain markers, storage sources, storage conflicts, WLAN low-power flags, WiFi/BT combo cards, DNS providers, network risky features, Modern Standby overrides, and more. Edit these — not the code — when adding categorizations.

## Testing

The seed machine used to build and validate this project is a Lenovo Slim 7 ProX 14ARH7 (Ryzen 9 6900HS + RTX 3050 + Radeon 680M) running Windows 11 Home 23H2. Full session findings in `knowledge_base/session_2026-07-04_lenovo_slim7prox.md`. Rules learned from actual runs in `knowledge_base/rules_from_runs.md`. Open work in `knowledge_base/backlog.md`.

## Requirements

- Windows 11 (22H2+; tested on 23H2 build 22631)
- Claude Code CLI installed
- PowerShell 5.1 (built-in) or 7+
- Admin session (see the non-technical usage guide above)

## Contributing

Extend `data/*.json` first, then module docs in `skill/modules/*.md`, then the PS scripts in `ps/diagnose/` and `ps/apply/`. Each module needs: diagnose script (JSON out), apply script (snapshot + apply + revert), and a module doc following the shape of `services.md`.

## License

MIT.

## Status

Alpha — the tool has been end-to-end tested on the seed machine (services, startup, bloat, privacy, explorer, storage) but the OPTIONAL modules haven't all been validated in a real run yet. Backlog in `knowledge_base/backlog.md`.
