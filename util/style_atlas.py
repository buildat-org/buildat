#!/usr/bin/env python3
# [MENU_BRAND]: draws extensions/ui_utils/res/style.png in c_quiet
# (src/interface/web_brand.h) over the cells of the old grey atlas.
# Cells style.xml names get their own fill and border; the rest (arrows,
# toolbar, cursors) keep their shapes, their greys tinted toward the brand's.
# Run from the repository root; it rewrites the PNG in place.
from PIL import Image, ImageDraw

PATH = "extensions/ui_utils/res/style.png"
FIELD = (21, 21, 26)       # #15151a
PANEL = (35, 35, 44)       # #23232c
LINE = (58, 58, 72)        # #3a3a48
BUTTON = (52, 52, 64)
BUTTON_LINE = (84, 84, 102)
DOWN = (30, 30, 38)
EDGE = (102, 102, 102)     # #666, a field's border
CYAN = (38, 217, 255)      # #26d9ff, the focus
AMBER = (255, 158, 31)     # #ff9e1f, the main button
AMBER_FILL = (122, 79, 12)  # #ddd on it is 5:1
AMBER_DOWN = (90, 58, 9)
AMBER_FOCUS = (148, 96, 15)

im = Image.open(PATH).convert("RGBA")
px = im.load()

# The greys left as they are drawn take the brand's blue tint
for y in range(64):
	for x in range(im.width):
		r, g, b, a = px[x, y]
		if a and r == g == b and r < 200:
			px[x, y] = (r, r, min(255, round(r * 1.25)), a)

d = ImageDraw.Draw(im)


# A focus ring is inset inside the cell's own outer ring: the UI's texture is
# filtered, and an edge differing from the cell's above shows on it as a line
def cell(x, y, fill, line, width=1, ring=None):
	d.rectangle((x, y, x + 15, y + 15), fill=(0, 0, 0, 0))
	d.rounded_rectangle((x, y, x + 15, y + 15), radius=3, fill=fill,
			outline=line, width=width)
	if ring:
		d.rounded_rectangle((x + 1, y + 1, x + 14, y + 14), radius=2,
				outline=ring, width=2)


def mark(x, y, color):
	# A checkbox's tick
	d.line((x + 4, y + 8, x + 7, y + 11, x + 12, y + 4), fill=color, width=2)


for x in (16, 112):  # Button, Menu: normal, pressed; under them hover/focus
	cell(x, 0, BUTTON, BUTTON_LINE)
	cell(x + 16, 0, DOWN, BUTTON_LINE)
	cell(x, 16, BUTTON, BUTTON_LINE, ring=CYAN)
	cell(x + 16, 16, DOWN, BUTTON_LINE, ring=CYAN)
cell(48, 0, PANEL, LINE)              # Window, panels, tooltip
cell(64, 0, FIELD, EDGE)              # LineEdit
cell(64, 16, FIELD, EDGE, ring=CYAN)  # LineEdit focused
for x, y, ring in ((80, 0, None), (80, 16, CYAN)):
	cell(x, y, FIELD, EDGE, ring=ring)  # CheckBox
	cell(x + 16, y, FIELD, EDGE, ring=ring)
	mark(x + 16, y, CYAN)
# PrimaryButton (non-auto): normal, pressed; under them hover/focus. Away
# from the atlas' edges: the texture wraps, and the top row's cells would
# take a line of what is at the bottom
cell(160, 80, AMBER_FILL, AMBER, 2)
cell(176, 80, AMBER_DOWN, AMBER, 2)
cell(160, 96, AMBER_FOCUS, AMBER, ring=CYAN)
cell(176, 96, AMBER_DOWN, AMBER, ring=CYAN)

im.save(PATH)
