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

**Two rules for every question:**

**Rule A — Plain English, no jargon.** No `SMB`, `MDM`, `HKCU`, `WSearch`, `ssh-agent` in what the user reads. Describe what the thing is FOR.

**Rule B — Always include "I'm not sure" as an option.** Most users honestly don't know if they use SMB, Miracast, IPv6, or SSH. Never make them guess. When they pick "I'm not sure", auto-detect from evidence on the machine (see the inference rules below each question) and treat the answer as if they said yes or no accordingly.

Ask exactly this shape (adjust items to what's actually installed on THIS machine):

---

**Q1 — "What do you actually use on this computer?" (check all that apply)**
- [ ] I print or scan documents from this computer
- [ ] I unlock this laptop with my face or fingerprint (Windows Hello)
- [ ] I like when my laptop's screen brightness adjusts automatically as I move between dim and bright rooms
- [ ] I care about surround sound / Dolby Atmos on my headphones or speakers
- [ ] **I'm not sure — figure it out for me**

If the user picks "I'm not sure" (or leaves some items blank), auto-detect:
- **Printer/scanner:** `Get-Printer | Where-Object { $_.Type -ne 'Local' -or $_.PrinterStatus -eq 'Normal' }` — if zero real printers OR none used in last 90 days (check job history), infer NO.
- **Face/fingerprint:** check registry `HKLM:\SOFTWARE\Microsoft\Windows Hello for Business` and `Get-PnpDevice -Class Biometric` — if no biometric device or Hello not enrolled, infer NO.
- **Auto-brightness:** check for ambient light sensor `Get-PnpDevice | Where-Object { $_.Class -eq 'Sensor' -and $_.FriendlyName -match 'ambient|light' }` — no sensor = NO.
- **Dolby Atmos:** check if Dolby Access app is installed OR `DolbyDAXAPI` service is currently running — otherwise NO.

---

**Q2 — "How do you use your home network?" (check all that apply)**
- [ ] I share files or a printer from this computer so my phone, tablet, or other computers on my WiFi can see them
- [ ] I sometimes send my screen or music/video from this laptop to a TV or speaker wirelessly (like Chromecast / AirPlay / Miracast — not via HDMI cable)
- [ ] I connect to a VPN using Windows' built-in feature (Settings → Network & internet → VPN) — NOT a separate app like NordVPN, OpenVPN, or ExpressVPN
- [ ] **I'm not sure — figure it out for me**

Inference for "I'm not sure":
- **Share files:** `Get-SmbShare | Where-Object { $_.Name -notin 'ADMIN$','C$','IPC$','print$' }` — if zero user-created shares, NO.
- **Cast/Miracast:** almost never true for typical users. If unsure → NO. Only check YES if `Get-Process | Where-Object { $_.Name -match 'miracast|castto' }` has run recently.
- **Windows VPN:** `Get-VpnConnection` — if zero configured, NO. If OpenVPN is running as a service (already detected in profile), the user isn't using Windows VPN.

---

**Q3 — "Which Microsoft things do you actually use?" (check all that apply)**
- [ ] OneDrive — my Microsoft cloud storage, even just occasionally
- [ ] Word, Excel, or PowerPoint installed as desktop apps (NOT just in the browser)
- [ ] Microsoft Edge as my browser — main OR backup
- [ ] Windows Copilot, or the new Mail / Calendar apps
- [ ] **I'm not sure**

Inference:
- **OneDrive:** `Get-Process OneDrive` running OR registry `HKCU:\Software\Microsoft\OneDrive\Accounts\Personal` shows an account. If neither, NO.
- **Office desktop:** `ClickToRunSvc` service Running OR `C:\Program Files\Microsoft Office` exists with recent access time. If neither, NO.
- **Edge:** check `%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Preferences` `last_active_time` — if older than 90 days, NO.
- **Copilot / UWP Mail:** UserAssist launch count — if never launched, NO.

---

**Q4 — "Last few things:" (check all that apply)**
- [ ] I want the Start menu to find my files when I type — like searching for a document by name (this uses about 200 MB of memory constantly; turn it off only if you use Everything by voidtools)
- [ ] I write code and use Git / SSH from a command line (this is a coder tool — if you don't know what SSH is, you don't need it)
- [ ] I still actively use Dropbox
- [ ] I use Comet, the AI browser from Perplexity
- [ ] **I'm not sure**

Inference:
- **Windows Search:** default KEEP unless the user has Everything (`voidtools.Everything`) installed. If they do have Everything, ask explicitly: "You have Everything installed — turn off Windows Search to save memory?"
- **Git/SSH:** check `git` in PATH OR `%USERPROFILE%\.gitconfig` exists OR any repo under Desktop/Documents. If none, NO — most non-developers won't have any of these.
- **Dropbox:** `Get-Process Dropbox` running OR `HKCU:\Software\Dropbox` has a recent access. If neither, NO — and flag Dropbox for uninstall in the `bloat` module instead.
- **Comet:** check installed apps. If not installed, skip the question entirely.

---

**Adaptive question phrasing:** Don't ask about things that aren't relevant to this machine.
- Skip Q1 face/fingerprint item if no biometric hardware exists.
- Skip Q1 auto-brightness item if no ambient light sensor exists.
- Skip Q2 Windows VPN item if the user has OpenVPN or another VPN app running (they've already answered).
- Skip Q4 Comet item if Comet isn't installed.

**On "I'm not sure":** Show the user what was auto-detected so they learn:
```
Auto-detected for you:
- Printer/scanner: NO (no printers configured)
- Face/fingerprint: NO (no biometric hardware)
- Windows VPN: NO (0 VPN connections in Windows Settings — you use OpenVPN separately)
- Git/SSH: NO (no .gitconfig, no git in PATH)
```
Then apply based on those inferences.

Use `AskUserQuestion` with `multiSelect: true`. Anything the user does NOT check AND the inference says NO → disable. Anything they check → mark KEEP-FOR-YOU.

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
