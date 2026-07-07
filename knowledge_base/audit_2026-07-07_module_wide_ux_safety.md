# Audit 2026-07-07 — Module-wide UX safety pass

## Trigger

After the BT pairing incident (see `incident_2026-07-07_bt_pairing_broken_by_services_module.md`), user asked for a full audit of every module to catch the same class of bug — anything that could break something a regular Windows user relies on daily. Every non-services module was audited.

## Findings summary

| Module | Risk before | Root cause | Fixed how |
|---|---|---|---|
| **storage** | HIGH | `apply/storage.ps1` ignored the `riskLevel:"ask"` field in `storage_sources.json` — Recycle Bin, Windows.old, memory dumps, and old Prefetch were deleted every run despite the schema saying "ask". | Runtime enforcement: refuse any source with `riskLevel:"ask"` unless plan entry has `"confirmed":true`. Emits `blocked-*.json` in snapshot dir. |
| **power** | MED | `lid_do_nothing` and `usb_selective_suspend_off` were applied silently on every laptop. Users lost the "close lid → sleep" default and battery to disabled USB power-save. | Added `promptRequired:true` + `promptText`/`promptOptions` to both recipes in `power_recipes.json`. `apply/power.ps1` refuses recipes with `promptRequired:true` unless `confirmed:true` in plan entry. |
| **network** | MED | SMBv1 / LLMNR / NetBIOS disabled on any plan flag; DNS override applied even with VPN active or captive-portal profile. | `apply/network.ps1` requires `<setting>Confirmed:true` for each of the 4 changes. DNS override additionally refused if a VPN adapter is Up (VPN name/desc pattern match) or `Get-NetConnectionProfile` shows a LocalNetwork profile. |
| **bloat** | MED | `Microsoft.XboxGamingOverlay` (and the Overlay/SpeechToText/Identity/TCUI family) in `safe` category — Win+G screenshots break for non-gamers who use it. Sticky Notes listed in both `safe` and `ask`. | Moved all Xbox overlay family from `safe` to `ask` in `bloat_uwp.json`. Removed duplicate Sticky Notes from `safe`. |
| **privacy** | MED | `recall` and `search_web` categories were in `apply_silently`. Silently disabled Windows Recall (users who enrolled on Copilot+ PCs) and Bing web results in Start search (users who search-web-from-Start). | Moved both to `ask_user` in `privacy_keys.json.notes`. `apply/privacy.ps1` refuses keys whose category is in `ask_user` unless `confirmed:true`. |
| **explorer** | MED | `TaskbarMn` (Chat/Teams icon) and `ShowTaskViewButton` (virtual desktops) applied silently despite the second's own note saying "Ask user". | Split into new `chat_ui` and `virtual_desktops` categories, both in `ask_user`. `apply/explorer.ps1` enforces `ask_user` categories require `confirmed:true`. |
| **defender** | MED | Path exclusions applied silently; a broad exclusion (Downloads, TEMP, %USERPROFILE%) would remove Defender from the exact locations malware lands. | Added `data/defender_dangerous_paths.json` with a refuse-list of 13 patterns (drive roots, Downloads, Desktop, Documents, TEMP, AppData family, ProgramData, WINDIR). `apply/defender.ps1` refuses matching exclusions unless `-IKnowWhatImDoing`. |
| startup, drivers, tray-taskbar, crashdumps, unused-apps, ninite | LOW | Already had tripwires + reversible + plan-gated. No changes needed. | n/a |

## The unifying pattern — the `confirmed:true` contract

Instead of ad-hoc gating logic per module, every apply script now enforces the same shape:

- Data JSON classifies entries as either "safe to apply" or "requires user confirmation" (either via `riskLevel`/`promptRequired`/`ask_user` category depending on module).
- Plan JSON entries in the "requires confirmation" bucket must carry `"confirmed": true`.
- Apply script refuses at runtime if that field is missing.
- `-IKnowWhatImDoing` overrides for scripted/testing use.
- Blocked entries are written to `<snapshot>/blocked-*.json` for orchestrator + user visibility.

This is principle #11 in SKILL.md.

## Smoke tests extended

`data/ux_smoke_tests.json` gained 4 new tests to catch these classes at runtime:

- **recycle_bin_exists** — `C:\$Recycle.Bin` still present after any storage apply.
- **windows_old_gate** — Windows.old still present (or was never present pre-run). Notes: needs pre-run snapshot to distinguish "user chose to delete" from "already gone".
- **lid_action_sane** — `powercfg /query SUB_BUTTONS LIDACTION` — FAIL if both AC and DC are 0 (silent do-nothing state). The seed machine currently FAILs this because user explicitly asked for lid=nothing on 2026-07-04 — that's a true positive for the general case.
- **dns_resolves** — Resolve-DnsName on `www.microsoft.com` succeeds. Catches DNS override to unreachable server, captive-portal poisoning, or VPN disruption.

`ps/verify/smoke.ps1` now supports probe types: `service_state_check`, `process_check_after_deep_link`, `path_check`, `powercfg_query`, `dns_query`.

## Design principle

Windows tuning tools should default to **"leave alone" for anything the user might notice**. The bar for silent application isn't "is this obscure?", it's "would a normal user, faced with this changed, spend ten seconds wondering why?". If yes → ask. If they can trivially undo it → still ask. Deep telemetry key that most users don't know exists → OK to apply silently. But anything that changes what the user sees, presses, uses, or expects — that's an ask. This was the pattern violation in every module flagged above.

## Files changed

- `data/bloat_uwp.json`
- `data/explorer_keys.json`
- `data/power_recipes.json`
- `data/privacy_keys.json`
- `data/ux_smoke_tests.json` (added 4 tests + new probe types)
- `data/defender_dangerous_paths.json` (NEW)
- `ps/apply/defender.ps1`
- `ps/apply/explorer.ps1`
- `ps/apply/network.ps1`
- `ps/apply/power.ps1`
- `ps/apply/privacy.ps1`
- `ps/apply/storage.ps1`
- `ps/verify/smoke.ps1`
- `skill/SKILL.md` (added principle #11)

Smoke test result on seed machine: 11/12 PASS. The 1 FAIL is `lid_action_sane` — true positive for the general case; the seed machine has lid=nothing because user explicitly asked for it on 2026-07-04 (pre-fix). Future runs on any machine will no longer silently reach this state.
