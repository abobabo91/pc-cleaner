# Incident 2026-07-08 — iPhone silently invisible in iTunes after services module

## Summary

The pc-cleaner author ran the tool on their own Windows 11 machine some time before 2026-07-08. On 2026-07-08 they discovered that plugging their iPhone in no longer surfaced it in iTunes. The phone charged normally, the "Trust this computer?" prompt no longer appeared, no error message anywhere. The tool's other modules were unaffected — this class of failure is silent.

- USB stack: **fine** (WinUsb / usbhub / USBHUB3 all running Manual, the phone charges).
- Apple Mobile Device Service (AMDS): **fine** — Running / Automatic, not touched.
- **Broken specifically:** `Bonjour Service` was Stopped + **Disabled**, and `StiSvc` (Windows Image Acquisition) was Stopped + **Disabled**. iTunes' device-discovery path goes through Bonjour + AMDS, and iOS-over-USB imaging goes through WIA — both dependencies dead.

Root cause: **two independent code paths disabled hidden-UX-dep services under questions that never named iPhone / iTunes.**

## The two services disabled and why each hurt

| Service | Path that killed it | What it actually backed |
|---|---|---|
| `StiSvc` (Windows Image Acquisition) | `services_disable_safe.json` → `printer_scanner` category. Q1 asked "Do you print documents or scan things from this computer?" — user answered NO. StiSvc was labeled "scanner/camera" only. | iOS devices expose themselves as **imaging devices** on Windows. The iTunes / Explorer "iPhone appears when you plug it in" pipeline uses the WIA stack. No WIA → no iPhone. Also backs its documented scanner-button-event role. |
| `Bonjour Service` (Apple mDNS) | `network_risky_features.json` → `mDNS_Bonjour` entry, described as "redundant since Windows 10 20H1+ has native mDNS". Silently disabled during whatever code path invoked it (network module or ad-hoc — the disable command in the JSON matches the observed state). | iTunes device-discovery and Home Sharing use Bonjour, NOT native Windows mDNS. Native mDNS covers AirPrint / AirPlay for Windows→Apple discovery, but the iTunes+iPhone direction goes through Bonjour service + AMDS. Also breaks Adobe Creative Cloud device presence and any third-party dev tools that speak mDNS on Windows. |

Same failure pattern as the 2026-07-07 BT pairing incident: **service name looks like it maps 1:1 to a feature, but backs multiple unrelated flows.**

## What we changed

- **`data/services_tripwire.json`** — added three services:
  - `StiSvc` (moved out of `services_disable_safe` — tripwire is now the authoritative home)
  - `Bonjour Service` (new)
  - `Apple Mobile Device Service` (defense-in-depth, in case a future rule sweeps "Apple bloat")
- **`data/services_disable_safe.json`** — removed `StiSvc` from `printer_scanner` category. Comment on the category updated with a pointer to this incident.
- **`data/network_risky_features.json`** — `mDNS_Bonjour` entry updated:
  - Risk raised `medium` → `high`.
  - New `requiresConfirm: "appleDeviceSyncConfirmedNo"` gate — the disable path REFUSES to run unless the plan carries that flag, set by the orchestrator after an explicit user answer.
  - Description no longer claims Bonjour is redundant; explicitly names iTunes device sync.
- **`skill/modules/services.md`** —
  - Q1 (printer/scanner) `Controls` list: `StiSvc` removed, note added.
  - New **Q16 — iPhone / iPad / iTunes**. Skip condition checks for any Apple-software marker (`Apple Mobile Device Service` present, `C:\Program Files\iTunes` exists, Apple Mobile Device USB Driver installed). No-Apple-software machines never see this question. Controls line notes that all governed services are tripwire and can't actually be disabled — the answer flows out to the `network` module's Bonjour gate and the `startup` module's `apple_helpers` category.
- **`data/ux_smoke_tests.json`** — new test `iphone_itunes_pipeline`. Verifies `Apple Mobile Device Service` + `StiSvc` are not Disabled and `Bonjour Service` (if present) is not Disabled. Uses new `skipIfServiceMissing` field to skip on machines without iTunes installed.
- **`ps/verify/smoke.ps1`** — added `skipIfServiceMissing` handling. New `SKIP` status displayed in DarkGray. Exit code counts only FAIL.

## Remediation script used on the author's machine

Direct commands (elevated PowerShell) — no script file, executed inline during the 2026-07-08 diagnosis conversation:

```powershell
sc.exe config "Bonjour Service" start= auto
sc.exe start   "Bonjour Service"
sc.exe config  stisvc            start= auto
sc.exe start   stisvc
```

Note: `Set-Service -StartupType Automatic` from an elevated PowerShell **appeared** to succeed but did not actually change SCM state; only after a direct `Set-ItemProperty` on `HKLM:\SYSTEM\CurrentControlSet\Services\Bonjour Service` `Start=2` did the value stick, and a follow-up `sc.exe config` was needed to refresh the SCM cache before `sc.exe start` would accept the service. Suspected cause is a stale SCM cache from the original disable path — investigate before relying on Set-Service alone in future remediation scripts.

After the fixes, the iPhone reappeared in iTunes on the next USB plug + Trust prompt.

## Detection playbook for future incidents

Symptom: "My iPhone / iPad no longer shows up in iTunes / File Explorer, no error, phone just charges" after any tuning tool ran.

```powershell
Get-Service 'Apple Mobile Device Service','Bonjour Service','stisvc' |
  Format-Table Name, Status, StartType -AutoSize
```

If any of the three is `Disabled`, that's the cause. Fix with the commands under Remediation above. If AMDS itself is Disabled and Bonjour is missing entirely, iTunes needs a full reinstall (Apple ships them together).

## Principle to remember

Every "this service looks redundant because Windows now ships its own version" claim should be checked against **what actually uses the third-party service, not what the Windows version was designed to replace.** Windows-native mDNS did NOT replace Bonjour for iTunes purposes, because Apple's own userspace stack talks to Bonjour by name, not to whatever mDNS the OS provides. Same pattern applies to any Apple / Adobe / Google helper service someone labels "redundant": if the vendor's app was written against a specific service name, replacing the protocol doesn't help.

Corollary to the 2026-07-07 principle: **hidden UX dependencies aren't only across Windows features — they cross vendor boundaries too.** Tripwire scope must include third-party services whose disabled state silently breaks a well-known first-party experience (iTunes+iPhone, Adobe CC device sync, etc.).
