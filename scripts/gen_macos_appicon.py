#!/usr/bin/env python3
"""Generate macOS-shaped app-icon PNGs from a full-bleed source image.

macOS (unlike iOS, and unlike macOS 26 Tahoe) does NOT mask app icons. It
expects the artwork itself to already carry the rounded-rectangle shape plus
the standard transparent margin around it. A full-bleed square source therefore
renders as a hard-cornered square in the Dock / Finder / Stage Manager on
macOS 15 and earlier.

This script bakes Apple's *shipping* macOS icon grid into the artwork. The
numbers below were measured from the 256px (128pt@2x) icons of Safari, Notes,
Reminders, App Store, System Settings, Music and Mail on macOS 15 — all
identical:

  * rounded square body   = 0.875 of the tile   (224/256)
  * side margin           = 0.0625 of the tile   (16/256, left & right)
  * top / bottom margin   = 0.0703 / 0.0547      (18/256 and 14/256 — the art
                            sits slightly high; the extra room below holds the
                            drop shadow)
  * corner radius         ~ 0.224 of the body

An earlier version of this script used the old published 824/1024 (0.805)
template with the body centred and no shadow; that came out visibly smaller
than its neighbours in Stage Manager, hence the measured values here.

Output files land next to the iOS icons in the AppIcon.appiconset and are wired
into the `mac` idiom entries of Contents.json (see that file).

Usage:  python3 scripts/gen_macos_appicon.py
"""

from __future__ import annotations

import pathlib

from PIL import Image, ImageDraw, ImageFilter

REPO = pathlib.Path(__file__).resolve().parent.parent
SOURCE = REPO / "icon_source.png"
OUT_DIR = REPO / "VikunjaWidgetApp/Assets.xcassets/AppIcon.appiconset"

# Apple's shipping macOS icon grid, as fractions of the full tile.
BODY_RATIO = 0.875
SIDE_MARGIN = 0.0625
TOP_MARGIN = 0.0703125
RADIUS_RATIO = 0.224  # of the body

# Drop shadow, as fractions of the full tile.
SHADOW_OFFSET_Y = 0.006
SHADOW_BLUR = 0.012
SHADOW_ALPHA = 62  # 0-255

# Every pixel size the `mac` idiom references in Contents.json.
SIZES = [16, 32, 64, 128, 256, 512, 1024]
SUPERSAMPLE = 4
MAX_RENDER = 4096


def render(size: int, src: Image.Image) -> Image.Image:
    ss = min(size * SUPERSAMPLE, MAX_RENDER)
    body = round(ss * BODY_RATIO)
    off_x = round((ss - body) / 2)
    off_y = round(ss * TOP_MARGIN)
    radius = round(body * RADIUS_RATIO)

    art = src.resize((body, body), Image.LANCZOS).convert("RGBA")

    mask = Image.new("L", (body, body), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, body - 1, body - 1], radius=radius, fill=255)

    canvas = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))

    # Soft drop shadow behind the body.
    shadow = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, SHADOW_ALPHA), (off_x, off_y + round(ss * SHADOW_OFFSET_Y)), mask)
    shadow = shadow.filter(ImageFilter.GaussianBlur(ss * SHADOW_BLUR))
    canvas.alpha_composite(shadow)

    canvas.paste(art, (off_x, off_y), mask)

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
