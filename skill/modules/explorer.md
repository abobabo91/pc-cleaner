# module: explorer

Tier: CORE. Auto-runs. Non-destructive UI tweaks. Asks one question per tweak, conversationally.

## Success criteria

At the end of this module the user has:
1. `.reg` export of every touched key BEFORE any change.
2. Widgets removed from taskbar (AUTO).
3. Search box on taskbar reduced to icon-only (AUTO).
4. File extensions visible (AUTO).
5. Chat / Copilot buttons on taskbar hidden per user answer.
6. Classic right-click menu restored per user answer.
7. Taskbar alignment set to Left per user answer.
8. Dark mode set per user answer (never overridden silently).
9. Hidden files visibility set per user answer.
10. A `revert.ps1`.

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
- Chat / Copilot button state (`TaskbarMn`, `ShowCopilotButton`).

### 2. Categorize

- **AUTO-APPLY** — Widgets off, Search box → icon-only, file extensions visible. Broadly safe and reversible.
- **ASK-USER (per-tweak conversational)** — classic context menu, taskbar alignment, hide Widgets (asked as a nudge in case they use it), hide Chat/Copilot button, show file extensions (also asked so the user is aware), dark mode, hidden files visible.
- **NEVER-TOUCH** — accent color, wallpaper.

### 3. Ask the user, one at a time

**Plain-English rule: describe what the change LOOKS like, not the registry name.** Keep raw values (`TaskbarAl=0`, the classic-menu CLSID) INTERNAL.

Use `AskUserQuestion` with `multiSelect: false` — one call per tweak. Skip conditions are honored.

---

**Q1 — Classic right-click menu**

> "In Windows 11 the right-click menu is a short list with 'Show more options' at the bottom. Do you want the old, full menu back so you see everything at once?"

*Skip if:* a conflicting shell customizer is installed (Nilesoft Shell, 7-Taskbar Tweaker, StartAllBack, ExplorerPatcher — see `data/explorer_conflicts.json`).

*"I'm not sure" inference:* → YES. (The Win11 filtered menu is nearly universally disliked; the classic menu is a one-key-close revert.)

*Controls:* `HKCU:\SOFTWARE\CLASSES\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32` (empty default value).

---

**Q2 — Widgets on the taskbar**

> "Hide the Widgets icon on the taskbar? (The weather / news panel that pops out from the left corner.)"

*Skip if:* Widgets already hidden (`TaskbarDa=0`).

*"I'm not sure" inference:* → YES (Widgets runs a background WebView2 process most users never open).

*Controls:* `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDa = 0`.

---

**Q3 — Chat / Teams button**

> "Hide the Chat icon on the taskbar? (The purple speech-bubble icon that opens Microsoft's personal Teams.)"

*Skip if:* icon already hidden (`TaskbarMn=0`), OR the Microsoft Teams Personal package is not installed.

*"I'm not sure" inference:* → YES.

*Controls:* `HKCU:\...\Advanced\TaskbarMn = 0`.

---

**Q4 — Copilot button**

> "Hide the Copilot icon on the taskbar? (The AI chat assistant next to Search.)"

*Skip if:* icon already hidden (`ShowCopilotButton=0`).

*"I'm not sure" inference:* → YES (Copilot is also being disabled in the privacy module by default).

*Controls:* `HKCU:\...\Advanced\ShowCopilotButton = 0`.

---

**Q5 — Taskbar alignment (Left vs Center)**

> "Line up the Start button and taskbar icons on the left side (like Windows 10), or leave them centered like Windows 11 does by default?"

Answers: `Left` / `Center` / `I'm not sure`.

*Skip if:* touch-enabled tablet-form chassis (`Win32_SystemEnclosure.ChassisTypes` = 30 or 31) — Center is friendlier for touch.

*"I'm not sure" inference:* → LEFT if the user is on a laptop / desktop with mouse + keyboard as primary input; → CENTER if touch is primary.

*Controls:* `HKCU:\...\Advanced\TaskbarAl` — `0` = Left, `1` = Center.

---

**Q6 — File extensions**

> "Show file extensions in File Explorer? (So you see .jpg / .exe / .docx at the end of filenames. Helps you spot fake .exe files pretending to be PDFs.)"

*Skip if:* already visible (`HideFileExt=0`).

*"I'm not sure" inference:* → YES (small usability + security win; almost no downside).

*Controls:* `HKCU:\...\Advanced\HideFileExt = 0`.

---

**Q7 — Dark mode**

> "Do you want dark mode for Windows and apps? (Windows itself, plus most apps that support it.)"

Answers: `Yes — dark mode` / `No — light mode` / `I'm not sure`.

*Skip if:* the user has clearly picked a theme (has changed from Windows default within the last 30 d — check the value's mtime via `Get-ItemProperty` last-modified metadata is not reliable, so instead: don't skip, always ask).

*"I'm not sure" inference:* → keep current setting untouched (this is a taste decision; not-sure means don't change).

*Controls:* `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize\AppsUseLightTheme` and `SystemUsesLightTheme` (both 0 = dark, both 1 = light).

---

**Q8 — Hidden files**

> "Show hidden files and folders in File Explorer? (Warning: this also shows the huge, confusing AppData folder in your user folder. Say no if you're not sure.)"

*Skip if:* already visible (`Hidden=1`).

*"I'm not sure" inference:* → NO (the AppData mess trips up non-technical users; leave off).

*Controls:* `HKCU:\...\Advanced\Hidden = 1`.

---

### After all questions, show the decision summary

```
File Explorer / taskbar tweaks — here's what I figured out:

  Widgets:                HIDE   (auto)
  Search box:             ICON   (auto)
  File extensions:        SHOW   (auto)
  Classic right-click:    YES    (you said yes)
  Chat icon:              HIDE   (auto)
  Copilot icon:           HIDE   (auto)
  Taskbar alignment:      LEFT   (auto: mouse + keyboard primary)
  Dark mode:              LEAVE ALONE (auto: not sure = don't change)
  Hidden files:           OFF    (auto: safer default)

I'll change 9 settings.
Continue?  [Yes / No / Show me the list]
```

Anything the user challenges here → flip the decision, adjust the plan, ask them to confirm again.

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
- If `restartExplorer` and any of the changes need it: `Stop-Process -Name explorer -Force; Start-Process explorer` (this WILL close all Explorer windows — warn user first). Actually deferred to end of full run — see SKILL.md cross-module contract #2.

### 6. Report

- List of tweaks applied.
- Snapshot + revert paths.
- Note: some settings (widgets, taskbar alignment) only take effect after explorer restart or sign-out. Say so.

## Known gotchas

- The classic menu registry override (`{86ca1aa0-...}` with empty InprocServer32) is well-known but breaks some third-party context menu extensions that were written assuming the Win11 filtered menu. If user has Nilesoft Shell or 7-Taskbar Tweaker installed, do NOT apply this override — check first. `data/explorer_conflicts.json` lists known-conflicting apps.
- Windows Search taskbar mode values: `0` = hidden, `1` = icon only, `2` = search box, `3` = icon + label. On 22H2 the default is `2`; on some 23H2 builds it's silently reset to `3` after feature update — the value survives but doesn't take effect until explorer restart.
- `TaskbarAl` (0=Left, 1=Center) is per-user. Setting HKLM equivalents has no effect on Win11 22H2+.
- Widgets removal via `TaskbarDa=0` disables the icon but the background process (`msedgewebview2.exe` under Widgets service) may still run. Full removal needs the "Widgets" Windows feature disabled: `Get-WindowsCapability -Online | Where Name -like '*Widgets*'` — not always present as a capability. Just disabling the taskbar icon is the pragmatic default here.
- Show hidden files also shows the huge and confusing `AppData` — some users hate this. Never default to on.
- Restarting explorer while the user has an open Save-As dialog can crash the calling app. Consider asking user to close open dialogs first, or use `taskkill /F /IM explorer.exe && start explorer.exe` in a delayed dispatch.
- On Windows 11 24H2 the "recommended files" section in File Explorer Home is controlled by a new key `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShowRecommendations` — the old `ShowFrequent`/`ShowRecent` still work but don't cover it. Add both.

## Curated defaults / Data files

- `data/explorer_keys.json` — array of `{path, name, type, desiredValue, category ("AUTO-APPLY"|"ASK-USER"|"NEVER"), question, reason, affectsRestart: bool}`.
- `data/explorer_conflicts.json` — array of `{appMatch, override}`. If any of these apps are installed (checked via `Get-Package` / `Get-AppxPackage` / `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`), skip the listed overrides.

## Machine profile branches

- Multi-monitor detected (`(Get-CimInstance Win32_VideoController).Count > 1` with active outputs): if the user has "Multiple displays" set to "Show taskbar on all displays", do NOT centralize taskbar alignment (user is already customizing).
- Touch-enabled device (`Get-PnpDevice -Class HIDClass | Where FriendlyName -match 'touch screen'`): keep the search BOX (not icon-only) — touch users benefit from a larger target. Skip Search box AUTO and note why in the log.
- Tablet mode / convertible chassis (`Win32_SystemEnclosure.ChassisTypes` = 30 or 31): skip Q5 taskbar alignment (Center is friendlier for touch).
- Windows Home vs Pro: no branch.
