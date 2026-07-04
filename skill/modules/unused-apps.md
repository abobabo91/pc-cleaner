# module: unused-apps

Tier: OPTIONAL. Opt-in via `--include unused-apps`. Detects installed apps not launched in 90+ days AND >100 MB installed, proposes per-app uninstall. Asks per candidate.

## Success criteria

At the end of this module the user has:
1. A table of installed apps ranked by (days since last launch × install size), filtered to apps >100 MB and last-launched >90 days ago (or never).
2. Per-app: user confirms uninstall or skips.
3. Confirmed apps uninstalled via winget / MsiExec / uninstaller registry command.
4. A `revert.ps1` — narrow: notes winget IDs so user can re-install; MSI/EXE uninstalls are one-way unless user has the installer.

## Flow

### 1. Diagnose

Run `ps/diagnose/unused-apps.ps1`. It:
- Enumerates installed apps: union of `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*` (+ Wow6432Node), `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*`, `Get-AppxPackage` for UWP. Emits `{name, publisher, version, installDate, uninstallString, installLocation, estimatedSize, source}`.
- Computes last-launched time for each app from three sources (best of):
  1. **Prefetch** — `C:\Windows\Prefetch\<EXENAME>-<HASH>.pf`. `LastWriteTime` on the `.pf` file = last launch of that .exe. Cross-reference against each app's install location — for each `.exe` in `installLocation`, look up its `.pf`.
  2. **UserAssist** — `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\UserAssist\{CEBFF5CD-...}\Count` and `{F4E57C4B-...}\Count`. Values are ROT13-encoded. Decode. Each entry has run count + last-used FILETIME. Match by executable path.
  3. **Access time on the main .exe** — Get-Item `installLocation\<mainExe>` .LastAccessTime. Only trustworthy if the volume has last-access-time tracking on (`fsutil behavior query DisableLastAccess` = 0 or 2 — 1 or 3 = disabled). Modern Windows defaults to disabled; skip if so.
- For each app: `lastLaunched = max of (source 1..3)`; `neverLaunched: bool` if none found; `installSizeMB` from registry `EstimatedSize` (in KB) or by scanning `installLocation`.

### 2. Categorize

Include in candidate list if ALL:
- `installSizeMB > 100`
- `lastLaunched < today - 90 d` OR `neverLaunched = true`
- App is NOT in `data/unused_apps_never.json` — protects apps that are legitimately background-only (drivers' control panels, security agents, Windows Media Feature Pack, Visual C++ Redistributables — even 500 MB of VC++ redists is normal and must never be flagged).

Rank by `installSizeMB × log10(days_since_launch + 1)`.

### 3. Ask the user

`AskUserQuestion`, `multiSelect: true`. Split into ≤4 questions of ~5 apps each. Show for each:
- Name
- Size (MB or GB)
- Last launched (date or "never")
- Publisher

Do NOT include Windows-shipped UWP bloat here — that's `bloat` module's job. Only reach for third-party apps installed by the user or OEM.

### 4. Build plan JSON

```json
{
  "uninstall": [
    {"name":"Old Adobe App","source":"winget","wingetId":"Adobe.Something","reason":"Not launched in 8 months, 2.1 GB"},
    {"name":"Game X","source":"registry","uninstallString":"\"C:\\...\\uninstall.exe\" /SILENT","reason":"Never launched, 45 GB"}
  ]
}
```

### 5. Apply (elevated)

Call `ps/apply/unused-apps.ps1 -Plan <path> -SnapshotDir <path>`. For each app:
- Prefer winget when a winget ID is known: `winget uninstall --id <id> --silent`.
- Else fall back to MSI: parse `uninstallString` for `MsiExec.exe /X{GUID}` and run with `/qn`.
- Else run the uninstall string with silent flags if we recognize them (`/S` for NSIS, `--mode unattended` for BitRock, `/qn` for MSI, `-silent` for InstallShield). If we don't recognize the flags, log the uninstall string to the report and skip auto-uninstall — force the user to run it manually.
- After each uninstall: verify the app disappeared from the enumeration (some uninstalls exit 0 but leave the app behind — those need manual cleanup).
- Note bytes reclaimed per app.
- `revert.ps1` records the winget IDs / publisher+name for anything removed. Not a true revert — a hint list.

### 6. Report

- Table: what was uninstalled, size reclaimed, time since last launch.
- Total bytes reclaimed.
- Anything skipped because we couldn't determine silent flags (user follow-up needed).

## Known gotchas

- Prefetch is disabled on SSDs by default on some Win11 builds since 24H2. Check `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters\EnablePrefetcher` — 0 means Prefetch disabled and this source of last-launched is dead. Fall back on UserAssist.
- Prefetch files hash by full path. If the user has moved an app (e.g. dragged Steam Library between drives), the old Prefetch file lingers with old LastWriteTime while the new location has none. Cross-reference both.
- UserAssist ROT13 encoding: each subkey name is ROT13(path). Values are binary blobs where offset 60 (0x3C) has `LastUsedTime` as FILETIME. Referenced pattern well-documented for forensics — encode carefully.
- UserAssist only tracks apps launched from Start / Run / Explorer. Apps launched purely from CLI (`node`, `python`, tools users invoke from the command line) never appear here. Do not conclude "never launched" for CLI-only tools based on UserAssist alone — cross-check Prefetch.
- Disabled last-access time on NTFS: `fsutil behavior query DisableLastAccess` — 1 or 3 = disabled (Windows 10+ default). If disabled, `.LastAccessTime` on the exe is useless.
- Apps with active scheduled tasks that run their exe periodically: LastWriteTime on Prefetch may show recent activity even if the user hasn't interacted with the app. Cross-reference against Task Scheduler entries; exclude apps whose "launches" come from a scheduled task.
- Some apps register as multiple Uninstall entries (main app + updater + helper). Uninstalling only "main" may leave the helper. When possible, uninstall by winget ID which handles the family.
- Non-silent uninstallers pop UAC + confirmation dialogs. If run under a scheduled task or non-interactive session, they hang forever. Detect silent-flag support; refuse to auto-run non-silent uninstalls.
- Steam / Epic / Ubisoft / EA games — each launcher has its own uninstall mechanism. `winget uninstall` for a Steam game may fail; the correct path is `steam://uninstall/<appid>` or via the launcher. Detect via `installLocation` under a known launcher root and route through the launcher, or refuse and tell user to uninstall via the launcher.
- Adobe apps require Adobe's own uninstaller — regular MSI uninstall leaves shared components in a broken state. Suggest via `Adobe Creative Cloud → Apps → Installed → Uninstall` instead of scripting it.
- Portable apps (no installer, extracted to a folder) don't show up in Uninstall registry. Prefetch will show they've been launched, but there's no "uninstall" — just delete the folder. Skip these in the report unless user asks about specific paths.
- 90-day threshold is a heuristic. Some apps (annual tax software, occasional utilities) are legitimately used every 6-12 months. Ask, never auto.
- `EstimatedSize` in the Uninstall registry is often wrong or missing. Cross-check by scanning `installLocation` for the top offenders — but that's slow. Only rescan the top 20 by claimed size.

## Curated defaults / Data files

- `data/unused_apps_never.json` — array of `{namePattern, publisherPattern, reason}`. Apps to NEVER include as candidates regardless of last-launched:
  - Visual C++ Redistributables (all).
  - .NET Runtimes (all).
  - Microsoft Edge WebView2 Runtime.
  - Windows drivers' control panels (NVIDIA Control Panel, AMD Adrenalin, Intel Graphics Command Center, Realtek Audio Console).
  - Security agents (Defender helpers, CrowdStrike, SentinelOne, third-party AV).
  - Backup agents (Backblaze, Arq — could sit unused for months but must not be removed).
  - Password managers.
  - `Microsoft OneDrive` (handled by `bloat` if user opts).
- `data/silent_uninstall_flags.json` — installer type detection patterns + their silent flag: NSIS (`/S`), Inno Setup (`/VERYSILENT /SUPPRESSMSGBOXES`), InstallShield (`/s /f1<responseFile>`), BitRock (`--mode unattended`), MSI (`/qn`), Squirrel (`--uninstall`), etc.

## Machine profile branches

- Prefetch disabled (checked at diagnose time): fall back to UserAssist only. Print in report: "Prefetch disabled on this machine — last-launched estimates come from UserAssist only, less complete."
- Small disk (`profile.disk[0].sizeGB < 512`): raise the threshold from 100 MB to 50 MB — every GB matters on a small SSD.
- Large disk (`profile.disk[0].sizeGB > 2000`): keep 100 MB threshold. Optionally add "and never launched" filter to reduce noise on machines where users have lots of installed-but-untouched software.
- Gaming role detected (Steam / Epic detected + `installLocation` under a launcher root): default to routing through the launcher; do NOT try to `winget uninstall` a Steam game.
- Corporate machine: warn before uninstalling any Publisher matching known corp deployments (McAfee, Kaspersky, Cisco, Zscaler, VPN clients). Ask twice.
