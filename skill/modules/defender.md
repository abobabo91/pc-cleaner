# module: defender

Tier: OPTIONAL. Opt-in via `--include defender`. Adds path exclusions for dev caches. Never modifies RTP settings, never adds process/extension exclusions.

## Success criteria

At the end of this module the user has:
1. Snapshot of current Defender exclusions (`Get-MpPreference | Select ExclusionPath, ExclusionExtension, ExclusionProcess`) BEFORE change.
2. Path exclusions added for the user's detected dev caches (pnpm store, cargo, rustup, gradle, m2, go modules, npm cache, nuget packages, WSL2 vhdx, Docker data root, node_modules under detected git repos).
3. User confirmed each exclusion category. This module ALWAYS asks; no auto-apply.
4. RTP and cloud-delivered protection untouched.
5. A `revert.ps1` that removes each added exclusion.

## Flow

### 1. Diagnose

Run `ps/diagnose/defender.ps1`. Emits:
- `.mpPreference` — output of `Get-MpPreference`, subset: `ExclusionPath`, `ExclusionExtension`, `ExclusionProcess`, `RealTimeProtectionEnabled`, `MAPSReporting`, `SubmitSamplesConsent`, `DisableRealtimeMonitoring` (must be false).
- `.tamperProtection` — `Get-MpComputerStatus | Select IsTamperProtected` — if `true`, exclusions can be added via PowerShell but the change may be reverted by MDM/policy. Warn.
- `.detectedDevCaches[]` — walks the user profile and known locations, records which are present and their sizes:
  - `%LOCALAPPDATA%\pnpm-store` (pnpm)
  - `%APPDATA%\npm-cache`, `%LOCALAPPDATA%\npm-cache` (npm)
  - `%LOCALAPPDATA%\Yarn\Cache` (yarn)
  - `~\.cargo\registry`, `~\.cargo\git`, `~\.rustup` (Rust)
  - `~\.gradle\caches`, `~\.gradle\wrapper` (Gradle)
  - `~\.m2\repository` (Maven)
  - `~\go\pkg\mod` (Go modules; also `$env:GOMODCACHE` if set)
  - `~\.nuget\packages`, `%LOCALAPPDATA%\NuGet\v3-cache` (NuGet)
  - WSL2 vhdx: `%LOCALAPPDATA%\Packages\CanonicalGroupLimited*\LocalState\ext4.vhdx` and equivalent for other distros, plus `%LOCALAPPDATA%\Docker\wsl\data\ext4.vhdx`
  - Docker Desktop data root: `%APPDATA%\Docker`, `%PROGRAMDATA%\DockerDesktop\vm-data\`
  - `%LOCALAPPDATA%\pip\Cache`, `~\AppData\Local\pypoetry\Cache` (Python)
  - `~\.cache\JetBrains`, `~\.gradle\.tmp` (JetBrains local caches)
  - Detected git repos: walk `~\source`, `~\projects`, `~\Desktop\github`, `~\src`, `~\dev`, `~\code`, `~\Documents\GitHub` — first two levels — record any dir with a `.git` child. For each such repo, offer `<repo>\node_modules`, `<repo>\.next`, `<repo>\dist`, `<repo>\build`, `<repo>\target` if they exist.

### 2. Categorize

- **HIGH-VALUE** — pnpm-store, node_modules (per-repo), Cargo registry, .m2, Docker WSL vhdx — largest and most-scanned during builds. Real-Time Protection scanning these visibly slows npm install / cargo build / gradle build.
- **MEDIUM-VALUE** — go modules, .rustup, NuGet, pip cache.
- **LOW-VALUE** — old .cargo/git subdirs (small files, but many), Yarn cache, small language caches.

### 3. Ask the user

`AskUserQuestion`, `multiSelect: true`, ≤3 questions grouped by role:

- **Package manager caches to exclude?** — checkboxes for each present: pnpm-store, npm-cache, yarn cache, NuGet packages, pip cache, poetry cache.
- **Language toolchains to exclude?** — Cargo, .rustup, Gradle, .m2, Go modules, JetBrains caches.
- **Docker / WSL / per-repo?** — WSL vhdx (Ubuntu / Docker), Docker data root, node_modules across N detected repos, .next/dist/build/target across N repos.

Warn in the question copy: "Excluded paths are not scanned in real time. Do this only for build caches you trust — not for random Downloads." No auto-tick.

### 4. Build plan JSON

```json
{
  "exclusions": [
    {"path":"C:\\Users\\<user>\\AppData\\Local\\pnpm-store","reason":"pnpm store"},
    {"path":"C:\\Users\\<user>\\AppData\\Local\\Packages\\CanonicalGroupLimited.Ubuntu_79rhkp1fndgsc\\LocalState\\ext4.vhdx","reason":"WSL2 Ubuntu vhdx"}
  ]
}
```

Never emit `exclusionProcess`, `exclusionExtension`, or anything that touches `Set-MpPreference` for global toggles.

### 5. Apply (elevated)

Call `ps/apply/defender.ps1 -Plan <path> -SnapshotDir <path>`. It:
- Snapshots current `Get-MpPreference` → `snapshot.json`.
- For each `exclusions[].path`: `Add-MpPreference -ExclusionPath <path>`. Idempotent — Defender silently skips duplicates.
- Logs each addition to `apply.log` with the reason.
- `revert.ps1` runs `Remove-MpPreference -ExclusionPath <path>` for each entry added by this run.

### 6. Report

- Count of exclusions added.
- Total size of excluded paths (info only — hints at how much scan work is being avoided).
- Explicit note: RTP still on, cloud protection still on, sample submission unchanged.
- Snapshot + revert paths.

## Known gotchas

- Tamper Protection ON: `Add-MpPreference` succeeds silently but the exclusion may be undone by policy on next sync. Detect via `Get-MpComputerStatus | Select IsTamperProtected`. Warn the user; suggest disabling TP temporarily (via UI — Defender does NOT allow scripted disable) only if they need the exclusion to stick and the MDM will not reapply.
- Exclusions do NOT apply to Controlled Folder Access. If the user has CFA on and their build tries to write into a protected folder, exclusion won't help. Report `Get-MpPreference | Select EnableControlledFolderAccess` and note if on.
- Symlinks and junctions: Defender exclusions match on resolved path, not symlink path. `~\.cargo` on many machines is a junction to `C:\Users\<user>\.cargo` — resolve first (`(Get-Item <path>).Target`) and exclude the target.
- WSL2 vhdx path varies by distro version + Windows Store update. `Get-ChildItem "$env:LOCALAPPDATA\Packages\CanonicalGroupLimited*\LocalState\ext4.vhdx"` handles Ubuntu; other distros have their own package prefixes. Enumerate rather than hardcode.
- Docker Desktop on WSL2 mode: the docker vhdx lives at `%LOCALAPPDATA%\Docker\wsl\disk\docker_data.vhdx` (older) or `%LOCALAPPDATA%\Docker\wsl\data\ext4.vhdx` (newer). Detect which exists.
- Docker Desktop on Hyper-V mode: `%PROGRAMDATA%\DockerDesktop\vm-data\DockerDesktop.vhdx`. Excluding this exceeds the "user profile only" rule — needs admin, tell the user why.
- `node_modules` inside a repo excluded WILL be excluded from the on-access scan while it's in that path. If the user moves the repo, the exclusion no longer applies to the new location (it's path-based, not identity-based).
- On MDM-managed machines (Intune, ConfigMgr), exclusions set via `Add-MpPreference` may be visible in `Get-MpPreference` but overridden at policy evaluation. Warn the user if `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Defender` has policy values set — MDM likely owns exclusions.
- Adding an exclusion for a path that doesn't yet exist is fine — Defender will honor it when the path appears (common when installing a new toolchain right after this module).
- Do NOT exclude `%USERPROFILE%` root. Do NOT exclude `Downloads`. Do NOT exclude `Desktop`. The apply script should refuse these paths hard.

## Curated defaults / Data files

- `data/dev_cache_paths.json` — array of `{name, category ("HIGH"|"MEDIUM"|"LOW"), pathPattern, requiresElevation, detectVia ("filesystem"|"envVar"|"registry"), notes}`. Extend to add new toolchain cache locations.
- `data/repo_scan_roots.json` — list of directories to walk to detect user git repos: `~\source`, `~\projects`, `~\Desktop\github`, `~\src`, `~\dev`, `~\code`, `~\Documents\GitHub`. Depth 2. Extend per-user via override.

## Machine profile branches

- No user profile detected as "dev" (no dev cache dirs, no repos found under scan roots): skip this module entirely with reason "no developer cache dirs found — Defender exclusions not useful for your workload."
- WSL2 not installed (`Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -Online` = Disabled): skip the WSL vhdx section.
- Docker Desktop not installed: skip Docker section.
- MDM-managed (`HKLM:\SOFTWARE\Microsoft\PolicyManager\current` has Defender-related keys): still run, but tag every exclusion in the report as "may be overridden by MDM."
- `profile.os.edition` = Home: Tamper Protection default is OFF on many Home installs, exclusions are stickier. On Pro/Enterprise, TP more often on.
