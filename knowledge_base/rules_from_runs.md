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

## Global rules — apply to every module

1. **If the user answers "I don't use [App X]" for any app, immediately:**
   - Apply defaults for all settings related to that app (usually "off").
   - Add the app to the bloat module's plan if it's removable.
   - Don't ask any further questions about it.
2. **Add "I'm not sure" to every yes/no question.** Never a trap.
3. **Neutral phrasing for preferences.** "Do you prefer X or Y?" not "Do you want to change to Y?"
4. **Basics never get asked about.** Notepad, Calculator, File Explorer defaults, Recycle Bin, Volume tray icon, Network tray icon.
5. **User profile (from the intake questions) overrides module defaults.** Clicker asked about → nothing dev-related. Developer asked about → everything.
