#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-02)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/box/box.c builtin/kit/types/teleporter.lua builtin/kit/client_lua/editor.lua builtin/replicate/** builtin/voxelworld/** apps/workbench/**
# [KIT_SCENES] (kit_plan 4k) Scenes, each its own World; portals. A fresh
# save on Workbench, the admin Ended, a World on the main scene:
#   1. A stone in the main scene. A new scene "cave" with the World
#      copied: the builder taken there, the stone not in it (its own
#      voxels), a plank and a sign placed in it, its World's level
#      raised (its own row). A new scene "sky", blank. Refusals: the
#      same name again, a bad name. Back to the main scene: the stone
#      there, the plank not. A teleporter in the main scene onto the
#      sign, two-way: a teleporter back on the sign. Played: the
#      teleporter takes the admin to the cave, onto the sign without
#      stepping on its teleporter; the sign's takes them back.
#   2. The save's World moved onto the root (as before scenes); a
#      restart: it moves back onto the main scene, the scenes are made
#      again by the app, each its voxels.
#   util/kit_scenes_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_scenes; t=$CHECK_TMP
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
	vox 3 1 3 kit/stone
	# 4, 5: the cave, its World a copy of the main one's
	edit '{"op": "new_scene", "name": "cave", "copy": true}'
	in_scene cave "world, cave"
	echo "sync 5000"
	info 3 1 3
	vox 6 1 6 kit/planks
	edit '{"op": "set", "id": 5, "comp": 0, "param": "level", "value": 4}'
	echo "sync 5000"
	# 6: the sign the teleporter goes to
	edit '{"op": "place", "type": "kit/sign", "pos": [2, 5, 2]}'
	refused '{"op": "new_scene", "name": "cave"}' "new_scene: there is a scene cave already"
	refused '{"op": "new_scene", "name": "a b"}' "new_scene: a scene's name is 1 to 32 letters, digits and _"
	# 7: the sky, blank
	edit '{"op": "new_scene", "name": "sky"}'
	in_scene sky "world, cave, sky"
	ed '{"op": "scene", "name": "world"}'
	in_scene world "world, cave, sky"
	echo "sync 5000"
	refused '{"op": "scene", "name": "world"}' "scene: already in the scene world"
	refused '{"op": "scene", "name": "nowhere"}' "scene: no scene nowhere"
	info 3 1 3
	info 6 1 6
	# 8: a teleporter onto the sign, two-way
	edit '{"op": "place", "type": "kit/teleporter", "pos": [8, 1, 8]}'
	edit '{"op": "set", "id": 8, "comp": 0, "param": "target", "value": 6}'
	edit '{"op": "set", "id": 8, "comp": 0, "param": "two_way", "value": true}'
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
event kit_edit {"op": "try", "id": 8, "comp": 0, "input": "teleport"}
EOF
	in_scene cave "world, cave, sky"
	echo "sync 5000"
	echo 'event kit_edit {"op": "try", "id": 6, "comp": 1, "input": "teleport"}'
	in_scene world "world, cave, sky"
	echo "sync 5000"
	echo quit
} > "$t/boss1.cmds"
server 1
wait_for_log "$t/srv1.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv1.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss1
stop
s=$t/srv1.log
grep -a "Voxel at\|scene\|teleport\|An edit" "$s" | sed 's/^.*\(kit\|main\) *: /  /' | cut -c1-170
infos=$(grep -aoP 'Voxel at \K.*' "$s")
line() { echo "$infos" | sed -n "$1p"; }
expect() # <n> <text>
{
	[ "$(line "$1")" = "$2" ] || fail "cell $1: \"$(line "$1")\", not \"$2\" ($s)"
}
want "$s" "An edit by kitboss: made the scene cave, its World world's copied" \
	"Scene cave made by the app" "kitboss goes to the scene cave" \
	"An edit by kitboss: made the scene sky"
expect 1 "(3,1,3): air, param 0, tint 0, sky light 0"
expect 2 "(3,1,3): kit/stone, param 0, tint 0, sky light 0"
expect 3 "(6,1,6): air, param 0, tint 0, sky light 0"
echo "ok: a new scene, its World copied, its own voxels; a blank one; switching between them"
want "$t/boss1.log" "kit editor: refused: new_scene: there is a scene cave already" \
	"kit editor: refused: scene: no scene nowhere"
want "$s" ", a teleporter back on entity 6" \
	"Entity 8's kit/teleporter teleports kitboss to (2, 5, 2) in the scene cave" \
	"kit/teleporter 6: signalled for kitboss to entity 8" \
	"Entity 6's kit/teleporter teleports kitboss to (8, 1, 8) in the scene world"
grep -aq "kit/teleporter 6: stepped on by\|kit/teleporter 8: stepped on by" "$s" &&
	fail "an arrival stepped on the teleporter it arrived on ($s)"
echo "ok: a two-way teleporter between scenes: there onto the sign and back, arriving silently"
db=$(find "$t/user" -name save.sqlite -path "*/saves/world/*" | head -1)
[ -n "$db" ] || fail "no save.sqlite under $t/user"
python3 - "$db" <<'PY' || fail "the scenes in the save ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
row = lambda k: json.loads(db.execute("select value from store where store='kit' and key=?", (k,)).fetchone()[0])
au = row("authored")
ents = {e["id"]: e for e in au["entities"]}
assert ents[4].get("kind") == "scene" and ents[4]["name"] == "cave", ents[4]
assert ents[7].get("kind") == "scene" and ents[7]["name"] == "sky", ents[7]
assert ents[5]["parent"] == 4 and "pos" not in ents[5], ents[5]
assert ents[6]["parent"] == 4, ents[6]
assert row("world")["params"]["level"] == 0, row("world")
assert row("world:cave")["params"]["level"] == 4, row("world:cave")
assert row("world:sky")["params"]["generator"] == "flat", row("world:sky")
# As before scenes: the World on the root
main = ents[3]["parent"]
ents[3]["parent"] = 1
db.execute("update store set value=? where store='kit' and key='authored'", (json.dumps(au),))
db.commit()
print("  the World 3 moved from scene %d onto the root" % main)
PY
echo "ok: the scenes and their Worlds in the save, each World its own row"

# 2. A restart: the root World migrates, the scenes come back
n=0
{
	joined
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: state:
EOF
	info 3 1 3
	ed '{"op": "scene", "name": "cave"}'
	in_scene cave "world, cave, sky"
	echo "sync 5000"
	info 6 1 6
	info 3 1 3
	echo quit
} > "$t/boss2.cmds"
server 2
BUILDAT_JOIN_CREATE= client boss2
stop
s=$t/srv2.log
want "$s" "World: entity 3 moved from the root onto the scene world" \
	"Scene cave made by the app" "Scene sky made by the app"
infos=$(grep -aoP 'Voxel at \K.*' "$s")
expect 1 "(3,1,3): kit/stone, param 0, tint 0, sky light 0"
expect 2 "(6,1,6): kit/planks, param 0, tint 0, sky light 0"
expect 3 "(3,1,3): air, param 0, tint 0, sky light 0"
echo "ok: after a restart a root World moves onto the main scene; the scenes are made again, each its voxels"
echo "PASS: scenes: a new scene with its World copied or blank, switched between, each its voxels and World row; refusals; a two-way teleporter between scenes, arriving silently; a root World migrated and the scenes back after a restart"
# vim: set noet ts=4 sw=4:
