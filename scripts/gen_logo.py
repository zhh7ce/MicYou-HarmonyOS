#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# MicYou — Turns your phone into a high-quality PC microphone.
# Copyright (C) 2026 zhh7ce <https://github.com/zhh7ce/MicYou-HarmonyOS>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.

"""Draw the MicYou HarmonyOS client logo and write every icon asset from it.

    python3 scripts/gen_logo.py

Requires Pillow. Flat two-tone mark: a rounded tile plus a microphone glyph.
Supersampled 8x so the capsule and arc stay smooth at 144 px. Rerun after
editing the geometry constants below.
"""

from pathlib import Path
import math

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
MEDIA = [ROOT / "AppScope/resources/base/media", ROOT / "entry/src/main/resources/base/media"]

TILE = (0, 99, 159)  # #00639F, resources/base/element/color.json "primary"
GLYPH = (255, 255, 255)
SS = 8  # supersample factor

# All coordinates are fractions of the glyph box, so one description scales to
# every output size.
CAP_X = 0.5
CAP_TOP = 0.06
CAP_W = 0.30
CAP_H = 0.47
ARC_CX = 0.5
ARC_CY = 0.40
ARC_R = 0.31
ARC_START = 25
ARC_END = 155
STEM_TOP = 0.66
STEM_BOTTOM = 0.85
BASE_HALF = 0.16
BASE_Y = 0.85
WEIGHT = 0.075  # stroke weight for arc, stem and base


def glyph_box(size: int, fraction: float) -> tuple[int, int, int, int]:
    side = int(round(size * fraction))
    origin = (size - side) // 2
    return (origin, origin, origin + side, origin + side)


def draw_glyph(im: Image.Image, box: tuple[int, int, int, int], color, weight: int) -> None:
    d = ImageDraw.Draw(im)
    x0, y0, x1, y1 = box
    w = x1 - x0
    h = y1 - y0

    cap = (
        x0 + int(round((CAP_X - CAP_W / 2) * w)),
        y0 + int(round(CAP_TOP * h)),
        x0 + int(round((CAP_X + CAP_W / 2) * w)),
        y0 + int(round((CAP_TOP + CAP_H) * h)),
    )
    d.rounded_rectangle(cap, radius=(cap[2] - cap[0]) // 2, fill=color)

    r = ARC_R * w
    cx = x0 + ARC_CX * w
    cy = y0 + ARC_CY * h
    arc = (cx - r, cy - r, cx + r, cy + r)
    d.arc(arc, ARC_START, ARC_END, fill=color, width=weight)

    stem_x = x0 + ARC_CX * w
    d.line(
        (stem_x, y0 + STEM_TOP * h, stem_x, y0 + STEM_BOTTOM * h),
        fill=color,
        width=weight,
    )
    half = BASE_HALF * w
    d.line(
        (stem_x - half, y0 + BASE_Y * h, stem_x + half, y0 + BASE_Y * h),
        fill=color,
        width=weight,
    )
    # Square the stroke ends so the base bar reads as a flat cut, not a capsule.
    d.rectangle(
        (stem_x - half - weight // 2, y0 + BASE_Y * h - weight // 2,
         stem_x + half + weight // 2, y0 + BASE_Y * h + weight // 2),
        fill=color,
    )


def tile(size: int, fraction: float) -> Image.Image:
    """Rounded-square app tile with the glyph centered on it."""
    s = size * SS
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    radius = int(round(s * 0.225))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((0, 0, s - 1, s - 1), radius=radius, fill=TILE + (255,))
    draw_glyph(im, glyph_box(s, fraction), GLYPH, int(round(s * WEIGHT)))
    return im.resize((size, size), Image.LANCZOS)


def foreground(size: int, fraction: float) -> Image.Image:
    """Layered-icon foreground: the glyph alone, white, on transparency."""
    s = size * SS
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw_glyph(im, glyph_box(s, fraction), GLYPH + (255,), int(round(s * WEIGHT)))
    return im.resize((size, size), Image.LANCZOS)


def background(size: int) -> Image.Image:
    return Image.new("RGBA", (size, size), TILE + (255,))


def main() -> None:
    for media in MEDIA:
        media.mkdir(parents=True, exist_ok=True)
        # Layered launcher icon: white glyph over the brand tile colour. The
        # system masks the pair, so keep the glyph inside the central 60 %.
        foreground(1024, 0.60).save(media / "foreground.png")
        background(1024).save(media / "background.png")
    entry = ROOT / "entry/src/main/resources/base/media"
    # Start-window icon and the in-app header mark.
    tile(144, 0.62).save(entry / "startIcon.png")
    tile(192, 0.62).save(entry / "app_logo.png")
    for media in [ROOT / "AppScope/resources/base/media", entry]:
        for name in sorted(p.name for p in media.glob("*.png")):
            print((media / name).relative_to(ROOT))


if __name__ == "__main__":
    main()
