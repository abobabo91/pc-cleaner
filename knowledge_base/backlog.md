# Backlog — data files and known unknowns

Tracked here so they don't fall off. Not a plan, just a punch list.

## Missing data files (module docs reference these — need to be created)

Grouped by module. Some are simple JSON extracts of existing knowledge; some need research.

### profile
- `cpu_generations.json` — regex catalog: Ryzen (\d)\d{3} etc. Include Intel Core i\d-1[1-4]\d{3} for Modern-Standby generation detection.
- `oem_pci_vendors.json` — subsystem vendor code → OEM name (103C=HP, 17AA=Lenovo, 1028=Dell, 1043=ASUS, 1462=MSI, 1458=Gigabyte, 10DE=NVIDIA, 8086=Intel, 10EC=Realtek). Partially inlined in profile.ps1 — extract to JSON.

### startup
- `startup_disable_safe.json` — well-known bloat autostarts by exe/registry name (Adobe ARM Updater, CCleaner tray, Spotify web helper, etc.).
- `startup_tripwire.json` — never disable (OneDrive, Docker Desktop, cloud-drive daemons the user depends on, security software).
- `startup_role_hints.json` — heuristics to detect user's role from installed autostarts (Docker → dev, Adobe → creative, Steam → gamer).

### bloat
- `bloat_winget.json` — non-UWP winget IDs to flag (McAfee WebAdvisor, Norton, ESET trial, WildTangent games, Candy Crush classic, HP Support Assistant if not Lenovo). Complement to `bloat_uwp.json`.

### explorer
- `explorer_keys.json` — registry tweaks for Win11 UI: classic right-click, taskbar align, Search style, Widgets remove, dark mode default.
- `explorer_conflicts.json` — settings the classic-menu override conflicts with on 24H2 (StartAllBack, ExplorerPatcher installed → skip).

### storage
- `storage_sources.json` — cleanup targets with default risk: %TEMP% (auto), Prefetch (skip if unused-apps ran), Delivery Optimization cache (auto), Windows.old (ask; may be big), Windows Update download cache (auto).

### power / network / drivers
- `wlan_lps_flags.json` — Realtek WLAN registry keys to zero out for combo-card BT range (already inlined in `knowledge_base/session_2026-07-04_...md`; extract).
- `combo_cards.json` — WLAN chips that share antenna with a BT radio: RTL8822CE, RTL8852BE, MediaTek MT7921, Intel AX200/AX201/AX211.
- `dns_providers.json` — Cloudflare 1.1.1.1, Quad9 9.9.9.9, Google 8.8.8.8 with DoH endpoints.
- `network_riskyFeatures.json` — SMBv1, NetBIOS over TCP, LLMNR — safe to disable.
- `driver_sources.json` — per-OEM SoftPaq URL pattern: HP ftp.hp.com/pub/softpaq/spN-500-spN/spN.exe, Lenovo, Dell, ASUS.
- `known_bad_drivers.json` — driver files with known issues at specific versions (e.g. `rtwlane.sys < 2024.10.230.600` on 8822CE).

### defender
- `dev_cache_paths.json` — canonical dev toolchain cache paths worth excluding.
- `repo_scan_roots.json` — where to look for user git repos (Desktop, Documents, C:\dev, ~/src, ~/code).

### crashdumps
- `known_drivers.json` — common .sys → owner mapping (rtwlane → Realtek WiFi, amduw23g → AMD Radeon, nvlddmkm → NVIDIA display).
- `bugcheck_codes.json` — bug check code → human-readable meaning (0x133 → DPC_WATCHDOG_VIOLATION, etc.).
- `sdk_urls.json` — current Windows SDK installer URL. Rot-prone. Refresh monthly.

### tray-taskbar
- `known_tray_apps.json` — common tray icons the user might or might not want visible.
- `taskbar_default_pins.json` — Win11 default pins to distinguish "OEM added" from "user pinned".

### ninite-personalized
- `ninite_bundles.json` — per role (dev / creative / gamer / office / student) list of winget IDs to suggest.
- `role_signals.json` — installed apps that identify a role (Docker/VSCode → dev, Photoshop → creative, Steam → gamer).

### unused-apps
- `unused_apps_never.json` — apps that get low usage but should NOT be flagged (OneDrive, Discord, VPN clients, security agents).
- `silent_uninstall_flags.json` — winget uninstall flags known to work reliably per publisher.

## New gaps flagged by data-file agent (2026-07-04)

- **`storage_conflicts.json`** — user may already run CCleaner / Wise Disk Cleaner with its own scheduled Prefetch/Temp sweeps. Our auto-purge could fight it. Analogous to `explorer_conflicts.json`.
- **`modern_standby_overrides.json`** — some Lenovo Ideapad SKUs expose S3 via BIOS setting. Power module currently branches purely on CPU gen; small mfg+model override list would prevent applying DC-sleep-never on machines where the user flipped BIOS to S3.

## Uncertainty flags from data-files agent round 2 (2026-07-04)

Verify these at runtime; do not trust the data file value blindly.

- **NVIDIA `nvlddmkm.sys` min-good-version** — no specific known-bad version pinned; placeholder in `known_bad_drivers.json`. Real answer varies by GPU generation.
- **Intel RST `iaStorAC.sys` min-good** — 17.11 estimate; real threshold varies by PCH.
- **HP SoftPaq bucket boundaries** (`sp{lower}-{upper}` in `driver_sources.json`) — verified for the current 500-range HP uses, but historically HP has shifted bucket sizes.
- **Windows SDK fwlink `2286561`** — verified working 2026-07-04. `sdk_urls.json` has `verifyMonthly: true` flag + refresh instructions; the crashdumps apply script must fall back to `winget install Microsoft.WindowsSDK` if the URL 404s.
- **`ShowCopilotButton` registry key name in `explorer_keys.json`** — Microsoft has renamed the Copilot toggle multiple times across 23H2/24H2/25H2. Probe the current value name at runtime before writing.
- **Various winget IDs in `ninite_bundles.json`** — `Microsoft.Office` vs `Microsoft365.Apps`, `TheDocumentFoundation.LibreOffice` vs `LibreOffice.LibreOffice`, `DarkTable.DarkTable` casing, NVIDIA App vs GeForce Experience — marked with `verify:` fields; resolve at runtime by trying the primary, falling back to alternates.
- **BIOS S3 opt-in list in `modern_standby_overrides.json`** — labeled `_bestEffort`. Module must always defer to live `powercfg /a` at runtime; the list is a hint about which machines have a BIOS knob at all.
- **`taskbar_default_pins.json` programmatic unpin on 24H2** — fragile (documented in the file's `_apiRisk` field). Matches the tray-taskbar module doc's warning about undocumented `FavoritesResolve` blob.

## Known unknowns (agent flagged)

- **tray-taskbar pinned-app manipulation on Win11 24H2**: Microsoft moved the pins to a binary blob (`FavoritesResolve` or newer format). Undocumented, changes between builds. Fallback plan documented but may need a native COM helper (`IPinnedListManager`) that PowerShell can't cleanly reach on all builds.
- **explorer classic right-click menu**: the `{86ca1aa0-...}` empty InprocServer32 override is threatened by Microsoft. Add runtime probe: after apply, verify it worked, roll back automatically if the user's shell doesn't respect it.
- **Windows SDK Debuggers download URL**: fwlink IDs rot. `sdk_urls.json` needs monthly refresh, or check `winget install Microsoft.WindowsSDK --version-preference newest` as a fallback.

## Not yet implemented (PS scripts)

Diagnose scripts written: services, startup, bloat, privacy, profile, benchmark.
Diagnose scripts still to write: explorer, storage, power, network, drivers, defender, crashdumps, tray-taskbar, ninite-personalized, unused-apps.

Apply scripts written: services, startup, bloat, privacy.
Apply scripts still to write: explorer, storage, power, network, drivers, defender, crashdumps, tray-taskbar, ninite-personalized, unused-apps.

Top-level orchestrator script (`ps/pc-cleaner.ps1` or driven directly from SKILL.md) — TODO.
