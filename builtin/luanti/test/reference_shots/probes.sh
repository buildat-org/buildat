#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# The probe table, read out of the reference shots -- what a tuning cycle
# ends with, so that "did that work" is a command rather than a memory.
# See [RENDER_MODES] and [GREEN_BIAS] in doc/plan/rendering_plan.md.
#
#   builtin/luanti/test/reference_shots/probes.sh          read what is on disk
# Every run also writes <set>/probes.png: every crop with its context and
# its box, one sheet per set, beside the pictures it was read from.
#   builtin/luanti/test/reference_shots/probes.sh --shoot  re-take all three
#                                                          module modes, then read
#
# Each mode is compared against its own reference -- shadows against
# official_shadows, unlit against official_unlit, pbr against the
# path-traced set. The crops are set.lua's, read through build.sh. **Hue is what this judges**: the ratio
# between channels on a surface, which is [GREEN_BIAS]'s subject. How much
# brighter than Luanti a mode is belongs to [TOO_BRIGHT] and is printed
# without an opinion.
set -u
here=$(cd "$(dirname "$0")/../../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
shots="${REFSHOT_SHOTS_DIR:-$here/local/reference_shots}"
built=$(mktemp -d /tmp/refshots_build.XXXXXX)
"$me/build.sh" "$built" || exit 2
. "$built/env.sh"
seed=$REFSHOT_SEED

if [ "${1:-}" = "--shoot" ]; then
	bash "$me/shoot_buildat_server.sh" unlit shadows pbr || exit 1
fi

# name | picture | crop | what it is for
PROBES=$REFSHOT_PROBES

# mode -> the set it must match, at the same range: a set's _r<RANGE>
# postfix carries over, so module_shadows_r150 is read against
# official_r150 and never against a set of another range. pbr's is the
# path-traced set, textured since 2026-09-17 ([PATH_TRACE_TEX]).
target_of() {
	local r=${1##*_r}
	case "$1" in
		*_shadows_r*) echo "official_shadows_r$r" ;;
		*_unlit_r*)   echo "official_unlit_r$r" ;;
		*_pbr_r*)     echo "pathtrace_r$r" ;;
		*)            echo "" ;;
	esac
}

# The picture a set has of a probe. The path-traced set names its renders
# without the seed -- cycles_vp6_1300_none.png beside the dump -- and is a
# reference like official ([PATH_TRACE_REF]).
file_of() {   # set pic -> path
	case "$1" in
		pathtrace*) echo "$shots/$1/cycles_$2_none.png" ;;
		*) echo "$shots/$1/${seed}_$2_none.png" ;;
	esac
}

read_probe() {   # file crop -> "r g b"
	magick "$1" -crop "$2" +repage -format '%[fx:mean.r] %[fx:mean.g] %[fx:mean.b]' info: 2>/dev/null
}

# Anything shot before the newest source file cannot be measuring it
newest_src=$(find "$here/builtin" "$here/apps" "$here/extensions" \
		-name '*.lua' -o -name '*.cpp' -o -name '*.h' -o -name '*.glsl' \
		2>/dev/null | xargs -r stat -c %Y 2>/dev/null | sort -rn | head -1)

sets=""
for d in "$shots"/*/; do sets="$sets $(basename "$d")"; done

echo "=== staleness ==="
for s in $sets; do
	newest=$(ls -t "$shots/$s" 2>/dev/null | head -1)
	[ -n "$newest" ] || continue
	t=$(stat -c %Y "$shots/$s/$newest")
	case "$s" in official*|pathtrace*) note="(reference, no need to re-take)" ;; *)
		if [ "$t" -lt "${newest_src:-0}" ]; then note="** STALE: older than the source **"
		else note="current" ; fi ;;
	esac
	printf "  %-24s %s  %s\n" "$s" "$(date -d @"$t" +%H:%M)" "$note"
done

echo "$PROBES" | while IFS='|' read -r name pic crop why; do
	[ -n "$name" ] || continue
	echo
	echo "=== $name -- $why"
	for s in $sets; do
		f=$(file_of "$s" "$pic")
		[ -f "$f" ] || continue
		rgb=$(read_probe "$f" "$crop")
		[ -n "$rgb" ] || continue
		tgt=$(target_of "$s")
		line=$(echo "$rgb" | awk -v s="$s" '{printf "  %-24s %3d,%3d,%3d  B/R %.2f  mean %.3f",
				s, $1*255, $2*255, $3*255, $3/($1+1e-9), ($1+$2+$3)/3}')
		if [ -n "$tgt" ] && [ -f "$(file_of "$tgt" "$pic")" ]; then
			t_rgb=$(read_probe "$(file_of "$tgt" "$pic")" "$crop")
			flag=$(echo "$rgb $t_rgb" | awk -v n="$name" '{
				br=$3/($1+1e-9); tbr=$6/($4+1e-9); d=br-tbr; if(d<0)d=-d;
				lim=(n=="stone")?0.03:0.05;
				m=($1+$2+$3)/3; tm=($4+$5+$6)/3; r=(tm>0.02)?m/tm:1;
				printf "  vs %s B/R %.2f  %s", "target", tbr,
						(d>lim ? (n=="stone" ? "** CONTROL MOVED **" : "** HUE OFF **") :
						(r>1.25||r<0.8) ? "** LEVEL OFF **" : "ok")}')
			line="$line$flag"
		fi
		echo "$line"
	done
done
echo
echo "Hue is the verdict; mean is for TOO_BRIGHT, and against a parity target a mean off by a quarter is LEVEL OFF: a mode that lost a term ([PARITY_LEFTOVERS])."

# [PBR_FIT]: what the fit is run against, in linear light -- the render's
# EXR, the client's 16-bit sRGB PNG undone to linear (magick's RGB
# colourspace). **One crop per probe, read absolute and per channel**: since
# [PT_EXPOSURE] both sides are metered by one rule and a crop's linear value
# is comparable on its own (the stone control 0.179 against 0.180), and the
# target is the absolute -- a ratio can be right with both ends wrong. The
# ratios below are derived from the names and printed as a reading aid.
# name | picture | crop | what it is
CROPS="
lit_dirt|vp1_1300|64x10+280+530|vp1 the dirt row in the sun
open_shade_dirt|vp1_1300|20x20+0+310|vp1 a shaded dirt face under open sky, the cliff top at the left edge
pit_dirt|vp1_1300|48x10+216+530|vp1 the shaded dirt row in the pit beside the stone block
dirt_side_lit|vp1_1300|40x12+957+690|vp1 a sunlit dirt side
dirt_side_camera|vp1_1300|40x12+666+564|vp1 a dirt side facing the camera
snow_sun|vp5_1000|60x40+420+540|vp5 the sunlit snow field
snow_shade|vp5_1000|60x30+400+660|vp5 snow in the tree's shadow
sun_step|vp7_1300|60x8+560+650|vp7 the sunlit floor step in the cave mouth
near_wall|vp7_1300|60x40+545+560|vp7 the cave wall near the mouth (moved fifteen left off the closer wall the flood cannot light, 2026-09-20)
deep_wall|vp7_1300|128x36+256+252|pbri: vp7 the deep wall, on the fold where it turns back -- the mouth's bounce, PBRI's, not held against the render ([CAVE_PROBES])
sky_mouth|vp7_1300|128x36+704+252|vp7 the sky through the mouth
lit_rim|vp7_1300|64x36+768+324|vp7 the sunlit rim of the mouth
outside_terrain|vp7_1300|64x36+512+432|vp7 the half-lit terrain seen through the mouth
grass_lit|vp1_1300|40x12+666+534|vp1 a grass top in the sun
leaves|vp1_1300|30x20+390+160|vp1 a canopy
water_sea|vp1_1300|80x40+1120+430|vp1 the sea, looking down into it
flowers|vp5_1000|10x10+646+482|vp5 a rose's petals
sky_patch|vp5_1000|60x40+20+20|vp5 a sky patch
grass_occluded|vp1_0545|33x11+271+498|vp1 05:45 a grass top under the mountain
grass_open|vp1_0545|56x40+871+562|vp1 05:45 a grass top with an open horizon
glint|vp1_0545|34x25+653+409|vp1 05:45 the sun's glint on a grass top
grass_beside|vp1_0545|40x15+600+440|vp1 05:45 the grass beside the glint
canopy_dawn|vp4_0545|40x40+160+100|vp4 05:45 a canopy with the low sun behind it: sunlight through the leaves
water_far|vp3_0545|120x15+40+355|vp3 05:45 the water near the horizon
water_near|vp3_0545|120x30+80+490|vp3 05:45 the near water
dirt_face_0545|vp1_0545|40x10+2+608|vp1 05:45 the foreground block's lit dirt face
dirt_face_1300|vp1_1300|40x10+2+608|vp1 13:00 the same face
lamp_wall|vp8_1300|59x36+326+41|vp8 the ceiling and wall above the glowstone
cave_bottom_dark|vp8_1300|120x60+560+620|vp8 the bottom of the view, which the lamp must not reach
sky_zenith_1300|vp1_1300|60x40+900+30|vp1 near the top of the sky, 13:00
sky_horizon_1300|vp1_1300|60x20+1100+225|vp1 just over the sea, away from the sun
sky_glow_0545|vp2_0545|60x40+600+30|vp2 the dawn glow, 05:45, mid-gradient toward the disc
sky_horizon_0545|vp1_0545|60x20+1100+225|vp1 the horizon opposite the dawn
sky_night_0200|vp5_0200|60x40+20+20|vp5 away from the moon, 02:00
night_snow_lit|vp5_0200|160x40+320+600|vp5 02:00 the moonlit snow field ([NIGHT_LIGHT]'s ladder crop; 77 of 255 at moon x3)
night_cave_wall|vp4_2030|50x50+811+460|vp4 20:30 the cave wall the moon does not reach
cave_lit_wall|vp4_1300|40x32+448+410|vp4 the small cave's wall at a nibble of 14 ([INTERIOR_FALLOFF], user's crop)
cave_back_wall|vp4_1300|64x32+768+448|vp4 the small cave's back wall, a handful of nodes in
cave_ao_corner|vp4_1300|16x16+438+384|vp4 a corner the mesher's AO should darken, so the shade reads sharp
bore_wall_near|vp9_1300|64x32+544+320|vp9 the bore's side wall about one voxel down
bore_wall_far|vp9_1300|64x32+576+320|vp9 much of the rest of the bore's side wall
bore_back_wall|vp9_1300|32x64+624+320|vp9 the bore's back wall, ten columns in
"
# The ratios, from the crops' names. kind: lum -- luminance over luminance;
# rgb -- per channel; sat -- max over min channel of one crop; hue -- R/B
# of the first over R/B of the second (the sun's colour with the material
# controlled for). No pass mark: two crops off by the same factor is the
# level, a metering or gate finding, not a term.
RATIOS="
contrast_dirt|lum|lit_dirt|open_shade_dirt|sun over sky-only, the open case the ambient is fitted to
contrast_dirt_pit|lum|lit_dirt|pit_dirt|a deep shadow hemmed in on three sides: occlusion and bounce
incidence_dirt|lum|dirt_side_lit|dirt_side_camera|the face-shade table and the sun's direction
contrast_snow|lum|snow_sun|snow_shade|at the top of the range
night_range|lum|night_snow_lit|night_cave_wall|moonlit snow over a dark wall: the night's range
cave_falloff|lum|cave_back_wall|cave_lit_wall|the small cave's ramp, back over lit ([INTERIOR_FALLOFF])
cave_ao|lum|cave_ao_corner|cave_lit_wall|the corner table's darkening, corner over lit wall
bore_falloff|lum|bore_back_wall|bore_wall_near|the bore's ramp, back over near
contrast_cave|lum|sun_step|deep_wall|pbri: the sun reaching into the cave (the fold is PBRI's)
cave_wall_near|lum|near_wall|deep_wall|pbri: the interior's falloff past the flood (PBRI's)
cave_opening|lum|sky_mouth|near_wall|the range across the mouth the meter spans
cave_rim|lum|lit_rim|near_wall|the sky must read above the lit rim
cave_outside|lum|outside_terrain|near_wall|the meter keys on the interior without blowing the outside
saturation_grass|sat|grass_lit||chroma
saturation_leaves|sat|leaves||chroma
saturation_water|sat|water_sea||chroma
saturation_flowers|sat|flowers||chroma
sky_to_sun|lum|sky_patch|snow_sun|the ratio the base hangs on
terrain_occlusion|rgb|grass_occluded|grass_open|sky fraction at the hills' scale
sun_glint|rgb|glint|grass_beside|the grazing specular on a rough dielectric
water_reflection|rgb|water_far|water_near|Fresnel and the reflected sky on a mirror
dawn_sun_dirt|hue|dirt_face_0545|dirt_face_1300|the low sun's colour on a lit dirt side
"

linear_rgb() {   # file crop -> "r g b" in linear light
	case "$1" in
		*.exr) magick "$1" -crop "$2" +repage \
			-format '%[fx:mean.r] %[fx:mean.g] %[fx:mean.b]' info: 2>/dev/null ;;
		*) magick "$1" -crop "$2" +repage -colorspace RGB \
			-format '%[fx:mean.r] %[fx:mean.g] %[fx:mean.b]' info: 2>/dev/null ;;
	esac
}
# The fit's ratios are read off the render's EXR where it is there: its
# metered PNG clips the sunlit snow (34 in the sky's units, exposed past
# 1), and a ratio against a clipped top is a floor. The pbr side is its
# PNG; its own clipping is what BUILDAT_VOXEL_LINEAR's frame shows.
fit_file_of() {   # set pic -> path
	local f="$shots/$1/cycles_$2_none.exr"
	case "$1" in
		pathtrace*) [ -f "$f" ] && { echo "$f"; return; } ;;
	esac
	file_of "$1" "$2"
}


# The render's EXR is radiance before the meter; its PNG is metered but
# clips at one. So the EXR is read and scaled by the meter's own rule --
# pathtrace_render.py's expose(): log-average luminance as the key,
# clamped to LUM_RANGE, MIDDLE_GREY over it -- which puts it in the pbr
# frame's units without the clip. One scale per picture, cached.
declare -A SCALE
exr_scale() {   # exr -> the meter's scale for that frame
	local f="$1"
	if [ -z "${SCALE[$f]:-}" ]; then
		SCALE[$f]=$(magick "$f" -depth 32 -define quantum:format=floating-point rgb:- 2>/dev/null |
			python3 -c '
import sys, numpy as np
a = np.frombuffer(sys.stdin.buffer.read(), dtype="<f4").reshape(-1, 3)
lum = a @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
key = float(np.exp(np.mean(np.log(lum + 1e-5))))
key = min(max(key, 0.003), 100.0)
print("%.6f" % (0.18 / key))')
	fi
	echo "${SCALE[$f]}"
}

# Every crop read once per set: VAL[set/name] = "r g b", linear, in the
# metered frame's units on both sides
declare -A VAL
for s in pathtrace_r150 module_pbr_r150; do
	while IFS='|' read -r name pic crop why; do
		[ -n "$name" ] || continue
		f=$(fit_file_of "$s" "$pic"); [ -f "$f" ] || continue
		v=$(linear_rgb "$f" "$crop")
		case "$f" in *.exr) k=$(exr_scale "$f"); v=$(awk -v k="$k" '{printf "%.5f %.5f %.5f", $1*k, $2*k, $3*k}' <<< "$v") ;; esac
		VAL["$s/$name"]=$v
	done <<< "$CROPS"
done
lum() { awk '{printf "%.4f", 0.2126*$1+0.7152*$2+0.0722*$3}' <<< "$1"; }

echo
echo "=== the crops, absolute, in the metered frame's linear units: render r/g/b | pbr r/g/b (pbr over render)"
echo "    the render off its EXR times the meter's scale, so it does not clip; pbr's PNG clips at 1.000"
while IFS='|' read -r name pic crop why; do
	[ -n "$name" ] || continue
	r=${VAL[pathtrace_r150/$name]:-}; p=${VAL[module_pbr_r150/$name]:-}
	printf "  %-18s" "$name"
	# A row tagged pbri: (see [CAVE_PROBES]) is the render's second
	# bounce past the flood's reach, [PBRI]'s: pbr's number is printed
	# and not read against the render
	pbri=0; case "$why" in pbri:*) pbri=1 ;; esac
	awk -v r="$r" -v p="$p" -v pbri="$pbri" 'BEGIN{ nr=split(r,a," "); np=split(p,b," ");
		if(nr==3) printf "%.3f/%.3f/%.3f", a[1],a[2],a[3]; else printf "(no render)";
		printf "  ";
		if(np==3) printf "%.3f/%.3f/%.3f", b[1],b[2],b[3]; else printf "(no pbr)";
		if(pbri) printf "  (pbri: not held)";
		else if(nr==3 && np==3){ printf "  ("; for(i=1;i<=3;i++) printf "%s%s", (i>1?"/":""), (a[i]>0.0005 ? sprintf("%.2f", b[i]/a[i]) : "-"); printf ")" }
		printf "  -- %s\n", ARGV[1] }' "$why"
done <<< "$CROPS"

echo
echo "=== derived ratios, render | pbr (pbr over render); a reading aid, no pass mark"
while IFS='|' read -r name kind a b why; do
	[ -n "$name" ] || continue
	printf "  %-20s" "$name"
	for s in pathtrace_r150 module_pbr_r150; do
		va=${VAL[$s/$a]:-}; vb=${VAL[$s/$b]:-}
		awk -v k="$kind" -v A="$va" -v B="$vb" 'BEGIN{ na=split(A,a," "); nb=split(B,b," ");
			if(na!=3 || (k!="sat" && nb!=3)){ printf "  (missing)"; exit }
			if(k=="lum"){ la=0.2126*a[1]+0.7152*a[2]+0.0722*a[3]; lb=0.2126*b[1]+0.7152*b[2]+0.0722*b[3]; printf "  %.3f", la/(lb+1e-9) }
			else if(k=="sat"){ mx=a[1]; mn=a[1]; for(i=2;i<=3;i++){if(a[i]>mx)mx=a[i]; if(a[i]<mn)mn=a[i]}; printf "  %.3f", mx/(mn+1e-9) }
			else if(k=="rgb"){ printf "  %.2f/%.2f/%.2f", a[1]/(b[1]+1e-9), a[2]/(b[2]+1e-9), a[3]/(b[3]+1e-9) }
			else if(k=="hue"){ printf "  %.3f", (a[1]/(a[3]+1e-9)) / (b[1]/(b[3]+1e-9)) } }'
	done | awk '{ if(NF>=2 && $1+0>0 && $2+0>0) printf "%s  (%.2f)", $0, $2/$1; else printf "%s", $0 }'
	echo "  -- $why"
done <<< "$RATIOS"

# The crop sheet, on every run: every crop cut with three times its context
# and its box drawn, one sheet per set as probes.png inside the set's own
# directory, so it is dated with the pictures it was read from and an old
# set can be re-seen with its crops (user, 2026-09-18). A crop enters a
# table only after someone has looked at its cell: typed coordinates are a
# guess until seen.
show_cell() {   # out name file crop -> a cell png
	local geom="$4"
	local w=${geom%%x*}; local rest=${geom#*x}; local h=${rest%%+*}
	rest=${rest#*+}; local x=${rest%%+*}; local y=${rest#*+}
	local cx=$((x - w)); local cy=$((y - h)); [ $cx -lt 0 ] && cx=0; [ $cy -lt 0 ] && cy=0
	magick "$3" -crop "$((w * 3))x$((h * 3))+$cx+$cy" +repage \
		-fill none -stroke red -strokewidth 1 \
		-draw "rectangle $((x - cx)),$((y - cy)) $((x - cx + w - 1)),$((y - cy + h - 1))" \
		-scale 300% -gravity north -background black -fill white -pointsize 12 \
		-splice 0x14 -annotate +0+1 "$2 $5" "$1/$2.png" 2>/dev/null
}
for s in pathtrace_r150 module_pbr_r150; do
	[ -d "$shots/$s" ] || continue
	cells=$(mktemp -d)
	# One cell per crop, its label carrying this set's reading after its
	# name, so the picture and the number are read together
	n=0
	while IFS='|' read -r name pic crop why; do
		[ -n "$name" ] || continue
		f=$(file_of "$s" "$pic"); [ -f "$f" ] || continue
		n=$((n + 1))
		label=$(awk '{printf "%.3f %.3f %.3f", $1, $2, $3}' <<< "${VAL[$s/$name]:-}")
		show_cell "$cells" "$(printf '%02d_%s' $n "$name")" "$f" "$crop" "$label"
	done <<< "$CROPS"
	magick montage "$cells"/*.png -tile 4x -geometry +4+4 -background gray20 \
		"$shots/$s/probes.png" 2>/dev/null && echo "crop sheet: $shots/$s/probes.png"
	rm -rf "$cells"
done

