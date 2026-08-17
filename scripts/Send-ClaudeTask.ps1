<#
.SYNOPSIS
    Send a task to one of the running Claude windows, or to all of them.

.DESCRIPTION
    Finds a window opened by Open-QuadClaude.ps1 by its name, focuses it, types
    the task into the Claude session running there, and presses Enter.

    Typing is done with SendInput in Unicode mode rather than by pasting. That
    keeps the clipboard untouched - a manager dispatching tasks should not be
    stealing the user's clipboard - and it sidesteps every quoting and escaping
    problem, since each character is delivered as a character rather than being
    parsed by anything on the way.

    Focus is required: keystrokes go to whatever window is in the foreground, so
    the target has to be brought there first. Whatever was focused before is
    restored afterwards, so dispatching a task does not steal the user's place.

.PARAMETER To
    Window name to send to, e.g. 'backend'. Use 'all' to broadcast.

.PARAMETER Task
    The prompt to type. Newlines are collapsed to spaces, because Enter submits
    in Claude and a literal newline would send the task half-finished.

.PARAMETER NoSubmit
    Type the task but do not press Enter, leaving it for review.

.PARAMETER SettleMs
    Pause after focusing before typing. Raise it if keystrokes arrive truncated.

.EXAMPLE
    .\Send-ClaudeTask.ps1 -To backend -Task "Review src/auth for race conditions"

.EXAMPLE
    .\Send-ClaudeTask.ps1 -To all -Task "Summarise what you just changed"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $To,
    [Parameter(Mandatory)][string] $Task,
    [switch] $NoSubmit,
    [int]    $SettleMs = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([IntPtr]::Size -ne 8) {
    throw "This script needs 64-bit PowerShell; the SendInput struct layout below is the x64 one."
}

function Initialize-Input {
    if ('QuadClaude.Input' -as [type]) { return }
    Add-Type -Namespace QuadClaude -Name Input -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

// x64 layout: 4-byte type, 4 bytes padding, then the union at offset 8.
[StructLayout(LayoutKind.Explicit, Size = 40)]
public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; }

[DllImport("user32.dll", SetLastError = true)]
public static extern uint SendInput(uint n, INPUT[] inputs, int cb);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder t, int c);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder t, int c);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);

const uint INPUT_KEYBOARD = 1;
const uint KEYEVENTF_KEYUP = 0x0002;
const uint KEYEVENTF_UNICODE = 0x0004;

public static System.Collections.Generic.List<string> FindTerminals() {
    var found = new System.Collections.Generic.List<string>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
        if (!IsWindowVisible(h)) return true;
        var c = new System.Text.StringBuilder(256);
        GetClassName(h, c, c.Capacity);
        if (c.ToString() != "CASCADIA_HOSTING_WINDOW_CLASS") return true;
        var t = new System.Text.StringBuilder(512);
        GetWindowText(h, t, t.Capacity);
        found.Add(h.ToInt64() + "\t" + t.ToString());
        return true;
    }, IntPtr.Zero);
    return found;
}

// SetForegroundWindow is refused unless the caller owns the foreground. The
// documented way round it is to attach to the current foreground thread's
// input queue first, which makes us count as part of it.
public static bool Focus(IntPtr h) {
    if (IsIconic(h)) ShowWindow(h, 9);   // SW_RESTORE
    IntPtr fg = GetForegroundWindow();
    if (fg == h) return true;
    uint us = GetCurrentThreadId();
    uint them = GetWindowThreadProcessId(fg, IntPtr.Zero);
    if (us != them) AttachThreadInput(us, them, true);
    bool ok = SetForegroundWindow(h);
    if (us != them) AttachThreadInput(us, them, false);
    return ok;
}

public static uint TypeText(string s) {
    var list = new System.Collections.Generic.List<INPUT>();
    foreach (char ch in s) {
        for (int updown = 0; updown < 2; updown++) {
            var i = new INPUT();
            i.type = INPUT_KEYBOARD;
            i.ki.wVk = 0;
            i.ki.wScan = ch;
            i.ki.dwFlags = KEYEVENTF_UNICODE | (updown == 1 ? KEYEVENTF_KEYUP : 0);
            list.Add(i);
        }
    }
    var arr = list.ToArray();
    return SendInput((uint)arr.Length, arr, Marshal.SizeOf(typeof(INPUT)));
}

public static uint PressEnter() {
    var arr = new INPUT[2];
    for (int k = 0; k < 2; k++) {
        arr[k].type = INPUT_KEYBOARD;
        arr[k].ki.wVk = 0x0D;   // VK_RETURN
        arr[k].ki.dwFlags = (k == 1 ? KEYEVENTF_KEYUP : 0);
    }
    return SendInput((uint)arr.Length, arr, Marshal.SizeOf(typeof(INPUT)));
}
'@
}

Initialize-Input

# Enter submits in Claude, so a literal newline would send a half-written task.
$text = ($Task -replace '\r?\n', ' ').Trim()
if (-not $text) { throw "Task is empty." }

# Live windows, keyed by handle. Titles are deliberately NOT used as the key:
# they are not unique, and a stale window from an earlier run answers to the
# same name. Typing a task into a dead terminal fails silently, which is the
# worst possible failure for a dispatcher.
$live = @{}
foreach ($row in [QuadClaude.Input]::FindTerminals()) {
    $parts = $row -split "`t", 2
    if ($parts.Count -eq 2) { $live[[int64]$parts[0]] = $parts[1] }
}

$StatePath = Join-Path $env:LOCALAPPDATA 'quad-claude\session.json'
$windows   = @{}

if (Test-Path -LiteralPath $StatePath) {
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    foreach ($w in $state.windows) {
        # Trust the recorded handle only if it is still a live terminal window
        # AND still carries the name it was created with, so a recycled handle
        # cannot be mistaken for the original.
        if ($live.ContainsKey([int64]$w.Hwnd) -and $live[[int64]$w.Hwnd] -eq $w.Name) {
            $windows[$w.Name] = [IntPtr][int64]$w.Hwnd
        }
    }
}

if ($windows.Count -eq 0) {
    # No usable state: fall back to matching titles, but refuse when the name is
    # ambiguous rather than picking one and hoping.
    Write-Verbose "No usable session state; falling back to title matching."
    $byName = @{}
    foreach ($h in $live.Keys) {
        $n = $live[$h]
        if (-not $n) { continue }
        if (-not $byName.ContainsKey($n)) { $byName[$n] = @() }
        $byName[$n] += $h
    }
    foreach ($n in $byName.Keys) {
        if ($byName[$n].Count -gt 1) {
            throw "More than one window is called '$n' and there is no session state to tell them apart. Close the stale one, or relaunch with Open-QuadClaude.ps1 to record fresh handles."
        }
        $windows[$n] = [IntPtr][int64]$byName[$n][0]
    }
}

if ($To -eq 'all') {
    $targets = @($windows.Keys | Where-Object { $_ -notmatch '^\s*$' })
    if ($targets.Count -eq 0) { throw "No terminal windows found." }
} else {
    $match = $windows.Keys | Where-Object { $_ -eq $To } | Select-Object -First 1
    if (-not $match) {
        $match = $windows.Keys | Where-Object { $_ -like "*$To*" } | Select-Object -First 1
    }
    if (-not $match) {
        throw "No window named '$To'. Open windows: $(($windows.Keys | Sort-Object) -join ', ')"
    }
    $targets = @($match)
}

$previous = [QuadClaude.Input]::GetForegroundWindow()
$sent = @()

foreach ($name in $targets) {
    $h = $windows[$name]

    if (-not [QuadClaude.Input]::Focus($h)) {
        Write-Warning "Could not focus '$name'; skipped."
        continue
    }
    Start-Sleep -Milliseconds $SettleMs

    if ([QuadClaude.Input]::GetForegroundWindow() -ne $h) {
        Write-Warning "'$name' did not come to the foreground; skipped rather than typing into the wrong window."
        continue
    }

    [void][QuadClaude.Input]::TypeText($text)
    if (-not $NoSubmit) {
        Start-Sleep -Milliseconds 150
        [void][QuadClaude.Input]::PressEnter()
    }
    $sent += $name
    Start-Sleep -Milliseconds 200
}

# Put the user back where they were.
if ($previous -ne [IntPtr]::Zero) { [void][QuadClaude.Input]::Focus($previous) }

if ($sent.Count -eq 0) {
    throw "Task was not delivered to any window."
}
Write-Host "Sent to $($sent -join ', '): $text"
