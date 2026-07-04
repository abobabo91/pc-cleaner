# module: power

Tier: OPTIONAL by default; auto-runs on laptops if `profile.flags.isLaptop=true`. Skip on desktops unless user opts in via `--include power`.

Backed by the seed session — see `knowledge_base/session_2026-07-04_lenovo_slim7prox.md` (Problems 2, 3, and the WLAN LPS registry set that overrides `powercfg`).

## Success criteria

At the end of this module the user has:
1. `powercfg /export` of the active plan + `powercfg /a` + `powercfg /queryoverrides` in the snapshot.
2. PCIe ASPM disabled at the OS power plan (both AC and DC).
3. USB selective suspend disabled for Bluetooth radios (registry per-device), for combo WLAN/BT cards specifically.
4. Hibernate configured correctly for the platform (see profile branches below).
5. Lid-close behavior set sanely for Modern Standby platforms.
6. WLAN driver-level LPS flags all cleared if a combo WLAN/BT card is present (else these override `powercfg`).
7. A `revert.ps1`.

## Flow

### 1. Diagnose

Run `ps/diagnose/power.ps1`. Emits:
- `.activePlan.guid`, `.activePlan.name`
- `.availableSleepStates` — parsed from `powercfg /a`
- `.overrides` — from `powercfg /queryoverrides`
- `.aspm.ac`, `.aspm.dc` — parsed from `powercfg /q SCHEME_CURRENT SUB_PCIEXPRESS ASPM` (subgroup GUID `501a4d13-42af-4429-9fd1-a8218c268e20`, setting GUID `ee12f906-d277-404b-b6da-e5fa1a576df5`).
- `.usbSelectiveSuspend.ac`, `.usbSelectiveSuspend.dc`
- `.lidClose.ac`, `.lidClose.dc`
- `.hibernateOn` — `powercfg /a` mentions hibernate or not; `hiberfil.sys` present.
- `.hibernateType` — `full` / `reduced` / off (from `powercfg /h /type`).
- `.wlanLpsFlags[]` — enumerate `HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}\<N>` and read the LPS-related values from the seed session: `PciASPM`, `bLowPowerEnable`, `bLPS_PG_En`, `bLPSTuningEnable`, `bFwCtrlLPS`, `bProtectLps`, `bAdvancedLPs`, `bLeisurePs`. Emit path + name + current value + matchingDeviceId.
- `.bthusb.selectiveSuspend` — `HKLM:\SYSTEM\CurrentControlSet\Services\BTHUSB\Parameters\EnableSelectiveSuspend`.
- `.modernStandbyIncidents[]` — Event 41 kernel-power with BugCheckCode=0 in the last 30 d, matched against `volmgr 161` in same window. That's the fingerprint of a Modern Standby freeze (seed session Problem 3).

### 2. Categorize / decide

- **AUTO** — PCIe ASPM off both AC and DC (universally safe on any laptop; on desktops with USB audio interfaces it's ALSO the fix for USB dropout, so also apply if user opted in). USB selective suspend off for BT radios if a combo card is present.
- **AUTO if Modern Standby platform** — Lid close = Do nothing (AC), Hibernate (DC). Configure hibernate to trigger 30 min after idle on DC.
- **AUTO if combo WLAN/BT card detected** — clear all 8 WLAN LPS driver registry flags (seed session Problem 2 — they override the OS ASPM setting).
- **ASK** — Fast Startup on/off (some users need it off for dual-boot / diagnostics), `hiberfil.sys` disable entirely (frees ~40% of RAM in disk space), monitor sleep timeout.

### 3. Ask the user

**Plain-English rule: describe what the user experiences, not `powercfg` verbs or file names like `hiberfil.sys`.** Keep raw flag names (`HiberbootEnabled`, `LIDACTION`, LPS flag list) INTERNAL. Substitute actual GB numbers for hibernate-file sizes at ask time.

`AskUserQuestion`, `multiSelect: true`, ≤3 questions:

**Q1 — "Sleep and shutdown behavior — check what you want" (check all that apply)**
- Make the PC do a real, full shutdown when you click Shutdown (currently Windows does a hybrid shutdown that saves state; a real shutdown is a bit slower to boot but fixes many weird post-sleep bugs, and it's required if you dual-boot with Linux)
- Free up about X GB of disk space by removing hibernate entirely (you'll lose the ability to hibernate — sleep still works normally)
- Cut the hibernate file size roughly in half (~X GB freed, hibernate keeps working but resumes a bit slower)

**Q2 — "How long before the screen turns off and the PC sleeps?" (leave alone if the current settings feel fine)**
- Ask for preferred minutes for screen-off on battery / on charger
- Ask for preferred minutes for sleep on battery / on charger
- Or pick a preset

**Q3 — "When you close the lid, what should the laptop do?" (laptops only — check what you want)**
- On battery: go to Hibernate (safe long-term, doesn't drain the battery flat overnight)
- On charger: do nothing (the laptop keeps running — useful if you use it with an external monitor while the lid is closed)

### 4. Build plan JSON

```json
{
  "aspm": {"ac":"off","dc":"off"},
  "usbSelectiveSuspend": {"ac":"off","dc":"off","btRadiosOnly":true},
  "lidClose": {"ac":"nothing","dc":"hibernate"},
  "hibernate": {"enable":true, "type":"reduced"},
  "fastStartup": "off",
  "wlanLpsFlagsClear": true,
  "wlanRestartAdapter": true
}
```

### 5. Apply (elevated)

Call `ps/apply/power.ps1 -Plan <path> -SnapshotDir <path>`. It:
- Snapshots the active plan: `powercfg /export "<snapshotDir>\plan-active.pow" SCHEME_CURRENT` + `powercfg /a > sleep-states.txt` + `powercfg /queryoverrides > overrides.txt`.
- ASPM: `powercfg /setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0` + DC equivalent + `powercfg /setactive SCHEME_CURRENT`.
- USB selective suspend for BT: enumerate PnP BT radios and set per-device `HKLM:\SYSTEM\CurrentControlSet\Enum\<devInstPath>\Device Parameters\SelectiveSuspendEnabled = 0`. Also `HKLM:\SYSTEM\CurrentControlSet\Services\BTHUSB\Parameters\EnableSelectiveSuspend = 0`.
- Lid close: `powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0` (0=Do nothing) + DC to 2 (Hibernate).
- Hibernate: `powercfg /h on` OR `powercfg /h off`; type via `powercfg /h /type reduced`.
- Fast startup: `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power\HiberbootEnabled = 0`.
- WLAN LPS flags: for each of the 8 keys on each matching WLAN driver Class instance, set value to `0` (DWord/string per current type). Then `Disable-NetAdapter -Name <wlan>; Start-Sleep 3; Enable-NetAdapter -Name <wlan>` — LPS is read at init only.

### 6. Report

- What changed with reason.
- Whether user needs to reboot (fast startup change requires reboot; ASPM and USB selective suspend take effect on next PCIe / USB device init; WLAN LPS after the adapter cycle already done).
- Modern Standby incident count from the past 30 days, if any (with Event IDs). If >0 in the last week, explicitly point at the hibernate-only fallback fix.

## Known gotchas

- `powercfg /queryoverrides` shows kernel or driver overrides (e.g. `PROCESSOR_IDLE_DISABLE`) that will silently defeat your `powercfg` changes. Log these in the report as caveats — do not try to "fix" them, they're usually vendor tools.
- WLAN LPS registry set is at the CLASS level (`{4d36e972-...}`), not per-device Enum. Multiple keys under that class = multiple net drivers; grep `MatchingDeviceId` for the specific `ven_10ec&dev_c822` etc. Do not blast every subkey.
- After clearing WLAN LPS flags, the settings take effect only on adapter init. `Disable-NetAdapter; Enable-NetAdapter` triggers this. If you skip the cycle, changes look applied but aren't live.
- On Ryzen 6000 laptops, `powercfg /a` reports S3 as NOT available — only S0 Low Power Idle (Modern Standby) and Hibernate. Do NOT try to force S3 back on — the firmware doesn't support it. Hibernate-on-timer is the workaround.
- `powercfg /h off` frees `hiberfil.sys` (~40% of RAM) but disables Fast Startup AND removes hibernate as a state. Only offer with clear warning.
- `powercfg /h /type reduced` cuts hiberfil.sys roughly in half at the cost of slower resume. Better default than full-off.
- `HKLM:\SYSTEM\CurrentControlSet\Services\BTHUSB` may be protected on some builds — set-itemproperty succeeds but the value reverts on next boot. Diagnose after apply to confirm sticky.
- The Modern Standby fingerprint `Kernel-Power 41 BugCheckCode=0 + volmgr 161 nearby` (from seed session) is a HARD FREEZE not a bugcheck — do NOT go looking for a `.dmp`. Distinguish from real BSODs in `crashdumps` module.
- Some OEM tools (Lenovo Vantage, ASUS Armoury Crate, Dell Power Manager) re-apply their own PCIe ASPM and USB selective suspend settings on their own timer or at logon. If the user is using them, note that our changes may get reverted. Suggest disabling the OEM's power tuning if the user cares about our tune sticking.

## Curated defaults / Data files

- `data/wlan_lps_flags.json` — the 8 LPS driver value names from the seed session (`PciASPM`, `bLowPowerEnable`, `bLPS_PG_En`, `bLPSTuningEnable`, `bFwCtrlLPS`, `bProtectLps`, `bAdvancedLPs`, `bLeisurePs`), with target values (all `0`) and expected data type. Extend when a new Realtek/Intel chipset ships with new LPS knobs.
- `data/combo_cards.json` — known WLAN+BT combo cards by `VID_DID` — Realtek RTL8822CE / RTL8852BE / RTL8852CE, Intel AX210 / AX211, Qualcomm QCA6390 / WCN685X. If not in this list, treat as separate chips and skip the WLAN-LPS-affects-BT branch.

## Machine profile branches

- `profile.flags.isLaptop=false`: skip lid-close, skip DC values, skip battery-drain warnings. PCIe ASPM only if user opted in explicitly (desktops with USB audio DACs often benefit — but generic advice is: leave alone).
- `profile.flags.isRyzen6000Plus=true` OR `profile.flags.isModernStandbyOnly=true`: STRONGLY default Fast Startup off, hibernate on-timer at 30 min, lid-close on DC = hibernate. See seed session Problem 3.
- `profile.flags.hasComboWlanBt=true`: apply WLAN LPS flag clear. Otherwise skip (no BT-side benefit and unnecessary risk).
- `profile.system.manufacturer` in {Lenovo, HP, Dell, ASUS}: if `Get-Package` shows their vendor power tool installed, add "reverted by OEM tool" caveat to the report.
- `profile.wifi.subsystemId` OEM mismatch (`oemSubsystemMismatch=true`): flag that WLAN driver updates for this chip will NOT come from the OEM (Windows Update, OEM update tool). `drivers` module is where the fix lives — cross-reference.
