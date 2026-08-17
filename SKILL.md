---
name: quad-claude
description: Use when the user wants several Claude Code sessions open side by side on one screen, or wants to hand a task to one of them - "open 4 claudes", "quad terminal", "give me 3 terminals on monitor 2", "5 claudes on the portrait screen", "tile some claude windows", "tell the backend one to run the tests". Opens any number of separate, named Windows Terminal windows running cmd, tiled flush across a chosen monitor, each running claude, and can type tasks into them afterwards.
---

# Quad Claude

Separate Windows Terminal windows running Claude Code, tiled flush across
whichever monitor the user names. Four by default; `-Count` takes 1 to 16.

```
+-----------+-----------+
|     1     |     2     |
+-----------+-----------+
|     3     |     4     |
+-----------+-----------+
```

They are real windows, not panes in one window: each has its own title bar
showing its name, its own taskbar entry, and can be moved or closed on its own.
The shell is `cmd`.

## How to run it

```powershell
& "$env:USERPROFILE\.claude\skills\quad-claude\scripts\Open-QuadClaude.ps1" `
    -Monitor 2 `
    -Titles backend,frontend,tests,notes `
    -WorkingDir "C:\path\to\project"
```

All parameters are optional. With none, you get `Claude 1`..`Claude 4` on the
primary monitor, all starting in the current directory.

| Parameter | Meaning |
|---|---|
| `-Monitor` | `1..N` left-to-right, or `primary` (default), `left`, `right`, `portrait`, or a device-name substring like `DISPLAY6` |
| `-Count` | how many windows, 1-16. Defaults to the number of `-Titles` given, or 4 |
| `-Titles` | window names; missing ones fill in as `Claude <n>` |
| `-WorkingDir` | starting directory for all four windows; defaults to the current directory |
| `-Gap` | pixels between the tiled windows; default `0` (flush) |
| `-SkipPermissions` | start Claude with `--dangerously-skip-permissions`. **On by default**; pass `-SkipPermissions:$false` for sessions that should still prompt |
| `-NoClaude` | tile four plain cmd windows instead of starting Claude - use this to test layout changes |
| `-DryRun` | print the resolved plan and each `wt.exe` argument list, launch nothing |

`--dangerously-skip-permissions` does **not** skip the first-run workspace trust
prompt ("Is this a project you trust?"). That is a separate check, and it still
needs one Enter per window the first time a folder is used.

Always test layout changes with `-NoClaude` first. Four real sessions is a lot
to throw away because a window landed wrong.

## Layouts

Four is only the default. `-Count` tiles any number from 1 to 16:

```
2                3                4                5
+-----+-----+    +-----+-----+    +-----+-----+    +---+---+---+
|     |     |    |     |  2  |    |  1  |  2  |    | 1 | 2 | 3 |
|  1  |  2  |    |  1  +-----+    +-----+-----+    +---+-+-+---+
|     |     |    |     |  3  |    |  3  |  4  |    |  4  |  5  |
+-----+-----+    +-----+-----+    +-----+-----+    +-----+-----+
```

1-6 are hand-picked shapes; above 6 it falls back to a balanced grid of
`ceil(sqrt(n))` rows with the remainder spread across the top rows. 3 is the
one worth noting - two-then-one leaves a lonely wide window, so it is one tall
beside two stacked instead.

Every layout is built by `Split-Span`, which computes each boundary from the
span's own arithmetic (`floor(i*avail/N)`) rather than by accumulating piece
sizes. Rounding therefore cannot drift: whatever the remainder, pieces meet
edge to edge and cover the span exactly. Verified for counts 1-7 by summing
window areas and checking the total equals the working area exactly.

Accent themes cycle every four, so a fifth window is themed rather than blank.

## Giving a running window a task

`Send-ClaudeTask.ps1` types a prompt into a named window and presses Enter, so
Claude can hand work to sessions it started:

```powershell
& "$env:USERPROFILE\.claude\skills\quad-claude\scripts\Send-ClaudeTask.ps1" `
    -To backend -Task "Review src/auth for race conditions"
```

`-To all` broadcasts. `-NoSubmit` types without pressing Enter.

Typing is `SendInput` in Unicode mode, not a clipboard paste: the clipboard
belongs to the user, and per-character delivery sidesteps every quoting problem.
Keystrokes go to the foreground window, so the target is focused first and
whatever was focused before is restored afterwards. Newlines in a task are
collapsed to spaces, because Enter submits and a literal newline would send it
half-written.

**Targets are resolved through `session.json`, not by window title.** Titles are
not unique - a stale window left over from an earlier run answers to the same
name, and a task typed into a dead terminal fails silently, which is the worst
way for a dispatcher to fail. `Open-QuadClaude.ps1` records the handles it
creates; `Send-ClaudeTask.ps1` re-validates each against the live window list
and its title before using it. If state is missing it falls back to title
matching but refuses when a name is ambiguous rather than guessing.

## Reading the user's monitor request

Screens are sorted left-to-right by X coordinate, so `-Monitor 1` is always the
physically leftmost screen. This is re-derived on every run, so it survives a
monitor being unplugged or rearranged.

To see the current layout:

```powershell
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X } |
    Format-Table DeviceName, Primary, Bounds
```

If the user says something vague like "my left screen" or "the tall one", map it
to `left` or `portrait` rather than guessing an index.

## How the alignment works

Each window is launched with `--pos` near its quadrant, then moved with
`SetWindowPos` to exact bounds. The second step is what makes it flush.

Every Windows window has an **invisible resize border** around it, roughly 7px
on the left, right and bottom. `GetWindowRect` includes that border, so tiling
by those numbers leaves a visible gap of about 14px between neighbours. The real
visible edge comes from `DWMWA_EXTENDED_FRAME_BOUNDS` (attribute `9`). The
script measures the difference between the two rectangles and adds it back, so
the *visible* frames land exactly on the target quadrants.

Quadrants come from the monitor's **working area**, not its bounds, so windows
never end up behind the taskbar. The second half of each axis is computed by
subtraction rather than doubling, so odd widths and heights still tile exactly
with no seam.

A correct run on a 1920x1080 screen (1032px work area) produces four windows of
exactly 960x516 at `0,0`, `960,0`, `0,516`, `960,516`.

## Colour

Each window applies its own theme at startup by writing OSC escape sequences:
`OSC 4` for the sixteen palette slots, `OSC 10/11/12` for foreground, background
and cursor. Every colour a CLI prints resolves through those sixteen slots, so
setting them is what makes Claude's output colourful rather than white on black.

This is deliberately done with escape sequences rather than a Terminal colour
scheme. A scheme lives in the profile fragment, and fragments only load when
Terminal starts, so a scheme would not apply until the user had closed every
Terminal window. OSC sequences apply to the live session immediately.

All windows share one neutral dark background (`#0d1117`). Per-window tints were
tried and dropped: they cut the contrast of everything Claude printed on top,
and identity is better carried by a coloured accent than by washing the whole
surface. Each window's accent shows in its banner and its shell prompt, and the
accents cycle every four.

The shell prompt is coloured too, with SGR codes in the `PROMPT` string - `$E`
is cmd's own escape character there, so it needs no ESC variable. Without that
the prompt renders default white, which was the giveaway that a monochrome
Claude was an environment problem and not a terminal one.

All of it is in `Start-ClaudeWindow.cmd` - change it there, in one place.

## Boot animations

Every window plays a short animation before Claude starts. `-Anim` picks one:

| Style | What it does |
|---|---|
| `random` | default - a different one per window, every launch |
| `matrix` | katakana rain that resolves into the window name |
| `bios` | fake POST checks, then a gradient progress bar |
| `glitch` | scrambled noise locking into the name, with a chromatic split |
| `wave` | twin sine waves in cycling hues, name fading up between them |
| `figlet` | big block letters via pyfiglet, in a rich panel with a spinner |
| `off` | no animation |

**One style per launch, shared by every window.** `random` is rolled once in
`Open-QuadClaude.ps1`, not inside each window: the windows open as a set and
should read as one machine booting. Letting each roll its own looked like four
unrelated things starting. The saved value stays `random`, so it re-rolls per
launch rather than per window.

`-AnimMs` sets the length, default 3000. `-StaggerMs` (default 300, only past
two windows) spaces the launches so the animations cascade rather than collide.

**Every animation adapts to resize.** Window size is re-read each frame and the
layout rebuilt when it changes, so dragging the window mid-animation reflows
the rain, waves and panels instead of tearing them.

**The sequence is intro, then outro, then Claude** - all before the session.
The outro is the hand-off: the name, `launching claude`, and two accent shutters
closing across it, so the session does not appear on top of a half-finished
flourish. One outro rather than one per style, because whichever intro just
played, this is the same beat: stop, hand over.

Four styles are pure PowerShell (`Show-BootAnimation.ps1`). cmd cannot do this
itself - no sub-second sleep, no cursor control - so the batch shells out to
PowerShell, which gets ANSI cursor addressing and 24-bit colour with no
dependencies.

`figlet` is the exception: it runs `splash.py` (pyfiglet + rich), because real
block-letter type needs a font database and pyfiglet ships 571. If Python or
pyfiglet is missing it falls back to `glitch` rather than leaving a blank
window. The attempt is the availability check - probing first would cost an
extra interpreter start on every launch.

Animations run before Claude, not alongside it, because cmd is sequential.
Budget is ~1.7s. Keep it short: this is time the user waits.

### Three traps, all found the hard way

**Console encoding, not font.** Non-ASCII glyphs arrive as `?` unless
`[Console]::OutputEncoding` is UTF-8 - the console encodes in its code page,
which has no katakana and no block characters. `?` means mis-encoded; a missing
glyph would render as a box instead. Same fix on the Python side with
`sys.stdout.reconfigure(encoding="utf-8")`.

**Grab the writer after setting the encoding.** Assigning `OutputEncoding`
builds a *new* writer. A handle cached beforehand keeps writing through the old
encoding, so the fix silently does nothing.

**`NO_COLOR` must be cleared before the animation, not just before Claude.**
The PowerShell animations emit raw ANSI and ignore it, but rich honours it, so
the figlet splash rendered in monochrome while the others looked fine.

## If Claude renders monochrome, it is NO_COLOR

A Claude session sets `NO_COLOR=1` in the environment of every process it
spawns, so the command output it captures stays plain text. If these windows
are opened *from inside* a Claude session - which is exactly what happens when
Claude runs this skill for the user - that variable is inherited all the way
down, and Claude in the new window honours it and renders completely
monochrome. Coloured background, white text, nothing else.

The same inheritance carries `CLAUDE_CODE_CHILD_SESSION`, which turns transcript
saving off and shows a warning in the status line.

`Start-ClaudeWindow.cmd` clears both, plus the other session markers, immediately
before launching. These windows are meant to be independent sessions, not
children of whatever spawned them.

Worth knowing because the symptom points the wrong way: it looks like a terminal
colour problem, so the instinct is to go fix palettes and colour schemes. The
terminal is fine - the shell prompt right above it is colourful. Claude was told
not to use colour. To confirm which it is, check whether SGR output from the
shell itself is coloured; if it is, the terminal is not the problem.

## Two traps worth remembering

**`wt.exe` splits its command line on `;` even inside a single quoted argument.**
The tail after the semicolon is re-read as a `wt` subcommand, which silently
produces junk tabs and a garbage window title. This is why each window's startup
lives in `Start-ClaudeWindow.cmd` instead of being an inline command, and why the
banner colour is passed as a window *number*: ANSI colour codes are
semicolon-separated, so passing `104;97` through `wt.exe` would split the
command. The colour lookup happens inside the batch file.

`wt.exe` *does* preserve quoting of arguments it passes on to the shell, so
window names containing spaces are safe as plain arguments.

**Window naming needs `suppressApplicationTitle`.** Claude renames the terminal
while it works, which would overwrite the name. The `Claude` profile sets this,
with `--suppressApplicationTitle` on the command line as the fallback.

## The Claude profile

`scripts/Install-ClaudeProfile.ps1` installs a Windows Terminal *fragment* at

```
%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\quad-claude\claude-window.json
```

A fragment adds a profile without touching the user's `settings.json`, so
uninstalling is `-Uninstall`, which deletes that one file.

The profile exists for the two settings the `wt` command line cannot express:

- `closeOnExit` - controls the `[process exited] ... you can configure this in
  your profile settings` notice left in a window when its shell dies. Default
  here is `graceful`: clean exits close silently, crashes stay open so you can
  read them. Pass `-CloseOnExit always` to never see the notice, at the cost of
  a crashed session vanishing before you can read it.
- `suppressApplicationTitle` - keeps the name you gave the window.

`Open-QuadClaude.ps1` installs the fragment automatically on first run.

**Terminal only reads fragments at startup.** If Terminal is already running,
the profile is not live until every Terminal window has been closed once. The
script detects this by comparing the fragment's timestamp against the oldest
`WindowsTerminal` process start time, and falls back to the default profile
meanwhile - the windows still open and tile either way. If the user asks why
exit behaviour has not changed, this is why: close all Terminal windows once.

## Verifying a change

Measure, do not eyeball. Read each window's *visible* frame and check the edges
meet:

```powershell
Add-Type -Namespace V -Name W -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
'@
# DwmGetWindowAttribute(hwnd, 9, out rect, 16) -> visible frame
```

Neighbouring edges must be equal numbers, and all four windows the same size.
A screenshot is a good second check but a bad first one - a 7px seam is easy to
miss by eye and obvious in the numbers.

## Cleaning up test windows

Never kill the `WindowsTerminal` process - all windows share one process, so
that takes the user's other sessions with it. Close by exact window title with
`PostMessage(hwnd, WM_CLOSE)`, or kill only the specific shell PIDs.
