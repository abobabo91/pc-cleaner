# module: tray-taskbar

Tier: OPTIONAL. Opt-in via `--include tray-taskbar`. Non-destructive: unpin from taskbar / hide from tray. Never uninstalls the underlying app.

## Success criteria

At the end of this module the user has:
1. Snapshot of current pinned taskbar apps + tray icon overflow state BEFORE change.
2. User-picked pinned taskbar apps unpinned.
3. User-picked tray icons hidden (moved to overflow) or shown (moved out of overflow).
4. A `revert.ps1` that restores pin order and tray promotion state.

## Flow

### 1. Diagnose

Run `ps/diagnose/tray-taskbar.ps1`. Emits:
- `.pinned[]` — pinned taskbar apps, in order. Two sources:
  - Win11 22H2+: `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Taskband\FavoritesResolve` (binary blob) — parse to extract app paths, or read taskbar-pinned `.lnk` files from `%APPDATA%\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\`.
  - Cross-reference against `Get-AppxPackage` for UWP pins.
- `.tray[]` — tray icons and their visibility state:
  - Win10/11 tray state is stored in `HKCU:\Control Panel\NotifyIconSettings\<hash>` — each subkey has `ExecutablePath`, `IsPromoted` (1 = shown, 0 = hidden in overflow), `LastActivationHint`. Enumerate all subkeys.
  - Cross-reference against actively running tray-icon-having processes: `Get-Process | Where MainWindowTitle -eq '' -and Path` filtered by our known tray-emitter list from `data/known_tray_apps.json`.
- `.taskbarAppearance` — Widgets on/off, Search state, Chat icon, Copilot icon, Task View. All from `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced` (`TaskbarDa`, `SearchboxTaskbarMode`, `TaskbarMn`, `ShowCopilotButton`, `ShowTaskViewButton`).

### 2. Categorize

- **PIN candidates for unpin**: user judgment only. No auto.
- **TRAY-VISIBLE promotions**: user judgment. Some users want their VPN + password manager + Discord always visible.
- **TASKBAR-BUTTONS**: Widgets, Chat/Teams button, Copilot button, Task View button — these are covered by `explorer` module partially. If `explorer` already handled them in the same session, skip; don't ask twice.

### 3. Ask the user

`AskUserQuestion`, `multiSelect: true`, ≤3 questions:

- **Unpin from taskbar** — checkbox per currently-pinned app: "Microsoft Edge", "Store", "Mail", "Copilot", "Xbox", ... plus any third-party pins found.
- **Tray icons — promote to always visible** (show, not hide) — checkbox per known tray app currently in overflow: password manager, VPN, Discord, Slack, notification apps.
- **Tray icons — demote to overflow** — checkbox per currently-shown tray icon the user wants hidden: OneDrive, Backup agent, printer spooler, Realtek Audio, etc.

Skip any Windows-built-in taskbar buttons (Widgets, Chat, Copilot, Task View, Search) if the `explorer` module already handled them.

### 4. Build plan JSON

```json
{
  "unpin": ["shell:AppsFolder\\Microsoft.WindowsStore_8wekyb3d8bbwe!App", "C:\\Program Files\\Microsoft Office\\root\\Office16\\OUTLOOK.EXE"],
  "trayPromote": [{"hash":"abc123","reason":"1Password — keep visible"}],
  "trayDemote":  [{"hash":"def456","reason":"OneDrive — hide in overflow"}]
}
```

### 5. Apply (no elevation for HKCU changes)

Call `ps/apply/tray-taskbar.ps1 -Plan <path> -SnapshotDir <path>`. It:
- Snapshots `HKCU:\...\Taskband` and `HKCU:\Control Panel\NotifyIconSettings` fully as `.reg` files.
- Unpin: preferred approach is programmatic via Shell verb `unpinfromtaskbar`. On Win11 22H2+ Microsoft removed the `unpinfromtaskbar` verb from most Explorer shell verbs, but it still works for `.lnk` files under `%APPDATA%\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\`. Delete matching `.lnk` files + strip the corresponding entry from `FavoritesResolve` blob. Then restart explorer.
- Tray promote / demote: set `HKCU:\Control Panel\NotifyIconSettings\<hash>\IsPromoted` to `1` or `0`. Explorer must restart to pick up changes.
- Restart explorer (warn user first).

### 6. Report

- Count of pins removed, tray icons promoted, tray icons demoted.
- Snapshot + revert paths.
- Note: explorer will be restarted; save open Save-As dialogs.

## Known gotchas

- The `FavoritesResolve` binary blob is undocumented and structure varies by Win11 build. Reading it correctly to extract pin identity requires parsing an IShellLink serialization. In practice, easier and more reliable to:
  1. Read `.lnk` files in `%APPDATA%\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\` for pinned apps.
  2. Delete the `.lnk`.
  3. Reset the entire `FavoritesResolve` value (or set to `EncryptedFavoritesEnabled=0` first — Win11 encrypts on some builds).
  4. Restart explorer to have the taskbar rebuild from `.lnk` files.
- Restart explorer required for both pin AND tray changes. Warn user, or defer to end of session so a single restart covers everything.
- `IsPromoted` = 1 means the icon IS shown in the tray (not in overflow). Some documentation flips this — verify by manipulating a known-visible icon and re-reading.
- Some tray icons are drawn by shared host processes (`explorer.exe`, `ctfmon.exe`, `runtimebroker.exe`) — they won't have a distinct `ExecutablePath` and can't be individually promoted/demoted. Filter these out of the ASK question.
- UWP apps' pinned entries have `shell:AppsFolder\<PackageFamily>!<AppId>` identity, not a file path. The unpin approach for UWP is different — remove the `.lnk` in the same TaskBar folder that points at the AppsFolder verb.
- After Windows feature update (23H2 → 24H2), the pinned taskbar may be reset to Windows default. Note in the report so the user knows to re-run.
- Restarting explorer with pinned Office apps open sometimes causes Office's own tray icon to get orphaned until re-open. Cosmetic only.
- Chat/Teams button = `TaskbarMn` (0 = hidden, 1 = shown). Copilot = `ShowCopilotButton`. Task View = `ShowTaskViewButton`. Search = `SearchboxTaskbarMode`. Widgets = `TaskbarDa`.
- Do NOT try to reorder pins programmatically — the FavoritesResolve blob is order-sensitive and easy to corrupt. Just add/remove.
- Some third-party dock/taskbar replacements (StartAllBack, ExplorerPatcher) intercept these registry keys and store their own settings elsewhere. If detected, skip and note.

## Curated defaults / Data files

- `data/known_tray_apps.json` — map process name → human-readable name + role (e.g. `1Password.exe` → "1Password", role=`password_manager`; `slack.exe` → "Slack", role=`chat`). Used to auto-suggest promote-to-visible for common utility apps and hide-in-overflow for common cruft (`OneDrive.exe`, `Realtek*.exe`, `iTunesHelper.exe`).
- `data/taskbar_default_pins.json` — Windows 11 default pin list per build. Used to detect if the user has customized their taskbar or is running defaults.

## Machine profile branches

- Third-party taskbar tool detected (StartAllBack, ExplorerPatcher, Start11, Nilesoft): skip this module entirely and print "third-party taskbar tool detected — configure it directly, our tweaks would conflict."
- `profile.flags.isLaptop=true` with touch screen: leave Search box as `2` (full box) if it's currently a box — touch users want the target size. Same rule as `explorer` module.
- Windows 10 (unlikely given README says Win11 focus, but if detected): the tray registry paths differ (`HKCU:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\TrayNotify` — `IconStreams` and `PastIconsStream` binary blobs). Refuse and print "Windows 10 tray customization not implemented."
