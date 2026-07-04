# module: drivers

Tier: OPTIONAL. Auto-runs on laptops if `profile.flags.oemSubsystemMismatch=true` OR if any core-component driver is >18 months old. Otherwise opt-in.

Backed by seed session — see `knowledge_base/session_2026-07-04_lenovo_slim7prox.md` (Problem 1: Realtek RTL8822CE stuck at 2021 driver because Lenovo laptop had HP subsystem ID `103C`).

## Success criteria

At the end of this module the user has:
1. Snapshot of every PnP device's current driver (`Get-PnpDevice` + `pnputil /enum-drivers`) BEFORE change.
2. A table of stale drivers (age >18 months) on core components (WLAN, BT, GPU, chipset, audio, storage controller).
3. A table of OEM-vs-subsystem mismatches — where the machine's OEM won't push updates for that card because the card's subsystem vendor ID belongs to a different OEM.
4. For each stale/mismatched entry, a concrete download suggestion (URL to HP SoftPaq / Dell driver page / Lenovo download / Realtek WHQL / Intel WLAN / AMD Adrenalin) with version number and reason.
5. NEVER auto-installs a driver. Suggests only. The user runs the installer.
6. A `revert.ps1` — narrow scope: only rollback via `pnputil /delete-driver` if the user runs an install and wants to roll back a specific one.

## Flow

### 1. Diagnose

Run `ps/diagnose/drivers.ps1`. Emits:
- `.drivers[]` — one row per active driver: `deviceClass`, `deviceName`, `vid`, `did`, `subsysVid`, `subsysDid`, `revision`, `driverVersion`, `driverDate`, `provider`, `inf`, `signed`, `isMicrosoftGeneric` (provider = Microsoft AND deviceClass in critical set).
- `.oemInfo` — `.system.manufacturer` + `oem_pci_vendors.json` lookup → OEM VID.
- `.mismatches[]` — devices where `subsysVid != oemVid` AND the device class is one where subsystem is the routing key (WLAN, BT, audio, camera). Not for GPU (dGPU comes from NVIDIA/AMD directly; iGPU from the CPU vendor).
- `.stale[]` — drivers with `driverDate < today - 18 months` on device class in {`Net` (WLAN), `Bluetooth`, `Display`, `System` (chipset), `AudioEndpoint`/`Media`, `SCSIAdapter`/`SystemDevices` (storage controller), `Camera`}.
- `.msGeneric[]` — devices for non-generic hardware (WLAN, BT, audio) where the driver provider is Microsoft (means vendor driver never installed or was uninstalled). Seed session Problem 2 hit this — BT running on Microsoft `bth.inf`.
- `.crashCounts[]` — from `System` event log, WHEA and Kernel-Live-Dump events grouped by `Origin` module name over last 30 d. Cross-reference with `crashdumps` module output if that's run in the same session.

### 2. Categorize

For each candidate emit `{severity ("HIGH"|"MEDIUM"|"LOW"), category ("stale"|"mismatch"|"generic"|"crash-linked"), suggestedSource, suggestedVersion, downloadUrl, notes}`.

Never label as "AUTO-APPLY". This module is always suggestion-only.

- **HIGH** — crash-linked (driver appears in a WinDbg `!analyze -v` FAILURE_BUCKET_ID in last N dumps) OR OEM-subsystem mismatch on WLAN/BT combo card.
- **MEDIUM** — stale >24 months on any core component.
- **LOW** — stale 18-24 months, no crash link.

### 3. Ask the user

**Plain-English rule: describe what each chip DOES ("your WiFi + Bluetooth chip") and why we're pointing at a different brand's site ("your laptop's own updater can't reach it"), not chip model numbers or "subsystem mismatch."** Keep raw VID/DID/subsys IDs, SoftPaq numbers, and URLs in the INTERNAL plan JSON.

Single `AskUserQuestion` with `multiSelect: true`:

**Q1 — "I found some outdated drivers on this PC. Want me to look up fresh download links for you?" (I won't install anything — you'll get URLs to review and run yourself. Check all you want links for.)**

Each option, in plain English, should read like:

- "Your WiFi and Bluetooth chip — your laptop maker's usual updater can't reach this specific chip (it was made for a different laptop brand), so it's stuck on a 3-year-old driver. I found a fresher one on the actual chip maker's site." *(rank: HIGH)*
- "Your graphics card — driver is from 18+ months ago. There's a newer one on the graphics-card maker's site." *(rank: MEDIUM)*
- "Your laptop's sound chip — the current driver is generic Windows instead of the version from the maker of your speakers. Sometimes fixes crackle or missing bass features." *(rank: MEDIUM)*
- "Your chipset (the main circuitry) — driver is old; new one might fix random freezes." *(rank: LOW)*

The user checks what they want a link for. We do NOT install.

### 4. Build plan JSON

```json
{
  "reportOnly": true,
  "leads": [
    {"device":"Realtek RTL8822CE","source":"HP SoftPaq","spNumber":"sp162860","version":"2024.10.230.600","url":"https://ftp.hp.com/pub/softpaq/sp162501-163000/sp162860.exe","reason":"..."}
  ]
}
```

### 5. Apply (no elevation required — this module writes a Markdown report, does not install)

Call `ps/apply/drivers.ps1 -Plan <path> -SnapshotDir <path>`. It writes:
- `<snapshotDir>/drivers/report.md` — human-readable table with rank, reason, download URL, expected version.
- `<snapshotDir>/drivers/pnputil-enum-drivers.txt` — `pnputil /enum-drivers` snapshot for revert reference.
- `<snapshotDir>/drivers/revert.ps1` — instructions on how to `pnputil /delete-driver <oem##.inf> /uninstall /force` if a manual install breaks something, plus how to restore the pre-install driver from `pnputil` snapshot.

### 6. Report

Print the report.md to the run log. Explicitly say: "run these installers yourself, do NOT let Windows Update auto-install the older Microsoft-signed generic while you're at it — pause Windows Update for the day before installing."

## Known gotchas

- Subsystem ID vs vendor ID is the key insight. A Realtek RTL8822CE reports `VID_10EC&DEV_C822` (Realtek) but its `SUBSYS_85F7103C` says "HP-vendored variant." Lenovo's driver catalog matches on `SUBSYS_XXXX17AA` — it will never push an update for `_103C`. That means Lenovo Vantage, Windows Update, and Windows Optional Updates all show "current" while the card is running a 3-year-old driver. Fix: look at HP's SoftPaq catalog for the same VID/DEV.
- HP SoftPaqs live at `https://ftp.hp.com/pub/softpaq/sp<floor(N/500)*500+1>-<floor(N/500)*500+500>/spN.exe`. `sp162860` → `https://ftp.hp.com/pub/softpaq/sp162501-163000/sp162860.exe`. Encode this in `data/driver_sources.json`.
- Dell has a similar catalog under `https://dl.dell.com/FOLDER<n>/1/<file>.exe`. Not URL-derivable from a SoftPaq number — must scrape or curate.
- Lenovo: `https://download.lenovo.com/pccbbs/mobiles/<file>.exe`. Also not derivable.
- Realtek's public WHQL bundles are NOT the same as the OEM-tuned ones. OEM-tuned includes antenna coexistence tables specific to the laptop. Prefer OEM-source SoftPaq/driver over generic Realtek unless there's no OEM source.
- `pnputil /enum-drivers` returns all `oemXX.inf` staged drivers, not just active ones. Cross-reference with `Get-PnpDeviceProperty` to identify which oem##.inf is currently bound.
- After a driver install, the old driver stays staged. `pnputil /delete-driver oem##.inf /uninstall /force` after uninstalling the new one rolls back to the previous. Document per-device.
- Do NOT flash BIOS/UEFI here. SKILL.md forbids it. Point user at OEM's own firmware tool.
- Microsoft generic driver for a class-specific device (BT with `bth.inf`, WLAN with `netwlan.inf`, chipset with `machine.inf`) means the vendor's driver never took or was cleaned up. Reinstalling requires ordered dependencies (chipset first, then class driver, then peripheral). Note the ordering.
- If a device shows up multiple times under different subsystem IDs (docking station Ethernet vs onboard) treat them independently.
- Discrete GPU drivers on a MUX-off machine: sometimes the dGPU doesn't enumerate; `driverDate` is missing. That's expected — don't flag as "stale" unless the dGPU is present in `profile.gpu[]`.
- The Realtek `rtwlane.sys` name and Bluetooth `rtbtusb.sys` overlap: crash-linked WLAN often shows up in dumps as `rtwlane.sys` but the fix is a combo package that ships BOTH files. Suggest the combo installer, not just WLAN.

## Curated defaults / Data files

- `data/driver_sources.json` — array of `{oemVendorId, driverClass, sourcePriority: ["OEM-cross-vendor","Vendor-WHQL","OEM-native"], urlPattern, notes}`. Encodes HP SoftPaq URL derivation, known Dell/Lenovo/ASUS driver page anchors.
- `data/known_bad_drivers.json` — driver versions (by inf name + version) known to cause specific bugcheck codes. E.g. `rtwlane.sys 2024.0.10.223` → 0x133 DPC_WATCHDOG. When the diagnose script sees one of these on the machine, HIGH severity.
- `data/oem_pci_vendors.json` — see `profile.md`. Reused.

## Machine profile branches

- `profile.flags.oemSubsystemMismatch=true`: raise every mismatched-subsystem driver to at least MEDIUM. Include in the ASK question with clear callout.
- `profile.flags.hasComboWlanBt=true`: when suggesting a WLAN driver, ALWAYS suggest the combo package that also ships the BT driver — do not suggest WLAN-only. Cross-reference `power` module WLAN LPS flag clearing (needs redo after any WLAN driver install because installer re-populates the registry).
- Desktop (`profile.flags.isLaptop=false`): OEM-cross-vendor is less common (retail motherboards). Just focus on stale drivers from motherboard maker (ASUS/Gigabyte/MSI/ASRock) and GPU vendor.
- `profile.gpu[]` contains NVIDIA: prefer NVIDIA Studio driver on laptops with creator branding, Game Ready on gaming laptops. Detect via CPU suffix (`Creator Edition`, `H`/`HX` vs `HS`).
- `profile.gpu[].driverProvider` = AMD: prefer AMD Adrenalin over OEM-shipped AMD driver on desktop. On laptops with mux, some OEMs (Lenovo Slim Pro X) provide tuned AMD drivers — check the seed session's note.
- Windows Insider build (`profile.os.build` >= a threshold, or `HKLM:\SOFTWARE\Microsoft\WindowsSelfHost\Applicability\BranchName != ""`): warn that Insider drivers can differ, and OEM installers may refuse to install. Suggest with caveat.
