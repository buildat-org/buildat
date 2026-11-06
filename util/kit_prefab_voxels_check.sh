#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-02)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/client_lua/editor.lua apps/workbench/**
# [KIT_PREFAB_VOXELS] (kit_plan 4i) Prefabs with voxels; a copy and paste
# of voxels. A fresh save on Workbench, the admin Ended, a World (flat
# grassland):
#   1. A stone stair (facing 1, tint 2), a stone and a planks slab (upside
#      down) with a gate and a button linked to it beside them; a copy
#      (the server's) of the two entities and the box round them. Pasted
#      twice: as it was (air skipped: a stone already where the box has
#      air stays) and turned 90 (the cells, the shapes' facings, the
#      entities and their yaws turned about the base; the link between
#      the copies). The copy named a prefab with "air replaces" and
#      placed: its air takes the stone; undone, entities and voxels back
#      together. A prefab of voxels alone (a box, no entities) placed
#      turned 180. Refusals: a copy of nothing, a box too big, a turn not
#      a quarter's. The editor: the Box tool (B), Ctrl+C with nothing,
#      Ctrl+V pasting and Z turning it.
#   2. A restart: the voxel prefabs load (0 entities is a prefab with
#      voxels) and place.
#   util/kit_prefab_voxels_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_prefab_voxels; t=$CHECK_TMP
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
# An edit and the undo count it leaves
edit() # <json>
{
	n=$((n + 1))
	ed "$1"
	printf 'wait_log 10000 entities, %d to undo\n' "$n"
}
vox() # <x> <y> <z> <voxel> [param tint]
{
	if [ $# -gt 4 ]; then
		edit "{\"op\": \"set_voxel\", \"pos\": [$1, $2, $3], \"voxel\": \"$4\", \"param\": $5, \"tint\": $6}"
	else
		edit "{\"op\": \"set_voxel\", \"pos\": [$1, $2, $3], \"voxel\": \"$4\"}"
	fi
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
	edit '{"op": "place", "type": "kit/world", "pos": [0, 1, 0]}'
	edit '{"op": "set", "id": 3, "comp": 0, "param": "biome", "value": "grassland"}'
	echo "wait_log_any 30000 kit: World: generated again"
	# The original: x 3..4, y 1..2, z 3..4 (z 4 the entities' row)
	vox 3 1 3 kit/stone:stair 1 2
	vox 4 1 3 kit/stone
	vox 4 2 3 kit/planks:slab 4 0
	edit '{"op": "place", "type": "kit/gate", "pos": [3, 1, 4]}'
	edit '{"op": "place", "type": "kit/button", "pos": [4, 1, 4]}'
	edit '{"op": "link", "id": 5, "comp": 0, "output": "pressed", "to": 4, "input": "open"}'
	# The editor's keys: the Box tool, a copy of nothing, then the copy
	cat <<'EOF'
keypress b
wait_log 5000 kit editor: tool box
keydown ctrl
keypress c
keyup ctrl
wait_log 5000 kit editor: copy: nothing selected and no box
keypress b
wait_log 5000 kit editor: tool select
EOF
	refused '{"op": "copy"}' "copy: ids: 1 to 64 entities, or a box"
	refused '{"op": "copy", "box": [0, 0, 0, 64, 1, 1]}' "copy: box: 64 cells each way at most"
	ed '{"op": "copy", "ids": [4, 5], "box": [3, 1, 3, 4, 2, 4]}'
	echo "sync 5000"
	cat <<'EOF'
keydown ctrl
keypress v
keyup ctrl
wait_log 5000 kit editor: pasting
keypress z
wait_log 5000 kit editor: placing turned 270
keypress Escape
EOF
	# A stone where the box has air: a paste without "air" keeps it
	vox 10 2 3 kit/stone
	edit '{"op": "place", "clipboard": true, "pos": [10, 1, 3]}'
	refused '{"op": "place", "clipboard": true, "pos": [20, 1, 3], "turn": 45}' "place: turn: a multiple of 90 degrees"
	edit '{"op": "place", "clipboard": true, "pos": [20, 1, 3], "turn": 90}'
	for c in "10 1 3" "11 1 3" "11 2 3" "10 2 3" "20 1 3" "20 1 2" "20 2 2"; do
		info $c
	done
	# Named, air replacing; placed over a stone where it has air
	edit '{"op": "save_prefab", "clipboard": true, "name": "hut", "air": true}'
	vox 30 2 3 kit/stone
	edit '{"op": "place", "prefab": "kitboss/hut", "pos": [30, 1, 3]}'
	info 30 1 3
	info 30 2 3
	n=$((n - 1))
	ed '{"op": "undo"}'
	printf 'wait_log 10000 entities, %d to undo\n' "$n"
	info 30 1 3
	info 30 2 3
	# Voxels alone: the stair and the stone, turned 180
	edit '{"op": "save_prefab", "box": [3, 1, 3, 4, 1, 3], "name": "step"}'
	edit '{"op": "place", "prefab": "kitboss/step", "pos": [40, 1, 3], "turn": 180}'
	info 40 1 3
	info 39 1 3
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
grep -a "Voxel at\|copied\|pasted\|prefab kitboss\|An undo" "$s" | sed 's/^.*kit *: /  /' | cut -c1-170
infos=$(grep -aoP 'Voxel at \K.*' "$s")
line() { echo "$infos" | sed -n "$1p"; }
expect() # <n> <text>
{
	[ "$(line "$1")" = "$2" ] || fail "cell $1: \"$(line "$1")\", not \"$2\" ($s)"
}
want "$s" "kitboss copied 2 entities and a box of [2,2,2] voxels (" \
	"pasted the copy as 6...7, 3 voxels written" \
	"pasted the copy as 8...9, turned 90, 3 voxels written"
expect 1 "(10,1,3): kit/stone:stair, param 1, tint 2, sky light 0"
expect 2 "(11,1,3): kit/stone, param 0, tint 0, sky light 0"
expect 3 "(11,2,3): kit/planks:slab, param 4, tint 0, sky light 0"
expect 4 "(10,2,3): kit/stone, param 0, tint 0, sky light 0"
echo "ok: a paste writes the copy's voxels with their facings and tints; its air skipped"
expect 5 "(20,1,3): kit/stone:stair, param 2, tint 2, sky light 0"
expect 6 "(20,1,2): kit/stone, param 0, tint 0, sky light 0"
expect 7 "(20,2,2): kit/planks:slab, param 5, tint 0, sky light 0"
echo "ok: a paste turned 90: the cells about the base, the shapes' facings a quarter on (upside down kept)"
want "$s" "saved prefab kitboss/hut version 1 of 2 entities and a box of [2,2,2] voxels (air replaces)" \
	"placed prefab kitboss/hut as 10...12, 4 voxels written"
expect 8 "(30,1,3): kit/stone:stair, param 1, tint 2, sky light 0"
expect 9 "(30,2,3): air, param 0, tint 0, sky light 0"
expect 10 "(30,1,3): air, param 0, tint 0, sky light 0"
expect 11 "(30,2,3): kit/stone, param 0, tint 0, sky light 0"
want "$s" "An undo by kitboss: a voxel edit, 4 cells" "An undo by kitboss: 3 entities put back"
echo "ok: the copy named a prefab, air replacing; its place undone whole (entities and voxels)"
want "$s" "saved prefab kitboss/step version 1 of 0 entities and a box of [2,1,1] voxels" \
	"placed prefab kitboss/step as 13...13, turned 180, 2 voxels written"
expect 12 "(40,1,3): kit/stone:stair, param 3, tint 2, sky light 0"
expect 13 "(39,1,3): kit/stone, param 0, tint 0, sky light 0"
echo "ok: a prefab of voxels alone, placed turned 180"
want "$t/boss1.log" "kit editor: refused: copy: ids: 1 to 64 entities, or a box" \
	"kit editor: refused: copy: box: 64 cells each way at most" \
	"kit editor: refused: place: turn: a multiple of 90 degrees"
db=$(find "$t/user" -name save.sqlite -path "*/saves/world/*" | head -1)
[ -n "$db" ] || fail "no save.sqlite under $t/user"
python3 - "$db" <<'PY' || fail "the pasted entities in the save ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
row = lambda k: json.loads(db.execute("select value from store where store='kit' and key=?", (k,)).fetchone()[0])
ents = {e["id"]: e for e in row("authored")["entities"]}
def at(i):
	e = ents[i]
	return (tuple(e["pos"]), e.get("yaw", 0))
def links(i):
	return [(l["output"], l["to"], l["input"]) for l in ents[i]["components"][0].get("links", [])]
assert at(6) == ((10, 1, 4), 0) and at(7) == ((11, 1, 4), 0), (at(6), at(7))
assert links(7) == [("pressed", 6, "open")], links(7)
assert at(8) == ((21, 1, 3), 90) and at(9) == ((21, 1, 2), 90), (at(8), at(9))
assert links(9) == [("pressed", 8, "open")], links(9)
assert 10 not in ents and 11 not in ents and 12 not in ents, "the undone place's entities"
assert "prefab" not in ents[6], ents[6]
hut = row("prefab:kitboss/hut")
assert hut["voxels"]["air"] is True and hut["voxels"]["size"] == [2, 2, 2], hut["voxels"]
step = row("prefab:kitboss/step")
assert step["entities"] == [] and step["voxels"]["size"] == [2, 1, 1], step
print("  pasted: 6 %s, 7 %s; turned: 8 %s, 9 %s" % (at(6), at(7), at(8), at(9)))
PY
echo "ok: the pasted entities as the copy's (no prefab's), the turned ones about the base with their yaws, the links between the copies"

# 2. A restart: the voxel prefabs load and place
n=0
{
	joined
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: state:
EOF
	ed '{"op": "place", "prefab": "kitboss/step", "pos": [50, 1, 3]}'
	echo "wait_log 10000 kit editor: state:"
	echo "sync 5000"
	info 50 1 3
	info 51 1 3
	echo quit
} > "$t/boss2.cmds"
server 2
BUILDAT_JOIN_CREATE= client boss2
stop
s2=$t/srv2.log
want "$s2" "kitboss/hut" "kitboss/step" "placed prefab kitboss/step as 14...14, 2 voxels written"
grep -aq "Prefab kitboss/.* does not load" "$s2" && fail "a voxel prefab did not load ($s2)"
infos=$(grep -aoP 'Voxel at \K.*' "$s2")
s=$s2
expect 1 "(50,1,3): kit/stone:stair, param 1, tint 2, sky light 0"
expect 2 "(51,1,3): kit/stone, param 0, tint 0, sky light 0"
echo "ok: after a restart the voxel prefabs load and place"
echo "PASS: prefabs with voxels: a copy of entities and a box of voxels pasted as it was and turned (cells, facings, entities, yaws, links), named a prefab with air replacing, its place undone whole; a prefab of voxels alone; refusals; the editor's Box tool and keys; loaded again after a restart"
# vim: set noet ts=4 sw=4:
