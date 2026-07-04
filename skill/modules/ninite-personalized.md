# module: ninite-personalized

Tier: OPTIONAL. Opt-in via `--include ninite-personalized`. Detects the user's role, suggests missing companion apps as copy-paste `winget install` commands. NEVER auto-installs.

## Success criteria

At the end of this module the user has:
1. A detected-role JSON (`dev` / `creative` / `gamer` / `office` / `sysadmin` — non-exclusive, weighted).
2. A per-role recommended companion bundle, filtered to remove apps already installed.
3. A copy-paste block of `winget install --id <id> --silent` commands for each recommended app.
4. No installations run. This module writes a suggestion Markdown to the snapshot dir. User runs commands manually.

## Flow

### 1. Diagnose

Run `ps/diagnose/ninite-personalized.ps1`. It emits:
- `.installed[]` — union of `Get-Package`, `Get-AppxPackage`, `winget list`, plus registry `Uninstall` scan (both HKLM 64-bit + Wow6432Node, HKCU). Normalized to `{id, name, publisher, source, version}`.
- `.roleSignals[]` — evidence for each role:
  - **dev** — presence of: Git, VS Code / any JetBrains IDE / Visual Studio, Node/pnpm/npm, Python, WSL, Docker Desktop, PowerShell 7, Windows Terminal, GitHub CLI, Postman/Insomnia/Bruno, DBeaver/SSMS, .cargo dir, ~go dir.
  - **creative** — Adobe Creative Cloud, Affinity apps, DaVinci Resolve, Blender, Figma, OBS Studio, Canva desktop, Krita, GIMP.
  - **gamer** — Steam, Epic Games Launcher, Battle.net, EA App, Ubisoft Connect, GOG Galaxy, Discord, GeForce Experience / NVIDIA App / AMD Adrenalin, MSI Afterburner.
  - **office** — Office suite installed, Slack, Teams (Work), Zoom, Outlook, Notion, Todoist, 1Password / Bitwarden business plan indicators.
  - **sysadmin** — RSAT features enabled, Sysinternals, WSL + admin tools (nmap? terraform? aws-cli? azure-cli? kubectl?), Wireshark, PuTTY / MobaXterm, VeraCrypt, VMware Workstation.
- `.roles` — weighted (0-1) role scores based on `.roleSignals` count vs each role's threshold.

### 2. Categorize / decide

- For each role scoring > 0.3, load its bundle from `data/ninite_bundles.json`.
- Filter bundle: remove any app already installed (match by winget ID or by publisher+name in `.installed[]`).
- Rank remaining suggestions by "how universal within this role" (a per-app score in the bundle file).
- Keep top 8 per role. Total across roles capped at 20 suggestions to avoid overwhelming.

### 3. Ask the user

Single `AskUserQuestion`, `multiSelect: true`:

- **Detected roles: dev (0.8), sysadmin (0.4). Which roles should we suggest companion apps for?** — options are the detected roles + "Show me apps from another role I didn't get" (opens a follow-up).

Optionally a follow-up question:

- **Which of these apps would you like copy-paste install commands for?** — checkbox per suggested app, with a one-line reason each.

### 4. Build plan JSON

```json
{
  "reportOnly": true,
  "detectedRoles": {"dev":0.82,"sysadmin":0.41},
  "suggestions": [
    {"role":"dev","name":"Windows Terminal","wingetId":"Microsoft.WindowsTerminal","reason":"You have VS Code but no terminal — recommended companion"},
    {"role":"dev","name":"GitHub CLI","wingetId":"GitHub.cli","reason":"Git installed, no gh"}
  ]
}
```

### 5. Apply (no elevation, no install)

Call `ps/apply/ninite-personalized.ps1 -Plan <path> -SnapshotDir <path>`. It writes:
- `<snapshotDir>/ninite-personalized/suggestions.md` — human-readable table with reason + copy-paste block:
  ```
  winget install --id Microsoft.WindowsTerminal --silent --accept-source-agreements --accept-package-agreements
  winget install --id GitHub.cli --silent --accept-source-agreements --accept-package-agreements
  ```
- No changes to the system. `revert.ps1` is a no-op (or absent) since we didn't do anything.

### 6. Report

Print the suggestions table + copy-paste block to the run log. Explicit note: "This module never installs. Run these commands yourself. Elevated PowerShell recommended."

## Known gotchas

- winget install of a package that already exists (via non-winget source, e.g. Chocolatey or MSI) sometimes exits 0 with "no available upgrade" and sometimes fails with "package already installed by another source." Detect installed-outside-winget via the union of sources in diagnose, and skip in suggestions.
- Some packages have wildly different winget IDs than expected: `Notepad++.Notepad++` (not `Notepad++`), `Microsoft.PowerShell` (not `PowerShell.PowerShell7`), `OpenJS.NodeJS.LTS` (LTS suffix mandatory), `Docker.DockerDesktop` (not `DockerDesktop`). Encode canonical IDs in `data/ninite_bundles.json`, do not hand-derive.
- Detecting Steam/Epic/Ubisoft launchers via `Get-Package` misses them on some machines because they install per-user under `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`. Walk HKCU too.
- Adobe Creative Cloud installs 50+ subpackages; a machine with even one Adobe app usually has the CC helper. Detect the helper as the anchor for "creative role" rather than expecting every Adobe app individually.
- WSL-based tooling (`aws-cli` inside a WSL distro) doesn't count for the Windows-native suggestion. If the user has `aws-cli` in WSL only, still suggest the Windows-native one (or explicitly note "you have aws-cli in WSL; a Windows version is optional").
- Winget source agreements must be accepted on first run per user. Include `--accept-source-agreements --accept-package-agreements` in every copy-paste command.
- winget upgrades of Store-installed apps sometimes lock up if the Store app has a pending update. If suggesting `winget upgrade`, warn.
- OEM-installed antivirus (McAfee LiveSafe, Norton) shows up in `Get-Package` — do not suggest replacing with a "better" AV. Off scope.
- Role signals can be misleading — a machine with Docker Desktop + Steam + Adobe is not "not any role", it's "all of them." Treat scores as additive, not exclusive.
- Some suggestions require additional setup steps (Windows Terminal profile config, `gh auth login`, `wsl --install` for a distro). The suggestions.md should link to those follow-ups, not just the install command.

## Curated defaults / Data files

- `data/ninite_bundles.json` — schema:
  ```json
  {
    "dev": [
      {"name":"Windows Terminal","wingetId":"Microsoft.WindowsTerminal","universality":0.95,"reason":"Modern terminal for cmd/pwsh/wsl"},
      {"name":"PowerShell 7","wingetId":"Microsoft.PowerShell","universality":0.9,"reason":"Modern cross-platform PS"},
      ...
    ],
    "creative": [...],
    "gamer": [...],
    "office": [...],
    "sysadmin": [...]
  }
  ```
  Extend to add apps or new roles. `universality` (0-1) is the "how universally useful within this role" weight — used for ranking.
- `data/role_signals.json` — map from installed-app match pattern → role and weight. E.g. `Git.Git` → `dev` weight 0.3, `Docker.DockerDesktop` → `dev` weight 0.5, `Adobe.Photoshop` → `creative` weight 0.4. Extend per user feedback.

## Machine profile branches

- `profile.flags.hasDiscreteGPU=true` AND detected gamer role: also suggest MSI Afterburner + HWiNFO64 for monitoring.
- `profile.flags.hasDiscreteGPU=true` AND detected creative role: also suggest OBS (recording), DaVinci Resolve (if not present).
- No dev role detected AND no creative role detected AND WSL not installed: suggest very little for "office" role — Notion, 1Password, Zoom, and stop. Don't push tools they'll never use.
- Windows Home vs Pro: on Home, don't suggest RSAT / Hyper-V Manager (they need Pro/Enterprise).
- Corporate machine (`.domain.joined=true` or MDM-managed): print a caveat that installs may violate corp policy; user should check with IT.
