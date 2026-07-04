# module: bloat

Tier: CORE. Auto-runs. Uses winget + Remove-AppxPackage. Asks one question per ambiguous UWP / OEM app.

## Success criteria

At the end of this module the user has:
1. JSON snapshot of every AppX package (per-user + provisioned) BEFORE any change.
2. Every unambiguous bloat UWP uninstalled (Xbox stack, Copilot, News, Weather, LinkedIn, People, Skype, Feedback Hub, Get Started/Tips, Solitaire, MS Teams Personal, Family, Clipchamp).
3. Every MAYBE resolved one at a time (Yes / No / I'm not sure), skip-conditions honored.
4. Provisioned copies also removed so the same bloat does not come back for a new user profile.
5. A `revert.ps1` that reinstalls each removed package from its stored manifest / winget ID.

## Flow

### 1. Diagnose

Run `ps/diagnose/bloat.ps1`. Emits JSON with:
- `.installed[]` — `Get-AppxPackage -AllUsers` — name, publisher, version, install location, per-user vs all-users.
- `.provisioned[]` — `Get-AppxProvisionedPackage -Online` — name, publisher, display name.
- `.winget[]` — `winget list --accept-source-agreements` cross-referenced by AppX PackageFamilyName where possible.

Then for each entry: look up `data/bloat_uwp.json` and label:
- `SAFE` — uninstall without asking.
- `ASK` — one question at a time (see below).
- `NEVER` — do not touch (Windows Security, Store, Photos on newer builds, Camera, Calculator by default, .NET runtimes, WebView2, VCLibs, `.WindowsAppRuntime.*`).
- `UNKNOWN` — publisher not in list, ask via the fall-through Q.

### 2. Ask the MAYBEs one by one, conversationally

**Approach:** Each MAYBE UWP or MSI/EXE gets its own quick yes/no/"I'm not sure" question. This is a conversation, not a form. Every question shows the app icon + a one-line description.

**Skip conditions apply always:**
- Never ask about apps in `data/bloat_uwp.json` under the `never` list.
- Never ask about apps already uninstalled.
- Never ask about apps flagged SAFE (they're gone silently).
- Never ask about apps flagged NEVER (they stay silently).

The question template used for every ASK entry:

> "You have [App Name] installed. Do you use it?"

Show alongside: icon + one-line "what this app does" (from `data/bloat_uwp.json` `description` field). Never show the raw `Microsoft.XboxGamingOverlay` in visible text.

Answers: `Yes` (keep), `No` (uninstall), `I'm not sure` (inference rule below).

The order in which entries are asked, and the skip / inference rules per class:

---

**MAYBE-Q1 — Photos, Groove, Movies & TV, built-in Mail / Calendar, Sticky Notes, Snipping Tool, Voice Recorder, Notepad**

*Skip if:* not installed, OR listed as `never` in `data/bloat_uwp.json` (Notepad often is).

*"I'm not sure" inference:*
- **Photos**: default association for jpg/png = `Microsoft.Windows.Photos` → YES. Otherwise → NO.
- **Groove Music, Movies & TV**: → NO (both are deprecated; VLC or the media apps in `ninite-personalized` are better).
- **Built-in Mail / Calendar**: if `Get-Package "Microsoft.Office*"` OR the user's default browser is signed into a webmail → NO. Otherwise → YES (some users rely on them).
- **Sticky Notes, Snipping Tool, Voice Recorder**: UserAssist launch count in the last 90 d ≥ 3 → YES. Otherwise → NO.

*Controls:* `Microsoft.Windows.Photos`, `Microsoft.ZuneMusic`, `Microsoft.ZuneVideo`, `microsoft.windowscommunicationsapps` (Mail+Calendar package), `Microsoft.MicrosoftStickyNotes`, `Microsoft.ScreenSketch`, `Microsoft.WindowsSoundRecorder`, `Microsoft.WindowsNotepad`.

---

**MAYBE-Q2 — Pre-installed games / gaming extras** (per entry: Microsoft Solitaire Collection, Minecraft Launcher, Game Bar, Xbox app, Xbox sign-in service, pre-installed Spotify)

*Skip if:* not installed.

*"I'm not sure" inference:*
- **Solitaire**: → NO (bundled cruft).
- **Minecraft Launcher**: UserAssist launch in last 90 d → YES. Otherwise → NO.
- **Game Bar (`Microsoft.XboxGamingOverlay`)**: if `profile.gpu[]` has a discrete GPU AND role_signals shows gamer signals → YES. Otherwise → NO.
- **Xbox app**: same rule as Game Bar. Additionally, if the app has been launched in 90 d → YES.
- **Xbox sign-in service (`Microsoft.XboxIdentityProvider`)**: if Xbox app kept OR Minecraft kept OR Forza detected → YES. Otherwise → NO (but note: it's needed for any game with MSA sign-in; the SAFE default is actually to keep it).
- **Pre-installed Spotify (`SpotifyAB.SpotifyMusic`)**: if the desktop Spotify (`Spotify.exe` under LocalAppData) is installed → NO (the desktop one is what the user uses). Otherwise use UserAssist to decide.

*Controls:* `Microsoft.MicrosoftSolitaireCollection`, `Microsoft.MinecraftUWP`, `Microsoft.XboxGamingOverlay`, `Microsoft.GamingApp`, `Microsoft.XboxIdentityProvider`, `SpotifyAB.SpotifyMusic`.

---

**MAYBE-Q3 — OEM pre-installed apps** (per entry: Lenovo Vantage / HP Support Assistant / Dell Update / ASUS ROG, HP QuickDrop / Dell Digital Delivery / Lenovo Now file-sharing, McAfee / Norton trial AV)

*Skip if:* `profile.system.manufacturer` doesn't match the app (a Dell app on a Lenovo laptop = leftover, mark SAFE bloat directly, don't ask).

*"I'm not sure" inference:*
- **OEM main management app (Vantage etc.)**: if `profile.flags.isLaptop=true` AND `profile.system.manufacturer` matches → YES (warranty / firmware / thermals). Otherwise → NO.
- **OEM extras (QuickDrop, Digital Delivery, Lenovo Now)**: → NO (rarely used, replicable with any file-transfer app).
- **Pre-installed AV trial (McAfee, Norton)**: → NO. Never a genuine YES.

*Controls:* `E046963F.LenovoSettingsforEnterprise`, `AD2F1837.HPSupportAssistant`, `DellInc.PartnerPromo`, `AsusOSSupport`, `SonicMcAfeeSecureConnection`, etc. — the actual package names vary. Look up in `data/bloat_uwp.json`.

---

**MAYBE-Q4 — Social / news / assistant apps** (per entry: LinkedIn, News, Weather, People, Skype, Clipchamp, Microsoft Family, Copilot, Feedback Hub)

*Skip if:* not installed.

*"I'm not sure" inference:* → NO for all of these. UserAssist launch count in last 90 d ≥ 3 → YES override. (These are the top-uninstall UWP bloat; the vast majority of users never opened them.)

*Controls:* `Microsoft.LinkedIn`, `Microsoft.BingNews`, `Microsoft.BingWeather`, `Microsoft.People`, `Microsoft.SkypeApp`, `Clipchamp.Clipchamp`, `MicrosoftCorporationII.MicrosoftFamily`, `Microsoft.Copilot` (and taskbar-pin cleanup handled separately in `tray-taskbar`), `Microsoft.WindowsFeedbackHub`.

---

**MAYBE-Q5 — Anything else that fell through** (UNKNOWN category — publisher not in `data/bloat_uwp.json`)

*Skip if:* installed by user manually within the last 30 d (recent installs are almost never bloat).

*"I'm not sure" inference:* → NO on the uninstall action (leave it alone; if we don't know what it is, don't remove it). Flag for a curation update to `data/bloat_uwp.json`.

*Controls:* whatever the AppX PackageFamilyName / winget ID is. INTERNAL.

---

### After all questions, show the decision summary

```
Bloat cleanup — here's what I figured out:

  Photos:                YES  (auto: your default image app)
  Groove Music:          (skipped — already uninstalled)
  Movies & TV:           NO   (auto: deprecated app)
  Mail (built-in):       NO   (auto: Outlook installed)
  Sticky Notes:          YES  (auto: launched 12x in 90 days)
  Snipping Tool:         YES  (auto: launched daily)
  Solitaire:             NO   (auto: bundled cruft)
  Minecraft Launcher:    NO   (you said no)
  Game Bar:              NO   (auto: no discrete GPU / gamer signals)
  Xbox app:              NO   (you said no)
  Xbox sign-in:          NO   (auto: no games depend on it)
  Lenovo Vantage:        YES  (auto: laptop, matches OEM)
  Lenovo Now:            NO   (auto: OEM extra)
  McAfee trial:          NO   (auto: never a YES)
  LinkedIn / News / Weather / People / Skype / Clipchamp / Family / Copilot / Feedback Hub:  (all NO — auto, unused)

I'll uninstall 18 apps (~1.4 GB reclaimed).
Continue?  [Yes / No / Show me the list]
```

Use `AskUserQuestion` with `multiSelect: false` (single-select yes/no/not-sure) — one call per MAYBE. Keep raw AppX PackageFamilyNames INTERNAL.

### 3. Build plan JSON

```json
{
  "removePerUser":     ["Microsoft.XboxGamingOverlay", "Microsoft.LinkedIn"],
  "removeProvisioned": ["Microsoft.XboxGamingOverlay"],
  "wingetUninstall":   [{"id":"Microsoft.Teams", "reason":"Personal Teams, user said no"}]
}
```

### 4. Apply (elevated)

Call `ps/apply/bloat.ps1 -Plan <path> -SnapshotDir <path>`. It:
- `Get-AppxPackage -AllUsers <name> | Remove-AppxPackage -AllUsers` per entry.
- `Remove-AppxProvisionedPackage -Online -PackageName <full>` per provisioned entry.
- `winget uninstall --id <id> --silent --accept-source-agreements` per winget entry.
- Writes each successful removal to `apply.log` with the exact `PackageFullName` so `revert.ps1` can `Add-AppxPackage -Register` from the AppxManifest OR fall back to winget install.

### 5. Report

- Count of packages removed (per-user vs provisioned vs winget).
- Disk space reclaimed (sum of `InstallLocation` sizes captured pre-remove).
- Path to snapshot + revert.

## Known gotchas

- `Remove-AppxPackage` without `-AllUsers` only removes for the current user; the package stays on disk and can be re-registered on next login. Always use `-AllUsers` for a real uninstall.
- `Remove-AppxProvisionedPackage` needs the full package name (with version + arch + hash suffix), not just the display name. Grab it from the diagnose output — do not hand-construct.
- The Xbox app family cross-depends: `Microsoft.GamingApp` needs `Microsoft.XboxIdentityProvider` for Xbox Live sign-in in unrelated games. If the user plays Minecraft (Java or Bedrock) with an MSA account, leaving `XboxIdentityProvider` in place is a good default even after removing the Xbox app.
- `Microsoft.Windows.Photos` — the "new" Media/Photos on 24H2 is a different package (`Microsoft.Windows.Photos` still, but versioned 2024+). Removing it and the user then trying to open a jpg gets "no app associated." Photos is on the `ASK` list, not `SAFE`.
- `Microsoft.549981C3F5F10` = the Cortana UWP shell. On 22H2+ Cortana is deprecated but the package removal may fail with 0x80073CFA "PACKAGE_MANAGER_ERROR_REMOVE_SYSTEM_PACKAGE" if it's still marked as system app. Detect that HRESULT and fall back to `Set-AppxProvisionedPackage -Online -PackageName <name> -Remove` via DISM.
- Winget uninstalls can fail silently with exit code 0 if the package is per-machine but you ran winget non-elevated. Check that the apply script is elevated before calling winget for MSI installs.
- Feature updates (23H2 → 24H2) reinstall Copilot, Clipchamp, Family, and sometimes Teams Personal from the recovery image. Note in the report: "re-run bloat after any Windows feature update."
- OneDrive is NOT a UWP app — it's an .exe under `%LOCALAPPDATA%\Microsoft\OneDrive\`. If the user wants OneDrive gone entirely, use `winget uninstall Microsoft.OneDrive` — do not try `Remove-AppxPackage` on it.

## Curated defaults / Data files

- `data/bloat_uwp.json` — categorized list. Schema: array of `{packageFamilyPattern, category ("SAFE"|"ASK"|"NEVER"), question ("peripherals"|"games"|"oem"|"social"), description ("this app is for..." one-liner shown to user), reason}`. Extend this file to add new bloat; do not edit the code.
- `data/bloat_winget.json` — categorized list of non-UWP MSI/EXE bloat commonly OEM-preinstalled (McAfee, Norton, WildTangent, HP JumpStart, Dell SupportAssist for Home PCs). Same schema.

## Machine profile branches

- Laptop with matching OEM detected (`profile.system.manufacturer` = Lenovo/HP/Dell/ASUS): move that OEM's management app into the `ASK` bucket instead of `SAFE`. Keeping it is the more common right answer on a warranty-active laptop.
- Desktop: OEM apps default to `SAFE` (bloat).
- If `profile.gpu[].vendor` includes NVIDIA: never remove `NVIDIA Control Panel` UWP.
- If `profile.gpu[].vendor` includes AMD: never remove `AMD Radeon Software` UWP.
- On Windows Home: MS Teams Personal is on by default and is bloat unless the user opts to keep. On Windows Pro joined to Entra ID, MS Teams may be enterprise-mandated — check registry `HKLM:\SOFTWARE\Policies\Microsoft\Teams` and skip if managed.
- If the user detected as "office role" by startup module (Outlook / Word / Excel autostart entries present), tip Sticky Notes / Snipping Tool / Mail toward KEEP.
