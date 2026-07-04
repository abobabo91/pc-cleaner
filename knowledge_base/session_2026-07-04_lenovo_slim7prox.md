# Session 2026-07-04 — Lenovo Slim 7 ProX 14ARH7 (Ryzen 6900HS)

Concrete findings from the session that seeded this project.

## Machine

- Lenovo Slim 7 ProX 14ARH7 (MT 82V2)
- Ryzen 9 6900HS Creator Edition
- NVIDIA RTX 3050 Laptop + AMD Radeon 680M iGPU
- Samsung PM9A1 1TB NVMe, firmware CL1QGXA7
- Realtek RTL8822CE WiFi + BT combo (subsystem `85F7103C` = HP-vendored variant)
- BIOS JVCN40WW (Feb 2024)

## Problem 1 — Recurring BSODs

13 crashes in the ~4 weeks before this session. WinDbg analysis of last 5 dumps:

| Bug check | Failing driver | Count |
|---|---|---|
| 0x133 DPC_WATCHDOG_VIOLATION | rtwlane.sys (Realtek WiFi) or ndis!ndisQueuePeriodicReceivesTimer (Realtek miniport) | 3 |
| 0x139 KERNEL_SECURITY_CHECK_FAILURE (GUARD_ICALL) | rtwlane.sys | 2 |
| 0x133 | dxgmms2.sys (GPU scheduler) | 1 |
| 0x133 | amdacpbus.sys (AMD Audio CoProcessor — carries BT on Ryzen 6000) | 1 |

**Root cause:** Realtek WiFi driver stuck at May 2021 build (`2024.0.10.223`). Lenovo could not push updates because the card's subsystem ID is HP's (`103C`), so Lenovo System Update / Windows Update / Windows Optional Updates all said "you're current." Cross-vendor SoftPaq from HP was the fix.

**Fix applied:** HP SoftPaq sp162860 (WLAN, v2024.10.230.600, Jun 2025) + PCIe ASPM disabled at OS level. Zero BSODs since.

**Generalization for `drivers` module:**
- Always check subsystem ID, not just VID/DEV.
- If OEM = Lenovo but subsystem = HP/Dell/other, the OEM won't ship updates. Look at the actual subsystem OEM's driver catalog.
- HP SoftPaqs at `ftp.hp.com/pub/softpaq/sp<N-500>-<N>/spN.exe`.

## Problem 2 — Bluetooth 10cm range

BT enumerated with Microsoft generic `bth.inf` driver, not Realtek's vendor driver. Missing:
- Chip-specific firmware patch
- WiFi/BT antenna coexistence tuning
- Chip TX power lift

**Fix:** HP SoftPaq sp155460 (Realtek BT, v1.10.1072.3000). Additionally:

- `HKLM\...\Services\BTHUSB\Parameters\EnableSelectiveSuspend = 0`
- Device-level `DeviceSelectiveSuspended = 0`, `IdleInWorkingState = 0`
- WLAN driver-level low-power flags **all set to 0** — these override the OS `powercfg` PCIe ASPM setting:
  - `PciASPM`, `bLowPowerEnable`, `bLPS_PG_En`, `bLPSTuningEnable`,
  - `bFwCtrlLPS`, `bProtectLps`, `bAdvancedLPs`, `bLeisurePs`

Range improved from 10cm → 30cm. Further improvement pending physical antenna check.

**Generalization for `network` / `drivers` modules:**
- On combo WiFi/BT cards, driver-level LPS settings on the WLAN kill BT range independently of OS power plan.
- Always cycle WLAN adapter after registry LPS changes — settings take effect at init only.
- The WLAN driver keys live at `HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}\<0000|0001|...>` — enumerate by `MatchingDeviceId` regex against `ven_10ec&dev_c822` etc.

## Problem 3 — Modern Standby wake failure

One "crash" was actually a hard freeze / power loss on 2026-07-03 12:20, no BSOD, no dump. Sequence:
1. 12:01 — lid closed → entered Modern Standby
2. 12:20:26 — `amduw23g` (Radeon driver) TDR'd during background wake
3. 12:20:32 — hard reset

**Fix:** switch lid-close to Do nothing, DC hibernate after 30 min. Never enter Modern Standby.

**Generalization for `power` module:**
- On Ryzen 6000 laptops with W11, `powercfg /a` shows S3 NOT available. Only S0ix (Modern Standby) and Hibernate.
- The `power` module should detect this platform and default to hibernate-on-timer instead of sleep.
- WHEA-Logger silence + Kernel-Power 41 with BugCheckCode=0 + `volmgr 161` = hallmark of a Modern Standby freeze, not a BSOD. Distinguish these from real bug-checks.

## Problem 4 — Services bloat

307 services on the machine at start. Categorized as:
- ~110 KEEP
- ~25 KEEP-FOR-YOU (specific apps: WSL2, Docker, OpenVPN, Apple Mobile Device, NVIDIA, Realtek BT, Task Scheduler)
- ~80 DISABLE-SAFE
- ~30 MAYBE

Cleanup: **107 services disabled** in one batch (89 DISABLE-SAFE + 18 MAYBE→disable after 4 grouped multi-select questions). Running services: 109 → 101. Disabled: 36 → 131.

**Generalization for `services` module:**
- Per-user services with random suffix (`_bd465` on this machine) cannot be disabled via `Set-Service` — they return "The parameter is incorrect". Must edit the TEMPLATE key (without suffix) directly: `HKLM:\SYSTEM\CurrentControlSet\Services\<TemplateName>\Start = 4`.
- `EntAppSvc` and `embeddedmode` return Access Denied via `Set-Service` but succeed via registry (still Administrator, not TrustedInstaller).
- Grouping MAYBEs into 4 multi-select questions (Peripherals, Networking, MS ecosystem, Extras) resolved all 30 MAYBEs in one round of Q&A.

## Problem 5 — Comet browser uninstall

winget uninstall exit 19 on first try (Comet was running). Retry after killing processes: no-op ("No installed package found") — first attempt actually succeeded, just returned nonzero because of the process being killed mid-uninstall.

**Generalization for `bloat` and `unused-apps` modules:**
- Always kill processes before winget uninstall.
- Trust the post-uninstall registry / Program Files check, not the winget exit code.

## Session artifacts (not committed — see `.gitignore`)

- `~/Desktop/services_audit.md` — full 540-line per-service categorization
- `~/Desktop/services_before_cleanup.csv` — pre-change snapshot for revert
- `~/Desktop/services_to_disable.txt` — the 107-item list applied
- `~/Desktop/cleanup_log.txt` + `cleanup_fix_log.txt` — apply audit trail
- `~/Desktop/wlan_powerkeys_backup.txt` + `wlan_powerkeys_restore.reg` — WLAN LPS revert
- `~/Desktop/bsod-dumps/` — 5 minidumps copied out of `C:\Windows\Minidump`
- `~/Desktop/symcache/` — cached Microsoft debug symbols

Each `*.md` module doc in `skill/modules/` should link back to the relevant section of this file for the "why" behind the module's defaults.
