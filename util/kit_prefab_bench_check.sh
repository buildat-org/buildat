#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-06)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua builtin/kit/client_lua/prefabs.lua apps/workbench/**
# [KIT_PREFAB_BENCH] A prefab edited in its temporary scene, by the palette's
# menu. A fresh save on Workbench, the admin Ended, a World; prefab kitboss/hut
# (a gate, two voxels in a 2x2x2 box), a copy at (10,1,3), a stone beside the
# original.
#   1. Edit: the scene empty but for one copy at the origin, the bar, the box's
#      handles. A voxel set and undone, a voxel set and the box's +x face dragged
#      over another; Save: version 2 of a 3x2x2 box and nothing else. Refused
#      there: exports, another bench. Close: back where they were, the project's
#      entities and voxels intact, its undo its own; the copy behind by "voxels
#      v1, prefab v2", and its Refresh matches. Close asks only when unsaved.
#      Kit's prefab has no Edit. An export has nothing of it.
#   2. Two builders each in a bench at once, one's stone not in the other's; a
#      restart with both open: no scene, no rows left. The save has one scene.
# Screenshots kept with KEEP_TMP=1: $t/*.png
#   util/kit_prefab_bench_check.sh
#   util/kit_prefab_bench_check.sh web    the same Edit in headless Chrome
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
if [ "${1:-}" = web ]; then
	# The web client (web/) at 1200x800, the mouse only: kit/hut placed, a prefab
	# of one's own made of it; Edit by its menu, the box's +x handle dragged, Save,
	# Close: no question (saved), back in the project with its undo
	export BUILDAT_WORKBENCH_STONE=1
	check_tmp kit_prefab_bench_web; t=$CHECK_TMP
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
	$down
	["click", "Button", "[kit/hut]"], ["waitlog", "the palette's menu of .kit/hut", 10], ["frames", 3],
	["shot", "\${OUT}/menu_kit.png"],
	["click", "Button", "Cancel"], ["frames", 3],
	["key", "b"], ["frames", 3],
	["click", 540, 360], ["frames", 3], ["click", 566, 340], ["frames", 5],
	["shot", "\${OUT}/box.png"],
	["click", "Button", "Make prefab..."], ["frames", 5],
	["click", 680, 400], ["frames", 2], ["type", "bar"], ["frames", 3],
	["shot", "\${OUT}/make.png"],
	["click", "Button", "Save prefab"], ["waitlog", "entities, 1 to undo", 10], ["frames", 3],
	["click", "Button", "Components"], ["frames", 3],
	$down
	["click", "Button", "[webboss/bar]"], ["waitlog", "the palette's menu of .webboss/bar", 10], ["frames", 3],
	["shot", "\${OUT}/menu_own.png"],
	["click", "Button", "Edit"], ["waitlog", "kit editor: editing the prefab webboss/bar", 10],
	["waitlog", "the prefab's voxels are in", 30], ["frames", 10],
	["shot", "\${OUT}/bench.png"],
	["mouse", 795, 420], ["frames", 3],
	["drag", 795, 420, 860, 420],
	["waitlog", "face .x by", 10], ["frames", 5],
	["shot", "\${OUT}/adjusted.png"],
	["click", "Button", "Save"], ["sync", 5000], ["frames", 5],
	["shot", "\${OUT}/saved.png"],
	["click", "Button", "Close"], ["waitlog", "kit editor: the prefab's scene closed", 10], ["frames", 60],
	["shot", "\${OUT}/after.png"],
	["click", "Button", "Undo"], ["waitlog", "entities, 0 to undo", 10], ["frames", 3]
]
J
	"$here/util/web_drive.sh" chrome workbench "$t/steps.json" "$t/out" ||
		fail "the web drive ($t/out)"
	for w in "Session 1 (a bench) by webboss" "saved prefab webboss/bar version 2" \
			"Session 1 ended by webboss"; do
		grep -aqF "$w" "$t/out/server.log" || fail "no \"$w\" in $t/out/server.log"
	done
	grep -aE "saved prefab webboss/bar version 2 .*a box of .1[5-9],1,11" "$t/out/server.log" >/dev/null ||
		fail "the handle's box did not reach Save ($t/out/server.log)"
	echo "PASS: a prefab's temporary scene in the web client: Edit by the menu, the box's handle, Save, Close"
	exit 0
fi
export BUILDAT_WORKBENCH_PROJECT=world
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_prefab_bench; t=$CHECK_TMP
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
		[ "${2:-}" = killed ] ||
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
edit() # <json>
{
	n=$((n + 1))
	ed "$1"
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
	# (undefined: a cell the empty World's generator wrote nothing in)
	grep -aoP 'Voxel at \K\([^:]*: [^,]*' "$1" | sed 's/undefined$/air/' |
			diff - "$cells" >&2 ||
		fail "the cells in $1, against $cells"
}
menu() # <label>: a palette prefab's menu
{
	# Own prefabs come last: the list scrolled to its end
	echo "frames 2"
	echo "mouse_pos 100 400"
	for _ in 1 2 3 4 5 6 7 8; do
		printf 'mouse_wheel -1\nframes 1\n'
	done
	printf 'click Button "[%s]"\nwait_log 5000 the palette'"'"'s menu of [%s]\nframes 3\n' "$1" "$1"
}
into_bench() # <prefab>
{
	menu "$1"
	printf 'click Button "Edit"\nwait_log 10000 kit editor: editing the prefab %s\nwait_log 30000 the prefab'"'"'s voxels are in\nframes 5\n' "$1"
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
drag() # <handle> <x> <y> <dx> <dy>...: the pointer's steps
{
	local name=$1 x=$2 y=$3
	shift 3
	printf 'event kit_box_where %s\nwait_log_any 5000 kit editor: box handle %s on the screen at %d, %d\n' "$name" "$name" "$x" "$y"
	printf 'mouse_pos %d %d\nframes 2\nmouse_down left\nwait_log 5000 kit editor: box handle %s\n' "$x" "$y" "$name"
	while [ $# -ge 2 ]; do
		printf 'mouse_pos %d %d\nframes 2\n' $((x + $1)) $((y + $2))
		shift 2
	done
	echo "mouse_up left"
}
closed() # back in the project, its undo count $1
{
	printf 'wait_log 10000 kit editor: the prefab'"'"'s scene closed\n'
	n=$1
	printf 'wait_log_any 10000 entities, %d to undo\nframes 5\n' "$n"
}
# ---- 1
cells=$t/cells1
: > "$cells"
A=5 B=7
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
	vox 3 1 3 kit/stone
	vox 4 1 3 kit/planks
	edit '{"op": "place", "type": "kit/gate", "pos": [3, 1, 4]}'
	edit '{"op": "save_prefab", "ids": [4], "box": [3, 1, 3, 4, 2, 4], "name": "hut"}'
	vox 5 1 3 kit/stone
	edit '{"op": "place", "prefab": "kitboss/hut", "pos": [10, 1, 3]}'
	edit '{"op": "place", "prefab": "kitboss/hut", "pos": [20, 1, 3]}'
	cell 10 1 3 kit/stone
	cell 12 1 3 air
	cat <<EOF
keypress F2
wait_log 5000 kit editor: the view is 3D
event kit_cam3d 7.5 8 -4 7.5 1 3
frames 5
screenshot $t/before.png
EOF
	# Kit's prefab: no Edit in its menu
	menu kit/hut
	echo "screenshot $t/menu_kit.png"
	echo 'click Button "Cancel"'
	echo "frames 3"
	ed '{"op": "prefab_bench", "prefab": "kit/hut"}'
	echo "wait_log 10000 kit editor: refused: prefab_bench: kit/hut is not yours"
	n0=$n
	n=0
	menu kitboss/hut
	echo "screenshot $t/menu_own.png"
	cat <<'EOF'
click Button "Edit"
wait_log 10000 kit editor: editing the prefab kitboss/hut
wait_log 30000 the prefab's voxels are in
frames 5
EOF
	echo "screenshot $t/bench.png"
	# Empty but for the copy
	cell 0 0 0 kit/stone
	cell 1 0 0 kit/planks
	cell 2 0 0 air
	cell 0 -1 0 air
	cell 3 0 3 air
	# A voxel and its undo, here
	vox 1 1 0 kit/stone
	cell 1 1 0 kit/stone
	n=$((n - 1))
	echo 'click Button "Undo"'
	undo_count
	cell 1 1 0 air
	# Refused here
	ed '{"op": "export"}'
	echo "wait_log 10000 kit editor: refused: export: editing a prefab"
	ed '{"op": "prefab_bench", "prefab": "kitboss/hut"}'
	echo "wait_log 10000 kit editor: refused: prefab_bench: editing a prefab"
	# A stone outside its box; the box's +x face dragged over it
	vox 2 0 0 kit/stone
	drag +x 568 393 30 0 64 0
	echo "wait_log 5000 kit editor: box 0,0,0,2,1,1 (face +x"
	echo "frames 3"
	echo "screenshot $t/box_adjusted.png"
	n=$((n + 1))
	echo 'click Button "Save"'
	undo_count
	echo "sync 5000"
	echo "frames 3"
	echo "screenshot $t/saved.png"
	# All that was done here undone, as far as it goes: nothing of the project's
	for _ in 1 2; do
		n=$((n - 1))
		echo 'click Button "Undo"'
		undo_count
	done
	cell 2 0 0 air
	# Close: no question after those? Undo is an edit: it asks
	echo 'click Button "Close"'
	echo "wait_log 5000 kit editor: close unsaved?"
	echo "frames 3"
	echo "screenshot $t/close_unsaved.png"
	echo 'click Button "Keep editing"'
	echo "frames 3"
	cell 0 0 0 kit/stone
	echo 'click Button "Close"'
	echo "wait_log 5000 kit editor: close unsaved?"
	echo "frames 3"
	echo 'click Button "Close it"'
	closed "$n0"
	cat <<EOF
event kit_cam_where after
wait_log_any 5000 kit editor: the 3D camera at 7.50 8.00 -4.00 (after)
EOF
	# The project as it was; the copies behind
	cell 3 1 3 kit/stone
	cell 5 1 3 kit/stone
	cell 10 1 3 kit/stone
	cell 12 1 3 air
	echo "frames 60"
	echo "screenshot $t/after.png"
	printf 'event kit_select %d\nwait_log_any 5000 kit editor: voxels v1, prefab v2\nframes 5\n' "$A"
	echo "screenshot $t/behind.png"
	# Refresh matches the box saved
	cat <<'EOF'
click Button "Refresh voxels"
wait_log 10000 kit editor: the stamp dialog of
frames 3
EOF
	n=$((n + 1))
	printf 'click Button "Stamp without clearing"\nwait_log 10000 entities, %d to undo\nsync 5000\n' "$n"
	echo "frames 5"
	echo "screenshot $t/refreshed.png"
	cell 10 1 3 kit/stone
	cell 11 1 3 kit/planks
	cell 12 1 3 kit/stone
	# The project's undo: that stamp, then its own edits; never the bench's
	n=$((n - 1))
	echo 'click Button "Undo"'
	undo_count
	cell 12 1 3 air
	cell 11 1 3 kit/planks
	n=$((n - 1))
	echo 'click Button "Undo"'
	undo_count
	# (the second copy gone, the first still; placed again for what follows)
	cell 20 1 3 air
	cell 10 1 3 kit/stone
	edit '{"op": "place", "prefab": "kitboss/hut", "pos": [20, 1, 3]}'
	cell 22 1 3 kit/stone
	# A second visit: the box as saved, the scene new; nothing to ask at Close
	n1=$n
	n=0
	menu kitboss/hut
	cat <<'EOF'
click Button "Edit"
wait_log 10000 kit editor: editing the prefab kitboss/hut
wait_log 30000 the prefab's voxels are in
frames 5
EOF
	cell 2 0 0 kit/stone
	cell 1 1 0 air
	# Walking there
	cat <<EOF
keypress F3
wait_log 5000 kit editor: the view is
frames 60
screenshot $t/walk.png
keypress F2
wait_log 5000 kit editor: the view is 3D
EOF
	echo 'click Button "Close"'
	closed "$n1"
	ed '{"op": "sessions"}'
	echo "sync 5000"
	# Published: its package
	ed '{"op": "export"}'
	echo "sync 5000"
	echo "quit"
} > "$t/boss1.cmds"
server 1
wait_for_log "$t/srv1.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv1.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss1
# (an ended session's scene goes 2 s after; a stop before that is part 2's case)
wait_for_log "$t/srv1.log" "Session scene world~2 dropped" 10
stop
s=$t/srv1.log
grep -a "Session \|session \|prefab \|An undo\|exports\|follow" "$s" | sed 's/^.*\(kit\|main\) *: /  /' | cut -c1-170
cells_are "$s"
want "$s" "Session 1 (a bench) by kitboss: 3 entities from the start" \
	"The prefab kitboss/hut's voxels laid out in session 1: 2" \
	"saved prefab kitboss/hut version 2 of 1 entities and a box of [3,2,2] voxels" \
	"The project's copies of kitboss/hut follow:" "2 other copies follow it" \
	"Session scene world~1 dropped" "kitboss to scene world" \
	"Session 2 (a bench) by kitboss" "kitboss exports"
grep -a "Sessions: " "$s" | tail -1 | grep -aq '"kind":"bench"' &&
	fail "a bench left after its Close ($s)"
want "$t/boss1.log" "kit editor: bar: Menu (Esc) 14,10; Save" "; Close "
[ "$(grep -ac "saved prefab kitboss/hut version 3" "$s")" = 0 ] ||
	fail "the unsaved Close saved a version ($s)"
db=$(db_of)
[ -n "$db" ] || fail "no save.sqlite under $t/user"
python3 - "$db" "$A" <<'PY' || fail "the save after Close ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
A = int(sys.argv[2])
row = lambda k: json.loads(db.execute("select value from store where store='kit' and key=?", (k,)).fetchone()[0])
hut = row("prefab:kitboss/hut")
v = hut["voxels"]
assert hut["version"] == 2 and hut["voxels_version"] == 2, hut
assert v["size"] == [3, 2, 2] and v["at"] == [0, 0, 0], v
assert len(hut["entities"]) == 1, hut["entities"]
names = [k[0] for k in v["kinds"]]
assert sorted(names) == ["air", "kit/planks", "kit/stone"], names
assert v["runs"][:6] == [1, names.index("kit/stone"), 1, names.index("kit/planks"), 1, names.index("kit/stone")], v["runs"]
ents = {e["id"]: e for e in row("authored")["entities"]}
scenes = [e for e in ents.values() if e.get("kind") == "scene"]
assert [e["name"] for e in scenes] == ["world"], scenes
assert ents[A]["prefab"]["version"] == 2 and ents[A]["prefab"]["voxels"] == 1, ents[A]
assert ents[A]["pos"] == [10, 1, 3], ents[A]
assert row("sessions")["live"] == [], row("sessions")
n = db.execute("select count(*) from store where store='voxelworld' and key like 'scene_world~%'").fetchone()[0]
assert n == 0, n
print("  the save: hut v2 %s; copy %d follows at v2, voxels v1; one scene; no rows" % (v["size"], A))
PY
echo "ok: Edit by the menu, the empty scene, a voxel and the box's handle, Save; Close back with the project intact, the copy behind, its Refresh matching, the undo histories apart, Close asking when unsaved"
# ---- 2: two builders, and a restart with both open
ed2() { printf 'event kit_edit %s\n' "$1"; }
cat > "$t/boss2.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log_any 10000 kit editor: state:
wait_log_any 30000 kit editor: people: kitbob
EOF
{
	menu kitboss/hut
	cat <<'EOF'
click Button "Edit"
wait_log 10000 kit editor: editing the prefab kitboss/hut
wait_log 30000 the prefab's voxels are in
event kit_edit {"op": "set_voxel", "pos": [0, 3, 0], "voxel": "kit/stone"}
wait_log 10000 entities, 1 to undo
event kit_edit {"op": "builder", "name": "kitbob", "on": true}
wait_log 100000 no such line: the check takes this client down
EOF
} >> "$t/boss2.cmds"
{
	# (the rights come after kitboss's stone in kitboss's bench: its voxel_info
	# below reads a stone that is there, in the other scene)
	cat <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 60000 kit editor: edit rights: yes
keypress F6
wait_log_any 10000 kit editor: state:
EOF
	ed2 '{"op": "save_prefab", "box": [3, 1, 3, 4, 1, 3], "name": "step"}'
	echo "wait_log 10000 entities, 1 to undo"
	echo "sync 5000"
	# Not another's scene, not by a name
	ed2 '{"op": "scene", "name": "world~3"}'
	echo "wait_log 10000 kit editor: refused: scene: no scene world~3"
	ed2 '{"op": "prefab_bench", "prefab": "kitboss/hut"}'
	echo "wait_log 10000 kit editor: refused: prefab_bench: kitboss/hut is not yours"
	menu kitbob/step
	cat <<EOF
click Button "Edit"
wait_log 10000 kit editor: editing the prefab kitbob/step
wait_log 30000 the prefab's voxels are in
frames 5
screenshot $t/bob_bench.png
EOF
	ed2 '{"op": "voxel_info", "pos": [0, 3, 0]}'
	echo "sync 5000"
	echo "wait_log 100000 no such line: the check takes this client down"
} > "$t/bob2.cmds"
server 2
( BUILDAT_JOIN_NAME=kitboss client boss2 killed ) &
( BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 client bob2 killed ) &
s=$t/srv2.log
wait_for_log "$s" "kitbob edits the prefab kitbob/step in session" 120 ||
	fail "kitbob's bench ($s, $t/bob2.log, $t/boss2.log)"
wait_for_log "$s" "Voxel at .0,3,0.: (air|undefined)" 30 ||
	fail "kitbob's scene has kitboss's voxel, or no answer ($s)"
stop
for p in $(check_pgrep buildat); do
	kill -9 "$p" 2>/dev/null
done
wait 2>/dev/null
want "$s" "Session 3 (a bench) by kitboss" "Session 4 (a bench) by kitbob" \
	"A voxel edit by kitboss: placed kit/stone at (0,3,0)"
db=$(db_of)
python3 - "$db" <<'PY' || fail "the save with two open ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
row = lambda k: json.loads(db.execute("select value from store where store='kit' and key=?", (k,)).fetchone()[0])
assert sorted(row("sessions")["live"]) == ["world~3", "world~4"], row("sessions")
scenes = [e["name"] for e in row("authored")["entities"] if e.get("kind") == "scene"]
assert scenes == ["world"], scenes
PY
# ---- 3: the next start: no scene, no rows
: > "$t/cells3"
cells=$t/cells3
{
	joined
	cat <<'EOF'
keypress F6
wait_log_any 10000 kit editor: state:
EOF
	cell 12 1 3 air
	cell 3 1 3 kit/stone
	menu kitboss/hut
	cat <<'EOF'
click Button "Edit"
wait_log 10000 kit editor: editing the prefab kitboss/hut
wait_log 30000 the prefab's voxels are in
frames 5
EOF
	# kitboss's stone of the last run is gone with its scene
	cell 0 3 0 air
	echo 'click Button "Close"'
	echo "wait_log 10000 kit editor: the prefab's scene closed"
	echo "quit"
} > "$t/boss3.cmds"
server 3
BUILDAT_JOIN_NAME=kitboss client boss3
wait_for_log "$t/srv3.log" "Session scene world~5 dropped" 10
stop
s=$t/srv3.log
cells_are "$s"
want "$s" "Sessions: 2 scenes of sessions before the restart dropped" \
	"workbench: scene world~3 dropped" "workbench: scene world~4 dropped"
db=$(db_of)
python3 - "$db" <<'PY' || fail "the save after the restart ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
row = lambda k: json.loads(db.execute("select value from store where store='kit' and key=?", (k,)).fetchone()[0])
assert row("sessions")["live"] == [], row("sessions")
n = db.execute("select count(*) from store where store='voxelworld' and key like 'scene_world~%'").fetchone()[0]
assert n == 0, n
scenes = [e["name"] for e in row("authored")["entities"] if e.get("kind") == "scene"]
assert scenes == ["world"], scenes
PY
echo "ok: two builders each in a bench; a restart with both open: no scene, no rows"
grep -a "CVoxelRegistry::get(): name=" "$t"/srv*.log | head -3 | grep . &&
	fail "a voxel name unknown in a registry"
echo "PASS: a prefab's temporary scene: Edit, the voxels and the box's handle, Save, the copies behind, Close and its question, undo apart, one scene each, nothing left after a restart"
# vim: set noet ts=4 sw=4:
