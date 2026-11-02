#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-02)
# covers: builtin/kit/kit.cpp builtin/kit/world.h builtin/kit/materials.json builtin/kit/types/environment.lua builtin/kit/client_lua/module.lua builtin/voxelworld/client_lua/** apps/workbench/**
# [KIT_ENVIRONMENT] (kit_plan 4k) kit/environment. A fresh save on
# Workbench, the admin Ended, a World on the main scene (no trees):
#   - an environment placed goes on the root; the client is told it (the
#     main scene's, from the root); its weather set to snow, its season to
#     winter (the season's textures swapped, the client's registry
#     swapped), its gravity halved (the player's movement's gravity).
#     A screenshot of the snowy winter noon.
#   - a new scene "cave": the root's environment there too; one placed in
#     the cave is the cave's own, the season summer again (the registry
#     back), the main scene keeping the root's.
#   - played (the round starts on the main scene): the root's set by
#     signals (try): rain, a day of a minute
#     from 5.9 o'clock (dawn signalled), a bad weather refused quietly.
#   util/kit_environment_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
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
	edit '{"op": "place", "type": "kit/world", "pos": [0, 1, 0]}'
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
	cat <<EOF
wait_log_any 10000 kit: weather drawn: snow
frames 60
screenshot $t/winter.png
EOF
	# 5, 6: the cave, the root's environment there too
	edit '{"op": "new_scene", "name": "cave", "copy": true}'
	in_scene cave "world, cave"
	echo "sync 5000"
	# 7: the cave's own
	edit '{"op": "place", "type": "kit/environment", "pos": [0, 1, 0]}'
	echo "wait_log_any 10000 kit: environment: from the scene, 7,"
	echo "wait_log_any 10000 kit: season summer: own registry again"
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
want "$c" "kit: environment: from the root, 4, 12.0 o'clock, sky #8cadd9, fog 120-200, gravity 1, weather clear, season summer" \
	"kit: weather snow" "kit: season winter: registry swapped"
grep -aqP 'Environment of the scene world: \{.*"entity":4,.*"from":"root"' "$s" ||
	fail "the main scene's environment not from the root ($s)"
grep -aqP 'Season winter of the scene world: [1-9][0-9]* voxel types' "$s" ||
	fail "no voxel types' textures swapped for winter ($s)"
echo "ok: an environment on the root, its weather and season told; the winter textures swapped"
grep -aqP "kitboss's movement kit/walker changed: gravity 10\.0" "$s" ||
	fail "the movement's gravity not halved ($s)"
echo "ok: the environment's gravity times the movement's own"
want "$c" "kit: environment: from the scene, 7, 12.0 o'clock" \
	"kit: season summer: own registry again" "kit: weather rain"
grep -aqP 'Environment of the scene cave: \{.*"entity":4,.*"from":"root"' "$s" ||
	fail "the cave not first given the root's environment ($s)"
grep -aqP 'Environment of the scene cave: \{.*"entity":7,.*"from":"scene"' "$s" ||
	fail "the cave's own environment not its ($s)"
echo "ok: a scene's own environment over the root's, whole"
want "$s" "kit/environment 4: set_weather rain by kitboss" \
	"kit/environment 4: set_day_minutes 1" "kit/environment 4: dawn"
grep -aq "set_weather hail" "$s" && fail "a bad weather taken ($s)"
echo "ok: the environment's signals: weather, the clock and dawn"
[ -s "$t/winter.png" ] || fail "no screenshot ($t/winter.png)"
echo "PASS: environment: on the root and a scene's own, weather, season textures, gravity, signals and the clock"
# vim: set noet ts=4 sw=4:
