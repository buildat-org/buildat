#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-06)
# covers: builtin/kit/kit.cpp builtin/kit/types/environment.lua builtin/kit/client_lua/module.lua builtin/kit/client_lua/environment.lua builtin/kit/client_lua/controls.lua builtin/kit/client_data/KitVoxel* extensions/cartoon_sky/** extensions/sky_render/** extensions/physical_sky/** apps/workbench/**
# [KIT_LIGHTING] (kit_plan 4o) kit/environment's lighting, sky and weather
# on Workbench. A fresh save, the admin Ended, a flat grassland World (no
# trees); the shots from the editor's 3D camera at (20, 4, 20) toward
# (48, 2, 48), each frame cut into 16 x 10 cells and their mean colours
# compared:
#   1. Cartoon is today's look: with no environment the whole frame, and
#      with one at noon (cartoon, sky light off) the ground's cells (its
#      sky is new), against util/kit_lighting_ref.txt -- the same frames
#      of Workbench before [KIT_LIGHTING] (REF=1 takes them again; run it
#      on a build of the commit before). Within the noise floor: 3 of
#      255 a cell (the editor camera's frame is exact; a host's
#      rasteriser is what differs).
#   2. The sky: the sun, the moon and the stars by the hour (noon, dusk,
#      night) and off by their switches; the clouds by their cover and,
#      at a wind, moving between two frames (none: still).
#   3. physical: the frame differs from cartoon's and is metered (noon's
#      ground neither black nor white; the night's lifted off black).
#   4. The World's sky light on: a closed room dug under the ground is
#      dark in both modes, lit as the open air with it off.
#   5. The weather a modifier: each weather's floors over the builder's
#      cover (an overcast clear day stays overcast under rain, and after
#      it), intensity scaling the drops and the floors, a change fading
#      over weather_fade, set_weather apart from set_clouds.
#   6. [KIT_CLOUDS_DIM_SUN] the cover dims the sun, both lightings: none
#      through at full cover, all at 0.2 and under.
#   7. [KIT_PHYS_SHADOWS] a plate (kit/part) over the ground: its shadow
#      under physical, none under cartoon nor under physical's full cover.
#   8. [KIT_FORCE_CARTOON] a second client with the preference lighting
#      cartoon draws the composition's physical as cartoon. The first runs
#      with lighting game (software GL's default is cartoon).
#  10. [KIT_FAST_PHYSICAL] the environment's default fast_physical: no
#      plate's shadow, its noon metered and its sky physical's.
# The shots are kept with KEEP_TMP=1; look at them.
#   util/kit_lighting_check.sh
#   REF=1 util/kit_lighting_check.sh   writes util/kit_lighting_ref.txt
set -u
. "$(dirname "$0")/check_lib.sh"
check_user
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_lighting; t=$CHECK_TMP
cd "$here/Build"
REF_FILE=$here/util/kit_lighting_ref.txt

server()
{
	start_server "$t/srv.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
		--sim-rate "$CHECK_RATE" ||
		fail "the server did not come up ($t/srv.log)"
	CHECK_PIDS+=($SERVER_PID)
}
client() # <name>: its commands in $t/<name>.cmds
{
	sed -i "s|@T@|$t|g" "$t/$1.cmds"
	run_client 60 "$t/$1.log" timeout 420 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-o "lighting=${LIGHTING:-game}" -c @"$t/$1.cmds" ||
		fail "client $1 failed ($t/$1.log, $t/srv.log)"
}
want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss
n=0
ed() { printf 'event kit_edit %s\n' "$1"; }
edit() # <json>: the undo's 50 at most (kit.cpp's UNDO_MAX)
{
	n=$((n + 1))
	ed "$1"
	printf 'wait_log 10000 entities, %d to undo\n' "$((n > 50 ? 50 : n))"
}
ep() # <param> <json value>
{
	edit "{\"op\": \"set\", \"id\": 4, \"comp\": 0, \"param\": \"$1\", \"value\": $2}"
}
# An edit and the line it brings, tens of ms behind its "to undo": waited
# for instead of that, from before the edit is sent, as a wait started
# after the "to undo" line can start after this one too (a slow frame) and
# then never sees it ([KIT_LIGHTING_CHECK_RACE])
edit_line() # <json> <ms> <the line>
{
	n=$((n + 1))
	ed "$1"
	printf 'wait_log %d %s\n' "$2" "$3"
}
ep_line() # <param> <json value> <the line>
{
	edit_line "{\"op\": \"set\", \"id\": 4, \"comp\": 0, \"param\": \"$1\", \"value\": $2}" 10000 "$3"
}
try() # <input> <json value>
{
	ed "{\"op\": \"try\", \"id\": 4, \"comp\": 0, \"input\": \"$1\", \"value\": $2}"
	echo "sync 5000"
}
# A shot from the editor's 3D camera: settled, the frame the sky's line;
# the meter each frame's own ([KIT_LIGHTING_FAST_SKY_FLAKE]: at its 0.6 a
# second, how far it came back from an overcast was the host's frame rate)
shot() # <name> [camera: x y z x y z]
{
	cat <<EOF
event kit_cam3d ${2:-20 4 20 48 2 48}
event kit_meter 1000000
frames 10
delay ${SETTLE:-4000}
frames 3
screenshot @T@/$1.png
event kit_meter
event kit_ui_where $1
EOF
}
sky() # <text>: in the client's sky line ("kit: sky: <mode>, <hour>, ...")
{
	printf 'wait_log_any 10000 %s\n' "$1"
}
skyn() # <text>: in the next sky line (one a fade settles)
{
	printf 'wait_log 10000 %s\n' "$1"
}
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
	# 3: the World, flat, no trees
	edit '{"op": "place", "type": "kit/terrain", "pos": [0, 1, 0]}'
	edit '{"op": "set", "id": 3, "comp": 0, "param": "biome", "value": "grassland"}'
	echo "wait_log_any 30000 kit: World: generated again"
	edit_line '{"op": "set", "id": 3, "comp": 0, "param": "decorations", "value": false}' 30000 "kit: World: generated again"
	echo "idle 30000"
	shot plain
	# 4: the environment, on the root
	edit '{"op": "place", "type": "kit/environment", "pos": [0, 1, 0]}'
	echo "wait_log_any 10000 kit: environment: from the root, 4,"
	# The noon sun its references were taken under (the default 15
	# o'clock and north 0 since [KIT_ENV_DEFAULTS])
	ep time 12
	ep north 30
	# [KIT_FAST_PHYSICAL] its default fast_physical; cartoon set, the
	# reference's look
	echo "wait_log_any 10000 kit: lighting fast_physical (HDR, metered; no shadow map, no bloom)"
	ep_line lighting '"cartoon"' "kit: lighting cartoon"
	# Under a cover of 0.2 the sun all through, as the reference's frame
	# ([KIT_CLOUDS_TOO_BRIGHT]: the default 0.4 lets 0.80 of it through)
	ep cloud_cover 0.2
	shot env_noon
	if [ -n "${REF:-}" ]; then
		echo quit
	else
		ep cloud_cover 0.4
		# 2. The sky by the hour and its switches (cartoon), at once
		ep weather_fade 0
		sky "cartoon, 12.0 o'clock, sun 1, moon 0, stars 0.00, clouds 0.40"
		ep time 17.5
		sky "cartoon, 17.5 o'clock, sun 1"
		shot cartoon_dusk
		ep time 0
		sky "cartoon, 0.0 o'clock, sun 0, moon 1, stars 1.00"
		shot cartoon_night
		ep stars false
		sky "cartoon, 0.0 o'clock, sun 0, moon 1, stars 0.00"
		ep moon false
		sky "cartoon, 0.0 o'clock, sun 0, moon 0, stars 0.00"
		ep stars true
		ep moon true
		ep time 12
		ep sun false
		sky "cartoon, 12.0 o'clock, sun 0, moon 0"
		ep sun true
		# The clouds: none, a cover, still and at a wind
		ep cloud_wind_speed 0
		sky "clouds 0.40 at 120, wind 0.0"
		ep cloud_cover 0
		sky "cartoon, 12.0 o'clock, sun 1, moon 0, stars 0.00, clouds 0.00 at 120, wind 0.0"
		shot clouds_none
		ep cloud_cover 0.8
		sky "cartoon, 12.0 o'clock, sun 1, moon 0, stars 0.00, clouds 0.80 at 120, wind 0.0"
		shot clouds_still
		shot clouds_still2
		sky "light 1.00, fog 1.00, sun through 0.06, shadows 0"
		ep cloud_wind_speed 30
		sky "clouds 0.80 at 120, wind 30.0 toward 180"
		shot clouds_wind
		shot clouds_wind2
		ep cloud_wind_speed 0
		ep cloud_cover 1
		sky "clouds 1.00 at 120, wind 0.0 toward 180; clear 1.00: light 1.00, fog 1.00, sun through 0.00, shadows 0"
		ep cloud_cover 0.1
		sky "cartoon, 12.0 o'clock, sun 1, moon 0, stars 0.00, clouds 0.10 at 120, wind 0.0"
		# 7. A plate over the ground behind the default camera (5), its
		# noon shadow 2 cells toward +z: the camera looks down at it
		edit '{"op": "place", "type": "kit/part", "pos": [10, 6, 5]}'
		edit '{"op": "set", "id": 5, "comp": 0, "param": "size", "value": [4, 0.5, 4]}'
		PLATE="10 8 16 10 0.5 7.1"
		shot cartoon_plate "$PLATE"
		# 3. physical at noon, dusk and night
		ep_line lighting '"physical"' "kit: lighting physical"
		sky "physical, 12.0 o'clock, sun 1"
		sky "sun through 1.00, shadows 1"
		shot phys_plate "$PLATE"
		ep cloud_cover 1
		sky "physical, 12.0 o'clock, sun 1, moon 0, stars 0.00, clouds 1.00 at 120, wind 0.0 toward 180; clear 1.00: light 1.00, fog 1.00, sun through 0.00, shadows 0"
		shot phys_plate_overcast "$PLATE"
		ep cloud_cover 0.1
		sky "physical, 12.0 o'clock, sun 1, moon 0, stars 0.00, clouds 0.10"
		shot phys_noon
		# [KIT_FAST_PHYSICAL] fast_physical: physical's frame, no shadow
		ep_line lighting '"fast_physical"' "kit: lighting fast_physical"
		sky "fast_physical, 12.0 o'clock, sun 1, moon 0, stars 0.00, clouds 0.10 at 120, wind 0.0 toward 180; clear 1.00: light 1.00, fog 1.00, sun through 1.00, shadows 0"
		shot fast_plate "$PLATE"
		shot fast_noon
		ep_line lighting '"physical"' "kit: lighting physical"
		ep time 17.5
		sky "physical, 17.5 o'clock"
		shot phys_dusk
		ep time 0
		sky "physical, 0.0 o'clock"
		shot phys_night
		ep time 12
		# 4. The sky light: a 2x2x2 room under the ground, closed
		for y in -5 -4; do for z in 6 7; do for x in 6 7; do
			edit "{\"op\": \"set_voxel\", \"pos\": [$x, $y, $z], \"voxel\": \"air\"}"
		done; done; done
		CAVE="6.6 -4.4 6.6 7.4 -4.7 7.4"
		shot phys_cave_off "$CAVE"
		ep_line lighting '"cartoon"' "kit: lighting cartoon"
		shot cartoon_cave_off "$CAVE"
		edit '{"op": "set", "id": 3, "comp": 0, "param": "sky_light", "value": true}'
		echo "wait_log_any 10000 kit: sky light on"
		echo "wait_log_any 60000 kit: sky light: the loaded world relit"
		echo "idle 30000"
		shot cartoon_cave "$CAVE"
		ep_line lighting '"physical"' "kit: lighting physical"
		shot phys_cave "$CAVE"
		# A builder's voxel type that gives light, in the room's corner:
		# physical draws it, cartoon has no light levels
		ed '{"op": "voxel", "name": "lamp", "texture": "kit/sand.png", "light": 14}'
		echo "sync 5000"
		edit '{"op": "set_voxel", "pos": [6, -5, 7], "voxel": "kitboss/lamp"}'
		echo "wait_log_any 10000 kit: lamps: 1 lit about the camera"
		shot phys_cave_lamp "$CAVE"
		ep_line lighting '"cartoon"' "kit: lighting cartoon"
		shot cartoon_cave_lamp "$CAVE"
		# 5. The weather over a builder's cover of 0.9 (an overcast clear
		# day), each change faded over a second (the lines are the settled
		# values)
		ep weather_fade 1
		ep cloud_cover 0.9
		skyn "clouds 0.90 at 120, wind 0.0 toward 180; clear 1.00: light 1.00"
		shot overcast
		ep weather '"rain"'
		skyn "clouds 0.90 at 120, wind 0.0 toward 180; rain 1.00: light 0.80, fog 1.00"
		echo "wait_log_any 10000 kit: weather drawn: rain, 400 drops"
		shot rain
		ep intensity 0.5
		skyn "; rain 0.50: light 0.90, fog 1.00"
		echo "wait_log_any 10000 kit: weather drawn: rain, 200 drops"
		ep cloud_cover 0
		skyn "clouds 0.40 at 120, wind 0.0 toward 180; rain 0.50: light 0.90, fog 1.00"
		ep intensity 1
		skyn "clouds 0.80 at 120, wind 0.0 toward 180; rain 1.00: light 0.80, fog 1.00"
		# rain's values: no fade, the line at once (before the "to undo")
		ep_line weather '"snow"' "clouds 0.80 at 120, wind 0.0 toward 180; snow 1.00: light 0.80, fog 1.00"
		shot snow
		ep weather '"storm"'
		skyn "clouds 0.95 at 120, wind 10.0 toward 180; storm 1.00: light 0.55, fog 0.50"
		shot storm
		ep weather '"cloudy"'
		skyn "clouds 0.70 at 120, wind 0.0 toward 180; cloudy 1.00: light 0.90, fog 1.00"
		shot cloudy
		ep weather '"clear"'
		skyn "clouds 0.00 at 120, wind 0.0 toward 180; clear 1.00: light 1.00, fog 1.00"
		shot clear
		# A change fades: a storm rolling in over 3 s, and out
		ep weather_fade 3
		ep weather '"storm"'
		echo "wait_log_any 10000 kit: weather: fading to storm over 3.0 s"
		echo "wait_log 10000 kit: weather: half way"
		skyn "clouds 0.95 at 120, wind 10.0 toward 180; storm 1.00: light 0.55"
		ep weather '"clear"'
		skyn "clouds 0.00 at 120, wind 0.0 toward 180; clear 1.00"
		ep weather_fade 1
		# 8. Left physical for the second client
		ep_line lighting '"physical"' "kit: lighting physical"
		# 9. Physical's water over the flat ground (the sea up to 2), and
		# the ground as voxels and as a heightmap (the same grass), the
		# sky light off (the heightmap has none)
		w() { edit "{\"op\": \"set\", \"id\": 3, \"comp\": 0, \"param\": \"$1\", \"value\": $2}"; }
		w_line() { edit_line "{\"op\": \"set\", \"id\": 3, \"comp\": 0, \"param\": \"$1\", \"value\": $2}" "$3" "$4"; }
		w_line sky_light false 10000 "kit: sky light off"
		LOW="20 6 20 32 0 32"
		w_line sea_level 2 30000 "kit: World: generated again"
		echo "idle 30000"
		shot phys_water "$LOW"
		w_line sea_level 0 30000 "kit: World: generated again"
		echo "idle 30000"
		shot phys_ground_voxels "$LOW"
		# [KIT_RELIEF_TINT] a grass voxel's sides under physical, behind
		# the camera (out of the heightmap's frame)
		edit '{"op": "set_voxel", "pos": [14, 1, 14], "voxel": "kit/grass"}'
		echo "idle 30000"
		shot phys_grass_side "11.5 2.2 11.5 14.5 1.4 14.5"
		w surface '"heightmap"'
		echo "wait_log_any 60000 heightmap: terrain built"
		echo "idle 30000"
		shot phys_ground_heightmap "$LOW"
		# The signals in play: set_clouds the base, set_weather the
		# modifier, each apart (the gloom outlasts the rain)
		echo 'event kit_edit {"op": "play"}'
		echo 'wait_log 10000 kit editor: the server is Running (by kitboss)'
		try set_clouds 0.9
		skyn "clouds 0.90 at 120, wind 0.0 toward 180; clear 1.00"
		try set_weather '"rain"'
		skyn "clouds 0.90 at 120, wind 0.0 toward 180; rain 1.00: light 0.80"
		try set_weather '"clear"'
		skyn "clouds 0.90 at 120, wind 0.0 toward 180; clear 1.00: light 1.00"
		try set_intensity 0.25
		sky "; clear 0.25"
		try set_weather '"storm"'
		skyn "clouds 0.90 at 120, wind 2.5 toward 180; storm 0.25: light 0.89, fog 0.88"
		echo "wait_log_any 10000 kit: weather drawn: storm, 175 drops"
		# The drops as a player sees them (they fall about the app's
		# camera): out of edit mode, a look up the rain
		printf 'keypress F6\nwait_log_any 10000 kit editor: edit mode off\ndelay 3000\nscreenshot @T@/play_storm.png\n'
		echo quit
	fi
} > "$t/boss.cmds"
server
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss
if [ -z "${REF:-}" ]; then
	# 8. The composition physical, this client's preference cartoon
	cat > "$t/force.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 kit: lighting physical drawn as cartoon (the client's preference)
wait_log_any 30000 kit: sky: cartoon
delay 3000
screenshot @T@/force_cartoon.png
quit
EOF
	LIGHTING=cartoon client force
fi
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
c=$t/boss.log

# A shot's 16 x 10 cells' mean colours, one cell a line "r g b"
cells() # <png>
{
	python3 -I - "$1" <<'EOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB").resize((16, 10), Image.BOX)
for y in range(10):
	for x in range(16):
		print("%d %d %d" % im.getpixel((x, y)))
EOF
}
# The largest difference of two cell lists, over the rows from..to (0..9),
# the cells under the editor's UI left out: the reference's (the bar's
# row 0, columns 0-5 but row 7) and the windows where the shot's client
# logged them (kit_ui_where: the left panel's size follows its tabs and
# its components, [KIT_TABS_TWO_ROWS])
celldiff() # <cells a> <cells b> <from> <to> <shot>
{
	python3 -I - "$1" "$2" "$3" "$4" \
		"$(grep -aoP "kit editor: the windows at \K.*(?= \($5\))" "$c" | tail -1)" <<'EOF'
import sys, re
a = [list(map(int, l.split())) for l in open(sys.argv[1])]
b = [list(map(int, l.split())) for l in open(sys.argv[2])]
r0, r1 = int(sys.argv[3]), int(sys.argv[4])
# The windows, x y w h in the 1024x700 frame's pixels; a cell 64 x 70
rects = [tuple(map(int, m)) for m in
	re.findall(r"\w+ (-?\d+) (-?\d+) (\d+) (\d+)", sys.argv[5])]
assert rects, "no windows logged"
def over(i):
	x0, y0 = i % 16 * 64, i // 16 * 70
	return any(x < x0 + 64 and x + w > x0 and y < y0 + 70 and y + h > y0
		for x, y, w, h in rects)
ui = lambda i: i < 16 or (i % 16 < 6 and i // 16 != 7) or over(i)
print(max(abs(x - y) for i in range(r0 * 16, (r1 + 1) * 16) if not ui(i)
	for x, y in zip(a[i], b[i])))
EOF
}
# A shot's mean brightness (0..255) over the rows from..to
mean() # <png> <from> <to>
{
	cells "$1" | python3 -I -c "
import sys
v = [sum(map(int, l.split())) / 3 for l in sys.stdin]
r = v[$2 * 16:($3 + 1) * 16]
print('%.1f' % (sum(r) / len(r)))"
}
for s in plain env_noon; do
	[ -s "$t/$s.png" ] || fail "no shot $s ($c)"
	cells "$t/$s.png" > "$t/$s.cells"
done
if [ -n "${REF:-}" ]; then
	{
		echo "# util/kit_lighting_check.sh's reference: Workbench's frames"
		echo "# before [KIT_LIGHTING] ($(git -C "$here" rev-parse --short HEAD)), 16 x 10 cells' mean colours"
		echo "plain"; cat "$t/plain.cells"
		echo "env_noon"; cat "$t/env_noon.cells"
	} > "$REF_FILE"
	echo "PASS: the reference written ($REF_FILE)"
	exit 0
fi
sed -n '/^plain$/,/^env_noon$/p' "$REF_FILE" | sed '1d;$d' > "$t/ref_plain.cells"
sed -n '/^env_noon$/,$p' "$REF_FILE" | sed '1d' > "$t/ref_env_noon.cells"
d1=$(celldiff "$t/plain.cells" "$t/ref_plain.cells" 0 9 plain) || fail "no windows logged for the mask ($c)"
d2=$(celldiff "$t/env_noon.cells" "$t/ref_env_noon.cells" 8 9 env_noon) || fail "no windows logged for the mask ($c)"
[ "$d1" -le 3 ] || fail "with no environment the frame moved from today's: $d1 of 255 a cell"
[ "$d2" -le 3 ] || fail "cartoon's ground at noon moved from today's: $d2 of 255 a cell"
echo "ok: cartoon is today's look: the frame with no environment within $d1 of 255 a cell, the ground under cartoon's noon within $d2"
# The sky: the sun, the moon and the stars by the hour and their switches
# (the lines waited for above)
echo "ok: the sun, the moon and the stars by the hour (noon, 17.5, midnight) and switched off one by one"
# A shot's mean difference from another over the sky (the view's upper
# half, right of the palette), 0..255
skydiff() # <a> <b>
{
	python3 -I - "$t/$1.png" "$t/$2.png" <<'EOF'
import sys
from PIL import Image, ImageChops
a, b = (Image.open(f).convert("L").crop((300, 40, 1024, 380)) for f in sys.argv[1:3])
h = ImageChops.difference(a, b).histogram()
print("%.2f" % (sum(i * c for i, c in enumerate(h)) / sum(h)))
EOF
}
still=$(skydiff clouds_still clouds_still2)
wind=$(skydiff clouds_wind clouds_wind2)
cover=$(skydiff clouds_none clouds_still)
awk "BEGIN{exit !($cover > 5)}" || fail "the clouds' cover 0.8 drew no clouds over none: $cover"
awk "BEGIN{exit !($still < 0.3 && $wind > 0.5)}" ||
	fail "the clouds not still at no wind ($still) or not moving at 30 ($wind)"
echo "ok: the clouds by their cover (0.8 over none: $cover a pixel) and wind (still: $still, at 30 a second: $wind)"
# physical: another frame, metered; its night not black
pn=$(mean "$t/phys_noon.png" 7 9) cn=$(mean "$t/env_noon.png" 7 9)
pd=$(skydiff env_noon phys_noon) pk=$(mean "$t/phys_night.png" 0 9)
awk "BEGIN{exit !($pd > 5 && $pn > 40 && $pn < 220 && $pk > 2)}" ||
	fail "physical not its own metered frame: sky $pd from cartoon's, its noon's ground $pn (cartoon's $cn), its night $pk"
want "$c" "kit: lighting physical (HDR, metered)"
echo "ok: physical another frame (sky $pd from cartoon's), metered: its noon's ground $pn (cartoon's $cn), its night $pk"
# The sky light: the closed room dark in both, lit with it off
cc=$(mean "$t/cartoon_cave.png" 0 9) co=$(mean "$t/cartoon_cave_off.png" 0 9)
pc=$(mean "$t/phys_cave.png" 0 9) po=$(mean "$t/phys_cave_off.png" 0 9)
awk "BEGIN{exit !($cc < $co * 0.3 && $pc < $po * 0.5)}" ||
	fail "the sky light did not darken the closed room: cartoon $cc (off $co), physical $pc (off $po)"
echo "ok: the sky light darkens a closed room: cartoon $cc (off $co), physical $pc (off $po)"
pl=$(mean "$t/phys_cave_lamp.png" 0 9) cl=$(mean "$t/cartoon_cave_lamp.png" 0 9)
awk "BEGIN{exit !($pl > $pc * 1.5 && $cl < $co * 0.3)}" ||
	fail "the lamp: physical $pl (dark $pc), cartoon $cl"
echo "ok: a voxel type's light lights the room under physical ($pl, dark $pc), not cartoon ($cl)"
# The weather: the floors over the builder's cover, the intensity, the
# fade (the lines waited for above), a storm darker than the clear day
half=$(grep -aA200 "kit: weather: fading to storm over 3.0 s" "$c" |
	grep -aoP 'half way: clouds \K[0-9.]+' | head -1)
awk "BEGIN{exit !(${half:-0} > 0.2 && ${half:-0} < 0.8)}" ||
	fail "the storm's fade half way at a cover of $half"
st=$(mean "$t/storm.png" 0 9) cl=$(mean "$t/clear.png" 0 9)
awk "BEGIN{exit !($st < $cl * 0.85)}" || fail "the storm ($st) not darker than the clear day ($cl)"
echo "ok: the weather's floors over a cover of 0.9 and of 0 (rain, snow, storm, cloudy, clear), the intensity's drops (400, 200, 175), a fade half way at $half, the storm $st against clear $cl"
echo "ok: in play set_clouds and set_weather apart: the overcast through the rain and after it"
# 6. The cover dims the sun: cartoon's ground under 0.8 against none (the
# lines' "sun through" waited for above: 0.06 at 0.8, none at full, both
# lightings)
gn=$(mean "$t/clouds_none.png" 8 9) gc=$(mean "$t/clouds_still.png" 8 9)
awk "BEGIN{exit !($gc < $gn * 0.85)}" ||
	fail "the cover did not dim cartoon's sun: the ground $gc under 0.8, $gn under none"
echo "ok: the cover dims the sun: cartoon's ground $gc under 0.8 against $gn under none; none through at full cover in both lightings"
# 7. The plate's shadow: the frame's middle (the ground under the plate's
# noon shadow) against its right side (the open ground; the panels on the
# left), rows 4-5
shade() # <png>: the middle's mean over the sides'
{
	cells "$1" | python3 -I -c "
import sys
v = [sum(map(int, l.split())) / 3 for l in sys.stdin]
mid = [v[r * 16 + c] for r in (4, 5) for c in (7, 8)]
side = [v[r * 16 + c] for r in (4, 5) for c in (13, 14, 15)]
print('%.2f' % ((sum(mid) / len(mid)) / max(1, sum(side) / len(side))))"
}
sp=$(shade "$t/phys_plate.png") sc=$(shade "$t/cartoon_plate.png")
so=$(shade "$t/phys_plate_overcast.png")
awk "BEGIN{exit !($sp < 0.6 && $sc > 0.85 && $so > 0.85)}" ||
	fail "the plate's shadow: physical $sp, cartoon $sc, physical overcast $so (the middle over the sides)"
echo "ok: the plate's shadow under physical ($sp of the open ground), none under cartoon ($sc) nor physical's full cover ($so)"
# [KIT_FAST_PHYSICAL] fast_physical: no shadow, physical's metered frame
# but for the shadows and the bloom
sf=$(shade "$t/fast_plate.png") fn=$(mean "$t/fast_noon.png" 7 9)
fd=$(skydiff phys_noon fast_noon)
awk "BEGIN{exit !($sf > 0.85 && $fn > 40 && $fn < 220 && $fd < 3)}" ||
	fail "fast_physical: the plate's shadow $sf, its noon's ground $fn, its sky $fd from physical's"
echo "ok: fast_physical: no plate's shadow ($sf), metered (its noon's ground $fn), its sky $fd from physical's"
# 8. The preference: physical drawn as cartoon on that client alone
f=$t/force.log
want "$f" "kit: lighting physical drawn as cartoon (the client's preference)" \
	"kit: sky: cartoon"
! grep -aqF "kit: lighting physical (HDR" "$f" ||
	fail "the client with lighting cartoon drew physical ($f)"
echo "ok: the preference lighting cartoon draws the composition's physical as cartoon"
# 9. Physical's water (its sand through the shallows, blue deeper), the
# heightmap's ground at the voxels' level (decoded to linear; it read pale):
# the frame's lower right, off the panels
low() # <png>: "r g b" over columns 6-15, rows 7-9
{
	cells "$1" | python3 -I -c "
import sys
v = [list(map(int, l.split())) for l in sys.stdin]
r = [v[y * 16 + x] for y in (7, 8, 9) for x in range(6, 16)]
print(' '.join('%.0f' % (sum(c[i] for c in r) / len(r)) for i in range(3)))"
}
# [KIT_PHYS_WATER_LOOK] the shallow water shows its sand bed (the plain
# alpha, as skeldat's), the deep water past it blue: row 5, columns 11-14
# [KIT_SPOTS] the set's glints by kind and name (kit/core no ore)
gl=$(grep -ah "Kit's materials' glints: " "$t"/srv*.log | head -1)
for g in "kit/leaves 0.03/0.00" "kit/sand 0.00/0.04" "kit/snow 0.00/0.06" "kit/water 0.05/0.00"; do
	[[ $gl == *"$g"* ]] || fail "Kit's materials' glints: no $g ($gl)"
done
[ "$(grep -o 'kit/' <<<"${gl#*glints: }" | wc -l)" = 4 ] ||
	fail "Kit's materials' glints on others too ($gl)"
# [KIT_NORMALS] the set's relief by kind and name: water flat, sand,
# leaves and snow less, stone (not listed) full
rl=$(grep -ah "Kit's materials' relief: " "$t"/srv*.log | head -1)
for g in "kit/water 0.00" "kit/sand 0.60" "kit/leaves 0.20" "kit/snow 0.20"; do
	[[ $rl == *"$g"* ]] || fail "Kit's materials' relief: no $g ($rl)"
done
[[ $rl != *"kit/stone "* ]] || fail "Kit's materials' relief: stone not full ($rl)"
# [KIT_RELIEF_TINT] the grass side's relief from the colour drawn: its
# green fringe no longer a step over the dirt (phys_grass_side.png)
gs=$(grep -ah "kit/grass_side.png tinted #" "$t/boss.log" | head -1)
read gd gf <<<"$(sed -n 's/.*steepest step \([0-9.]*\), untinted \([0-9.]*\).*/\1 \2/p' <<<"$gs")"
[ -n "${gf:-}" ] || fail "no grass side's tinted relief line in $t/boss.log"
awk "BEGIN{exit !($gd < $gf * 0.5)}" ||
	fail "the grass side's relief still steps at its fringe: $gs"
echo "ok: the grass side's relief from its tinted colour: the steepest step $gd (the file's $gf)"
read wr wg wb <<<"$(low "$t/phys_water.png")"
awk "BEGIN{exit !($wr > $wb)}" ||
	fail "physical's shallow water hides its sand: $wr $wg $wb"
read dr dg db <<<"$(cells "$t/phys_water.png" | python3 -I -c "
import sys
v = [list(map(int, l.split())) for l in sys.stdin]
r = [v[5 * 16 + x] for x in range(11, 15)]
print(' '.join('%.0f' % (sum(c[i] for c in r) / len(r)) for i in range(3)))")"
awk "BEGIN{exit !($db > $dr * 1.25)}" ||
	fail "physical's deep water not blue: $dr $dg $db"
read vr vg vb <<<"$(low "$t/phys_ground_voxels.png")"
read hr hg hb <<<"$(low "$t/phys_ground_heightmap.png")"
awk "BEGIN{v = $vr + $vg + $vb; h = $hr + $hg + $hb; exit !(h > v * 0.85 && h < v * 1.15)}" ||
	fail "physical's heightmap ground ($hr $hg $hb) not the voxels' ($vr $vg $vb)"
echo "ok: physical's water: its sand through the shallows ($wr $wg $wb), deeper blue ($dr $dg $db); its heightmap ground ($hr $hg $hb) the voxels' ($vr $vg $vb)"
echo "PASS: lighting: cartoon today's look, physical metered, the sky by the hour and its switches, the clouds, the sky light in caves, the weather a modifier that fades, the cover dimming the sun, physical's shadows, the client's force cartoon, physical's water and heightmap ground"
# vim: set noet ts=4 sw=4:
