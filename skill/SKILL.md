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
5. **Never touch tripwire services / settings.** See `data/services_tripwire.json`. Enforced at THREE layers: (1) Claude reasoning must not add a tripwire name to any plan; (2) `apply/services.ps1` refuses at runtime; (3) `verify/smoke.ps1` catches regressions post-apply. If a user tries to force one via a flag, explain the risk and refuse without `--iknowwhatimdoing`.
6. **Additive optional modules only apply if opted in.** The user's iPhone doesn't get their apps rearranged because they said "clean my PC".
7. **All user-facing questions must be plain English, informal.** Never use technical names in what the user reads. Describe things from the user's perspective ("Do you share files from this computer so other people on your WiFi can access them?"), not the technical name ("Enable SMB server?"). If a term is unavoidable, add a parenthetical explanation ("this is very rare", "used by only a few games"). No jargon: no `MDM`, `S3`, `HKCU`, `SubsystemVendor`, `LPS flags`, `Prefetch`, `stornvme`, etc. in the question text itself.
8. **Conversational, one question at a time.** Ask like you'd talk to a non-technical friend, not like a form. Each MAYBE gets its own quick yes/no/"I'm not sure" question. Front-load hardware detection so items that can't apply (fingerprint on a machine with no biometric hardware, Windows VPN when OpenVPN is running, Comet when it isn't installed) never appear as questions. This keeps the actual number of questions low on any specific machine even though the module knows about a lot of things.

Every question offers three options:
- **Yes** — keep the related service(s)
- **No** — disable
- **I'm not sure — figure it out for me** — trigger the inference rule

**Every module doc must specify the inference rule for each question** — the exact PowerShell / registry check that produces YES or NO. Auto-inference is a hard contract, not "Claude figures it out."

9. **Hidden UX dependency rule.** No question of the form "do you use feature X?" may make the disable decision for a service that backs multiple unrelated UX flows. These services belong in `services_tripwire.json` under the new schema (`{ reason, backs: [...] }`) and stay on Windows defaults regardless of user answers. Examples the seed session got wrong: `fdPHost` (backs BT pairing wizard + printer wizard + Miracast — not just casting), `CDPSvc` (backs BT pairing + Nearby Sharing + Quick Assist — not just Copilot), `MapsBroker` (backs Copilot location + Weather + Photos map view — not just the Maps app). When in doubt, put it in tripwire — false positives cost users nothing; a false negative silently breaks a Windows UX flow the user can't debug.

10. **Post-apply UX smoke test.** After every module apply, the orchestrator calls `ps/verify/smoke.ps1` which runs `data/ux_smoke_tests.json`. Each test names a UX flow (BT pairing wizard, Add printer, Settings launch, Start search, notification delivery, MS account sign-in, Store app launch, audio device switch) and the services required for it. If any test FAILS, the orchestrator shows the failing flow + points at the last apply as the suspect + offers the revert command. `services.ps1` invokes it automatically; other modules invoke it via the orchestrator after they finish. The smoke test is READ-ONLY and takes <5s per run.

11. **The `confirmed:true` contract.** Any entry in a plan JSON that has a `riskLevel:"ask"` (storage), `promptRequired:true` (power), or belongs to an `ask_user` category (privacy, explorer) — the orchestrator MUST first ask the user, then add `"confirmed": true` to that entry before writing the plan. Apply scripts refuse ask-gated entries without this field. This is enforced runtime in every apply/*.ps1 as a defence-in-depth backstop. Same principle as tripwire but at entry-granularity instead of service-granularity. Also covers: network SMBv1/LLMNR/NetBIOS/DNS (each has its own `<setting>Confirmed:true` boolean at the plan root), defender exclusion paths (checked against `data/defender_dangerous_paths.json` and refused if matching a "critical malware landing spot" like Downloads/TEMP/drive root, unless `-IKnowWhatImDoing`).

After all questions in a module are answered, show the user a "here's what I decided" summary with what was checked, what was inferred, and what got disabled/kept. Let them override before applying.

**Dependency skips:** if an earlier answer implies a later one, don't ask. Example: user said "I don't print" → don't separately ask about scanning; user has no biometric hardware → face/fingerprint question doesn't exist for them.

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
4. ASK THE USER 2 BASELINE QUESTIONS UP FRONT (see "User profile" section below).
   These answers become the defaults for every module downstream.
5. If full run: ask ONE up-front question — "Which OPTIONAL modules should I include?" (multi-select).
6. Run `benchmark` (before).
6. For each module in order:
   a. Run its `diagnose` script → JSON.
   b. Read the module's .md doc for its categorization + question rules.
   c. Categorize items using: (1) data files, (2) machine profile, (3) Claude reasoning.
   d. Ask the module's grouped MAYBE questions.
   e. Build plan JSON.
   f. Call `apply` script (elevated). Log everything.
7. Run `ps/verify/smoke.ps1` (post-apply UX smoke test). If any FAIL:
   - Print the failing flows and which required service(s) are in the wrong state.
   - Name the module(s) whose apply.log mentions those services as the suspects.
   - Offer the revert command for those modules.
   Do NOT auto-revert — the user might have a reason to see the failure first.
8. Run `benchmark` (after). Show diff table.
9. Emit final summary: what was applied, what was skipped, snapshot folder, one-command revert, smoke test result.
```

## Elevation: get admin ONCE at the start, not per module

Before the run starts, check if the current session is already Administrator (`([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)`).

- If NOT admin: tell the user in plain English:
  > "This tool needs administrator permission to change some settings. Please close Claude Code (or the terminal you launched it from) and re-open it as Administrator, then run `/pc-cleaner` again."
  > "On Windows 11: right-click the Start button → Terminal (Admin) → run Claude Code from there."
  Stop the run. Do NOT try to elevate individual module applies with `Start-Process -Verb RunAs` — that produces a UAC prompt per module that the user often can't see (secure-desktop windows land off-screen on multi-monitor setups, hide behind fullscreen apps, or dismiss too fast to catch).

- If admin: proceed. All apply scripts run in the same elevated session with zero further prompts.

Never fall through to per-module UAC prompts. It's unreliable UX.

## User profile — 2 baseline questions at the very start

Before any module runs, ask these two questions in plain English. They define the *user profile* which sets sensible defaults for every subsequent question. This means non-technical users don't get bombarded with jargon, and developers get useful cleanups skipped for regular users.

**Baseline Q1 — "What do you mostly use this computer for?"** (single-select)
- Browsing the web, email, YouTube, social media
- School / office work (documents, spreadsheets, video calls)
- Photo, video, or music creation
- Gaming
- Software development
- A mix of these (I'll pick a specific answer if needed)

**Baseline Q2 — "How comfortable are you with tech?"** (single-select)
- I mostly just click things and want stuff to work
- I know my way around Settings and can Google problems
- I'm technical — I use the command line sometimes, I've edited the registry
- I'm a developer or IT pro

Store both answers in `profile.userIntent` and `profile.userTechnicalLevel`. Every module doc must specify how its questions/defaults change based on these.

### How each user profile affects module defaults

**userTechnicalLevel = "clicker" (level 1):**
- Skip ALL developer/advanced modules by default (defender, crashdumps, ssh-agent, drivers-manual, unused-apps).
- Never ask about "hidden system files", "PowerShell", "registry keys" etc. — use even simpler wording, hide advanced options.
- Recycle Bin, thumbnail cache, WU cache — auto-clean (they'll never miss them).
- Aggressive defaults: uninstall built-in apps they clearly don't use, no need to ask about Notepad / Calc (they'll be kept anyway).
- Never uninstall apps they might use ambiguously — err heavily on keep.
- crashdumps module: don't offer unless there are 3+ recent BSODs.

**userTechnicalLevel = "power user" (level 2):**
- Standard flow. Show tweaks like classic right-click, hide Widgets. Ask about Photos/Camera.
- Skip developer-specific modules (defender exclusions for toolchains, ssh-agent) unless they ask.
- crashdumps offered if any recent BSODs.

**userTechnicalLevel = "technical" (level 3):**
- Include developer modules by default.
- Ask about SSH, ssh-agent, Windows Terminal, WSL2 preferences.
- Show all options — no dumbing-down. Include DISM cleanup as an offered option.

**userTechnicalLevel = "developer" (level 4):**
- Include ALL modules by default including drivers hunt + crashdumps + defender toolchain exclusions.
- Offer ssh-agent enable, PowerShell 7 install, Windows Terminal.
- Aggressive unused-apps thresholds (offer at 60 days idle instead of 90).
- Suggest dev-role app installs (VS Code, Git, GitHub CLI, Docker if missing).

**userIntent = "browsing"** or **"office"**:
- Skip gaming module treatments (Epic launcher auto-start = disable without asking).
- Skip creator apps in ninite-personalized.
- Keep media/streaming assumption for VLC skip.

**userIntent = "creation"**:
- Ninite-personalized includes creator bundle (Audacity, HandBrake, OBS, IrfanView).
- Local media assumed → VLC + audio tools included.
- Storage module: warn extra loud before touching any user-created folders.

**userIntent = "gaming"**:
- Keep Xbox Game Bar (don't silently uninstall).
- Keep Epic, Steam, Discord auto-starts (don't ask).
- Suggest gamer bundle: Steam, Discord, GeForce Experience.

**userIntent = "development"**:
- Same as technical level 3+ regardless of tech level answer.
- ssh-agent auto-enabled if git present.
- Defender exclusions asked for every detected toolchain.

The two baseline questions replace the need for many mid-module asks. A "clicker" user picking "browsing" gets ~3 total questions across all CORE modules. A developer picking "development" gets ~15.

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
