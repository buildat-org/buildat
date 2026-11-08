#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-08)
# covers: builtin/kit/kit.cpp builtin/kit/world.h builtin/kit/types/world_region.lua builtin/kit/client_lua/editor_input.lua
# [KIT_AIRSHIPS_2] kit/world_region and the terrain tool on floating islands,
# in Workbench's world project, its World (3) a heightmap 128 x 128 at level
# -20; kitboss edits in Kit's editor:
#   1. A region (4) placed in the air at (10, 10, 10), 16 x 8 x 16, flat:
#      grass at y 13, dirt under it, air over it; made a sphere (its corner
#      air, its middle grass); undone (the box again); moved to (10, 30, 10):
#      its old cells air again, its new ones made.
#   2. The terrain tool's seed in the air at (40, 20, 40) (size 2: a ball of
#      grass, dirt), raise on it (on the voxels: the column taller, the
#      heightmap's samples there not touched), lower past its bottom (dug,
#      nothing grown under it); the seed by mouse: the tool's Seed in 3D,
#      looking up into the sky, a click: a seed in the air.
#   3. A restart: the region's cells from the save, none written again.
#   util/kit_world_region_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_world_region; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss

n=0
edit() # <json>
{
	n=$((n + 1))
	printf 'event kit_edit %s\nwait_log 20000 entities, %d to undo\n' "$1" "$n"
}
set_e() # <id> <param> <json value>
{
	edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"
}
info() # <x> <y> <z>
{
	echo "$1 $2 $3" >> "$t/infos"
	printf 'event kit_edit {"op": "voxel_info", "pos": [%s, %s, %s]}\nsync 1000\n' "$1" "$2" "$3"
}
terrain() # <tool> <x> <y> <z> <size> <strength> <stroke>
{
	n=$((n + 1))
	printf 'event kit_edit {"op": "terrain", "tool": "%s", "on": "voxels", "x": %s, "y": %s, "z": %s, "size": %s, "strength": %s, "stroke": %s}\nwait_log 5000 kit editor: terrain: %s\n' "$@" "$1"
}
column() # <x> <y> <z>: the voxels' column near y
{
	printf 'event kit_edit {"op": "terrain", "tool": "column", "on": "voxels", "x": %s, "y": %s, "z": %s}\nwait_log 5000 kit editor: terrain: column at (%s,\n' "$1" "$2" "$3" "$1"
}
server() # <n>
{
	start_server "$t/srv$1.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
		fail "the server did not come up ($t/srv$1.log)"
	CHECK_PIDS+=($SERVER_PID)
}
client() # <n>
{
	run_client 60 "$t/boss$1.log" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/boss$1.cmds" || fail "the client failed ($t/boss$1.log, $t/srv$1.log)"
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
}
start='wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don'"'"'t add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
event kit_edit {"op": "mode", "on": true}
wait_log_any 10000 kit editor: edit mode on
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)'
: > "$t/infos"
{
	echo "$start"
	edit '{"op": "place", "type": "kit/world", "pos": [0, 1, 0]}'
	set_w() { set_e 3 "$@"; }
	set_w biome '"grassland"'
	set_w decorations false
	set_w level -20
	set_w width 128
	set_w depth 128
	set_w surface '"heightmap"'
	echo 'wait_log_any 20000 heightmap: terrain built'
	# 1. a region in the air
	edit '{"op": "place", "type": "kit/world_region", "pos": [10, 10, 10]}'
	set_e 4 generator '"flat"'
	set_e 4 decorations false
	info 15 13 15; info 15 12 15; info 15 14 15; info 10 10 10
	set_e 4 shape '"sphere"'
	info 10 10 10; info 17 13 17
	n=$((n - 1))
	printf 'event kit_edit {"op": "undo"}\nwait_log 20000 entities, %d to undo\n' "$n"
	info 10 10 10
	edit '{"op": "move", "id": 4, "pos": [10, 30, 10]}'
	info 15 13 15; info 15 33 15
	# 2. the terrain tool on the voxels: a seed in the air, raised, lowered
	terrain seed 40 20 40 2 2 1
	info 40 21 40; info 40 20 40; info 40 22 40
	column 40 21 40
	terrain raise 40 21 40 2 2 2
	column 40 21 40
	terrain lower 40 23 40 2 5 3
	info 40 19 40; info 40 18 40
	# The seed by mouse: Seed in 3D, looking up into the sky
	cat <<'EOF'
event kit_cam3d 0 40 0 0 60 30
wait_log_any 5000 kit editor: the view is 3D
keypress T
wait_log 5000 kit editor: tool terrain
click Button "Seed"
wait_log 5000 kit editor: brush seed
frames 10
mouse_pos 512 350
frames 3
mouse_down left
frames 2
mouse_up left
wait_log_any 5000 kit editor: a seed stroke at
wait_log_any 5000 kit editor: terrain: seed
frames 10
screenshot @T@/seeded.png
quit
EOF
} | sed "s|@T@|$t|g" > "$t/boss1.cmds"
server 1
wait_for_log "$t/srv1.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv1.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 client 1
# 3. a restart: the region's cells from the save
{
	echo "$start" | grep -v "ntfy\|Don\|^frames 3$\|stop\|Ended"
	info 15 33 15; info 15 13 15
	echo quit
} > "$t/boss2.cmds"
server 2
client 2
grep -a "kit/world_region\|Terrain by" "$t/srv1.log" "$t/srv2.log" |
	sed 's/^.* [IW] [a-z_]* *: /  /' | cut -c1-200
python3 - "$t" <<'PY' || fail "the region ($t/srv1.log, $t/boss1.log)"
import re, sys
t = sys.argv[1]
srv = [open("%s/srv%d.log" % (t, i), errors="replace").read() for i in (1, 2)]
cli = open(t + "/boss1.log", errors="replace").read()
asked = [tuple(map(int, l.split())) for l in open(t + "/infos")]
reads = re.findall(r"Voxel at \((-?\d+),(-?\d+),(-?\d+)\): ([^,]+)", srv[0] + srv[1])
want = ["kit/grass", "kit/dirt", "air", "kit/dirt",
	"air", "kit/grass",
	"kit/dirt",
	"air", "kit/grass",
	"kit/grass", "kit/dirt", "air",
	"air", "air",
	"kit/grass", "air"]
assert len(reads) == len(want) == len(asked), (len(reads), len(want), len(asked))
bad = 0
for (x, y, z, v), p, w in zip(reads, asked, want):
	ok = (int(x), int(y), int(z)) == p and v == w
	print("  %s %s: %s%s" % ("ok " if ok else "BAD", p, v, "" if ok else " (wanted %s)" % w))
	bad += not ok
# Written as placed and changed, nothing at the restart
lines = re.findall(r"kit/world_region: (\d+) regions, (\d+) cells written, (\d+) cleared", srv[0])
print("  region syncs:", lines)
# (placed, flat, no decorations, a sphere, the undo -- its cells put back by
# the undo itself --, moved)
assert len(lines) == 6 and lines[4] == ("1", "0", "0") and all(
	int(w) + int(c) > 0 for i, (_, w, c) in enumerate(lines) if i != 4), lines
assert "kit/world_region:" not in srv[1], "written again at the restart"
# The raise was the voxels': the column taller, the seed by mouse in the air
cols = re.findall(r"terrain: column at \(40,-?\d+,40\).*?; column \(40,40\): ([^;(]*)", cli)
print("  the seed's column before and after the raise:", cols)
assert len(cols) == 2 and cols[0] != cols[1], cols
m = re.search(r"kit editor: a seed stroke at ([-\d.]+), ([-\d.]+), ([-\d.]+) \(on the voxels\)", cli)
assert m and float(m[2]) > 45, m and m[0]
air = [int(m[1]) for m in re.finditer(r"Terrain by kitboss: seed at \(-?\d+,(\d+),-?\d+\) size \d+ strength \d+: \d+ columns, [1-9]\d* cells", srv[0])]
print("  the seeds' heights:", air)
assert len(air) == 2 and air[1] > 45, air
sys.exit(1 if bad else 0)
PY
echo "PASS: kit/world_region: a floating island made, reshaped, undone and moved; the terrain tool's seed in the air, raise and lower on it; kept over a restart"
# vim: set noet ts=4 sw=4:
