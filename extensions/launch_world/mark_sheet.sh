#!/bin/bash
# [LAUNCH_WORLD]'s mark, the options round: the same orbs from the same
# place, both ways, into local/options_for_LAUNCH_WORLD_mark/.
#
#   extensions/launch_world/mark_sheet.sh
#
#   A  the icon in full colour in the diffuse, padded so the whole of it
#      shows -- a coloured picture in a glass marble
#   B  the same logo as one bit in the roughness -- an etch, the surface
#      taking the light differently where the mark is
#
# The glowing orbs are one way in both sheets: nothing greyer than about
# four per cent survives an emissive of 26, so their mark is one bit
# whatever is picked. What the sheets are for is **the white and the
# chrome ones**.
#
# No tier line: this makes a picture for a person to choose from, and
# decides nothing itself.
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
# BUILDAT_MARK_OUT names another directory to shoot into, so a re-shoot
# does not write over a sheet somebody is still looking at
out="${BUILDAT_MARK_OUT:-$here/local/options_for_LAUNCH_WORLD_mark}"
mkdir -p "$out"
cd "$here/Build"
if check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat client is already running" >&2; exit 2
fi
# **One shot of each kind of sphere, each presenting its face** (user,
# 2026-09-24): a glowing orb, a chrome one and a white one, since each
# surface does something different with a mark, and the round cannot be
# judged off whichever ball happened to be in frame.
#
# The camera is flown by the room's own search -- typing a name in menu
# mode flies to that thing and stops in front of it -- which is both
# deterministic and the way a player meets an orb.
#
# **On a client with no save of its own**: a sphere somebody moved is a
# sphere in the wrong place.
mkdir -p "$out/emptyuser"
shot() {   # $1 option ("" as shipped), $2 keys to type, $3 tag
	{ echo "delay 5000"
		echo "event mode menu"
		echo "delay 700"
		for c in $2; do echo "keypress $c"; done
		echo "delay 2600"
		echo "screenshot $out/$1-$3.png"
		echo "delay 400"
		echo "quit"; } > "$out/cmds_$1_$3.txt"
	# **A portrait distance**: the room's own hop stops four and a half
	# back, which frames the orb in its place rather than its face. Two
	# is where a mark can be judged (2026-09-24).
	# **Straight on, not from above**: a portrait of a mark, and close
	# in a camera that rises leaves a pocket's corridor for the slab
	# beside it (2026-09-25)
	env ${1:+BUILDAT_LAUNCH_MARK=$1} BUILDAT_LAUNCH_HOP="${HOP:-2.0}" \
		BUILDAT_LAUNCH_HOP_FLAT=1 \
		timeout 180 bin/buildat -m launch_world -D "$out/emptyuser" \
		-w 1280x720 -l 3 -c @"$out/cmds_$1_$3.txt" > "$out/cli_$1_$3.log" 2>&1
}
# **The glowing orb first** ([MARK_ONEBIT], 2026-09-24): the settled
# transform draws a thin outline, and the emission mask is where a thin
# line has the least room -- the cut is 0.04 of an emissive multiplied
# by 26 ([GLOW_MARK]), which is the top of the band a mark can read in,
# so if it does not read there the answer is line weight and not another
# transform. Chrome and white follow, each marked in the
# slot it can show.
#
# One row, as the room ships, since the A/B question is settled;
# OPTIONS="A B" brings the old two-row comparison back.
for opt in ${OPTIONS:-""}; do
	shot "$opt" "D I G G E R" glowing
	shot "$opt" "L O C A L H O S T" chrome
	shot "$opt" "I M P O R T" white
	# **And one mark that came from a logo** ([MARK_ONEBIT]): most orbs
	# in this tree wear the room's generated sigil, which is a height
	# field and keeps the plain cut -- so a sheet of those three says
	# nothing about the settled transform. "Luanti settings" ships an
	# icon of its own and is marked by it.
	shot "$opt" "L U A N T I Space S E T" logo
done
python3 - "$out" <<'PY'
import sys, os
from PIL import Image, ImageDraw, ImageFont
out = sys.argv[1]
kinds = ["glowing", "chrome", "white", "logo"]
tiles = []
for opt in (os.environ.get("OPTIONS", "").split() or [""]):
	for k in kinds:
		p = "%s/%s-%s.png" % (out, opt, k)
		if not os.path.exists(p):
			print("missing: %s" % p)
			continue
		im = Image.open(p).convert("RGB")
		d = ImageDraw.Draw(im)
		try:
			font = ImageFont.truetype(
					"/usr/share/fonts/liberation-mono/LiberationMono-Bold.ttf", 34)
		except Exception:
			font = ImageFont.load_default()
		what = {"A": "A: the icon in the diffuse",
				"B": "B: one bit in the roughness"}.get(opt,
				{"glowing": "the emission mask, cut to 0.04",
				"chrome": "the mark in the metalness",
				"white": "the picture in the diffuse",
				"logo": "a logo's own outline, not a sigil"}[k])
		d.rectangle((0, 0, 720, 54), fill=(0, 0, 0))
		d.text((14, 8), "%s   %s" % (what, k), fill=(255, 220, 120), font=font)
		tiles.append(im)
if tiles:
	w, h = tiles[0].size
	per = 2 if len(tiles) == 4 else 3
	rows = (len(tiles) + per - 1) // per
	sheet = Image.new("RGB", (w * per + 8 * per, h * rows + 8 * rows), (0, 0, 0))
	for i, im in enumerate(tiles):
		sheet.paste(im, ((i % per) * (w + 8), (i // per) * (h + 8)))
	sheet = sheet.resize((sheet.size[0] // 3, sheet.size[1] // 3), Image.LANCZOS)
	sheet.save("%s/sheet.png" % out)
	print("the sheet: %s/sheet.png -- a glowing orb first, then a chrome "
			"sphere and a white one" % out)
PY
