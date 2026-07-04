# module: storage

Tier: CORE. Auto-runs. Safe temp cleanup + DISM component cleanup + Storage Sense config. Asks ≤2 grouped questions.

## Success criteria

At the end of this module the user has:
1. Bytes-freed report per source.
2. `%TEMP%` and `%LOCALAPPDATA%\Temp` emptied of files older than 24 hours (skip open handles).
3. Delivery Optimization cache cleared.
4. WinSxS component store cleaned via DISM.
5. `Windows.old` removed if present AND older than 10 days AND user confirms.
6. Storage Sense enabled with sensible defaults if user opts in.
7. A `revert.ps1` — this module's revert is narrow (Storage Sense settings only; temp files gone are gone).

## Flow

### 1. Diagnose

Run `ps/diagnose/storage.ps1`. It computes sizes (not deletes) for each candidate:

| Source | Path / Command |
|---|---|
| User TEMP | `$env:TEMP` |
| Local TEMP | `%LOCALAPPDATA%\Temp` |
| System TEMP | `C:\Windows\Temp` |
| Windows Update cache | `C:\Windows\SoftwareDistribution\Download` |
| Delivery Optimization cache | `C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache` |
| Prefetch | `C:\Windows\Prefetch` |
| Windows.old | `C:\Windows.old` |
| WinSxS analysis | `dism /online /cleanup-image /analyzecomponentstore` |
| Recycle bin | `Clear-RecycleBin` — but only size, not the emptying, in diagnose |
| CBS logs | `C:\Windows\Logs\CBS` |
| Panther logs | `C:\Windows\Panther` |
| WER queue | `C:\ProgramData\Microsoft\Windows\WER\ReportQueue`, `ReportArchive` |
| Browser caches | Chrome / Edge / Brave `%LOCALAPPDATA%\<vendor>\User Data\<profile>\Cache` |

Emit total per source + top 20 largest single files.

### 2. Categorize

- **AUTO** — files in TEMP dirs older than 24 h, Delivery Optimization cache, WER queue, CBS logs older than 30 d.
- **ASK** — Windows.old (destructive after 10 d default grace), Recycle Bin (contains user files), browser caches (kills sign-ins in some cases), Prefetch (very rarely worth cleaning; can slow next boot).
- **NEVER** — `pagefile.sys`, `hiberfil.sys`, `swapfile.sys` (power module handles hibernate), `System Volume Information`, `Recovery`.

### 3. Ask the user

**Plain-English rule: show the user what gets freed and what the trade-off is, not the internal source name.** Substitute actual GB numbers into the copy at ask time.

Grouped `AskUserQuestion`, `multiSelect: true`, ≤2 questions:

**Q1 — "Which of these do you want cleaned up?" (check all that apply — sizes are what we'd free)**
- Leftover files from your previous Windows install (~X GB) — after this you can't roll back to the old Windows version, but you also won't be able to anyway after 10 days
- Recycle Bin (~X GB) — empties everything you've thrown away
- Web browser caches for Chrome / Edge / Brave (~X GB) — some sites will feel a bit slower the first time you visit them again while they re-cache
- Windows' app-launch history file (~X GB) — makes Windows very slightly slower to launch programs for a few boots; usually not worth doing

**Q2 — "Do you want Windows to auto-clean itself when your disk gets full?" (check all that apply)**
- Yes, turn on Windows' auto-cleanup (it kicks in when your disk starts getting full)
- Auto-empty the Recycle Bin for anything older than 30 days
- Auto-delete files in Downloads that you haven't touched in 60 days (leave off if you park installers there)
- For files stored in OneDrive: keep them in the cloud only if you haven't opened them in 30 days (they still show in File Explorer; downloaded on demand when you double-click)

### 4. Build plan JSON

```json
{
  "cleanTempOlderThanHours": 24,
  "cleanDeliveryOptimization": true,
  "cleanWERQueue": true,
  "cleanCBSLogsOlderThanDays": 30,
  "removeWindowsOld": false,
  "emptyRecycleBin": false,
  "cleanBrowserCache": [],
  "dismStartComponentCleanup": true,
  "dismResetBase": false,
  "storageSense": { "enable": true, "recycleBinDays": 30, "downloadsDays": 0, "cloudSyncDays": 30 }
}
```

`dismResetBase` — only if disk pressure is real (free space <15%). It's irreversible for future WinSxS rollback.

### 5. Apply (elevated)

Call `ps/apply/storage.ps1 -Plan <path> -SnapshotDir <path>`. It:
- Deletes temp files older than N hours (`Get-ChildItem -Force | Where LastWriteTime -lt (Get-Date).AddHours(-N) | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue`). Locked files silently skipped.
- Delivery Optimization: stop DoSvc, remove cache dir, start DoSvc.
- WER queue: `Remove-Item` cache dirs.
- DISM: `dism /online /cleanup-image /startcomponentcleanup` + optionally `/resetbase`. Takes 5-20 minutes; stream output to `apply.log`.
- Windows.old: `takeown /f C:\Windows.old /r /d y` then `icacls C:\Windows.old /grant Administrators:F /t` then `Remove-Item -Recurse -Force C:\Windows.old`.
- Storage Sense: keys under `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy`.

### 6. Report

Table of source → bytes freed. Total. Path to snapshot + revert.

## Known gotchas

- Files under `%TEMP%` may be open by long-running apps (browsers, IDEs). Use `Remove-Item -ErrorAction SilentlyContinue` and count skipped vs deleted.
- Delivery Optimization cache: if you `Remove-Item` the folder while DoSvc is running, DoSvc recreates and refills it. Stop `DoSvc` first, remove, start.
- DISM `/resetbase` makes existing Windows Update rollbacks impossible for THIS accumulated servicing — after it runs, you cannot uninstall the currently-installed cumulative update. Only run when free-space pressure is real. Ask user explicitly.
- `Windows.old` deletion via Explorer/CleanMgr often fails on `WindowsApps` subfolder due to TrustedInstaller-owned ACLs. The `takeown /r + icacls` combo is what works. Requires elevation.
- `C:\Windows\SoftwareDistribution\Download` — safe to clean, but you must stop `wuauserv` first or Windows Update will re-lock files instantly. Restart wuauserv after.
- Prefetch (`.pf` files) is used by `unused-apps` module to estimate last-launched time. Cleaning Prefetch WIPES that data. If `unused-apps` will run in this session, run it FIRST and skip Prefetch cleanup, or note the loss in the report.
- Recycle Bin per-volume ($Recycle.Bin) is USER-specific. `Clear-RecycleBin -Force` from an admin PS session clears the CURRENT user's bin, not all users. If you want all users you need to enumerate `C:\$Recycle.Bin\<SID>` and delete per-SID.
- Storage Sense keys are per-user — running elevated does NOT set them for the user profile. Set them under the invoking user's HKCU (`HKCU:` is fine in a non-elevated context; if the apply script IS elevated, load the user hive explicitly or write via `reg.exe` targeting `HKCU\...` of the logged-on user).
- `hiberfil.sys` — do NOT touch here. If user wants it gone, that's `power` module's `powercfg /h off`.
- Browser cache cleaning while browser is running is a no-op (locked files). Ask user to close browser or skip.
- Fast Startup uses `hiberfil.sys` — cleaning it in `power` will free 4-16 GB. Cross-note that here so we don't double-count.

## Curated defaults / Data files

- `data/storage_sources.json` — array of `{name, path, expandEnv: bool, category, requiresElevation, requiresServiceStopped, minAgeHours, notes}`. Extend to add new cache paths (Discord cache, Slack cache, Spotify cache, etc.).

## Machine profile branches

- Free disk space (from `profile.disk[]` or fresh `Get-Volume C:`): if <15%, upgrade `dismResetBase` from opt-in to STRONGLY-SUGGESTED (still ask). If <5%, add Downloads-cleanup and old browser profiles to the ASK list even though they normally aren't.
- SSD vs HDD (`profile.disk[].MediaType`): on HDD, skip Prefetch cleanup unconditionally (Prefetch matters MORE on HDD). On SSD, defrag is never suggested; TRIM is Windows-managed.
- Small NVMe (256 GB or less): keep Storage Sense-suggested cleanup thresholds aggressive (Recycle 14 d, Downloads 30 d default when user opts in). Large SSD (1 TB+): 30 d / 60 d.
- `profile.flags.isLaptop=true` AND battery: DISM `/startcomponentcleanup` is CPU-heavy; if AC not plugged, warn user before starting. `Win32_Battery.BatteryStatus` = 2 means AC.
