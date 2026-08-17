<#
.SYNOPSIS
    Opens one Windows Terminal window, split into a perfectly aligned 2x2 grid
    of four named Claude Code sessions, on the monitor you choose.

.DESCRIPTION
    Builds a single `wt.exe` invocation that creates a tab and then splits it
    three times, so Windows Terminal itself computes the geometry. Every split
    is 50%, so the four panes are exact halves and stay aligned when the window
    is resized.

    Pane order:
        +-----------+-----------+
        |     1     |     2     |
        +-----------+-----------+
        |     3     |     4     |
        +-----------+-----------+

    After launch the new window is maximized onto the target monitor with a
    Win32 ShowWindow call, so it fills that screen exactly.

    Each pane's startup script is passed as -EncodedCommand. That is not
    decoration: wt.exe splits its command line on ';' even inside a quoted
    argument, so a plain inline command gets shredded at the first semicolon
    and the fragments are re-read as wt subcommands. Base64 contains no
    semicolons, spaces, or quotes, so nothing can be re-split.

.PARAMETER Monitor
    Which display to use. Accepts:
      - an index 1..N, ordered left-to-right by screen X coordinate
      - 'primary'  (default)
      - 'left' / 'right'      - leftmost / rightmost screen
      - 'portrait'            - first screen taller than it is wide
      - a device-name substring, e.g. 'DISPLAY6'

.PARAMETER Titles
    One to four pane names. Missing names are filled with 'Claude <n>'.

.PARAMETER WorkingDir
    Starting directory for all four panes. Defaults to the current directory.

.PARAMETER NoClaude
    Lay out the grid with plain shells instead of starting Claude. For testing.

.PARAMETER DryRun
    Print the resolved plan and the wt.exe argument list, then exit.

.EXAMPLE
    .\Open-QuadClaude.ps1
    Four 'Claude 1'..'Claude 4' panes on the primary monitor.

.EXAMPLE
    .\Open-QuadClaude.ps1 -Monitor 2 -Titles backend,frontend,tests,notes
    Named panes on the second monitor from the left.
#>
[CmdletBinding()]
param(
    [string]   $Monitor    = 'primary',
    [string[]] $Titles     = @(),
    [string]   $WorkingDir = $PWD.Path,
    [switch]   $NoClaude,
    [switch]   $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Background colors for the pane banners, so the four are tellable apart at a glance.
$PaneColors   = @('DarkCyan', 'DarkMagenta', 'DarkYellow', 'DarkGreen')
$ProfileName  = 'Claude Pane'
$FragmentPath = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\quad-claude\claude-pane.json'

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

function Test-PaneProfileLive {
    <#
        The 'Claude Pane' profile ships as a Terminal fragment, and Terminal
        only reads fragments at startup. So the profile is usable only if no
        Terminal process predates the fragment file.
    #>
    if (-not (Test-Path -LiteralPath $FragmentPath)) { return $false }

    $procs = @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return $true }

    $oldestStart  = ($procs | Sort-Object StartTime | Select-Object -First 1).StartTime
    $fragmentTime = (Get-Item -LiteralPath $FragmentPath).LastWriteTime
    return ($fragmentTime -lt $oldestStart)
}

function New-PaneScript {
    param([string]$Title, [string]$Color, [bool]$StartClaude)

    $safeTitle  = $Title -replace "'", "''"
    $safeBanner = ("  " + $Title.ToUpper() + "  ") -replace "'", "''"

    $lines = @(
        "`$Host.UI.RawUI.WindowTitle = '$safeTitle'"
        "Write-Host ''"
        "Write-Host '$safeBanner' -ForegroundColor White -BackgroundColor $Color"
        "Write-Host ''"
    )
    if ($StartClaude) { $lines += 'claude' }

    return ($lines -join "`n")
}

function Add-PaneArgs {
    param(
        [System.Collections.Generic.List[string]] $List,
        [string] $Subcommand,   # 'new-tab' | 'split-pane'
        [string] $SplitFlag,    # '' | '--vertical' | '--horizontal'
        [string] $Title,
        [string] $Color,
        [string] $Directory,
        [bool]   $StartClaude,
        [bool]   $UseProfile
    )

    $List.Add($Subcommand)
    if ($SplitFlag) { $List.Add($SplitFlag) }

    if ($UseProfile) {
        # The profile carries closeOnExit and suppressApplicationTitle.
        $List.Add('--profile'); $List.Add($ProfileName)
    } else {
        # Best the command line alone can do: keep Claude from renaming the pane.
        $List.Add('--suppressApplicationTitle')
    }

    $List.Add('--title');             $List.Add($Title)
    $List.Add('--startingDirectory'); $List.Add($Directory)

    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes((New-PaneScript -Title $Title -Color $Color -StartClaude $StartClaude))
    )
    $List.Add('powershell.exe')
    $List.Add('-NoLogo')
    $List.Add('-NoExit')
    $List.Add('-EncodedCommand')
    $List.Add($encoded)
}

function Get-TerminalWindowHandles {
    if (-not ('QuadClaude.Win32' -as [type])) {
        Add-Type -Namespace QuadClaude -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder text, int count);
[DllImport("user32.dll")]
public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")]
public static extern bool SetForegroundWindow(IntPtr hWnd);
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
'@
    }
    return [QuadClaude.Win32]::FindByClass('CASCADIA_HOSTING_WINDOW_CLASS')
}

# --- resolve inputs -----------------------------------------------------------

if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
    throw "Windows Terminal (wt.exe) was not found on PATH. Install it from the Microsoft Store."
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

$startClaude = -not $NoClaude.IsPresent

# Install the profile fragment on first run so pane exits are handled the way
# the profile says, rather than leaving Terminal's exit notice in the pane.
if (-not (Test-Path -LiteralPath $FragmentPath)) {
    $installer = Join-Path $PSScriptRoot 'Install-ClaudePaneProfile.ps1'
    if (Test-Path -LiteralPath $installer) { & $installer | Out-Null }
}
$useProfile = Test-PaneProfileLive

# --- build the wt.exe command -------------------------------------------------

$wa = $screen.WorkingArea
# Land just inside the target monitor; the maximize below snaps it to the edges.
$posX = $wa.X + 24
$posY = $wa.Y + 24

$a = New-Object System.Collections.Generic.List[string]
$a.Add("--pos=$posX,$posY")     # '=' form: the value may legitimately start with '-'
$a.Add('--window=-1')           # always a brand new window

# 1 fills the tab; split right for 2; split 2 down for 4; back to the left
# column; split it down for 3. Every split is 50%, so the grid is exact.
Add-PaneArgs -List $a -Subcommand 'new-tab'    -SplitFlag ''             -Title $names[0] -Color $PaneColors[0] -Directory $dir -StartClaude $startClaude -UseProfile $useProfile
$a.Add(';')
Add-PaneArgs -List $a -Subcommand 'split-pane' -SplitFlag '--vertical'   -Title $names[1] -Color $PaneColors[1] -Directory $dir -StartClaude $startClaude -UseProfile $useProfile
$a.Add(';')
Add-PaneArgs -List $a -Subcommand 'split-pane' -SplitFlag '--horizontal' -Title $names[3] -Color $PaneColors[3] -Directory $dir -StartClaude $startClaude -UseProfile $useProfile
$a.Add(';')
$a.Add('move-focus'); $a.Add('left')
$a.Add(';')
Add-PaneArgs -List $a -Subcommand 'split-pane' -SplitFlag '--horizontal' -Title $names[2] -Color $PaneColors[2] -Directory $dir -StartClaude $startClaude -UseProfile $useProfile
$a.Add(';')
$a.Add('move-focus'); $a.Add('up')   # end up focused on pane 1

if ($DryRun) {
    Write-Host "Target monitor : $($screen.DeviceName)  bounds=$($screen.Bounds)  primary=$($screen.Primary)"
    Write-Host "Window position: $posX,$posY  (then maximized)"
    Write-Host "Panes          : $($names -join ' | ')"
    Write-Host "Profile        : $(if ($useProfile) { "'$ProfileName' (fragment loaded)" } else { 'default (fragment not loaded yet)' })"
    Write-Host "Claude         : $(if ($startClaude) { 'yes' } else { 'no (-NoClaude)' })"
    Write-Host ''
    Write-Host 'Pane script (pane 1, before base64):'
    (New-PaneScript -Title $names[0] -Color $PaneColors[0] -StartClaude $startClaude) -split "`n" | ForEach-Object { "  $_" }
    Write-Host ''
    Write-Host 'wt.exe arguments:'
    $a | ForEach-Object { "  $_" }
    return
}

# --- launch and place ---------------------------------------------------------

$before = @(Get-TerminalWindowHandles)

& wt.exe @a

$new = $null
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
    $candidates = @(Get-TerminalWindowHandles | Where-Object { $before -notcontains $_ })
    if ($candidates.Count -gt 0) { $new = $candidates[-1]; break }
}

if ($new) {
    Start-Sleep -Milliseconds 400          # let the four panes finish spawning
    [void][QuadClaude.Win32]::ShowWindow($new, 3)   # SW_MAXIMIZE
    [void][QuadClaude.Win32]::SetForegroundWindow($new)
    Write-Host "Opened 2x2 grid on $($screen.DeviceName): $($names -join ' | ')"
} else {
    Write-Warning "Terminal launched but its window was not found in time; it was not maximized."
}
