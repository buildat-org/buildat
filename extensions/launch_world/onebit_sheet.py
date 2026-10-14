#!/usr/bin/env python3
"""[MARK_ONEBIT]: how a logo becomes one bit, as a sheet to pick from.

    extensions/launch_world/onebit_sheet.py

An orb's mark is one bit on three of the room's surfaces -- a hole in a
glowing orb's emission, a patch of a mirror that stops being metal, an
etch in a white sphere's roughness -- and how a *logo* becomes that bit
is the pick this sheet is for. No engine: the transforms are here, over
the logos this tree ships, and the sheet is a picture.

**The round is settled** (2026-09-24): the mark is the largest
per-channel colour difference to a drawn neighbour, above a threshold
searched for an ink share of MARK_INK, unioned with the alpha
silhouette. That is the first column, and the sheet is now a record of
why rather than a menu -- the columns beside it are the choices that
were made and the reasons they were made, so that each is not asked
again:

  lum auto    -- the same search over brightness: what colour buys.
  outline     -- one fixed threshold: a dirt cube as a bare hexagon,
                 which is why the threshold is searched.
  alpha       -- the cut-out, and the blob a coloured logo becomes.
  luminance   -- the polarity trap: the buildat logo is luminance 1
                 everywhere it is drawn, and vanishes.
  outline|dither -- tone bought with four times the ink; rejected as
                 noise with a shape around it at this size.

Rows are the logos, the first column is the original and each further
column is a method. **Judged at the size the sphere gives it**: the
mark is about 64 texels on an orb, so every method is applied to a
64-pixel version rather than to the original -- a logo that thresholds
well at 512 can be mush at 64.

**Polarity is the trap.** A logo may be white lines on transparency or
black ink on white, and a mark needs the *shape* to be the ink either
way. The buildat logo is luminance 1 everywhere it is drawn, which is
what made it vanish under a luminance threshold. Every method here says
how it decides, and a method that gets it backwards shows as an
inverted tile rather than as a quiet mistake.

Writes local/options_for_LAUNCH_WORLD_mark_onebit/sheet.png.
"""
import os
import sys
import glob

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "local", "options_for_LAUNCH_WORLD_mark_onebit")
SIZE = 64          # the size a mark gets on an orb
TILE = 128         # how big a tile is drawn on the sheet

LOGOS = [
    "client/data/buildat_logo.png",
    "apps/vanilla/launcher/grass_block.png",
    "extensions/luanti_client/res/icon.png",
    "extensions/launch_menu/res/icon_local.png",
    "extensions/launch_menu/res/icon_network.png",
    "extensions/launch_menu/res/icon_preferences.png",
]


def load(path):
    im = Image.open(path).convert("RGBA")
    # **Down first, then decide.** Every method is judged at the size
    # the sphere gives it, so the resize is part of the input rather
    # than of any one method.
    return im.resize((SIZE, SIZE), Image.LANCZOS)


# The picture the colour methods need, kept beside the row being drawn
# rather than threaded through ten method signatures that do not want it.
CURRENT_RGB = None


def parts(im):
    global CURRENT_RGB
    a = np.asarray(im, dtype=np.float32) / 255.0
    rgb, alpha = a[..., :3], a[..., 3]
    CURRENT_RGB = rgb
    lum = rgb[..., 0] * 0.299 + rgb[..., 1] * 0.587 + rgb[..., 2] * 0.114
    return lum, alpha


def colour_distance(alpha):
    """**A feature is a colour difference, not a brightness one** (user,
    2026-09-24). Two patches can differ in hue or in saturation at the
    same brightness and still be the strongest thing in a logo -- a
    ContentDB icon's coloured corner markers against grey are exactly
    that, and a luminance gradient is blind to them by construction.

    **The largest single-channel difference**, over the four
    neighbours. It was drawn against CIE dE76 in Lab and five other
    metrics (`outline_cheap.png`) and agrees with Lab on every logo
    this tree ships; it wins the row that separates them, and it is
    three subtractions rather than a colour space the room would have
    to carry.

    **The reason a crude metric can stand in here**: the threshold is
    searched for an ink share rather than fixed, so a metric only has
    to rank edges in roughly the same order -- the search divides its
    absolute scale out. Luminance still could not, because it does not
    rank a coloured marker low, it scores it at zero.

    Taken among drawn pixels only: an undrawn neighbour contributes
    nothing rather than black, or a cut-out's own edge is the strongest
    feature in the picture and every line-art icon comes out fat.
    """
    drawn = alpha >= 0.5
    g = np.zeros(drawn.shape, dtype=np.float32)
    for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        near = np.roll(np.roll(CURRENT_RGB, dy, 0), dx, 1)
        d = np.abs(CURRENT_RGB - near).max(axis=-1)
        g = np.fmax(g, np.where(drawn & np.roll(np.roll(drawn, dy, 0), dx, 1),
                d, 0.0))
    return np.where(drawn, g, 0.0)


def as_tile(mask, name):
    """A mask is True where the mark is; the mark is drawn black."""
    px = np.where(mask, 0, 255).astype(np.uint8)
    return Image.fromarray(px, mode="L").convert("RGB"), name


def ink_share(mask):
    return float(mask.mean())


# ---- the methods ---------------------------------------------------

def m_alpha(lum, alpha):
    """The shape is the cut-out. What most icons want, and it says
    nothing about colour -- so polarity cannot go wrong."""
    return alpha >= 0.5


def m_luminance(lum, alpha):
    """A fixed cut at 0.5, the room's rule before this round. Dark ink
    on light ground only: a white logo on transparency vanishes."""
    return (lum < 0.5) & (alpha >= 0.5)



def m_outline(lum, alpha, t=0.15):
    """A morphological gradient: any logo becomes a line drawing, which
    is the most *etched* of the lot and does not care whether the ink
    is light or dark. `t` is swept by m_outline_auto rather than
    chosen; the default is only what the first sheet was drawn with."""
    v = np.where(alpha >= 0.5, lum, 0.0)
    pad = np.pad(v, 1, mode="edge")
    hi = np.maximum.reduce([pad[:-2, 1:-1], pad[2:, 1:-1],
            pad[1:-1, :-2], pad[1:-1, 2:], v])
    lo = np.minimum.reduce([pad[:-2, 1:-1], pad[2:, 1:-1],
            pad[1:-1, :-2], pad[1:-1, 2:], v])
    edge = hi - lo
    a = np.pad(alpha, 1, mode="edge")
    ahi = np.maximum.reduce([a[:-2, 1:-1], a[2:, 1:-1], a[1:-1, :-2],
            a[1:-1, 2:], alpha])
    alo = np.minimum.reduce([a[:-2, 1:-1], a[2:, 1:-1], a[1:-1, :-2],
            a[1:-1, 2:], alpha])
    return (edge > t) | ((ahi - alo) > 0.5)


MARK_INK = 0.16    # how much of the mark is ink, the quantity held still


def m_outline_colour(lum, alpha, t=0.15):
    """The outline over the colour distance instead of the luminance
    one. The alpha silhouette is the same second term."""
    g = colour_distance(alpha)
    a = np.pad(alpha, 1, mode="edge")
    ahi = np.maximum.reduce([a[:-2, 1:-1], a[2:, 1:-1], a[1:-1, :-2],
            a[1:-1, 2:], alpha])
    alo = np.minimum.reduce([a[:-2, 1:-1], a[2:, 1:-1], a[1:-1, :-2],
            a[1:-1, 2:], alpha])
    return (g > t) | ((ahi - alo) > 0.5)


def m_outline_luminance_auto(lum, alpha):
    """**The same search over a brightness difference**, kept as the
    column that shows what colour buys: a ContentDB icon's coloured
    corner markers against grey come out faint and partial here and
    clean beside it, because luminance does not rank them low -- it
    scores them at zero."""
    best = None
    for t in np.arange(0.02, 0.61, 0.01):
        mask = m_outline(lum, alpha, float(t))
        d = abs(float(mask.mean()) - MARK_INK)
        if best is None or d <= best[0]:
            best = (d, mask)
    return best[1]


def m_outline_auto(lum, alpha):
    """**The reference, and the pick** (user, 2026-09-24): the colour
    outline with its threshold searched rather than chosen. What is constant is
    how much of the sphere the mark covers -- a person reads that from
    across the room -- so `t` is whatever lands nearest MARK_INK. A
    fixed threshold cannot serve both a flat icon and a photograph:
    0.15 reduces a dirt cube to a bare hexagon, and 0.04 turns a
    ContentDB thumbnail into 48% ink.

    Ties go to the higher `t`, the sparser mark being the safer one.
    The target is an aim and not a guarantee: half of these logos are
    line art on transparency whose mark comes entirely from the alpha
    term, and no threshold moves them at all.
    """
    best = None
    for t in np.arange(0.02, 0.61, 0.01):
        mask = m_outline_colour(lum, alpha, float(t))
        d = abs(float(mask.mean()) - MARK_INK)
        if best is None or d <= best[0]:
            best = (d, mask, float(mask.mean()))
    # A picture with no contrast has no edges, and the search runs to
    # the end of its range chasing a target it cannot reach. The
    # cut-out is the only other mark available -- but only when there
    # is a cut-out: on a fully opaque thumbnail alpha is the whole
    # tile, which is a black sphere rather than a mark, and worse than
    # the specks it replaced.
    if best[2] < MARK_INK * 0.4:
        cut = m_alpha(lum, alpha)
        if float(cut.mean()) < 0.45:
            return cut
        # Neither works: this logo has no mark in it, and the room's
        # generated sigil is what such a game should get.
    return best[1]



def m_dither(lum, alpha):
    """Floyd-Steinberg, to rule out: it keeps apparent tone and should
    be noise at this size."""
    v = np.where(alpha >= 0.5, lum, 1.0).astype(np.float32).copy()
    h, w = v.shape
    for y in range(h):
        for x in range(w):
            old = v[y, x]
            new = 1.0 if old >= 0.5 else 0.0
            v[y, x] = new
            err = old - new
            if x + 1 < w:
                v[y, x + 1] += err * 7 / 16
            if y + 1 < h:
                if x > 0:
                    v[y + 1, x - 1] += err * 3 / 16
                v[y + 1, x] += err * 5 / 16
                if x + 1 < w:
                    v[y + 1, x + 1] += err * 1 / 16
    return (v < 0.5) & (alpha >= 0.5)


def m_outline_or_dither(lum, alpha):
    """The union of the two that fail in opposite directions: the
    outline is a shape with nothing inside it, the dither is tone with
    no shape. Together, a readable silhouette whose large flat areas
    carry some value."""
    return m_outline(lum, alpha) | m_dither(lum, alpha)


# **The reference column comes first**, beside the original: every
# future round is judged against the best so far, not against nothing.
METHODS = [
    # **The settled transform comes first**, beside the original: every
    # future round is judged against it rather than against nothing.
    ("auto %d%%" % (MARK_INK * 100), m_outline_auto),
    # The rest are here to hold the round's decisions, not as choices.
    # Each one is a question somebody will otherwise ask again.
    ("lum auto %d%%" % (MARK_INK * 100), m_outline_luminance_auto),
    ("outline .15", m_outline),
    ("alpha", m_alpha),
    ("luminance .5", m_luminance),
    ("outl|dither", m_outline_or_dither),
]



def main():
    os.makedirs(OUT, exist_ok=True)
    paths = [os.path.join(ROOT, p) for p in LOGOS]
    paths = [p for p in paths if os.path.exists(p)]
    # **A game's own icon is what a mark usually is**, and those follow
    # none of this tree's conventions -- so a few off ContentDB, by
    # size rather than by name, since the cache is hashes.
    thumbs = []
    for p in sorted(glob.glob(os.path.join(ROOT, "cache", "tmp", "*.png")))[:400]:
        try:
            im = Image.open(p)
            if im.size[0] >= 96 and im.size[0] == im.size[1]:
                thumbs.append(p)
        except Exception:
            pass
        if len(thumbs) >= 3:
            break
    paths += thumbs
    if not paths:
        print("no logos found")
        return 1
    try:
        font = ImageFont.truetype(
                "/usr/share/fonts/liberation-mono/LiberationMono-Bold.ttf", 18)
    except Exception:
        font = ImageFont.load_default()
    cols = 1 + len(METHODS)
    sheet = Image.new("RGB", (cols * (TILE + 6) + 6,
            (len(paths) + 1) * (TILE + 6) + 6), (18, 18, 20))
    d = ImageDraw.Draw(sheet)
    for i, (name, _) in enumerate([("original", None)] + METHODS):
        d.text((6 + (i + 0) * (TILE + 6) + 4, 8), name, fill=(255, 220, 120),
                font=font)
    print("%-34s %s" % ("logo", "  ".join("%-9s" % n for n, _ in METHODS)))
    for r, p in enumerate(paths):
        im = load(p)
        lum, alpha = parts(im)
        y = 6 + (r + 1) * (TILE + 6)
        flat = Image.new("RGB", im.size, (255, 255, 255))
        flat.paste(im, (0, 0), im)
        sheet.paste(flat.resize((TILE, TILE), Image.NEAREST), (6, y))
        shares = []
        for c, (name, fn) in enumerate(METHODS):
            mask = fn(lum, alpha)
            shares.append(ink_share(mask))
            tile, _ = as_tile(mask, name)
            sheet.paste(tile.resize((TILE, TILE), Image.NEAREST),
                    (6 + (c + 1) * (TILE + 6), y))
        short = os.path.relpath(p, ROOT)
        if short.startswith("cache/"):
            short = "contentdb/" + os.path.basename(p)[:8]
        print("%-34s %s" % (short[-34:],
                "  ".join("%8.1f%%" % (s * 100) for s in shares)))
        d.text((10, y + TILE - 22), short[-16:], fill=(200, 200, 200),
                font=font)
    sheet.save(os.path.join(OUT, "sheet.png"))
    print("\nthe sheet: %s/sheet.png -- the original first, a method a "
            "column; the mark is the black" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
