#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-01)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/world.h builtin/kit/materials.json builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua builtin/kit/client_lua/module.lua builtin/kit/client_data/KitVoxel* builtin/kit/client_data/*.png src/impl/mesh.cpp src/interface/voxel*.h apps/workbench/main/main.cpp apps/workbench/main/client_data/brick.png apps/workbench/main/client_data/glass.png
# [KIT_TINT_PALETTE] [KIT_TINT_MASK] [KIT_TINT_NATURE] [KIT_TINT_MATERIALS]
# Tint palettes on Workbench: a fresh save, the admin Ended, a flat World
# (no decorations). The editor's tints of a material (its dropdown's
# labels: the default ramp's names, grass's biomes, the brick's six, the
# stained glass's sixteen). A wall of bands facing the player, each a
# material at a tint: the shot's band colours say
#   - grass and leaves at 0 green (their old look), at savanna/autumn
#     yellower and redder: a hue, not a darkening;
#   - a grass block's side: its dirt the same brown at grass tints 0 and
#     savanna (the mask), its top strip not;
#   - brick at 0 red, white-washed pale; its mortar the same grey at both;
#   - stained glass red lets the stone behind through, tinted red;
#   - stone "dark" darker than at 0; water warm greener than ocean;
#     cherry planks paler and pinker than oak; red sand red.
# The shot is kept with KEEP_TMP=1; look at it.
#   util/kit_tint_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_tint; t=$CHECK_TMP
cd "$here/Build"
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
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
edit() # <json>
{
	n=$((n + 1))
	ed "$1"
	printf 'wait_log 10000 entities, %d to undo\n' "$n"
}
# A band: x0..x1 at z, y 1..H, of a voxel at a tint
H=6
band() # <x0> <x1> <z> <voxel> <tint>
{
	local x y
	for y in $(seq 1 $H); do for x in $(seq "$1" "$2"); do
		ed "{\"op\": \"set_voxel\", \"pos\": [$x, $y, $3], \"voxel\": \"$4\", \"param\": 0, \"tint\": $5}"
	done; done
	# (not counted: the undo stack keeps the last 50)
	echo "sync 5000"
}
{
	cat <<'EOF2'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
event kit_tints kit/stone
event kit_tints kit/grass
event kit_tints kit/leaves
event kit_tints kit/water
event kit_tints workbench/brick
event kit_tints workbench/glass
event kit_tints kit/cobble
sync 5000
EOF2
	edit '{"op": "place", "type": "kit/world", "pos": [0, 1, 0]}'
	edit '{"op": "set", "id": 3, "comp": 0, "param": "biome", "value": "grassland"}'
	echo "wait_log 30000 kit: World: generated again"
	edit '{"op": "set", "id": 3, "comp": 0, "param": "decorations", "value": false}'
	echo "wait_log 30000 kit: World: generated again"
	echo "idle 30000"
	# The wall at z 8, a cell a band, x -6...7 (+x on the right); stone
	# behind the glass
	B="-6 kit/stone 0 9
-6 workbench/glass 14 8
-5 kit/stone 4 8
-4 kit/stone 0 8
-3 workbench/brick 3 8
-2 workbench/brick 0 8
-1 kit/leaves 15 8
0 kit/leaves 0 8
1 kit/grass 6 8
2 kit/grass 0 8
3 kit/water 0 8
4 kit/water 1 8
5 kit/planks 0 8
6 kit/planks 7 8
7 kit/sand 1 8"
	echo "$B" | while read -r x v tint z; do band "$x" "$x" "$z" "$v" "$tint"; done
	# [KIT_TINT_MASK] Doors (looks) wearing the brick and the grass before
	# the wall: drawn at their palettes' entry 0, masked
	# (the undo stack full: its count stays)
	ed '{"op": "place", "type": "kit/door", "pos": [-2, 2, 5]}'
	echo "wait_log 10000 kit: entity 4 drawn"
	ed '{"op": "set", "id": 4, "comp": 0, "param": "material", "value": "workbench/brick"}'
	echo "wait_log 10000 kit: entity 4 wears workbench/brick"
	ed '{"op": "place", "type": "kit/door", "pos": [3, 2, 5]}'
	echo "wait_log 10000 kit: entity 5 drawn"
	ed '{"op": "set", "id": 5, "comp": 0, "param": "material", "value": "kit/grass"}'
	echo "wait_log 10000 kit: entity 5 wears kit/grass"
	cat <<'EOF2'
keypress F6
wait_log 10000 the server put the player at
wait_log_any 10000 kit editor: edit mode off
idle 30000
look_dir 0 0.15 1
frames 10
idle 30000
frames 5
screenshot @T@/wall.png
quit
EOF2
} > "$t/boss.cmds"
sed -i "s|@T@|$t|g" "$t/boss.cmds"
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" \
	run_client 60 "$t/boss.log" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_boss" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/boss.cmds" ||
	fail "the client failed ($t/boss.log, $t/srv.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
grep -aoP 'kit editor: tints of \K.*' "$t/boss.log" | sed 's/^/  /' | cut -c1-160
want "$t/boss.log" \
	"tints of kit/stone: grey, warm, cool, sandstone, dark, pale, granite" \
	"tints of kit/grass: plains, forest, birch forest, dark forest, jungle, sparse jungle, savanna, swamp," \
	"tints of kit/leaves: plains, forest, birch forest, dark forest, jungle, sparse jungle, savanna, swamp, taiga, snowy, badlands, meadow, windswept, mushroom fields, mangrove, autumn" \
	"tints of workbench/brick: clay red, yellow, dark, white-washed, brown, orange" \
	"tints of workbench/glass: clear, orange, magenta, light blue, yellow, lime, pink, grey, light grey, cyan, purple, blue, brown, green, red, black" \
	"tints of kit/cobble: default, dusty, very dusty, muddy, very muddy, brown, faintly mossy, slightly mossy, mossy, very mossy, green, grimy, very grimy, sooty, very sooty, dark"
echo "ok: the editor's tints: a material set's palettes by name, Workbench's brick and glass theirs, the default ramp's names"
[ -s "$t/wall.png" ] || fail "no shot ($t/boss.log)"
# The bands' colours: each band's middle (a cell's width is ~60 px; the
# wall leans with the view), the sky behind the cut out leaves left out
python3 -I - "$t/wall.png" <<'PY2' || fail "the bands' colours ($t/wall.png)"
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
W, H = im.size
assert (W, H) == (1024, 700), im.size
# Band i's (x -6 + i) middle on row y: 120 + 60 i at the wall's top (y
# 150), 72 + 65.6 i at its foot (y 520)
def mid(i, y):
	f = (y - 150) / 370.0
	return (120 + 60 * i) * (1 - f) + (72 + 65.6 * i) * f
def px(i, y0, y1, keep=lambda p: True):
	out = []
	for y in range(y0, y1):
		c = int(mid(i, y))
		for x in range(c - 10, c + 11):
			p = im.getpixel((x, y))
			if keep(p):
				out.append(p)
	return out
def mean(ps):
	assert ps
	return [sum(p[k] for p in ps) / len(ps) for k in range(3)]
def lum(c):
	return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]
not_sky = lambda p: not (p[2] > p[0] + 30 and p[2] > p[1] + 10)
band = {}
for i, name in enumerate(["glass red", "stone dark", "stone", "brick white-washed",
		"brick", "leaves autumn", "leaves", "grass savanna", "grass", "water",
		"water warm", "planks", "planks cherry", "sand red"]):
	band[name] = px(i, 160, 262, not_sky if name.startswith("leaves") else
			lambda p: True)
m = {k: mean(v) for k, v in band.items()}
for k, v in m.items():
	print("  %-18s #%02x%02x%02x" % ((k,) + tuple(int(c) for c in v)))
r, g, b = m["leaves"]
assert g > r and g > b, "the leaves at 0 are not green"
r, g, b = m["leaves autumn"]
assert r > g * 1.3 and r > b * 2, "the leaves at autumn are not orange"
# A grass block's side: its top cell (rows 147...210): the strip of
# grass at its top, the dirt under it
strip = {k: mean(px(i, 150, 157)) for i, k in ((7, "savanna"), (8, "plains"))}
dirt = {k: mean(px(i, 175, 205)) for i, k in ((7, "savanna"), (8, "plains"))}
print("  grass side strip %s, dirt %s" % ({k: "#%02x%02x%02x" % tuple(int(c) for c in v) for k, v in strip.items()},
		{k: "#%02x%02x%02x" % tuple(int(c) for c in v) for k, v in dirt.items()}))
assert strip["plains"][1] > strip["plains"][0] * 1.2, "the plains strip is not green"
assert strip["savanna"][0] / strip["savanna"][1] > strip["plains"][0] / strip["plains"][1] + 0.15, \
	"savanna's strip is no yellower than plains'"
assert all(abs(dirt["savanna"][k] - dirt["plains"][k]) < 10 for k in range(3)), \
	"the dirt took the tint (the mask)"
r, g, b = m["brick"]
assert r > g * 1.4 and r > b * 1.4, "the brick at 0 is not red"
assert max(m["brick white-washed"]) - min(m["brick white-washed"]) < 30 and \
	lum(m["brick white-washed"]) > lum(m["brick"]) * 1.4, "white-washed is not pale"
# The mortar of the red brick keeps its grey: pixels near grey there
grey = [p for p in band["brick"] if abs(p[0] - p[1]) < 25 and p[0] > 90]
assert len(grey) > len(band["brick"]) * 0.1, "the brick's mortar took the tint"
assert lum(m["stone dark"]) < lum(m["stone"]) * 0.75, "stone dark is not darker"
r, g, b = m["glass red"]
assert r > g + 25 and r > b + 10, "the red glass is not red"
assert m["water"][2] > m["water"][0] * 1.5 and \
	m["water warm"][1] / m["water warm"][2] > m["water"][1] / m["water"][2] + 0.15, \
	"the water's ocean and warm"
assert m["planks cherry"][2] / m["planks cherry"][0] > m["planks"][2] / m["planks"][0] + 0.1 and \
	lum(m["planks cherry"]) > lum(m["planks"]), "cherry planks are not paler and pinker"
r, g, b = m["sand red"]
assert r > g * 1.5, "red sand is not red"
# The doors before the wall wearing the brick (x 200...310, y 290...450)
# and the grass (x 720...810; its top cell's strip y 280...300, its dirt
# 320...360): entry 0, masked
door = [im.getpixel((x, y)) for x in range(215, 300) for y in range(300, 440)]
r, g, b = mean(door)
grey = [p for p in door if abs(p[0] - p[1]) < 25 and p[0] > 90]
print("  doors: brick #%02x%02x%02x (%d%% mortar)" % (int(r), int(g), int(b), 100 * len(grey) // len(door)), end="")
assert r > g * 1.4 and len(grey) > len(door) * 0.1, "the brick door"
gs = mean([im.getpixel((x, y)) for x in range(730, 800) for y in range(282, 298)])
gd = mean([im.getpixel((x, y)) for x in range(730, 800) for y in range(322, 358)])
print(", grass strip #%02x%02x%02x, dirt #%02x%02x%02x" % tuple(int(c) for c in gs + gd))
assert gs[1] > gs[0] * 1.2 and gd[0] > gd[1], "the grass door"
PY2
echo "ok: the shot's bands: grass, leaves and water hued by their palettes, the dirt and the mortar kept by the mask, brick red and white-washed, stone dark, red glass over stone, cherry planks, red sand; doors wearing the brick and the grass as the voxels do ($t/wall.png)"
echo "PASS: Kit's tint palettes: named entries in the editor (a set's palettes, Workbench's brick and glass, the default ramp), the textures re-painted to tint 0's old look and hued by the palettes, masked where the texture says"
