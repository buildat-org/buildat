#!/bin/bash
# [GLOW_MARK]: the glowing orb's mark across the usable band, both
# figures, at two distances, into local/options_for_LAUNCH_WORLD_glow/.
#
#   extensions/launch_world/glow_sheet.sh
#
# **A grid, not two rows**: an outline is thinner *and* the lightness
# lifts it, so an outlined mark at the light end may be nothing at all;
# only a grid says where the two meet.
#
#   across  the emissive fraction that survives under the mark --
#           0, 0.01, 0.02, 0.03, 0.04. The emissive is multiplied by 26,
#           so a masked pixel only comes out of saturation below about
#           0.04 and nothing above the band does anything.
#   down    the figure (the mask, then its outline) at the portrait
#           distance, then the same two at the room's own hop -- a mark
#           exists to be read across the room, and this round's own
#           earlier mistake was judging tiles at sheet size.
#
# Only the glowing orb is shot: chrome and white are settled and their
# mark does not go through this cut.
#
# No tier line: this makes a picture for a person to choose from, and
# decides nothing itself.
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/options_for_LAUNCH_WORLD_glow"; mkdir -p "$out"
cd "$here/Build"
if check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat client is already running" >&2; exit 2
fi
mkdir -p "$out/emptyuser"
CUTS=${CUTS:-"0 0.01 0.02 0.03 0.04"}
FIGS=${FIGS:-"mask outline"}
HOPS=${HOPS:-"2.0 4.5"}
shot() {   # $1 cut, $2 figure, $3 hop
	tag="$1-$2-$3"
	{ echo "delay 5000"
		echo "event mode menu"
		echo "delay 700"
		# The camera is flown by the room's own search: typing a name in
		# menu mode flies to that thing and stops in front of it, which
		# is deterministic and the way a player meets an orb.
		for c in D I G G E R; do echo "keypress $c"; done
		echo "delay 2600"
		echo "screenshot $out/$tag.png"
		echo "delay 400"
		echo "quit"; } > "$out/cmds_$tag.txt"
	env BUILDAT_LAUNCH_GLOW_CUT="$1" \
		${2:+BUILDAT_LAUNCH_MARK_FIGURE=$2} \
		BUILDAT_LAUNCH_HOP="$3" \
		timeout 180 bin/buildat -m launch_world -D "$out/emptyuser" \
		-w 1280x720 -l 3 -c @"$out/cmds_$tag.txt" > "$out/cli_$tag.log" 2>&1
}
for hop in $HOPS; do
	for fig in $FIGS; do
		for cut in $CUTS; do
			shot "$cut" "$fig" "$hop"
			echo "shot cut $cut, $fig, hop $hop: $(grep -c 'mark: ' \
					"$out/cli_$cut-$fig-$hop.log") marks"
		done
	done
done
CUTS="$CUTS" FIGS="$FIGS" HOPS="$HOPS" python3 - "$out" <<'PY'
import sys, os
from PIL import Image, ImageDraw, ImageFont
out = sys.argv[1]
cuts = os.environ["CUTS"].split()
figs = os.environ["FIGS"].split()
hops = os.environ["HOPS"].split()
try:
	font = ImageFont.truetype(
			"/usr/share/fonts/liberation-mono/LiberationMono-Bold.ttf", 22)
except Exception:
	font = ImageFont.load_default()
# **The orb, not the room**: the camera stops square on to the sphere,
# so the middle of the frame is the mark and the rest is wall. A grid of
# whole frames is unreadable at any size a sheet can be looked at.
CROP, CELL = 560, 300
rows = []
# **The arithmetic beside the picture**: how much of the orb is dark and
# how light those pixels are. A knob nobody can see is a knob that does
# nothing, and the eye cannot tell 0.01 from 0.02 on a sheet.
print("%-6s %-8s %-4s %6s %8s" % ("cut", "fig", "hop", "dark%", "meanlum"))
for hop in hops:
	for fig in figs:
		cells = []
		for cut in cuts:
			p = "%s/%s-%s-%s.png" % (out, cut, fig, hop)
			if not os.path.exists(p):
				print("missing: %s" % p)
				continue
			im = Image.open(p).convert("RGB")
			w, h = im.size
			# The disc alone, at whichever distance it was shot from
			s = 160 if hop == "2.0" else 70
			disc = im.crop(((w - s) // 2, (h - s) // 2,
					(w + s) // 2, (h + s) // 2))
			lum = [0.299 * r + 0.587 * g + 0.114 * b
					for r, g, b in disc.getdata()]
			dark = [v for v in lum if v < 200]
			print("%-6s %-8s %-4s %6.1f %8.1f" % (cut, fig, hop,
					100.0 * len(dark) / len(lum),
					sum(dark) / len(dark) if dark else -1))
			im = im.crop(((w - CROP) // 2, (h - CROP) // 2,
					(w + CROP) // 2, (h + CROP) // 2))
			im = im.resize((CELL, CELL), Image.LANCZOS)
			d = ImageDraw.Draw(im)
			d.rectangle((0, 0, CELL, 30), fill=(0, 0, 0))
			d.text((8, 5), "cut %s  %s  hop %s" % (cut, fig, hop),
					fill=(255, 220, 120), font=font)
			cells.append(im)
		if cells:
			rows.append(cells)
if rows:
	per = max(len(r) for r in rows)
	sheet = Image.new("RGB", (per * (CELL + 6), len(rows) * (CELL + 6)),
			(0, 0, 0))
	for y, r in enumerate(rows):
		for x, im in enumerate(r):
			sheet.paste(im, (x * (CELL + 6), y * (CELL + 6)))
	sheet.save("%s/sheet.png" % out)
	print("the sheet: %s/sheet.png -- the lightness across, the figure "
			"and the distance down" % out)
PY
