# module: defender

Tier: OPTIONAL. Opt-in via `--include defender`. Adds path exclusions for dev caches, one at a time per detected toolchain. Never modifies RTP settings, never adds process/extension exclusions.

## Success criteria

At the end of this module the user has:
1. Snapshot of current Defender exclusions (`Get-MpPreference | Select ExclusionPath, ExclusionExtension, ExclusionProcess`) BEFORE change.
2. Path exclusions added for each user-approved dev cache.
3. One question per detected toolchain — no batching, no "check all that apply."
4. RTP and cloud-delivered protection untouched.
5. A `revert.ps1` that removes each added exclusion.

## Flow

### 1. Diagnose

Run `ps/diagnose/defender.ps1`. Emits:
- `.mpPreference` — output of `Get-MpPreference`, subset: `ExclusionPath`, `ExclusionExtension`, `ExclusionProcess`, `RealTimeProtectionEnabled`, `MAPSReporting`, `SubmitSamplesConsent`, `DisableRealtimeMonitoring` (must be false).
- `.tamperProtection` — `Get-MpComputerStatus | Select IsTamperProtected` — if `true`, exclusions can be added via PowerShell but the change may be reverted by MDM/policy. Warn.
- `.detectedToolchains[]` — one entry per detected toolchain, each with `{name, humanName, cachePaths[], present: bool, sizeMB, question: "..."}`. Each ask cycle asks ONE toolchain at a time.

Toolchains detected:

| Internal name | Human name | Paths / detection |
|---|---|---|
| `node` | Node.js | `%LOCALAPPDATA%\pnpm-store`, `%APPDATA%\npm-cache`, `%LOCALAPPDATA%\npm-cache`, `%LOCALAPPDATA%\Yarn\Cache` |
| `cargo-rustup` | Rust (Cargo + rustup) | `~\.cargo\registry`, `~\.cargo\git`, `~\.rustup` |
| `gradle` | Gradle | `~\.gradle\caches`, `~\.gradle\wrapper` |
| `maven` | Maven | `~\.m2\repository` |
| `go` | Go modules | `~\go\pkg\mod`, `$env:GOMODCACHE` |
| `nuget` | .NET / NuGet | `~\.nuget\packages`, `%LOCALAPPDATA%\NuGet\v3-cache` |
| `python` | Python (pip + Poetry) | `%LOCALAPPDATA%\pip\Cache`, `~\AppData\Local\pypoetry\Cache` |
| `jetbrains` | JetBrains IDE caches | `~\.cache\JetBrains`, `~\.gradle\.tmp` |
| `wsl` | WSL2 Linux virtual disk | `%LOCALAPPDATA%\Packages\CanonicalGroupLimited*\LocalState\ext4.vhdx` etc. |
| `docker` | Docker Desktop | `%LOCALAPPDATA%\Docker\wsl\data\ext4.vhdx`, `%PROGRAMDATA%\DockerDesktop\vm-data\` |
| `repos-node_modules` | your project `node_modules` folders | Walk `data/repo_scan_roots.json` depth 2; find `.git` dirs; per repo list `node_modules` if present |
| `repos-build` | your project build outputs | Same walk; per repo `.next`, `dist`, `build`, `target` |

Present = at least one path exists AND has data.

### 2. Categorize

- **ASK-USER (per toolchain)** — one question per PRESENT toolchain. Not asked if not present.
- **NEVER-AUTO** — this module always asks; no silent apply.

Refuse hard:
- `%USERPROFILE%` root
- `Downloads`
- `Desktop`
- `Documents` root

### 3. Ask the user, one at a time — ONE question per toolchain that is actually present

**Plain-English rule: describe folders by which tool creates them ("the folder Node.js puts downloaded packages in"), not by their path or ecosystem name.** Keep raw paths INTERNAL.

Use `AskUserQuestion` with `multiSelect: false` — one call per PRESENT toolchain.

Below is a question per toolchain — asked only if the toolchain is present.

---

**Q — Node.js**

> "You have Node.js installed. Antivirus scanning your npm cache slows down builds a lot. Want me to tell Windows Defender to skip that folder?"

*Skip if:* `node` toolchain not detected (no pnpm-store, no npm-cache, no yarn cache).

*"I'm not sure" inference:* → YES. Node builds do many thousands of tiny file writes; the RTP scan cost is 3-10x on cold `npm install`. Exclusion is a widely-recommended standard for dev machines.

*Controls:* `Add-MpPreference -ExclusionPath` for each detected Node.js cache path.

---

**Q — Rust (Cargo)**

> "You have Rust installed. Antivirus scanning your cargo cache slows down builds a lot. Want me to skip those folders?"

*Skip if:* `cargo-rustup` toolchain not detected.

*"I'm not sure" inference:* → YES. `cargo build` on a fresh cache pulls thousands of source files; RTP scan is measurable.

*Controls:* `Add-MpPreference -ExclusionPath ~\.cargo\registry`, `~\.cargo\git`, `~\.rustup`.

---

**Q — Gradle**

> "You have Gradle projects. Antivirus scanning the Gradle cache is a common slowdown. Want me to skip it?"

*Skip if:* `gradle` toolchain not detected.

*"I'm not sure" inference:* → YES.

*Controls:* `~\.gradle\caches`, `~\.gradle\wrapper`.

---

**Q — Maven**

> "You have Maven / .m2 caches. Want me to tell antivirus to skip them?"

*Skip if:* `maven` toolchain not detected.

*"I'm not sure" inference:* → YES.

*Controls:* `~\.m2\repository`.

---

**Q — Go modules**

> "You use Go. Want antivirus to skip your Go module cache?"

*Skip if:* `go` toolchain not detected.

*"I'm not sure" inference:* → YES.

*Controls:* `~\go\pkg\mod`, `$env:GOMODCACHE`.

---

**Q — .NET / NuGet**

> "You use .NET / NuGet. Want antivirus to skip the NuGet package cache?"

*Skip if:* `nuget` toolchain not detected.

*"I'm not sure" inference:* → YES.

*Controls:* `~\.nuget\packages`, `%LOCALAPPDATA%\NuGet\v3-cache`.

---

**Q — Python (pip / Poetry)**

> "You use Python. Want antivirus to skip the pip download cache?"

*Skip if:* `python` toolchain not detected.

*"I'm not sure" inference:* → YES.

*Controls:* `%LOCALAPPDATA%\pip\Cache`, `~\AppData\Local\pypoetry\Cache`.

---

**Q — JetBrains IDE caches**

> "You use a JetBrains IDE (IntelliJ / PyCharm / WebStorm / etc.). Want antivirus to skip the IDE's indexing cache?"

*Skip if:* `jetbrains` toolchain not detected.

*"I'm not sure" inference:* → YES.

*Controls:* `~\.cache\JetBrains`.

---

**Q — WSL2 Linux virtual disk**

> "Your WSL2 Ubuntu (or other Linux) lives inside one big virtual-disk file. Antivirus scans it constantly. Want me to skip it?"

*Skip if:* `wsl` toolchain not detected.

*"I'm not sure" inference:* → YES. This is the single highest-value exclusion for WSL users.

*Controls:* the actual detected `ext4.vhdx` path (varies per distro).

---

**Q — Docker Desktop**

> "You have Docker Desktop. Its virtual-disk file is scanned constantly. Want me to skip it?"

*Skip if:* `docker` toolchain not detected.

*"I'm not sure" inference:* → YES.

*Controls:* `%LOCALAPPDATA%\Docker\wsl\data\ext4.vhdx` (WSL2 mode) or `%PROGRAMDATA%\DockerDesktop\vm-data\DockerDesktop.vhdx` (Hyper-V mode).

---

**Q — Your project `node_modules` folders**

> "I found node_modules folders in [N] of your git repositories. Want antivirus to skip those?"

*Skip if:* no repos with node_modules detected.

*"I'm not sure" inference:* → YES if repos scanned found ≤ 5 with node_modules. If > 5 → still YES but include a caveat in the report about scope.

*Controls:* per-repo `<repo>\node_modules` — one exclusion each.

---

### After all questions, show the decision summary

```
Antivirus exclusions — here's what I figured out:

  Node.js caches:        ADD  (auto: 4.8 GB, cold-install speedup)
  Rust caches:           ADD  (you said yes)
  Gradle:                (skipped — not detected)
  Maven:                 (skipped — not detected)
  Go modules:            ADD  (auto)
  NuGet:                 (skipped — not detected)
  Python (pip):          ADD  (auto)
  JetBrains:             (skipped — not detected)
  WSL2 Linux disk:       ADD  (auto: 12 GB)
  Docker:                (skipped — not installed)
  Repo node_modules:     ADD  (auto: 3 repos)

I'll add 9 path exclusions to Windows Defender.
RTP and cloud protection stay ON.
Continue?  [Yes / No / Show me the list]
```

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
- On MDM-managed machines (Intune, ConfigMgr), exclusions set via `Add-MpPreference` may be visible in `Get-MpPreference` but overridden at policy evaluation.
- Adding an exclusion for a path that doesn't yet exist is fine — Defender will honor it when the path appears (common when installing a new toolchain right after this module).
- Do NOT exclude `%USERPROFILE%` root. Do NOT exclude `Downloads`. Do NOT exclude `Desktop`. The apply script should refuse these paths hard.

## Curated defaults / Data files

- `data/dev_cache_paths.json` — array of `{name, category ("HIGH"|"MEDIUM"|"LOW"), pathPattern, requiresElevation, detectVia ("filesystem"|"envVar"|"registry"), notes, humanName, question}`. Extend to add new toolchain cache locations.
- `data/repo_scan_roots.json` — list of directories to walk to detect user git repos: `~\source`, `~\projects`, `~\Desktop\github`, `~\src`, `~\dev`, `~\code`, `~\Documents\GitHub`. Depth 2.

## Machine profile branches

- No user profile detected as "dev" (no dev cache dirs, no repos found under scan roots): skip this module entirely with reason "no developer cache dirs found — Defender exclusions not useful for your workload."
- WSL2 not installed: skip WSL vhdx question.
- Docker Desktop not installed: skip Docker question.
- MDM-managed: still run, but tag every exclusion in the report as "may be overridden by MDM."
- `profile.os.edition` = Home: Tamper Protection default is OFF on many Home installs, exclusions are stickier. On Pro/Enterprise, TP more often on.
