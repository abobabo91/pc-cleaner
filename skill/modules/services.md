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

### 3. Ask the MAYBEs one by one, conversationally, adaptive

**Approach:** Each MAYBE gets its own quick yes/no/"I'm not sure" question. This is a conversation, not a form. Total questions typically 4-8 per machine (many get skipped by hardware detection).

**Adaptive skip:** Before asking any question, check the skip condition. If it applies, don't ask — that item is decided by evidence alone. All questions offer three answers: `Yes`, `No`, `I'm not sure`. "I'm not sure" triggers the inference rule.

The questions, in the order they should be asked (skip any whose condition fails):

---

**Q1 — Printer / scanner**
> "Do you print documents or scan things from this computer?"

*Skip if:* `Get-Printer` returns only default Microsoft PDF/XPS/OneNote-Send print destinations. (No real printer = don't even ask.)

*"I'm not sure" inference:* If any real printer is configured AND has been used in the last 90 days (check `Get-PrintJob` history), → YES. Otherwise → NO.

*Controls:* `Spooler`, `PrintNotify`, `PrintWorkflowUserSvc_bd465`, `McpManagementService`, `WiaRpc`, `StiSvc`.

---

**Q2 — Face or fingerprint login**
> "Do you unlock this laptop with your face or fingerprint? (Windows Hello)"

*Skip if:* `Get-PnpDevice -Class Biometric` returns nothing. (No biometric hardware = don't ask.)

*"I'm not sure" inference:* Check registry `HKLM:\SOFTWARE\Microsoft\Windows Hello`. If not enrolled → NO.

*Controls:* `WbioSrvc`.

---

**Q3 — Auto-brightness**
> "Do you like when your laptop's screen brightness changes automatically as you move between dim and bright rooms?"

*Skip if:* No ambient light sensor. Check `Get-PnpDevice -Class Sensor | Where-Object FriendlyName -match 'ambient|light'`.

*"I'm not sure" inference:* Currently ON (service running)? → YES. Currently disabled? → NO.

*Controls:* `SensrSvc`.

---

**Q4 — Surround sound**
> "Do you use surround sound / spatial audio like Dolby Atmos on your headphones or speakers?"

*Skip if:* Neither Dolby Access app nor `DolbyDAXAPI` service is present.

*"I'm not sure" inference:* → NO. (Almost nobody knowingly uses spatial audio without deliberately setting it up.)

*Controls:* `VacSvc`, `FMAPOService`, `DolbyDAXAPI`.

---

**Q5 — File sharing on WiFi**
> "Do you share files or a printer from THIS computer with other devices on your WiFi? (Meaning: others can open folders on this laptop from their own devices. Not just accessing others.)"

*Skip if:* `Get-SmbShare` returns only default admin shares (ADMIN$, C$, IPC$, print$).

*"I'm not sure" inference:* → NO. (Real user-hosted shares are almost always intentional and the user knows.)

*Controls:* `LanmanServer`, `lmhosts`.

---

**Q6 — Casting to a TV or speaker**
> "Do you ever cast your screen or music from this laptop to a TV or speaker wirelessly? (Like Chromecast, AirPlay, or Miracast. Not via an HDMI cable.)"

*"I'm not sure" inference:* → NO. If a Miracast display was recently connected (check event log for `PLAYTO` or `Miracast` events), → YES.

*Controls:* `WFDSConMgrSvc`, `fdPHost`, `SSDPSRV`.

---

**Q7 — Windows built-in VPN**
> "Do you connect to a VPN using Windows' built-in feature? (Settings → Network & internet → VPN.) NOT a separate app like NordVPN, ExpressVPN, or OpenVPN."

*Skip if:* User is running OpenVPN as a service OR any third-party VPN app was detected in the profile step. (Answering has already been implied.)

*"I'm not sure" inference:* `Get-VpnConnection` returns zero → NO.

*Controls:* `RasMan`.

---

**Q8 — OneDrive**
> "Do you use OneDrive — Microsoft's cloud storage? (Even just occasionally.)"

*"I'm not sure" inference:* `Get-Process OneDrive` running OR `HKCU:\Software\Microsoft\OneDrive\Accounts\Personal` has an account? YES. Otherwise NO.

*Controls:* `OneSyncSvc_bd465`, `CloudBackupRestoreSvc_bd465`. (Note: OneDrive Updater / FileSyncHelper always kept if this is YES.)

---

**Q9 — Office desktop apps**
> "Do you use Word, Excel, or PowerPoint as installed apps? (Not the free online versions in your browser.)"

*"I'm not sure" inference:* `ClickToRunSvc` service exists? OR `C:\Program Files\Microsoft Office` with recent access? → YES. Otherwise → NO.

*Controls:* `ClickToRunSvc`.

---

**Q10 — Microsoft Edge**
> "Do you use Microsoft Edge as your web browser — either your main one or a backup?"

*"I'm not sure" inference:* `%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Preferences` — check `last_active_time`. Used within last 90 days → YES. Otherwise → NO.

*Controls:* `edgeupdate`, `edgeupdatem`.

---

**Q11 — Copilot or new UWP apps**
> "Do you use Windows Copilot (the AI assistant), or the new Mail / Calendar apps that came with Windows 11?"

*"I'm not sure" inference:* UserAssist launch counts. Any of them launched in last 90 days → YES. Otherwise → NO.

*Controls:* `MicrosoftCopilotElevationService`, plus per-user Mail/Calendar template services.

---

**Q12 — Windows file search in Start menu**
> "When you open the Start menu and type a filename, do you want Windows to find it? (Turning this off saves about 200 MB of memory but you'll need another way to search files, like the app 'Everything'.)"

*"I'm not sure" inference:* If `voidtools.Everything` is installed → suggest turning off (they have an alternative). Otherwise → KEEP ON.

*Controls:* `WSearch`.

---

**Q13 — Git / SSH from command line**
> "Do you write code and use Git or SSH from a terminal? (This is a coder tool. If you don't recognize the names, you don't use it — that's fine.)"

*Skip if:* No sign of coding on the machine. Check: no `git` in PATH, no `%USERPROFILE%\.gitconfig`, no `Git.Git` in winget list, no repo folders under Desktop/Documents. If ALL absent, don't ask — just skip enabling ssh-agent.

*"I'm not sure" inference:* Any of the above present → YES (turn on ssh-agent). None → NO.

*Controls:* `ssh-agent`.

---

**Q14 — Dropbox**
> "Do you still actively use Dropbox?"

*Skip if:* Dropbox process not running AND registry `HKCU:\Software\Dropbox` doesn't exist. (Dropbox isn't installed.)

*"I'm not sure" inference:* Dropbox process running today → YES. Registry account with `last_synced` in last 90 days → YES. Otherwise → NO, and flag Dropbox for uninstall in the `bloat` module instead.

*Controls:* `DbxSvc`.

---

**Q15 — Comet browser**
> "Do you use Comet — the AI browser from Perplexity?"

*Skip if:* Comet isn't installed.

*"I'm not sure" inference:* Recent launch within 30 days → YES. Otherwise → NO, and flag for uninstall in the `bloat` module.

*Controls:* `CometElevationService`, `CometUpdaterService*`.

---

### After all questions, show the decision summary

Format like a friendly recap before applying:

```
Here's what I figured out and what I'll change:

  Print / scan:          NO   (you said no)
  Face / fingerprint:    (skipped — no fingerprint sensor on this laptop)
  Auto-brightness:       (skipped — no light sensor)
  Surround sound:        NO   (auto-detected: Dolby Access not installed)
  Share files on WiFi:   NO   (auto-detected: no shared folders on this PC)
  Cast to TV:            NO   (you said no)
  Windows VPN:           (skipped — you use OpenVPN, so we know)
  OneDrive:              NO   (auto-detected: not signed in)
  Office desktop apps:   NO   (auto-detected: not installed)
  Edge browser:          NO   (auto-detected: not opened in 90+ days)
  Copilot / new Mail:    NO   (auto-detected: never launched)
  Windows Search:        YES  (kept — you didn't say to turn it off)
  Git / SSH:             (skipped — no coding tools detected)
  Dropbox:               (skipped — not installed)
  Comet:                 (skipped — not installed)

I'll disable 87 services total.
Continue?  [Yes / No / Show me the list]
```

Anything the user challenges here → flip the decision, adjust the plan, ask them to confirm again.

Use `AskUserQuestion` with `multiSelect: false` (single-select yes/no/not-sure) — one call per question. Keep raw service names (`Spooler`, `WSearch`, `LanmanServer`, etc.) INTERNAL — never shown in the visible text.

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
