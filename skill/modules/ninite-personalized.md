# module: ninite-personalized

Tier: OPTIONAL. Opt-in via `--include ninite-personalized`. Detects the user's role AND recommends the "well-configured modern PC" defaults. One question per app, conversationally. NEVER auto-installs.

## Success criteria

At the end of this module the user has:
1. A detected-role JSON (`dev` / `creative` / `gamer` / `office` / `sysadmin` / `modern-solo-dev` — non-exclusive, weighted).
2. The `recommended-modern` bundle applied on top of role bundles — this is the seed-machine's setup, treated as the good-practice baseline for any modern user.
3. Per-app question, one at a time — Yes / No / What's this?
4. After all installs are agreed to, default-app follow-up questions (VLC for video, browser default, etc.).
5. A copy-paste block of `winget install --id <id> --silent` commands for each user-approved app, PLUS a launched-Settings prompt for each default-app change the user agreed to.
6. No installations run. This module writes a suggestion Markdown to the snapshot dir; user runs commands manually.

## Flow

### 1. Diagnose

Run `ps/diagnose/ninite-personalized.ps1`. It emits:
- `.installed[]` — union of `Get-Package`, `Get-AppxPackage`, `winget list`, plus registry `Uninstall` scan (both HKLM 64-bit + Wow6432Node, HKCU). Normalized to `{id, name, publisher, source, version}`.
- `.roleSignals[]` — evidence per role (dev, creative, gamer, office, sysadmin, modern-solo-dev). See `data/role_signals.json`.
- `.roles` — weighted (0-1) role scores.
- `.recommendedDefaults[]` — the `recommended-modern` bundle from `data/ninite_bundles.json`, filtered to only those not-installed.
- `.roleBundles{}` — per-role bundles, filtered to only those not-installed.

### 2. Categorize / decide

For each app in `recommendedDefaults` OR in an active role bundle:
- **ASK-USER (per-app)** — one question per app that the user doesn't already have.
- **SKIP** — app is already installed (any source).
- **NEVER-AUTO** — this module never runs `winget install`.

Prioritize the `recommended-modern` bundle first (universal), then top ranked role-specific apps. Cap total questions per run at 15 to avoid overwhelming.

### 3. Ask the runtime gate questions FIRST

Before asking about individual apps, ask 1-2 gate questions that determine which apps are even in scope.

---

**Gate Q1 — Music / video usage**

> "How do you mostly listen to music and watch videos?"

Answers:
- `Streaming services (Spotify, Apple Music, YouTube Music, Netflix, etc.)`
- `Local files on my computer (MP3s, MP4s I already have)`
- `Both`
- `I'm not sure`

*"I'm not sure" inference:* If Spotify / Apple Music / iTunes / YouTube Music process was launched in the last 30 days → `Streaming`. If VLC / Windows Media Player / Winamp launched recently → `Local`. If nothing detected → `Streaming` (safer default; most users these days).

Use this to gate `askOnlyIf: local_media` apps in the bundle. If Streaming: skip VLC and Audacity questions (user doesn't need them). If Local or Both: include them.

---

**Skip password manager entirely.** The data file explicitly omits Bitwarden / 1Password because choosing a password manager is a personal decision pc-cleaner should not push. If the user asks in conversation "should I use a password manager?", give a neutral 3-line comparison: Bitwarden (free), 1Password (paid, family plan), KeePassXC (offline). Do not add a `winget install` step for any of them unless the user explicitly asks to install a specific one.

**Single-choice browser.** Only offer Chrome. If the user already has Chrome installed → skip the question. If the user explicitly asks "what about Firefox?" — mention it as a privacy alternative in one line, do not add it as an automatic recommendation.

**Single-choice image viewer.** Only offer IrfanView. Nomacs is not in the default recommendation.

### 4. Ask the user, one app at a time

**Plain-English rule: describe apps by what they DO ("a free code editor most developers use") not by publisher / role ID.** Keep winget package IDs INTERNAL.

Use `AskUserQuestion` with `multiSelect: false` — one call per app.

---

**Q template for each recommended app the user doesn't have:**

> "You don't have [App Name] installed. [One-sentence what it does.] Want me to install it?"

Answers:
- `Yes`
- `No`
- `What's this?` — expands to publisher, size, category. Re-asks.
- `I'm not sure — figure it out for me` — applies the inference rule.

Question metadata per app (from `data/ninite_bundles.json`):
- `whyItMatters` — the one-sentence blurb shown in the question
- `sizeMB` — approx install size
- `publisher` — who makes it
- `category` — utility / media / communication / browser / editor / terminal / developer

*Skip if:* the app is already installed (per `.installed[]`).
*Skip if:* the app has `askOnlyIf: local_media` AND the gate answer was `Streaming`.
*Skip if:* the app is in the deliberately-omitted list (password managers).

*"I'm not sure" inference per app:*
- `7zip.7zip` → YES (universal utility, tiny footprint, everyone needs archive support).
- `Microsoft.PowerToys` → YES (free, from Microsoft, quality tweaks).
- `voidtools.Everything` → YES (5 MB, most people love it once they try it).
- `VideoLAN.VLC` → YES only if gate = Local; otherwise SKIP entirely.
- `IrfanSkiljan.IrfanView` → YES (tiny, opens JPGs instantly, Photos app is slow).
- `Microsoft.VisualStudioCode` → YES if any dev signal present, otherwise NO.
- `Microsoft.WindowsTerminal` → YES if any dev signal, otherwise NO.
- Communication apps (Zoom, Discord, Slack) → SKIP the question entirely if user has zero signal for that platform. Only ask if a related file or contact was seen.
- `Google.Chrome` → YES unless the user has clearly stated they use Firefox as main browser.

*Controls:* winget package ID (INTERNAL) — copied to the plan JSON.

---

**Q — Set as default? (asked AFTER all install questions)**

For each app the user agreed to install AND for which "set as default" is meaningful (VLC for video, Firefox/Chrome for browser, IrfanView/Nomacs for image, VS Code for text):

> "Set [VLC] as your default for video files?"

Answers:
- `Yes — open Settings for me to click`
- `No — leave defaults alone`
- `I'm not sure`

*Skip if:* app wasn't installed OR "default app for X" would require a file-association only meaningful once the app is installed. The apply script defers these to a "post-install" checklist.

*"I'm not sure" inference:* → NO (safer — never auto-change file associations; user's existing default might be intentional).

*Controls:* the apply script writes a follow-up instruction file that opens `ms-settings:defaultapps?registeredAppUser=<app>` for each YES.

---

### After all questions, show the decision summary

> **DEPRECATED under the batched orchestrator (SKILL.md, 2026-07-07).** In full `/pc-cleaner` runs, this per-module summary is absorbed into the unified plan preview — do NOT emit it. Kept below as reference for the single-module invocation `/pc-cleaner ninite-personalized` where a per-module summary still makes sense.

```
Recommended apps — here's what I'll suggest:

  Install:
    7-Zip:                    YES  (auto: universal)
    PowerToys:                YES  (auto)
    Everything (search):      YES  (auto)
    VLC:                      YES  (you said yes)
    Bitwarden:                YES  (auto: no password manager detected)
    VS Code:                  YES  (auto: dev role detected)
    Windows Terminal:         YES  (auto: dev)
    OBS Studio:               NO   (you said no)
    Discord:                  (skipped — already installed)
    Chrome:                   NO   (you said no)
    Firefox:                  (skipped — Chrome installed, mutually exclusive)

  Set as default:
    VLC for video:            (deferred to post-install)
    IrfanView for images:     (deferred to post-install)

I'll write copy-paste install commands to <snapshot>/ninite-personalized/suggestions.md.
Nothing installs automatically.
Continue?  [Yes / No / Show me the list]
```

### 4. Build plan JSON

```json
{
  "reportOnly": true,
  "detectedRoles": {"dev":0.82,"modern-solo-dev":0.75},
  "suggestions": [
    {"role":"always_useful","name":"7-Zip","wingetId":"7zip.7zip","whyItMatters":"...","sizeMB":2,"publisher":"7-Zip"},
    {"role":"dev","name":"Windows Terminal","wingetId":"Microsoft.WindowsTerminal","whyItMatters":"...","sizeMB":80,"publisher":"Microsoft"}
  ],
  "setDefaults": [
    {"app":"VideoLAN.VLC","for":"video","action":"open-settings"}
  ]
}
```

### 5. Apply (no elevation, no install)

Call `ps/apply/ninite-personalized.ps1 -Plan <path> -SnapshotDir <path>`. It writes:
- `<snapshotDir>/ninite-personalized/suggestions.md` — human-readable table with reason + copy-paste block:
  ```
  winget install --id 7zip.7zip --silent --accept-source-agreements --accept-package-agreements
  winget install --id Microsoft.WindowsTerminal --silent --accept-source-agreements --accept-package-agreements
  ```
- `<snapshotDir>/ninite-personalized/set-defaults.md` — for each `setDefaults[]` entry, one-line instruction: "After VLC installs, open Settings → Default Apps → VLC → set for .mp4, .mkv, .mov."
- No changes to the system. `revert.ps1` is a no-op.

### 6. Report

Print the suggestions table + copy-paste block + set-defaults follow-up to the run log. Explicit note: "This module never installs. Run these commands yourself. Elevated PowerShell recommended."

## Known gotchas

- winget install of a package that already exists (via non-winget source, e.g. Chocolatey or MSI) sometimes exits 0 with "no available upgrade" and sometimes fails with "package already installed by another source." Detect installed-outside-winget via the union of sources in diagnose, and skip in suggestions.
- Some packages have wildly different winget IDs than expected: `Notepad++.Notepad++`, `Microsoft.PowerShell`, `OpenJS.NodeJS.LTS`, `Docker.DockerDesktop`. Encode canonical IDs in `data/ninite_bundles.json`.
- Detecting Steam/Epic/Ubisoft launchers via `Get-Package` misses them on some machines because they install per-user under `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`. Walk HKCU too.
- Adobe Creative Cloud installs 50+ subpackages; a machine with even one Adobe app usually has the CC helper. Detect the helper as the anchor for "creative role."
- WSL-based tooling (`aws-cli` inside a WSL distro) doesn't count for the Windows-native suggestion. If the user has `aws-cli` in WSL only, still suggest the Windows-native one.
- Winget source agreements must be accepted on first run per user. Include `--accept-source-agreements --accept-package-agreements` in every copy-paste command.
- winget upgrades of Store-installed apps sometimes lock up if the Store app has a pending update.
- OEM-installed antivirus (McAfee LiveSafe, Norton) shows up in `Get-Package` — do not suggest replacing with a "better" AV. Off scope.
- Role signals are additive, not exclusive. A machine with Docker Desktop + Steam + Adobe is "all of them."
- Some suggestions require additional setup steps (Windows Terminal profile config, `gh auth login`, `wsl --install` for a distro). The suggestions.md should link to those follow-ups, not just the install command.
- Setting default apps programmatically is blocked on Win10 1803+ — you can't `assoc` your way to a new default. The only path is opening Settings and having the user click. Handle via `setDefaults[]` action.
- Mutually exclusive groups (browser: Chrome vs Firefox; password manager: Bitwarden vs 1Password) — only ask about one at a time. If user rejects the offered one, don't come back with the alternative unless they ask.

## Curated defaults / Data files

- `data/ninite_bundles.json` — schema per app:
  ```json
  {
    "id": "7zip.7zip",
    "name": "7-Zip",
    "whyItMatters": "Opens .zip / .rar / .7z / .tar.gz files. Free.",
    "sizeMB": 2,
    "publisher": "Igor Pavlov",
    "category": "utility",
    "commonAmong": "everyone",
    "mutuallyExclusiveGroup": null
  }
  ```
  Bundles: `recommended-modern` (always offered), `dev`, `creative`, `gamer`, `office`, `student`, `sysadmin`, `always_useful` (legacy — merging into `recommended-modern`).
- `data/role_signals.json` — map from installed-app match pattern → role and weight. Includes the `modern-solo-dev` role.

## Machine profile branches

- `profile.flags.hasDiscreteGPU=true` AND detected gamer role: also suggest MSI Afterburner + HWiNFO64 for monitoring.
- `profile.flags.hasDiscreteGPU=true` AND detected creative role: also suggest OBS (recording), DaVinci Resolve (if not present).
- No dev role AND no creative role AND WSL not installed: prune `dev`-heavy suggestions from the `recommended-modern` bundle (VS Code, Windows Terminal). Keep 7-Zip, PowerToys, Everything, VLC.
- Windows Home vs Pro: on Home, don't suggest RSAT / Hyper-V Manager.
- Corporate machine (`.domain.joined=true` or MDM-managed): print a caveat that installs may violate corp policy.
