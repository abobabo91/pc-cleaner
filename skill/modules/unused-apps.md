# module: unused-apps

Tier: OPTIONAL. Opt-in via `--include unused-apps`. Detects installed apps not launched in 90+ days AND >100 MB, asks one question per candidate.

## Success criteria

At the end of this module the user has:
1. A table of installed apps ranked by (days since last launch × install size), filtered to apps >100 MB and last-launched >90 days ago (or never).
2. One conversational question per candidate — Yes / No / I'm not sure.
3. Confirmed apps uninstalled via winget / MsiExec / uninstaller registry command.
4. A `revert.ps1` — narrow: notes winget IDs so user can re-install; MSI/EXE uninstalls are one-way unless user has the installer.

## Flow

### 1. Diagnose

Run `ps/diagnose/unused-apps.ps1`. It:
- Enumerates installed apps: union of `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*` (+ Wow6432Node), `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*`, `Get-AppxPackage` for UWP. Emits `{name, publisher, version, installDate, uninstallString, installLocation, estimatedSize, source}`.
- Computes last-launched time for each app from three sources (best of):
  1. **Prefetch** — `C:\Windows\Prefetch\<EXENAME>-<HASH>.pf`. `LastWriteTime` on the `.pf` file = last launch of that .exe.
  2. **UserAssist** — `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\UserAssist\{CEBFF5CD-...}\Count` and `{F4E57C4B-...}\Count`. ROT13-encoded.
  3. **Access time on the main .exe** — Get-Item `installLocation\<mainExe>` .LastAccessTime. Only trustworthy if `fsutil behavior query DisableLastAccess` = 0 or 2.
- For each app: `lastLaunched = max of (source 1..3)`; `neverLaunched: bool`; `installSizeMB` from registry `EstimatedSize` or by scanning `installLocation`.
- Also emits `humanRelativeTime` for each — "8 months ago", "over a year", "never" — for the question copy.

### 2. Categorize

Include in candidate list if ALL:
- `installSizeMB > 100`
- `lastLaunched < today - 90 d` OR `neverLaunched = true`
- App is NOT in `data/unused_apps_never.json`.

Rank by `installSizeMB × log10(days_since_launch + 1)`.

### 3. Ask the user, one at a time

**Plain-English rule: show the app the way the user would recognize it — the name they saw in Add or Remove Programs, plus size and when they last opened it. No `UserAssist`, `Prefetch`, `.pf`, or `HKCU\...\Uninstall` references in the visible copy.** Keep those in the INTERNAL plan JSON.

Use `AskUserQuestion` with `multiSelect: false` — one call per candidate. Cap total questions at 15 per run to avoid fatigue; if there are more candidates, note in the report that there are more and the user can rerun.

---

**Q per candidate:**

> "You have [App Name] installed ([size]). I don't see any sign you've opened it in [humanRelativeTime]. Want to uninstall it?"

Show alongside: the publisher name in small text ("Made by Adobe"), the install location if it's on a non-C: drive (users often forget about apps on external drives).

Answers:
- `Yes — uninstall`
- `No — keep it`
- `I'm not sure`

*Skip if:* app is in `data/unused_apps_never.json` (Visual C++ redistributables, .NET runtimes, WebView2, security agents, backup agents, password managers, etc.).
*Skip if:* app was installed in the last 30 days (recent installs are almost never "unused").
*Skip if:* app has an active scheduled task or service (its .exe is being launched by the system, not the user — Prefetch says "used" but user hasn't interacted).

*"I'm not sure" inference:* → NO (keep it). This is the safer default — uninstalling a barely-known app is more likely to regret than to reward. If we're not sure, we leave it alone.

*Special case override:*
- If the app is a launcher game (installed under Steam / Epic / Ubisoft / EA) with size > 30 GB AND never-launched: the question copy adds "This is a game — you'd re-download it from [launcher] if you wanted it back." Inference stays NO.
- If the app is a trial or a bundleware antivirus (McAfee, Norton, WildTangent) AND `installDate < 90 d after Windows OOBE`: inference tips → YES (OEM bloat).

*Controls:* the uninstall command — winget ID preferred, uninstallString fallback. INTERNAL.

---

### After all questions, show the decision summary

```
Unused apps — here's what I figured out:

  Old Adobe App (2.1 GB, 8 months ago):        UNINSTALL  (you said yes)
  Some Random Game (45 GB, never):             UNINSTALL  (you said yes)
  McAfee LiveSafe trial (500 MB, 90 d):        UNINSTALL  (auto: OEM trial)
  Occasional Utility (200 MB, 6 months):       KEEP       (auto: not sure = keep)
  Big Sample Editor (4.5 GB, 11 months):       KEEP       (you said no)

I'll uninstall 3 apps and reclaim ~47.6 GB.
Continue?  [Yes / No / Show me the list]
```

### 4. Build plan JSON

```json
{
  "uninstall": [
    {"name":"Old Adobe App","source":"winget","wingetId":"Adobe.Something","reason":"Not launched in 8 months, 2.1 GB — user said yes"},
    {"name":"Game X","source":"registry","uninstallString":"\"C:\\...\\uninstall.exe\" /SILENT","reason":"Never launched, 45 GB"}
  ]
}
```

### 5. Apply (elevated)

Call `ps/apply/unused-apps.ps1 -Plan <path> -SnapshotDir <path>`. For each app:
- Prefer winget when a winget ID is known: `winget uninstall --id <id> --silent`.
- Else fall back to MSI: parse `uninstallString` for `MsiExec.exe /X{GUID}` and run with `/qn`.
- Else run the uninstall string with silent flags if we recognize them (`/S` for NSIS, `--mode unattended` for BitRock, `/qn` for MSI, `-silent` for InstallShield). If we don't recognize the flags, log the uninstall string to the report and skip auto-uninstall.
- After each uninstall: verify the app disappeared from the enumeration.
- `revert.ps1` records the winget IDs / publisher+name for anything removed.

### 6. Report

- Table: what was uninstalled, size reclaimed, time since last launch.
- Total bytes reclaimed.
- Anything skipped because we couldn't determine silent flags (user follow-up needed).
- If more than 15 candidates existed, note it and suggest rerun.

## Known gotchas

- Prefetch is disabled on SSDs by default on some Win11 builds since 24H2. Check `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters\EnablePrefetcher` — 0 means Prefetch disabled and this source of last-launched is dead. Fall back on UserAssist.
- Prefetch files hash by full path. If the user has moved an app (e.g. dragged Steam Library between drives), the old Prefetch file lingers with old LastWriteTime while the new location has none.
- UserAssist ROT13 encoding: each subkey name is ROT13(path). Values are binary blobs where offset 60 (0x3C) has `LastUsedTime` as FILETIME.
- UserAssist only tracks apps launched from Start / Run / Explorer. Apps launched purely from CLI never appear here.
- Disabled last-access time on NTFS: `fsutil behavior query DisableLastAccess` — 1 or 3 = disabled (Windows 10+ default).
- Apps with active scheduled tasks that run their exe periodically: LastWriteTime on Prefetch may show recent activity even if the user hasn't interacted. Cross-reference against Task Scheduler; exclude apps whose "launches" come from a scheduled task.
- Some apps register as multiple Uninstall entries (main app + updater + helper).
- Non-silent uninstallers pop UAC + confirmation dialogs. If run under a scheduled task, they hang forever. Detect silent-flag support; refuse to auto-run non-silent uninstalls.
- Steam / Epic / Ubisoft / EA games — each launcher has its own uninstall mechanism. Route through the launcher or refuse.
- Adobe apps require Adobe's own uninstaller — regular MSI uninstall leaves shared components broken.
- Portable apps (no installer, extracted to a folder) don't show up in Uninstall registry.
- 90-day threshold is a heuristic. Some apps (annual tax software) are legitimately used every 6-12 months. Ask, never auto.
- `EstimatedSize` in the Uninstall registry is often wrong or missing. Cross-check by scanning `installLocation` for the top 20.

## Curated defaults / Data files

- `data/unused_apps_never.json` — array of `{namePattern, publisherPattern, reason}`. Apps to NEVER include as candidates: VC++ redistributables, .NET runtimes, WebView2, drivers' control panels (NVIDIA Control Panel, AMD Adrenalin, Intel Graphics Command Center, Realtek Audio Console), security agents, backup agents, password managers, OneDrive.
- `data/silent_uninstall_flags.json` — installer type detection patterns + their silent flag: NSIS (`/S`), Inno Setup (`/VERYSILENT /SUPPRESSMSGBOXES`), InstallShield (`/s /f1<responseFile>`), BitRock (`--mode unattended`), MSI (`/qn`), Squirrel (`--uninstall`).

## Machine profile branches

- Prefetch disabled (checked at diagnose time): fall back to UserAssist only. Print in report.
- Small disk (`profile.disk[0].sizeGB < 512`): raise the threshold from 100 MB to 50 MB — every GB matters on a small SSD.
- Large disk (`profile.disk[0].sizeGB > 2000`): keep 100 MB threshold. Optionally add "and never launched" filter to reduce noise on machines where users have lots of installed-but-untouched software.
- Gaming role detected (Steam / Epic detected + `installLocation` under a launcher root): default to routing through the launcher; do NOT try to `winget uninstall` a Steam game.
- Corporate machine: warn before uninstalling any Publisher matching known corp deployments (McAfee, Kaspersky, Cisco, Zscaler, VPN clients). Ask twice.
