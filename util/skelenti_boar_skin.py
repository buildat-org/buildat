#!/usr/bin/env python3
# skelenti's boar skin (user, 2026-10-14: a boar, not a pig): a dark
# brown-grey bristly coat, a darker bristle ridge down the spine, darker
# legs and hooves, a grey snout with tusks. The layout is the boxes of
# apps/demo_skelenti/main/client_lua/mobs.lua's KINDS.skelenti_boar.
#   util/skelenti_boar_skin.py [out.png]
import random, sys
from PIL import Image

OUT = sys.argv[1] if len(sys.argv) > 1 else \
	"apps/demo_skelenti/main/game/mods/skelenti/textures/skelenti_boar.png"
im = Image.new("RGBA", (64, 32), (0, 0, 0, 0))
rnd = random.Random(7)

def coat(base, spread=10):
	# Bristles: a pixel lighter or darker than its neighbour
	k = rnd.randint(-spread, spread)
	if rnd.random() < 0.12:
		k += 18
	return tuple(max(0, min(255, c + k)) for c in base) + (255,)

def fill(x, y, w, h, base, spread=10):
	for j in range(h):
		for i in range(w):
			im.putpixel((x + i, y + j), coat(base, spread))

def skin(u, v, w, h, d):
	return {"top": (u + d, v, w, d), "bottom": (u + d + w, v, w, d),
		"right": (u, v + d, d, h), "front": (u + d, v + d, w, h),
		"left": (u + d + w, v + d, d, h), "back": (u + 2 * d + w, v + d, w, h)}

COAT = (78, 62, 50)
BELLY = (96, 80, 66)
RIDGE = (42, 34, 30)
LEG = (52, 42, 36)
HOOF = (28, 24, 22)
SNOUT = (92, 78, 72)
TUSK = (232, 226, 204)
EYE = (12, 10, 10)

head, snout = skin(0, 0, 8, 8, 8), skin(16, 16, 4, 3, 1)
body, leg = skin(28, 8, 10, 16, 8), skin(0, 16, 4, 6, 4)
for f in head.values():
	fill(*f, COAT)
for f in body.values():
	fill(*f, COAT)
# The body lies along z: the skin's "back" is the spine, its "front" the
# belly; the ridge is the spine's middle columns, on into the sides' tops
x, y, w, h = body["back"]
fill(x + 3, y, 4, h, RIDGE, 14)
x, y, w, h = body["front"]
fill(x + 1, y, w - 2, h, BELLY, 8)
# The head: a ridge on top, dark ears at its back corners, eyes in front
x, y, w, h = head["top"]
fill(x + 3, y, 2, h, RIDGE, 14)
im.putpixel((x, y + h - 1), RIDGE + (255,)); im.putpixel((x + w - 1, y + h - 1), RIDGE + (255,))
x, y, w, h = head["front"]
im.putpixel((x + 1, y + 3), EYE + (255,)); im.putpixel((x + 6, y + 3), EYE + (255,))
for f in snout.values():
	fill(*f, SNOUT, 6)
x, y, w, h = snout["front"]
im.putpixel((x + 1, y + 1), EYE + (255,)); im.putpixel((x + 2, y + 1), EYE + (255,))
im.putpixel((x, y + h - 1), TUSK + (255,)); im.putpixel((x + w - 1, y + h - 1), TUSK + (255,))
for side in ("right", "left"):
	x, y, w, h = snout[side]
	im.putpixel((x, y + h - 1), TUSK + (255,))
for name, f in leg.items():
	fill(*f, LEG, 8)
	x, y, w, h = f
	if name not in ("top", "bottom"):
		fill(x, y + h - 1, w, 1, HOOF, 4)
fill(*leg["bottom"], HOOF, 4)
im.save(OUT)
