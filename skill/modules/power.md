# module: power

Tier: OPTIONAL by default; auto-runs on laptops if `profile.flags.isLaptop=true`. Skip on desktops unless user opts in via `--include power`.

Backed by the seed session — see `knowledge_base/session_2026-07-04_lenovo_slim7prox.md` (Problems 2, 3, and the WLAN LPS registry set that overrides `powercfg`).

## Success criteria

At the end of this module the user has:
1. `powercfg /export` of the active plan + `powercfg /a` + `powercfg /queryoverrides` in the snapshot.
2. PCIe ASPM disabled at the OS power plan (both AC and DC).
3. USB selective suspend disabled for Bluetooth radios (registry per-device), for combo WLAN/BT cards specifically.
4. Hibernate configured correctly for the platform (see profile branches below).
5. Lid-close behavior + idle-sleep behavior set per user answers.
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
- `.sleepIdleTimeout.ac`, `.sleepIdleTimeout.dc` — from `powercfg /q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE`.
- `.hibernateOn` — `powercfg /a` mentions hibernate or not; `hiberfil.sys` present.
- `.hibernateType` — `full` / `reduced` / off (from `powercfg /h /type`).
- `.wlanLpsFlags[]` — enumerate `HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}\<N>` and read the LPS-related values from the seed session: `PciASPM`, `bLowPowerEnable`, `bLPS_PG_En`, `bLPSTuningEnable`, `bFwCtrlLPS`, `bProtectLps`, `bAdvancedLPs`, `bLeisurePs`. Emit path + name + current value + matchingDeviceId.
- `.bthusb.selectiveSuspend` — `HKLM:\SYSTEM\CurrentControlSet\Services\BTHUSB\Parameters\EnableSelectiveSuspend`.
- `.modernStandbyIncidents[]` — Event 41 kernel-power with BugCheckCode=0 in the last 30 d, matched against `volmgr 161` in same window. That's the fingerprint of a Modern Standby freeze (seed session Problem 3).
- `.wlanLpsFlagsNonZero: bool` — any of the 8 flags on the WLAN card is non-zero → indicates the Bluetooth-range issue is likely.

### 2. Categorize / decide

- **AUTO** — PCIe ASPM off both AC and DC (universally safe on any laptop). USB selective suspend off for BT radios if a combo card is present. WLAN LPS flags cleared if a combo card is detected (seed session Problem 2). These are applied silently.
- **ASK-USER (per question)** — lid-close behavior, idle-sleep behavior, WLAN LPS clarification question (only if the range-issue signal is present).
- **ASK-USER (deferred / advanced)** — Fast Startup on/off, `hiberfil.sys` size (full vs reduced vs off). Currently these are handled via inference given the modern-standby platform; only offered as an override.

### 3. Ask the user, one at a time

**Plain-English rule: describe what the user experiences, not `powercfg` verbs or file names like `hiberfil.sys`.** Keep raw flag names INTERNAL. Substitute actual GB numbers for hibernate-file sizes at ask time. Use `AskUserQuestion` with `multiSelect: false` — one call per question.

---

**Q1 — Lid-close behavior**

> "When you close the laptop lid, what do you want to happen?"

Answers:
- `Nothing — keep running` (useful with external monitor + keyboard)
- `Turn off screen but keep running`
- `Sleep`
- `Hibernate`
- `I'm not sure`

*Skip if:* `profile.flags.isLaptop=false` (desktops don't have a lid).

*"I'm not sure" inference:*
- `profile.flags.isRyzen6kPlus=true` OR `profile.flags.isIntelIce11Plus=true` (Modern Standby platform) → `Hibernate` (Sleep is unreliable on these; seed session Problem 3).
- Older laptop (S3 supported) → `Sleep`.

*Controls:* `powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION <n>` where n is `0`=nothing, `1`=sleep, `2`=hibernate, `3`=shutdown. Both AC and DC get the same answer unless the user gave separate answers (default: same for both — but the "keep running" case is more common on AC than DC).

---

**Q2 — Idle sleep on battery**

> "On battery, if you don't use the laptop for a while, should it go to sleep or hibernate?"

Answers:
- `Sleep after 30 min`
- `Hibernate after 30 min`
- `Never sleep`
- `I'm not sure`

*Skip if:* `profile.flags.isLaptop=false` (no DC state).

*"I'm not sure" inference:* → `Hibernate after 30 min`. Safer default given Modern Standby issues on Ryzen 6000+ / Intel 11+ platforms; hibernate is battery-preserving and can't get stuck. On older S3-supported laptops → `Sleep after 30 min`.

*Controls:* `powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE <seconds>` (30 min = 1800), and if the answer is "hibernate", also set `HIBERNATEIDLE` at the same 1800 s and `STANDBYIDLE` at a slightly-lower value.

---

**Q3 — Bluetooth range fix**

> "I noticed your Bluetooth might have short range. Want me to fix a driver setting that improves it?"

Answers:
- `Yes`
- `No`
- `Explain more`

The `Explain more` branch prints: "Your WiFi and Bluetooth are on the same chip. There's a power-saving flag turned on that trades signal strength for battery life — it's the reason wireless mice / earbuds cut out at 3-4 feet. Turning it off costs a tiny bit of battery (~2%), gives you back the full range."

*Skip if:* `profile.flags.hasComboWlanBt=false` (not a combo card, no WLAN-LPS-affects-BT link).
*Skip if:* `.wlanLpsFlagsNonZero=false` (all flags already 0 — nothing to fix; already applied by AUTO or a previous run).

*"I'm not sure" inference:* If `hasComboWlanBt=true` AND any flag is non-zero → YES (the seed session confirms the fix restores usable BT range; the battery cost is negligible).

*Controls:* the 8 WLAN LPS driver registry values under `HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-...}\<N>` — `PciASPM`, `bLowPowerEnable`, `bLPS_PG_En`, `bLPSTuningEnable`, `bFwCtrlLPS`, `bProtectLps`, `bAdvancedLPs`, `bLeisurePs` — all set to `0`. Adapter cycle follows (`Disable-NetAdapter; Enable-NetAdapter`) — but batched via SKILL.md cross-module contract #3.

---

**Q4 — Fast Startup (optional / rarely asked)**

> "Windows uses a 'hybrid shutdown' where it saves system state when you click Shutdown, so it boots faster. Want a real full shutdown instead? (A bit slower to boot but fixes many weird post-sleep bugs, and required if you dual-boot with Linux.)"

*Skip if:* the user didn't ask for advanced power options (`--include power` alone doesn't ask this; requires `--include power --advanced` OR the `crashdumps` module already ran and flagged Modern Standby freezes).

*"I'm not sure" inference:*
- `.modernStandbyIncidents.count > 0` → YES (Fast Startup is a common contributor).
- Dual-boot detected (Linux entry in `bcdedit`) → YES.
- Otherwise → NO.

*Controls:* `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power\HiberbootEnabled = 0`.

---

### After all questions, show the decision summary

> **DEPRECATED under the batched orchestrator (SKILL.md, 2026-07-07).** In full `/pc-cleaner` runs, this per-module summary is absorbed into the unified plan preview — do NOT emit it. Kept below as reference for the single-module invocation `/pc-cleaner power` where a per-module summary still makes sense.

```
Power / sleep tweaks — here's what I figured out:

  PCIe power-save:              OFF (AC + DC)   (auto — universally safe)
  USB power-save for Bluetooth: OFF             (auto — combo card detected)
  Lid close:                    Hibernate       (auto: Ryzen 6000, Modern Standby)
  Idle on battery:              Hibernate 30 m  (auto: Modern Standby platform)
  Bluetooth range flags:        CLEARED         (auto — combo card + flags were on)
  Fast Startup:                 (not asked — not in advanced mode)

Reboot needed for lid-close change to fully stick.
Continue?  [Yes / No / Show me the list]
```

### 4. Build plan JSON

```json
{
  "aspm": {"ac":"off","dc":"off"},
  "usbSelectiveSuspend": {"ac":"off","dc":"off","btRadiosOnly":true},
  "lidClose": {"ac":"nothing","dc":"hibernate"},
  "idleSleep": {"acMinutes":0,"dcMinutes":30,"dcAction":"hibernate"},
  "hibernate": {"enable":true, "type":"reduced"},
  "fastStartup": "leave-alone",
  "wlanLpsFlagsClear": true,
  "wlanRestartAdapter": true
}
```

### 5. Apply (elevated)

Call `ps/apply/power.ps1 -Plan <path> -SnapshotDir <path>`. It:
- Snapshots the active plan: `powercfg /export "<snapshotDir>\plan-active.pow" SCHEME_CURRENT` + `powercfg /a > sleep-states.txt` + `powercfg /queryoverrides > overrides.txt`.
- ASPM: `powercfg /setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0` + DC equivalent + `powercfg /setactive SCHEME_CURRENT`.
- USB selective suspend for BT: enumerate PnP BT radios and set per-device `HKLM:\SYSTEM\CurrentControlSet\Enum\<devInstPath>\Device Parameters\SelectiveSuspendEnabled = 0`. Also `HKLM:\SYSTEM\CurrentControlSet\Services\BTHUSB\Parameters\EnableSelectiveSuspend = 0`.
- Lid close: `powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0` (or user's answer) + DC to 2 (Hibernate) — as per plan.
- Idle sleep: `powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 1800` (etc.).
- Hibernate: `powercfg /h on` OR `powercfg /h off`; type via `powercfg /h /type reduced`.
- Fast startup: only if plan requests it — `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power\HiberbootEnabled = 0`.
- WLAN LPS flags: for each of the 8 keys on each matching WLAN driver Class instance, set value to `0` (DWord/string per current type). Then adapter cycle (batched, see contract #3).

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

- `profile.flags.isLaptop=false`: skip Q1, Q2 (no lid, no DC). PCIe ASPM only if user opted in explicitly (desktops with USB audio DACs often benefit — but generic advice is: leave alone).
- `profile.flags.isRyzen6kPlus=true` OR `profile.flags.isIntelIce11Plus=true` (Modern-Standby-only): Q1 inference tips Hibernate, Q2 inference tips Hibernate. See seed session Problem 3.
- `profile.flags.hasComboWlanBt=true`: Q3 asked (if flags non-zero) OR AUTO-clear applied silently (if flags on AND user is in the fast path).
- `profile.system.manufacturer` in {Lenovo, HP, Dell, ASUS}: if `Get-Package` shows their vendor power tool installed, add "reverted by OEM tool" caveat to the report.
- `profile.wifi.subsystemId` OEM mismatch (`oemSubsystemMismatch=true`): flag that WLAN driver updates for this chip will NOT come from the OEM. `drivers` module is where the fix lives — cross-reference.
