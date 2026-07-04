# module: crashdumps

Tier: OPTIONAL. Opt-in via `--include crashdumps` or `--dumps`. Installs Windows SDK Debuggers (~200 MB), configures symbol cache, runs `!analyze -v` on the last N minidumps, produces a driver-blame report.

Proven end-to-end in the seed session — see `knowledge_base/session_2026-07-04_lenovo_slim7prox.md` (Problem 1: 5 minidumps analyzed, `rtwlane.sys` identified as failing driver in 5 of 7 events).

## Success criteria

At the end of this module the user has:
1. WinDbg (`kd.exe`) installed at `C:\Program Files (x86)\Windows Kits\10\Debuggers\<arch>\kd.exe` or already present.
2. `_NT_SYMBOL_PATH` set to `srv*C:\Symbols*https://msdl.microsoft.com/download/symbols` (system-scope) with local symbol cache at `C:\Symbols`.
3. All recent minidumps from `C:\Windows\Minidump\*.dmp` copied to `<snapshotDir>/crashdumps/dumps/`.
4. For each dump: a `kd.exe -z <dump> -c "!analyze -v; q" -logo` log stored, and parsed `MODULE_NAME`, `IMAGE_NAME`, `BUGCHECK_CODE`, `BUGCHECK_STR`, `FAILURE_BUCKET_ID`, `PROCESS_NAME`.
5. A report ranking failing drivers by count, mapped to human-readable driver names via `data/known_drivers.json`.
6. `drivers` module cross-linkage: for each blamed driver, the report notes whether `drivers` module also flagged it (stale / OEM mismatch).

## Flow

### 1. Diagnose

Run `ps/diagnose/crashdumps.ps1`. It:
- Checks for `kd.exe` at both x64 and ARM64 locations.
- Checks `_NT_SYMBOL_PATH` at Machine and User scope.
- Enumerates `C:\Windows\Minidump\*.dmp` — count, oldest, newest, total bytes.
- Enumerates `C:\Windows\MEMORY.DMP` (full kernel dump if the user has kernel dump enabled).
- Also enumerates kernel-power 41 events with `BugCheckCode=0` in last 30 d — these are freezes without a dump, useful for the report even though we can't analyze them (see Modern Standby fingerprint in `power` module).

### 2. Ask the user

**Plain-English rule: describe what we're doing ("figure out which driver is crashing your PC") instead of tool names like "WinDbg" or "kd.exe."** Keep raw tool names, symbol paths, and SDK URLs INTERNAL. Substitute the actual crash-log count found at diagnose time.

Single `AskUserQuestion`:

**Q1 — "I found N crash reports from the last 30 days. Want me to figure out which driver is crashing your PC?" (this needs a ~200 MB tool from Microsoft. I'll download it, run it against the crash reports, and give you a ranked list of which driver / hardware chip is to blame.)**
- Yes — download the analysis tool (~200 MB) and analyze the crash reports
- Yes — I've already got the tool installed, just do the analysis
- No — skip this

### 3. Build plan JSON

```json
{
  "installSdk": true,
  "analyzeCount": 10,
  "symbolCachePath": "C:\\Symbols",
  "symbolServer": "https://msdl.microsoft.com/download/symbols"
}
```

### 4. Apply (elevated)

Call `ps/apply/crashdumps.ps1 -Plan <path> -SnapshotDir <path>`. It:
- If `installSdk` and `kd.exe` not present: download `winsdksetup.exe` from `https://go.microsoft.com/fwlink/?linkid=<current>` (encoded in `data/sdk_urls.json` — check current link before shipping), run `winsdksetup.exe /features OptionId.WindowsDesktopDebuggers /quiet /norestart /log <snapshotDir>/sdk-install.log`. Wait for exit; verify `kd.exe` appears.
- Set `_NT_SYMBOL_PATH` machine-scope: `[Environment]::SetEnvironmentVariable('_NT_SYMBOL_PATH','srv*C:\Symbols*https://msdl.microsoft.com/download/symbols','Machine')`. Also `New-Item C:\Symbols -ItemType Directory -Force`.
- Copy the last `analyzeCount` `.dmp` files (by LastWriteTime desc) from `C:\Windows\Minidump\` to `<snapshotDir>/crashdumps/dumps/`. This copy step needs elevation because `Minidump` folder ACL is Administrators-only.
- For each copied dump: `& $kd -z "$dump" -c "!analyze -v; q" -logo "<snapshotDir>/crashdumps/logs/<dumpname>.log"`. Kd downloads symbols on first run — first analysis is slow (30-60 s), subsequent fast.
- Parse each log: extract `BUGCHECK_CODE`, `BUGCHECK_STR`, `MODULE_NAME`, `IMAGE_NAME`, `FAILURE_BUCKET_ID`, `PROCESS_NAME`, `STACK_TEXT` first frame.
- Group by `IMAGE_NAME` (or `MODULE_NAME` when `IMAGE_NAME` empty) and emit ranked report.

### 5. Report

Table:

| Rank | Failing driver | Human name | Bug check(s) | Count | Cross-reference |
|---|---|---|---|---|---|
| 1 | rtwlane.sys | Realtek RTL8822CE WLAN | 0x133, 0x139 | 5 | drivers module flagged as HIGH (OEM subsystem mismatch, stale 3y) |
| 2 | dxgmms2.sys | DirectX Graphics MMS | 0x133 | 1 | GPU sched — likely triggered by upstream driver, not root cause |
| 3 | amdacpbus.sys | AMD ACP bus (carries BT on Ryzen) | 0x133 | 1 | drivers module: latest BIOS ships this |

Note the total count of kernel-power 41 freezes (no dump) alongside, since those are silent Modern Standby crashes not covered by bugcheck analysis. If that count is high, point at `power` module.

## Known gotchas

- `winsdksetup.exe /features OptionId.WindowsDesktopDebuggers /quiet` sometimes returns exit 0 without installing anything if a newer SDK is already partially installed. Verify by `Test-Path` on `kd.exe` after — do not trust exit code alone.
- The SDK installer download link (`fwlink/?linkid=`) changes with SDK version. Encode current URL in `data/sdk_urls.json` and check for a 3xx redirect chain resolving to a `.exe` before trusting it. If URL rots, the module should say "unable to auto-download SDK; download WinSDK manually from https://developer.microsoft.com/windows/downloads/windows-sdk/ and rerun."
- Setting `_NT_SYMBOL_PATH` at Machine scope requires elevation. Existing sessions do NOT inherit the change — the kd invocation in the same `apply.log` step must pass the env explicitly: `& { $env:_NT_SYMBOL_PATH = 'srv*C:\Symbols*https://msdl.microsoft.com/download/symbols'; & $kd ... }`.
- `C:\Windows\Minidump` has ACL denying non-admin read. `Copy-Item` from a non-elevated session fails silently.
- If Windows is set to "small memory dump" (default on modern Win11), minidumps are in `Minidump\`. If it's set to "kernel memory dump" or "complete", the big dump is at `C:\Windows\MEMORY.DMP` — sometimes minidumps are ALSO written. `!analyze -v` on MEMORY.DMP works but takes minutes and needs 3-8 GB free during analysis.
- First kd run on a machine can spend 5-15 min downloading `ntoskrnl.exe.pdb` and platform PDBs. Streaming output to `apply.log` is essential so the user sees progress.
- `!analyze -v` on a Modern Standby freeze (no dump written) has nothing to analyze. Distinguish these upfront by cross-referencing Kernel-Power 41 events with `BugCheckCode=0` — do NOT confuse with real bugchecks.
- `FAILURE_BUCKET_ID` and `MODULE_NAME` can name a downstream driver, not the root cause. E.g. `nt` or `ntoskrnl` blaming is almost always a symptom, not the cause — walk `STACK_TEXT` for the first non-`nt!` module.
- The seed-session case where `ndis!ndisQueuePeriodicReceivesTimer` blamed `ndis.sys` — the actual failing driver was Realtek's miniport under it. Look one frame down the stack in kd output.
- If Secure Boot is on and the user has a self-signed test driver installed, kd will refuse to analyze the dump signature — this is rare, but note it.
- On ARM64 Windows (Snapdragon X), `kd.exe` and PDBs are separate; use the ARM64 kd from the SDK. `data/sdk_urls.json` needs both arches.
- Symbol server calls go over HTTPS to `msdl.microsoft.com`. If the machine is behind a proxy that MITMs SSL, kd will fail on symbol download with cryptic errors. Detect corp proxy via `netsh winhttp show proxy` and warn.

## Curated defaults / Data files

- `data/known_drivers.json` — maps `image.sys` filename to `{humanName, vendor, chipsetOrProduct, notes}`. E.g. `rtwlane.sys` → Realtek RTL8822/8852 series WLAN. Extend with each new investigation.
- `data/bugcheck_codes.json` — bugcheck hex code → human-readable string + typical culprits (0x133 DPC_WATCHDOG_VIOLATION → CPU vs driver DPC time; 0x139 KERNEL_SECURITY_CHECK_FAILURE → stack corruption or GS-cookie mismatch; 0x1E KMODE_EXCEPTION_NOT_HANDLED → NULL deref usually). Referenced by the report.
- `data/sdk_urls.json` — current SDK installer URL + version + expected `kd.exe` path + arch. Check monthly.

## Machine profile branches

- `profile.arch` (x64 vs ARM64): pick the matching kd.exe path. `C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\` vs `\arm64\`.
- `profile.flags.isModernStandbyOnly=true`: the report MUST explicitly separate real bugchecks from Kernel-Power 41 no-dump freezes. Cross-link to `power` module fix (lid = do nothing, hibernate on DC timer).
- Bugcheck count in last 30 d = 0: still run if user asked — user may want to verify no historic dumps are lingering. Report should say "no minidumps found; if you've had crashes, verify Small Memory Dump is enabled in System Properties → Advanced → Startup and Recovery."
- Small NVMe with `<10 GB` free: warn before installing SDK — 200 MB SDK + up to 8 GB symbol cache.
- Corporate machine (`profile.domain.joined=true` or MDM-managed): warn user before installing SDK unattended — IT may treat unattended SDK installs as policy violations. Suggest opt-out.
