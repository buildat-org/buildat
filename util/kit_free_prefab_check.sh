#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-06)
# covers: builtin/kit/kit.cpp builtin/kit/client_lua/move.lua builtin/kit/client_lua/controls.lua builtin/kit/client_lua/prefabs.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua builtin/kit/types/prefab_copy.lua builtin/voxel_objects/** apps/workbench/**
# [KIT_FREE_PREFAB] A voxel prefab as a free object: kit/prefab_copy's mode. A
# fresh save on Workbench, a flat World, a walker and controls; prefab
# kitboss/wall: a wall 6x2x1 of stone and a gate before it. The turned wall goes
# across the way the body walks from where it starts.
#   1. A stamped copy still stamps. A free one by kit_edit: no voxel in the world,
#      moved, turned 37.5 (rows and object). One by the palette's Place free, its
#      knob dragged at the free step to an angle no step has. Its members under
#      it. A stamp refused on it. The editor and play in screenshots.
#   2. Walked into: the body stops at the wall, in the wall's frame, the server
#      agreeing (no corrections). Moved out of the way: it walks through where it
#      was. Moved back, the server restarted: from the rows alone, it stops again.
#   3. The prefab edited in its temporary scene and saved, a gap in the wall: both
#      free copies on the new model, the old one gone, the body through the gap;
#      the stamped copy merely behind.
#   4. A switch of the stamped copy to free (its dialog clears its box) and back
#      (its dialog stamps); at an angle no stamp is offered.
# Screenshots kept with KEEP_TMP=1: $t/*.png
#   util/kit_free_prefab_check.sh
#   util/kit_free_prefab_check.sh web    in headless Chrome, on web/'s wasm
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
if [ "${1:-}" = web ]; then
	# The menu's Place free of kit/hut in the 2D plan, selected: inspector and
	# box; turned by keys at a step of 1, moved by a key. One placed in the 3D view
	# and turned there; the editor's view of it, play's, and walked at in play.
	export BUILDAT_WORKBENCH_STONE=1
	check_tmp kit_free_prefab_web; t=$CHECK_TMP
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
	turn=""
	for _ in $(seq 7); do
		turn="$turn [\"key\", \"x\"], [\"waitlog\", \"kit editor: state:\", 10],"
	done
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
	["shot", "\${OUT}/menu.png"],
	["click", "Button", "Place free"], ["waitlog", "kit editor: placing .kit/hut", 10],
	["click", 560, 340], ["waitlog", "kit editor: state: 2 entities, 1 to undo", 10],
	["click", 560, 340, 50, 2], ["waitlog", "kit editor: placing nothing", 10], ["frames", 3],
	["click", 560, 340], ["waitlog", "kit editor: selected 3", 10], ["frames", 3],
	["waitlog_any", "the box of the free copy 3 ", 10],
	["shot", "\${OUT}/root.png"],
	["key", "h"], ["frames", 2], ["key", "h"], ["frames", 2], ["key", "h"], ["frames", 2],
	["key", "h"], ["waitlog", "kit editor: angle step 1", 10],
	$turn
	["key", "Right"], ["sync", 5000], ["frames", 5],
	["shot", "\${OUT}/plan_turned.png"],
	["key", "F2"], ["waitlog", "kit editor: the view is 3D", 10], ["frames", 5],
	["click", "Button", "[kit/hut]"], ["waitlog", "the palette's menu of .kit/hut", 10], ["frames", 3],
	["click", "Button", "Place free"], ["waitlog", "kit editor: placing .kit/hut", 10],
	["click", 800, 600], ["waitlog", "kit editor: state: 3 entities", 10],
	["click", 800, 600, 50, 2], ["waitlog", "kit editor: placing nothing", 10], ["frames", 3],
	["click", 800, 600], ["waitlog", "kit editor: selected 4", 10], ["frames", 3],
	$turn
	["frames", 5],
	["shot", "\${OUT}/view3d.png"],
	["key", "Escape"], ["waitlog", "pause: the menu shown", 10], ["frames", 3],
	["click", "Button", "Play mode", 600, 339], ["waitlog", "kit editor: edit mode off", 10],
	["frames", 10], ["shot", "\${OUT}/play.png"],
	["holdkey", "w", 1500], ["frames", 10], ["shot", "\${OUT}/play_walked.png"],
	["key", "Escape"], ["waitlog", "pause: the menu shown", 10], ["frames", 3],
	["click", "Button", "Edit", 600, 339], ["waitlog", "kit editor: edit mode on", 20], ["frames", 5],
	["click", "DropDownList", "▼", 1120, 387], ["waitlog", " open", 5], ["frames", 3],
	["click", "Text", "stamped"], ["waitlog", "kit editor: 4/1 mode = stamped", 5], ["frames", 3],
	["click", "Button", "Apply"], ["waitlog_any", "kit editor: state: 3 entities", 10], ["sync", 5000], ["frames", 5],
	["shot", "\${OUT}/switched.png"]
]
J
	"$here/util/web_drive.sh" chrome workbench "$t/steps.json" "$t/out" ||
		fail "the web drive ($t/out)"
	for w in "The free object of kit/hut: entity 3" "The free object of kit/hut: entity 4" \
			"The free object of entity 3 moved to" "yaw 7.000" "The free object of entity 4 is gone" \
			"set 4's kit/prefab_copy mode to \"stamped\"" ; do
		grep -aqF "$w" "$t/out/server.log" || fail "no \"$w\" in $t/out/server.log"
	done
	echo "PASS: a free prefab object in the web client"
	exit 0
fi
export BUILDAT_WORKBENCH_PROJECT=world
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_free_prefab; t=$CHECK_TMP
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
cell() # <x> <y> <z>: asked here, its answers compared at the end
{
	ed "{\"op\": \"voxel_info\", \"pos\": [$1, $2, $3]}"
	echo "sync 5000"
}
menu() # <label>: a palette prefab's menu
{
	echo "frames 2"
	echo "mouse_pos 100 400"
	for _ in 1 2 3 4 5 6 7 8; do
		printf 'mouse_wheel -1\nframes 1\n'
	done
	printf 'click Button "[%s]"\nwait_log 5000 the palette'"'"'s menu of [%s]\nframes 3\n' "$1" "$1"
}
joined()
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
EOF
}
to_edit() # from a fresh client: edit mode, the server Ended; the undo count kept
{
	joined
	cat <<'EOF'
keypress F6
wait_log_any 10000 kit editor: state:
event kit_edit {"op": "stop"}
wait_log_any 10000 kit editor: the server is Ended (by kitboss)
frames 3
EOF
}
# Into play from edit mode; the body back where it starts, looking +z, walked for
# two seconds, then a screenshot
walk() # <shot>
{
	cat <<EOF
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log_any 10000 kit: controls: camera first_person
frames 10
look_dir 0 0 1
frames 10
event kit_body
keydown W
delay 2000
keyup W
frames 10
event kit_body
screenshot $t/$1.png
EOF
}
back_to_edit()
{
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: state:
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
frames 3
EOF
}
bodies() # <log>: its "body at" lines, x y z corrections
{
	grep -aoP 'kit: body at \K[-0-9.,]+, [0-9]+ acks, [0-9]+' "$1" |
		sed 's/, [0-9]* acks, / /; s/,/ /g'
}
# ---- Set up: the world, the prefab, a stamped copy, where a body starts
A=5
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
	for y in 1 2; do
		for x in 3 4 5 6 7 8; do
			vox $x $y -30 kit/stone
		done
	done
	edit '{"op": "place", "type": "kit/gate", "pos": [3, 1, -29]}'
	edit '{"op": "save_prefab", "ids": [4], "box": [3, 1, -30, 8, 2, -30], "name": "wall"}'
	edit "{\"op\": \"place\", \"prefab\": \"kitboss/wall\", \"pos\": [10, 1, -20]}"
	edit '{"op": "place", "type": "kit/walker", "pos": [0, 1, 0]}'
	edit '{"op": "place", "type": "kit/controls", "pos": [0, 1, 0]}'
	cell 10 1 -20
	walk start
	echo quit
} > "$t/boss1.cmds"
server 1
wait_for_log "$t/srv1.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv1.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 client boss1
want "$t/srv1.log" "placed prefab kitboss/wall as $A...$((A + 1)), 12 voxels written" \
	"Voxel at (10,1,-20): kit/stone"
read -r bx by bz _ < <(bodies "$t/boss1.log" | head -1)
[ -n "${bz:-}" ] || fail "no body's place ($t/boss1.log)"
echo "the body starts at $bx $by $bz"
# The wall's middle 6 before it, turned 37.5: where its root goes (1/16 grid)
geom=$(python3 -c "
import math
bx, by, bz = map(float, '$bx $by $bz'.split())
a = math.radians(37.5)
g = lambda v: round(v * 16) / 16
print(g(bx - 2.5 * math.cos(a)), round(by + 0.5), g(bz + 6 + 2.5 * math.sin(a)))")
read -r rx ry rz <<< "$geom"
far=$(python3 -c "print($rx - 40)")
gx=$(python3 -c "print($rx - 15)")
# Entities now: 3 world, 4 gate, 5+6 the stamped copy, 7 walker, 8 controls; the
# free one 9 (member 10), the palette's 11 (member 12)
F=9 G=11
{
	to_edit
	edit "{\"op\": \"place\", \"prefab\": \"kitboss/wall\", \"pos\": [$far, $ry, $rz], \"free\": true}"
	cell "$far" "$ry" "$rz"
	edit "{\"op\": \"move\", \"ids\": [$F], \"by\": [40, 0, 0], \"turn\": 37.5}"
	echo "sync 5000"
	cell "$rx" "$ry" "$rz"
	ed "{\"op\": \"stamp\", \"id\": $F}"
	echo "sync 5000"
	# The palette's Place free, at the plan's middle
	menu kitboss/wall
	printf 'screenshot %s/menu.png\nclick Button "Place free"\nwait_log 5000 kit editor: placing [kitboss/wall]\nframes 3\n' "$t"
	cat <<EOF
event kit_plan $gx $rz 20 3
frames 5
mouse_pos 512 350
frames 2
mouse_click left
EOF
	n=$((n + 1))
	undo_count
	cat <<EOF
mouse_click right
wait_log 5000 kit editor: placing nothing
frames 3
event kit_select $G
wait_log_any 5000 kit editor: the box of the free copy $G
frames 5
keypress H
frames 2
keypress H
frames 2
keypress H
wait_log 5000 kit editor: angle step free
frames 3
event kit_knob_where
wait_log_any 5000 kit editor: the knob on the screen at
screenshot $t/plan_selected.png
EOF
	echo "quit"
} > "$t/boss2.cmds"
BUILDAT_JOIN_CREATE= client boss2
want "$t/srv1.log" "The free object of kitboss/wall: entity $F" \
	"The free object of entity $F moved to" "yaw 37.500" \
	"is a free object: nothing to stamp"
knob=$(grep -aoP 'the knob on the screen at \K[0-9]+, [0-9]+' "$t/boss2.log" | tail -1)
[ -n "$knob" ] || fail "no knob in $t/boss2.log"
kx=${knob%%,*} ky=${knob##* }
echo "the knob at $kx $ky"
{
	to_edit
	cat <<EOF
event kit_plan $gx $rz 20 3
frames 5
event kit_select $G
wait_log_any 5000 kit editor: the box of the free copy $G
frames 5
keypress H
frames 2
keypress H
frames 2
keypress H
wait_log 5000 kit editor: angle step free
frames 3
mouse_pos $kx $ky
frames 2
mouse_down left
frames 2
mouse_pos $((kx - 17)) $((ky + 7))
frames 2
mouse_pos $((kx - 53)) $((ky + 31))
frames 3
screenshot $t/plan_dragging.png
mouse_up left
wait_log 5000 kit editor: turned 1 by
sync 5000
frames 10
screenshot $t/plan_turned.png
event kit_cam3d $(python3 -c "print($rx - 8)") $((ry + 8)) $(python3 -c "print($rz - 8)") $rx $ry $rz
frames 10
event kit_select $F
wait_log_any 5000 kit editor: the box of the free copy $F
frames 10
screenshot $t/editor.png
EOF
	walk play_stopped
	back_to_edit
	echo "quit"
} > "$t/boss3.cmds"
BUILDAT_JOIN_CREATE= client boss3
# ---- 2 Move it away, walk through; back, restart
{
	to_edit
	ed "{\"op\": \"move\", \"ids\": [$F], \"by\": [0, 0, 14], \"turn\": 0}"
	echo "sync 5000"
	walk play_through
	back_to_edit
	ed "{\"op\": \"move\", \"ids\": [$F], \"by\": [0, 0, -14], \"turn\": 0}"
	echo "sync 5000"
	echo "quit"
} > "$t/boss4.cmds"
BUILDAT_JOIN_CREATE= client boss4
stop
db=$(find "$t/user" -name save.sqlite -path "*/saves/world/*" | head -1)
[ -n "$db" ] || fail "no save.sqlite under $t/user"
python3 - "$db" "$F" "$G" "$rx" "$ry" "$rz" <<'PY' || fail "the rows in the save ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
F, G = map(int, sys.argv[2:4])
rx, ry, rz = map(float, sys.argv[4:7])
row = lambda k: json.loads(db.execute("select value from store where store='kit' and key=?", (k,)).fetchone()[0])
ents = {e["id"]: e for e in row("authored")["entities"]}
f = ents[F]
assert f["components"][0]["type"] == "kit/prefab_copy", f
assert f["components"][0]["params"]["mode"] == "free", f
assert f["pos"] == [rx, ry, rz] and f["yaw"] == 37.5, f
g = ents[G]
assert g["components"][0]["params"]["mode"] == "free", g
assert g["yaw"] % 15 != 0, g
for r in (F, G):
	m = ents[r + 1]
	assert m["parent"] == r and m["built"]["by"] == r, m
	assert m["components"][0]["type"] == "kit/gate", m
	assert m["pos"] == [0, 0, 1], m
print("the free copies' rows, knob's yaw", g["yaw"])
PY
# The walks: start, stopped, through
python3 - "$t/boss1.log" "$t/boss3.log" "$t/boss4.log" "$rx" "$rz" <<'PY' || fail "the walks ($t/boss*.log)"
import math, re, sys
def bodies(p):
	return [tuple(map(float, m)) for m in re.findall(r"kit: body at ([-0-9.]+),([-0-9.]+),([-0-9.]+), \d+ acks, (\d+)", open(p, errors="replace").read())]
start, stopped, through = (bodies(p) for p in sys.argv[1:4])
rx, rz = map(float, sys.argv[4:6])
a = math.radians(37.5)
def local(b):
	dx, dz = b[0] - rx, b[2] - rz
	return dx * math.cos(a) - dz * math.sin(a), dx * math.sin(a) + dz * math.cos(a)
b0, b1 = stopped[-2], stopped[-1]
walked = math.hypot(b1[0] - b0[0], b1[2] - b0[2])
lx, lz = local(b1)
print("stopped: walked %.2f, in the wall's frame %.2f %.2f, corrections %d" % (walked, lx, lz, b1[3]))
assert walked > 2, "it did not walk"
assert -2 < lz < -0.5 and -1 < lx < 7, "not at the wall"
assert b1[3] == b0[3], "the server disagreed"
t0, t1 = through[-2], through[-1]
print("through: from z %.2f to %.2f" % (t0[2], t1[2]))
assert t1[2] > b0[2] + 6.8, "the wall still where it was moved from"
PY
# ---- 3 A fresh load, the prefab edited
server 2
{
	to_edit
	walk play_loaded
	back_to_edit
	menu kitboss/wall
	printf 'click Button "Edit"\nwait_log 10000 kit editor: editing the prefab kitboss/wall\nwait_log 30000 the prefab'"'"'s voxels are in\nframes 5\nscreenshot %s/bench.png\n' "$t"
	n=0
	# (the prefab's frame in the bench: its base at the origin)
	for y in 0 1; do
		for x in 1 2 3 4; do
			vox $x $y 0 air
		done
	done
	cat <<EOF
click Button "Save"
sync 5000
frames 5
click Button "Close"
wait_log 10000 kit editor: the prefab's scene closed
frames 10
EOF
	echo "event kit_select $A"
	echo "wait_log_any 5000 kit editor: voxels v"
	cat <<EOF
event kit_cam3d $(python3 -c "print($rx - 8)") $((ry + 8)) $(python3 -c "print($rz - 8)") $rx $ry $rz
frames 20
screenshot $t/gap.png
EOF
	walk play_gap
	echo "quit"
} > "$t/boss5.cmds"
BUILDAT_JOIN_CREATE= client boss5
grep -aqE "entity $F, model kitfree_[0-9a-f]+_[0-9]+, at $(printf %.3f "$rx"),$(printf %.3f "$ry"),$(printf %.3f "$rz") yaw 37.500" "$t/srv2.log" ||
	fail "no object of $F from the rows at $rx $ry $rz ($t/srv2.log)"
python3 - "$t/boss5.log" <<'PY' || fail "the walks after the load and the save ($t/boss5.log)"
import re, sys
b = [tuple(map(float, m)) for m in re.findall(r"kit: body at ([-0-9.]+),([-0-9.]+),([-0-9.]+), \d+ acks, (\d+)", open(sys.argv[1], errors="replace").read())]
assert len(b) == 4, b
print("loaded: from z %.2f to %.2f; gap: from z %.2f to %.2f" % (b[0][2], b[1][2], b[2][2], b[3][2]))
assert b[1][2] - b[0][2] > 1 and b[1][2] < b[0][2] + 6.8, "no wall after the load"
# (in the gap, past where the wall stopped it; the gate behind the wall stops it next)
assert b[3][2] > b[1][2] + 1, "no gap after the save"
PY
for w in "saved prefab kitboss/wall version" "The free object of kitboss/wall: entity $F, model kitfree_" \
		"The free object of kitboss/wall: entity $G, model kitfree_" "is no longer in use"; do
	want "$t/srv2.log" "$w"
done
m1=$(grep -aoP "entity $F, model \Kkitfree_[0-9a-f]+_[0-9]+" "$t/srv2.log" | sort -u | wc -l)
m2=$(grep -aoP "entity $G, model \Kkitfree_[0-9a-f]+_[0-9]+" "$t/srv2.log" | sort -u | wc -l)
[ "$m1" = 2 ] && [ "$m2" = 2 ] || fail "not each copy on a new model: $m1 $m2 ($t/srv2.log)"
want "$t/boss5.log" "kit editor: voxels v"
# ---- 4 Switching, by the inspector's dropdown
pick() # <id> <its row's y> <mode>
{
	cat <<EOF
event kit_select $1
wait_log_any 5000 kit editor: selected $1
frames 5
click DropDownList "▼" 970 $2
frames 3
click Text "$3"
wait_log 5000 kit editor: $1/1 mode = $3
frames 2
click Button "Apply"
EOF
}
{
	to_edit
	cell 10 1 -20
	pick "$A" 197 free
	cat <<'EOF'
wait_log 5000 kit editor: the free dialog of 5
frames 3
EOF
	echo "screenshot $t/dialog_free.png"
	cat <<'EOF'
click Button "Clear the box"
wait_log 5000 kit editor: clear the stamp of 5
sync 5000
frames 3
EOF
	cell 10 1 -20
	pick "$A" 197 stamped
	cat <<'EOF'
wait_log 5000 kit editor: the stamp dialog of 5
frames 3
click Button "Stamp without clearing"
wait_log 5000 kit editor: stamp 5
sync 5000
frames 3
EOF
	cell 10 1 -20
	pick "$G" 220 stamped
	cat <<'EOF'
wait_log 5000 kit editor: No stamp at this turn
sync 5000
quit
EOF
} > "$t/boss6.cmds"
BUILDAT_JOIN_CREATE= client boss6
stop
want "$t/srv2.log" "cleared the stamp of kitboss/wall on $A" \
	"The free object of kitboss/wall: entity $A" "The free object of entity $A is gone" \
	"The free object of entity $G is gone"
grep -aoP 'Voxel at \(10,1,-20\): \K[^,]*' "$t/srv2.log" | tail -3 | tr '\n' ' ' | grep -qF "kit/stone air kit/stone" ||
	fail "the stamped copy's cell through the switches ($t/srv2.log)"
echo "PASS: a voxel prefab as a free object: placed, moved, turned, members, collision after the move, the save and a load, a prefab's save on all copies, stamped mode, the switch"
