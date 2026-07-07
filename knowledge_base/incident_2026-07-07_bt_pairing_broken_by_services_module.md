# Incident 2026-07-07 — Bluetooth pairing broken by services module

## Summary

A user reported "Bluetooth doesn't work at all" two days after running pc-cleaner CORE (services, startup, bloat, privacy, explorer, storage) on the seed machine on 2026-07-05. Investigation on 2026-07-07 found:

- Radio + driver: **fine** (Realtek Bluetooth 5 Adapter OK, driver `1.10.1072.3000` installed by session on 2026-07-01).
- Already-paired devices: **fine** (Logi Z607 speaker showed OK, `Logi Z607 Avrcp Transport` present).
- **Broken specifically:** clicking "Add device → Bluetooth" in Settings caused the wizard window to appear and instantly close. Clicking the arrow next to Bluetooth in Quick Settings → "Manage Bluetooth devices" did nothing.

Root cause: the services module disabled **7 services** that back the Windows 11 "Add device" wizard, under questions that named unrelated features.

## The seven services disabled and why each hurt

| Service | Question that killed it | What it actually backed |
|---|---|---|
| `fdPHost` | Q6 "Do you ever cast your screen wirelessly to a TV, or play music to a wireless speaker?" — user said No | **The discovery back-end for the entire Windows 11 "Add device" wizard** — including BT, WSD network printers, DLNA, Miracast. This was the main culprit. Without it the wizard has no way to enumerate devices and closes silently. |
| `SSDPSRV` | Same Q6 | UPnP media renderer discovery, but also participates in some BT+WiFi pairing flows. |
| `WFDSConMgrSvc` | Same Q6 | Wi-Fi Direct connection manager. Backs Miracast + some BT/WiFi handoff during pairing. |
| `FDResPub` | `services_disable_safe.json` `legacy_networking` category — no question asked, just default-disabled | Outgoing device advertisement so THIS PC appears in other devices' pair lists. |
| `upnphost` | Same — `legacy_networking` category, default-disabled | UPnP device host. |
| `NcdAutoSetup` | `enterprise_mdm` category — assumed enterprise-only | Wireless device onboarding (WPS-adjacent flows, Xbox controller pairing). |
| `PhoneSvc` | Not tracked in data files — Claude runtime call under Q11 (Copilot) | Bluetooth hands-free profile (any BT audio device with a mic). |
| `MessagingService` | `windows_features_off_by_default` — labeled "SMS/messaging (Phone Link)" | Phone Link SMS relay AND MMS attachments. Users don't map "do I use Copilot" to "SMS relay works". |
| `CDPSvc` | Never listed in data files — Claude runtime call under Q11 | Nearby Sharing + Quick Assist + Phone Link discovery + BT pairing wizard's cross-device components. |
| `MapsBroker` | `windows_features_off_by_default` — labeled "Downloaded Maps" | Also backs Cortana/Copilot location, Weather app location detection, Photos map view. |

Two failure classes are visible here:

1. **Single-question kills multi-flow service.** Q6 asked about casting but the `Controls` line listed `fdPHost`/`SSDPSRV`/`WFDSConMgrSvc` — services that back many other UX flows including BT pairing. The question flow assumed one service = one feature.
2. **Blind category disable.** `legacy_networking` (`FDResPub`, `upnphost`) and `enterprise_mdm` (`NcdAutoSetup`) and `windows_features_off_by_default` (`MapsBroker`, `MessagingService`) had no per-item question at all. They were disabled by default on every run.

## What we changed

- **`data/services_tripwire.json`** — schema extended to `{ reason, backs: [...], addedAt, incident }`. Every service in the table above (plus `AppXSvc`, `StateRepository`, `TokenBroker`, `WpnService`, `WSService`, `LicenseManager`, `DeviceAssociationService`) added to tripwire.
- **`data/services_disable_safe.json`** — removed `NcdAutoSetup` from enterprise_mdm; removed `FDResPub`, `upnphost`, `wcncsvc` from legacy_networking (renamed to `legacy_p2p` — only truly obsolete P2P protocols); removed `MapsBroker`, `MessagingService` from windows_features_off_by_default.
- **`data/ux_smoke_tests.json`** — NEW. Eight tests: BT pairing wizard, Add printer, Settings launches, Start search, notifications, MS account sign-in, Store app launch, audio device switch. Each names required services + remediation.
- **`ps/verify/smoke.ps1`** — NEW. Runs the smoke tests, returns JSON to the orchestrator.
- **`ps/apply/services.ps1`** — added runtime tripwire enforcement (refuses to disable any tripwire name regardless of plan JSON, unless `-IKnowWhatImDoing`). Auto-invokes smoke test after apply.
- **`ps/diagnose/services.ps1`** — handles both legacy string and new object tripwire schemas. Emits `Backs` field per service.
- **`skill/modules/services.md`** — new "Hard rule: never disable a tripwire service" section at top. Q6 Controls updated to note nothing is disabled based on the answer anymore. Q11 Controls stripped of the fuzzy "plus per-user Mail/Calendar template services" wording.
- **`skill/SKILL.md`** — added principles 9 (Hidden UX dependency rule) and 10 (Post-apply UX smoke test). Orchestration flow step 7 now runs the smoke test between apply and benchmark-after.

## Remediation script that was used on the seed machine

`Desktop\fix-bluetooth.ps1` on 2026-07-07 — set the 7 services to Manual, started the 4 discovery ones (`fdPHost`, `FDResPub`, `SSDPSRV`, `upnphost`), restarted `bthserv`. After that the wizard opened normally.

## Detection playbook for future incidents

Symptom: "Settings > Bluetooth > Add device → window closes silently" OR "arrow next to BT in Quick Settings does nothing" after any tuning tool ran.

```powershell
Get-Service fdPHost, FDResPub, CDPSvc, NcdAutoSetup, SSDPSRV, upnphost, PhoneSvc, WFDSConMgrSvc, bthserv, DeviceAssociationService, AppXSvc, StateRepository |
  Format-Table Name, Status, StartType -AutoSize
```

If any of the first 8 are `Disabled`, that's the cause. Fix by setting to Manual and starting the discovery ones.

## Principle to remember

Windows service names look like they map 1:1 to features. They don't. Many services back multiple unrelated UX flows and there's no in-Windows way to see the reverse dependency map. Any tuning tool that lets a single-feature question decide a service's fate will break something the user wasn't asked about. Tripwire + hidden-deps schema is the only durable defense.
