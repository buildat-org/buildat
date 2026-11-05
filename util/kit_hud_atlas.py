#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 OR MIT
# [KIT_HUD_STYLE] Writes builtin/kit/client_data/hud_atlas.png: white, the
# shapes in its alpha, tinted by a BorderImage's colour, each one's image
# rect a 128 px cell, 8 in a row: index 0..31 the pie's steps 1..32 of 32
# from twelve o'clock clockwise (31 the whole disc), 32 the ring. Run by
# hand; the png is committed (it does not change).
#   util/kit_hud_atlas.py builtin/kit/client_data/hud_atlas.png
import math
import sys

from PIL import Image

CELL, COLS, SS, R, RING = 128, 8, 4, 60.0, 0.86


def cover(i, x, y):
    """Whether a point in cell coordinates is in shape i."""
    dx, dy = x - CELL / 2, y - CELL / 2
    d = math.hypot(dx, dy)
    if d > R:
        return False
    if i == 32:
        return d >= R * RING
    return (math.atan2(dx, -dy) % (2 * math.pi)) <= (i + 1) / 32 * 2 * math.pi


size = 1024
im = Image.new("RGBA", (size, size), (255, 255, 255, 0))
px = im.load()
for i in range(33):
    ox, oy = (i % COLS) * CELL, (i // COLS) * CELL
    for y in range(CELL):
        for x in range(CELL):
            n = sum(cover(i, x + (a + 0.5) / SS, y + (b + 0.5) / SS)
                    for a in range(SS) for b in range(SS))
            px[ox + x, oy + y] = (255, 255, 255, n * 255 // (SS * SS))
im.save(sys.argv[1], optimize=True)
