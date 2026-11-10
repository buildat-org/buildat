#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2.5 min, ~4.5 min with web (2026-11-07)
# covers: builtin/kit/kit.cpp builtin/kit/box/box.c builtin/kit/client_lua/module.lua builtin/kit/client_lua/move.lua builtin/kit/client_lua/controls.lua builtin/kit/client_lua/prefabs.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua builtin/kit/types/prefab_copy.lua builtin/kit/types/region.lua builtin/kit/types/trigger_zone.lua builtin/voxel_objects/** apps/workbench/**
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
# [KIT_FREE_ROTATION] A fresh save (rotation(); "rotation" for it alone): a free
# copy under a turned part, a part under its member: each pose against the rows
# composed here (python, its own quaternions), on the server and in the client's
# nodes, a parent's turn taken along, seven quick key presses all counted. A zone
# under a pitched parent walked through: its edge where the turned box has it. A
# region under one: cells round its edges against the box, by the server, the client
# and c:region_at. The three handles of the editor dragged: each one angle of the
# row. A stamp refused when tilted. Saved, the server restarted: the same poses. A
# walker up a pitched deck (on its true surface; no corrections). Screenshots of the
# editor and of play.
# [KIT_WALKER_FRAME] A fresh save (frame(); "frame" for it alone): a walker on free
# decks pitched 10, rolled 350, turned on all three axes, and pitched 60: fallen onto,
# walked up, down and across, off an edge and back on by the low end's step, stopped
# by a high end's wall, jumped; past slope_limit it slides off, under a limit raised
# past the deck it stands. At each mark, in the deck's frame by this check's own
# quaternions: the feet on the top within 0.02 m, none corrected, the frames entered
# in the order given. A second player, native, sees the body within 0.1 m. Screenshots:
# fp_world, fp_object, chase_object, chase_world, chase_edge, seen_by_bob.
# Screenshots kept with KEEP_TMP=1: $t/*.png
#   util/kit_free_prefab_check.sh
#   util/kit_free_prefab_check.sh rotation
#   util/kit_free_prefab_check.sh frame
#   util/kit_free_prefab_check.sh web frame   the walking in the page, kitbob native
#   util/kit_free_prefab_check.sh web    in headless Chrome, on web/'s wasm: a
#      drive of the plan and palette, then this whole check, its sequences turned
#      into a page's steps (mid-drag screenshots left out)
#   util/kit_free_prefab_check.sh web rotation   rotation() alone, in the page
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
PAGE_STUB="(function(){ var held = null, refuse = false;
 Object.defineProperty(document, 'pointerLockElement', {configurable: true, get: function(){ return held; }});
 function set(e){ held = e; document.dispatchEvent(new Event('pointerlockchange')); }
 document.addEventListener('keydown', function(e){ if(e.key === 'Escape') refuse = true; }, true);
 document.addEventListener('mousedown', function(){ refuse = false; }, true);
 HTMLCanvasElement.prototype.requestPointerLock = function(){
  if(refuse || !window.lockOk){ document.dispatchEvent(new Event('pointerlockerror')); return Promise.reject(new Error('refused')); }
  if(held !== this) set(this); return Promise.resolve(); };
 document.exitPointerLock = function(){ if(held) set(null); };
 return 'stub'; })()"
WEB=
if [ "${1:-}" = web ]; then
	WEB=1
	check_tmp kit_free_prefab_web; t=$CHECK_TMP
fi
if [ -n "$WEB" ] && [ "${2:-}" != rotation ] && [ "${2:-}" != frame ]; then
	# The menu's Place free of kit/hut in the 2D plan, selected: inspector and
	# box; turned by keys at a step of 1, moved by a key. One placed in the 3D view
	# and turned there; the editor's view of it, play's, and walked at in play.
	export BUILDAT_WORKBENCH_STONE=1
	stub=$PAGE_STUB
	# The plan zoomed out by 12 notches over the view, as the palette's
	# wheel events past its end used to (the copies' clicks below are
	# where that view puts them)
	zoom=$(for _ in $(seq 12); do printf '["wheel", 800, 400, 100], ["frames", 1], '; done)
	turn=""
	for _ in $(seq 7); do
		# ([KIT_TURN_KEYS_DROP] Nothing waited for: each press counts)
		turn="$turn [\"key\", \"x\"],"
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
	["mouse", 800, 400], ["frames", 2], $zoom
	$(pal_find_web kit/hut click)
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
	["sync", 5000],
	["key", "Right"], ["sync", 5000], ["frames", 5],
	["shot", "\${OUT}/plan_turned.png"],
	["key", "F2"], ["waitlog", "kit editor: the view is 3D", 10], ["frames", 5],
	["click", "Button", "[kit/hut]"], ["waitlog", "the palette's menu of .kit/hut", 10], ["frames", 3],
	["click", "Button", "Place free"], ["waitlog", "kit editor: placing .kit/hut", 10],
	["click", 560, 600], ["waitlog", "kit editor: state: 3 entities", 10],
	["click", 560, 600, 50, 2], ["waitlog", "kit editor: placing nothing", 10], ["frames", 3],
	["click", 560, 600], ["waitlog", "kit editor: selected 4", 10], ["frames", 3],
	$turn
	["sync", 5000], ["frames", 5],
	["shot", "\${OUT}/view3d.png"],
	["key", "Escape"], ["waitlog", "pause: the menu shown", 10], ["frames", 3],
	["click", "Button", "Play mode", 600, 339], ["waitlog", "kit editor: edit mode off", 10],
	["frames", 10], ["shot", "\${OUT}/play.png"],
	["holdkey", "w", 1500], ["frames", 10], ["shot", "\${OUT}/play_walked.png"],
	["key", "Escape"], ["waitlog", "pause: the menu shown", 10], ["frames", 3],
	["click", "Button", "Edit", 600, 339], ["waitlog", "kit editor: edit mode on", 20], ["frames", 5],
	["click", "DropDownList", "▼", 1120, 422], ["waitlog", " open", 5], ["frames", 3],
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
	echo "ok: a free prefab object in the web client, from the palette"
	unset BUILDAT_WORKBENCH_STONE
fi
export BUILDAT_WORKBENCH_PROJECT=world
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
[ -n "$WEB" ] || { check_tmp kit_free_prefab; t=$CHECK_TMP; }
cd "$here/Build"

server() # <n>
{
	start_server "$t/srv$1.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "${USERDIR:-$t/user}" -l 3 \
		${WEB:+-W "$here/web"} --sim-rate "$CHECK_RATE" ||
		fail "the server did not come up ($t/srv$1.log)"
	CHECK_PIDS+=($SERVER_PID)
	WEB_SERVER_LOG=$t/srv$1.log
}
# A sequence as a page's steps. The first client makes the account as natively.
# The page's pointer lock stubbed, as headless Chrome has none; the pause menu its
# first frames open closed. Keys held: over each delay, the events between them run.
cat > "$t/to_web.py" <<'PY'
import json, math, re, shlex, sys
PAUSE = [["waitlog_any", "pause: the menu shown", 10], ["eval", "window.lockOk = true, 'lock'"],
	["click", 100, 680], ["waitlog", "pause: the menu closed", 10], ["wait", 500]]
out, held, at, down = json.load(open(sys.argv[2])), None, [512, 350], None
for line in open(sys.argv[1]):
	line = line.strip()
	if not line:
		continue
	cmd, _, rest = line.partition(" ")
	if cmd == "event":
		out.append(["event", rest])
	elif cmd in ("wait_log", "wait_log_any"):
		ms, _, text = rest.partition(" ")
		out.append(["waitlog" if cmd == "wait_log" else "waitlog_any", re.escape(text), int(ms) / 1000])
		if "player physics enabled" in text:
			out += PAUSE
	elif cmd in ("frames", "sync"):
		out.append([cmd, int(rest)])
	elif cmd == "delay":
		out.append(["holdkey", held, int(rest)] if held else ["wait", int(rest)])
	elif cmd == "keypress":
		out.append(["key", rest.lower() if len(rest) == 1 else rest])
	elif cmd == "keydown":
		held = rest.lower() if len(rest) == 1 else rest
	elif cmd == "keyup":
		held = None
	elif cmd == "screenshot":
		# (a drag is one step: nothing to see in the middle of it)
		if not down:
			out.append(["shot", rest])
	elif cmd == "mouse_pos":
		at = list(map(int, rest.split()))
		if not down:
			out.append(["mouse", *at])
	elif cmd == "mouse_down":
		down = at
	elif cmd == "mouse_up":
		out.append(["ldrag", *down, *at])
		down = None
	elif cmd == "mouse_click":
		out.append(["click", *at, 50, 2 if rest == "right" else 0])
	elif cmd == "mouse_wheel":
		out.append(["wheel", *at, 100 if int(rest) < 0 else -100])
	elif cmd == "click":
		a = shlex.split(rest)
		out.append(["click", *a[:2], *map(int, a[2:])])
	elif cmd == "text":
		out.append(["type", rest])
	elif cmd == "look_dir":
		x, y, z = map(float, rest.split())
		out.append(["event", "kit_face %.3f %.3f" % (math.degrees(math.atan2(x, z)),
			-math.degrees(math.atan2(y, math.hypot(x, z))))])
	elif cmd == "quit":
		out.append(["sync", 3000])
	else:
		sys.exit("no page's step for: " + line)
json.dump(out, sys.stdout)
PY
web_client() # <name>
{
	local log=$t/$1.log login
	if [ -n "${BUILDAT_JOIN_CREATE:-}" ]; then
		login=$(web_login_steps kitboss "$WEB_SERVER_LOG") || fail "$login"
	else
		# (the login page's first field is the name's)
		login=' ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["selall"], ["frames", 2], ["type", "kitboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Enter"], ["waitlog", "Joined as kitboss", 30],'
	fi
	# (the UI at the size a native 1024x700 run has: its places the same)
	printf '[["nav", "${URL}?scale=0.648148"], ["eval", %s], %s ["frames", 2]]' \
		"$(printf %s "$PAGE_STUB" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
		"$login" > "$t/$1.head.json"
	python3 "$t/to_web.py" "$t/$1.cmds" "$t/$1.head.json" > "$t/$1.json" ||
		fail "the steps of $1"
	WEB_DRIVE_VIEWPORT=1024x700@1 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
		"$here/util/web_drive.sh" chrome workbench "$t/$1.json" "$t/drive_$1" \
		> "$t/drive_$1.txt" 2>&1
	local st=$?
	cp "$t/drive_$1/page.log" "$log" 2>/dev/null
	[ $st = 0 ] || fail "the page's $1 ($(tail -2 "$t/drive_$1.txt"), $log, $t/srv*.log)"
}
client() # <name>: its commands in $t/<name>.cmds
{
	[ -z "$WEB" ] || { web_client "$1"; return; }
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
	pal_find "$1"
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
write_geo()
{
	cat > "$t/geo.py" <<'PY'
# The check's own frames: rows composed, nothing of kit.cpp's
import json, math, re, sqlite3, sys
def quat(yaw=0, pitch=0, roll=0):
	# Urho3D's Quaternion(pitch, yaw, roll): roll, then pitch, then yaw
	def ax(a, i):
		q = [math.cos(math.radians(a) / 2), 0, 0, 0]
		q[i] = math.sin(math.radians(a) / 2)
		return q
	return mul(ax(yaw, 2), mul(ax(pitch, 1), ax(roll, 3)))
def mul(a, b):
	return [a[0]*b[0]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3], a[0]*b[1]+a[1]*b[0]+a[2]*b[3]-a[3]*b[2],
		a[0]*b[2]-a[1]*b[3]+a[2]*b[0]+a[3]*b[1], a[0]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[0]]
def conj(q):
	return [q[0], -q[1], -q[2], -q[3]]
def rot(q, v):
	return mul(mul(q, [0] + list(v)), conj(q))[1:]
def add(a, b):
	return [x + y for x, y in zip(a, b)]
def sub(a, b):
	return [x - y for x, y in zip(a, b)]
def same(a, b):
	return abs(sum(x * y for x, y in zip(a, b)))
def g(v):
	return round(v * 16) / 16
def rows(db):
	d = sqlite3.connect(db)
	r = json.loads(d.execute("select value from store where store='kit' and key='authored'").fetchone()[0])
	return {e["id"]: e for e in r["entities"]}
def world(es, i):
	# Its place and turn through its parents
	e = es.get(i)
	if e is None or "pos" not in e:
		return [0, 0, 0], quat()
	o, q = world(es, e.get("parent", 0))
	return add(o, rot(q, e["pos"])), mul(q, quat(e.get("yaw", 0), e.get("pitch", 0), e.get("roll", 0)))
def holds(o, q, n, p):
	l = rot(conj(q), sub(p, o))
	return all(0 <= math.floor(l[k] + 0.5) < n[k] for k in range(3))
def poses(path, prefix):
	# "<prefix> id x,y,z turn w,x,y,z"
	out = {}
	for m in re.finditer(re.escape(prefix) + r" (\d+) ([-\d.]+),([-\d.]+),([-\d.]+) turn ([-\d.]+),([-\d.]+),([-\d.]+),([-\d.]+)", open(path, errors="replace").read()):
		out[int(m[1])] = ([float(m[k]) for k in (2, 3, 4)], [float(m[k]) for k in (5, 6, 7, 8)])
	return out
def bodies(path):
	return [tuple(map(float, m)) for m in re.findall(r"kit: body at ([-0-9.]+),([-0-9.]+),([-0-9.]+), \d+ acks, (\d+)", open(path, errors="replace").read())]
PY
}
# ---- [KIT_FREE_ROTATION]
rotation()
{
	USERDIR=$t/rot/user
	export BUILDAT_WORKBENCH_TYPES="$USERDIR/apps/workbench/check_types"
	mkdir -p "$BUILDAT_WORKBENCH_TYPES"
	cat > "$BUILDAT_WORKBENCH_TYPES/probe.lua" <<'LUA'
-- c:region_at for the check
return {
	version = 1,
	regions = true,
	inputs = {region = "position"},
	on_input = function(c, input, v)
		local r = c:region_at(v)
		c:log(r and "region " .. r.id or "no region")
	end,
}
LUA
	write_geo
	c3() { python3 -c "print($1)"; }
	# (more edits than the undo counts: each one waited for by a round trip)
	edit() { ed "$1"; echo "sync 5000"; }
	# ---- Set up: the world, the prefabs, a walker
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
		for y in 1 2; do
			for x in 3 4 5 6 7 8; do
				vox $x $y -30 kit/stone
			done
		done
		edit '{"op": "place", "type": "kit/gate", "pos": [3, 1, -29]}'
		edit '{"op": "save_prefab", "ids": [4], "box": [3, 1, -30, 8, 2, -30], "name": "wall"}'
		for z in -40 -39 -38 -37 -36 -35 -34 -33; do
			for x in 3 4 5 6 7 8 9 10; do
				vox $x 1 $z kit/stone
			done
		done
		edit '{"op": "save_prefab", "ids": [], "box": [3, 1, -40, 10, 1, -33], "name": "deck"}'
		edit '{"op": "place", "type": "kit/walker", "pos": [0, 1, 0]}'
		edit '{"op": "place", "type": "kit/controls", "pos": [0, 1, 0]}'
		edit '{"op": "place", "type": "workbench/probe", "pos": [0, 1, -20]}'
		walk rot_start | grep -v 'camera first_person'
		echo quit
	} > "$t/ro1.cmds"
	server r1
	wait_for_log "$t/srvr1.log" "setup code [A-Z0-9]+" 30
	code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srvr1.log" | head -1)
	[ -n "$code" ] || fail "no setup code ($t/srvr1.log)"
	BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 client ro1
	read -r bx by bz _ < <(bodies "$t/ro1.log" | head -1)
	[ -n "${bz:-}" ] || fail "no body's place ($t/ro1.log)"
	bx=$(c3 "round($bx * 16) / 16"); bz=$(c3 "round($bz * 16) / 16"); by=$(c3 "round($by * 16) / 16")
	echo "the body starts at $bx $by $bz"
	# Entities from here: 8 ZP, the zone's parent, 9 the zone; 10 RP, the region's
	# parent, 11 the region; 12 CP a part, 13 F a free root under it, 14 F's gate,
	# 15 K a part under the gate; 16 G a free root for the handles, 17 its gate; 18
	# the deck; 19 S, stamped, 20 its gate
	ZY=45 ZP=15
	read -r zox zoy zoz <<< "$(python3 - "$t" "$bx" "$by" "$bz" "$ZY" "$ZP" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from geo import *
bx, by, bz, y, p = map(float, sys.argv[2:7])
# The box's middle on the way the body walks, 3.5 before it
o = sub([bx, by + 0.5, bz + 3.5], rot(quat(y, p, 0), [1.5, 2.5, 1.5]))
print(*map(g, o))
PY
)"
	rx=$(c3 "$bx + 10"); ry=$(c3 "$by + 1"); rz=$(c3 "$bz + 2")
	cx=$(c3 "$bx - 10"); cy=$(c3 "$by + 4"); cz=$(c3 "$bz + 12")
	gx=$(c3 "$bx + 6"); gy=$(c3 "$by + 3"); gz=$(c3 "$bz - 8")
	dx=$(c3 "$bx - 4"); dy=$(c3 "$by - 0.375"); dz=$(c3 "$bz + 6.5")
	sx=$(c3 "int($bx) + 30")
	python3 - "$t" "$rx" "$ry" "$rz" > "$t/cells.txt" <<'PY' || fail "the cells"
import sys
sys.path.insert(0, sys.argv[1])
from geo import *
rx, ry, rz = map(float, sys.argv[2:5])
q = quat(30, 20, 10)
o = add([rx, ry, rz], rot(q, [1, 0, 0]))
n = [6, 3, 4]
ins, out = [], []
for x in range(int(rx) - 10, int(rx) + 12):
	for y in range(max(0, int(ry) - 4), int(ry) + 8):
		for z in range(int(rz) - 10, int(rz) + 12):
			l = rot(conj(q), sub([x, y, z], o))
			# The distance past the box's nearest face, inside negative
			d = max(max(-0.5 - l[k], l[k] - (n[k] - 0.5)) for k in range(3))
			if abs(d) < 0.6:
				(ins if d < 0 else out).append((x, y, z))
assert len(ins) > 10 and len(out) > 10
for c in ins[:: max(1, len(ins) // 16)] + out[:: max(1, len(out) // 16)]:
	print(*c)
PY
	{
		to_edit
		edit "{\"op\": \"place\", \"type\": \"kit/part\", \"pos\": [$zox, $zoy, $zoz]}"
		edit '{"op": "set", "id": 8, "comp": 0, "param": "collision", "value": false}'
		edit "{\"op\": \"place\", \"type\": \"kit/trigger_zone\", \"pos\": [$zox, $zoy, $zoz], \"parent\": 8}"
		edit '{"op": "set", "id": 9, "comp": 0, "param": "size", "value": [4, 6, 4]}'
		edit "{\"op\": \"move\", \"id\": 8, \"pos\": [$zox, $zoy, $zoz], \"yaw\": $ZY, \"pitch\": $ZP}"
		edit "{\"op\": \"place\", \"type\": \"kit/part\", \"pos\": [$rx, $ry, $rz]}"
		edit '{"op": "set", "id": 10, "comp": 0, "param": "collision", "value": false}'
		edit "{\"op\": \"place\", \"type\": \"kit/region\", \"pos\": [$(c3 "$rx + 1"), $ry, $rz], \"parent\": 10}"
		edit '{"op": "set", "id": 11, "comp": 0, "param": "size", "value": [6, 3, 4]}'
		edit "{\"op\": \"move\", \"id\": 10, \"pos\": [$rx, $ry, $rz], \"yaw\": 30, \"pitch\": 20, \"roll\": 10}"
		# The chain, level as it is made
		edit "{\"op\": \"place\", \"type\": \"kit/part\", \"pos\": [$cx, $cy, $cz]}"
		edit '{"op": "set", "id": 12, "comp": 0, "param": "color", "value": "#3060ff"}'
		edit "{\"op\": \"place\", \"prefab\": \"kitboss/wall\", \"pos\": [$(c3 "$cx + 1"), $cy, $cz], \"free\": true, \"parent\": 12}"
		edit "{\"op\": \"place\", \"type\": \"kit/part\", \"pos\": [$(c3 "$cx + 1"), $(c3 "$cy + 1"), $(c3 "$cz + 1")], \"parent\": 14}"
		edit '{"op": "set", "id": 15, "comp": 0, "param": "color", "value": "#ff2020"}'
		edit '{"op": "set", "id": 15, "comp": 0, "param": "collision", "value": false}'
		# F's turn in the world, then its parent's: F's goes along
		edit "{\"op\": \"move\", \"id\": 13, \"pos\": [$(c3 "$cx + 1"), $cy, $cz], \"yaw\": 70, \"pitch\": 25, \"roll\": 35}"
		echo "sync 5000"
		edit "{\"op\": \"move\", \"id\": 12, \"pos\": [$cx, $cy, $cz], \"yaw\": 30, \"pitch\": 15, \"roll\": 350}"
		echo "sync 5000"
		edit "{\"op\": \"place\", \"prefab\": \"kitboss/wall\", \"pos\": [$gx, $gy, $gz], \"free\": true}"
		edit "{\"op\": \"move\", \"id\": 16, \"pos\": [$gx, $gy, $gz], \"yaw\": 40, \"pitch\": 10, \"roll\": 20}"
		edit "{\"op\": \"place\", \"prefab\": \"kitboss/deck\", \"pos\": [$dx, $dy, $dz], \"free\": true}"
		edit "{\"op\": \"move\", \"id\": 18, \"pos\": [$dx, $dy, $dz], \"pitch\": 350}"
		# A stamp is refused at a tilt, and a free one has none
		ed '{"op": "stamp", "id": 13}'
		echo "sync 5000"
		edit "{\"op\": \"place\", \"prefab\": \"kitboss/wall\", \"pos\": [$sx, 1, 0]}"
		edit "{\"op\": \"move\", \"id\": 19, \"pos\": [$sx, 1, 0], \"pitch\": 20}"
		ed '{"op": "stamp", "id": 19}'
		echo "sync 5000"
		# The cells, three ways (a try needs the game running)
		echo 'event kit_edit {"op": "play"}'
		echo "wait_log 10000 kit editor: the server is Running (by kitboss)"
		while read -r x y z; do
			echo "event kit_edit {\"op\": \"voxel_info\", \"pos\": [$x, $y, $z]}"
			echo "event kit_probe $x $y $z"
			echo "event kit_edit {\"op\": \"try\", \"id\": 7, \"input\": \"region\", \"value\": [$x, $y, $z]}"
			echo "wait_log 5000 kit editor: tried 7's region"
			echo "sync 5000"
		done < "$t/cells.txt"
		echo 'event kit_edit {"op": "stop"}'
		echo "wait_log 10000 kit editor: the server is Ended (by kitboss)"
		# Seven quick presses on the parent: a step of 1
		echo "event kit_select 12"
		echo "wait_log_any 5000 kit editor: selected 12"
		printf 'keypress H\nframes 2\nkeypress H\nframes 2\nkeypress H\nframes 2\nkeypress H\nwait_log 5000 kit editor: angle step 1\nframes 2\n'
		for _ in 1 2 3 4 5 6 7; do
			printf 'keypress X\nframes 1\n'
		done
		echo "sync 5000"
		# The screenshots of the editor: the chain, the boxes
		cat <<EOF
event kit_cam3d $(c3 "$cx + 12") $(c3 "$cy + 6") $(c3 "$cz - 3") $cx $cy $(c3 "$cz - 2")
event kit_select 13
wait_log_any 5000 kit editor: the box of the free copy 13
frames 10
screenshot $t/rot_chain.png
event kit_cam3d $(c3 "$bx + 5") $(c3 "$by + 12") $(c3 "$bz - 12") $(c3 "$bx + 5") $by $(c3 "$bz + 3")
event kit_select 10
wait_log_any 5000 kit editor: selected 10
frames 10
screenshot $t/rot_boxes.png
event kit_cam3d $(c3 "$gx + 20") $(c3 "$gy + 14") $(c3 "$gz + 2") $gx $gy $gz
event kit_select 16
wait_log_any 5000 kit editor: the box of the free copy 16
frames 10
event kit_knob_where
wait_log_any 5000 kit editor: the knob on the screen at
screenshot $t/rot_knobs.png
event kit_cam3d $(c3 "$gx + 20") $gy $gz $gx $gy $gz
frames 3
event kit_knob_where
wait_log_any 5000 kit editor: the rings shown:
screenshot $t/rot_level.png
quit
EOF
	} > "$t/ro2.cmds"
	BUILDAT_JOIN_CREATE= client ro2
	# A ring seen edge-on is not shown: from above-ish the yaw's, level not
	rings=$(grep -ao "kit editor: the rings shown: [a-z0-9 .()]*;" "$t/ro2.log" | tr '\n' '|')
	case "$rings" in
		*"shown: yaw"*"|"*"shown: "*) ;;
		*) fail "the rings shown: $rings ($t/ro2.log)";;
	esac
	[ "$(grep -ao "kit editor: the rings shown: [a-z0-9 .()]*;" "$t/ro2.log" | tail -1 | grep -c yaw)" = 0 ] ||
		fail "the yaw ring shown edge-on: $rings ($t/ro2.log)"
	want "$t/srvr1.log" "is a free object: nothing to stamp" \
		"is turned yaw 0 pitch 20 roll 0: voxels go by multiples of 90"
	# ---- The handles, dragged: the roll first, which moves no other knob
	# Across the radius on the screen (along it a ring seen askew turns little)
	drag() # <knob's x> <y> <shot>
	{
		local ax=$(($2 - m_y)) ay=$((m_x - $1)) l
		l=$(python3 -c "import math; print(max(1, int(math.hypot($ax, $ay))))")
		cat <<EOF
mouse_pos $1 $2
frames 2
mouse_down left
frames 2
mouse_pos $(($1 + ax * 12 / l)) $(($2 + ay * 12 / l))
frames 2
mouse_pos $(($1 + ax * 45 / l)) $(($2 + ay * 45 / l))
frames 3
screenshot $t/$3.png
mouse_up left
wait_log 5000 kit editor: turned 1 by
sync 5000
frames 5
EOF
	}
	knob_at() # <the words before "knob">
	{
		grep -aoP "kit editor: the ${1}knob on the screen at \K[0-9]+, [0-9]+" "$t/ro2.log" | head -1 | sed 's/,//'
	}
	k_yaw=$(knob_at ""); k_pitch=$(knob_at "pitch "); k_roll=$(knob_at "roll ")
	[ -n "$k_yaw" ] && [ -n "$k_pitch" ] && [ -n "$k_roll" ] ||
		fail "no knobs in $t/ro2.log: $k_yaw; $k_pitch; $k_roll"
	read -r m_x m_y <<<"$(grep -aoP "kit editor: the middle on the screen at \K[0-9]+, [0-9]+" "$t/ro2.log" | head -1 | sed 's/,//')"
	[ -n "$m_y" ] || fail "no middle in $t/ro2.log"
	echo "the knobs: yaw $k_yaw, pitch $k_pitch, roll $k_roll, round $m_x $m_y"
	{
		to_edit
		cat <<EOF
event kit_cam3d $(c3 "$gx + 20") $(c3 "$gy + 14") $(c3 "$gz + 2") $gx $gy $gz
event kit_select 16
wait_log_any 5000 kit editor: the box of the free copy 16
frames 10
keypress H
frames 2
keypress H
frames 2
keypress H
frames 2
keypress H
wait_log 5000 kit editor: angle step 1
frames 3
EOF
		drag $k_roll rot_drag_roll
		drag $k_pitch rot_drag_pitch
		drag $k_yaw rot_drag_yaw
		# Through the zone, onto the deck: its steps
		cat <<'EOF'
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
EOF
		for _ in 1 2 3 4 5 6 7 8; do
			printf 'delay 500\nevent kit_body\n'
		done
		cat <<EOF
keyup W
frames 10
event kit_body
screenshot $t/rot_deck.png
look_dir -0.62 0.15 -0.77
frames 10
screenshot $t/rot_play_look.png
look_dir -0.3 0 -1
frames 10
screenshot $t/rot_play_deck.png
EOF
		back_to_edit
		echo quit
	} > "$t/ro3.cmds"
	BUILDAT_JOIN_CREATE= client ro3
	stop
	db=$(find "$USERDIR" -name save.sqlite -path "*/saves/world/*" | head -1)
	[ -n "$db" ] || fail "no save.sqlite under $USERDIR"
	# ---- The numbers, before the restart
	python3 - "$t" "$db" "$t/srvr1.log" "$t/ro2.log" "$t/ro3.log" "$t/cells.txt" <<'PY' || fail "rotation's numbers ($t)"
import sys
sys.path.insert(0, sys.argv[1])
from geo import *
db, slog, c2, c3, cells = sys.argv[2:7]
es = rows(db)
srv = open(slog, errors="replace").read()
# The composition from the rows: the server's object's node, at the last of its moves
nodes = re.findall(r"free object[^\n]*entity 13[^\n]*node at ([-\d.]+),([-\d.]+),([-\d.]+) turn ([-\d.]+),([-\d.]+),([-\d.]+),([-\d.]+)", srv)
assert len(nodes) >= 3, "the object's moves: %d" % len(nodes)
o, q = world(es, 13)
m = nodes[-1]
assert max(abs(a - float(b)) for a, b in zip(add(o, rot(q, [-0.5, -0.5, -0.5])), m[:3])) < 2e-3, (o, m)
assert same(q, list(map(float, m[3:]))) > 1 - 1e-5, (q, m)
print("F's node against the rows composed, its last of %d moves: at %s" % (len(nodes), m[:3]))
# F given its turn in the world while its parent stood level
assert re.search(r"free object of entity 13 moved to [^\n]* yaw 70\.\d+ pitch 25\.\d+ roll 35\.\d+", srv), "F's given turn"
# The seven presses
assert es[12]["yaw"] == 37, es[12]
assert es[12].get("pitch") == 15 and es[12].get("roll") == 350, es[12]
print("the parent's yaw after 7 quick presses from 30:", es[12]["yaw"])
# Rows are their parents' frames'
assert es[14]["pos"] == [0, 0, 1], es[14]
assert es[15]["pos"] == [0, 1, 0], es[15]
assert es[9]["pos"] == [0, 0, 0], es[9]
assert "pitch" in es[13] and "roll" in es[13], es[13]
assert es[19].get("pitch") == 20
# The handles
log = open(c3, errors="replace").read()
by = list(map(float, re.findall(r"kit editor: turned 1 by (-?[\d.]+)", log)))
assert len(by) == 3 and all(by), by
e = es[16]
exp = [(40 + by[2]) % 360, (10 + by[1]) % 360, (20 + by[0]) % 360]
got = [e.get("yaw", 0), e.get("pitch", 0), e.get("roll", 0)]
print("the handles: roll by %g, pitch by %g, yaw by %g; the row's yaw %g pitch %g roll %g" % (by[0], by[1], by[2], *got))
assert all(abs(((a - b) + 180) % 360 - 180) < 0.07 for a, b in zip(exp, got)), (exp, got)
assert es[17]["pos"] == [0, 0, 1], es[17]
# The zone: where the walk entered and left against the turned box
o, q = world(es, 9)
n = [4, 6, 4]
z = re.findall(r"Entity 9: kitboss (enters|leaves) its zone at ([-\d.]+),([-\d.]+),([-\d.]+)", srv)
assert len(z) >= 2 and z[0][0] == "enters" and z[1][0] == "leaves", z
def face(p):
	l = rot(conj(q), sub(p, o))
	return max(max(-0.5 - l[k], l[k] - (n[k] - 0.5)) for k in range(3))
pe, pl = [list(map(float, x[1:])) for x in z[:2]]
print("the zone: entered at z %.2f, %.2f past the turned box's face; left at z %.2f, %.2f past it" % (pe[2], -face(pe), pl[2], face(pl)))
# (a tick's walk past the edge at most)
assert -0.5 < face(pe) <= 0, ("entered", pe, face(pe))
assert 0 < face(pl) < 0.5, ("left", pl, face(pl))
# Regions: three ways, against the box
o, q = world(es, 11)
n = [6, 3, 4]
want = []
for line in open(cells):
	c = list(map(int, line.split()))
	want.append((c, holds(o, q, n, c)))
assert any(w[1] for w in want) and not all(w[1] for w in want)
vox = {}
for m in re.finditer(r"Voxel at \((-?\d+),(-?\d+),(-?\d+)\): [^\n]*?(?:, region (\d+))?\n", srv):
	vox[tuple(map(int, m.group(1, 2, 3)))] = m.group(4)
prob = re.findall(r"kit probe: voxel [^\n]*?(?:, region (\d+))?\n", open(c2, errors="replace").read())
box = re.findall(r"probe 7: (region \d+|no region)", srv)
assert len(prob) == len(want) and len(box) >= len(want), (len(prob), len(box), len(want))
bad = 0
for i, (c, h) in enumerate(want):
	s = vox.get(tuple(c), "?")
	if (s == "11") != h or (prob[i] == "11") != h or (box[i] == "region 11") != h:
		print("a cell", c, "should be", h, "server", s, "client", prob[i], "box", box[i])
		bad += 1
assert not bad
print("the region: %d cells round its edges, %d in it, the same three ways" % (len(want), sum(1 for w in want if w[1])))
PY
	# ---- The deck: climbing with no corrections, its steps printed
	python3 - "$t" "$t/ro3.log" "$dy" "$dz" "$by" <<'PY' || fail "the walk onto the deck ($t/ro3.log)"
import sys
sys.path.insert(0, sys.argv[1])
from geo import *
log, dy, dz, by = sys.argv[2], *map(float, sys.argv[3:6])
b = bodies(log)
t = math.tan(math.radians(10))
for x in b:
	true = dy + 0.5 / math.cos(math.radians(10)) + (x[2] - dz) * t if x[2] >= dz - 0.5 else by
	print("  body z %.2f y %.2f (the deck's top under it %.2f), corrections %d" % (x[2], x[1], true, x[3]))
	assert not dz < x[2] < dz + 7 or abs(x[1] - true) < 0.03, "not on the deck's surface"
assert b[-1][3] == b[0][3], "corrections on the deck"
assert max(x[1] for x in b) > by + 0.3, "it did not climb"
PY
	# ---- A restart: the same poses, from the rows, and the client's nodes
	{
		to_edit
		printf 'event kit_pose 8 9 10 11 12 13 14 15 16 17 18\nframes 5\n'
		cat <<EOF
event kit_cam3d $(c3 "$cx + 12") $(c3 "$cy + 6") $(c3 "$cz - 3") $cx $cy $(c3 "$cz - 2")
event kit_select 13
wait_log_any 5000 kit editor: the box of the free copy 13
frames 10
screenshot $t/rot_loaded.png
quit
EOF
	} > "$t/ro4.cmds"
	server r2
	BUILDAT_JOIN_CREATE= client ro4
	stop
	python3 - "$t" "$db" "$t/ro4.log" "$t/srvr2.log" <<'PY' || fail "the poses after the load ($t)"
import sys
sys.path.insert(0, sys.argv[1])
from geo import *
db, cl, slog = sys.argv[2:5]
es = rows(db)
got = poses(cl, "kit pose:")
assert got, "no poses in " + cl
for i in (8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18):
	o, q = world(es, i)
	assert i in got, ("no pose of", i, sorted(got))
	p, r = got[i]
	assert max(abs(a - b) for a, b in zip(o, p)) < 2e-3, (i, o, p)
	assert same(q, r) > 1 - 1e-5, (i, q, r)
print("the client's nodes against the rows composed: %d poses" % len(got))
srv = open(slog, errors="replace").read()
for i in (13, 16, 18):
	o, q = world(es, i)
	m = re.search(r"entity %d, model kitfree_\w+, at [^\n]*node at ([-\d.]+),([-\d.]+),([-\d.]+) turn ([-\d.]+),([-\d.]+),([-\d.]+),([-\d.]+)" % i, srv)
	assert m, ("no object of", i)
	assert max(abs(a - float(b)) for a, b in zip(add(o, rot(q, [-0.5, -0.5, -0.5])), m.groups()[:3])) < 2e-3, (i, o, m.groups())
	assert same(q, list(map(float, m.groups()[3:]))) > 1 - 1e-5, (i, q, m.groups())
print("the objects from the rows after the restart")
PY
	echo "ok: [KIT_FREE_ROTATION] poses, zone, region, handles, keys, a stamp refused, save and load"
	unset USERDIR BUILDAT_WORKBENCH_TYPES
}
# ---- [KIT_WALKER_FRAME]
frame()
{
	USERDIR=$t/fr/user
	# (a floor with no trees for a deck to meet)
	export BUILDAT_WORKBENCH_STONE=1
	export BUILDAT_WORKBENCH_TYPES="$USERDIR/apps/workbench/check_types"
	mkdir -p "$BUILDAT_WORKBENCH_TYPES"
	cat > "$BUILDAT_WORKBENCH_TYPES/tele.lua" <<'LUA'
-- Puts the player who tries it where a mark starts
return {
	version = 1,
	inputs = {go = "position"},
	on_input = function(c, input, v)
		c:teleport(v)
	end,
}
LUA
	write_geo
	c3() { python3 -c "print($1)"; }
	edit() { ed "$1"; echo "sync 5000"; }
	native() # <name>
	{
		run_client 90 "$t/$1.log" timeout 240 bin/buildat -C "$t/client_cache" \
			-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
			-c @"$t/$1.cmds" || fail "client $1 failed ($t/$1.log, $t/srv*.log)"
	}
	# ---- Set up, natively: the world, the deck's prefab, a walker; where it starts
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
		for z in -40 -39 -38 -37 -36 -35 -34 -33; do
			for x in 3 4 5 6 7 8 9 10; do
				vox $x 1 $z kit/stone
			done
		done
		edit '{"op": "save_prefab", "ids": [], "box": [3, 1, -40, 10, 1, -33], "name": "deck"}'
		edit '{"op": "place", "type": "kit/walker", "pos": [0, 1, 0]}'
		edit '{"op": "place", "type": "kit/controls", "pos": [0, 1, 0]}'
		edit '{"op": "place", "type": "workbench/tele", "pos": [0, 1, -20]}'
		walk fr_start | grep -v 'camera first_person'
		echo quit
	} > "$t/fr1.cmds"
	server f1
	wait_for_log "$t/srvf1.log" "setup code [A-Z0-9]+" 30
	code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srvf1.log" | head -1)
	[ -n "$code" ] || fail "no setup code ($t/srvf1.log)"
	BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
		BUILDAT_JOIN_ADMIN="setting open_registration on" native fr1
	read -r bx by bz _ < <(bodies "$t/fr1.log" | head -1)
	[ -n "${bz:-}" ] || fail "no body's place ($t/fr1.log)"
	bx=$(c3 "round($bx * 16) / 16"); bz=$(c3 "round($bz * 16) / 16"); by=$(c3 "round($by * 16) / 16")
	echo "the body starts at $bx $by $bz"
	# 3 world, 4 walker, 5 controls, 6 tele; 7 the pitched deck: its low end (+z) a
	# 0.3 step over the floor; 8 rolled; 9 on all axes; 10 past the limit, its low end
	# in the air
	cat > "$t/decks.py" <<PY
BY = $by
DECKS = {
	7: ([$(c3 "$bx - 4"), $(c3 "$by + 1.125"), $(c3 "$bz + 5")], 0, 10, 0),
	8: ([$(c3 "$bx + 20"), $(c3 "$by + 2"), $(c3 "$bz + 5")], 0, 0, 350),
	9: ([$(c3 "$bx - 24"), $(c3 "$by + 4"), $(c3 "$bz + 5")], 30, 15, 350),
	10: ([$(c3 "$bx - 4"), $(c3 "$by + 8"), $(c3 "$bz - 24")], 0, 60, 0),
}
PY
	over() # <deck> <local x> <local z>: a place 1.5 over the deck's top, for tele
	{
		python3 - "$t" "$1" "$2" "$3" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from geo import *
from decks import *
o, y, p, r = DECKS[int(sys.argv[2])]
w = add(o, rot(quat(y, p, r), [float(sys.argv[3]), 0.5, float(sys.argv[4])]))
print("[%.3f, %.3f, %.3f]" % (w[0], w[1] + 2, w[2]))
PY
	}
	in_edit() # <event kit_edit's>: an edit or a try takes edit mode, the game running
	{
		printf 'keypress F6\nwait_log 5000 kit editor: state:\nevent kit_edit %s\nsync 3000\n' "$1"
		printf 'keypress F6\nwait_log 5000 kit editor: edit mode off\n'
	}
	tele() # <deck> <local x> <local z>: there, and fallen onto it
	{
		in_edit "{\"op\": \"try\", \"id\": 6, \"input\": \"go\", \"value\": $(over "$1" "$2" "$3")}"
		echo "wait_log 10000 kit: the body's frame: $1"
		echo "frames 3"
	}
	mark() # <name>: the body's place at a settled moment, named in order
	{
		echo "$1" >> "$t/marks.txt"
		echo "sync 3000"
		echo "event kit_body"
	}
	walked() # <dir x> <dir z> <ms> <name>
	{
		printf 'look_dir %s 0 %s\nframes 2\nkeydown W\ndelay %s\n' "$1" "$2" "$3"
		mark "$4"
		printf 'keyup W\ndelay 100\n'
	}
	: > "$t/marks.txt"
	mark_set() # <id> <param> <value>: a parameter while playing
	{
		in_edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"
		echo "frames 3"
	}
	{
		to_edit
		cat <<'EOF'
event kit_edit {"op": "place", "prefab": "kitboss/deck", "pos": [0, 30, -80], "free": true}
sync 5000
event kit_edit {"op": "place", "prefab": "kitboss/deck", "pos": [0, 30, -80], "free": true}
sync 5000
event kit_edit {"op": "place", "prefab": "kitboss/deck", "pos": [0, 30, -80], "free": true}
sync 5000
event kit_edit {"op": "place", "prefab": "kitboss/deck", "pos": [0, 30, -80], "free": true}
sync 5000
EOF
		python3 - "$t" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
from decks import *
for i, (o, y, p, r) in DECKS.items():
	print("event kit_edit " + json.dumps({"op": "move", "id": i, "pos": o, "yaw": y, "pitch": p, "roll": r}))
	print("sync 5000")
PY
		# Fresh: in play, kitbob on his way
		cat <<EOF
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
keypress F6
wait_log 10000 kit editor: edit mode off
frames 10
EOF
		# The pitched deck: fallen onto, up (-z), down, across, jumped
		tele 7 3.5 3.5
		mark p_fall
		walked 0 -1 300 p_up
		walked 0 1 500 p_down
		walked 0 -1 200 p_up2
		walked 1 0 300 p_across
		walked -1 0 500 p_across2
		walked 1 0 200 p_across3
		printf 'keydown Space\ndelay 100\nkeyup Space\ndelay 1000\n'
		mark p_jump
		# Off the low end; back up it by its step; on over the high end, a wall from
		# the floor there
		walked 0 1 1200 p_off_low
		echo "delay 500"
		mark p_floor
		walked 0 -1 1000 p_back_on
		walked 0 -1 1000 p_off_high
		echo "delay 500"
		mark p_floor2
		walked 0 1 800 p_at_wall
		# Rolled: its top falling away along -x... each way
		tele 8 3.5 3.5
		mark r_fall
		walked 1 0 300 r_x
		walked -1 0 500 r_x2
		walked 1 0 200 r_x3
		walked 0 1 300 r_z
		walked 0 -1 500 r_z2
		walked 0 1 200 r_z3
		walked 1 1 200 r_diag
		walked -1 -1 200 r_diag2
		# All three axes
		tele 9 3.5 3.5
		mark a_fall
		walked 0 1 300 a_a
		walked 0 -1 500 a_b
		walked 1 0 300 a_c
		walked -1 0 500 a_d
		printf 'keydown Space\ndelay 100\nkeyup Space\ndelay 1000\n'
		mark a_jump
		# Past the limit: slides
		tele 10 3.5 1
		mark s_on
		echo "delay 300"
		mark s_lower
		echo "delay 1500"
		mark s_floor
		# The limit past the deck: it stands, and the keys take it up and down
		mark_set 4 slope_limit 65
		tele 10 3.5 3.5
		mark l_on
		echo "delay 500"
		mark l_still
		walked 0 1 200 l_down
		mark_set 4 slope_limit 50
		# The views on the pitched deck, across its slope and over the low end
		tele 7 3.5 3.5
		printf 'look_dir 1 -0.15 0.6\nframes 10\n'
		mark v_world
		echo "screenshot $t/fp_world.png"
		mark_set 5 camera_frame '"object"'
		echo "delay 800"
		mark v_object
		echo "screenshot $t/fp_object.png"
		mark_set 5 camera '"chase"'
		echo "delay 800"
		echo "screenshot $t/chase_object.png"
		mark_set 5 camera_frame '"world"'
		echo "delay 800"
		echo "screenshot $t/chase_world.png"
		# The body at the deck's edge, the view from outside it: the feet on the top
		tele 7 6.9 3.5
		printf 'look_dir -1 -0.05 0.1\nframes 10\ndelay 400\n'
		mark v_edge
		echo "screenshot $t/chase_edge.png"
		mark_set 5 camera '"first_person"'
		# Walking under the object's view: where its forward goes on the deck
		mark_set 5 camera_frame '"object"'
		echo "delay 500"
		walked 0 -1 200 v_walk
		mark_set 5 camera_frame '"world"'
		# And for kitbob
		in_edit '{"op": "try", "id": 5, "input": "shake", "value": 0.01}'
		echo "delay 1500"
		mark bob_saw
		echo "sync 3000"
		echo quit
	} > "$t/fr2.cmds"
	# (he stands where the body started, looking at the deck)
	cat > "$t/frbob.cmds" <<EOF
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
look_dir -0.5 0.1 1
wait_log 200000 kit: camera shake 0.01
event kit_players
frames 5
screenshot $t/seen_by_bob.png
sync 1000
quit
EOF
	# (kitbob first: he must be in when it plays; his client quits by its own)
	BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 native frbob &
	bob=$!
	wait_for_log "$t/frbob.log" "player physics enabled" 120 ||
		fail "kitbob did not get in ($t/frbob.log)"
	client fr2
	wait $bob || fail "kitbob's client ($t/frbob.log)"
	stop
	python3 - "$t" "$t/fr2.log" "$t/marks.txt" "$t/frbob.log" <<'PY' || fail "the walker's frame ($t/fr2.log)"
import sys
sys.path.insert(0, sys.argv[1])
from geo import *
from decks import *
log, marks, boblog = sys.argv[2:5]
text = open(log, errors="replace").read()
names = open(marks).read().split()
got = re.findall(r"kit: body at [-\d.,]+, \d+ acks, (\d+) corrections, \d+ pending, (\d+) jumps, \d+ arrivals\n.*?kit: feet at ([-\d.]+),([-\d.]+),([-\d.]+), frame (\w+)", text)
# (walk()'s, not marks, come before)
assert len(got) >= len(names), (len(got), len(names))
got = got[-len(names):]
M = {}
for n, g in zip(names, got):
	f = None if g[5] == "none" else int(g[5])
	p = [float(g[2]), float(g[3]), float(g[4])]
	l = None
	if f is not None:
		o, y, pi, r = DECKS[f]
		l = rot(conj(quat(y, pi, r)), sub(p, o))
	M[n] = {"corr": int(g[0]), "jumps": int(g[1]), "p": p, "f": f, "l": l}
worst = 0
for n in names:
	m = M[n]
	lt = " in %d, %.4f over its top" % (m["f"], m["l"][1] - 0.5) if m["f"] else ""
	print("  %-10s %.3f %.3f %.3f%s, corrections %d" % (n, *m["p"], lt, m["corr"]))
	if m["f"]:
		worst = max(worst, abs(m["l"][1] - 0.5))
print("the worst height over a deck's true surface: %.4f m" % worst)
assert worst < 0.02, worst
def on(n, f):
	assert M[n]["f"] == f, (n, M[n]["f"], f)
for n in "p_fall p_up p_down p_up2 p_across p_across2 p_across3 p_jump p_back_on".split():
	on(n, 7)
for n in "r_fall r_x r_x2 r_x3 r_z r_z2 r_z3 r_diag r_diag2".split():
	on(n, 8)
for n in "a_fall a_a a_b a_c a_d a_jump".split():
	on(n, 9)
for n in "s_on s_lower l_on l_still l_down".split():
	on(n, 10)
for n in "v_world v_object v_edge v_walk".split():
	on(n, 7)
# Moved as asked, up the deck and down it
def d(a, b, k):
	return M[b]["p"][k] - M[a]["p"][k]
assert d("p_fall", "p_up", 1) > 0.1 and d("p_fall", "p_up", 2) < -0.5, "uphill"
assert d("p_up", "p_down", 1) < -0.1 and d("p_up", "p_down", 2) > 0.5, "downhill"
assert abs(d("p_across", "p_across2", 1)) < 0.01 and d("p_across", "p_across2", 0) < -0.5, "across"
assert d("r_fall", "r_x", 0) > 0.5 and abs(d("r_fall", "r_x", 1)) > 0.05, "roll: along it"
assert abs(d("r_z", "r_z2", 1)) < 0.01 and d("r_z", "r_z2", 2) < -0.5, "roll: across it"
# The jumps
assert M["p_jump"]["jumps"] > M["p_across3"]["jumps"], "the jump"
assert M["a_jump"]["jumps"] > M["a_d"]["jumps"], "the jump on all axes"
# Off the low end, on the floor; back on; off the high end; the wall
for n in "p_floor p_floor2 p_at_wall s_floor".split():
	assert M[n]["f"] is None and abs(M[n]["p"][1] - BY) < 0.02, (n, M[n])
o = DECKS[7][0]
assert M["p_floor"]["p"][2] > o[2] + 7.5, "off the low end"
assert M["p_floor2"]["p"][2] < o[2] - 0.5, "off the high end"
assert o[2] - 2 < M["p_at_wall"]["p"][2] < o[2], ("stopped at the high end", M["p_at_wall"])
# The slide: further down on its own, off it
assert d("s_on", "s_lower", 1) < -0.2, "it slid"
# Under a limit past the deck it stands
assert all(abs(d("l_on", "l_still", k)) < 0.001 for k in range(3)), "it stands at limit 65"
assert d("l_still", "l_down", 1) < -0.3, "walked down it at limit 65"
# The order of the frames
frames = re.findall(r"kit +: kit: the body's frame: (\w+)", text)
print("the frames in order:", " ".join(frames))
W = "the"
assert frames == ["7", W, "7", W, "7", W, "8", W, "9", W, "9", W, "10", W, "10", W, "7", W, "7"], frames
assert M[names[-1]]["corr"] == 0, ("corrections", M[names[-1]]["corr"])
print("no corrections in %d acks" % int(re.findall(r"(\d+) acks", text)[-1]))
# What kitbob saw
b = re.findall(r"kit: player (\d+) drawn at ([-\d.]+),([-\d.]+),([-\d.]+)", open(boblog, errors="replace").read())
want = M["bob_saw"]["p"]
near = min(max(abs(float(x[k + 1]) - want[k]) for k in range(3)) for x in b)
print("kitbob draws the body %.3f m from where it is (%s)" % (near, want))
assert near < 0.1, (b, want)
PY
	echo "ok: [KIT_WALKER_FRAME] on decks, off and back, jumped, slid; no corrections; seen by another"
	unset USERDIR BUILDAT_WORKBENCH_TYPES
}
if [ "${1:-}" = frame ] || [ "${2:-}" = frame ]; then
	frame
	echo "PASS: a walker's frame"
	exit 0
fi
if [ "${1:-}" = rotation ] || [ "${2:-}" = rotation ]; then
	rotation
	echo "PASS: free rotation"
	exit 0
fi
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
	edit '{"op": "place", "type": "kit/terrain", "pos": [0, 1, 0]}'
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
	pick "$A" 220 stamped
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
rotation
frame
echo "PASS: a voxel prefab as a free object: placed, moved, turned, members, collision after the move, the save and a load, a prefab's save on all copies, stamped mode, the switch"
