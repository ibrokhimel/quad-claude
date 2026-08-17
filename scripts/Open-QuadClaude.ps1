<#
.SYNOPSIS
    Opens four separate, named Windows Terminal windows running Claude Code,
    tiled flush into the four quadrants of the monitor you choose.

.DESCRIPTION
    Four independent Terminal windows, one per quadrant:

        +-----------+-----------+
        |     1     |     2     |
        +-----------+-----------+
        |     3     |     4     |
        +-----------+-----------+

    Each is a real window - its own title bar, its own taskbar entry, movable
    and closable on its own - and each runs cmd.

    Alignment is done in two steps. Each window is launched with --pos near its
    quadrant, then moved with SetWindowPos to exact pixel bounds. The second
    step compensates for the invisible resize border Windows puts around every
    window: GetWindowRect includes it, so tiling by those numbers leaves a
    visible gap of roughly 7px between neighbours. The real visible edge comes
    from DWMWA_EXTENDED_FRAME_BOUNDS, and the difference between the two is
    added back, which is what makes the four windows sit truly flush.

    Quadrants are computed from the monitor's working area, so windows never
    hide behind the taskbar, and the halves are derived by subtraction rather
    than doubling so odd widths and heights still tile exactly.

.PARAMETER Monitor
    Which display to use. Accepts:
      - an index 1..N, ordered left-to-right by screen X coordinate
      - 'primary'  (default)
      - 'left' / 'right'      - leftmost / rightmost screen
      - 'portrait'            - first screen taller than it is wide
      - a device-name substring, e.g. 'DISPLAY6'

.PARAMETER Titles
    One to four window names. Missing names are filled with 'Claude <n>'.

.PARAMETER WorkingDir
    Starting directory for all four windows. Defaults to the current directory.

.PARAMETER Gap
    Pixels of space to leave between the tiled windows. Default 0 (flush).

.PARAMETER SkipPermissions
    Start Claude with --dangerously-skip-permissions. On by default; use
    -SkipPermissions:$false for sessions that should still prompt.

.PARAMETER NoClaude
    Tile four plain cmd windows instead of starting Claude. For testing layout.

.PARAMETER DryRun
    Print the resolved plan and each wt.exe argument list, launch nothing.

.EXAMPLE
    .\Open-QuadClaude.ps1
    Four 'Claude 1'..'Claude 4' windows on the primary monitor.

.EXAMPLE
    .\Open-QuadClaude.ps1 -Monitor 2 -Titles backend,frontend,tests,notes
    Named windows tiled on the second monitor from the left.
#>
[CmdletBinding()]
param(
    [string]   $Monitor    = 'primary',
    [string[]] $Titles     = @(),
    [string]   $WorkingDir = $PWD.Path,
    [int]      $Gap        = 0,
    [bool]     $SkipPermissions = $true,
    [switch]   $NoClaude,
    [switch]   $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Banner colours live in Start-ClaudePane.cmd, keyed by window number. They
# cannot be passed through here: ANSI colour codes are semicolon-separated and
# wt.exe splits its command line on ';' even inside a quoted argument.
$ProfileName  = 'Claude'
$FragmentPath = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\quad-claude\claude-pane.json'
$PaneScript   = Join-Path $PSScriptRoot 'Start-ClaudePane.cmd'

function Get-SortedScreens {
    Add-Type -AssemblyName System.Windows.Forms
    # Left-to-right, so 'monitor 1' means the one physically on the left.
    return @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X })
}

function Resolve-TargetScreen {
    param([string]$Spec)

    $screens = Get-SortedScreens

    $index = 0
    if ([int]::TryParse($Spec, [ref]$index)) {
        if ($index -lt 1 -or $index -gt $screens.Count) {
            throw "Monitor $index does not exist. You have $($screens.Count) screen(s), numbered 1..$($screens.Count) left to right."
        }
        return $screens[$index - 1]
    }

    switch -Regex ($Spec) {
        '^(?i)primary$'  { return ($screens | Where-Object { $_.Primary } | Select-Object -First 1) }
        '^(?i)left$'     { return $screens[0] }
        '^(?i)right$'    { return $screens[-1] }
        '^(?i)portrait$' {
            $p = $screens | Where-Object { $_.Bounds.Height -gt $_.Bounds.Width } | Select-Object -First 1
            if (-not $p) { throw "No portrait (taller-than-wide) monitor found." }
            return $p
        }
    }

    $match = $screens | Where-Object { $_.DeviceName -like "*$Spec*" } | Select-Object -First 1
    if ($match) { return $match }

    $names = ($screens | ForEach-Object { $_.DeviceName }) -join ', '
    throw "Could not resolve monitor '$Spec'. Use 1..$($screens.Count), primary, left, right, portrait, or one of: $names"
}

function Test-ClaudeProfileLive {
    <#
        The 'Claude' profile ships as a Terminal fragment, and Terminal only
        reads fragments at startup. So the profile is usable only if no Terminal
        process predates the fragment file.
    #>
    if (-not (Test-Path -LiteralPath $FragmentPath)) { return $false }

    $procs = @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return $true }

    $oldestStart  = ($procs | Sort-Object StartTime | Select-Object -First 1).StartTime
    $fragmentTime = (Get-Item -LiteralPath $FragmentPath).LastWriteTime
    return ($fragmentTime -lt $oldestStart)
}

function Get-QuadrantRects {
    param($WorkingArea, [int]$Gap)

    $wa = $WorkingArea
    # Derive the second half by subtraction, so an odd width or height still
    # tiles exactly instead of leaving a one-pixel seam.
    $leftW = [int][math]::Floor(($wa.Width  - $Gap) / 2)
    $topH  = [int][math]::Floor(($wa.Height - $Gap) / 2)
    $rightW  = $wa.Width  - $leftW - $Gap
    $bottomH = $wa.Height - $topH  - $Gap

    $x1 = $wa.X
    $x2 = $wa.X + $leftW + $Gap
    $y1 = $wa.Y
    $y2 = $wa.Y + $topH + $Gap

    return @(
        @{ X = $x1; Y = $y1; W = $leftW;  H = $topH    }   # 1 top-left
        @{ X = $x2; Y = $y1; W = $rightW; H = $topH    }   # 2 top-right
        @{ X = $x1; Y = $y2; W = $leftW;  H = $bottomH }   # 3 bottom-left
        @{ X = $x2; Y = $y2; W = $rightW; H = $bottomH }   # 4 bottom-right
    )
}

function Initialize-Win32 {
    if ('QuadClaude.Win32' -as [type]) { return }
    Add-Type -Namespace QuadClaude -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left, Top, Right, Bottom; }

[DllImport("user32.dll")]
public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder text, int count);
[DllImport("user32.dll")]
public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll")]
public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
[DllImport("user32.dll")]
public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")]
public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("dwmapi.dll")]
public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out RECT r, int size);
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

public static System.Collections.Generic.List<IntPtr> FindByClass(string cls) {
    var found = new System.Collections.Generic.List<IntPtr>();
    EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
        if (!IsWindowVisible(hWnd)) return true;
        var sb = new System.Text.StringBuilder(256);
        GetClassName(hWnd, sb, sb.Capacity);
        if (sb.ToString() == cls) found.Add(hWnd);
        return true;
    }, IntPtr.Zero);
    return found;
}

// Place a window so its VISIBLE edges land exactly on the given rectangle.
// GetWindowRect includes the invisible resize border; DWMWA_EXTENDED_FRAME_BOUNDS
// (9) does not. The difference is the padding to add back.
public static string PlaceVisible(IntPtr hWnd, int x, int y, int w, int h) {
    ShowWindow(hWnd, 9);            // SW_RESTORE: never tile a maximized window
    RECT wr, fr;
    GetWindowRect(hWnd, out wr);
    int dx = 0, dy = 0, dw = 0, dh = 0;
    if (DwmGetWindowAttribute(hWnd, 9, out fr, 16) == 0) {
        dx = fr.Left - wr.Left;
        dy = fr.Top  - wr.Top;
        dw = (wr.Right - wr.Left) - (fr.Right - fr.Left);
        dh = (wr.Bottom - wr.Top) - (fr.Bottom - fr.Top);
    }
    SetWindowPos(hWnd, IntPtr.Zero, x - dx, y - dy, w + dw, h + dh, 0x0004); // SWP_NOZORDER
    return "border dx=" + dx + " dy=" + dy + " dw=" + dw + " dh=" + dh;
}
'@
}

function Get-TerminalWindowHandles {
    Initialize-Win32
    return [QuadClaude.Win32]::FindByClass('CASCADIA_HOSTING_WINDOW_CLASS')
}

function Get-SpaceSafePath {
    <#
        cmd.exe /k mishandles quoted paths in some argument shapes. If the
        script path contains a space, hand cmd the 8.3 short path instead.
    #>
    param([string]$Path)

    if ($Path -notmatch '\s') { return $Path }
    try {
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $short = $fso.GetFile($Path).ShortPath
        if ($short) { return $short }
    } catch { }
    return $Path   # 8.3 names disabled on this volume; quoting is the best we can do
}

# --- resolve inputs -----------------------------------------------------------

if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
    throw "Windows Terminal (wt.exe) was not found on PATH. Install it from the Microsoft Store."
}
if (-not (Test-Path -LiteralPath $PaneScript)) {
    throw "Missing $PaneScript - it ships alongside this script."
}

$screen = Resolve-TargetScreen -Spec $Monitor

if (-not (Test-Path -LiteralPath $WorkingDir)) {
    throw "Working directory does not exist: $WorkingDir"
}
$dir = (Resolve-Path -LiteralPath $WorkingDir).Path
if ($dir.Length -gt 3) { $dir = $dir.TrimEnd('\') }   # keep 'C:\' intact

$names = @()
for ($i = 0; $i -lt 4; $i++) {
    if ($i -lt $Titles.Count -and -not [string]::IsNullOrWhiteSpace($Titles[$i])) {
        $names += $Titles[$i].Trim()
    } else {
        $names += "Claude $($i + 1)"
    }
}

# Install the profile fragment on first run, so window exits follow the profile
# instead of leaving Terminal's exit notice sitting in the window.
if (-not (Test-Path -LiteralPath $FragmentPath)) {
    $installer = Join-Path $PSScriptRoot 'Install-ClaudePaneProfile.ps1'
    if (Test-Path -LiteralPath $installer) { & $installer | Out-Null }
}
$useProfile = Test-ClaudeProfileLive

$rects   = Get-QuadrantRects -WorkingArea $screen.WorkingArea -Gap $Gap
$paneCmd = Get-SpaceSafePath -Path $PaneScript

function New-WtArgs {
    param([int]$Index)

    $a = New-Object System.Collections.Generic.List[string]
    $a.Add("--pos=$($rects[$Index].X),$($rects[$Index].Y)")   # '=' form: value may start with '-'
    $a.Add('--window=-1')                                     # always a brand new window
    $a.Add('new-tab')
    if ($useProfile) {
        # The profile carries closeOnExit and suppressApplicationTitle.
        $a.Add('--profile'); $a.Add($ProfileName)
    } else {
        # Best the command line alone can do: keep Claude from renaming the window.
        $a.Add('--suppressApplicationTitle')
    }
    $a.Add('--title');             $a.Add($names[$Index])
    $a.Add('--startingDirectory'); $a.Add($dir)
    $a.Add('cmd.exe')
    $a.Add('/k')
    $a.Add($paneCmd)
    $a.Add($names[$Index])
    $a.Add(($Index + 1).ToString())
    if ($NoClaude)             { $a.Add('none') }
    elseif ($SkipPermissions)  { $a.Add('skip') }
    else                       { $a.Add('safe') }
    return $a
}

if ($DryRun) {
    Write-Host "Target monitor : $($screen.DeviceName)  working area=$($screen.WorkingArea)  primary=$($screen.Primary)"
    Write-Host "Profile        : $(if ($useProfile) { "'$ProfileName' (fragment loaded)" } else { 'default (fragment not loaded yet)' })"
    Write-Host "Claude         : $(if ($NoClaude) { 'no (-NoClaude)' } elseif ($SkipPermissions) { 'yes, --dangerously-skip-permissions' } else { 'yes, with permission prompts' })"
    Write-Host "Gap            : $Gap px"
    Write-Host ''
    for ($i = 0; $i -lt 4; $i++) {
        $r = $rects[$i]
        Write-Host "Window $($i + 1): '$($names[$i])'  ->  x=$($r.X) y=$($r.Y) $($r.W)x$($r.H)"
        Write-Host ('  wt.exe ' + ((New-WtArgs -Index $i) -join ' '))
    }
    return
}

# --- launch and tile ----------------------------------------------------------

Initialize-Win32
$placed = @()

for ($i = 0; $i -lt 4; $i++) {
    $before = @(Get-TerminalWindowHandles)

    & wt.exe @(New-WtArgs -Index $i)

    $new = $null
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $candidates = @(Get-TerminalWindowHandles | Where-Object { $before -notcontains $_ })
        if ($candidates.Count -gt 0) { $new = $candidates[-1]; break }
    }

    if (-not $new) {
        Write-Warning "Window $($i + 1) ('$($names[$i])') did not appear in time; it was not tiled."
        continue
    }

    $r = $rects[$i]
    Start-Sleep -Milliseconds 250          # let Terminal finish its own initial sizing
    $detail = [QuadClaude.Win32]::PlaceVisible($new, $r.X, $r.Y, $r.W, $r.H)
    Write-Verbose "Window $($i + 1) '$($names[$i])': $detail"
    $placed += $new
}

# Focus window 1 last, so the grid ends up with the top-left window active.
if ($placed.Count -gt 0) {
    [void][QuadClaude.Win32]::SetForegroundWindow($placed[0])
}

Write-Host "Tiled $($placed.Count) window(s) on $($screen.DeviceName): $($names -join ' | ')"
