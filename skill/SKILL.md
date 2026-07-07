---
name: pc-cleaner
description: Audit and clean a Windows PC. Disable bloat services, kill autostart cruft, uninstall unused apps, tune privacy defaults, and (opt-in) fix laptop-platform performance issues (Ryzen 6000 sleep, Realtek WiFi driver stale-ness, PCIe ASPM). Use when the user asks to "clean the PC", "make Windows faster", "audit services", or invokes a specific module by name.
---

# pc-cleaner

## Invocation forms

| User types | Behavior |
|---|---|
| `/pc-cleaner` | Run all CORE modules. Present ONE unified plan (lists of what's used vs not used, what'll be cleaned, what'll be tweaked). ONE apply/change/cancel question. |
| `/pc-cleaner all` | CORE + OPTIONAL, same unified-plan flow. |
| `/pc-cleaner <module>` | Run one module. Still shows a plan preview; still ONE apply question. |
| `/pc-cleaner --include a,b,c` | CORE + explicitly-listed optionals. |
| `/pc-cleaner --exclude a,b` | CORE minus the listed modules. |
| `/pc-cleaner undo` | Undo the latest snapshot. No timestamp needed — finds the newest folder under `~/Desktop/pc-cleaner-snapshots/` and runs its `revert.ps1` in reverse module order. |
| `/pc-cleaner undo <timestamp>` | Undo a specific snapshot. Only if user wants to skip past the latest. |
| `/pc-cleaner dry-run` | Diagnose + show plan preview — do NOT apply. Same as picking "Cancel" at the apply gate. |
| `/pc-cleaner quick` | Zero questions. Apply only the unambiguously-safe defaults (skips every ask-gated item). For users who explicitly want minimum interaction. |

If the user asked in natural language ("clean my PC", "make it faster") without specifying, run the default CORE flow.

## Guiding principles

1. **Snapshot before every apply.** No exceptions. Every module writes its own snapshot to `%USERPROFILE%\Desktop\pc-cleaner-snapshots\<ISO-timestamp>\<module>\`. Every apply produces a `revert.ps1` in that folder.
2. **Ask only when the decision is genuinely ambiguous, and ask ONCE per run.** If a category is unambiguously safe or unambiguously required for THIS machine, apply / skip without asking. The orchestrator batches every module's inference rules into a single unified plan preview (see "The unified plan preview" section), then asks ONE Apply/Change/Cancel question. Individual per-module questions from the module docs are the *decision logic* the orchestrator reads — not questions asked directly. The absolute maximum surviving to individual AskUserQuestion calls after the plan preview is 4 taste-decision items. Interrogating the user in per-module sequence is the anti-pattern; a Level-1 user should see 2 baseline questions + 1 plan preview + 0-4 taste questions, total.
3. **Machine-aware first.** `profile` runs before everything. Every subsequent module branches on the profile. Warnings and defaults are targeted to real risk on this specific machine.
4. **Explain every decision** in the run log. `[APPLY] <what> — reason: <why>`. No mystery meat.
5. **Never touch tripwire services / settings.** See `data/services_tripwire.json`. Enforced at THREE layers: (1) Claude reasoning must not add a tripwire name to any plan; (2) `apply/services.ps1` refuses at runtime; (3) `verify/smoke.ps1` catches regressions post-apply. If a user tries to force one via a flag, explain the risk and refuse without `--iknowwhatimdoing`.
6. **Additive optional modules only apply if opted in.** The user's iPhone doesn't get their apps rearranged because they said "clean my PC".
7. **All user-facing questions must be plain English, informal.** Never use technical names in what the user reads. Describe things from the user's perspective ("Do you share files from this computer so other people on your WiFi can access them?"), not the technical name ("Enable SMB server?"). If a term is unavoidable, add a parenthetical explanation ("this is very rare", "used by only a few games"). No jargon: no `MDM`, `S3`, `HKCU`, `SubsystemVendor`, `LPS flags`, `Prefetch`, `stornvme`, etc. in the question text itself.
8. **Lists over interrogation.** The user sees a structured plan preview (lists of "apps you use / don't use / features I'll turn off / cleanup items / small tweaks"), not a sequence of individual Q's. Each entry is written for the user's mental model — what they'd RECOGNIZE the thing as, not its Windows API name. The plan preview is the primary interaction surface; single AskUserQuestion calls come only for taste decisions (max 4). Front-load hardware detection so items that can't apply (fingerprint on a machine with no biometric hardware, Windows VPN when OpenVPN is running, Comet when it isn't installed) don't appear in the plan at all.

**Every module doc still specifies the inference rule per candidate item** — the exact PowerShell / registry check that produces YES or NO. The orchestrator reads these rules in step 6 and applies them all at once. Rules are the contract; the module's individual per-question wording is fallback for the case where the orchestrator needs to drill in.

Every taste-decision AskUserQuestion (the max-4 surviving to individual asks) offers three options: `Yes`, `No`, `I'm not sure — pick the safe default`.

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

## Top-level orchestration flow — the list-based batched model

The goal: for a non-technical user, the whole run is **2 baseline questions → look at a list → one Apply button**. Not a per-module interview. Individual module docs still specify the underlying inference rules — the orchestrator reads all of them once and batches the presentation.

```
1. Parse invocation. Determine module list.
2. Confirm scope in one line, plain-English:
   "I'll check your services, startup apps, preinstalled apps, privacy
    settings, File Explorer, and disk cleanup. This takes about 20 seconds
    to look, then I'll show you what I found."
3. Run `profile` diagnose. Cache machine profile for the whole run.
4. Ask the 2 BASELINE questions (usage + tech level). These auto-decide the
   majority of downstream items.
5. Run ALL diagnose scripts in parallel (they're read-only and independent).
   No apply yet. This is the "look at your PC" phase.
6. Build the UNIFIED PLAN by walking every module's inference rules with the
   baseline profile as context. For each candidate item:
   a. Detect state on this machine (installed / running / hardware present).
   b. Apply the inference rule (many resolve to a definite YES/NO without asking).
   c. Mark items that STILL need user input as `needsInput:true`.
6a. If `userTechnicalLevel == "clicker"`: force `needsInput:false` on all
    items whose category is technical (LLMNR, Prefetch, DoH provider,
    DISM /resetbase, Fast Startup, ssh-agent). Fall back to the safe
    default from the module's inference rule.
7. PRESENT the plan as structured lists in assistant text (see next section
   for the exact template). This is the "here's what I found" moment.
8. Ask ONE question: "Apply all this, change something, or cancel?"
   - Apply all — proceed.
   - Change something — free-form input: "Just tell me what to keep or
     what to skip." Parse into plan edits; re-show; ask again.
   - Cancel — stop here. This is also the "dry run" outcome.
9. Run `benchmark` (before).
10. For each module: call its `apply` script (elevated) with the batched
    plan JSON (every ask-gated entry has `confirmed:true`).
11. Run `ps/verify/smoke.ps1`. If any FAIL:
    - Print the failing flows in plain English.
    - Point at the module suspects.
    - Offer: "Want me to undo the last changes? Type 'undo' to revert."
    Do NOT auto-revert.
12. Run `benchmark` (after). Show one-line diff.
13. Final summary — three lines max:
    "Done. Changed 47 things, freed 4.2 GB. If anything looks wrong,
     type '/pc-cleaner undo' — I'll roll it all back."
```

**Non-goals of this orchestrator:**
- No per-module summary blocks. One plan, one summary.
- No question sequences longer than 3 items visible at once. Anything longer becomes a list in prose.
- No technical vocabulary in the plan preview. Every item is named for what the user experiences.

## The unified plan preview — exact shape

This is what the orchestrator emits at step 7. It's Markdown text (rendered in the chat), not an AskUserQuestion — those come after. Sections are omitted entirely if they'd be empty for this machine. Never show a section header with "(nothing to change)" underneath.

```markdown
Here's what I found on your PC. I grouped it so you can skim.

## Apps I noticed you don't use

Based on when you last opened them (or that you never did):

- Xbox app — never opened
- Solitaire Collection — never opened
- Feedback Hub — never opened
- Get Started / Tips — never opened
- LinkedIn — never opened
- Skype — 8 months ago
- Movies & TV — 6 months ago (deprecated app)
- Groove Music — never opened (deprecated app)

→ I'll uninstall these. Frees ~1.4 GB.

## Apps I noticed you DO use — keeping these

- Photos, Camera, Calculator, Sticky Notes, Snipping Tool
- Xbox Game Bar — because you press Windows+G sometimes (screenshot / recording)
- Lenovo Vantage — because this is a Lenovo laptop under warranty

## Windows features I'll turn off

(These are all safe because your PC doesn't have the hardware or you never
use them. If any surprise you, just say so.)

- Cellular / LTE data — your laptop has no SIM card slot
- Smart card reader — you don't have one
- Fax — nobody has a fax
- Xbox Live networking — you don't play online multiplayer
- Windows Insider — you're on the stable channel
- Old file-sharing from 2005 (SMBv1) — modern devices don't use it
- Print Spooler — you told me you don't print

## Windows features I'll leave alone (even though they look disable-able)

- Bluetooth pairing wizard back-end — you'd lose the ability to add new BT devices
- Nearby Sharing / Quick Assist / Phone Link discovery
- Windows Copilot Recall — asking about this separately below

## Cleanup

- Delete 3.2 GB of temporary files, browser cache, old crash reports (safe)
- Empty Recycle Bin (1.1 GB, oldest item is 47 days old) — **skip if you might want anything back**
- Windows.old (18 GB, from your last big Windows update 23 days ago) — **can't be rolled back after**
- Compact Windows update history (2.4 GB, takes 5-15 min of CPU) — safe

## Small UI tweaks

- Hide the Widgets icon on your taskbar
- Show file extensions in File Explorer (.jpg, .docx, .exe)
- Left-align the taskbar (Windows 10 style)
- Hide the Chat (purple bubble) icon
- Hide the Copilot icon

## Things I need to ask about

Only these need your input — everything above is already decided:

1. **Windows Recall** (auto-screenshots for search): turn off, or keep on if you use it?
2. **Bing/web results in Start menu search**: keep, or files-and-apps-only?
3. **Dark mode**: turn on, or leave alone?
4. **Sleep vs Hibernate on battery**: which do you want after 30 min idle?

---
Ready to apply everything above? (I'll ask about the 4 items in "Things I need to ask" as I go.)
```

Then the single AskUserQuestion:

- **Apply everything and answer those 4 questions** — main path.
- **Change something first** — free-form: "Just tell me what to keep or skip and I'll adjust the plan."
- **Cancel** — dry-run outcome. Snapshot dir contains the plan JSON for reference.

### Rules for the plan preview

1. **Every "Apps I noticed you don't use" entry names WHEN the user last opened it.** "Never opened", "8 months ago". Not a raw filename or PackageFamilyName.
2. **Every "Apps you DO use" entry says WHY it's kept.** "Because you press Windows+G", "Because this is a Lenovo laptop". Not just an app name.
3. **Every "Windows features I'll turn off" entry explains in plain English why it's safe.** "Your laptop has no SIM slot", "You don't have one". Not "hardware not detected".
4. **The "leave alone" section is critical for building trust.** Users assume aggressive cleaners nuke random things. Explicitly showing what's PRESERVED and why demonstrates the tool understands hidden dependencies.
5. **Risky cleanup items get inline warnings.** "Skip if you might want anything back" for Recycle Bin, "can't be rolled back after" for Windows.old.
6. **The "Things I need to ask about" section caps at 4 items.** If there are more genuinely ambiguous items, batch the extras: "I'll ask about 2 more small ones during setup." Never more than 4 visible in the preview.
7. **Numbers matter.** Free space freed, size of caches, count of apps. Not "reclaim disk space" — "reclaim 4.2 GB". Not "several apps" — "8 apps".
8. **Never emit an empty section.** If bloat detected nothing to remove, drop the "Apps I noticed you don't use" section entirely. Same for every other section.

### Handling "change something"

When user picks "Change something", accept free-form text. Parse for:
- App names → toggle their remove flag ("keep Skype")
- Feature names → toggle their disable flag ("keep Print Spooler")
- Cleanup items → toggle their delete flag ("skip Windows.old", "don't empty recycle bin")
- Section-level ops ("keep all Xbox stuff", "cancel all cleanup")

Then re-render the plan preview (delta only — just the changed sections + a note "Updated based on your changes.") and ask again. Loop until Apply or Cancel.

### The 4 "must ask" questions rules

The only items that survive to be individual AskUserQuestion calls after the plan is applied:

- Anything the module doc's inference rule couldn't resolve (very rare — inference should decide everything except taste choices).
- Taste decisions with no correct default: dark mode, DNS provider, lid-close behavior when user has no historical data to infer from.
- Risky consent gates: Recall off/on, wide-open Defender exclusion.

Cap at 4. If more than 4 items genuinely need input, the orchestrator picks the top 4 by "user-visible impact if wrong" and defaults the rest to the module's safe-default value with a line in the final report: "I used the safe defaults for X, Y, Z. If any feel wrong, `/pc-cleaner undo` reverts everything."

## Level-1 fast path (userTechnicalLevel = "clicker")

When the user picks "I mostly just click things" at the baseline, the orchestrator additionally:

- Filters the "Things I need to ask about" section to only items whose wrong-answer cost is high enough to warrant a prompt. Typically: Recall (privacy sensitivity), lid-close behavior (they'll notice), maybe Windows.old (18 GB is a lot to explain to grandma if she wanted to roll back). Everything else uses the safe default silently.
- Presents the plan preview with EVEN fewer sections — collapses "Windows features I'll turn off" into a single line: "I'll turn off 12 Windows features you don't have hardware for (SIM card, smart cards, fax, Xbox networking, etc.) — safe list, no surprises."
- The "Apply everything?" question offers just two options: `Yes, apply` and `Cancel`. No "change something" branch for Level 1 (adds cognitive load; they can `/pc-cleaner undo` if anything feels off).

## Level 3-4 path (userTechnicalLevel = "technical" or "developer")

Same plan preview but:

- Full sections shown, no collapsing.
- Extra section: "Advanced items I skipped because they need judgment" (DNS provider choice, DoH strict-vs-fallback, DISM /resetbase, ssh-agent, defender toolchain exclusions). Each with a one-line explanation.
- The "Change something" branch accepts technical terms as free-form: "add exclusion for C:\dev", "set DNS to 1.1.1.1", "run resetbase".
- Extra final question at the end: "Anything else you want configured while I'm here?" — free-form input to add ad-hoc requests.

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

The two baseline questions + the unified plan preview replace all mid-module asks. Under the new orchestrator model (see "Top-level orchestration flow"): a "clicker" user picking "browsing" gets **3 questions total** (2 baseline + 1 apply gate). A developer picking "development" gets **4-8 questions total** (2 baseline + apply gate + up to 4 taste Q's + optional "anything else" free-form). No more per-module interviews — the orchestrator batches everything.

## PowerShell contract

Every module uses two script types under `ps/`:

- `diagnose/<module>.ps1` — read-only. Prints structured JSON to stdout. No admin needed. Exit 0 always if it ran.
- `apply/<module>.ps1` — takes `-Plan <path-to-JSON>` and `-SnapshotDir <path>`. Requires admin (elevate via `Start-Process -Verb RunAs` if not already elevated). Logs to `$SnapshotDir\apply.log`. Emits `$SnapshotDir\revert.ps1`.

Shared helpers in `ps/_lib/common.ps1`:
- `New-SnapshotDir -Module <name>` — returns and creates the module's snapshot dir under the current run's timestamp.
- `Test-Admin` / `Assert-Admin`.
- `Write-Log $path $level $message`.
- `Get-MachineProfile` — returns the machine profile object.

## Claude's role in the batched orchestrator

Claude IS the orchestrator. Modules are Claude's decision-logic library, not user-facing flows.

At run start:
1. Read every module's `.md` doc — treat the "Ask the user" / "Q1-QN" sections as **inference-rule catalogs**, not as sequential questions to invoke. Each Q lists a skip condition + inference rule + Controls line; these are the rules Claude applies at plan-build time.
2. Run every diagnose script in parallel (they're read-only and independent).
3. Ask the 2 baseline questions.
4. Walk every module's inference rules with the machine profile + baseline answers + diagnose output. Resolve every item to a definite YES / NO / SKIP. Only items with no possible inference (pure taste decisions) survive as `needsInput:true`.
5. Emit each module's `plan.json` (all with `confirmed:true` set on the items the orchestrator resolved).
6. Present the unified plan preview (see "The unified plan preview" section for the exact template).
7. Ask the ONE Apply/Change/Cancel question.
8. If Change: parse free-form input into plan edits, re-render preview, re-ask.
9. If Apply: run remaining ≤4 taste Q's if any; call each module's apply script; run smoke tests; benchmark diff; final summary.

**Rejected pattern:** running a module's diagnose, then reading its "Q1" section, then invoking AskUserQuestion for it, then plan, then apply — that's the per-module interview shape the orchestrator explicitly replaces.

**How to read the deprecated per-module summary blocks in module docs.** Several module docs (services, storage, privacy, explorer) contain "After all questions, show the decision summary" example blocks with sample text and a "Continue? [Yes/No/Show me the list]" prompt. Those were the pre-orchestrator design. Under the batched model: those blocks are absorbed into the unified plan preview. Do not emit per-module summaries or per-module "Continue?" questions.

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

## /pc-cleaner undo — the one-command revert

Non-technical users need a single command to unwind a run. Implementation:

1. `Get-ChildItem $env:USERPROFILE\Desktop\pc-cleaner-snapshots -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1` — this is the target snapshot.
2. Show the user in plain English: "Undoing the run from 2 hours ago. This restores your services, apps, cleanup, and UI tweaks to how they were before. Sound good?"
3. If Yes: walk every module subfolder in the snapshot (services/, startup/, bloat/, privacy/, explorer/, storage/, power/, network/, defender/) in **reverse of the module order they were applied in**, and run each `revert.ps1` — in an elevated PowerShell session Claude launches via UAC prompt.
4. Storage is special: its revert.ps1 is documentation only (deletions are irreversible). Note this in the report — cleanup items can't come back.
5. Bloat is semi-special: revert.ps1 for UWP removals is a reinstall command that either uses winget or `Add-AppxPackage -Register` from a preserved manifest. Some apps (especially preloaded games with expired licenses) may fail to reinstall — note per-app failures without blocking the rest of the revert.
6. Report: "Undone: 44 changes. 3 things couldn't be undone (empty temp folders can't come back, Skype UWP reinstall failed — you can get it from the Store). Everything else is back to how it was."

`/pc-cleaner undo <timestamp>` bypasses step 1 and targets that specific snapshot. Useful if the user ran pc-cleaner twice and wants to undo the earlier one only.

Never auto-undo. Even after a smoke-test failure, the orchestrator suggests undo but requires user confirmation. Users may have a reason to see the failure state before rolling back.

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

### 5. AskUserQuestion budget — hard cap

The orchestrator batches every module's decision logic into a single plan preview. AskUserQuestion is used only for:

- **2 baseline questions** at run start (usage + tech level).
- **1 Apply/Change/Cancel gate** after the plan preview.
- **0-4 taste-decision questions** for items no inference rule can decide (dark mode, DNS provider, lid behavior when no history, Recall). Hard cap: 4.
- **1 optional "anything else?" free-form ask** for Level 3-4 users.

Total run maximum:
- **Level 1 (clicker)**: 3 questions (2 baseline + 1 apply gate). No taste Q's shown.
- **Level 2 (power user)**: 3-6 questions (add 1-3 taste Q's).
- **Level 3-4 (technical/developer)**: 4-8 questions (add taste Q's + optional "anything else").
- **`/pc-cleaner quick`**: 0 questions. All ask-gated items default to their safe-default value.

Modules never invoke AskUserQuestion themselves. If a module doc lists Q1-Q15, those are **inference rules** the orchestrator reads at plan-build time — not questions asked in sequence. The per-module wording survives only as fallback copy if the orchestrator needs to drill into a single item during "Change something" branch.

Rejected patterns:
- Per-module summary + confirmation → replaced by single plan preview.
- Sequential Y/N questions during module run → all resolved during plan build.
- "Show me the details" branch that opens 20 more Q's → replaced by free-form change-request text.

### 6. Shared crash → driver linkage

`crashdumps` produces `crash_linked_drivers.json` (drivers that appeared in `!analyze -v` MODULE_NAME output). `drivers` reads that file and prioritizes updating those drivers first. Path: `<snapshotRoot>/crash_linked_drivers.json` — shared across modules in the same run.

## Not in scope

- **Do NOT touch Windows Defender's real-time protection.** Only add path exclusions for dev folders in the `defender` module, and only if user opts in.
- **Do NOT flash BIOS / firmware.** Ever. Point the user at Lenovo Vantage / vendor tool.
- **Do NOT auto-install any app.** `ninite-personalized` suggests; user runs.
- **Do NOT touch Group Policy / gpsvc.** Login lockout risk.
- **Do NOT modify network adapter settings without cycling the adapter afterward.** Silent config drift causes hard-to-debug bugs.
- **Do NOT run OPTIONAL modules the user didn't include.** Additive by explicit choice only.
