#!/usr/bin/env python3
# Generates the five voxel textures demo_undermine adds to the ones it inherits
# from demo_digger (rock, dirt, grass, water). The output is committed, so this
# only needs running when one of them is being changed.
#
# 16x16 to match the textures already there, and RGB rather than RGBA
# because none of these has a hole in it. No normal or roughness map: the
# atlas derives both from the texture itself, see src/impl/atlas.cpp.
#
# What each texture has to do is say what the material *does* -- bedrock is
# not diggable, timber holds a span, brick carries weight -- from across a
# dark tunnel, so each is one clear pattern rather than a detailed surface.
import os
import struct
import zlib

SIZE = 16
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
        "main", "client_data")


def write_png(name, rows):
    def chunk(tag, data):
        c = tag + data
        return (struct.pack(">I", len(data)) + c +
                struct.pack(">I", zlib.crc32(c) & 0xffffffff))
    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    png = (b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(raw, 9)) +
            chunk(b"IEND", b""))
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(png)
    print(name)


# A value hash rather than a random number generator, so that a texel's noise
# depends only on where it is: the same seed gives the same texture on any
# machine, and neighbouring texels are uncorrelated.
def noise(x, y, seed):
    h = (x * 374761393 + y * 668265263 + seed * 2147483647) & 0xffffffff
    h = (h ^ (h >> 13)) * 1274126177 & 0xffffffff
    return ((h ^ (h >> 16)) & 0xffff) / 65535.0


def clamp(v):
    return max(0, min(255, int(v * 255.0 + 0.5)))


def solid(name, base, grain, seed, blob=1):
    # blob > 1 makes the noise coarser: the same value over a blob x blob
    # square, which is what reads as gravel rather than sand
    rows = []
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            n = noise(x // blob, y // blob, seed) - 0.5
            for c in base:
                row.append(clamp(c + n * grain))
        rows.append(row)
    write_png(name, rows)


def timber():
    # Vertical grain: a few darker lines down the texture, plus lengthwise
    # streaks, so a prop reads as a post standing up
    base = (0.44, 0.31, 0.18)
    rows = []
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            # Streaks are long in y and narrow in x
            n = (noise(x, y // 6, 11) - 0.5) * 0.10
            line = -0.09 if x % 5 == 0 else 0.0
            for c in base:
                row.append(clamp(c + n + line))
        rows.append(row)
    write_png("timber.png", rows)


def brick():
    # Courses 4 texels high, bricks 8 wide, offset half a brick each course,
    # with a texel of mortar between them. Whole numbers across 16 so it
    # tiles.
    brick_base = (0.47, 0.22, 0.17)
    mortar = (0.62, 0.60, 0.56)
    rows = []
    for y in range(SIZE):
        course = y // 4
        row = []
        for x in range(SIZE):
            xo = (x + (4 if course % 2 else 0)) % SIZE
            is_mortar = (y % 4 == 0) or (xo % 8 == 0)
            base = mortar if is_mortar else brick_base
            n = (noise(x, y, 23) - 0.5) * (0.04 if is_mortar else 0.09)
            for c in base:
                row.append(clamp(c + n))
        rows.append(row)
    write_png("brick.png", rows)


def main():
    # The stress view tints this rather than a material's own texture, so
    # that what is on screen is the gradient and nothing else
    solid("white.png", (1.0, 1.0, 1.0), 0.0, 0)
    # Nearly black and strongly speckled: the one thing in the world that
    # cannot be dug, and it should look like it
    solid("bedrock.png", (0.13, 0.13, 0.15), 0.16, 3)
    # Fine and pale
    solid("sand.png", (0.76, 0.68, 0.44), 0.10, 5)
    # Coarse and mixed, from a 2x2 blob: what everything becomes after it
    # falls
    solid("rubble.png", (0.42, 0.38, 0.34), 0.30, 7, blob=2)
    # Dirt that has taken water: darker and a little bluer, so that a wet
    # patch reads as one from across a tunnel
    # Half the brightness of dry dirt rather than a different brown: under a
    # lit sky the hue of a texture washes out and only the value survives,
    # so darkness is what reads as wet from across a tunnel
    solid("wet_dirt.png", (0.15, 0.115, 0.10), 0.06, 13)
    timber()
    brick()


main()
