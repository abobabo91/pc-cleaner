# BSOD 0x133 DPC storm on Ryzen 6000 + VBS-on (Lenovo Slim 7 ProX 14ARH7)

Investigated 2026-07-01, second wave 2026-07-16, root cause found 2026-07-17. 16+ BSODs since Feb 2024, cluster of 4 in three weeks.

Continues the crash investigation started in [`session_2026-07-04_lenovo_slim7prox.md`](session_2026-07-04_lenovo_slim7prox.md) ("Problem 1 — Recurring BSODs"), which blamed `rtwlane.sys` from the dump signatures alone. That was the wrong conclusion, for the reason given below: in this crash class the blamed driver rotates. LatencyMon settled it — the real load is Hyper-V/VBS, and the WiFi adapter was only a contributor.

## Signature that identifies this class

Multiple 0x133 DPC_WATCHDOG_VIOLATION crashes where **`!analyze -v` blames a different driver each time**. If you see 3+ 0x133s in the same month with different `MODULE_NAME`s pointing at AMD platform drivers or Microsoft hypervisor bits — it's this, not any single driver.

Confirmed pattern from `C:\Windows\Minidump\` on this machine:

| Date | BUCKET | Blamed module |
|---|---|---|
| 2026-06-28 | `0x133_DPC_dxgmms2!VidSchiUnwaitMonitoredFences` | dxgmms2.sys (DX graphics MM) |
| 2026-07-01 | `0x133_DPC_amdacpbus!unknown_function` | amdacpbus.sys (AMD audio co-processor bus) |
| 2026-07-11 | `0x133_DPC_winhvr!WinHvpProcessSignalBitsetMessage` | winhvr.sys (Hyper-V VMBus root) |
| 2026-07-16 | `0x133_ISR_amdgpio2!unknown_function` (P1=1 → ISR storm) | amdgpio2.sys (AMD GPIO) |

Also seen: `0x139 KERNEL_SECURITY_CHECK_FAILURE (LIST_ENTRY)`, `0x7E SYSTEM_THREAD_EXCEPTION_NOT_HANDLED` — same wave, same cause.

## Why the culprit is not the blamed driver

0x133 P1=0 fires when a single DPC exceeds its individual watchdog window (~20s). P1=1 fires when accumulated DPC time across all drivers exceeds the periodic watchdog window (default 1.28s of DPC time in a 8s interval). If the platform's interrupt scheduling is starved (bad AGESA microcode + hypervisor overhead), whoever happened to be running when the timer fired takes the blame. AMD chipset drivers + winhvr.sys are the most frequent "wrong place, wrong time" losers because they run hot.

No WHEA events accompany these — so hardware (CPU / RAM / PCIe) is not reporting errors. This is firmware/software.

## Diagnosis workflow (30s)

Non-elevated PowerShell:

```powershell
# 1. All bugchecks from event log
Get-WinEvent -FilterHashtable @{LogName='System'; ID=1001; ProviderName='Microsoft-Windows-WER-SystemErrorReporting'} -MaxEvents 20 |
    Select-Object TimeCreated, @{n='Msg';e={($_.Message -split "`n")[0..1] -join ' '}} | Format-List

# 2. VBS state — if =2, hypervisor is up
Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard |
    Select-Object VirtualizationBasedSecurityStatus
```

Elevated (for actual `!analyze -v`):
1. Copy dumps out of `C:\Windows\Minidump\` (ACL-locked) with elevated `copy`, or
2. Run `cdb.exe -z <dump> -c "!analyze -v; q"` via `Start-Process -Verb RunAs`. WinDbg install path: `C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\`.

For headless analysis of multiple dumps, wrap in a `.cmd`, redirect to `.txt`, launch elevated once. (A `tools/bsod-analysis-helper/` was mentioned as a possible home for that wrapper on 2026-07-16; it was never created — write the `.cmd` inline.)

## Fix (in order)

**IMPORTANT — verified 2026-07-16**: For this specific machine (Slim 7 ProX 14ARH7 82V2 + Ryzen 9 6900HS), the "obvious updates" are dead ends. Verify each of these is genuinely stale BEFORE recommending; the pcsupport.lenovo.com API confirms `JVCN40WW` (Feb 2024) is the **final BIOS Lenovo shipped for 82V2** — no successor was ever released. `download.lenovo.com/consumer/mobiles/jvcn40ww.txt` shows the release notes: D-Notify persistence + CPU security CVEs, nothing DPC-related. AMD Chipset `8.05.04.516` is also the current amd.com release — check `Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*` filtered on AMD Chipset before assuming it's stale.

Actual usable fix order once "just update it" is ruled out:

1. **LatencyMon** (free from resplendence.com, signed by Daniel Terhell — SHA256 `D4E472879954380F5FBC49E2D5BE8C5DBD75D5CF8908DD77278472598C6D17AF` as of 7.31). Run 10 min under normal load, check Drivers tab sorted by "Highest measured interrupt to process latency". Identifies the actual DPC hog — the surgical diagnosis instead of guessing.
2. **PCIe LSPM Off** — Power Options → PCI Express → Link State Power Management → Off. Note: High Performance scheme has this Off by default; only useful on Balanced.
3. **USB selective suspend disabled** + **WiFi power management disabled** — two known DPC-latency workarounds on Ryzen 6000 laptops. Easily reversible via powercfg + `Set-NetAdapterAdvancedProperty`.
4. **`mdsched.exe` overnight** — 0x139 LIST_ENTRY (P1=0xA) in the same crash wave is a memory-integrity signal; hardware fatigue is not ruled out by WHEA absence.
5. **If Docker Desktop / WSL2 / Windows Sandbox / HVCI is NOT used**: turn off VBS + Memory Integrity. Removes hypervisor overhead. **Skip if any of the above are in use** — Docker Desktop requires VBS. Confirmed 2026-07-16: user runs Docker, so this is not an option.

**What NOT to recommend on this machine (confirmed dead ends 2026-07-16)**:
- BIOS update via Vantage (final release already installed)
- AMD Chipset Software from amd.com (already latest at 8.05.04.516)
- Realtek WiFi driver update via Lenovo (installed 2024.10.230.600 dated 2025-06 is what Lenovo ships)

## Actual root cause identified 2026-07-17 via LatencyMon

Three LatencyMon runs confirmed:
- **rtwlane.sys** (Realtek WiFi) → 63 µs peak DPC, 18 ms total in 7 min → **not the culprit**
- **vmswitch.sys** (Hyper-V vSwitch) → 39 µs peak DPC → **not the culprit**
- **winhvr.sys** (Hyper-V root) → **22,473 ms total DPC in 7 min = 4.9% of one CPU dedicated to Hyper-V baseline overhead**
- **vmbusr.sys** → 485k DPCs / 7 min = 1,062 DPCs/s of virtual-bus chatter
- **ndis.sys** → 17.8 ms peak when it batches queued packets under Docker+VBS load

**Root cause: sustained high DPC pressure from Docker Desktop + WSL2 + VBS on Ryzen 6000, occasionally spiking into DPC watchdog crashes.** Neither BIOS nor chipset can fix this because VBS + Hyper-V is inherent to running Docker Desktop.

### Fixes applied 2026-07-17

WiFi ISR-storm side (killed the 07-16 crash type):
- `Set-NetAdapterAdvancedProperty` on Realtek RTL8822CE:
  - `*WakeOnMagicPacket=0`, `*WakeOnPattern=0` → no wake-event ISR bursts
  - `RegROAMSensitiveLevel=127` → roaming disabled, no scan DPCs
  - **Kept**: `ARPOffloadEnable=1`, `GTKOffloadEnable=1`, `NSOffloadEnable=1` — disabling these made the DPC side WORSE (radio firmware offload was actively reducing per-packet CPU work; keep enabled)
- Registry `HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-...}\<idx>\PnPCapabilities = 0x118` → OS can't power down Realtek adapter → no PCI resume DPCs

Docker/WSL2 DPC-storm side:
- Defender exclusions added (8 paths, 16 processes): Docker Desktop dirs, WSL2 Ubuntu VHDX package dirs, all `com.docker.*` and `wsl*` process names. Kills `vmmemwsl` hard-pagefault storm (was top pagefault process).
- `%USERPROFILE%\.wslconfig` written with `memory=8GB, processors=8, swap=4GB, autoMemoryReclaim=gradual, sparseVhd=true`. Caps WSL2's resource ceiling.
- `wsl --shutdown` to apply.

### Verification workflow after applying fixes

1. Wait 1–2 weeks. Check `Get-WinEvent -FilterHashtable @{LogName='System';ID=1001;ProviderName='Microsoft-Windows-WER-SystemErrorReporting'} -MaxEvents 5`. Ideally zero new bugchecks.
2. Re-run LatencyMon 10 min under normal Docker load. Expected: `vmmemwsl` should NOT be top pagefault process anymore; `winhvr` total DPC time should drop; `ndis.sys` peak DPC should stay below 5 ms.
3. If bugchecks continue: `mdsched.exe` overnight to rule out RAM (0x139 crashes in the historical set aren't DPC-related, could be memory).

## Verification

After each round of fixes, wait 1–2 weeks and re-check `Get-WinEvent ID 1001`. Zero new bugchecks = fixed.

If new dumps show the SAME single driver 3 times in a row, THAT driver is the real cause (unlike this class where the blame rotates).
