# module: services

## Success criteria

At the end of this module the user has:
1. A JSON snapshot of every service's start type + status BEFORE any change.
2. Every DISABLE-SAFE service disabled.
3. Every genuinely-required service confirmed KEEP with no change.
4. The user's MAYBEs resolved in ≤4 grouped multi-select questions and applied.
5. A `revert.ps1` in the snapshot dir that undoes everything.

## Flow

### 1. Diagnose

Run `ps/diagnose/services.ps1`. It emits a JSON blob:
- `.profile` — machine profile (see common.ps1)
- `.summary` — counts by verdict / start mode / state
- `.services[]` — one row per service with `Verdict`, `Reason`, `Category` pre-labeled from `data/services_tripwire.json` and `data/services_disable_safe.json`.

### 2. Enrich verdicts using machine profile + running third-party services

For each service still tagged UNCLASSIFIED, decide:
- `KEEP` if it's a core Windows service you (Claude) recognize as required.
- `KEEP-FOR-YOU` if `PathName` or `Description` matches a currently-installed third-party app (Docker, OpenVPN, NVIDIA, AMD, Realtek, Apple, Lenovo, Google, WSL). Name the app in the reason.
- `MAYBE` if the answer depends on user behavior. Add to the MAYBE bucket.

Never override a KEEP-TRIPWIRE.

### 3. Batch the MAYBEs into ≤4 grouped multi-select questions

**Plain-English rule: describe what the thing is FOR, not its technical name.** No `SMB`, `MDM`, `HKCU`, `WSearch`, `ssh-agent` etc. in the visible question text.

Ask exactly this shape (adjust items to what's actually installed on THIS machine):

**Q1 — "What do you actually use on this computer?" (check all that apply)**
- I print or scan documents from this computer
- I unlock this laptop with my face or fingerprint
- My laptop's screen dims automatically in dim light (I want that)
- I use surround sound / Dolby Atmos on speakers or headphones

**Q2 — "How do you use the network?" (check all that apply)**
- I share files or folders from this computer so other devices on my WiFi can open them
- I sometimes cast my screen wirelessly to a TV
- I sometimes play music/video from this laptop to a wireless speaker or smart TV
- I use the built-in Windows VPN feature (not OpenVPN or a separate VPN app)
- I play online games or use apps that specifically require IPv6 (very rare — say no if unsure)

**Q3 — "Which Microsoft things do you actually use?" (check all that apply)**
- OneDrive — even just occasionally
- Word / Excel / PowerPoint installed as desktop apps (not just in the browser)
- Microsoft Edge browser (as my main or backup browser)
- Windows Copilot, the new Mail app, or the Calendar app

**Q4 — "Last few things:" (check all that apply)**
- Keep Windows' file search working in the Start menu (uses ~200 MB of RAM constantly — turn off if you use Everything or don't rely on Start search)
- I use Git or SSH keys from the command line (turns on the key helper so you don't retype passphrases)
- I still actively use Dropbox
- I use Comet (Perplexity's browser)

Use `AskUserQuestion` with `multiSelect: true`. Anything the user does NOT check → tip toward DISABLE. Anything they check → mark KEEP-FOR-YOU and skip the disable.

Keep the raw service names (`Spooler`, `WSearch`, `LanmanServer`, etc.) INTERNAL — used in the plan JSON and log, never shown to the user.

### 4. Build the plan JSON

```json
{
  "disable":      ["Spooler", "DiagTrack", ...],
  "enableManual": ["ssh-agent"],
  "enableAuto":   []
}
```

Include a `notes` field per service explaining the reason so it can be logged.

### 5. Apply (elevated)

Call `ps/apply/services.ps1 -Plan <path> -SnapshotDir <path>`. It writes:
- `snapshot.csv` — pre-state
- `apply.log` — one line per action with reason
- `revert.ps1` — one command per service to restore

The apply script falls back to registry (`Start=4`) for per-user template services with a hash suffix (`AarSvc_bd465` → template `AarSvc`) since `Set-Service` fails on those with "The parameter is incorrect".

### 6. Report

Show the user:
- Before/after count of Running + Disabled services
- Full path to `snapshot.csv` and `revert.ps1`
- The MAYBE decisions with the question that triggered each
- Reboot suggestion if any per-user template services were changed

## Known gotchas (from seed session, 2026-07-04)

- `_bd465`-suffixed services fail Set-Service. Use template registry key.
- `EntAppSvc` and `embeddedmode` return Access Denied via Set-Service but succeed via registry (Administrator, not TrustedInstaller).
- `iphlpsvc` — safe to disable if pure IPv4 but flag: OpenVPN, WSL2 sometimes use interface enumeration via IP Helper. Recommend Manual instead of Disabled unless the user is confident.
- `LanmanServer` — safe to disable ONLY if the user does not host any SMB shares AND doesn't need to see their own machine's admin shares (`\\localhost\c$`).
- Never disable `LanmanWorkstation` — that's the SMB CLIENT.

## Curated defaults

- `data/services_tripwire.json` — do-not-touch list. Refuse without override.
- `data/services_disable_safe.json` — categorized safe-disable list. Machine-agnostic.

Extend these files, not the code, when adding new categorizations.
