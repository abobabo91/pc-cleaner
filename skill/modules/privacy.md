# module: privacy

Tier: CORE. Auto-runs. Applies safe telemetry/ad/tracking registry tweaks. Asks a single summary question up front, then two individual conversational questions for the ask-user items.

## Success criteria

At the end of this module the user has:
1. A `.reg` export of every key BEFORE change.
2. Telemetry minimized (Diagnostic Data set to Required = 1, DiagTrack service already handled by `services`).
3. Advertising ID disabled, Activity History disabled, Tailored Experiences off, Suggested Content in Settings off.
4. Explorer / Start Menu ads (`SubscribedContent-*` keys) all off.
5. Edge tracking prevention set to Strict (if user opts in), Edge personalized ads off, Edge news feed off.
6. Location services state matches user's answer.
7. A `revert.ps1` that restores every touched value.

## Flow

### 1. Diagnose

Run `ps/diagnose/privacy.ps1`. It walks `data/privacy_keys.json` and emits current state for each key: `path`, `name`, `type`, `currentValue`, `desiredValue`, `category`.

### 2. Categorize

- **AUTO** — always apply, no question. Telemetry to Required. Ad ID off. Activity History off. Tailored Experiences off. Explorer / Start `SubscribedContent-*` all 0. Show sync provider notifications 0. Cortana search web 0. Windows tips 0. Copilot key + Win+C shortcut + taskbar icon (Copilot is unambiguously off-by-default in the seed-machine target profile).
- **ASK-USER** — location services (Q2), Edge tracking prevention (Q3).
- **SUMMARY** — one question up front so the user can bail out or see the list before any AUTO change happens (Q1).

Never touch:
- Anything under `HKLM:\SYSTEM\CurrentControlSet\Services\WinDefend`.
- SmartScreen keys (leave user default).
- Anything that requires disabling Windows Update (out of scope — not a privacy module job).

### 3. Ask the user, conversationally

**Plain-English rule: describe what the user sees or stops seeing, not the registry key name.** Keep raw paths INTERNAL.

Use `AskUserQuestion` with `multiSelect: false` — one call per question.

---

**Q1 — Summary opt-in**

> "Turn off Windows tracking, ads, and telemetry? (This makes Windows send less data to Microsoft. Everything I turn off is reversible.)"

Answers:
- `Yes` — apply all AUTO tweaks, then move on to Q2 and Q3.
- `No` — skip the whole module (log "user opted out").
- `Show me what changes` — print the list of AUTO keys with human descriptions (telemetry level, Ad ID, Activity History, Tailored Experiences, tips, lock-screen suggestions, Suggested Content in Settings, Copilot key, Bing/web results in Start) and then re-ask.

*Skip if:* no ambiguity — this is the entry-gate question, always asked when the module runs.

*"I'm not sure" inference:* not offered here. This is a consent gate; if the user is genuinely unsure, `Show me what changes` gives them the specifics.

*Controls:* every AUTO entry in `data/privacy_keys.json`.

---

**Q2 — Location services**

> "Does Windows need to know where you are? (Weather, Find My Device, and a few other apps use this. Most people can safely say no.)"

*Skip if:* location services already disabled (`HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration\Status\Value = 0`).

*"I'm not sure" inference:* If `profile.flags.isLaptop=true` AND Find My Device is enabled (`HKLM:\SOFTWARE\Microsoft\Settings\FindMyDevice\LocationSyncEnabled = 1`) → YES (keep on — laptop-loss recovery is worth the tradeoff). Otherwise → NO.

*Controls:* `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location\Value` and the `lfsvc` service setting.

---

**Q3 — Edge tracking prevention**

> "In the Edge browser, block more of the trackers that follow you across websites? (This is stricter than the default. Some sites like Teams or Office may make you sign in again after the change.)"

*Skip if:* Edge is not installed OR the user's default browser is not Edge AND Edge shows no launches in the last 90 d (Edge is effectively unused; the tweak has no impact worth explaining).

*"I'm not sure" inference:* Default browser check via `HKCU:\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice\ProgId`.
- If `MSEdgeHTM` (Edge is default) → YES.
- If Edge is installed but not default AND has been launched in last 90 d → YES.
- If Edge is installed but never opened → NO (change has no impact).

*Controls:* `HKCU:\SOFTWARE\Microsoft\Edge\TrackingPrevention\Level = 3` (Strict), plus Edge personalized ads off, Edge news feed off, Edge startup boost off — all bundled with this decision.

---

**Q4 — Web results in Start menu**

> "When you type into the Start menu, do you want it to also search the web (with Bing) — or only find things on your computer?"

Answers:
- `Only files and apps on my computer` (Bing off in Start)
- `Also web results from Bing` (keep default)
- `I'm not sure`

*Skip if:* user's default browser is Edge AND their default search engine is Bing (both signals of "I like Bing" — don't fight it).

*"I'm not sure" inference:* → `Only files and apps on my computer` (majority of users find the web results in Start noisy or annoying; if the user actually uses them they'll know and answer differently).

*Controls:* `HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer\DisableSearchBoxSuggestions = 1` and `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search\BingSearchEnabled = 0` and `CortanaConsent = 0`. Moved from apply_silently to ask_user 2026-07-07 after audit — silently killing Bing-in-Start is surprising to users who used it deliberately.

---

**Q5 — Windows Recall (Copilot+ PCs)**

> "Your PC has a feature called Recall — it automatically takes screenshots every few seconds so you can search 'what was that recipe I saw last week?' Some people love it, others find it creepy. Which are you?"

Answers:
- `Turn it off — feels creepy`
- `Keep it on — I use it (or want to try it)`
- `I'm not sure`

*Skip if:* the machine is not a Copilot+ PC (i.e. no ARM64 Copilot+ hardware and no `HKLM:\SOFTWARE\Microsoft\Policies\WindowsAI` key structure that indicates the feature is present). On non-Copilot+ machines, Recall is not available and the policy has no effect — silent apply is fine, skip the question.

*"I'm not sure" inference:* → `Turn it off — feels creepy`. Recall is opt-in in current builds; most users who don't remember enrolling would rather not have screenshots taken.

*Controls:* `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI\DisableAIDataAnalysis = 1` and `HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI\DisableAIDataAnalysis = 1`. Moved from apply_silently to ask_user 2026-07-07 after audit — some users deliberately enroll in Recall on Copilot+ PCs and silently disabling it regresses their workflow.

---

### After all questions, show the decision summary

```
Privacy tweaks — here's what I figured out:

  Ad ID:                 OFF  (auto)
  Activity History:      OFF  (auto)
  Tailored Experiences:  OFF  (auto)
  Windows tips:          OFF  (auto)
  Lock-screen ads:       OFF  (auto)
  Bing/web in Start:     OFF  (auto)
  Copilot key & icon:    OFF  (auto)
  Telemetry level:       Required (1)  (auto — Home can't go lower)
  Location services:     KEEP ON  (auto: laptop, Find My Device enabled)
  Edge tracking:         STRICT  (auto: Edge is your default browser)

I'll change 24 registry values.
Continue?  [Yes / No / Show me the list]
```

Anything the user challenges here → flip the decision, adjust the plan, ask them to confirm again.

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

- Count of keys touched grouped by category (telemetry / ads / Explorer / Edge / Location / Copilot / Search).
- Which of the ASK-USER questions the user opted into.
- Snapshot + revert paths.
- Note: some keys need explorer.exe restart or sign-out to take effect. Say so.

## Known gotchas

- `AllowTelemetry` under `HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection` — on Win11 Home, this key exists but is enforced only up to level 1 (Required). Setting it to 0 (Security) is a Pro/Enterprise-only enforcement; on Home the OS silently treats 0 as 1. Not a failure, but don't claim it's off if it's not.
- `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager` — the `SubscribedContent-XXXXXX` keys have different numeric suffixes on different Windows builds (e.g. `-338388Enabled` for Start suggestions, `-353694Enabled` for Settings suggestions, `-338389Enabled` for tips). Do not hardcode — walk the subkeys and match by known suffix set from `data/privacy_keys.json`.
- `Advertising ID` reset does not clear the current ID until sign-out. Note in report.
- Edge tracking prevention Strict can break Microsoft Teams for Web SSO, some Office 365 apps. That's the whole point of the Q3 skip / inference — if Edge isn't used, we don't do it.
- Copilot disable: on 24H2 the Copilot key is a distinct scancode (0x5D under `HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout\Scancode Map`). Merely setting `HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot\TurnOffWindowsCopilot=1` disables the app but the physical key still glows / opens something. Full disable requires the scancode remap AND the policy AND removing the taskbar pin.
- On Home edition, `HKLM:\SOFTWARE\Policies\...` GPO-style keys are often not enforced unless a corresponding GPO Preferences setting is present. Prefer the HKCU per-user Settings keys where equivalent exists.
- `Windows.old` cleanup is NOT here — it lives in `storage`. Do not touch.
- Do NOT touch `SmartScreen*` values here even though they look privacy-adjacent. That's a security tradeoff, out of scope.
- The Diagnostic Data Viewer + Feedback Hub keys can be disabled but the corresponding UWP apps then error. `bloat` module handles removing the UWPs; do these keys AFTER `bloat` in the run order, or Feedback Hub errors briefly.

## Curated defaults / Data files

- `data/privacy_keys.json` — array of `{path, name, type, desiredValue, category ("AUTO"|"ASK-LOCATION"|"ASK-EDGE"), reason, affectsExplorer: bool, requiresSignout: bool}`. Extend this file to add new privacy keys.

## Machine profile branches

- `profile.os.edition` = Home: skip `HKLM:\SOFTWARE\Policies\...` keys that require Pro/Enterprise enforcement (log them as "would-set but Home ignores"). Prefer HKCU equivalents.
- `profile.os.edition` = Enterprise/Education: assume MDM/Intune may already enforce some of these. Diagnose script tags `managedBy: "MDM"` if the corresponding `SOFTWARE\Microsoft\PolicyManager\current` key is set — do not overwrite those.
- `profile.flags.isLaptop=true`: default Q2 (location) toward KEEP if Find My Device is enrolled.
- If Edge is not the default browser AND was never launched: skip Q3 entirely (no impact worth explaining).
