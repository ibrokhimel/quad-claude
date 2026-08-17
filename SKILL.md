---
name: quad-claude
description: Use when the user wants several Claude Code sessions open side by side on one screen - "open 4 claudes", "quad terminal", "give me 4 terminals on monitor 2", "4 claudes on the portrait screen", "tile some claude windows". Opens four separate, named Windows Terminal windows running cmd, tiled flush into the four quadrants of a chosen monitor, each running claude.
---

# Quad Claude

Four separate Windows Terminal windows running Claude Code, tiled flush into the
quadrants of whichever monitor the user names.

```
+-----------+-----------+
|     1     |     2     |
+-----------+-----------+
|     3     |     4     |
+-----------+-----------+
```

They are four real windows, not panes in one window: each has its own title bar
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
| `-Titles` | one to four window names; missing ones fill in as `Claude <n>` |
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

Backgrounds are dark tints, one per window, so Claude's output stays readable
on top: navy, purple, amber, green for windows 1-4. The banner colour matches.
All four share one vivid palette. Everything is in `Start-ClaudePane.cmd` -
change it there, in one place.

## If Claude renders monochrome, it is NO_COLOR

A Claude session sets `NO_COLOR=1` in the environment of every process it
spawns, so the command output it captures stays plain text. If these windows
are opened *from inside* a Claude session - which is exactly what happens when
Claude runs this skill for the user - that variable is inherited all the way
down, and Claude in the new window honours it and renders completely
monochrome. Coloured background, white text, nothing else.

The same inheritance carries `CLAUDE_CODE_CHILD_SESSION`, which turns transcript
saving off and shows a warning in the status line.

`Start-ClaudePane.cmd` clears both, plus the other session markers, immediately
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
lives in `Start-ClaudePane.cmd` instead of being an inline command, and why the
banner colour is passed as a window *number*: ANSI colour codes are
semicolon-separated, so passing `104;97` through `wt.exe` would split the
command. The colour lookup happens inside the batch file.

`wt.exe` *does* preserve quoting of arguments it passes on to the shell, so
window names containing spaces are safe as plain arguments.

**Window naming needs `suppressApplicationTitle`.** Claude renames the terminal
while it works, which would overwrite the name. The `Claude` profile sets this,
with `--suppressApplicationTitle` on the command line as the fallback.

## The Claude profile

`scripts/Install-ClaudePaneProfile.ps1` installs a Windows Terminal *fragment* at

```
%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\quad-claude\claude-pane.json
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
