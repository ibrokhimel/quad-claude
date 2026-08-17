<#
.SYNOPSIS
    Plays a boot or shutdown animation in the current terminal, then clears it.

.DESCRIPTION
    Run by Start-ClaudeWindow.cmd around the Claude session: intro before it
    starts, outro after it exits.

    PowerShell rather than cmd because cmd has no sub-second sleep and no
    cursor control, which rules out animation entirely. Frames are composed
    into a single string and written in one call - writing per character is
    what makes terminal animation flicker.

    Every animation re-reads the window size each frame and re-lays itself out
    when it changes, so resizing mid-play reflows instead of tearing.

    Everything is ANSI: cursor addressing, 24-bit colour, hide/show cursor.
    Windows Terminal supports all of it, and nothing here needs a font,
    module or binary that is not already on the machine.

.PARAMETER Name
    Window name, shown as the thing being booted.

.PARAMETER Index
    Window number, picks the accent colour. Cycles every four.

.PARAMETER Style
    matrix | bios | glitch | wave | figlet, or random to pick one.

.PARAMETER Phase
    intro (default) for the chosen style, or outro for the hand-off that closes
    it out. Both run before Claude: intro, then outro, then the session.

.PARAMETER DurationMs
    Rough target length for the intro. Every millisecond here is one the user
    waits before Claude appears; the outro runs at roughly a third of it.
#>
[CmdletBinding()]
param(
    [string] $Name  = 'CLAUDE',
    [int]    $Index = 1,
    [ValidateSet('random', 'matrix', 'bios', 'glitch', 'wave', 'figlet')]
    [string] $Style = 'random',
    [ValidateSet('intro', 'outro')]
    [string] $Phase = 'intro',
    [int]    $DurationMs = 3000
)

$ErrorActionPreference = 'Stop'

$E    = [char]27
$Rand = New-Object System.Random

# Without this every non-ASCII glyph reaches the terminal as '?'. The console
# encodes output in its code page, which on a default Windows box is 1252 and
# has no katakana and no block-drawing characters. Note it is the ENCODING, not
# the font: a missing glyph renders as a box, a mis-encoded one renders as '?'.
$PrevEncoding = [Console]::OutputEncoding
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# Grab the writer AFTER switching encoding, never before: assigning
# OutputEncoding builds a new writer, so a handle cached earlier keeps writing
# through the old encoding and every glyph still arrives as '?'.
$Out = [Console]::Out

function Fg { param([int]$r, [int]$g, [int]$b) return "$E[38;2;$r;$g;$($b)m" }
function At { param([int]$row, [int]$col) return "$E[$row;$($col)H" }
$Reset = "$E[0m"
$Bold  = "$E[1m"

# Accent per window, cycling every four - the same four identities the banner
# and prompt use, so the animation belongs to the window rather than floating free.
$Accents = @(
    @(97, 175, 239),    # blue
    @(255, 121, 198),   # pink
    @(241, 250, 140),   # yellow
    @(80, 250, 123)     # green
)
$Acc = $Accents[(($Index - 1) % 4 + 4) % 4]
$AccFg = Fg $Acc[0] $Acc[1] $Acc[2]

function Show-Frame { param([string]$s) $Out.Write($s); $Out.Flush() }

# --- geometry ----------------------------------------------------------------
# Size lives at script scope because every animation re-reads it per frame and
# re-lays itself out when the user drags the window.
$script:W = 80
$script:H = 24

function Read-Size {
    try {
        $s = $Host.UI.RawUI.WindowSize
        return @{ W = [Math]::Max(24, [int]$s.Width); H = [Math]::Max(9, [int]$s.Height) }
    } catch {
        return @{ W = $script:W; H = $script:H }
    }
}

function Test-Resized {
    <# True when the window changed size since the last check, updating W/H. #>
    $s = Read-Size
    if ($s.W -ne $script:W -or $s.H -ne $script:H) {
        $script:W = $s.W
        $script:H = $s.H
        return $true
    }
    return $false
}

$init = Read-Size
$script:W = $init.W
$script:H = $init.H
if ($script:W -lt 24 -or $script:H -lt 9) { return }

$Label = $Name.ToUpper()

function Get-Spaced {
    <# Letter-spaced, which is as close to "big" as a terminal gets without
       shipping a block font that would overflow a long name anyway. Recomputed
       on resize because a narrow window has to drop back to the plain name. #>
    $s = ($Label.ToCharArray() -join ' ')
    if ($s.Length -gt $script:W - 4) { $s = $Label }
    if ($s.Length -gt $script:W - 4) { $s = $Label.Substring(0, [Math]::Max(1, $script:W - 4)) }
    return $s
}

# --- matrix ------------------------------------------------------------------
function Play-Matrix {
    # Halfwidth katakana (U+FF66-FF9D) deliberately, not the full-width forms:
    # full-width glyphs occupy two cells, which would break the one-column-per
    # -drop model and tear the rain apart.
    $glyphs = @()
    for ($c = 0xFF66; $c -le 0xFF9D; $c++) { $glyphs += [char]$c }
    0..9 | ForEach-Object { $glyphs += [char](48 + $_) }
    $gn = $glyphs.Count

    $head = Fg 220 255 220
    $body = Fg 0 200 90

    $y = $null; $rate = $null; $trail = $null; $prev = $null
    function Reset-Drops {
        $script:y     = New-Object int[] $script:W
        $script:rate  = New-Object int[] $script:W
        $script:trail = New-Object int[] $script:W
        $script:prev  = New-Object 'char[]' $script:W
        for ($c = 0; $c -lt $script:W; $c++) {
            $script:y[$c]     = -$Rand.Next(0, $script:H)
            $script:rate[$c]  = $Rand.Next(1, 4)
            $script:trail[$c] = $Rand.Next(5, 16)
            $script:prev[$c]  = ' '
        }
    }
    Reset-Drops

    $step    = 50
    $frames  = [int]($DurationMs / $step)
    $resolve = [int]($frames * 0.55)

    Show-Frame "$E[2J"
    for ($f = 0; $f -lt $frames; $f++) {
        if (Test-Resized) { Reset-Drops; Show-Frame "$E[2J" }

        $mid = [int]($script:H / 2)
        $spaced = Get-Spaced
        $startCol = [int](($script:W - $spaced.Length) / 2) + 1

        $sb = New-Object System.Text.StringBuilder
        for ($c = 0; $c -lt $script:W; $c++) {
            if ($f % $script:rate[$c] -ne 0) { continue }

            # Re-colour the previous head to trail green, then draw the new one
            # white. Only these two cells change, so the rest of the trail keeps
            # the colour it was drawn with - full redraws are what kill framerate.
            $py = $script:y[$c]
            if ($py -ge 1 -and $py -le $script:H -and $script:prev[$c] -ne ' ') {
                [void]$sb.Append((At $py ($c + 1))).Append($body).Append($script:prev[$c])
            }

            $script:y[$c]++
            $ny = $script:y[$c]
            $ch = $glyphs[$Rand.Next(0, $gn)]
            if ($ny -ge 1 -and $ny -le $script:H) {
                [void]$sb.Append((At $ny ($c + 1))).Append($head).Append($ch)
            }
            $script:prev[$c] = $ch

            $ty = $ny - $script:trail[$c]
            if ($ty -ge 1 -and $ty -le $script:H) {
                [void]$sb.Append((At $ty ($c + 1))).Append(' ')
            }
            if ($ny -gt $script:H + $script:trail[$c]) {
                $script:y[$c]     = -$Rand.Next(0, 8)
                $script:rate[$c]  = $Rand.Next(1, 4)
                $script:trail[$c] = $Rand.Next(5, 16)
                $script:prev[$c]  = ' '
            }
        }

        if ($f -ge $resolve) {
            # Hold a clear band so the rain never runs through the name.
            $p = [Math]::Min(1.0, ($f - $resolve) / [double][Math]::Max(1, ($frames - $resolve - 3)))
            $show = [int][Math]::Ceiling($spaced.Length * $p)
            [void]$sb.Append((At ($mid - 1) 1)).Append((' ' * $script:W))
            [void]$sb.Append((At ($mid + 1) 1)).Append((' ' * $script:W))
            [void]$sb.Append((At $mid 1)).Append((' ' * $script:W))
            [void]$sb.Append((At $mid $startCol)).Append($Bold).Append($AccFg)
            [void]$sb.Append($spaced.Substring(0, [Math]::Min($show, $spaced.Length)))
        }

        [void]$sb.Append($Reset)
        Show-Frame $sb.ToString()
        Start-Sleep -Milliseconds $step
    }
}

# --- bios --------------------------------------------------------------------
function Play-Bios {
    $ok    = Fg 80 250 123
    $grey  = Fg 125 133 144
    $white = Fg 230 237 243
    $dot   = [char]0x00B7

    $checks = @(
        @('terminal',    'vt / truecolor'),
        @('palette',     '16 / 16'),
        @('workspace',   'mounted'),
        @('permissions', 'bypassed'),
        @('session',     'independent')
    )

    Show-Frame "$E[2J$(At 2 3)$Bold$AccFg CLAUDE BOOT SEQUENCE $Reset$grey  $dot  node $Reset$white$Label$Reset"
    $rule = [string][char]0x2500 * [Math]::Min($script:W - 5, 46)
    Show-Frame "$(At 3 3)$grey$rule$Reset"
    Start-Sleep -Milliseconds 140

    $row = 5
    foreach ($c in $checks) {
        [void](Test-Resized)
        $dots = '.' * [Math]::Max(2, 18 - $c[0].Length)
        Show-Frame "$(At $row 3)$grey[ $Reset$ok`OK$grey ]$Reset  $white$($c[0]) $grey$dots $Reset$($c[1])"
        $row++
        Start-Sleep -Milliseconds 170
    }

    Show-Frame "$(At $row 3)$grey[ $Reset$AccFg..$grey ]$Reset  $white`claude $grey........... $Reset`starting"
    $row += 2

    # Gradient bar: red at empty, amber mid, green at full, so the colour itself
    # reports progress rather than just the length of the fill.
    $barW = [Math]::Min($script:W - 12, 40)
    for ($i = 0; $i -le $barW; $i++) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append((At $row 3))
        for ($k = 0; $k -lt $barW; $k++) {
            if ($k -lt $i) {
                $t = $k / [double]$barW
                if ($t -lt 0.5) {
                    $r = 255; $g = [int](80 + 340 * $t); $b = 70
                } else {
                    $r = [int](255 - 350 * ($t - 0.5)); $g = 250; $b = [int](70 + 60 * ($t - 0.5))
                }
                [void]$sb.Append((Fg $r $g $b)).Append([char]0x2588)
            } else {
                [void]$sb.Append($grey).Append([char]0x2591)
            }
        }
        $pct = [int](100 * $i / $barW)
        [void]$sb.Append($Reset).Append('  ').Append($white).Append("$pct%  ").Append($Reset)
        Show-Frame $sb.ToString()
        Start-Sleep -Milliseconds ([Math]::Max(12, [int]($DurationMs * 0.45 / $barW)))
    }

    Show-Frame "$(At ($row + 2) 3)$Bold$ok`CLAUDE ONLINE$Reset"
    Start-Sleep -Milliseconds 400
}

# --- glitch ------------------------------------------------------------------
function Get-Noise {
    # Built from code points rather than written literally: PowerShell 5.1 reads
    # a .ps1 as ANSI unless it carries a BOM, so non-ASCII literals in the source
    # are one careless re-save away from turning into mojibake.
    $n = @()
    foreach ($code in 0x2593, 0x2592, 0x2591, 0x2588, 0x259A, 0x259E, 0x259B, 0x259C, 0x2584, 0x2580, 0x2590, 0x258C) {
        $n += [char]$code
    }
    foreach ($ch in '#', '%', '&', '@', '$', '?', '!', '/', '\', '|', '<', '>', '=', '+', '*') {
        $n += [char]$ch
    }
    return $n
}

function Play-Glitch {
    $noise = Get-Noise
    $nn = $noise.Count
    $white = Fg 230 237 243

    $spaced = Get-Spaced
    $chars = $spaced.ToCharArray()

    function Draw-Frame-Box {
        $mid = [int]($script:H / 2)
        $bw = [Math]::Min($script:W - 4, $spaced.Length + 8)
        $bx = [int](($script:W - $bw) / 2) + 1
        Show-Frame "$E[2J"
        Show-Frame "$(At ($mid - 2) $bx)$AccFg$([char]0x250C)$([string][char]0x2500 * ($bw - 2))$([char]0x2510)$Reset"
        Show-Frame "$(At ($mid + 2) $bx)$AccFg$([char]0x2514)$([string][char]0x2500 * ($bw - 2))$([char]0x2518)$Reset"
    }
    Draw-Frame-Box

    # Scramble, then lock characters in a random order so it reads as decrypting
    # rather than simply typing out left to right.
    $order = 0..($chars.Count - 1) | Sort-Object { $Rand.Next() }
    $locked = New-Object bool[] $chars.Count
    $steps = $chars.Count + 10
    $per = [Math]::Max(30, [int]($DurationMs * 0.6 / [Math]::Max(1, $steps)))

    for ($s = 0; $s -lt $steps; $s++) {
        if (Test-Resized) {
            $spaced = Get-Spaced
            $chars = $spaced.ToCharArray()
            if ($locked.Count -ne $chars.Count) {
                $locked = New-Object bool[] $chars.Count
                for ($k = 0; $k -lt [Math]::Min($s, $chars.Count); $k++) { $locked[$k] = $true }
            }
            Draw-Frame-Box
        }
        if ($s -lt $order.Count -and $order[$s] -lt $locked.Count) { $locked[$order[$s]] = $true }

        $mid = [int]($script:H / 2)
        $startCol = [int](($script:W - $spaced.Length) / 2) + 1
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append((At $mid $startCol))
        for ($i = 0; $i -lt $chars.Count; $i++) {
            if ($chars[$i] -eq ' ') { [void]$sb.Append(' '); continue }
            if ($locked[$i]) {
                [void]$sb.Append($Bold).Append($white).Append($chars[$i]).Append($Reset)
            } else {
                [void]$sb.Append($AccFg).Append($noise[$Rand.Next(0, $nn)])
            }
        }
        [void]$sb.Append($Reset)
        Show-Frame $sb.ToString()
        Start-Sleep -Milliseconds $per
    }

    # Chromatic split: the same text offset a column each way in red and cyan,
    # for two frames. Cheap, and it sells the whole effect.
    $mid = [int]($script:H / 2)
    $startCol = [int](($script:W - $spaced.Length) / 2) + 1
    foreach ($pass in 1, 2, 3) {
        Show-Frame "$(At $mid ([Math]::Max(1, $startCol - 1)))$(Fg 255 60 60)$spaced$Reset"
        Show-Frame "$(At $mid ([Math]::Min($script:W, $startCol + 1)))$(Fg 60 230 255)$spaced$Reset"
        Start-Sleep -Milliseconds 70
        Show-Frame "$(At $mid 1)$(' ' * $script:W)$(At $mid $startCol)$Bold$white$spaced$Reset"
        Start-Sleep -Milliseconds 90
    }
    Start-Sleep -Milliseconds 260
}

# --- wave --------------------------------------------------------------------
function Play-Wave {
    $blocks = [char[]]@(0x2581, 0x2582, 0x2583, 0x2584, 0x2585, 0x2586, 0x2587, 0x2588)
    $step = 55
    $frames = [int]($DurationMs / $step)

    Show-Frame "$E[2J"
    for ($f = 0; $f -lt $frames; $f++) {
        if (Test-Resized) { Show-Frame "$E[2J" }

        $mid = [int]($script:H / 2)
        $top = [Math]::Max(1, $mid - 2)
        $bot = [Math]::Min($script:H, $mid + 2)
        $spaced = Get-Spaced
        $startCol = [int](($script:W - $spaced.Length) / 2) + 1

        $phase = $f * 0.34
        $sb = New-Object System.Text.StringBuilder

        foreach ($row in @($top, $bot)) {
            $dir = 1
            if ($row -eq $bot) { $dir = -1 }
            [void]$sb.Append((At $row 1))
            for ($x = 0; $x -lt $script:W; $x++) {
                $v = [Math]::Sin(($x * 0.22) + ($phase * $dir))
                $lvl = [int](($v + 1) / 2 * 7)
                # Hue sweeps along x so the crest reads as travelling, not pulsing.
                $t = ($x / [double]$script:W + $f / 45.0) % 1.0
                $r = [int](127 + 127 * [Math]::Sin(6.283 * $t))
                $g = [int](127 + 127 * [Math]::Sin(6.283 * ($t + 0.33)))
                $b = [int](127 + 127 * [Math]::Sin(6.283 * ($t + 0.66)))
                [void]$sb.Append((Fg $r $g $b)).Append($blocks[$lvl])
            }
        }

        # Name fades up out of the middle as the waves run.
        $p = [Math]::Min(1.0, $f / [double][Math]::Max(1, $frames * 0.6))
        $lv = [int](60 + 195 * $p)
        [void]$sb.Append((At $mid 1)).Append((' ' * $script:W))
        [void]$sb.Append((At $mid $startCol)).Append($Bold).Append((Fg $lv $lv $lv))
        [void]$sb.Append([char]0x25C6).Append('  ').Append($spaced).Append('  ').Append([char]0x25C6)
        [void]$sb.Append($Reset)

        Show-Frame $sb.ToString()
        Start-Sleep -Milliseconds $step
    }
}

# --- figlet ------------------------------------------------------------------
function Play-Figlet {
    <#
        Block-letter splash, rendered by splash.py with pyfiglet and rich.
        Python rather than PowerShell because block type needs a font database.

        Returns $true only if it actually ran, so the caller can fall back to a
        native animation when Python or pyfiglet is not installed. The attempt
        itself is the availability check - probing first would cost an extra
        interpreter start on every single launch.
    #>
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { return $false }

    $splash = Join-Path $PSScriptRoot 'splash.py'
    if (-not (Test-Path -LiteralPath $splash)) { return $false }

    # stderr is deliberately NOT redirected: PowerShell handles a native
    # command's redirected streams badly enough to break the child's console
    # rendering, and the finally block wipes the screen anyway, so a traceback
    # costs nothing and a swallowed one costs an afternoon.
    $secs = [Math]::Round($DurationMs / 1000.0, 2)
    & python $splash --name $Name --index $Index --duration $secs
    return ($LASTEXITCODE -eq 0)
}

# --- outro -------------------------------------------------------------------
function Play-Outro {
    <#
        Hand-off sequence, style-agnostic: the name settles, two shutters close
        across it from the edges, then the line collapses to nothing and Claude
        takes the screen.

        It runs between the intro and Claude, not after the session. The point
        is to close the intro out deliberately, so the session does not appear
        on top of a half-finished flourish.

        One outro rather than one per style, because whichever intro just
        played, this is the same beat: stop, hand over.
    #>
    $grey  = Fg 125 133 144
    $white = Fg 230 237 243
    $bar   = [char]0x2588

    Show-Frame "$E[2J"

    $spaced = Get-Spaced
    $mid = [int]($script:H / 2)
    $startCol = [int](($script:W - $spaced.Length) / 2) + 1
    Show-Frame "$(At $mid $startCol)$Bold$white$spaced$Reset"
    $tag = 'launching claude'
    Show-Frame "$(At ($mid + 2) ([int](($script:W - $tag.Length) / 2) + 1))$grey$tag$Reset"
    Start-Sleep -Milliseconds 320

    # Shutters: two bars converge on the centre line, covering the name.
    $half = [int]($script:W / 2)
    $stepMs = [Math]::Max(8, [int]($DurationMs * 0.35 / [Math]::Max(1, $half)))
    for ($i = 0; $i -le $half; $i++) {
        if (Test-Resized) {
            $half = [int]($script:W / 2)
            $mid = [int]($script:H / 2)
        }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append((At $mid 1)).Append($AccFg).Append([string]$bar * $i)
        [void]$sb.Append((At $mid ([Math]::Max(1, $script:W - $i + 1)))).Append($AccFg).Append([string]$bar * $i)
        [void]$sb.Append($Reset)
        Show-Frame $sb.ToString()
        Start-Sleep -Milliseconds $stepMs
    }

    # Then the closed shutter collapses to a point and goes out.
    for ($i = $half; $i -ge 0; $i -= 2) {
        $left = [Math]::Max(1, $half - $i + 1)
        $len  = [Math]::Max(0, $i * 2)
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append((At $mid 1)).Append((' ' * $script:W))
        if ($len -gt 0) {
            [void]$sb.Append((At $mid $left)).Append($AccFg).Append([string]$bar * [Math]::Min($len, $script:W - $left + 1))
        }
        [void]$sb.Append($Reset)
        Show-Frame $sb.ToString()
        Start-Sleep -Milliseconds 16
    }
    Start-Sleep -Milliseconds 180
}

# --- run ---------------------------------------------------------------------
if ($Style -eq 'random') {
    $Style = @('matrix', 'bios', 'glitch', 'wave', 'figlet')[$Rand.Next(0, 5)]
}

try {
    Show-Frame "$E[?25l"          # hide cursor
    if ($Phase -eq 'outro') {
        Play-Outro
    } else {
        switch ($Style) {
            'matrix' { Play-Matrix }
            'bios'   { Play-Bios }
            'glitch' { Play-Glitch }
            'wave'   { Play-Wave }
            'figlet' {
                # Never leave a window with no animation because Python is missing.
                if (-not (Play-Figlet)) { Play-Glitch }
            }
        }
    }
} catch {
    # An animation is never worth failing a launch over.
} finally {
    # Always leave a clean screen and a visible cursor, whatever happened above,
    # so Claude starts on a blank terminal rather than the last frame.
    Show-Frame "$Reset$E[?25h$E[2J$E[H"
    # Hand the console back exactly as it was found; the code page is shared
    # with the cmd session that continues after this script.
    try { [Console]::OutputEncoding = $PrevEncoding } catch { }
}
