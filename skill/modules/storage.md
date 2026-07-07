# module: storage

Tier: CORE. Auto-runs. Safe temp cleanup + DISM component cleanup + Storage Sense config. One summary question up front, then individual conversational questions per destructive item.

## Success criteria

At the end of this module the user has:
1. Bytes-freed report per source.
2. `%TEMP%` and `%LOCALAPPDATA%\Temp` emptied of files older than 24 hours (skip open handles).
3. Delivery Optimization cache cleared.
4. WinSxS component store cleaned via DISM.
5. `Windows.old` removed if present AND older than 10 days AND user confirmed.
6. Recycle Bin emptied if user confirmed.
7. Storage Sense enabled if user opted in.
8. A `revert.ps1` — this module's revert is narrow (Storage Sense settings only; temp files gone are gone).

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

Emit total per source + top 20 largest single files. Also report `estimatedTotalGB` — the sum of everything the module would clean up under the AUTO umbrella plus the AUTO-eligible ASK items at their inferred defaults.

### 2. Categorize

- **AUTO** — files in TEMP dirs older than 24 h, Delivery Optimization cache, WER queue, CBS logs older than 30 d, browser caches (only if the browser is closed). These are the "temporary files, browser cache, old crash reports" bucket in the summary question.
- **ASK-USER** — Recycle Bin, Windows.old, DISM component cleanup (mention runtime), Storage Sense.
- **NEVER** — `pagefile.sys`, `hiberfil.sys`, `swapfile.sys` (power module handles hibernate), `System Volume Information`, `Recovery`.

### 3. Ask the user, one at a time

**Plain-English rule: show the user what gets freed and what the trade-off is, not the internal source name.** Substitute actual GB numbers into the copy at ask time. Use `AskUserQuestion` with `multiSelect: false` — one call per question.

---

**Q1 — Summary opt-in**

> "Delete about X GB of temporary files, browser cache, and old crash reports? (Doesn't touch your documents, photos, or downloads.)"

Where X is `estimatedTotalGB` from diagnose — the AUTO bucket only. This is the entry-gate question.

Answers:
- `Yes` — apply all AUTO cleanup, then move on to Q2-Q5.
- `No` — skip the whole module.
- `Show me what changes` — print the source → size table and re-ask.

*"I'm not sure" inference:* not offered. Consent gate.

*Controls:* AUTO sources in `data/storage_sources.json`.

---

**Q2 — Recycle Bin**

> "Empty the Recycle Bin? (There's about X GB in there right now. Anything you've thrown away in the last week will be gone for good.)"

Where X is the Recycle Bin size from diagnose.

*Skip if:* recycle bin is < 100 MB (barely worth asking).

*"I'm not sure" inference:* If size > 5 GB → YES (space matters). If size 100 MB — 5 GB AND the newest file in bin is > 30 days old → YES. Otherwise → NO.

*Controls:* `Clear-RecycleBin -Force` per-user (see gotchas for per-SID for all users).

---

**Q3 — Windows.old**

> "Delete the leftover files from your previous Windows install? (About X GB. After this you can't roll back to the old Windows version — but you also can't after 10 days from install, so if it's here, that window has already closed.)"

Where X is `Windows.old` folder size.

*Skip if:* `C:\Windows.old` doesn't exist.

*"I'm not sure" inference:* Folder is older than 10 days (`(Get-Date) - (Get-Item C:\Windows.old).CreationTime > 10 days`) → YES. Otherwise → NO (respect the rollback window).

*Controls:* `takeown /f C:\Windows.old /r /d y` then `icacls C:\Windows.old /grant Administrators:F /t` then `Remove-Item -Recurse -Force C:\Windows.old`.

---

**Q4 — DISM component store cleanup**

> "Compact the Windows update history? (Takes 5-15 minutes, uses one CPU core the whole time. Frees roughly X GB. You won't be able to uninstall Windows updates from before now — but you'll never actually want to.)"

Where X is the recoverable size from `dism /online /cleanup-image /analyzecomponentstore`.

*Skip if:* recoverable size < 500 MB.

*"I'm not sure" inference:*
- Free space < 15% → YES.
- Free space 15-30% AND recoverable > 2 GB → YES.
- Free space > 30% AND recoverable < 2 GB → NO.
- On battery AND laptop → NO (defer to next AC-plugged run).

*Controls:* `dism /online /cleanup-image /startcomponentcleanup`. `dism /resetbase` is only added if user explicitly agrees to a second, stronger prompt (irreversible).

---

**Q5 — Storage Sense**

> "Turn on Windows' auto-cleanup? (Kicks in when your disk starts getting full — empties old files from your Recycle Bin, cleans temp files, and asks about your Downloads folder.)"

*Skip if:* already enabled (`HKCU:\...\StorageSense\Parameters\StoragePolicy\01`).

*"I'm not sure" inference:*
- Disk < 512 GB → YES (small disks need the housekeeping).
- Disk >= 512 GB AND free space > 40% → NO (no pressure).
- Otherwise → YES.

*Controls:* keys under `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy`. Default Storage Sense config: Recycle Bin 30 d, Downloads NEVER (never auto-clean Downloads), OneDrive cloud-only for files not touched in 30 d.

---

### After all questions, show the decision summary

> **DEPRECATED under the batched orchestrator (SKILL.md, 2026-07-07).** In full `/pc-cleaner` runs, this per-module summary is absorbed into the unified plan preview — do NOT emit it. Kept below as reference for the single-module invocation `/pc-cleaner storage` where a per-module summary still makes sense.

```
Storage cleanup — here's what I figured out:

  Temp files, browser cache, crash reports (AUTO bucket):  4.2 GB
  Recycle Bin:                        1.1 GB       YES  (you said yes)
  Windows.old:                        (not present — skipped)
  DISM cleanup:                       2.4 GB       YES  (auto: 22% free)
  Storage Sense:                      turn ON      YES  (auto: 512 GB disk)

Total to free: ~7.7 GB.
Continue?  [Yes / No / Show me the list]
```

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

`dismResetBase` — only if disk pressure is real (free space <15%) AND user explicitly consented to a second stronger prompt. It's irreversible for future WinSxS rollback.

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
- DISM `/resetbase` makes existing Windows Update rollbacks impossible for THIS accumulated servicing — after it runs, you cannot uninstall the currently-installed cumulative update. Only run when free-space pressure is real. Ask user explicitly (second confirm prompt) — one "yes" to component cleanup does NOT authorize resetbase.
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

- Free disk space (from `profile.disk[]` or fresh `Get-Volume C:`): if <15%, tip Q4 (DISM) inference toward YES; if <5%, add Downloads-cleanup and old browser profiles to the ASK list even though they normally aren't.
- SSD vs HDD (`profile.disk[].MediaType`): on HDD, skip Prefetch cleanup unconditionally (Prefetch matters MORE on HDD). On SSD, defrag is never suggested; TRIM is Windows-managed.
- Small NVMe (256 GB or less): keep Storage Sense-suggested cleanup thresholds aggressive (Recycle 14 d default when user opts in). Large SSD (1 TB+): 30 d default.
- `profile.flags.isLaptop=true` AND battery: DISM `/startcomponentcleanup` is CPU-heavy; the Q4 inference tips NO when on battery. `Win32_Battery.BatteryStatus` = 2 means AC.
