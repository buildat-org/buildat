#!/bin/bash
# [LAUNCH_WORLD]'s floor, an options round: the same standing frame with
# the floor's light squares at four values and two finishes, into
# local/options_for_LAUNCH_WORLD_floor/.
#
#   extensions/launch_world/floor_sheet.sh
#
# **Why the floor and not the lighting** (2026-09-24): reading the look
# against the reference frame at the new standing place, the median sits
# under the reference's and the 90th and the white share sit over it,
# and both are the floor -- its light squares are the brightest surface
# in the room and they clip near the camera. The sources are where they
# should be.
#
# The knobs are BUILDAT_LAUNCH_FLOOR_VALUE (the light square's value)
# and BUILDAT_LAUNCH_FLOOR_GLOSS (its roughness; lower is glossier), so
# trying one is a flag rather than an edit.
#
# Taken on an empty user path, since a sphere the player parked in front
# of the camera is worth several points of every number here.
#
# No tier line: this makes a picture for a person to choose from, and
# decides nothing itself.
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/options_for_LAUNCH_WORLD_floor"; mkdir -p "$out"
rm -f "$out"/*.png
mkdir -p "$out/emptyuser"
cd "$here/Build"
if check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat client is already running" >&2; exit 2
fi
# **Wait for the probe** (user, 2026-09-24): it renders its ninety
# frames after the room comes up, and a sheet shot before it has settled
# shows differences that are not the knob's.
{ echo "delay 9000"; echo "screenshot $out/RUN.png"; echo "delay 500"
	echo "quit"; } > "$out/cmds.txt"
# **The room as the reference frame has it** (user, 2026-09-24): no
# launch actions, no saves, no servers and no save read, so the wall is
# lit by the light from above and the orbs in their pockets rather than
# by a game somebody left standing on the floor.
#
# **And the probe that lets the finish matter**: with one mip level a
# rough surface reflects as sharply as a mirror, so the gloss knob moved
# the picture six tenths of a level and the round could not be judged
# (user, 2026-09-24). An eight-bit cube takes a mip chain -- the float16
# one blacks every primitive that reflects it, its own shader having no
# guard against what the levels hold -- so the finish is shot on that
# one. What it costs is the top of a source inside a reflection, which
# is [PBR_HDR]'s own trade and is the user's to make.
probe="BUILDAT_LAUNCH_PROBE8=1 BUILDAT_LAUNCH_PROBEMIPS=1"
# **The two axes want two rooms** (user, 2026-09-24), so this is two
# sheets rather than a grid:
#
# - **The value axis** is about how bright the floor is against the
#   wall, and a game standing on the floor lights that wall from below
#   -- so it is shot **bare**, in the composition the reference frame
#   has, at one finish.
# - **The gloss axis** is about how crisply the floor returns *the
#   things standing on it*, and bare removes them all: what made
#   old1/refl.png read as a mirror at a glance was the torus and the
#   chrome spheres in it. So the finish is shot in the **populated**
#   room, at one value.
VALUE_AT="${VALUE_AT:-0.60}"
GLOSS_AT="${GLOSS_AT:-0.07}"
for v in 1.00 0.80 0.60 0.45; do
	name="value_$v"
	sed "s#RUN#$name#" "$out/cmds.txt" > "$out/cmds_$name.txt"
	env $probe BUILDAT_LAUNCH_BARE=1 BUILDAT_LAUNCH_FLOOR_VALUE=$v \
		BUILDAT_LAUNCH_FLOOR_GLOSS=$GLOSS_AT \
		bin/buildat -m launch_world -D "$out/emptyuser" \
		-w 1280x720 -l 3 -c @"$out/cmds_$name.txt" > /dev/null 2>&1
done
# **The second axis: how much the floor reflects at all** (user,
# 2026-09-24). A dielectric returns about four per cent straight on
# whatever its roughness -- what mirrors a wet road is Fresnel at a
# grazing angle -- so what is missing underfoot is reflectance rather
# than smoothness. This is a multiplier on the specular colour, 1 being
# the eight per cent the shader assumes; above 1 it is no longer a
# physical dielectric, which is why it is a pick.
for sp in 1 2 4 8; do
	name="spec_$sp"
	sed "s#RUN#$name#" "$out/cmds.txt" > "$out/cmds_$name.txt"
	env $probe BUILDAT_LAUNCH_FLOOR_VALUE=$VALUE_AT \
		BUILDAT_LAUNCH_FLOOR_GLOSS=0.04 BUILDAT_LAUNCH_FLOOR_SPEC=$sp \
		bin/buildat -m launch_world -D "$out/emptyuser" \
		-w 1280x720 -l 3 -c @"$out/cmds_$name.txt" > /dev/null 2>&1
done
for g in 0.02 0.04 0.10 0.25; do
	name="gloss_$g"
	sed "s#RUN#$name#" "$out/cmds.txt" > "$out/cmds_$name.txt"
	env $probe BUILDAT_LAUNCH_FLOOR_VALUE=$VALUE_AT \
		BUILDAT_LAUNCH_FLOOR_GLOSS=$g \
		bin/buildat -m launch_world -D "$out/emptyuser" \
		-w 1280x720 -l 3 -c @"$out/cmds_$name.txt" > /dev/null 2>&1
done
python3 - "$out" "$here/local/launch_world_reference/images/fps-stood.png" \
		"$VALUE_AT" "$GLOSS_AT" <<'PY'
import sys, os
from PIL import Image, ImageDraw, ImageFont

out, ref, value_at, gloss_at = sys.argv[1:5]
HUD = 70

def read(path):
	im = Image.open(path).convert("L")
	w, h = im.size
	d = sorted(im.crop((0, 0, w, h - HUD)).getdata())
	n = len(d)
	return (sum(d) / float(n), d[n // 2], d[int(n * 0.90)],
			100.0 * sum(1 for v in d if v >= 254) / n)

def a_font():
	try:
		return ImageFont.truetype(
				"/usr/share/fonts/liberation-mono/LiberationMono-Bold.ttf", 34)
	except Exception:
		return ImageFont.load_default()

def sheet(rows, name, title):
	tiles = []
	print("%-32s %6s %6s %6s %7s" % (title, "mean", "med", "90th", "white%"))
	for label, p in rows:
		if not os.path.exists(p):
			continue
		print("%-32s %6.1f %6d %6d %7.2f" % (label, read(p)[0], read(p)[1],
				read(p)[2], read(p)[3]))
		im = Image.open(p).convert("RGB")
		d = ImageDraw.Draw(im)
		d.rectangle((0, 0, 660, 54), fill=(0, 0, 0))
		d.text((14, 8), label, fill=(255, 220, 120), font=a_font())
		tiles.append(im)
	if os.path.exists(ref):
		r = read(ref)
		print("%-32s %6.1f %6d %6d %7.2f" % ("(the reference frame)", r[0],
				r[1], r[2], r[3]))
	if not tiles:
		return
	w, h = tiles[0].size
	cols = 2
	sh = Image.new("RGB", (w * cols + 8, ((len(tiles) + 1) // cols) * (h + 8)),
			(0, 0, 0))
	for i, im in enumerate(tiles):
		sh.paste(im, ((i % cols) * (w + 8), (i // cols) * (h + 8)))
	sh = sh.resize((sh.size[0] // 3, sh.size[1] // 3), Image.LANCZOS)
	sh.save("%s/%s" % (out, name))
	print("    -> %s/%s" % (out, name))
	print("")

sheet([("value %s   (gloss %s, bare)" % (v, gloss_at),
		"%s/value_%s.png" % (out, v)) for v in ("1.00", "0.80", "0.60", "0.45")],
		"sheet_value.png", "the value, in the reference's own room")
sheet([("gloss %s   (value %s, populated)" % (g, value_at),
		"%s/gloss_%s.png" % (out, g)) for g in ("0.02", "0.04", "0.10", "0.25")],
		"sheet_gloss.png", "the finish, with the room's things on it")
sheet([("reflectance x%s   (value %s, gloss 0.04)" % (sp, value_at),
		"%s/spec_%s.png" % (out, sp)) for sp in ("1", "2", "4", "8")],
		"sheet_spec.png", "how much the floor returns at all")
PY
