# module: explorer

Tier: CORE. Auto-runs. Non-destructive UI tweaks. Asks ≤1 grouped question for the user-taste items.

## Success criteria

At the end of this module the user has:
1. `.reg` export of every touched key BEFORE any change.
2. Windows 11 right-click classic (non-truncated) context menu restored, if user opts in.
3. Widgets removed from taskbar.
4. Search box on taskbar reduced to icon-only.
5. Taskbar alignment set to Left (if user opts in — respects current if they've moved it).
6. File extensions visible, hidden system files respected (asked, not defaulted).
7. Dark mode respected: never overridden from user's current setting.
8. A `revert.ps1`.

## Flow

### 1. Diagnose

Run `ps/diagnose/explorer.ps1`. Reads current values of the keys in `data/explorer_keys.json` and reports:
- Current classic-menu status (`HKCU:\SOFTWARE\CLASSES\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32` present and empty = classic).
- Widgets state (`HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\NewsAndInterests\AllowNewsAndInterests` and `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDa`).
- Search box state (`HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search\SearchboxTaskbarMode`).
- Taskbar alignment (`HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarAl`).
- Dark mode current (`HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize\AppsUseLightTheme` + `SystemUsesLightTheme`).
- File extension visibility (`HKCU:\...\Advanced\HideFileExt`).
- Hidden files visibility (`HKCU:\...\Advanced\Hidden`).
- Show all tray icons (`HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\EnableAutoTray`).

### 2. Categorize

- **AUTO-APPLY** — Widgets off, Search box → icon-only, file extensions visible. These are broadly safe and reversible.
- **ASK-TASTE** — classic context menu, taskbar alignment, hidden files visible.
- **NEVER-TOUCH** — dark mode (respect current), accent color, wallpaper.

### 3. Ask the user

**Plain-English rule: describe what the change LOOKS like, not the registry name.** Keep raw values (`TaskbarAl=0`, the classic-menu CLSID) INTERNAL.

Single grouped `AskUserQuestion`, `multiSelect: true`:

**Q1 — "Which of these tweaks do you want?" (check all that apply)**
- Bring back the old right-click menu (the one that shows all options at once, instead of the short list with "Show more options" at the bottom)
- Line up the Start button and taskbar icons on the left side (like Windows 10), instead of the middle
- Show hidden files and folders in File Explorer (warning: this also shows the confusing AppData folder — leave off if unsure)
- Show empty drives / card readers / SD slots even when nothing is plugged in

Only apply what the user checks.

### 4. Build plan JSON

```json
{
  "apply": [
    {"path":"HKCU:\\...\\Advanced","name":"HideFileExt","type":"DWord","value":0,"reason":"Show file extensions"}
  ],
  "classicMenu": true,
  "restartExplorer": true
}
```

### 5. Apply (no elevation needed for HKCU changes)

Call `ps/apply/explorer.ps1 -Plan <path> -SnapshotDir <path>`. It:
- Exports each touched parent key as a `.reg` first.
- Applies each value.
- For classic menu: creates `HKCU:\SOFTWARE\CLASSES\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32` with an empty default value.
- If `restartExplorer` and any of the changes need it: `Stop-Process -Name explorer -Force; Start-Process explorer` (this WILL close all Explorer windows — warn user first).

### 6. Report

- List of tweaks applied.
- Snapshot + revert paths.
- Note: some settings (widgets, taskbar alignment) only take effect after explorer restart or sign-out. Say so.

## Known gotchas

- The classic menu registry override (`{86ca1aa0-...}` with empty InprocServer32) is well-known but breaks some third-party context menu extensions that were written assuming the Win11 filtered menu. If user has Nilesoft Shell or 7-Taskbar Tweaker installed, do NOT apply this override — check first. `data/explorer_conflicts.json` lists known-conflicting apps.
- Windows Search taskbar mode values: `0` = hidden, `1` = icon only, `2` = search box, `3` = icon + label. On 22H2 the default is `2`; on some 23H2 builds it's silently reset to `3` after feature update — the value survives but doesn't take effect until explorer restart.
- `TaskbarAl` (0=Left, 1=Center) is per-user. Setting HKLM equivalents has no effect on Win11 22H2+.
- Widgets removal via `TaskbarDa=0` disables the icon but the background process (`msedgewebview2.exe` under Widgets service) may still run. Full removal needs the "Widgets" Windows feature disabled: `Get-WindowsCapability -Online | Where Name -like '*Widgets*'` — not always present as a capability. Just disabling the taskbar icon is the pragmatic default here.
- Show hidden files also shows the huge and confusing `AppData` — some users hate this. Never default to on; always ask.
- Restarting explorer while the user has an open Save-As dialog can crash the calling app. Consider asking user to close open dialogs first, or use `taskkill /F /IM explorer.exe && start explorer.exe` in a delayed dispatch.
- On Windows 11 24H2 the "recommended files" section in File Explorer Home is controlled by a new key `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShowRecommendations` — the old `ShowFrequent`/`ShowRecent` still work but don't cover it. Add both.
- Do not touch `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\LaunchTo` (Home vs This PC) unless user asks — it's a matter of taste and reversal is annoying.

## Curated defaults / Data files

- `data/explorer_keys.json` — array of `{path, name, type, desiredValue, category ("AUTO-APPLY"|"ASK-TASTE"|"NEVER"), question, reason, affectsRestart: bool}`.
- `data/explorer_conflicts.json` — array of `{appMatch, override}`. If any of these apps are installed (checked via `Get-Package` / `Get-AppxPackage` / `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`), skip the listed overrides.

## Machine profile branches

- Multi-monitor detected (`(Get-CimInstance Win32_VideoController).Count > 1` with active outputs): if the user has "Multiple displays" set to "Show taskbar on all displays", do NOT centralize taskbar alignment (user is already customizing).
- Touch-enabled device (`Get-PnpDevice -Class HIDClass | Where FriendlyName -match 'touch screen'`): keep the search BOX (not icon-only) — touch users benefit from a larger target. Skip the SearchboxTaskbarMode=1 change and note why in the log.
- Tablet mode / convertible chassis (`Win32_SystemEnclosure.ChassisTypes` = 30 or 31): skip taskbar alignment change (users often prefer Center on tablet-style form factor).
- Windows Home vs Pro: no branch.
