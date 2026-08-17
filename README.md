# quad-claude

Open four named [Claude Code](https://claude.com/claude-code) sessions in four
separate Windows Terminal windows, tiled flush into the quadrants of whichever
monitor you name.

```
+-----------+-----------+
|  backend  | frontend  |
+-----------+-----------+
|   tests   |   notes   |
+-----------+-----------+
```

Four real windows, not panes: each has its own title bar showing its name, its
own taskbar entry, and closes on its own. The shell is `cmd`.

It is also a [Claude Code skill](https://docs.claude.com/en/docs/claude-code/skills),
so you can just ask Claude for "4 claudes on my left monitor" and it will run it.

## Install

Clone into your Claude skills directory:

```powershell
git clone https://github.com/ibrokhimel/quad-claude "$env:USERPROFILE\.claude\skills\quad-claude"
```

Requires Windows Terminal and Windows PowerShell 5.1 (both ship with Windows 11).

## Use

```powershell
& "$env:USERPROFILE\.claude\skills\quad-claude\scripts\Open-QuadClaude.ps1" `
    -Monitor 2 `
    -Titles backend,frontend,tests,notes `
    -WorkingDir "C:\path\to\project"
```

Every parameter is optional. With none, you get `Claude 1`..`Claude 4` on the
primary monitor, starting in the current directory.

| Parameter | Meaning |
|---|---|
| `-Monitor` | `1..N` left-to-right, or `primary` (default), `left`, `right`, `portrait`, or a device name like `DISPLAY6` |
| `-Titles` | one to four window names |
| `-WorkingDir` | starting directory for all four windows |
| `-Gap` | pixels between windows; default `0` |
| `-SkipPermissions` | start Claude with `--dangerously-skip-permissions`; on by default, `-SkipPermissions:$false` to opt out |
| `-NoClaude` | tile four plain `cmd` windows instead of starting Claude |
| `-DryRun` | print the plan and the `wt.exe` arguments, launch nothing |

`--dangerously-skip-permissions` does not skip the first-run workspace trust
prompt — that is a separate check and still wants one Enter per window the first
time you use a folder.

## Colour

Each window writes its own theme at startup with OSC escape sequences: `OSC 4`
for the sixteen palette slots, `OSC 10/11/12` for foreground, background and
cursor. Every coloured thing a CLI prints resolves through those sixteen slots,
which is what makes Claude's output colourful instead of white on black.

Escape sequences rather than a Terminal colour scheme, on purpose: schemes live
in the profile fragment, fragments only load at Terminal startup, and OSC applies
to the live session immediately.

Backgrounds are dark tints — navy, purple, amber, green — so output stays
readable on top, and each window is identifiable at a glance. All four share one
vivid palette. It all lives in `scripts/Start-ClaudePane.cmd`.

## Why it is not just four `wt --pos` calls

**The invisible border.** Every Windows window carries a ~7px invisible resize
border. `GetWindowRect` includes it, so tiling by those numbers leaves a ~14px
visible gap between neighbours. The real edge is
`DWMWA_EXTENDED_FRAME_BOUNDS`; the difference between the two is measured and
added back, which is what makes the windows sit flush.

**`wt.exe` splits its command line on `;`** — even inside a single quoted
argument. Anything after the semicolon is re-read as a `wt` subcommand, which
silently produces junk tabs and a garbage window title. So each window's startup
lives in `scripts/Start-ClaudePane.cmd`, and the banner colour is passed as a
window *number*, because ANSI colour codes are semicolon-separated and would
split the command.

**Quadrants come from the working area**, not the screen bounds, so nothing hides
behind the taskbar. The second half of each axis is computed by subtraction, so
odd sizes still tile without a seam.

On a 1920x1080 screen this produces four windows of exactly 960x516 at `0,0`,
`960,0`, `0,516` and `960,516`.

## The Claude Terminal profile

`scripts/Install-ClaudePaneProfile.ps1` installs a Windows Terminal *fragment* —
a profile added by dropping in one JSON file, with your own `settings.json` left
untouched. `-Uninstall` deletes it.

It carries the two settings the `wt` command line cannot express:

- `closeOnExit` — kills the `[process exited] ... configure this in your profile
  settings` notice. Default `graceful`: clean exits close silently, crashes stay
  open so you can read them. `-CloseOnExit always` to never see it at all.
- `suppressApplicationTitle` — stops Claude renaming the window out from under
  the name you gave it.

Installed automatically on first run. Terminal only reads fragments at startup,
so if Terminal was already running the profile goes live after you have closed
every Terminal window once. Until then the windows still open and tile normally.

## Files

| File | Purpose |
|---|---|
| `SKILL.md` | the skill definition Claude reads |
| `scripts/Open-QuadClaude.ps1` | resolves the monitor, launches and tiles the four windows |
| `scripts/Start-ClaudePane.cmd` | per-window startup: colour theme, title, banner, launch Claude |
| `scripts/Install-ClaudePaneProfile.ps1` | installs/removes the Terminal profile fragment |
