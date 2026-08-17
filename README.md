# quad-claude

Open any number of named [Claude Code](https://claude.com/claude-code) sessions
in separate Windows Terminal windows, tiled flush across whichever monitor you
name — and hand them tasks from outside.

```
+-----------+-----------+
|  backend  | frontend  |
+-----------+-----------+
|   tests   |   notes   |
+-----------+-----------+
```

Real windows, not panes: each has its own title bar showing its name, its own
taskbar entry, and closes on its own. The shell is `cmd`. Four is the default;
`-Count` takes 1 to 16.

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
| `-Count` | how many windows, 1-16; defaults to the number of `-Titles`, or 4 |
| `-Anim` | animation style; omit to use the saved default |
| `-AnimMs` | animation length in ms, default 3000 |
| `-StaggerMs` | gap between window launches, default 300, only past two windows |
| `-SaveDefaults` | remember this run's `-Anim` / `-AnimMs` / `-StaggerMs` for later launches |
| `-Titles` | window names |
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

All windows share one neutral dark background (`#0d1117`). Per-window tints were
tried and dropped — they cut the contrast of everything Claude printed on top,
and identity is better carried by a coloured accent than by washing the whole
surface. Each window's accent shows in its banner and its shell prompt, cycling
every four.

It all lives in `scripts/Start-ClaudeWindow.cmd`.

## Boot animations

Every window plays a short animation before Claude starts. `-Anim` picks one:

| Style | What it does |
|---|---|
| `random` | default — a different one per window, every launch |
| `matrix` | katakana rain resolving into the window name |
| `bios` | fake POST checks, then a gradient progress bar |
| `glitch` | scrambled noise locking into the name, with a chromatic split |
| `wave` | twin sine waves in cycling hues, name fading up between them |
| `figlet` | big block letters via pyfiglet, in a rich panel with a spinner |
| `off` | no animation |

The sequence per window is **intro → outro → Claude**, all before the session.
The outro is the hand-off — the name, `launching claude`, and two accent
shutters closing across it — so Claude doesn't appear on top of a half-finished
flourish.

`random` is rolled **once per launch, not per window**: the windows open as a
set and should read as one machine booting. `-AnimMs` sets the length (default
3000) and `-StaggerMs` (default 300, only past two windows) offsets them so the
animations cascade rather than collide.

Every animation **adapts to resize** — window size is re-read each frame and the
layout rebuilt, so dragging mid-animation reflows instead of tearing.

Four styles are pure PowerShell. cmd can't animate — no sub-second sleep, no
cursor control — so the batch shells out to PowerShell for ANSI cursor
addressing and 24-bit colour, with no dependencies.

`figlet` runs `splash.py` (pyfiglet + rich), because real block-letter type
needs a font database. Missing Python or pyfiglet falls back to `glitch` rather
than leaving a blank window.

Budget is ~1.7s, before Claude rather than alongside it — cmd is sequential.

**Three traps, if you fork this:** non-ASCII arrives as `?` unless the console
encoding is UTF-8 (`?` = mis-encoded; a missing glyph would be a box); the
writer must be grabbed *after* setting that encoding, since assigning it builds
a new one; and `NO_COLOR` has to be cleared before the animation, not just
before Claude, because rich honours it while raw ANSI doesn't.

## Layouts

Four is the default, not the limit:

```
2                3                4                5
+-----+-----+    +-----+-----+    +-----+-----+    +---+---+---+
|     |     |    |     |  2  |    |  1  |  2  |    | 1 | 2 | 3 |
|  1  |  2  |    |  1  +-----+    +-----+-----+    +---+-+-+---+
|     |     |    |     |  3  |    |  3  |  4  |    |  4  |  5  |
+-----+-----+    +-----+-----+    +-----+-----+    +-----+-----+
```

1–6 are hand-picked shapes; above 6 it falls back to a balanced grid. 3 is the
interesting one — two-then-one leaves a lonely wide window, so it is one tall
beside two stacked.

Boundaries are computed from the span's own arithmetic (`floor(i*avail/N)`)
rather than by accumulating sizes, so rounding cannot drift. Verified for
counts 1–7 by summing window areas against the working area: exact every time.

## Handing a window a task

```powershell
& "$env:USERPROFILE\.claude\skills\quad-claude\scripts\Send-ClaudeTask.ps1" `
    -To backend -Task "Review src/auth for race conditions"
```

Types the prompt into that window's running Claude and presses Enter. `-To all`
broadcasts, `-NoSubmit` leaves it unsent for review.

`SendInput` in Unicode mode rather than a clipboard paste — the clipboard
belongs to the user, and per-character delivery sidesteps every quoting problem.
The target window is focused first (keystrokes follow focus) and whatever was
focused before is restored after.

Targets resolve through `session.json`, which records the handles the launcher
created — **not** by window title. Titles are not unique: a stale window from an
earlier run answers to the same name, and a task typed into a dead terminal
fails silently. Found that one the hard way.

## Why it is not just four `wt --pos` calls

**The invisible border.** Every Windows window carries a ~7px invisible resize
border. `GetWindowRect` includes it, so tiling by those numbers leaves a ~14px
visible gap between neighbours. The real edge is
`DWMWA_EXTENDED_FRAME_BOUNDS`; the difference between the two is measured and
added back, which is what makes the windows sit flush.

**`wt.exe` splits its command line on `;`** — even inside a single quoted
argument. Anything after the semicolon is re-read as a `wt` subcommand, which
silently produces junk tabs and a garbage window title. So each window's startup
lives in `scripts/Start-ClaudeWindow.cmd`, and the banner colour is passed as a
window *number*, because ANSI colour codes are semicolon-separated and would
split the command.

**Quadrants come from the working area**, not the screen bounds, so nothing hides
behind the taskbar. The second half of each axis is computed by subtraction, so
odd sizes still tile without a seam.

On a 1920x1080 screen this produces four windows of exactly 960x516 at `0,0`,
`960,0`, `0,516` and `960,516`.

## If Claude renders monochrome, it is `NO_COLOR`

A Claude session sets `NO_COLOR=1` in the environment of every process it spawns,
so the output it captures stays plain text. Open these windows *from inside* a
Claude session and that variable is inherited all the way down — Claude in the
new window honours it and renders completely monochrome. The same inheritance
carries `CLAUDE_CODE_CHILD_SESSION`, which turns transcript saving off.

`scripts/Start-ClaudeWindow.cmd` clears both, plus the other session markers,
right before launching. These windows are independent sessions, not children of
whatever spawned them.

The symptom points the wrong way — it looks like a terminal colour problem, so
the instinct is to go fix palettes. The terminal is fine; the coloured shell
prompt one line above proves it. Claude had simply been told not to use colour.

## The Claude Terminal profile

`scripts/Install-ClaudeProfile.ps1` installs a Windows Terminal *fragment* —
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
| `scripts/Start-ClaudeWindow.cmd` | per-window startup: colour theme, title, banner, launch Claude |
| `scripts/Install-ClaudeProfile.ps1` | installs/removes the Terminal profile fragment |
