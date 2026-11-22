#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-02)
# covers: builtin/kit/kit.cpp builtin/kit/terrain.h builtin/kit/materials.json builtin/kit/types/environment.lua builtin/kit/client_lua/module.lua builtin/kit/client_lua/environment.lua builtin/kit/client_lua/editor.lua builtin/voxelworld/client_lua/** apps/workbench/**
# [KIT_ENVIRONMENT] (kit_plan 4k) kit/environment. A fresh save on
# Workbench, the admin Ended, a World on the main scene (no trees):
#   - an environment placed goes on the root; the client is told it (the
#     main scene's, from the root); its weather set to snow, its season to
#     winter (the season's textures swapped, the client's registry
#     swapped), its gravity halved (the player's movement's gravity).
#     A screenshot of the snowy winter noon.
#   - a new scene "cave": the root's environment there too; one placed in
#     the cave with its sky alone set is the cave's own, the rest the
#     root's ([KIT_ENV_INHERIT]: time, fog, gravity, weather, season,
#     ambient, latitude; its ground lit as the root's, cave_root.png and
#     cave_sky.png), the main scene keeping the root's. Its season set
#     summer (the registry back), then inherited again by the inspector's
#     button (winter swapped in; inspector.png).
#   - played (the round starts on the main scene): the root's set by
#     signals (try): rain, a day of a minute
#     from 5.9 o'clock (dawn signalled), a bad weather refused quietly.
#   util/kit_environment_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
python3 -c "import PIL" 2>/dev/null || skip "no python3 PIL"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_environment; t=$CHECK_TMP
cd "$here/Build"

server() # <n>
{
	start_server "$t/srv$1.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
		--sim-rate "$CHECK_RATE" ||
		fail "the server did not come up ($t/srv$1.log)"
	CHECK_PIDS+=($SERVER_PID)
}
client() # <name>: its commands in $t/<name>.cmds
{
	run_client 60 "$t/$1.log" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" ||
		fail "client $1 failed ($t/$1.log, $t/srv*.log)"
}
stop()
{
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
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
edit() # <json>
{
	n=$((n + 1))
	ed "$1"
	printf 'wait_log 10000 entities, %d to undo\n' "$n"
}
vox() # <x> <y> <z> <voxel>
{
	edit "{\"op\": \"set_voxel\", \"pos\": [$1, $2, $3], \"voxel\": \"$4\"}"
}
info() # <x> <y> <z>
{
	ed "{\"op\": \"voxel_info\", \"pos\": [$1, $2, $3]}"
	echo "sync 5000"
}
refused() # <json> <reason>
{
	ed "$1"
	printf 'wait_log 10000 kit editor: refused: %s\n' "$2"
}
in_scene() # <scene> <scenes>
{
	printf 'wait_log 30000 kit editor: in the scene %s of %s\n' "$1" "$2"
}
joined()
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
EOF
}
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
EOF
	joined
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
	# 3: the main scene's World
	edit '{"op": "place", "type": "kit/terrain", "pos": [0, 1, 0]}'
	edit '{"op": "set", "id": 3, "comp": 0, "param": "biome", "value": "grassland"}'
	echo "wait_log_any 30000 kit: World: generated again"
	# No trees: the sky open above the camera
	edit '{"op": "set", "id": 3, "comp": 0, "param": "decorations", "value": false}'
	echo "wait_log 30000 kit: World: generated again"
	# 4: the environment, on the root
	edit '{"op": "place", "type": "kit/environment", "pos": [0, 1, 0]}'
	echo "wait_log_any 10000 kit: environment: from the root, 4,"
	edit '{"op": "set", "id": 4, "comp": 0, "param": "weather", "value": "snow"}'
	echo "wait_log_any 10000 kit: weather snow"
	edit '{"op": "set", "id": 4, "comp": 0, "param": "season", "value": "winter"}'
	echo "wait_log_any 10000 kit: season winter: registry swapped"
	edit '{"op": "set", "id": 4, "comp": 0, "param": "gravity", "value": 0.5}'
	# [KIT_FAR_CLIP] the cameras' far clip past the fog: at the default 200
	# the app's own, at 800 a tenth past it
	echo "wait_log_any 10000 kit: the far clip: play 250, editor 300 (fog_end 200)"
	edit '{"op": "set", "id": 4, "comp": 0, "param": "fog_end", "value": 800}'
	echo "wait_log_any 10000 kit: the far clip: play 880, editor 880 (fog_end 800)"
	# Latitude and north: by default (25, north 0, 15 o'clock) the sun
	# south-west, 40 degrees up; at 60 and 12 o'clock, 29.5 up, due -z
	echo "wait_log_any 10000 toward the sun -0.71 0.64 -0.31"
	edit '{"op": "set", "id": 4, "comp": 0, "param": "latitude", "value": 60}'
	edit '{"op": "set", "id": 4, "comp": 0, "param": "time", "value": 12}'
	echo "wait_log_any 10000 0.49 -0.87"
	# (an ambient of its own, to tell the cave's inherited one from the default)
	edit '{"op": "set", "id": 4, "comp": 0, "param": "ambient", "value": "#8c8c96"}'
	cat <<EOF
wait_log_any 10000 kit: weather drawn: snow
frames 60
screenshot $t/winter.png
EOF
	# 5, 6: the cave, the root's environment there too
	edit '{"op": "new_scene", "name": "cave", "copy": true}'
	in_scene cave "world, cave"
	echo "sync 5000"
	cat <<EOF
frames 60
screenshot $t/cave_root.png
EOF
	# 7: the cave's own, its sky alone set ([KIT_ENV_INHERIT]): the root's
	# light, fog, time and season kept
	edit '{"op": "place", "type": "kit/environment", "pos": [0, 1, 0], "params": {"sky": "#405a78"}}'
	echo "wait_log_any 10000 kit: environment: from the scene, 7, 12.0 o'clock, sky #405a78, fog 120-800, gravity 0.5, weather snow, season winter, ambient #8c8c96, sun true, latitude 60"
	cat <<EOF
frames 60
screenshot $t/cave_sky.png
EOF
	# Its season set (its own), then inherited again by the inspector's button
	edit '{"op": "set", "id": 7, "comp": 0, "param": "season", "value": "summer"}'
	echo "wait_log_any 10000 kit: season summer: own registry again"
	n=$((n + 1))
	cat <<EOF
event kit_select 7
wait_log_any 5000 kit editor: selected 7
frames 8
screenshot $t/inspector.png
click Button "Inherit season"
wait_log 5000 kit editor: 7/1 season inherited
wait_log 10000 entities, $n to undo
wait_log 10000 kit: season winter: registry swapped
EOF
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
event kit_edit {"op": "try", "id": 4, "comp": 0, "input": "set_weather", "value": "rain"}
wait_log 10000 kit: weather rain
event kit_edit {"op": "try", "id": 4, "comp": 0, "input": "set_weather", "value": "hail"}
event kit_edit {"op": "try", "id": 4, "comp": 0, "input": "set_day_minutes", "value": 1}
event kit_edit {"op": "try", "id": 4, "comp": 0, "input": "set_time", "value": 5.9}
delay 1500
sync 5000
EOF
	echo quit
} > "$t/boss1.cmds"
server 1
wait_for_log "$t/srv1.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv1.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss1
stop
s=$t/srv1.log c=$t/boss1.log
grep -a "Environment of\|Season\|kit/environment\|movement" "$s" | sed 's/^.*\(kit\|main\) *: /  /' | cut -c1-200
grep -a "kit: environment\|kit: weather\|kit: season" "$c" | sed 's/^.*kit: /  client: /' | cut -c1-200
want "$c" "kit: environment: from the root, 4, 15.0 o'clock, sky #8cadd9, fog 120-200, gravity 1, weather clear, season summer" \
	"kit: weather snow" "kit: season winter: registry swapped"
grep -aqP 'Environment of the scene world: \{.*"entity":4,.*"from":"root"' "$s" ||
	fail "the main scene's environment not from the root ($s)"
grep -aqP 'Season winter of the scene world: [1-9][0-9]* voxel types' "$s" ||
	fail "no voxel types' textures swapped for winter ($s)"
echo "ok: an environment on the root, its weather and season told; the winter textures swapped"
grep -aqP "kitboss's movement kit/walker changed: gravity 10\.0" "$s" ||
	fail "the movement's gravity not halved ($s)"
echo "ok: the environment's gravity times the movement's own"
want "$c" "kit: environment: from the scene, 7, 12.0 o'clock, sky #405a78, fog 120-800, gravity 0.5, weather snow, season winter, ambient #8c8c96, sun true, latitude 60" \
	"kit: season summer: own registry again" "kit editor: 7/1 season inherited" \
	"kit: weather rain"
grep -aqP 'Environment of the scene cave: \{.*"entity":4,.*"from":"root"' "$s" ||
	fail "the cave not first given the root's environment ($s)"
grep -aqP 'Environment of the scene cave: \{.*"entity":7,.*"from":"scene"' "$s" ||
	fail "the cave's own environment not its ($s)"
# (the season winter again after the inherit: the registry swapped twice
# after the own summer)
python3 -I - "$c" <<'PY' || fail "the cave's season not the root's again ($c)"
import sys
s = open(sys.argv[1], "rb").read().decode(errors="replace")
own = s.index("kit: season summer: own registry again")
assert "kit: season winter: registry swapped" in s[own:]
PY
# The sky alone the cave's: its ground lit as the root's (right of the
# palette and the new environment's gizmo, below the horizon: within a few
# levels, the snow's flakes aside). (Under fast_physical the sky drawn is
# physical_sky's: the sky colour is the far fog's, not seen at 800.)
python3 -I - "$t/cave_root.png" "$t/cave_sky.png" <<'PY' || fail "the cave's sky-only environment not lit as the root ($t/cave_root.png, $t/cave_sky.png)"
import sys
from PIL import Image
A, B = (Image.open(f).convert("RGB") for f in sys.argv[1:])
w, h = A.size
def mean(im):
    px = [im.getpixel((x, y)) for y in range(h // 2 + 60, h - 70, 3)
          for x in range(680, w - 10, 3)]
    return [sum(p[i] for p in px) / len(px) for i in range(3)]
ga, gb = mean(A), mean(B)
print("the ground under the root's %s, under the cave's own %s" % tuple(
    " ".join("%.0f" % c for c in v) for v in (ga, gb)))
assert sum(ga) / 3 > 40 and max(abs(a - b) for a, b in zip(ga, gb)) < 10, (ga, gb)
PY
echo "ok: a scene's own environment with its sky alone: the root's light, fog, time and season kept, its ground lit as the root's; a season set on it and inherited again"
# Saved and loaded again: the cave's environment has its sky alone its own
db=$(find "$t/user" -name save.sqlite -path "*/saves/world/*" | head -1)
python3 -I - "$db" <<'PY' || fail "the cave's environment's own parameters not saved ($db)"
import json, sqlite3, sys
db = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
a = json.loads(db.execute("select value from store where store='kit' and "
    "key='authored'").fetchone()[0])
c = [e for e in a["entities"] if e["id"] == 7][0]["components"][0]
assert c.get("overrides") == ["sky"] and c["params"]["sky"] == "#405a78", c
print("saved: entity 7's overrides %s" % c["overrides"])
PY
server 2
wait_for_log "$t/srv2.log" 'Environment of the scene cave: \{.*"entity":7' 60 ||
	fail "the cave's environment not told after the restart ($t/srv2.log)"
stop
grep -a 'Environment of the scene cave: {' "$t/srv2.log" | tail -1 | grep -aqF \
	'"ambient":"#8c8c96"' || fail "the cave's ambient not the root's after the restart ($t/srv2.log)"
grep -a 'Environment of the scene cave: {' "$t/srv2.log" | tail -1 | grep -aqP \
	'"from":"scene".*"season":"winter","sky":"#405a78"' ||
	fail "the cave's sky not its own, or its season not the root's, after the restart ($t/srv2.log)"
echo "ok: saved and loaded: the cave's sky its own, its ambient and season the root's"
want "$s" "kit/environment 4: set_weather rain by kitboss" \
	"kit/environment 4: set_day_minutes 1" "kit/environment 4: dawn"
grep -aq "set_weather hail" "$s" && fail "a bad weather taken ($s)"
echo "ok: the environment's signals: weather, the clock and dawn"
[ -s "$t/winter.png" ] || fail "no screenshot ($t/winter.png)"
echo "PASS: environment: on the root and a scene's own, weather, season textures, gravity, signals and the clock"
# vim: set noet ts=4 sw=4:
