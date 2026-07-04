# module: privacy

Tier: CORE. Auto-runs. Applies safe telemetry/ad/tracking registry tweaks. Asks ≤2 grouped questions for anything user-facing.

## Success criteria

At the end of this module the user has:
1. A `.reg` export of every key BEFORE change.
2. Telemetry minimized (Diagnostic Data set to Required = 1, DiagTrack service already handled by `services`).
3. Advertising ID disabled, Activity History disabled, Tailored Experiences off, Suggested Content in Settings off.
4. Explorer / Start Menu ads (`SubscribedContent-*` keys) all off.
5. Edge tracking prevention set to Strict, Edge personalized ads off, Edge news feed off.
6. Copilot key (Win+C) disabled if the user opts in.
7. Search-web-in-Start disabled if user opts in.
8. A `revert.ps1` that restores every touched value.

## Flow

### 1. Diagnose

Run `ps/diagnose/privacy.ps1`. It walks `data/privacy_keys.json` and emits current state for each key: `path`, `name`, `type`, `currentValue`, `desiredValue`, `category`.

### 2. Categorize

- **AUTO** — always apply, no question. Telemetry to Required. Ad ID off. Activity History off. Tailored Experiences off. Explorer / Start `SubscribedContent-*` all 0. Show sync provider notifications 0. Cortana search web 0. Windows tips 0.
- **ASK-COPILOT** — Copilot key + Win+C shortcut + Copilot taskbar icon. Some users want it.
- **ASK-EDGE** — Edge tracking prevention Strict, Edge personalized ads off, Edge news feed off, Edge startup boost off. Ask before touching, since Strict tracking prevention breaks some SSO flows.

Never touch:
- Anything under `HKLM:\SYSTEM\CurrentControlSet\Services\WinDefend`.
- SmartScreen keys (leave user default).
- Anything that requires disabling Windows Update (out of scope — not a privacy module job).

### 3. Ask the user

`AskUserQuestion`, `multiSelect: true`, at most 2 questions:

- **Which of these do you want disabled?** (options: "Copilot (Win+C shortcut and taskbar icon)", "Web results in Start Menu search", "Bing search suggestions", "Windows tips and Get Even More Out Of Windows notifications", "Lock screen ads and suggestions", "Suggested content in Settings")
- **Edge browser tweaks?** (options: "Set tracking prevention to Strict", "Turn off personalized ads based on browsing", "Turn off news feed on new tab", "Turn off startup boost")

Unchecked in either question → skip that key.

### 4. Build plan JSON

```json
{
  "apply": [
    {"path":"HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo","name":"Enabled","type":"DWord","value":0,"reason":"Ad ID off"}
  ]
}
```

### 5. Apply (elevated only if HKLM key present in plan)

Call `ps/apply/privacy.ps1 -Plan <path> -SnapshotDir <path>`. It:
- Exports each parent key to `<snapshotDir>/reg-exports/<sanitized-path>.reg` via `reg.exe export` BEFORE any change.
- Sets each value via `Set-ItemProperty` (or creates the key first if missing).
- Emits `revert.ps1` that runs `reg.exe import` on every exported `.reg`.

### 6. Report

- Count of keys touched grouped by category (telemetry / ads / Explorer / Edge / Copilot / Search).
- Which of the ASK-* questions the user opted into.
- Snapshot + revert paths.
- Note: some keys need explorer.exe restart or sign-out to take effect. Say so.

## Known gotchas

- `AllowTelemetry` under `HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection` — on Win11 Home, this key exists but is enforced only up to level 1 (Required). Setting it to 0 (Security) is a Pro/Enterprise-only enforcement; on Home the OS silently treats 0 as 1. Not a failure, but don't claim it's off if it's not.
- `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager` — the `SubscribedContent-XXXXXX` keys have different numeric suffixes on different Windows builds (e.g. `-338388Enabled` for Start suggestions, `-353694Enabled` for Settings suggestions, `-338389Enabled` for tips). Do not hardcode — walk the subkeys and match by known suffix set from `data/privacy_keys.json`.
- `Advertising ID` reset does not clear the current ID until sign-out. Note in report.
- Edge tracking prevention Strict can break Microsoft Teams for Web SSO, some Office 365 apps. Ask before setting.
- Copilot disable: on 24H2 the Copilot key is a distinct scancode (0x5D under `HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout\Scancode Map`). Merely setting `HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot\TurnOffWindowsCopilot=1` disables the app but the physical key still glows / opens something. Full disable requires the scancode remap AND the policy AND removing the taskbar pin.
- On Home edition, `HKLM:\SOFTWARE\Policies\...` GPO-style keys are often not enforced unless a corresponding GPO Preferences setting is present. Prefer the HKCU per-user Settings keys where equivalent exists.
- `Windows.old` cleanup is NOT here — it lives in `storage`. Do not touch.
- Do NOT touch `SmartScreen*` values here even though they look privacy-adjacent. That's a security tradeoff, out of scope.
- The Diagnostic Data Viewer + Feedback Hub keys can be disabled but the corresponding UWP apps then error. `bloat` module handles removing the UWPs; do these keys AFTER `bloat` in the run order, or Feedback Hub errors briefly.

## Curated defaults / Data files

- `data/privacy_keys.json` — array of `{path, name, type, desiredValue, category ("AUTO"|"ASK-COPILOT"|"ASK-EDGE"), reason, affectsExplorer: bool, requiresSignout: bool}`. Extend this file to add new privacy keys.

## Machine profile branches

- `profile.os.edition` = Home: skip `HKLM:\SOFTWARE\Policies\...` keys that require Pro/Enterprise enforcement (log them as "would-set but Home ignores"). Prefer HKCU equivalents.
- `profile.os.edition` = Enterprise/Education: assume MDM/Intune may already enforce some of these. Diagnose script tags `managedBy: "MDM"` if the corresponding `SOFTWARE\Microsoft\PolicyManager\current` key is set — do not overwrite those.
- `profile.flags.isLaptop=true`: keep "Location services" alone (users often want Find My Device). Do not touch `HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration\Status\Value`. That's a `services` decision, not privacy.
- If Edge is not the default browser (`HKCU:\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice\ProgId` != `MSEdgeHTM`), still offer ASK-EDGE tweaks — Edge runs in the background for widgets even when not default.
