#!/usr/bin/env python3
"""build-icon.py — generate VoiceSay.icns + a preview PNG in build/.

Design: dark blue square (matching Tokens.bg #0a1320), centered white
speech-wave glyph (three vertical bars suggesting audio levels), wrapped
in the app's accent border (#5fb3ff, Tokens.accent) so the icon frame
matches the accent used throughout the app. Output is a macOS-native
multi-resolution .icns built via the standard iconset → iconutil pipeline,
plus a standalone 1024px preview PNG.

Usage:
  python3 build-icon.py
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).parent
ICONSET_DIR = HERE / "build" / "AppIcon.iconset"
ICNS_OUT = HERE / "build" / "AppIcon.icns"

# Tokens.accent `#5fb3ff`, so the icon border matches the in-app accent.
BORDER_ACCENT = (95, 179, 255, 255)
BG_DARK = (10, 19, 32, 255)
GLYPH_WHITE = (232, 240, 250, 255)

# Apple's required iconset sizes (rendered, filename).
SIZES = [
    (16,  "icon_16x16.png"),
    (32,  "icon_16x16@2x.png"),
    (32,  "icon_32x32.png"),
    (64,  "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]


def rounded_rect_mask(size: int, radius: int) -> Image.Image:
    """Single-channel mask with a rounded square."""
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return m


def render(size: int) -> Image.Image:
    """Render the icon at the given pixel size. All proportions are
    expressed as fractions of `size` so the artwork stays crisp at every
    Apple-required dimension from 16 to 1024."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # Outer rounded square (clip mask) — macOS will already clip to the
    # squircle for app icons, but we render our own rounded background
    # so the border reads cleanly at every size.
    corner = int(size * 0.22)
    mask = rounded_rect_mask(size, corner)

    # Dark fill
    fill = Image.new("RGBA", (size, size), BG_DARK)
    img.paste(fill, (0, 0), mask)

    # Accent border — drawn as a thick rounded-rect stroke just inside
    # the outer edge. Width scales with size so it stays visible even at
    # 16px (where it'll be 2 px and read as a thin frame).
    border_w = max(2, int(size * 0.055))
    border = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bd = ImageDraw.Draw(border)
    for offset in range(border_w):
        bd.rounded_rectangle(
            (offset, offset, size - 1 - offset, size - 1 - offset),
            radius=max(1, corner - offset),
            outline=BORDER_ACCENT,
            width=1,
        )
    img.alpha_composite(border)

    # Centre glyph — three voice-level bars, sized to live entirely within
    # the border with comfortable margin on every side. The
    # half-heights are clamped to GLYPH_MAX_HALF so the tallest bar never
    # crowds the border.
    bar_count = 3
    bar_w = int(size * 0.09)
    gap = int(size * 0.06)
    block_w = bar_count * bar_w + (bar_count - 1) * gap
    cx = size // 2
    cy = size // 2
    x0 = cx - block_w // 2

    GLYPH_MAX_HALF = 0.27  # max half-height as a fraction of size
    heights_frac = [GLYPH_MAX_HALF * 0.55, GLYPH_MAX_HALF * 1.00, GLYPH_MAX_HALF * 0.72]
    d = ImageDraw.Draw(img)
    bar_radius = max(1, bar_w // 3)
    for i, hf in enumerate(heights_frac):
        bx0 = x0 + i * (bar_w + gap)
        bh = int(size * hf)
        bar_box = (bx0, cy - bh, bx0 + bar_w, cy + bh)
        if hasattr(d, "rounded_rectangle"):
            d.rounded_rectangle(bar_box, radius=bar_radius, fill=GLYPH_WHITE)
        else:
            d.rectangle(bar_box, fill=GLYPH_WHITE)

    return img


def main() -> int:
    if ICONSET_DIR.exists():
        shutil.rmtree(ICONSET_DIR)
    ICONSET_DIR.mkdir(parents=True)

    for size, name in SIZES:
        img = render(size)
        img.save(ICONSET_DIR / name, format="PNG")
        print(f"  {size:>4}px → {name}")

    print(f"[iconutil] {ICONSET_DIR} → {ICNS_OUT}")
    rc = subprocess.run(
        ["iconutil", "--convert", "icns", "--output", str(ICNS_OUT), str(ICONSET_DIR)],
        check=False,
    ).returncode
    if rc != 0:
        print("iconutil failed", file=sys.stderr)
        return rc

    # Standalone PNG preview next to the .icns, for previewing without
    # launching the bundle. Kept inside build/ so each build stays deterministic.
    preview_png = ICNS_OUT.parent / "VoiceSay-icon-preview.png"
    render(1024).save(preview_png, format="PNG")
    print(f"[preview] {preview_png}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
