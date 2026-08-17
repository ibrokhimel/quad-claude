<#
.SYNOPSIS
    Opens separate, named Windows Terminal windows running Claude Code, tiled
    flush across the monitor you choose.

.DESCRIPTION
    Independent Terminal windows, tiled to fill the screen. Four by default:

        +-----------+-----------+
        |     1     |     2     |
        +-----------+-----------+
        |     3     |     4     |
        +-----------+-----------+

    Each is a real window - its own title bar, its own taskbar entry, movable
    and closable on its own - and each runs cmd.

    Alignment is done in two steps. Each window is launched with --pos near its
    slot, then moved with SetWindowPos to exact pixel bounds. The second step
    compensates for the invisible resize border Windows puts around every
    window: GetWindowRect includes it, so tiling by those numbers leaves a
    visible gap of roughly 14px between neighbours. The real visible edge comes
    from DWMWA_EXTENDED_FRAME_BOUNDS, and the difference between the two is
    added back, which is what makes the windows sit truly flush.

    Slots are computed from the monitor's working area, so windows never hide
    behind the taskbar, and every boundary is derived from the span's own
    arithmetic rather than by accumulating sizes, so odd widths and heights
    still tile exactly with no seam.

.PARAMETER Monitor
    Which display to use. Accepts:
      - an index 1..N, ordered left-to-right by screen X coordinate
      - 'primary'  (default)
      - 'left' / 'right'      - leftmost / rightmost screen
      - 'portrait'            - first screen taller than it is wide
      - a device-name substring, e.g. 'DISPLAY6'

.PARAMETER Count
    How many windows, 1 to 16. Defaults to the number of -Titles given, or 4.
    Layouts for 1-6 are hand-picked; above that it is a balanced grid.

.PARAMETER Titles
    Window names. Missing names are filled with 'Claude <n>'.

.PARAMETER WorkingDir
    Starting directory for every window. Defaults to the current directory.

.PARAMETER Gap
    Pixels of space to leave between the tiled windows. Default 0 (flush).

.PARAMETER Anim
    Boot animation for every window: random (default), matrix, bios, glitch,
    wave, figlet, or off. Omit it to use whatever -SaveDefaults last stored.

.PARAMETER StaggerMs
    Pause between launching one window and the next, applied only past two
    windows. Defaults to 300, or whatever -SaveDefaults last stored.

.PARAMETER SaveDefaults
    Write the -Anim and -StaggerMs used by this run to config.json, so later
    launches pick them up without being told again.

.PARAMETER SkipPermissions
    Start Claude with --dangerously-skip-permissions. On by default; use
    -SkipPermissions:$false for sessions that should still prompt.

.PARAMETER NoClaude
    Tile plain cmd windows instead of starting Claude. For testing layout.

.PARAMETER DryRun
    Print the resolved plan and each wt.exe argument list, launch nothing.

.EXAMPLE
    .\Open-QuadClaude.ps1
    Four 'Claude 1'..'Claude 4' windows on the primary monitor.

.EXAMPLE
    .\Open-QuadClaude.ps1 -Monitor 2 -Titles backend,frontend,tests,notes
    Named windows tiled on the second monitor from the left.

.EXAMPLE
    .\Open-QuadClaude.ps1 -Count 3 -Monitor portrait
    Three windows on the portrait screen: one tall, two stacked beside it.
#>
[CmdletBinding()]
param(
    [string]   $Monitor    = 'primary',
    [int]      $Count      = 0,
    [string[]] $Titles     = @(),
    [string]   $WorkingDir = $PWD.Path,
    [int]      $Gap        = 0,
    # '' means "whatever is saved", which is how -SaveDefaults sticks. Listed in
    # the set so binding an explicit empty string is not an error either.
    [ValidateSet('', 'random', 'matrix', 'bios', 'glitch', 'wave', 'figlet', 'off')]
    [string]   $Anim       = '',
    [int]      $StaggerMs  = -1,
    [switch]   $SaveDefaults,
    [bool]     $SkipPermissions = $true,
    [switch]   $NoClaude,
    [switch]   $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Banner colours live in Start-ClaudeWindow.cmd, keyed by window number. They
# cannot be passed through here: ANSI colour codes are semicolon-separated and
# wt.exe splits its command line on ';' even inside a quoted argument.
$ProfileName  = 'Claude'
$FragmentPath = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\quad-claude\claude-window.json'
$WindowScript   = Join-Path $PSScriptRoot 'Start-ClaudeWindow.cmd'
$StatePath    = Join-Path $env:LOCALAPPDATA 'quad-claude\session.json'
$ConfigPath   = Join-Path $env:LOCALAPPDATA 'quad-claude\config.json'

# Shipped defaults, used until something is saved over them.
$DefaultAnim      = 'random'
$DefaultStaggerMs = 300

function Get-SavedDefaults {
    <#
        Saved preferences, so a choice can be made once instead of being
        retyped on every launch. A missing or unreadable file is not worth
        failing a launch over - fall back to the shipped defaults.
    #>
    $out = @{ anim = $DefaultAnim; staggerMs = $DefaultStaggerMs }
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $out }
    try {
        $c = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        if ($c.PSObject.Properties.Name -contains 'anim' -and $c.anim) {
            $out.anim = [string]$c.anim
        }
        if ($c.PSObject.Properties.Name -contains 'staggerMs' -and $c.staggerMs -ge 0) {
            $out.staggerMs = [int]$c.staggerMs
        }
    } catch { }
    return $out
}

function Save-Defaults {
    param([string]$AnimValue, [int]$StaggerValue)

    $dir = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [pscustomobject]@{ anim = $AnimValue; staggerMs = $StaggerValue } |
        ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    Write-Host "Saved defaults: anim=$AnimValue staggerMs=$StaggerValue"
    Write-Host "  $ConfigPath"
}

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

function Split-Span {
    <#
        Cut a span into N pieces that tile it exactly.

        Each boundary is computed from the span's own arithmetic rather than by
        adding up piece sizes, so rounding cannot accumulate: piece i runs from
        floor(i*avail/N) to floor((i+1)*avail/N). Whatever the remainder, the
        pieces still meet edge to edge and still cover the whole span.
    #>
    param([int]$Start, [int]$Total, [int]$N, [int]$Gap)

    $avail = $Total - ($Gap * ($N - 1))
    $out = @()
    for ($i = 0; $i -lt $N; $i++) {
        $a = [int][math]::Floor(($i * $avail) / $N)
        $b = [int][math]::Floor((($i + 1) * $avail) / $N)
        $out += @{ Pos = $Start + $a + ($i * $Gap); Size = $b - $a }
    }
    return $out
}

function Get-RowPlan {
    <#
        How many windows sit in each row, top to bottom.

        1-6 are hand-picked because the obvious arithmetic gives poor shapes at
        small counts: 3 as two-then-one leaves a lonely wide window, and one
        tall beside two stacked reads better. Above 6 a balanced grid is fine.
    #>
    param([int]$Count)

    switch ($Count) {
        1 { return @(1) }
        2 { return @(2) }
        3 { return 'L' }        # special-cased: one tall left, two stacked right
        4 { return @(2, 2) }
        5 { return @(3, 2) }
        6 { return @(3, 3) }
        default {
            $rows  = [int][math]::Ceiling([math]::Sqrt($Count))
            $base  = [int][math]::Floor($Count / $rows)
            $extra = $Count % $rows
            $plan  = @()
            for ($i = 0; $i -lt $rows; $i++) {
                $plan += $base + $(if ($i -lt $extra) { 1 } else { 0 })
            }
            return $plan
        }
    }
}

function Get-TileRects {
    param($WorkingArea, [int]$Count, [int]$Gap)

    $wa   = $WorkingArea
    $plan = Get-RowPlan -Count $Count
    $out  = @()

    if ($plan -is [string] -and $plan -eq 'L') {
        # One tall window on the left, two stacked on the right.
        $cols = @(Split-Span -Start $wa.X -Total $wa.Width  -N 2 -Gap $Gap)
        $rows = @(Split-Span -Start $wa.Y -Total $wa.Height -N 2 -Gap $Gap)
        $out += @{ X = $cols[0].Pos; Y = $wa.Y;        W = $cols[0].Size; H = $wa.Height   }
        $out += @{ X = $cols[1].Pos; Y = $rows[0].Pos; W = $cols[1].Size; H = $rows[0].Size }
        $out += @{ X = $cols[1].Pos; Y = $rows[1].Pos; W = $cols[1].Size; H = $rows[1].Size }
        return $out
    }

    # @() everywhere below is load-bearing: PowerShell unrolls a single-element
    # array to a scalar on return, and under Set-StrictMode a scalar has no
    # .Count, so a one-row plan (Count 1 or 2) throws without this.
    $plan = @($plan)
    $rows = @(Split-Span -Start $wa.Y -Total $wa.Height -N $plan.Count -Gap $Gap)
    for ($r = 0; $r -lt $plan.Count; $r++) {
        $cols = @(Split-Span -Start $wa.X -Total $wa.Width -N $plan[$r] -Gap $Gap)
        foreach ($c in $cols) {
            $out += @{ X = $c.Pos; Y = $rows[$r].Pos; W = $c.Size; H = $rows[$r].Size }
        }
    }
    return $out
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
if (-not (Test-Path -LiteralPath $WindowScript)) {
    throw "Missing $WindowScript - it ships alongside this script."
}

$screen = Resolve-TargetScreen -Spec $Monitor

if (-not (Test-Path -LiteralPath $WorkingDir)) {
    throw "Working directory does not exist: $WorkingDir"
}
$dir = (Resolve-Path -LiteralPath $WorkingDir).Path
if ($dir.Length -gt 3) { $dir = $dir.TrimEnd('\') }   # keep 'C:\' intact

# Count comes from -Count, else from however many names were given, else four.
if ($Count -le 0) {
    if ($Titles.Count -gt 0) { $Count = $Titles.Count } else { $Count = 4 }
}
if ($Count -lt 1)  { throw "Count must be at least 1." }
if ($Count -gt 16) { throw "Count of $Count is more than this is meant for; 16 is the ceiling." }

$names = @()
for ($i = 0; $i -lt $Count; $i++) {
    if ($i -lt $Titles.Count -and -not [string]::IsNullOrWhiteSpace($Titles[$i])) {
        $names += $Titles[$i].Trim()
    } else {
        $names += "Claude $($i + 1)"
    }
}

# An explicit switch wins for this run; otherwise fall back to what was saved.
$saved = Get-SavedDefaults
if (-not $Anim)       { $Anim      = $saved.anim }
if ($StaggerMs -lt 0) { $StaggerMs = $saved.staggerMs }
if ($SaveDefaults)    { Save-Defaults -AnimValue $Anim -StaggerValue $StaggerMs }

# Install the profile fragment on first run, so window exits follow the profile
# instead of leaving Terminal's exit notice sitting in the window.
if (-not (Test-Path -LiteralPath $FragmentPath)) {
    $installer = Join-Path $PSScriptRoot 'Install-ClaudeProfile.ps1'
    if (Test-Path -LiteralPath $installer) { & $installer | Out-Null }
}
$useProfile = Test-ClaudeProfileLive

$rects   = @(Get-TileRects -WorkingArea $screen.WorkingArea -Count $Count -Gap $Gap)
$paneCmd = Get-SpaceSafePath -Path $WindowScript

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
    # Four accent themes, cycled, so a fifth window is themed rather than blank.
    $a.Add((($Index % 4) + 1).ToString())
    if ($NoClaude)             { $a.Add('none') }
    elseif ($SkipPermissions)  { $a.Add('skip') }
    else                       { $a.Add('safe') }
    $a.Add($Anim)
    return $a
}

if ($DryRun) {
    Write-Host "Target monitor : $($screen.DeviceName)  working area=$($screen.WorkingArea)  primary=$($screen.Primary)"
    Write-Host "Profile        : $(if ($useProfile) { "'$ProfileName' (fragment loaded)" } else { 'default (fragment not loaded yet)' })"
    Write-Host "Claude         : $(if ($NoClaude) { 'no (-NoClaude)' } elseif ($SkipPermissions) { 'yes, --dangerously-skip-permissions' } else { 'yes, with permission prompts' })"
    Write-Host "Gap            : $Gap px"
    Write-Host "Windows        : $Count"
    Write-Host "Animation      : $Anim"
    Write-Host "Stagger        : $(if ($Count -gt 2) { "$StaggerMs ms between launches" } else { 'none (2 or fewer windows)' })"
    Write-Host ''
    for ($i = 0; $i -lt $Count; $i++) {
        $r = $rects[$i]
        Write-Host "Window $($i + 1): '$($names[$i])'  ->  x=$($r.X) y=$($r.Y) $($r.W)x$($r.H)"
        Write-Host ('  wt.exe ' + ((New-WtArgs -Index $i) -join ' '))
    }
    return
}

# --- launch and tile ----------------------------------------------------------

Initialize-Win32
$placed = @()

for ($i = 0; $i -lt $Count; $i++) {
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
    $placed += [pscustomobject]@{ Name = $names[$i]; Hwnd = $new.ToInt64() }

    # Let each window settle before starting the next. Only past two windows,
    # where several boot animations and shells would otherwise come up on top
    # of each other; one or two open fast enough that a pause is just a delay.
    if ($Count -gt 2 -and $StaggerMs -gt 0 -and $i -lt $Count - 1) {
        Start-Sleep -Milliseconds $StaggerMs
    }
}

# Focus window 1 last, so the grid ends up with the top-left window active.
if ($placed.Count -gt 0) {
    [void][QuadClaude.Win32]::SetForegroundWindow([IntPtr]$placed[0].Hwnd)
}

# Record exactly which windows this run created. Send-ClaudeTask.ps1 reads this
# instead of searching by title: window titles are not unique - a stale window
# left over from an earlier run answers to the same name, and a task typed into
# a dead terminal goes nowhere with no error.
$stateDir = Split-Path -Parent $StatePath
if (-not (Test-Path -LiteralPath $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}
[pscustomobject]@{
    created    = (Get-Date).ToString('o')
    monitor    = $screen.DeviceName
    workingDir = $dir
    windows    = $placed
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8

Write-Host "Tiled $($placed.Count) window(s) on $($screen.DeviceName): $($names -join ' | ')"
