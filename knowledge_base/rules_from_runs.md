# Rules learned from real pc-cleaner runs

Every time a real user pushes back on a question, that pushback becomes a rule here. Bake into module docs.

## From the 2026-07-05 run on the seed machine

### Bloat module

- **Don't ask about basic Windows utilities.** Notepad, Calculator, Snip & Sketch, Clock/Alarms, Sound Recorder, New Paint, Sticky Notes UWP — always KEEP. These are too niche to ask about; user won't notice their absence and asking wastes a question slot.
- **Photos: KEEP + install IrfanView as the default image viewer.** Windows Photos stays installed (it's what opens JPGs when no default is set). But the ninite-personalized module always offers IrfanView, and if the user accepts, we open `ms-settings:defaultapps` with a hint to set IrfanView for .jpg/.png/.gif/.bmp/.webp/.heic. This is a project-wide recommendation for any user, not just dev.
- **New Outlook: worth asking.** People who don't use Office desktop can remove it. Framing: "You don't use Word/Excel, right? Then you probably don't need New Outlook either."

### Privacy module

- **Don't ask about apps the user doesn't use.** If the user doesn't use Edge, don't ask about Edge tracking prevention — just apply the safest setting and flag Edge for removal in the bloat module. Same for Copilot, OneDrive, Cortana. General rule: **detected-not-in-use → apply defaults silently → offer to remove the app entirely**.
- Edge is removable via `%ProgramFiles(x86)%\Microsoft\Edge\Application\<version>\Installer\setup.exe --uninstall --system-level --verbose-logging --force-uninstall`. Bloat module has a `specialUninstall` array for these.

### Explorer module

- **Dark/light mode: neutral phrasing.** Don't ask "switch to dark mode?" (biased). Ask "Do you prefer light mode or dark mode for Windows?" with equal-weight options. Detect current state and note it: "You currently use light mode."
- **Hidden files: keep the 3-option split** (yes-all, yes-hidden-but-not-system, no). "Yes to everything" is dev-friendly, middle option covers curious users, "no" is default for clickers.

### Storage module

- **Don't ask about Recycle Bin as a standalone question — it's too basic.** Recycle Bin cleanup is an option under Storage Sense config, not a separate ask.
- **Storage Sense granular.** Ask two separate questions:
  1. "Run monthly auto-cleanup?" (yes/no)
  2. "Which categories should it clean?" (checkboxes: temp files / Downloads folder older than N days / Recycle Bin older than N days / OneDrive online-only)
- For most users, default: temp files ON, Recycle Bin OFF, Downloads OFF.

### Ninite-personalized

- **Set-as-default is a real feature.** After installing IrfanView, VLC, Chrome — always offer to set them as defaults for their file types. Open `ms-settings:defaultapps` with instructions.
- Password managers: deliberately omitted (see main data file). If a user asks about them, list 3 options (Bitwarden free / 1Password paid / KeePassXC offline) with one line each — don't push a specific one.

## The seed machine's current state IS the recommendation for non-technical users

Discovered during the 2026-07-05 run when I silently applied 4 explorer UI tweaks and the user pushed back:

> "i dont have this at all, i dont want it. my setting should be the recommended for the non technical users"

**Rule:** For any UI or visual preference (Win11 right-click menu, Widgets button, Search box style, Copilot button, taskbar alignment, etc.), the module MUST:

1. **First: detect what the user currently has set.**
2. **Compare to the seed machine's state** (which represents "recommended for non-technical users").
3. **If the user already matches the recommended baseline → do nothing, don't even ask.**
4. **If the user's state differs from the baseline → ask, framed as "want to try the more common setting?"**
5. **Only technical/developer users get asked "want classic Windows 10 style?" — that's a power-user preference, not a recommendation for everyone.**

The idea is that the seed machine's owner (a moderately-technical solo developer) has curated defaults that a typical non-technical user would find comfortable. That curated state = baseline.

Concrete decisions from this:
- Windows 11 right-click menu (default, two-step for advanced) is what non-technical users get.
- Widgets button hidden = recommended for non-technical.
- Search box hidden = recommended for non-technical.
- Copilot button hidden = recommended for non-technical (also matches the "don't advertise Microsoft products they don't use" principle).
- Light mode = recommended for non-technical (matches what most people have out of the box).

## Elevation

- pc-cleaner requires admin. Instead of trying to elevate mid-run (which produces UAC prompts that users can't see reliably), the tool must check admin at the very start.
- If not admin: explain plainly, tell them to relaunch Claude Code as Administrator, stop.
- Once admin: proceed with all applies in the same elevated session.

## Global rules — apply to every module

1. **If the user answers "I don't use [App X]" for any app, immediately:**
   - Apply defaults for all settings related to that app (usually "off").
   - Add the app to the bloat module's plan if it's removable.
   - Don't ask any further questions about it.
2. **Add "I'm not sure" to every yes/no question.** Never a trap.
3. **Neutral phrasing for preferences.** "Do you prefer X or Y?" not "Do you want to change to Y?"
4. **Basics never get asked about.** Notepad, Calculator, File Explorer defaults, Recycle Bin, Volume tray icon, Network tray icon.
5. **User profile (from the intake questions) overrides module defaults.** Clicker asked about → nothing dev-related. Developer asked about → everything.
