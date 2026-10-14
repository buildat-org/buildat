#!/bin/bash
# extensions/launch_world: a sheet of the room at a range of exposures,
# with a probe box of known albedos standing in it -- 90, 50, 18 and 4
# per cent grey and the orb's own orange. What it is for is settling the
# exposure by looking rather than by argument: every panel is the same
# room after the tonemap, and what differs is the cold light from above
# and the tonemap's own bias.
#
# Each panel says its two numbers, and the reading under it is what the
# floor's white tiles came to -- the one thing that must stay short of
# saturation.
#
#   extensions/launch_world/probe_sheet.sh
#
# Not a check: it makes a picture for a person, and says nothing about
# pass or fail. That is why it carries no tier line.
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/options_for_LAUNCH_WORLD/probe"
mkdir -p "$out"; rm -f "$out"/*.png
cd "$here/Build"
if check_pgrep buildat >/dev/null; then
	echo "a buildat client is already running" >&2; exit 2
fi
rm -f "$BUILDAT_USER_PATH/launch_world/room.txt"
# **The two that decide the top end.** The light from above is what the
# floor's white tiles read, and the tonemap's white point is where the
# curve reaches 255 -- and it was the white point, not the lighting,
# that held the room's floor at 165 however much light was thrown at it.
skies="${SKIES:-1.0 1.6 2.4}"
whites="${WHITES:-0.95 1.15 1.45}"
for sky in $skies; do
	for white in $whites; do
		name="sky${sky}_white${white}"
		{ echo "delay 5000"; echo "event room still"; echo "delay 400"
			echo "screenshot $out/$name.png"; echo "delay 400"
			echo "quit"; } > "$out/cmds.txt"
		BUILDAT_LAUNCH_PROBEBOX=1 BUILDAT_LAUNCH_SKY="$sky" \
			BUILDAT_LAUNCH_WHITE="$white" \
			timeout 120 bin/buildat -m launch_world -w 960x540 \
			-l 3 -c @"$out/cmds.txt" >/dev/null 2>&1
		[ -f "$out/$name.png" ] && echo "shot $name" || echo "missing $name"
	done
done
cd "$here"
python3 - "$out" "$here/local/launch_world_reference/images" <<'PY'
import sys, os, re
from PIL import Image, ImageDraw
out, refdir = sys.argv[1], sys.argv[2]
shots = sorted(f for f in os.listdir(out) if f.endswith(".png"))
if not shots:
	print("FAIL: no shots"); sys.exit(1)

def floor_reading(im):
	# The floor's light squares: near-neutral pixels low in the frame
	w, h = im.size
	px = [im.getpixel((x, y)) for y in range(int(h * 0.62), h, 2)
			for x in range(0, w, 3)]
	px = [p for p in px if max(p) - min(p) < 26]
	if not px:
		return (0, 0, 0), 0.0
	px.sort(key=sum)
	clipped = sum(1 for p in px if min(p) >= 250) / float(len(px))
	return px[int(len(px) * 0.97)], clipped

# The reference's own reading, for the same measure on the same scale
ref = None
for f in sorted(os.listdir(refdir)):
	if f.endswith((".jpg", ".png")):
		ref = Image.open(os.path.join(refdir, f)).convert("RGB"); break

cols = 3
tw = 480
rows = (len(shots) + cols - 1) // cols
th = int(tw * 0.5625)
pad = 22
sheet = Image.new("RGB", (cols * tw, rows * (th + pad)), (12, 12, 14))
draw = ImageDraw.Draw(sheet)
print("%-22s %-18s %s" % ("panel", "floor 97th", "clipped"))
if ref is not None:
	p, c = floor_reading(ref)
	print("%-22s %-18s %.1f%%" % ("(the reference)", "%d %d %d" % p, c * 100))
for i, f in enumerate(shots):
	im = Image.open(os.path.join(out, f)).convert("RGB")
	p, c = floor_reading(im)
	print("%-22s %-18s %.1f%%" % (f[:-4], "%d %d %d" % p, c * 100))
	x = (i % cols) * tw
	y = (i // cols) * (th + pad)
	sheet.paste(im.resize((tw, th)), (x, y))
	m = re.match(r"sky([\d.]+)_white([\d.]+)", f)
	label = ("sky %s, white %s -- floor %d %d %d, %.1f%% clipped"
			% (m.group(1), m.group(2), p[0], p[1], p[2], c * 100)) if m else f
	draw.text((x + 6, y + th + 5), label, fill=(190, 190, 200))
sheet.save(os.path.join(out, "..", "probe_sheet.png"))
print("the sheet: %s" % os.path.join(out, "..", "probe_sheet.png"))
PY
