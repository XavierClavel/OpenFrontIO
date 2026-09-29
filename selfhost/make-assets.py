#!/usr/bin/env python3
"""Generates the replacement artwork and audio under selfhost/proprietary/.

Standard library only; the PNG and WebP renders also need `rsvg-convert` and
`cwebp` on PATH. Run from anywhere:

    python3 selfhost/make-assets.py

The outputs are committed, so this only needs re-running to change them (the
logo text is WORDMARK below). Two files are not generated here: the font
(fonts/OpenFront.ttf, Press Start 2P) and the game-start alert, which is copied
from the repository's own resources/sounds/effects/game-start.mp3.
"""

import shutil
import struct
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "selfhost" / "proprietary"

# The wordmark: a small top line over a large bottom line, and the monogram.
WORDMARK = [("XAVIER'S", 3), ("FRONT", 5)]  # (text, pixel size in grid units)
MONOGRAM = "XF"
LINE_GAP = 3  # grid units between the two wordmark lines

BLUE = "#0084d1"
LIGHT = "#e5e7eb"

# 5x7 bitmap glyphs, drawn for this logo. "1" is a lit pixel.
GLYPHS = {
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
    "I": ["111", "010", "010", "010", "010", "010", "111"],
    "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
    "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    "V": ["10001", "10001", "10001", "01010", "01010", "00100", "00100"],
    "X": ["10001", "10001", "01010", "00100", "01010", "10001", "10001"],
    "'": ["1", "1", "0", "0", "0", "0", "0"],
    " ": ["000", "000", "000", "000", "000", "000", "000"],
}


def glyph(ch: str, bold: bool) -> list[str]:
    rows = GLYPHS[ch]
    if not bold:
        return rows
    # Classic bitmap bold: OR each row with itself shifted one pixel right.
    return [
        "".join(
            "1" if (r + "0")[i] == "1" or ("0" + r)[i] == "1" else "0"
            for i in range(len(r) + 1)
        )
        for r in rows
    ]


def text_pixels(text: str, bold: bool) -> tuple[list[tuple[int, int, int]], int]:
    """Horizontal pixel runs (x, y, length) for a line of text, and its width."""
    runs, x = [], 0
    for i, ch in enumerate(text):
        rows = glyph(ch, bold)
        for y, row in enumerate(rows):
            start = None
            for cx, bit in enumerate(row + "0"):
                if bit == "1" and start is None:
                    start = cx
                elif bit != "1" and start is not None:
                    runs.append((x + start, y, cx - start))
                    start = None
        x += len(rows[0]) + (1 if i < len(text) - 1 else 0)
    return runs, x


def path_for(runs, ox: int, oy: int, px: int) -> str:
    return "".join(
        f"M{ox + x * px} {oy + y * px}h{n * px}v{px}h{-n * px}z" for x, y, n in runs
    )


def svg(width: int, height: int, color: str, d: str, sized: bool) -> str:
    # The main logo carries only a viewBox, like the file it replaces, so every
    # slot that sizes it (h-full w-auto, max-w/max-h) keeps working unchanged.
    size = f' width="{width}" height="{height}"' if sized else ""
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}"'
        f'{size} shape-rendering="crispEdges">'
        f'<path fill="{color}" d="{d}"/></svg>\n'
    )


def wordmark(width: int, height: int, color: str, sized: bool) -> str:
    lines = [(text_pixels(t, bold=True), s) for t, s in WORDMARK]
    natural_w = max(w * s for (_, w), s in lines)
    natural_h = sum(7 * s for _, s in lines) + LINE_GAP * (len(lines) - 1)
    # Largest whole-pixel scale that fits with a margin, so edges stay crisp.
    k = max(1, int(min(width * 0.94 / natural_w, height * 0.94 / natural_h)))
    y = (height - natural_h * k) // 2
    d = ""
    for (runs, w), s in lines:
        d += path_for(runs, (width - w * s * k) // 2, y, s * k)
        y += (7 * s + LINE_GAP) * k
    return svg(width, height, color, d, sized)


def monogram(width: int, height: int, color: str, margin: float, bold: bool) -> str:
    runs, w = text_pixels(MONOGRAM, bold)
    k = max(1, int(min(width * (1 - margin) / w, height * (1 - margin) / 7)))
    d = path_for(runs, (width - w * k) // 2, (height - 7 * k) // 2, k)
    return svg(width, height, color, d, sized=True)


def silent_mp3(seconds: float) -> bytes:
    """Constant-bitrate MPEG-1 Layer III, 32 kbit/s, 44.1 kHz mono, all silence.

    Each frame is a header followed by zeroed side information and main data:
    part2_3_length and big_values are zero, so every spectral line decodes to 0.
    """
    header = struct.pack(">I", 0xFFFB10C0)  # sync, MPEG-1, layer III, no CRC,
    # 32 kbit/s, 44.1 kHz, no padding, mono
    frame = header + bytes(144 * 32000 // 44100 - 4)  # 104-byte frames
    frames = round(seconds * 44100 / 1152)
    return frame * frames


def render(svg_path: Path, png_path: Path, width: int, height: int) -> None:
    subprocess.run(
        ["rsvg-convert", "-w", str(width), "-h", str(height), "-o", str(png_path), str(svg_path)],
        check=True,
    )


def webp(png_path: Path, webp_path: Path) -> None:
    subprocess.run(
        ["cwebp", "-quiet", "-lossless", str(png_path), "-o", str(webp_path)], check=True
    )


def main() -> None:
    images = OUT / "images"
    images.mkdir(parents=True, exist_ok=True)

    # Nav bar, play page, Steam button: 1364x259 like the original, viewBox only.
    (images / "OpenFrontLogo.svg").write_text(wordmark(1364, 259, BLUE, sized=False))
    # Light variant for dark backgrounds (upstream uses it in its README only).
    (images / "OpenFrontLogoDark.svg").write_text(wordmark(1310, 298, LIGHT, sized=True))
    # 11x11 pixel grid, like the original favicon: plain (not bold) XF.
    (images / "Favicon.svg").write_text(monogram(11, 11, BLUE, margin=0, bold=False))

    tmp = OUT / ".tmp"
    tmp.mkdir(exist_ok=True)
    try:
        # Rasters at the originals' sizes. Each is drawn for its own box rather
        # than scaled from another, so it stays pixel-sharp.
        for name, w, h, draw in [
            ("OpenFrontLogo", 450, 85, lambda: wordmark(450, 85, BLUE, sized=True)),
            ("OpenFront", 1310, 298, lambda: wordmark(1310, 298, BLUE, sized=True)),
            ("OF", 517, 298, lambda: monogram(517, 298, BLUE, margin=0.2, bold=True)),
        ]:
            src = tmp / f"{name}.svg"
            src.write_text(draw())
            render(src, images / f"{name}.png", w, h)
        for name in ["OpenFront", "OF"]:
            webp(images / f"{name}.png", images / f"{name}.webp")
    finally:
        shutil.rmtree(tmp)

    music = OUT / "sounds" / "music"
    music.mkdir(parents=True, exist_ok=True)
    for name in ["menu-theme.mp3", "gameplay.mp3"]:
        (music / name).write_bytes(silent_mp3(5))

    effects = OUT / "sounds" / "effects"
    effects.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(
        ROOT / "resources" / "sounds" / "effects" / "game-start.mp3",
        effects / "game-start-alert.mp3",
    )


if __name__ == "__main__":
    main()
