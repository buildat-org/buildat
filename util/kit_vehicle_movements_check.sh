#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~4 min, ~5 min with web (2026-11-07)
# covers: builtin/kit/kit.cpp builtin/kit/client_lua/controls.lua builtin/kit/client_lua/move.lua builtin/kit/client_lua/editor.lua builtin/kit/types/sea_vessel.lua builtin/kit/types/airship.lua builtin/kit/types/turret.lua builtin/kit/types/course.lua builtin/kit/types/car.lua builtin/kit/types/wave.lua builtin/kit/box/box.c apps/workbench/**
# [KIT_VEHICLE_MOVEMENTS] Steered vehicles on a fresh Workbench save: one voxel hull
# prefab, placed free with each stock movement.
#   - 5 a sea vessel with a seat (6) and a turret (7) with its own seat (8) on its deck,
#     and a builder's component whose input raises its thrust and top speed in play
#     (c:set_param); 9 an airship with no seat (driven by its inputs, as a signal
#     would); 10 a car hull with a seat (11); 12 a course (kit/course); 13 a tower
#     with kit/wave.
#   - kitboss and kitbob spawn on the vessel's deck. kitboss drives it, its engine
#     upgraded while he does; hands the seat over to kitbob and walks the deck while
#     kitbob steers. kitcat joins late, the vessel driven by its inputs. kitboss turns
#     the turret, sends the airship up, drives the car.
#   - Measured: the speeds before and after the upgrade, the passengers' corrections
#     (reported), the turret's turn on the deck, the airship's climb, the course, the
#     tower rolling about its centre.
#   - [KIT_WAVE_PIVOT_CENTER] the tower's kit/wave added with its pivot at the tower's
#     centre; moved, and back by the inspector's "Center pivot".
# Native, or "web": kitboss in a page, kitbob and kitcat native.
# Screenshots with KEEP_TMP=1: $t/*.png
#   util/kit_vehicle_movements_check.sh [web]
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
WEB=
[ "${1:-}" = web ] && WEB=1
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_vehicle_movements${WEB:+_web}; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
export BUILDAT_JOIN_PASSWORD=checkpass12
USERDIR=$t/user
export BUILDAT_WORKBENCH_TYPES="$USERDIR/apps/workbench/check_types"
mkdir -p "$BUILDAT_WORKBENCH_TYPES"
# An engine upgrade, as a game would have it: its entity's movement's numbers
cat > "$BUILDAT_WORKBENCH_TYPES/upgrade.lua" <<'LUA'
return {
	version = 1,
	component = true,
	inputs = {upgrade = "number"},
	on_input = function(c, input, v)
		c:set_param(c.id, "kit/sea_vessel", "thrust", v)
		c:set_param(c.id, "kit/sea_vessel", "top_speed", v)
	end,
}
LUA
# Puts the player who tries it where a mark starts
cat > "$BUILDAT_WORKBENCH_TYPES/tele.lua" <<'LUA'
return {
	version = 1,
	inputs = {go = "position"},
	on_input = function(c, input, v)
		c:teleport(v)
	end,
}
LUA
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
cat > "$t/to_web.py" <<'PY'
# A sequence as a page's steps; a held key's delay a holdkey
import json, math, re, sys
PAUSE = [["waitlog_any", "pause: the menu shown", 10], ["eval", "window.lockOk = true, 'lock'"],
	["click", 100, 680], ["waitlog", "pause: the menu closed", 10], ["wait", 500]]
out, held = json.load(open(sys.argv[2])), []
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
	elif cmd == "keydown":
		held.append(rest.lower() if len(rest) == 1 else rest)
	elif cmd == "keyup":
		held = []
	elif cmd == "keypress":
		out.append(["key", rest.lower() if len(rest) == 1 else rest])
	elif cmd == "screenshot":
		out.append(["shot", rest])
	elif cmd == "click":
		m = re.fullmatch(r'(\w+) "([^"]*)"(?: (\d+) (\d+))?', rest)
		out.append(["click", m[1], m[2]] + ([int(m[3]), int(m[4])] if m[3] else []))
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
server()
{
	start_server "$t/srv.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$USERDIR" -l 3 \
		${WEB:+-W "$here/web"} ||
		fail "the server did not come up ($t/srv.log)"
	CHECK_PIDS+=($SERVER_PID)
}
native() # <name>
{
	run_client 90 "$t/$1.log" timeout 300 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" || fail "client $1 failed ($t/$1.log, $t/srv.log)"
}
page() # <name>: kitboss's account of old
{
	printf '[["nav", "${URL}?scale=0.648148"], ["eval", %s], ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["selall"], ["frames", 2], ["type", "kitboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Enter"], ["waitlog", "Joined as kitboss", 30], ["frames", 2]]' \
		"$(printf %s "$PAGE_STUB" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
		> "$t/$1.head.json"
	python3 "$t/to_web.py" "$t/$1.cmds" "$t/$1.head.json" > "$t/$1.json" ||
		fail "the steps of $1"
	WEB_DRIVE_VIEWPORT=1024x700@1 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
		"$here/util/web_drive.sh" chrome workbench "$t/$1.json" "$t/drive_$1" \
		> "$t/drive_$1.txt" 2>&1
	local st=$?
	cp "$t/drive_$1/page.log" "$t/$1.log" 2>/dev/null
	[ $st = 0 ] || fail "the page's $1 ($(tail -2 "$t/drive_$1.txt"), $t/$1.log, $t/srv.log)"
}
c3() { python3 -c "print($1)"; }
ed() { printf 'event kit_edit %s\nsync 5000\n' "$1"; }
vox() { ed "{\"op\": \"set_voxel\", \"pos\": [$1, $2, $3], \"voxel\": \"kit/stone\"}"; }
in_edit() { printf 'event kit_edit {"op": "mode", "on": true}\nwait_log 5000 kit editor: edit mode on\n'; ed "$1"; printf 'event kit_edit {"op": "mode", "on": false}\nwait_log 5000 kit editor: edit mode off\n'; }
try() { in_edit "{\"op\": \"try\", \"id\": $1, \"input\": \"$2\", \"value\": $3}"; }
shake() { try 14 shake "$1"; }
seated() { printf 'event kit_use %s\nwait_log 10000 movement %s, seat %s\nframes 10\n' "$1" "$2" "$1"; }
leave() { printf 'keypress F\nwait_log 10000 kit: controls: camera first_person, pointer crosshair, movement kit/walker\nframes 10\n'; }
sample() # <client> <name> <count>: its body as logged, named in order
{
	local k
	for k in $(seq "$3"); do
		echo "$2" >> "$t/marks_$1.txt"
		printf 'event kit_body\ndelay 200\n'
	done
}
held() # <client> <keys> <ms> <name>: the keys held, sampled
{
	local k
	for k in $2; do echo "keydown $k"; done
	sample "$1" "$4" $(($3 / 200))
	for k in $2; do echo "keyup $k"; done
}
# ---- Set up, natively: the account, the hull's and the tower's prefabs, where a body starts
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
event kit_edit {"op": "mode", "on": true}
wait_log_any 10000 kit editor: edit mode on
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
	ed '{"op": "place", "type": "kit/terrain", "pos": [0, 1, 0]}'
	ed '{"op": "place", "type": "kit/walker", "pos": [0, 1, 0]}'
	for z in $(seq -40 -31); do
		for x in $(seq 3 8); do
			vox $x 1 $z
		done
	done
	ed '{"op": "save_prefab", "ids": [], "box": [3, 1, -40, 8, 1, -31], "name": "hull"}'
	for y in 1 2 3 4; do
		for z in -50 -49; do
			for x in 3 4; do
				vox $x $y $z
			done
		done
	done
	ed '{"op": "save_prefab", "ids": [], "box": [3, 1, -50, 4, 4, -49], "name": "tower"}'
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
event kit_edit {"op": "mode", "on": false}
wait_log 10000 kit editor: edit mode off
frames 10
sync 3000
event kit_body
sync 3000
quit
EOF
} > "$t/setup.cmds"
server
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" native setup
read -r bx by bz < <(grep -aoP 'kit: feet at \K[-0-9.,]+' "$t/setup.log" | tail -1 | tr , ' ')
[ -n "${bz:-}" ] || fail "no body's place ($t/setup.log)"
g=$(c3 "round($by - 0.5)")
echo "the ground's top at $g + 0.5"
# 3 world, 4 walker; 5 the vessel, 6 its seat, 7 the turret, 8 its seat; 9 the airship;
# 10 the car's hull, 11 its seat; 12 the course; 13 the tower; 14 controls, 15 the spawner,
# 16 a teleporter, 17 a car on the vessel's deck
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
event kit_edit {"op": "mode", "on": true}
wait_log_any 10000 kit editor: edit mode on
event kit_edit {"op": "stop"}
wait_log_any 10000 kit editor: the server is Ended (by kitboss)
EOF
	ed "{\"op\": \"place\", \"prefab\": \"kitboss/hull\", \"pos\": [4, $((g + 2)), -30], \"free\": true}"
	ed '{"op": "add_component", "id": 5, "type": "kit/sea_vessel"}'
	ed '{"op": "set", "id": 5, "comp": 1, "param": "water", "value": "level"}'
	ed "{\"op\": \"set\", \"id\": 5, \"comp\": 1, \"param\": \"water_level\", \"value\": $((g + 3))}"
	# (slowed and turned quickly: the world is small)
	ed '{"op": "set", "id": 5, "comp": 1, "param": "drag", "value": 1.5}'
	ed '{"op": "set", "id": 5, "comp": 1, "param": "turn_rate", "value": 60}'
	ed '{"op": "add_component", "id": 5, "type": "workbench/upgrade"}'
	ed "{\"op\": \"place\", \"type\": \"kit/part\", \"parent\": 5, \"pos\": [6, $((g + 3)), -28], \"params\": {\"size\": [0.8, 0.5, 0.8], \"color\": \"#c03030\"}}"
	ed '{"op": "add_component", "id": 6, "type": "kit/seat"}'
	ed "{\"op\": \"place\", \"type\": \"kit/part\", \"parent\": 5, \"pos\": [7, $((g + 3)), -24], \"params\": {\"size\": [0.6, 0.6, 2], \"color\": \"#303030\"}}"
	ed '{"op": "add_component", "id": 7, "type": "kit/turret"}'
	ed "{\"op\": \"place\", \"type\": \"kit/part\", \"parent\": 7, \"pos\": [7, $((g + 3)), -26], \"params\": {\"size\": [0.8, 0.5, 0.8], \"color\": \"#3030c0\"}}"
	ed '{"op": "add_component", "id": 8, "type": "kit/seat"}'
	ed "{\"op\": \"place\", \"prefab\": \"kitboss/hull\", \"pos\": [-14, $((g + 6)), 0], \"free\": true}"
	ed '{"op": "add_component", "id": 9, "type": "kit/airship"}'
	ed "{\"op\": \"place\", \"prefab\": \"kitboss/hull\", \"pos\": [16, $((g + 1)), -10], \"free\": true}"
	ed '{"op": "add_component", "id": 10, "type": "kit/car"}'
	ed "{\"op\": \"place\", \"type\": \"kit/part\", \"parent\": 10, \"pos\": [18, $((g + 2)), -8], \"params\": {\"size\": [0.8, 0.5, 0.8], \"color\": \"#30c030\"}}"
	ed '{"op": "add_component", "id": 11, "type": "kit/seat"}'
	ed "{\"op\": \"place\", \"prefab\": \"kitboss/hull\", \"pos\": [-14, $((g + 1)), 14], \"free\": true}"
	ed '{"op": "add_component", "id": 12, "type": "kit/course"}'
	ed '{"op": "set", "id": 12, "comp": 1, "param": "course", "value": [6, 0, 0]}'
	ed '{"op": "set", "id": 12, "comp": 1, "param": "course_time", "value": 3}'
	# [KIT_WAVE_PIVOT_CENTER] the pivot at the tower's middle by itself
	ed "{\"op\": \"place\", \"prefab\": \"kitboss/tower\", \"pos\": [-26, $((g + 1)), -8], \"free\": true}"
	ed '{"op": "add_component", "id": 13, "type": "kit/wave"}'
	ed '{"op": "set", "id": 13, "comp": 1, "param": "wave_roll", "value": 25}'
	ed '{"op": "set", "id": 13, "comp": 1, "param": "wave_roll_period", "value": 4}'
	ed '{"op": "place", "type": "kit/controls", "pos": [0, 1, 0]}'
	ed "{\"op\": \"place\", \"type\": \"kit/spawner\", \"pos\": [6, $((g + 5)), -26]}"
	ed '{"op": "set", "id": 15, "comp": 0, "param": "players", "value": true}'
	ed '{"op": "place", "type": "workbench/tele", "pos": [0, 1, -4]}'
	# A car carried on the vessel's deck, nobody in it
	ed "{\"op\": \"place\", \"type\": \"kit/part\", \"parent\": 5, \"pos\": [5, $((g + 3)), -23], \"params\": {\"size\": [1.6, 0.7, 3], \"color\": \"#c0c030\"}}"
	ed '{"op": "add_component", "id": 17, "type": "kit/car"}'
	cat <<EOF
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
event kit_edit {"op": "mode", "on": false}
wait_log 10000 kit editor: edit mode off
wait_log 20000 kit: the body's frame: 5
EOF
	sample boss stand 5
	# ---- The vessel driven, its engine upgraded on the way
	seated 6 kit/sea_vessel
	printf 'look_dir 0 -0.3 1\n'
	held boss W 2000 sea_w
	echo "screenshot $t/sea_driven.png"
	try 5 upgrade 12
	held boss W 1000 sea_up
	held boss A 2000 sea_turn
	leave
	sample boss left 3
	# ---- Handed over: kitbob drives, kitboss walks the deck
	shake 0.01
	printf 'delay 1500\n'
	sample boss pass_stand 10
	printf 'look_dir 1 0 0\nframes 2\n'
	held boss W 400 pass_walk
	printf 'look_dir -1 0 0\nframes 2\n'
	held boss W 400 pass_walk
	printf 'look_dir 0 0 1\nframes 2\n'
	held boss W 400 pass_walk
	printf 'look_dir 0 0 -1\nframes 2\n'
	held boss W 400 pass_walk
	sample boss pass_stand2 10
	echo "screenshot $t/passenger.png"
	printf 'keydown Space\ndelay 100\nkeyup Space\n'
	sample boss pass_jump 8
	# ---- Nobody in it: driven by its inputs, a late joiner sees it
	try 5 throttle 0.6
	try 5 steer 1
	shake 0.03
	sample boss free_drive 10
	echo "wait_log 120000 's body drawn"
	sample boss late 20
	# ---- The gunman: the turret turned on the moving deck
	seated 8 kit/turret
	held boss D 1500 turret
	echo "screenshot $t/turret.png"
	leave
	try 5 throttle 0
	try 5 steer 0
	# ---- The airship up, by its inputs
	try 9 throttle 1
	try 9 climb 1
	sample boss airship 15
	try 9 climb 0
	sample boss airship_held 10
	printf 'look_dir -1 0.3 0\nframes 5\nscreenshot %s\n' "$t/airship.png"
	# ---- The car on its free hull
	try 16 go "[19.5, $((g + 4)), -7]"
	printf 'delay 1000\n'
	seated 11 kit/car
	held boss W 2000 car
	echo "screenshot $t/car.png"
	leave
	# ---- At Stop: the pivot moved, the inspector's Center
	printf 'event kit_edit {"op": "mode", "on": true}\nwait_log 5000 kit editor: edit mode on\n'
	printf 'event kit_edit {"op": "stop"}\nwait_log 10000 kit editor: the server is Ended (by kitboss)\nsync 3000\n'
	ed '{"op": "set", "id": 13, "comp": 1, "param": "pivot", "value": [0, 0, 0]}'
	printf 'event kit_select 13\nframes 10\nscreenshot %s\n' "$t/pivot_moved.png"
	printf 'click Button "Center pivot"\nwait_log 5000 pivot centred\nsync 3000\nframes 5\nscreenshot %s\n' "$t/pivot_centred.png"
	printf 'sync 3000\nquit\n'
} > "$t/boss.cmds"
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log 200000 kit: the body's frame: 5
EOF
	sample bob stand 30
	echo "screenshot $t/bob_deck.png"
	echo "wait_log_any 200000 kit: camera shake 0.01"
	seated 6 kit/sea_vessel
	held bob "W D" 2000 bob_drive
	echo "screenshot $t/bob_driving.png"
	held bob D 4000 bob_drive
	leave
	sample bob after 5
	echo "wait_log_any 200000 kit: camera shake 0.03"
	printf 'sync 1000\nquit\n'
} > "$t/bob.cmds"
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitcat
wait_log_any 60000 player physics enabled
delay 1000
EOF
	printf 'look_dir 0 -0.2 1\nframes 5\n'
	sample cat late 15
	echo "screenshot $t/cat_late.png"
	printf "look_dir -1 -0.2 0\nframes 5\nscreenshot %s\n" "$t/cat_late2.png"
	printf 'sync 1000\nquit\n'
} > "$t/cat.cmds"
# (bob first: he must be in when it plays)
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 native bob &
bob=$!
wait_for_log "$t/bob.log" "player physics enabled" 120 || fail "kitbob did not get in ($t/bob.log)"
if [ -n "$WEB" ]; then
	page boss &
else
	BUILDAT_JOIN_NAME=kitboss native boss &
fi
boss=$!
wait_for_log "$t/srv.log" "kitboss tries entity 14's shake 0.03" 300 || fail "not to the late joiner ($t/boss.log)"
BUILDAT_JOIN_NAME=kitcat BUILDAT_JOIN_CREATE=1 native cat &
cat=$!
wait $cat || fail "kitcat's client ($t/cat.log)"
wait $bob || fail "kitbob's client ($t/bob.log)"
wait $boss || fail "kitboss's client ($t/boss.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
python3 - "$t" "$g" <<'PY' || fail "the vehicles ($t/boss.log, $t/srv.log)"
import math, re, sys
t, g = sys.argv[1], float(sys.argv[2])
srv = open(t + "/srv.log", errors="replace").read()
def mul(a, b):
	return [a[0]*b[0]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3], a[0]*b[1]+a[1]*b[0]+a[2]*b[3]-a[3]*b[2],
		a[0]*b[2]-a[1]*b[3]+a[2]*b[0]+a[3]*b[1], a[0]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[0]]
def rot(q, v):
	return mul(mul(q, [0] + list(v)), [q[0], -q[1], -q[2], -q[3]])[1:]
def secs(line):
	h, m, s = re.search(r" (\d\d):(\d\d):(\d\d\.\d+) ", line).groups()
	return int(h) * 3600 + int(m) * 60 + float(s)
def samples(name):
	marks = open("%s/marks_%s.txt" % (t, name)).read().split()
	out, cur = [], None
	for l in open("%s/%s.log" % (t, name), errors="replace"):
		m = re.search(r"kit: body at [-0-9.,]+, (\d+) acks, (\d+) corrections", l)
		if m:
			cur = {"t": secs(l), "corr": int(m[2]), "nodes": {}, "ents": {}}
			out.append(cur)
			continue
		m = re.search(r"kit: feet at ([-0-9.]+),([-0-9.]+),([-0-9.]+), frame (\S+)", l)
		if m and cur:
			cur["p"], cur["frame"] = [float(m[k]) for k in (1, 2, 3)], m[4]
		if "kit: moving:" in l and cur:
			cur["drawn"] = float(re.search(r"drawn at ([-0-9.]+)", l)[1])
			for m in re.finditer(r"(\d+) node ([-0-9.]+),([-0-9.]+),([-0-9.]+) turn ([-0-9.]+),([-0-9.]+),([-0-9.]+),([-0-9.]+)", l):
				cur["nodes"][int(m[1])] = ([float(m[k]) for k in (2, 3, 4)], [float(m[k]) for k in (5, 6, 7, 8)])
			for m in re.finditer(r"(\d+) entity ([-0-9.]+),([-0-9.]+),([-0-9.]+) facing ([-0-9.]+),([-0-9.]+),([-0-9.]+)", l):
				cur["ents"][int(m[1])] = ([float(m[k]) for k in (2, 3, 4)], [float(m[k]) for k in (5, 6, 7)])
	assert len(out) == len(marks), (name, len(out), len(marks))
	for s, k in zip(out, marks):
		s["mark"] = k
	return out
S = {n: samples(n) for n in ("boss", "bob", "cat")}
def phase(n, *names):
	return [s for s in S[n] if s["mark"] in names]
def speed(ss):
	a, b = ss[-3], ss[-1]
	return math.hypot(b["p"][0] - a["p"][0], b["p"][2] - a["p"][2]) / (b["t"] - a["t"])
def heading(a, b):
	return math.degrees(math.atan2(b["p"][0] - a["p"][0], b["p"][2] - a["p"][2]))
def yaw_of(q):
	return math.degrees(2 * math.atan2(q[2], q[0]))
def wrap(a):
	return (a + 180) % 360 - 180
for w in ("Entity 5's kit/sea_vessel steps in play", "Entity 7's kit/turret steps in play",
		"Entity 9's kit/airship steps in play", "Entity 10's kit/car steps in play",
		"Entity 17's kit/car steps in play",
		"Entity 5's kit/sea_vessel thrust set to 12 in play", "Entity 5's kit/sea_vessel top_speed set to 12 in play",
		"kitboss leaves the seat of entity 6", "kitbob leaves the seat of entity 6",
		"kitboss leaves the seat of entity 8", "kitboss leaves the seat of entity 11"):
	assert w in srv, w
assert "Entity 12's kit/course steps" not in srv, "a course is timed"
# The vessel: the upgrade's speed, the turn
v1, v2 = speed(phase("boss", "sea_w")), speed(phase("boss", "sea_up"))
print("the vessel: %.2f m/s after 2 s of W, %.2f after 1 s more upgraded" % (v1, v2))
assert 1 < v1 < 2.5 and v2 > v1 + 2, (v1, v2)
tu = phase("boss", "sea_turn")
turn = wrap(heading(tu[-3], tu[-1]) - heading(tu[0], tu[2]))
print("the vessel's heading turned %.1f degrees by A" % turn)
assert turn < -10, turn
# kitbob took the seat over and drove
bd = phase("bob", "bob_drive")
moved = math.hypot(bd[-1]["p"][0] - bd[0]["p"][0], bd[-1]["p"][2] - bd[0]["p"][2])
print("kitbob drove %.2f m" % moved)
assert moved > 2, moved
# The passengers: on the deck all along, corrections counted
for n, ph in (("bob", ("stand",)), ("boss", ("pass_stand", "pass_walk", "pass_stand2"))):
	ss = phase(n, *ph)
	frames = set(s["frame"] for s in ss)
	print("%s on the steered deck: %d samples, frames %s, %d corrections" % (n, len(ss),
		sorted(frames), ss[-1]["corr"] - ss[0]["corr"]))
	assert frames == {"5"}, (n, frames)
	assert ss[-1]["p"] != ss[0]["p"], "not carried"
# The late joiner draws the vessel where kitboss does at the same shared time
diffs = []
for c in phase("cat", "late"):
	if 5 not in c["nodes"]:
		continue
	bs = [s for s in S["boss"] if 5 in s["nodes"] and "drawn" in s]
	for a, b in zip(bs, bs[1:]):
		if a["drawn"] <= c["drawn"] <= b["drawn"] and b["drawn"] - a["drawn"] < 0.5:
			u = (c["drawn"] - a["drawn"]) / (b["drawn"] - a["drawn"])
			pa, pb = a["nodes"][5][0], b["nodes"][5][0]
			diffs.append(math.dist(c["nodes"][5][0], [x + (y - x) * u for x, y in zip(pa, pb)]))
print("the late joiner's vessel against kitboss's: %d samples, at most %.3f m apart" %
	(len(diffs), max(diffs or [0])))
assert len(diffs) >= 5 and max(diffs) < 0.3, diffs
# The turret on the moving deck: turned on it, kept its place on it
tr = [s for s in phase("boss", "turret") if 7 in s["ents"] and 5 in s["nodes"]]
assert len(tr) >= 5, len(tr)
def rel(s):
	f = s["ents"][7][1]
	return wrap(math.degrees(math.atan2(f[0], f[2])) - yaw_of(s["nodes"][5][1]))
def off(s):
	p, q = s["nodes"][5]
	return rot([q[0], -q[1], -q[2], -q[3]], [a - b for a, b in zip(s["ents"][7][0], p)])
spread = max(math.dist(off(s), off(tr[0])) for s in tr)
print("the turret turned %.1f degrees on the deck, its place on it within %.3f m" %
	(wrap(rel(tr[-1]) - rel(tr[0])), spread))
assert abs(wrap(rel(tr[-1]) - rel(tr[0]))) > 20 and spread < 0.05, (rel(tr[0]), rel(tr[-1]), spread)
# The car on the deck: carried, it keeps its place on it (after it settles)
cd_ = [s for s in S["boss"] if 17 in s["ents"] and 5 in s["nodes"]][5:]
def off17(s):
	p, q = s["nodes"][5]
	return rot([q[0], -q[1], -q[2], -q[3]], [a - b for a, b in zip(s["ents"][17][0], p)])
moved = max(math.dist(s["nodes"][5][0], cd_[0]["nodes"][5][0]) for s in cd_)
spread = max(math.dist(off17(s), off17(cd_[0])) for s in cd_)
print("the car on the deck: %d samples, the deck moved %.1f m, the car's place on it within %.3f m" %
	(len(cd_), moved, spread))
assert len(cd_) > 20 and moved > 10 and spread < 0.1, (len(cd_), moved, spread)
# The airship up by its inputs, then held
ai = [s["nodes"][9][0][1] for s in phase("boss", "airship") if 9 in s["nodes"]]
ah = [s["nodes"][9][0][1] for s in phase("boss", "airship_held") if 9 in s["nodes"]]
print("the airship: %.2f to %.2f climbing, %.2f to %.2f held (it closes on its altitude)" %
	(ai[0], ai[-1], ah[0], ah[-1]))
assert ai[-1] - ai[0] > 2 and abs(ah[-1] - ah[-3]) < 0.2, (ai, ah)
# The car driven
ca = phase("boss", "car")
moved = math.hypot(ca[-1]["p"][0] - ca[0]["p"][0], ca[-1]["p"][2] - ca[0]["p"][2])
ys = [s["p"][1] for s in ca]
print("the car drove %.2f m, its seat's feet at %.2f..%.2f" % (moved, min(ys), max(ys)))
assert moved > 2 and g + 1 < min(ys) and max(ys) < g + 4, (moved, ys)
# The course
cx = [s["nodes"][12][0][0] for s in S["boss"] if 12 in s["nodes"]]
print("the course: x %.2f..%.2f" % (min(cx), max(cx)))
assert max(cx) - min(cx) > 4, cx
# [KIT_WAVE_PIVOT_CENTER] The tower: its kit/wave's pivot its centre, rolled about it
m = re.search(r"added kit/wave to 13, its pivot \[([-0-9.e]+),([-0-9.e]+),([-0-9.e]+)\]", srv)
assert m, "no pivot at the add"
piv = [float(m[k]) for k in (1, 2, 3)]
assert piv == [0.5, 1.5, 0.5], piv
centre = [-26 + piv[0], g + 1 + piv[1], -8 + piv[2]]
worst, rolls = 0, []
for s in S["boss"]:
	if 13 in s["nodes"]:
		p, q = s["nodes"][13]
		c = [a + b for a, b in zip(p, rot(q, [x + 0.5 for x in piv]))]
		worst = max(worst, math.dist(c, centre))
		rolls.append(math.degrees(2 * math.atan2(q[3], q[0])))
print("the tower: pivot %s, rolled %.1f..%.1f degrees, its centre at most %.4f m from %s" %
	(piv, min(rolls), max(rolls), worst, centre))
assert max(rolls) - min(rolls) > 20 and worst < 0.02, (rolls, worst)
sets = re.findall(r"set 13's kit/wave pivot to (\S+)", srv)
print("the pivot's sets:", sets)
assert sets == ["[0,0,0]", "[0.5,1.5,0.5]"], sets
PY
echo "PASS: vehicle movements${WEB:+ (web)}"
