# module: startup

Tier: CORE. Auto-runs. Asks a conversational one-question-per-item flow for every MAYBE autostart entry.

## Success criteria

At the end of this module the user has:
1. A JSON snapshot of every autostart entry (Run keys, Startup folders, logon-triggered scheduled tasks) BEFORE any change.
2. Every DISABLE-SAFE autostart disabled (not deleted — flip `Enabled=0` where possible).
3. Every KEEP-FOR-YOU entry left alone with reason logged.
4. Every MAYBE resolved one question at a time (Yes / No / I'm not sure), skip-conditions honored.
5. A `revert.ps1` in the snapshot dir that undoes everything.

## Flow

### 1. Diagnose

Run `ps/diagnose/startup.ps1`. Enumerates:

| Source | Path |
|---|---|
| HKLM Run | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run` |
| HKLM Run (Wow64) | `HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run` |
| HKCU Run | `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run` |
| HKCU Run (Wow64) | `HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run` |
| Approved list | `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run` (byte value: 03/02 = enabled) |
| User startup folder | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup` |
| Common startup folder | `%PROGRAMDATA%\Microsoft\Windows\Start Menu\Programs\Startup` |
| Task Scheduler | `Get-ScheduledTask` where triggers include `MSFT_TaskLogonTrigger` or `MSFT_TaskBootTrigger`, State=Ready, Author != "Microsoft Corporation" (or in `\Microsoft\Windows\` unless the task itself is user-created) |

For each entry emit `{source, name, command, publisher, signed, installedApp, enabled, category, iconPath, oneLineDescription}` where `installedApp` is a best-effort match of the command path against `Get-Package` / `Get-AppxPackage` output. The `oneLineDescription` is looked up in `data/startup_disable_safe.json` (`description` field) — "this app is for..." — and shown to the user with the icon.

### 2. Enrich verdicts using machine profile + installed apps

For each entry:
- `KEEP-TRIPWIRE` — in `data/startup_tripwire.json` (security agents, MDM, corporate VPN, password managers, backup agents, cloud sync with data locally). Never ask, never touch.
- `KEEP-FOR-YOU` if the launching app is clearly user-relied-on (Docker Desktop with `wsl -l` returning distros, NVIDIA / AMD control panel matching a present GPU, OEM management app on that laptop's OEM).
- `DISABLE-SAFE` if it's in `data/startup_disable_safe.json` (Adobe updater helpers, Spotify webhelper, Steam Client Bootstrapper, GoogleUpdate, EdgeUpdate) — silent updaters that re-run on demand. Do not ask.
- `MAYBE` — everything else. Each gets its own question.

### 3. Ask the MAYBEs one by one, conversationally, adaptive

**Approach:** Each MAYBE gets its own quick yes/no/"I'm not sure" question. This is a conversation, not a form. Show the app's icon + the one-line description alongside every question.

**Adaptive skip:** Before asking any question, check the skip condition. If it applies, don't ask — the item is decided by evidence alone. All questions offer three answers: `Yes`, `No`, `I'm not sure`. "I'm not sure" triggers the inference rule.

The question template used for every MAYBE:

> "Do you want [App Name] to open automatically when you start your computer?"

The question copy stays the same; only the app name and one-line description change. Below the question show: icon (if the diagnose script resolved one), `oneLineDescription` (e.g. "This is Spotify — music streaming."), and the source (e.g. "Currently opens at login."). Never show the raw registry name (`Spotify.exe`, `GoogleUpdate`, `RtkAudUService`) in visible text.

The order in which entries are asked, and the skip / inference rules per class:

---

**MAYBE-Q1 — Chat / messaging apps** (per entry: Slack, Discord, Telegram, WhatsApp Desktop, Signal, Zoom Chat, Microsoft Teams Personal, Skype)

*Skip if:* the app is not currently enabled to autostart, OR the app is not installed.

*"I'm not sure" inference:* UserAssist launch count in the last 30 days ≥ 5 → YES (they use it daily; opening at login is helpful). Otherwise → NO (they can open it from Start when they want it).

*Controls:* the entry's raw name — `Slack`, `Discord`, `Telegram`, `WhatsApp`, `Signal Desktop`, `MicrosoftTeams`, `Skype`, etc. Kept INTERNAL.

---

**MAYBE-Q2 — Game launchers** (per entry: Steam, Epic Games Launcher, Ubisoft Connect, EA App, Battle.net, GOG Galaxy, Rockstar Launcher)

*Skip if:* not currently enabled to autostart, OR launcher not installed.

*"I'm not sure" inference:* if `profile.gpu[]` has a discrete GPU AND UserAssist shows the launcher run within 14 days → YES. Otherwise → NO. (Game launchers run heavy background services; users typically launch them manually when they want to play.)

*Controls:* `Steam`, `EpicGamesLauncher`, `Ubisoft Connect`, `EADesktop`, `Battle.net`, `GalaxyClient`, etc.

---

**MAYBE-Q3 — Music / media players** (per entry: Spotify, iTunes / Apple Music, Tidal)

*Skip if:* not currently enabled to autostart, OR app not installed.

*"I'm not sure" inference:* UserAssist launch count in the last 30 days ≥ 10 → YES. Otherwise → NO (Spotify opens fast on demand).

*Controls:* `Spotify`, `iTunesHelper`, `Tidal`.

---

**MAYBE-Q4 — Silent app updaters** (per entry: Google's updater for Chrome, Microsoft Edge's updater, Java's updater, Adobe's updater, Brave's updater, Zoom's updater, GitHub Desktop updater)

Question copy for these differs slightly — spell out that it's a background updater and unchecking it doesn't stop the app from updating:

> "Do you want the background updater for [Chrome / Edge / Java / Adobe / etc.] to keep running at every boot? (The app still updates itself when you open it.)"

*Skip if:* the updater isn't currently enabled to autostart.

*"I'm not sure" inference:* → NO. (Silent updaters are one of the top boot-time cruft categories; the app re-adds them on next launch anyway if it needs to. Almost never a genuine YES.)

*Controls:* `GoogleUpdate`, `MicrosoftEdgeUpdate`, `SunJavaUpdateSched`, `AdobeAAMUpdater`, `BraveUpdate`, etc. These are also often duplicated as scheduled tasks — the diagnose script cross-references and asks once.

---

**MAYBE-Q5 — Cloud sync apps** (per entry: OneDrive, Dropbox, Google Drive, iCloud, MEGA, pCloud, Sync.com)

*Skip if:* not installed OR not currently enabled to autostart. Also skip OneDrive if `services` module already asked about it in this session (dependency).

*"I'm not sure" inference:*
- For OneDrive: `Get-Process OneDrive` running today OR `HKCU:\Software\Microsoft\OneDrive\Accounts\Personal` has an account with a `last_synced` timestamp in the last 30 d → YES. Otherwise → NO.
- For Dropbox: registry `HKCU:\Software\Dropbox` present AND process observed running within 30 d → YES. Otherwise → NO.
- Same pattern per provider: does the account exist AND has it synced recently?

*Controls:* `OneDrive`, `Dropbox`, `GoogleDriveFS`, `iCloudDrive`, `MEGAsync`, `pCloud`, `Sync`.

---

**MAYBE-Q6 — OEM helpers** (per entry: Lenovo Vantage, HP Support Assistant, Dell Command Update, ASUS Armoury Crate, MyASUS)

*Skip if:* `profile.system.manufacturer` doesn't match the helper (a Lenovo Vantage entry on an HP laptop = broken leftover, mark for uninstall via `bloat`, do not ask).

*"I'm not sure" inference:*
- If `profile.flags.isLaptop=true` AND the OEM matches the machine → YES (these push firmware / thermal fixes on laptops).
- If `profile.flags.isLaptop=false` (desktop) → NO.

*Controls:* `LenovoVantageService`, `HPSupportAssistant`, `Dell.Update`, `ArmouryCrate.exe`, `MyASUS`.

---

**MAYBE-Q7 — RGB / lighting software** (per entry: Corsair iCUE, Razer Synapse, Logitech G HUB, ASUS Aura, SignalRGB, OpenRGB)

*Skip if:* no matching device present. Diagnose script cross-references `Get-PnpDevice -Class HIDClass` for Corsair / Razer / Logitech VIDs.

*"I'm not sure" inference:* If the matching device is present AND UserAssist shows the app opened within 90 d → YES. Otherwise → NO (RGB software can be started manually when you want to change settings; running at boot is not required for LEDs to stay on).

*Controls:* `iCUE.exe`, `Razer Synapse 3`, `LGHUB`, `AuraService`, `SignalRGB`, `OpenRGB`.

---

**MAYBE-Q8 — GPU vendor tools** (per entry: NVIDIA App / GeForce Experience, AMD Adrenalin overlay, Intel Graphics Command Center)

*Skip if:* the matching GPU is not in `profile.gpu[]`.

*"I'm not sure" inference:* If the matching GPU is present AND user is detected as gamer role (per role_signals) → YES. Otherwise → NO (control panel opens fine on demand).

*Controls:* `NVIDIA App`, `NVIDIA GeForce Experience`, `AMD Software: Adrenalin Edition`, `Intel Graphics Command Center`.

---

**MAYBE-Q9 — Anything else that fell through**

For each remaining entry not covered above — an app the diagnose script found in the Run keys or Startup folder that we don't have a class for — ask the plain template:

> "Do you want [App Name] to open automatically when you start your computer?"

*Skip if:* not installed OR already disabled.

*"I'm not sure" inference:* → NO (default for grey-area entries). Any tripwire entry that ended up here by mistake is flagged as a bug in the diagnose script, not asked.

*Controls:* whatever raw registry name / .lnk name matches. INTERNAL.

---

### After all questions, show the decision summary

> **DEPRECATED under the batched orchestrator (SKILL.md, 2026-07-07).** In full `/pc-cleaner` runs, this per-module summary is absorbed into the unified plan preview — do NOT emit it. Kept below as reference for the single-module invocation `/pc-cleaner startup` where a per-module summary still makes sense.

```
Autostart cleanup — here's what I figured out:

  Discord:            NO   (you said no)
  Slack:              YES  (you said yes)
  Steam:              NO   (auto-detected: no launches in 14 days)
  Spotify:            NO   (auto-detected: you launched it 2x this month)
  Google's updater:   NO   (auto: silent updater, app still updates itself)
  Adobe's updater:    NO   (auto: silent updater)
  OneDrive:           YES  (auto-detected: synced today)
  Dropbox:            (skipped — not installed)
  Lenovo Vantage:     YES  (auto: laptop, matches OEM, pushes firmware)
  iCUE (Corsair):     (skipped — no Corsair device detected)
  NVIDIA App:         (skipped — no NVIDIA GPU)

I'll disable 12 autostart entries and keep 4.
Continue?  [Yes / No / Show me the list]
```

Anything the user challenges here → flip the decision, adjust the plan, ask them to confirm again.

Use `AskUserQuestion` with `multiSelect: false` (single-select yes/no/not-sure) — one call per MAYBE. Keep raw autostart names (`Spotify`, `GoogleUpdate`, `LenovoVantageService`) INTERNAL. Icon + oneLineDescription go in the question metadata, not the raw name.

### 4. Build plan JSON

```json
{
  "disableRegistry": [{"hive":"HKCU","view":"64","name":"Spotify","reason":"user said no"}],
  "disableStartupFolder": [{"scope":"user","file":"Discord.lnk","reason":"user said no"}],
  "disableTasks": [{"taskPath":"\\","taskName":"GoogleUpdateTaskUserS-1-...UA","reason":"silent updater — auto-inferred NO"}]
}
```

### 5. Apply (elevated only if HKLM or common startup or `\Microsoft\Windows\` tasks touched)

Call `ps/apply/startup.ps1 -Plan <path> -SnapshotDir <path>`. It:
- For Registry Run entries: writes the StartupApproved byte to disabled (`06 00 00 00 ...`) rather than deleting the value. Revert restores original bytes.
- For Startup folder: moves the `.lnk` into `<snapshotDir>\startup\disabled-lnks\` (do not delete).
- For scheduled tasks: `Disable-ScheduledTask`. Revert re-enables.

### 6. Report

- Autostart count before/after.
- Per-entry decision with the question that triggered each (or "auto-detected" reason).
- Snapshot + revert paths.

## Known gotchas

- The `StartupApproved` byte layout: bytes 0-3 = enable flag (`02 00 00 00` or `03 00 00 00` = enabled; `06 00 00 00` = disabled), bytes 4-11 = FILETIME of the state change. If you overwrite without preserving alignment Windows treats the entry as corrupt and shows "unknown" in Task Manager Startup tab. Copy the existing bytes, mutate only byte 0.
- Task Scheduler tasks under `\Microsoft\Windows\` may be re-created by Windows Update or feature updates. `Disable-ScheduledTask` survives cumulative updates but often does NOT survive feature updates (23H2 → 24H2). Note this in the report so the user knows to re-run after big updates.
- Some entries (Realtek Audio Console `RtkAudUService`, Intel Graphics helper `igfxTray`) are BOTH a service AND an autostart entry AND a scheduled task. Disabling only one has no effect. Cross-reference with the services module output and note overlap.
- `Get-ScheduledTask` on PS 5.1 silently truncates the task path when it contains non-ASCII (e.g. `\Microsoft\Windows\Söngi`). Use `schtasks.exe /query /fo csv /v` fallback when a non-ASCII task path is expected.
- OneDrive `OneDrive.exe /background` shows up as HKCU Run but if you disable it while files are actively syncing you can freeze Explorer. Check `Get-Process OneDrive` and pending queue file `%LOCALAPPDATA%\Microsoft\OneDrive\logs\Business1\SyncEngine.log` before disabling.
- Docker Desktop autostart also enables the `com.docker.service` Windows service. Disabling only the tray icon leaves the service running. Cross-check with services module — if user said "disable Docker autostart" they probably meant both.

## Curated defaults / Data files

- `data/startup_disable_safe.json` — array of `{namePattern, publisher, description ("this app is for..." one-liner), reason}`. Machine-agnostic autostart cruft. Extend to add more.
- `data/startup_tripwire.json` — never disable: security agents (CrowdStrike, SentinelOne, Defender helpers), MDM (Intune), corporate VPN, password managers, backup agents.
- `data/startup_role_hints.json` — maps common autostart names to a "role" (`dev`, `creative`, `gamer`, `office`) used by `ninite-personalized` to detect the user's role.

## Machine profile branches

- `profile.flags.isLaptop=true` AND OEM vendor management app installed (Lenovo Vantage, HP Support Assistant, Dell Command Update): inference tips YES. On laptops these push firmware/thermal fixes.
- `profile.flags.hasDiscreteGPU=true`: keep NVIDIA / AMD control panel launcher unless user unchecks (needed for Optimus / hybrid graphics switching).
- Desktop: OEM helpers are almost always cruft; inference tips NO.
- If `wsl -l -q` returns any distro, Docker Desktop / Rancher / Podman Desktop autostart is treated as KEEP-FOR-YOU by default (not asked).
