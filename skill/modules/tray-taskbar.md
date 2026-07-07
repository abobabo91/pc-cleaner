# module: tray-taskbar

Tier: OPTIONAL. Opt-in via `--include tray-taskbar`. Non-destructive: unpin from taskbar / hide from tray. Never uninstalls the underlying app. One question per pinned app + one per promoted tray icon.

## Success criteria

At the end of this module the user has:
1. Snapshot of current pinned taskbar apps + tray icon overflow state BEFORE change.
2. Every pinned app decided one at a time (Keep / Unpin / I'm not sure).
3. Every tray icon decided one at a time (Keep visible / Tuck away / I'm not sure), except tripwire icons which are never asked.
4. A `revert.ps1` that restores pin order and tray promotion state.

## Flow

### 1. Diagnose

Run `ps/diagnose/tray-taskbar.ps1`. Emits:
- `.pinned[]` — pinned taskbar apps, in order. Two sources:
  - Win11 22H2+: `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Taskband\FavoritesResolve` (binary blob) — parse to extract app paths, or read taskbar-pinned `.lnk` files from `%APPDATA%\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\`.
  - Cross-reference against `Get-AppxPackage` for UWP pins.
  - Emit per entry: `{name (human-readable), source, iconPath}`.
- `.tray[]` — tray icons and their visibility state:
  - Win10/11 tray state is stored in `HKCU:\Control Panel\NotifyIconSettings\<hash>` — each subkey has `ExecutablePath`, `IsPromoted` (1 = shown, 0 = hidden in overflow), `LastActivationHint`. Enumerate all subkeys.
  - Cross-reference against actively running tray-icon-having processes: `Get-Process | Where MainWindowTitle -eq '' -and Path` filtered by our known tray-emitter list from `data/known_tray_apps.json`.
  - Emit per entry: `{name (human-readable), executablePath, currentlyPromoted: bool, isTripwire: bool, hash}`.
- `.taskbarAppearance` — Widgets on/off, Search state, Chat icon, Copilot icon, Task View. All from `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced`. If the `explorer` module already ran, skip these here.

### 2. Categorize

- **PIN-ASK** — every pinned app gets its own question. No auto.
- **TRAY-ASK** — every currently-promoted tray icon that is NOT a tripwire gets its own question. Tripwires (Volume, Battery, Network / Wi-Fi, Windows Defender, Windows Update) are never asked — they stay visible always.
- **TASKBAR-BUTTONS** — Widgets, Chat/Teams button, Copilot button, Task View button — these are covered by `explorer` module. If `explorer` already handled them in the same session, skip here.

### 3. Ask the user, one at a time

**Plain-English rule: talk about "the row of icons at the bottom" and "the little icons next to the clock," not `Taskband` / `NotifyIconSettings`.** Keep the raw registry hashes and `shell:AppsFolder` identities INTERNAL. Show apps by the name the user sees.

Use `AskUserQuestion` with `multiSelect: false` — one call per item.

---

**Q per pinned app**

> "You have [App Name] pinned to your taskbar. Want to keep it there, or unpin?"

Answers: `Keep pinned` / `Unpin` / `I'm not sure`.

Show the app icon (via the diagnose script's iconPath) alongside the question.

*Skip if:* the app is a Windows-default pin AND the user hasn't customized it away yet (Start menu, Task View, Search — but note: those are usually treated as taskbar buttons in `explorer`, not pins).

*"I'm not sure" inference:* → `Keep pinned`. Safer default. Taskbar pins are trivial to remove later; leaving one in is zero cost.

*Controls:* remove `.lnk` file in `%APPDATA%\...\User Pinned\TaskBar\` + reset `FavoritesResolve` blob + explorer restart.

---

**Q per currently-promoted tray icon (non-tripwire)**

> "The [App Name] icon is always visible next to your clock. Keep it there, or tuck it away in the up-arrow menu? (Tucking away just hides it under the up-arrow — the app still runs.)"

Answers: `Keep visible` / `Tuck away` / `I'm not sure`.

Show the icon (from `.tray[].executablePath` icon resource) alongside.

*Skip if:* icon is in `data/known_tray_apps.json` as tripwire (Volume, Battery, Network, Defender, Update).
*Skip if:* icon is drawn by shared host processes (`explorer.exe`, `ctfmon.exe`, `runtimebroker.exe`) — those can't be individually promoted / demoted.

*"I'm not sure" inference:* → `Tuck away` (default: less clutter, less always-on cognitive weight). Exception per `data/known_tray_apps.json`: apps flagged `role: password_manager` or `role: security_agent` → `Keep visible`.

*Controls:* `HKCU:\Control Panel\NotifyIconSettings\<hash>\IsPromoted = 0` (tuck) or `1` (keep). Explorer restart to pick up.

---

**Q per tray icon currently in overflow (worth promoting)**

Optional — only asked if the icon matches `data/known_tray_apps.json` with `role: password_manager`, `role: chat` (Slack, Discord), or `role: notification_hub`. For these the module offers:

> "The [App Name] icon is currently hidden under the up-arrow menu. Want it always visible next to the clock instead?"

Answers: `Yes — always visible` / `No — leave hidden` / `I'm not sure`.

*Skip if:* icon doesn't match one of the promotion-worthy roles.

*"I'm not sure" inference:* → `Yes` for password managers (users benefit from seeing lock status at a glance). `No` for everything else (defaults are usually right).

*Controls:* set `IsPromoted = 1`.

---

### After all questions, show the decision summary

> **DEPRECATED under the batched orchestrator (SKILL.md, 2026-07-07).** In full `/pc-cleaner` runs, this per-module summary is absorbed into the unified plan preview — do NOT emit it. Kept below as reference for the single-module invocation `/pc-cleaner tray-taskbar` where a per-module summary still makes sense.

```
Taskbar & tray — here's what I figured out:

  Pinned:
    Microsoft Edge:        KEEP     (auto: not sure = keep)
    Microsoft Store:       UNPIN    (you said unpin)
    Mail:                  UNPIN    (you said unpin)
    File Explorer:         KEEP     (tripwire — always kept)

  Tray icons currently visible:
    OneDrive:              TUCK     (auto: default is less clutter)
    Realtek Audio:         TUCK     (auto)
    Volume, Battery, etc:  (skipped — tripwires)

  Tray icons currently hidden:
    Bitwarden:             PROMOTE  (auto: password manager)

I'll change 5 things. Explorer will restart once at the end.
Continue?  [Yes / No / Show me the list]
```

### 4. Build plan JSON

```json
{
  "unpin": ["shell:AppsFolder\\Microsoft.WindowsStore_8wekyb3d8bbwe!App", "C:\\Program Files\\Microsoft Office\\root\\Office16\\OUTLOOK.EXE"],
  "trayPromote": [{"hash":"abc123","reason":"Bitwarden — auto: password manager"}],
  "trayDemote":  [{"hash":"def456","reason":"OneDrive — auto: default"}]
}
```

### 5. Apply (no elevation for HKCU changes)

Call `ps/apply/tray-taskbar.ps1 -Plan <path> -SnapshotDir <path>`. It:
- Snapshots `HKCU:\...\Taskband` and `HKCU:\Control Panel\NotifyIconSettings` fully as `.reg` files.
- Unpin: preferred approach is programmatic via Shell verb `unpinfromtaskbar`. On Win11 22H2+ Microsoft removed the `unpinfromtaskbar` verb from most Explorer shell verbs, but it still works for `.lnk` files under `%APPDATA%\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\`. Delete matching `.lnk` files + strip the corresponding entry from `FavoritesResolve` blob.
- Tray promote / demote: set `HKCU:\Control Panel\NotifyIconSettings\<hash>\IsPromoted` to `1` or `0`.
- Restart explorer — batched via SKILL.md cross-module contract #2.

### 6. Report

- Count of pins removed, tray icons promoted, tray icons demoted.
- Snapshot + revert paths.
- Note: explorer will be restarted once at the end of the run.

## Known gotchas

- The `FavoritesResolve` binary blob is undocumented and structure varies by Win11 build. Reading it correctly to extract pin identity requires parsing an IShellLink serialization. In practice, easier and more reliable to:
  1. Read `.lnk` files in `%APPDATA%\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\` for pinned apps.
  2. Delete the `.lnk`.
  3. Reset the entire `FavoritesResolve` value (or set to `EncryptedFavoritesEnabled=0` first — Win11 encrypts on some builds).
  4. Restart explorer to have the taskbar rebuild from `.lnk` files.
- Restart explorer required for both pin AND tray changes. Deferred to end of session so a single restart covers everything.
- `IsPromoted` = 1 means the icon IS shown in the tray (not in overflow). Some documentation flips this — verify by manipulating a known-visible icon and re-reading.
- Some tray icons are drawn by shared host processes (`explorer.exe`, `ctfmon.exe`, `runtimebroker.exe`) — they won't have a distinct `ExecutablePath` and can't be individually promoted/demoted. Filter these out of the ASK question.
- UWP apps' pinned entries have `shell:AppsFolder\<PackageFamily>!<AppId>` identity, not a file path. The unpin approach for UWP is different — remove the `.lnk` in the same TaskBar folder that points at the AppsFolder verb.
- After Windows feature update (23H2 → 24H2), the pinned taskbar may be reset to Windows default. Note in the report so the user knows to re-run.
- Restarting explorer with pinned Office apps open sometimes causes Office's own tray icon to get orphaned until re-open. Cosmetic only.
- Chat/Teams button = `TaskbarMn` (0 = hidden, 1 = shown). Copilot = `ShowCopilotButton`. Task View = `ShowTaskViewButton`. Search = `SearchboxTaskbarMode`. Widgets = `TaskbarDa`. Handled in `explorer` module.
- Do NOT try to reorder pins programmatically — the FavoritesResolve blob is order-sensitive and easy to corrupt. Just add/remove.
- Some third-party dock/taskbar replacements (StartAllBack, ExplorerPatcher) intercept these registry keys and store their own settings elsewhere. If detected, skip and note.

## Curated defaults / Data files

- `data/known_tray_apps.json` — map process name → `{humanName, role, isTripwire}`. Roles: `password_manager` (promote-worthy), `chat`, `notification_hub`, `sync_status` (tuck away by default), `oem_helper` (tuck), `security_agent` (tripwire), `system_control` (tripwire — Volume / Battery / Network / Defender / Update). Used to auto-suggest visibility.
- `data/taskbar_default_pins.json` — Windows 11 default pin list per build. Used to detect if the user has customized their taskbar or is running defaults.

## Machine profile branches

- Third-party taskbar tool detected (StartAllBack, ExplorerPatcher, Start11, Nilesoft): skip this module entirely and print "third-party taskbar tool detected — configure it directly, our tweaks would conflict."
- `profile.flags.isLaptop=true` with touch screen: leave Search box as `2` (full box) — touch users want the target size. Same rule as `explorer` module.
- Windows 10 (unlikely given README says Win11 focus): the tray registry paths differ. Refuse and print "Windows 10 tray customization not implemented."
