#!/usr/bin/env python3
"""Generate macOS-shaped app-icon PNGs from a full-bleed source image.

macOS (unlike iOS, and unlike macOS 26 Tahoe) does NOT mask app icons. It
expects the artwork itself to already carry the rounded-rectangle shape plus
the standard transparent margin around it. A full-bleed square source therefore
renders as a hard-cornered square in the Dock / Finder on macOS 15 and earlier.

This script bakes Apple's macOS icon grid into the artwork:
  * visible rounded square = 824/1024 of the tile (~10% clear margin each side)
  * corner radius          = 185.4/1024 of the tile (= 0.225 of the body)

Output files land next to the iOS icons in the AppIcon.appiconset and are wired
into the `mac` idiom entries of Contents.json (see that file).

Usage:  python3 scripts/gen_macos_appicon.py
"""

from __future__ import annotations

import pathlib

from PIL import Image, ImageDraw

REPO = pathlib.Path(__file__).resolve().parent.parent
SOURCE = REPO / "icon_source.png"
OUT_DIR = REPO / "VikunjaWidgetApp/Assets.xcassets/AppIcon.appiconset"

# Apple macOS icon grid, as fractions of the full tile.
BODY_RATIO = 824 / 1024
RADIUS_RATIO = 0.225  # of the body (continuous-ish corner)

# Every pixel size the `mac` idiom references in Contents.json.
SIZES = [16, 32, 64, 128, 256, 512, 1024]
SUPERSAMPLE = 4
MAX_RENDER = 4096


def render(size: int, src: Image.Image) -> Image.Image:
    ss = min(size * SUPERSAMPLE, MAX_RENDER)
    body = round(ss * BODY_RATIO)
    offset = (ss - body) // 2
    radius = round(body * RADIUS_RATIO)

    art = src.resize((body, body), Image.LANCZOS).convert("RGBA")

    mask = Image.new("L", (body, body), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, body - 1, body - 1], radius=radius, fill=255)

    canvas = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    canvas.paste(art, (offset, offset), mask)

    if ss != size:
        canvas = canvas.resize((size, size), Image.LANCZOS)
    return canvas


def main() -> None:
    src = Image.open(SOURCE).convert("RGBA")
    for size in SIZES:
        out = OUT_DIR / f"mac_icon_{size}.png"
        render(size, src).save(out)
        print(f"wrote {out.relative_to(REPO)}")


if __name__ == "__main__":
    main()
