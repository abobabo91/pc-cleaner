# module: startup

Tier: CORE. Auto-runs. Asks up to 4 grouped multi-select questions for ambiguous entries.

## Success criteria

At the end of this module the user has:
1. A JSON snapshot of every autostart entry (Run keys, Startup folders, logon-triggered scheduled tasks) BEFORE any change.
2. Every DISABLE-SAFE autostart disabled (not deleted — flip `Enabled=0` where possible).
3. Every KEEP-FOR-YOU entry left alone with reason logged.
4. User's MAYBEs resolved in ≤4 grouped multi-select questions.
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
| Approved list | `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApprved\Run` (byte value: 03/02 = enabled) |
| User startup folder | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup` |
| Common startup folder | `%PROGRAMDATA%\Microsoft\Windows\Start Menu\Programs\Startup` |
| Task Scheduler | `Get-ScheduledTask` where triggers include `MSFT_TaskLogonTrigger` or `MSFT_TaskBootTrigger`, State=Ready, Author != "Microsoft Corporation" (or in `\Microsoft\Windows\` unless the task itself is user-created) |

For each entry emit `{source, name, command, publisher, signed, installedApp, enabled, category}` where `installedApp` is a best-effort match of the command path against `Get-Package` / `Get-AppxPackage` output.

### 2. Categorize

- **KEEP**: signed by Microsoft and required (Windows Security notification, Windows Defender).
- **KEEP-FOR-YOU**: matches a currently-used installed app the user relies on. Never touch:
  - OneDrive if the user has files under `%USERPROFILE%\OneDrive` synced.
  - Docker Desktop, Rancher Desktop, WSL if `wsl.exe -l` returns distros.
  - NVIDIA / AMD control panel launchers if the corresponding GPU is present.
  - Password managers (1Password, Bitwarden, KeePassXC).
  - Backup agents (Backblaze, Arq, Duplicati).
  - VPN clients if the user has active VPN configs.
- **DISABLE-SAFE**: known-safe autostart cruft (Adobe updater helpers, Spotify webhelper if music not in autostart-relevant state, Steam Client Bootstrapper if user launches Steam manually, GoogleUpdate, EdgeUpdate — these all re-run on demand).
- **MAYBE**: everything else. Bucket for a question.

### 3. Ask the user

Use `AskUserQuestion` with `multiSelect: true`, ≤4 questions, grouped:

- **Do you want these to launch at login?** — Slack, Discord, Steam, Epic Games Launcher, Spotify, other chat apps.
- **Which updaters can wait until you launch the app?** — GoogleUpdate, EdgeUpdate, JavaUpdate, Adobe ARM, Brave update.
- **Cloud sync at boot?** — OneDrive, Dropbox, Google Drive, iCloud, MEGA.
- **OEM & hardware helpers?** — Lenovo Vantage, Dell Command Update, ASUS Armoury Crate, HP Support Assistant, RGB software (iCUE, Aura, SignalRGB), NVIDIA App, AMD Adrenalin.

Unchecked → tip toward DISABLE. Checked → KEEP.

### 4. Build plan JSON

```json
{
  "disableRegistry": [{"hive":"HKCU","view":"64","name":"Spotify","reason":"..."}],
  "disableStartupFolder": [{"scope":"user","file":"Discord.lnk","reason":"..."}],
  "disableTasks": [{"taskPath":"\\","taskName":"GoogleUpdateTaskUserS-1-...UA","reason":"..."}]
}
```

### 5. Apply (elevated only if HKLM or common startup or `\Microsoft\Windows\` tasks touched)

Call `ps/apply/startup.ps1 -Plan <path> -SnapshotDir <path>`. It:
- For Registry Run entries: writes the StartupApproved byte to disabled (`06 00 00 00 ...`) rather than deleting the value. Revert restores original bytes.
- For Startup folder: moves the `.lnk` into `<snapshotDir>\startup\disabled-lnks\` (do not delete).
- For scheduled tasks: `Disable-ScheduledTask`. Revert re-enables.

### 6. Report

- Autostart count before/after.
- List of disabled entries with reason.
- Snapshot + revert paths.

## Known gotchas

- The `StartupApproved` byte layout: bytes 0-3 = enable flag (`02 00 00 00` or `03 00 00 00` = enabled; `06 00 00 00` = disabled), bytes 4-11 = FILETIME of the state change. If you overwrite without preserving alignment Windows treats the entry as corrupt and shows "unknown" in Task Manager Startup tab. Copy the existing bytes, mutate only byte 0.
- Task Scheduler tasks under `\Microsoft\Windows\` may be re-created by Windows Update or feature updates. `Disable-ScheduledTask` survives cumulative updates but often does NOT survive feature updates (23H2 → 24H2). Note this in the report so the user knows to re-run after big updates.
- Some entries (Realtek Audio Console `RtkAudUService`, Intel Graphics helper `igfxTray`) are BOTH a service AND an autostart entry AND a scheduled task. Disabling only one has no effect. Cross-reference with the services module output and note overlap.
- `Get-ScheduledTask` on PS 5.1 silently truncates the task path when it contains non-ASCII (e.g. `\Microsoft\Windows\Söngi`). Use `schtasks.exe /query /fo csv /v` fallback when a non-ASCII task path is expected.
- OneDrive `OneDrive.exe /background` shows up as HKCU Run but if you disable it while files are actively syncing you can freeze Explorer. Check `Get-Process OneDrive` and pending queue file `%LOCALAPPDATA%\Microsoft\OneDrive\logs\Business1\SyncEngine.log` before disabling.
- Docker Desktop autostart also enables the `com.docker.service` Windows service. Disabling only the tray icon leaves the service running. Cross-check with services module — if user said "disable Docker autostart" they probably meant both.

## Curated defaults / Data files

- `data/startup_disable_safe.json` — array of `{namePattern, publisher, reason}`. Machine-agnostic autostart cruft. Extend to add more.
- `data/startup_tripwire.json` — never disable: security agents (CrowdStrike, SentinelOne, Defender helpers), MDM (Intune), corporate VPN.
- `data/startup_role_hints.json` — maps common autostart names to a "role" (`dev`, `creative`, `gamer`, `office`) used by `ninite-personalized` to detect the user's role.

## Machine profile branches

- `profile.flags.isLaptop=true` AND OEM vendor management app installed (Lenovo Vantage, HP Support Assistant, Dell Command Update): keep by default unless user explicitly unchecks. On laptops these push firmware/thermal fixes.
- `profile.flags.hasDiscreteGPU=true`: keep NVIDIA / AMD control panel launcher unless user unchecks (needed for Optimus / hybrid graphics switching).
- Desktop: OEM helpers are almost always cruft, tip toward DISABLE.
- If `wsl -l -q` returns any distro, Docker Desktop / Rancher / Podman Desktop autostart is treated as KEEP-FOR-YOU by default.
