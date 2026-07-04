# module: drivers

Tier: OPTIONAL. Auto-runs on laptops if `profile.flags.oemSubsystemMismatch=true` OR if any core-component driver is >18 months old. Otherwise opt-in.

Backed by seed session — see `knowledge_base/session_2026-07-04_lenovo_slim7prox.md` (Problem 1: Realtek RTL8822CE stuck at 2021 driver because Lenovo laptop had HP subsystem ID `103C`).

## Success criteria

At the end of this module the user has:
1. Snapshot of every PnP device's current driver (`Get-PnpDevice` + `pnputil /enum-drivers`) BEFORE change.
2. A table of stale drivers (age >18 months) on core components (WLAN, BT, GPU, chipset, audio, storage controller).
3. A table of OEM-vs-subsystem mismatches — where the machine's OEM won't push updates for that card.
4. For each stale/mismatched entry, a concrete download suggestion (URL) with version + reason.
5. NEVER auto-installs a driver .exe. Downloads-then-user-runs; every suggestion is a download link to review.
6. A `revert.ps1` — narrow scope: instructions to `pnputil /delete-driver` if the user runs an install and wants to roll back.

## Flow

### 1. Diagnose

Run `ps/diagnose/drivers.ps1`. Emits:
- `.drivers[]` — one row per active driver: `deviceClass`, `deviceName`, `vid`, `did`, `subsysVid`, `subsysDid`, `revision`, `driverVersion`, `driverDate`, `provider`, `inf`, `signed`, `isMicrosoftGeneric` (provider = Microsoft AND deviceClass in critical set).
- `.oemInfo` — `.system.manufacturer` + `oem_pci_vendors.json` lookup → OEM VID.
- `.mismatches[]` — devices where `subsysVid != oemVid` AND the device class is one where subsystem is the routing key (WLAN, BT, audio, camera). Not for GPU (dGPU comes from NVIDIA/AMD directly; iGPU from the CPU vendor).
- `.stale[]` — drivers with `driverDate < today - 18 months` on device class in {`Net` (WLAN), `Bluetooth`, `Display`, `System` (chipset), `AudioEndpoint`/`Media`, `SCSIAdapter`/`SystemDevices` (storage controller), `Camera`}.
- `.msGeneric[]` — devices for non-generic hardware (WLAN, BT, audio) where the driver provider is Microsoft (means vendor driver never installed or was uninstalled).
- `.crashCounts[]` — from `System` event log, WHEA and Kernel-Live-Dump events grouped by `Origin` module name over last 30 d. Cross-reference with `crashdumps` module output if that's run in the same session.
- `.staleCount` — integer count of stale drivers for the introductory summary.

### 2. Categorize

For each candidate emit `{severity ("HIGH"|"MEDIUM"|"LOW"), category ("stale"|"mismatch"|"generic"|"crash-linked"), suggestedSource, suggestedVersion, downloadUrl, notes, plainEnglishDescription, oemRoutingExplanation}`.

Never label as "AUTO-APPLY". This module is always suggestion-only.

- **HIGH** — crash-linked (driver appears in a WinDbg `!analyze -v` FAILURE_BUCKET_ID in last N dumps) OR OEM-subsystem mismatch on WLAN/BT combo card.
- **MEDIUM** — stale >24 months on any core component.
- **LOW** — stale 18-24 months, no crash link.

### 3. Ask the user, conversationally

**Plain-English rule: describe what each chip DOES ("your WiFi + Bluetooth chip") and why we're pointing at a different brand's site ("your laptop's own updater can't reach it"), not chip model numbers or "subsystem mismatch."** Keep raw VID/DID/subsys IDs, SoftPaq numbers, and URLs in the INTERNAL plan JSON.

Use `AskUserQuestion` with `multiSelect: false` — one call per question.

---

**Q1 — Summary opt-in**

> "I found [N] drivers on your computer that haven't been updated in over 2 years. Want me to look for newer versions?"

Where N is `.staleCount`.

Answers:
- `Yes` — proceed with per-driver questions
- `No` — skip the module
- `Show me which ones` — print the table (device, current version, last date) then re-ask

*Skip if:* `.staleCount = 0` AND `.mismatches.count = 0` AND `.crashCounts` has no linked driver — nothing to offer.

*"I'm not sure" inference:* → YES if `.mismatches.count > 0` OR any HIGH-severity item exists. Otherwise → NO (drivers not-quite-current on a working machine isn't worth manually installing installers).

---

**Q2 through Q(1+K) — one question per HIGH / MEDIUM lead**

Per lead, generate a question tailored to its category. Sample templates below — the diagnose script picks the right one from `data/driver_sources.json` per lead:

**Q for OEM-mismatch WLAN/BT combo (Realtek-8822CE-style, seed session):**

> "Your WiFi + Bluetooth chip is from Realtek, but this laptop's usual updater doesn't cover it because of how [Lenovo] labeled the card. I can grab a fresh driver directly from [HP]'s website (they use the same chip). It'll be a normal installer — I'll download it and you double-click to install. Want me to?"

*Answers:* `Yes` / `No` / `Explain more`.

`Explain more` prints: "Every WiFi card carries a small 'subsystem ID' that tells manufacturers' update tools 'this card belongs to my catalog.' Your Realtek card has the HP subsystem ID (`103C`) even though the laptop is a Lenovo. So Lenovo Vantage skips it, Windows Update ships the older Microsoft generic driver, and the card stays on a 2021 driver forever. HP's SoftPaq catalog has the up-to-date driver for exactly this card. It'll install cleanly — same chip, same firmware format."

*"I'm not sure" inference:* → YES (this is the specific fix the seed session validated end to end).

*Controls:* `data/driver_sources.json` entry with `urlPattern` for HP SoftPaqs — resolve `spNNNNNN` to `https://ftp.hp.com/pub/softpaq/spNNN501-NNN000/spNNNNNN.exe`. Download to `<snapshotDir>/drivers/downloads/`, do NOT auto-run.

**Q for stale GPU driver:**

> "Your graphics card driver is from over 18 months ago. Newer versions often fix game crashes and video-playback issues. Want the direct download link from [NVIDIA / AMD / Intel]?"

*"I'm not sure" inference:* → YES if role_signals shows gamer, NO otherwise (silent stable driver is fine for office work).

**Q for stale audio driver (generic Windows instead of vendor):**

> "Your laptop's sound chip is running a generic Windows driver instead of the one from the sound-chip maker. This sometimes causes crackle, missing bass features, or Dolby Atmos not working. Want me to look up the vendor's version?"

*"I'm not sure" inference:* → YES if user has complained about audio (out-of-band signal — the diagnose script has no way to know; treat as NO by default).

**Q for stale chipset driver:**

> "Your chipset (the main circuitry that ties the CPU to everything else) has an old driver. New ones sometimes fix random freezes. Want the direct download link?"

*"I'm not sure" inference:* → YES if `.crashCounts` has any hits AND chipset driver is stale. Otherwise → NO.

---

### Rules for every driver question

- Show the human-readable device name and plain-English what-it-does.
- Show the current driver version + date and the newer available version.
- Show the source we're pointing at (HP / Lenovo / NVIDIA / Realtek WHQL) and the reason we picked that source.
- We NEVER auto-run any driver installer. The apply script downloads the file to the snapshot dir and prints the path with instructions to double-click.
- Never suggest BIOS/UEFI updates here — SKILL.md forbids.

### After all questions, show the decision summary

```
Driver suggestions — here's what I'll do:

  WiFi + Bluetooth chip:    DOWNLOAD  (auto: OEM mismatch, HP SoftPaq sp162860)
  Graphics driver:          DOWNLOAD  (you said yes)
  Audio driver:             SKIP      (you said no)
  Chipset:                  SKIP      (auto: no crash link)

I'll download 2 installers to <snapshot>/drivers/downloads/.
You run them yourself — I won't auto-install anything.
Continue?  [Yes / No / Show me the list]
```

### 4. Build plan JSON

```json
{
  "reportOnly": true,
  "leads": [
    {"device":"Realtek RTL8822CE","source":"HP SoftPaq","spNumber":"sp162860","version":"2024.10.230.600","url":"https://ftp.hp.com/pub/softpaq/sp162501-163000/sp162860.exe","reason":"OEM mismatch, seed session validated","downloadTo":"<snapshot>/drivers/downloads/sp162860.exe"}
  ]
}
```

### 5. Apply (no elevation required — this module writes a Markdown report + downloads installers; does not install)

Call `ps/apply/drivers.ps1 -Plan <path> -SnapshotDir <path>`. It writes:
- `<snapshotDir>/drivers/report.md` — human-readable table with rank, reason, download URL, expected version.
- `<snapshotDir>/drivers/downloads/<filename>.exe` — the downloaded installer for each lead the user approved. Never runs it.
- `<snapshotDir>/drivers/pnputil-enum-drivers.txt` — `pnputil /enum-drivers` snapshot for revert reference.
- `<snapshotDir>/drivers/revert.ps1` — instructions on how to `pnputil /delete-driver <oem##.inf> /uninstall /force` if a manual install breaks something.

### 6. Report

Print the report.md to the run log. Explicitly say:
- "The installer(s) are in `<snapshot>/drivers/downloads/`. Double-click to install. I did NOT auto-run them."
- "Pause Windows Update for a day before installing — Windows may push the older Microsoft generic driver over your fresh one otherwise."

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
- `data/known_bad_drivers.json` — driver versions (by inf name + version) known to cause specific bugcheck codes.
- `data/oem_pci_vendors.json` — see `profile.md`. Reused.

## Machine profile branches

- `profile.flags.oemSubsystemMismatch=true`: raise every mismatched-subsystem driver to at least MEDIUM. Include in Q2+ with clear callout.
- `profile.flags.hasComboWlanBt=true`: when suggesting a WLAN driver, ALWAYS suggest the combo package that also ships the BT driver. Cross-reference `power` module WLAN LPS flag clearing (needs redo after any WLAN driver install because installer re-populates the registry).
- Desktop (`profile.flags.isLaptop=false`): OEM-cross-vendor is less common (retail motherboards). Focus on stale drivers from motherboard maker (ASUS/Gigabyte/MSI/ASRock) and GPU vendor.
- `profile.gpu[]` contains NVIDIA: prefer NVIDIA Studio driver on laptops with creator branding, Game Ready on gaming laptops.
- `profile.gpu[].driverProvider` = AMD: prefer AMD Adrenalin over OEM-shipped AMD driver on desktop. On laptops with mux, some OEMs (Lenovo Slim Pro X) provide tuned AMD drivers — check the seed session's note.
- Windows Insider build: warn that Insider drivers can differ, and OEM installers may refuse to install. Suggest with caveat.
