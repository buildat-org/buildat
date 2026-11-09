#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-06)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua builtin/kit/client_lua/prefabs.lua builtin/kit/types/prefab_copy.lua apps/workbench/**
# [KIT_PREFAB_ROOT] A placed prefab's root, by the editor's clicks. A fresh save
# on Workbench, the admin Ended, a World (flat grassland); prefab kitboss/hut:
# a gate, a button linked to it, two voxels in a 2x2x2 box.
#   1. The palette's menu places it. Two copies: a parameter set on the first
#      (its mark, its Reset); the second given a door and a link and saved by
#      its inspector: the first gains them and keeps its parameter, then Reset.
#      Refusals: Kit's prefab saved, a stamp at a turn not a quarter's. Voxels
#      alone, and a prefab with no place, have a root too. In the save: the
#      numbers, parents, links and versions.
#   2. A restart. A turned copy saved (its voxels back in the prefab's frame);
#      Refresh voxels with each answer, undone; a single root moved by a key
#      with each answer, undone (no dialog on an undo); a turn off the quarters
#      says the voxels stay; its box's outline.
#   3. By the palette's menu: Rename (copies and an item's look follow, a taken
#      name refused), Delete refused for the look, Delete with copies placed,
#      what such a copy offers then. Detach. Save to prefab brings it back.
# Screenshots kept with KEEP_TMP=1: $t/*.png
#   util/kit_prefab_root_check.sh
#   util/kit_prefab_root_check.sh web    the new UI in headless Chrome
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
if [ "${1:-}" = web ]; then
	# The new UI in the web client (web/), in headless Chrome at 1200x800: the
	# palette's menu on a prefab and on a type with no place; kit/hut (voxels
	# alone) placed, its root's Refresh voxels and a key's move, the dialog
	# each way, undone; a prefab of one's own renamed and deleted by the menu
	export BUILDAT_WORKBENCH_STONE=1
	check_tmp kit_prefab_root_web; t=$CHECK_TMP
	stub="(function(){ var held = null, refuse = false;
 Object.defineProperty(document, 'pointerLockElement', {configurable: true, get: function(){ return held; }});
 function set(e){ held = e; document.dispatchEvent(new Event('pointerlockchange')); }
 document.addEventListener('keydown', function(e){ if(e.key === 'Escape') refuse = true; }, true);
 document.addEventListener('mousedown', function(){ refuse = false; }, true);
 HTMLCanvasElement.prototype.requestPointerLock = function(){
  if(refuse || !window.lockOk){ document.dispatchEvent(new Event('pointerlockerror')); return Promise.reject(new Error('refused')); }
  if(held !== this) set(this); return Promise.resolve(); };
 document.exitPointerLock = function(){ if(held) set(null); };
 return 'stub'; })()"
	# A wheel event is one row of the palette, under the pointer; own prefabs come last
	down="[\"mouse\", 100, 400], [\"frames\", 2],"
	for _ in $(seq 25); do
		down="$down [\"wheel\", 100, 400, 100], [\"frames\", 1],"
	done
	cat > "$t/steps.json" <<J
[
	["nav", "\${URL}"],
	["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
	["eval", "$(echo "$stub" | tr "\n" " ")"],
	["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000],
	["selall"], ["frames", 2], ["type", "webboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "\${SETUP_CODE}"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Enter"], ["waitlog", "Joined as webboss", 30],
	["waitlog_any", "server window: the page ntfy", 30], ["frames", 3],
	["click", "Button", "Don't add"], ["frames", 3],
	["waitlog_any", "world_menu: the list shown, 0 worlds", 30], ["frames", 3],
	["click", "Button", "New project..."],
	["waitlog", "world_menu: the name screen shown", 10], ["frames", 3],
	["click", "Button", "Create"],
	["waitlog", "player physics enabled", 120],
	["waitlog_any", "pause: the menu shown", 10],
	["eval", "window.lockOk = true, 'lock given from here'"],
	["click", 100, 700], ["waitlog", "pause: the menu closed", 10], ["wait", 1000],
	["waitlog_any", "kit editor: edit rights: yes", 10],
	["key", "Escape"], ["waitlog", "pause: the menu shown", 10], ["frames", 3],
	["click", "Button", "Edit", 600, 339], ["waitlog", "kit editor: state: 1 entities", 20],
	["key", "F1"], ["waitlog", "kit editor: the view is 2D", 10], ["frames", 3],
	["click", "Button", "kit/environment"], ["waitlog", "the palette's menu of kit/environment", 10], ["frames", 3],
	["shot", "\${OUT}/menu_positionless.png"],
	["click", "Button", "Cancel"], ["frames", 3],
	$down
	["click", "Button", "[kit/hut]"], ["waitlog", "the palette's menu of .kit/hut", 10], ["frames", 3],
	["shot", "\${OUT}/menu_prefab.png"],
	["click", "Button", "Place"], ["waitlog", "kit editor: placing .kit/hut", 10],
	["click", 900, 550], ["waitlog", "kit editor: state: 2 entities, 1 to undo", 10],
	["click", 900, 550, 50, 2], ["waitlog", "kit editor: placing nothing", 10], ["frames", 3],
	["click", 900, 550], ["waitlog", "kit editor: selected 3", 10], ["frames", 3],
	["shot", "\${OUT}/root.png"],
	["click", "Button", "Refresh voxels"], ["waitlog", "kit editor: the stamp dialog of 3", 10], ["frames", 3],
	["shot", "\${OUT}/dialog_refresh.png"],
	["click", "Button", "Cancel"], ["waitlog", "kit editor: no stamp of 3", 10], ["frames", 3],
	["key", "Right"], ["waitlog", "kit editor: the stamp dialog of 3 after a move", 10], ["frames", 3],
	["shot", "\${OUT}/dialog_move.png"],
	["click", "Button", "Clear the old box, then stamp"], ["waitlog", "kit editor: stamp 3, clearing", 10], ["sync", 5000], ["frames", 3],
	["click", "Button", "Undo"], ["waitlog", "kit editor: state: 2 entities, 1 to undo", 10], ["frames", 3],
	["click", "Button", "kit/teleporter"], ["waitlog", "kit editor: placing kit/teleporter", 10],
	["click", 650, 700], ["waitlog", "kit editor: state: 3 entities, 2 to undo", 10],
	["click", 650, 700, 50, 2], ["waitlog", "kit editor: placing nothing", 10], ["frames", 3],
	["click", 650, 700], ["waitlog", "kit editor: selected 4", 10], ["frames", 3],
	["click", 650, 700, 50, 2], ["frames", 3], ["click", "Button", "Make prefab..."], ["frames", 5],
	["shot", "\${OUT}/make.png"],
	["click", 680, 400], ["frames", 2], ["type", "bar"], ["frames", 3],
	["shot", "\${OUT}/make_typed.png"],
	["click", "Button", "Save prefab"], ["waitlog", "kit editor: state: 3 entities, 3 to undo", 10], ["frames", 3],
	$down
	["click", "Button", "[webboss/bar]"], ["waitlog", "the palette's menu of .webboss/bar", 10], ["frames", 3],
	["click", "Button", "Rename"], ["frames", 3],
	["shot", "\${OUT}/rename.png"],
	["click", "LineEdit", "bar"], ["frames", 2], ["key", "End"], ["type", "2"], ["frames", 2],
	["click", "Button", "Rename it"], ["waitlog", "kit editor: rename webboss/bar to bar2", 10], ["sync", 5000], ["frames", 5],
	$down
	["click", "Button", "[webboss/bar2]"], ["waitlog", "the palette's menu of .webboss/bar2", 10], ["frames", 3],
	["click", "Button", "Delete", 214, 680], ["waitlog", "kit editor: delete webboss/bar2. 0 copies", 10], ["frames", 3],
	["shot", "\${OUT}/delete.png"],
	["click", "Button", "Delete it"], ["sync", 5000], ["frames", 3]
]
J
	"$here/util/web_drive.sh" "${WEB_BROWSER:-chrome}" workbench "$t/steps.json" "$t/out" ||
		fail "the web drive ($t/out)"
	for w in "placed prefab kit/hut as 3...3" "stamped kit/hut on 3" \
			"webboss renamed the prefab webboss/bar to webboss/bar2 (0 copies)" \
			"webboss deleted the prefab webboss/bar2"; do
		grep -aqF "$w" "$t/out/server.log" || fail "no \"$w\" in $t/out/server.log"
	done
	echo "PASS: a placed prefab's root in the web client: the palette's menus, the root, Refresh and a move's dialog, rename and delete"
	exit 0
fi
export BUILDAT_WORKBENCH_PROJECT=world
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_prefab_root; t=$CHECK_TMP
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
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x900 -l 3 \
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
undo_count() { printf 'wait_log 10000 entities, %d to undo\n' "$n"; }
# An edit and the undo count it leaves
edit() # <json>
{
	n=$((n + 1))
	ed "$1"
	undo_count
}
undo() # by the button
{
	n=$((n - 1))
	echo 'click Button "Undo"'
	undo_count
}
vox() # <x> <y> <z> <voxel>
{
	edit "{\"op\": \"set_voxel\", \"pos\": [$1, $2, $3], \"voxel\": \"$4\"}"
}
# A cell's voxel, asked now and compared at the end with the server's answer
cell() # <x> <y> <z> <voxel>
{
	ed "{\"op\": \"voxel_info\", \"pos\": [$1, $2, $3]}"
	echo "sync 5000"
	echo "($1,$2,$3): $4" >> "$cells"
}
cells_are() # <server log>
{
	grep -aoP 'Voxel at \K\([^:]*: [^,]*' "$1" | diff - "$cells" >&2 ||
		fail "the cells in $1, against $cells"
}
refused() # <json> <reason>
{
	ed "$1"
	printf 'wait_log 10000 %s\n' "$2"
}
sel() # <id>
{
	printf 'event kit_select %s\nframes 5\n' "$1"
}
# A click that makes one edit
clicked() # <button>
{
	n=$((n + 1))
	printf 'click Button "%s"\n' "$1"
	undo_count
}
# A palette prefab's menu
menu() # <label>
{
	# Own prefabs come last: the list scrolled to its end, however many
	# types
	echo "frames 2"
	echo "mouse_pos 100 400"
	for _ in $(seq 16); do
		printf 'mouse_wheel -1\nframes 1\n'
	done
	printf 'click Button "[%s]"\nwait_log 5000 the palette'"'"'s menu of [%s]\nframes 3\n' "$1" "$1"
}
# A move by the key, up to its dialog; then answer() it
key_move() # <id>
{
	n=$((n + 1))
	printf 'keypress Right\nwait_log 10000 kit editor: the stamp dialog of %s after a move\nframes 3\n' "$1"
}
# The dialog's answer that stamps: its undo goes with the move's when merged
answer_merged() # <button>
{
	printf 'click Button "%s"\nwait_log 10000 entities, %d to undo\nsync 5000\n' "$1" "$n"
}
joined()
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
EOF
}
db_of()
{
	find "$t/user" -name save.sqlite -path "*/saves/world/*" | head -1
}
# ---- 1
cells=$t/cells1
: > "$cells"
A=9 B=12 STEP=17 BD=18 PIE=21
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
	edit '{"op": "place", "type": "kit/terrain", "pos": [0, 1, 0]}'
	edit '{"op": "set", "id": 3, "comp": 0, "param": "biome", "value": "grassland"}'
	echo "wait_log_any 30000 kit: World: generated again"
	vox 3 1 3 kit/stone
	vox 4 1 3 kit/planks
	edit '{"op": "place", "type": "kit/gate", "pos": [3, 1, 4]}'
	edit '{"op": "place", "type": "kit/button", "pos": [4, 1, 4]}'
	edit '{"op": "link", "id": 5, "comp": 0, "output": "pressed", "to": 4, "input": "open"}'
	edit '{"op": "save_prefab", "ids": [4, 5], "box": [3, 1, 3, 4, 2, 4], "name": "hut"}'
	# The palette's menu arms it; a click in the view places it; undone whole
	cat <<'EOF'
keypress F1
wait_log 5000 kit editor: the view is 2D
frames 3
EOF
	menu kitboss/hut
	echo "screenshot $t/palette_menu.png"
	cat <<'EOF'
click Button "Place"
wait_log 5000 kit editor: placing [kitboss/hut]
mouse_pos 614 306
mouse_click left
EOF
	n=$((n + 1))
	undo_count
	cat <<'EOF'
mouse_click right
wait_log 5000 kit editor: placing nothing
frames 3
EOF
	undo
	# Two copies
	edit '{"op": "place", "prefab": "kitboss/hut", "pos": [10, 1, 3]}'
	edit '{"op": "place", "prefab": "kitboss/hut", "pos": [20, 1, 3]}'
	cell 10 1 3 kit/stone
	cell 11 1 3 kit/planks
	# A parameter on the first's gate: its mark
	edit "{\"op\": \"set\", \"id\": $((A + 1)), \"comp\": 0, \"param\": \"material\", \"value\": \"kit/stone\"}"
	sel $((A + 1))
	echo "screenshot $t/override.png"
	# The second gains a door and a link, and is saved by its inspector
	edit "{\"op\": \"place\", \"type\": \"kit/door\", \"pos\": [22, 1, 5], \"parent\": $B}"
	D=$((B + 3))
	edit "{\"op\": \"link\", \"id\": $((B + 2)), \"comp\": 0, \"output\": \"pressed\", \"to\": $D, \"input\": \"toggle\"}"
	sel $B
	echo "screenshot $t/root.png"
	clicked "Save to prefab"
	echo "sync 5000"
	# The override stays: its mark, and Reset
	sel $((A + 1))
	echo "screenshot $t/override_kept.png"
	clicked "Reset material"
	# Voxels alone and no place have a root too; Kit's are not saved over;
	# a stamp takes quarters
	edit '{"op": "save_prefab", "box": [3, 1, 3, 4, 1, 3], "name": "step"}'
	edit '{"op": "place", "prefab": "kitboss/step", "pos": [50, 1, 3]}'
	edit '{"op": "place", "prefab": "kit/button_door", "pos": [55, 1, 3]}'
	edit '{"op": "place", "prefab": "kit/timer_pie", "pos": [0, 0, 0]}'
	refused "{\"op\": \"save_prefab\", \"root\": $BD}" "kit/button_door is Kit's"
	edit "{\"op\": \"move\", \"id\": $B, \"pos\": [20, 1, 3], \"yaw\": 45}"
	refused "{\"op\": \"stamp\", \"id\": $B}" "entity $B is turned 45"
	edit "{\"op\": \"move\", \"id\": $B, \"pos\": [20, 1, 3], \"yaw\": 0}"
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
grep -a "prefab\|An undo\|reset " "$s" | sed 's/^.*kit *: /  /' | cut -c1-170
cells_are "$s"
want "$s" "placed prefab kitboss/hut as $A...$((A + 2)), 2 voxels written" \
	"saved prefab kitboss/hut version 2 of 3 entities and a box of [2,2,2] voxels, built $A again: 3 children (2 kept, 1 new, 0 gone, 1 overrides kept) (1 other copies follow it)" \
	"reset $((A + 1))'s kit/gate material to the prefab's"
want "$t/boss1.log" "entity $B is turned 45: voxels go by multiples of 90"
db=$(db_of)
[ -n "$db" ] || fail "no save.sqlite under $t/user"
python3 - "$db" "$A" "$B" "$STEP" "$PIE" <<'PY' || fail "the copies in the save ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
A, B, STEP, PIE = map(int, sys.argv[2:])
row = lambda k: json.loads(db.execute("select value from store where store='kit' and key=?", (k,)).fetchone()[0])
ents = {e["id"]: e for e in row("authored")["entities"]}
def links(i):
	return sorted((l["output"], l["to"], l["input"]) for l in ents[i]["components"][0].get("links", []))
for r, x in ((A, 10), (B, 20)):
	e = ents[r]
	assert e["components"][0]["type"] == "kit/prefab_copy", e
	assert e["prefab"]["of"] == "kitboss/hut" and e["prefab"]["version"] == 2, e
	# The saved one's box as it stood, the world's grass in it: a new voxels
	# version; the other's stamp is behind
	assert e["prefab"]["voxels"] == (1 if r == A else 2), e
	assert e["pos"] == [x, 1, 3], e
	assert "built" not in e, e
door = {A: A + 7, B: B + 3}
for r in (A, B):
	assert [ents[i]["built"]["by"] for i in (r + 1, r + 2, door[r])] == [r] * 3
	assert [ents[i]["parent"] for i in (r + 1, r + 2, door[r])] == [r] * 3
	assert ents[door[r]]["pos"] == [2, 0, 2], ents[door[r]]
	assert ents[door[r]]["components"][0]["type"] == "kit/door"
	assert links(r + 2) == [("pressed", r + 1, "open"), ("pressed", door[r], "toggle")], links(r + 2)
g = ents[A + 1]["components"][0]
assert "overrides" not in g and g.get("params", {}).get("material", "") == "", g
hut = row("prefab:kitboss/hut")
assert hut["version"] == 2 and len(hut["entities"]) == 3 and hut["voxels_version"] == 2, hut
assert "prefab" not in ents[4] and "built" not in ents[4], ents[4]
step = ents[STEP]
assert step["prefab"]["of"] == "kitboss/step" and step["prefab"]["voxels"] == 1, step
assert not [e for e in ents.values() if e["parent"] == STEP]
pie = ents[PIE]
assert pie["prefab"]["of"] == "kit/timer_pie" and "pos" not in pie, pie
assert [e for e in ents.values() if e["parent"] == PIE], "the pie's members"
assert ents[B].get("yaw", 0) == 0
PY
echo "ok: the palette's menu places; a member's parameter marked; a save by the inspector: the other copy gains door and link and keeps its parameter; Reset; voxels alone and no place have roots; Kit's save and a turn off the quarters refused"

# ---- 2
cells=$t/cells2
: > "$cells"
next=$(grep -aoP 'placed prefab kit/timer_pie as \d+\.\.\.\K\d+' "$s")
[ -n "$next" ] || fail "no timer_pie's ids in $s"
C=$((next + 1)) E=$((next + 5))
n=0
{
	joined
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: state:
sync 5000
keypress F1
wait_log 5000 kit editor: the view is 2D
frames 3
EOF
	# A turned copy: the box in the world's, a cell added, saved in the prefab's
	edit '{"op": "place", "prefab": "kitboss/hut", "pos": [30, 1, 3], "turn": 90}'
	cell 30 1 3 kit/stone
	cell 30 1 2 kit/planks
	cell 31 2 3 air
	vox 31 2 3 kit/planks
	echo "event kit_select $C"
	echo "wait_log 5000 kit editor: the box of the copy $C 30,1,2 31,2,3"
	echo "frames 3"
	clicked "Save to prefab"
	echo "sync 5000"
	edit '{"op": "place", "prefab": "kitboss/hut", "pos": [5, 1, 8]}'
	cell 5 2 9 kit/planks
	cell 6 1 8 kit/planks
	# The outline, from above and from the walk's eye
	echo "event kit_select $E"
	echo "wait_log 5000 kit editor: the box of the copy $E 5,1,8 6,2,9"
	echo "frames 3"
	echo "screenshot $t/box_2d.png"
	cat <<'EOF'
keypress F3
wait_log 5000 kit editor: the view is
frames 5
EOF
	echo "screenshot $t/box_walk.png"
	cat <<'EOF'
keypress F1
wait_log 5000 kit editor: the view is 2D
frames 3
EOF
	# Its voxels behind; Refresh's three answers; a stone where the prefab has air
	cell 10 2 4 air
	vox 11 2 4 kit/stone
	echo "event kit_select $A"
	echo "wait_log 5000 kit editor: the box of the copy $A 10,1,3 11,2,4"
	echo "frames 3"
	echo "screenshot $t/behind.png"
	refresh()
	{
		echo 'click Button "Refresh voxels"'
		echo "wait_log 5000 kit editor: the stamp dialog of $A"
		echo "frames 3"
	}
	refresh
	echo "screenshot $t/dialog_refresh.png"
	echo 'click Button "Cancel"'
	echo "wait_log 5000 kit editor: no stamp of $A"
	cell 10 2 4 air
	refresh
	clicked "Stamp without clearing"
	cell 10 2 4 kit/planks
	cell 11 2 4 kit/stone
	undo
	cell 10 2 4 air
	refresh
	clicked "Clear the old box, then stamp"
	cell 10 2 4 kit/planks
	cell 11 2 4 air
	undo
	cell 10 2 4 air
	cell 11 2 4 kit/stone
	# A turned one's Refresh
	sel $C
	echo 'click Button "Refresh voxels"'
	echo "wait_log 5000 kit editor: the stamp dialog of $C"
	echo "frames 3"
	clicked "Clear the old box, then stamp"
	cell 30 1 3 kit/stone
	cell 31 2 3 kit/planks
	# A move: B's by the key
	sel $B
	key_move $B
	echo "screenshot $t/dialog_move.png"
	echo 'click Button "Leave the voxels"'
	echo "wait_log 5000 kit editor: no stamp of $B"
	cell 20 1 3 kit/stone
	cell 22 2 4 air
	key_move $B
	answer_merged "Stamp without clearing"
	cell 22 1 3 kit/stone
	cell 23 1 3 kit/planks
	cell 22 2 4 kit/planks
	cell 20 1 3 kit/stone
	vox 22 2 3 kit/stone
	key_move $B
	answer_merged "Clear the old box, then stamp"
	cell 22 1 3 air
	cell 22 2 3 air
	cell 23 1 3 kit/stone
	cell 24 1 3 kit/planks
	cell 23 2 4 kit/planks
	# One undo for the move and its stamp; no dialog
	undo
	cell 22 1 3 kit/stone
	cell 22 2 3 kit/stone
	cell 23 2 4 air
	# A turn off the quarters: said, no dialog
	n=$((n + 1))
	cat <<EOF
keypress z
wait_log 5000 kit editor: The voxels stay: turned
EOF
	undo
	# ---- 3: the palette's menu
	ed '{"op": "item", "name": "lookitem", "preset": "kit/sword", "look": "kitboss/hut"}'
	echo "sync 5000"
	# Nothing selected: the inspector's own Delete is out of the way
	echo "mouse_pos 700 800"
	echo "mouse_click left"
	echo "frames 3"
	refused '{"op": "prefab_rename", "name": "kitboss/hut", "to": "step"}' "there is a prefab kitboss/step already"
	refused '{"op": "prefab_rename", "name": "kit/hut", "to": "x"}' "kit/hut is"
	refused '{"op": "prefab_delete", "name": "kit/hut"}' "kit/hut is"
	menu kitboss/hut
	cat <<EOF
click Button "Rename"
frames 3
screenshot $t/rename.png
click LineEdit "hut"
keypress End
keypress Backspace
keypress Backspace
keypress Backspace
text shed
frames 2
click Button "Rename it"
wait_log 5000 kit editor: rename kitboss/hut to shed
sync 5000
frames 5
EOF
	menu kitboss/shed
	cat <<EOF
click Button "Delete"
wait_log 5000 kit editor: delete kitboss/shed? 4 copies
frames 3
click Button "Delete it"
wait_log 5000 kitboss/shed is the look of the item kitboss/lookitem
EOF
	ed '{"op": "item_delete", "name": "kitboss/lookitem"}'
	echo "sync 5000"
	menu kitboss/shed
	cat <<EOF
click Button "Delete"
wait_log 5000 kit editor: delete kitboss/shed? 4 copies
frames 3
screenshot $t/delete.png
click Button "Delete it"
wait_log 5000 kit editor: delete kitboss/shed
sync 5000
frames 5
EOF
	# A copy with no prefab: it says so, no dialog on a move, Detach, Save
	refused "{\"op\": \"stamp\", \"id\": $A}" "the prefab kitboss/shed is gone"
	sel $A
	echo "screenshot $t/deleted_root.png"
	n=$((n + 1))
	printf 'keypress Right\nwait_log 10000 entities, %d to undo\n' "$n"
	sel $B
	clicked "Detach"
	echo "sync 5000"
	sel $A
	clicked "Save to prefab"
	echo "sync 5000"
	# Delete of a root takes its entities; the voxels stay
	edit "{\"op\": \"delete\", \"id\": $C}"
	cell 30 1 3 kit/stone
	echo "frames 3"
	echo quit
} > "$t/boss2.cmds"
server 2
BUILDAT_JOIN_CREATE= client boss2
stop
s=$t/srv2.log
grep -a "prefab\|An undo\|stamped\|detached" "$s" | sed 's/^.*kit *: /  /' | cut -c1-170
cells_are "$s"
want "$s" "saved prefab kitboss/hut version 3 of 3 entities and a box of [2,2,2] voxels" "(2 other copies follow it)" \
	"kitboss renamed the prefab kitboss/hut to kitboss/shed (4 copies)" \
	"kitboss deleted the prefab kitboss/shed" \
	"detached 3 entities from the copy $B of kitboss/shed" \
	"saved prefab kitboss/shed version 4 of 3 entities"
[ "$(grep -acE "I kit +: kit editor: the stamp dialog of $B after a move" "$t/boss2.log")" = 3 ] ||
	fail "the move's dialog not three times: an undo or a dead prefab's move showed it ($t/boss2.log)"
[ "$(grep -acE "I kit +: kit editor: the stamp dialog of $A after a move" "$t/boss2.log")" = 0 ] ||
	fail "a move of a dead prefab's copy showed the dialog ($t/boss2.log)"
db=$(db_of)
python3 - "$db" "$A" "$B" "$C" "$E" <<'PY' || fail "the copies in the save ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
A, B, C, E = map(int, sys.argv[2:])
row = lambda k: json.loads(db.execute("select value from store where store='kit' and key=?", (k,)).fetchone()[0])
keys = [r[0] for r in db.execute("select key from store where store='kit'")]
ents = {e["id"]: e for e in row("authored")["entities"]}
assert "prefab:kitboss/hut" not in keys, keys
shed = row("prefab:kitboss/shed")
assert shed["version"] == 4 and shed["name"] == "shed", shed
# The turned copy's cell back in the prefab's frame
# Back with no box: its entities alone
assert "voxels" not in shed, shed
# Detached: root gone, members plain, under its parent, where they were
assert B not in ents, ents.get(B)
up = ents[A]["parent"]
for i in (B + 1, B + 2, B + 3):
	assert ents[i]["parent"] == up and "built" not in ents[i], ents[i]
assert ents[B + 3]["pos"] == [24, 1, 5], ents[B + 3]
# Deleted root: its entities gone
assert C not in ents and C + 1 not in ents, ents.get(C)
# The rest follow the rename; A saved
assert ents[A]["prefab"]["of"] == "kitboss/shed" and ents[A]["prefab"]["version"] == 4, ents[A]
assert ents[A]["pos"] == [11, 1, 3], ents[A]
assert ents[E]["prefab"]["of"] == "kitboss/shed", ents[E]
PY
# An item whose look is the prefab: a pickup of it gains no root, its own row alone
n=0
{
	joined
	echo "keypress F6"
	echo "wait_log_any 10000 kit editor: state:"
	ed '{"op": "item", "name": "lookitem2", "preset": "kit/sword", "look": "kitboss/shed"}'
	echo "sync 5000"
	edit '{"op": "place", "type": "kit/pickup", "pos": [40, 1, 40], "params": {"item": "kitboss/lookitem2"}}'
	printf 'frames 5\nquit\n'
} > "$t/boss3.cmds"
server 3
BUILDAT_JOIN_CREATE= client boss3
stop
python3 - "$(db_of)" <<'PY' || fail "the pickup of an item with a prefab's look"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
ents = json.loads(db.execute("select value from store where store='kit' and key='authored'").fetchone()[0])["entities"]
p = [e for e in ents if e.get("pos") == [40, 1, 40]]
assert len(p) == 1 and p[0]["components"][0]["type"] == "kit/pickup", p
assert "prefab" not in p[0], p
assert not [e for e in ents if e.get("parent") == p[0]["id"]], ents
PY
echo "ok: a turned copy saved in the prefab's frame; Refresh and a move with each answer, undone in one; the box; rename, delete with copies, detach, save brings it back"
echo "PASS: a placed prefab's root: copies follow by rebuild keeping their parameters, Save to prefab and Reset from the inspector, Refresh and a move's one dialog with each answer, undo in one, a turned copy's voxels, the palette's Rename and Delete, Detach; the refusals"
# vim: set noet ts=4 sw=4:
