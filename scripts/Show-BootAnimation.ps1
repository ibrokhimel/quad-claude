<#
.SYNOPSIS
    Plays a short boot animation in the current terminal, then clears it.

.DESCRIPTION
    Run by Start-ClaudeWindow.cmd just before Claude starts, so each window
    boots with something to watch instead of a bare prompt.

    PowerShell rather than cmd because cmd has no sub-second sleep and no
    cursor control, which rules out animation entirely. Here frames are
    composed into a single string and written in one call - writing per
    character is what makes terminal animation flicker.

    Everything is ANSI: cursor addressing, 24-bit colour, hide/show cursor.
    Windows Terminal supports all of it, and nothing here needs a font,
    module or binary that is not already on the machine.

.PARAMETER Name
    Window name, shown as the thing being booted.

.PARAMETER Index
    Window number, picks the accent colour. Cycles every four.

.PARAMETER Style
    matrix | bios | glitch | wave, or random (default) to pick one per launch.

.PARAMETER DurationMs
    Rough target length. Kept short on purpose - this plays before Claude
    starts, so every millisecond here is one the user waits.
#>
[CmdletBinding()]
param(
    [string] $Name  = 'CLAUDE',
    [int]    $Index = 1,
    [ValidateSet('random', 'matrix', 'bios', 'glitch', 'wave', 'figlet')]
    [string] $Style = 'random',
    [int]    $DurationMs = 1700
)

$ErrorActionPreference = 'Stop'

$E    = [char]27
$Rand = New-Object System.Random

# Without this every non-ASCII glyph reaches the terminal as '?'. The console
# encodes output in its code page, which on a default Windows box is 1252 and
# has no katakana and no block-drawing characters - so the rain and the bars
# come out as question marks. Note it is the ENCODING, not the font: a missing
# glyph renders as a box, a mis-encoded one renders as '?'.
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

# Accent per window, cycling every four - same four identities the banner and
# prompt use, so the animation belongs to the window rather than floating free.
$Accents = @(
    @(97, 175, 239),    # blue
    @(255, 121, 198),   # pink
    @(241, 250, 140),   # yellow
    @(80, 250, 123)     # green
)
$Acc = $Accents[(($Index - 1) % 4 + 4) % 4]
$AccFg = Fg $Acc[0] $Acc[1] $Acc[2]

# A terminal that cannot report its size cannot be drawn on reliably.
try {
    $size = $Host.UI.RawUI.WindowSize
    $W = [Math]::Max(24, [int]$size.Width)
    $H = [Math]::Max(9,  [int]$size.Height)
} catch {
    return
}

$Label = $Name.ToUpper()
# Letter-spaced, which is as close to "big" as a terminal gets without
# shipping a block font that would overflow on a long name anyway.
$Spaced = ($Label.ToCharArray() -join ' ')
if ($Spaced.Length -gt $W - 4) { $Spaced = $Label }
if ($Spaced.Length -gt $W - 4) { $Spaced = $Label.Substring(0, [Math]::Min($Label.Length, $W - 4)) }

function Show-Frame { param([string]$s) $Out.Write($s); $Out.Flush() }

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
    $dim  = Fg 0 110 50

    $y     = New-Object int[] $W
    $rate  = New-Object int[] $W
    $trail = New-Object int[] $W
    $prev  = New-Object 'char[]' $W
    for ($c = 0; $c -lt $W; $c++) {
        $y[$c]     = -$Rand.Next(0, $H)
        $rate[$c]  = $Rand.Next(1, 4)
        $trail[$c] = $Rand.Next(5, 16)
        $prev[$c]  = ' '
    }

    $frames  = [int]($DurationMs / 35)
    $resolve = [int]($frames * 0.55)
    $mid     = [int]($H / 2)
    $startCol = [int](($W - $Spaced.Length) / 2) + 1

    Show-Frame "$E[2J"
    for ($f = 0; $f -lt $frames; $f++) {
        $sb = New-Object System.Text.StringBuilder
        for ($c = 0; $c -lt $W; $c++) {
            if ($f % $rate[$c] -ne 0) { continue }

            # Re-colour the previous head to trail green, then draw the new one
            # white. Only these two cells change, so the rest of the trail keeps
            # the colour it was drawn with - full redraws are what kill framerate.
            $py = $y[$c]
            if ($py -ge 1 -and $py -le $H -and $prev[$c] -ne ' ') {
                [void]$sb.Append((At $py ($c + 1))).Append($body).Append($prev[$c])
            }

            $y[$c]++
            $ny = $y[$c]
            $ch = $glyphs[$Rand.Next(0, $gn)]
            if ($ny -ge 1 -and $ny -le $H) {
                [void]$sb.Append((At $ny ($c + 1))).Append($head).Append($ch)
            }
            $prev[$c] = $ch

            $ty = $ny - $trail[$c]
            if ($ty -ge 1 -and $ty -le $H) {
                [void]$sb.Append((At $ty ($c + 1))).Append(' ')
            }
            if ($ny -gt $H + $trail[$c]) {
                $y[$c]     = -$Rand.Next(0, 8)
                $rate[$c]  = $Rand.Next(1, 4)
                $trail[$c] = $Rand.Next(5, 16)
                $prev[$c]  = ' '
            }
        }

        if ($f -ge $resolve) {
            # Hold a clear band so the rain never runs through the name.
            $p = [Math]::Min(1.0, ($f - $resolve) / [double][Math]::Max(1, ($frames - $resolve - 3)))
            $show = [int][Math]::Ceiling($Spaced.Length * $p)
            [void]$sb.Append((At ($mid - 1) 1)).Append((' ' * $W))
            [void]$sb.Append((At ($mid + 1) 1)).Append((' ' * $W))
            [void]$sb.Append((At $mid 1)).Append((' ' * $W))
            [void]$sb.Append((At $mid $startCol)).Append($Bold).Append($AccFg)
            [void]$sb.Append($Spaced.Substring(0, [Math]::Min($show, $Spaced.Length)))
        }

        [void]$sb.Append($Reset)
        Show-Frame $sb.ToString()
        Start-Sleep -Milliseconds 35
    }
}

# --- bios --------------------------------------------------------------------
function Play-Bios {
    $ok   = Fg 80 250 123
    $grey = Fg 125 133 144
    $white = Fg 230 237 243

    $checks = @(
        @('terminal',    'vt / truecolor'),
        @('palette',     '16 / 16'),
        @('workspace',   'mounted'),
        @('permissions', 'bypassed')
    )

    $dot = [char]0x00B7
    Show-Frame "$E[2J$(At 2 3)$Bold$AccFg CLAUDE BOOT SEQUENCE $Reset$grey  $dot  node $Reset$white$Label$Reset"
    $rule = [string][char]0x2500 * [Math]::Min($W - 5, 46)
    Show-Frame "$(At 3 3)$grey$rule$Reset"
    Start-Sleep -Milliseconds 90

    $row = 5
    foreach ($c in $checks) {
        $dots = '.' * [Math]::Max(2, 18 - $c[0].Length)
        Show-Frame "$(At $row 3)$grey[ $Reset$ok`OK$grey ]$Reset  $white$($c[0]) $grey$dots $Reset$($c[1])"
        $row++
        Start-Sleep -Milliseconds 110
    }

    Show-Frame "$(At $row 3)$grey[ $Reset$AccFg..$grey ]$Reset  $white`claude $grey........... $Reset`starting"
    $row += 2

    # Gradient bar: red at empty, amber mid, green at full, so the colour itself
    # reports progress rather than just the length of the fill.
    $barW = [Math]::Min($W - 12, 40)
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
        Start-Sleep -Milliseconds ([Math]::Max(8, [int]($DurationMs * 0.45 / $barW)))
    }

    Show-Frame "$(At ($row + 2) 3)$Bold$ok`CLAUDE ONLINE$Reset"
    Start-Sleep -Milliseconds 260
}

# --- glitch ------------------------------------------------------------------
function Play-Glitch {
    # Built from code points rather than written literally: PowerShell 5.1 reads
    # a .ps1 as ANSI unless it carries a BOM, so non-ASCII literals in the source
    # are one careless re-save away from turning into mojibake.
    $noise = @()
    foreach ($code in 0x2593, 0x2592, 0x2591, 0x2588, 0x259A, 0x259E, 0x259B, 0x259C, 0x2584, 0x2580, 0x2590, 0x258C) {
        $noise += [char]$code
    }
    foreach ($ch in '#', '%', '&', '@', '$', '?', '!', '/', '\', '|', '<', '>', '=', '+', '*') {
        $noise += [char]$ch
    }
    $nn = $noise.Count
    $mid = [int]($H / 2)
    $startCol = [int](($W - $Spaced.Length) / 2) + 1
    $chars = $Spaced.ToCharArray()
    $white = Fg 230 237 243

    Show-Frame "$E[2J"

    # Frame the panel first so the noise has somewhere to live.
    $bw = [Math]::Min($W - 4, $Spaced.Length + 8)
    $bx = [int](($W - $bw) / 2) + 1
    Show-Frame "$(At ($mid - 2) $bx)$AccFg$([char]0x250C)$([string][char]0x2500 * ($bw - 2))$([char]0x2510)$Reset"
    Show-Frame "$(At ($mid + 2) $bx)$AccFg$([char]0x2514)$([string][char]0x2500 * ($bw - 2))$([char]0x2518)$Reset"

    # Scramble, then lock characters in a random order so it reads as decrypting
    # rather than simply typing out left to right.
    $order = 0..($chars.Count - 1) | Sort-Object { $Rand.Next() }
    $locked = New-Object bool[] $chars.Count
    $steps = $chars.Count + 6
    $per = [Math]::Max(18, [int]($DurationMs * 0.6 / [Math]::Max(1, $steps)))

    for ($s = 0; $s -lt $steps; $s++) {
        if ($s -lt $order.Count) { $locked[$order[$s]] = $true }
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
    foreach ($pass in 1, 2) {
        Show-Frame "$(At $mid ([Math]::Max(1, $startCol - 1)))$(Fg 255 60 60)$Spaced$Reset"
        Show-Frame "$(At $mid ([Math]::Min($W, $startCol + 1)))$(Fg 60 230 255)$Spaced$Reset"
        Start-Sleep -Milliseconds 45
        Show-Frame "$(At $mid 1)$(' ' * $W)$(At $mid $startCol)$Bold$white$Spaced$Reset"
        Start-Sleep -Milliseconds 55
    }
    Start-Sleep -Milliseconds 180
}

# --- wave --------------------------------------------------------------------
function Play-Wave {
    $blocks = [char[]]@(0x2581, 0x2582, 0x2583, 0x2584, 0x2585, 0x2586, 0x2587, 0x2588)
    $mid = [int]($H / 2)
    $top = [Math]::Max(1, $mid - 2)
    $bot = [Math]::Min($H, $mid + 2)
    $startCol = [int](($W - $Spaced.Length) / 2) + 1
    $frames = [int]($DurationMs / 40)

    Show-Frame "$E[2J"
    for ($f = 0; $f -lt $frames; $f++) {
        $phase = $f * 0.42
        $sb = New-Object System.Text.StringBuilder

        foreach ($row in @($top, $bot)) {
            $dir = 1
            if ($row -eq $bot) { $dir = -1 }
            [void]$sb.Append((At $row 1))
            for ($x = 0; $x -lt $W; $x++) {
                $v = [Math]::Sin(($x * 0.22) + ($phase * $dir))
                $lvl = [int](($v + 1) / 2 * 7)
                # Hue sweeps along x so the crest reads as travelling, not pulsing.
                $t = ($x / [double]$W + $f / 40.0) % 1.0
                $r = [int](127 + 127 * [Math]::Sin(6.283 * $t))
                $g = [int](127 + 127 * [Math]::Sin(6.283 * ($t + 0.33)))
                $b = [int](127 + 127 * [Math]::Sin(6.283 * ($t + 0.66)))
                [void]$sb.Append((Fg $r $g $b)).Append($blocks[$lvl])
            }
        }

        # Name fades up out of the middle as the waves run.
        $p = [Math]::Min(1.0, $f / [double][Math]::Max(1, $frames * 0.6))
        $lv = [int](60 + 195 * $p)
        [void]$sb.Append((At $mid 1)).Append((' ' * $W))
        [void]$sb.Append((At $mid $startCol)).Append($Bold).Append((Fg $lv $lv $lv))
        [void]$sb.Append([char]0x25C6).Append('  ').Append($Spaced).Append('  ').Append([char]0x25C6)
        [void]$sb.Append($Reset)

        Show-Frame $sb.ToString()
        Start-Sleep -Milliseconds 40
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

# --- run ---------------------------------------------------------------------
if ($Style -eq 'random') {
    $Style = @('matrix', 'bios', 'glitch', 'wave', 'figlet')[$Rand.Next(0, 5)]
}

try {
    Show-Frame "$E[?25l"          # hide cursor
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
