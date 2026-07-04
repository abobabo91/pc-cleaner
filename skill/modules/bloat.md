# module: bloat

Tier: CORE. Auto-runs. Uses winget + Remove-AppxPackage. Asks ≤4 grouped questions for the ambiguous UWP apps.

## Success criteria

At the end of this module the user has:
1. JSON snapshot of every AppX package (per-user + provisioned) BEFORE any change.
2. Every unambiguous bloat UWP uninstalled (Xbox stack, Copilot, News, Weather, LinkedIn, People, Skype, Feedback Hub, Get Started/Tips, Solitaire, MS Teams Personal, Family, Clipchamp).
3. User's MAYBEs resolved in ≤4 grouped multi-select questions.
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
- `ASK` — bucket for a grouped question.
- `NEVER` — do not touch (Windows Security, Store, Photos on newer builds, Camera, Calculator by default, .NET runtimes, WebView2, VCLibs, `.WindowsAppRuntime.*`).
- `UNKNOWN` — publisher not in list, ask.

### 2. Ask the user

Grouped `AskUserQuestion`, `multiSelect: true`, ≤4 questions:

- **Do you use any of these Microsoft apps?** — Photos (new Media), Groove Music, Movies & TV, Mail & Calendar (old), Sticky Notes, Snipping Tool, Voice Recorder, Notepad UWP.
- **Which pre-installed games/entertainment do you want to keep?** — Solitaire Collection, Minecraft Launcher, Xbox Game Bar, Xbox Console Companion, Xbox Live, Spotify preinstall.
- **Which OEM apps do you want to keep?** — Lenovo Vantage, Lenovo Now, HP Support Assistant, HP QuickDrop, Dell Update, Dell Digital Delivery, ASUS ROG apps, McAfee/Norton preinstall.
- **Which social / news apps?** — LinkedIn, News, Weather, People, Skype, Clipchamp, Family, Copilot, Feedback Hub.

Unchecked → uninstall. Checked → keep.

### 3. Build plan JSON

```json
{
  "removePerUser":     ["Microsoft.XboxGamingOverlay", "Microsoft.LinkedIn", ...],
  "removeProvisioned": ["Microsoft.XboxGamingOverlay", ...],
  "wingetUninstall":   [{"id":"Microsoft.Teams", "reason":"Personal Teams, user unchecked"}]
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

- `data/bloat_uwp.json` — categorized list. Schema: array of `{packageFamilyPattern, category ("SAFE"|"ASK"|"NEVER"), question ("peripherals"|"games"|"oem"|"social"), reason}`. Extend this file to add new bloat; do not edit the code.
- `data/bloat_winget.json` — categorized list of non-UWP MSI/EXE bloat commonly OEM-preinstalled (McAfee, Norton, WildTangent, HP JumpStart, Dell SupportAssist for Home PCs). Same schema.

## Machine profile branches

- Laptop with matching OEM detected (`profile.system.manufacturer` = Lenovo/HP/Dell/ASUS): move that OEM's management app into the `ASK` bucket instead of `SAFE`. Keeping it is the more common right answer on a warranty-active laptop.
- Desktop: OEM apps default to `SAFE` (bloat).
- If `profile.gpu[].vendor` includes NVIDIA: never remove `NVIDIA Control Panel` UWP.
- If `profile.gpu[].vendor` includes AMD: never remove `AMD Radeon Software` UWP.
- On Windows Home: MS Teams Personal is on by default and is bloat unless the user opts to keep. On Windows Pro joined to Entra ID, MS Teams may be enterprise-mandated — check registry `HKLM:\SOFTWARE\Policies\Microsoft\Teams` and skip if managed.
- If the user detected as "office role" by startup module (Outlook / Word / Excel autostart entries present), tip Sticky Notes / Snipping Tool / Mail toward KEEP.
