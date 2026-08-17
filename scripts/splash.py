#!/usr/bin/env python3
"""
splash.py - big block-letter boot splash for one quad-claude window.

Invoked by Show-BootAnimation.ps1 as the 'figlet' style. The other four
animations are pure PowerShell; this one is Python because real block-letter
type needs a font database, and pyfiglet already ships 571 of them. Writing a
block font by hand was the compromise this replaces.

Degrades rather than fails: an unavailable font falls through to the next, a
logo too wide for the terminal falls back to letter-spaced text, and a missing
pyfiglet exits quietly so the caller can play a different animation instead.
"""
from __future__ import annotations

import argparse
import sys
import time

# Same class of bug the PowerShell side hit: without this, block-drawing
# characters reach a Windows console as '?' because stdout inherits the
# locale code page rather than UTF-8.
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

# The four window identities, matching the banner and prompt accents.
ACCENTS = ["#61afef", "#ff79c6", "#f1fa8c", "#50fa7b"]

# Tried in order; first one that renders AND fits the terminal wins.
FONTS = ["ansi_shadow", "banner3-D", "big", "slant", "standard", "small"]


def build_logo(text: str, width: int) -> list[str] | None:
    """Render text as block letters, or None if nothing fits."""
    try:
        import pyfiglet
    except ImportError:
        return None

    for font in FONTS:
        try:
            art = pyfiglet.figlet_format(text, font=font)
        except Exception:
            continue
        lines = [ln.rstrip() for ln in art.splitlines()]
        lines = [ln for ln in lines if ln.strip()]
        if lines and max(len(ln) for ln in lines) <= width - 6:
            return lines
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default="CLAUDE")
    ap.add_argument("--index", type=int, default=1)
    ap.add_argument("--duration", type=float, default=1.7)
    args = ap.parse_args()

    from rich.align import Align
    from rich.console import Console
    from rich.live import Live
    from rich.panel import Panel
    from rich.progress import Progress, SpinnerColumn, TextColumn
    from rich.text import Text

    console = Console()
    accent = ACCENTS[(args.index - 1) % 4]
    name = args.name.upper()

    lines = build_logo(name, console.width)
    if lines is None or len(lines) + 6 > console.height:
        # Too narrow, too short, or no pyfiglet: letter-spacing is as close to
        # "big" as a terminal gets without a font.
        lines = [" ".join(name)]

    def panel(shown: list[str]) -> Panel:
        body = Text("\n".join(shown), style=f"bold {accent}")
        return Panel(
            Align.center(body),
            border_style=accent,
            padding=(1, 4),
            title=f"[bold {accent}]{name}[/bold {accent}]",
            subtitle="[dim]claude code[/dim]",
        )

    console.clear()

    # Reveal the logo a row at a time. Live redraws in place, so it wipes and
    # repaints rather than scrolling a new panel per frame.
    reveal = min(args.duration * 0.55, 1.2)
    per_line = reveal / max(1, len(lines))
    with Live(panel(lines[:1]), console=console, refresh_per_second=30) as live:
        for i in range(1, len(lines) + 1):
            live.update(panel(lines[:i]))
            time.sleep(per_line)

    # Then a spinner for whatever budget is left, so the splash reads as work
    # happening rather than a static image. transient=True clears it after.
    rest = max(0.3, args.duration - reveal)
    with Progress(
        SpinnerColumn("dots", style=accent),
        TextColumn(f"[{accent}]{{task.description}}[/{accent}]"),
        console=console,
        transient=True,
    ) as progress:
        progress.add_task("initialising claude", total=None)
        time.sleep(rest)

    console.clear()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        # Ctrl-C during a splash should drop straight into the session, not
        # leave a half-drawn panel and a traceback.
        print("\033[0m\033[2J\033[H", end="")
        sys.exit(0)
