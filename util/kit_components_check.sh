#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min, ~3 min with web (2026-11-07)
# covers: builtin/kit/kit.cpp builtin/kit/client_lua/editor.lua builtin/kit/client_lua/controls.lua builtin/kit/types/car.lua builtin/kit/types/car.prefab.json builtin/kit/types/seat.lua builtin/kit/types/wave.lua builtin/kit/types/prefab_copy.lua apps/workbench/**
# [KIT_COMPONENTS] Components on one entity, on a fresh Workbench save:
#   - A kit/part hull at the place today's car was measured at, the inspector's Add
#     component and Remove clicked: kit/timer on and off, kit/seat (its hint), kit/car.
#     An undo of each kind; the refusals, each with its reason.
#   - Driven as today's car: W from rest, S, then D and W from rest. The numbers below
#     were measured on a kit/car of commit 316b1e65c (one type: seat, movement, look)
#     by the same keys, and are functions of the place, not of the frames: speed by the
#     distance, the turn's yaw and path. Ride height, no corrections.
#   - Live, Running: a component before another removed under its timers (one tick
#     stream, no second start, on_remove once); the seat and then the movement taken
#     from under the driver (out of the seat), undone (a seat again). A builder's own
#     movement (workbench/sled) with a seat.
#   - The palette's prefab kit/car: placed, driven, back at Stop, its built hull's
#     components refused. A prefab saved from a hull, its copy's override kept by type
#     when the prefab's components change order.
#   - A restart: the three components in the save, the seat taken again.
# Native, or "web": the inspector and the drive in a page, the restart native.
# Screenshots with KEEP_TMP=1: $t/*.png
#   util/kit_components_check.sh [web]
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
WEB=
[ "${1:-}" = web ] && WEB=1
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_components${WEB:+_web}; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
export BUILDAT_JOIN_PASSWORD=checkpass12
USERDIR=$t/user
export BUILDAT_WORKBENCH_TYPES="$USERDIR/apps/workbench/check_types"
mkdir -p "$BUILDAT_WORKBENCH_TYPES"
# A builder's movement
cat > "$BUILDAT_WORKBENCH_TYPES/sled.lua" <<'LUA'
return {
	version = 1,
	component = true,
	movement = {body = {r = 1, h = 1}, camera = "chase", touch = "drive"},
	params = {speed = {type = "number", default = 4, min = 0, max = 20},
		rate = {type = "number", default = 60, min = 10, max = 120}},
	step = function(s, i, dt, w, p)
		s.pos = type(s.pos) == "table" and s.pos or {0, 0, 0}
		s.vel = {0, 0, (i.f or 0) * (p.speed or 4)}
		s.pos[3] = s.pos[3] + s.vel[3] * dt
	end,
}
LUA
# Its timers named and its starts and removes said in the log, two of it
for n in spy ear; do
	cat > "$BUILDAT_WORKBENCH_TYPES/$n.lua" <<LUA
return {
	version = 1,
	component = true,
	state = {n = {default = 0}},
	on_start = function(c)
		c:log("$n started")
		c:after(0.05, "t")
	end,
	on_timer = function(c)
		c.state.n = c.state.n + 1
		c:log("$n tick " .. c.state.n)
		c:after(0.05, "t")
	end,
	on_remove = function(c)
		c:log("$n removed")
	end,
}
LUA
done
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
import json, re, sys
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
	elif cmd == "quit":
		out.append(["sync", 3000])
	else:
		sys.exit("no page's step for: " + line)
json.dump(out, sys.stdout)
PY
server()
{
	start_server "$t/srv$1.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$USERDIR" -l 3 \
		${WEB:+-W "$here/web"} ||
		fail "the server did not come up ($t/srv$1.log)"
	CHECK_PIDS+=($SERVER_PID)
}
native() # <name>
{
	run_client 150 "$t/$1.log" timeout 240 bin/buildat -C "$t/client_cache" \
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
ed() { printf 'event kit_edit %s\nsync 5000\n' "$1"; }
stop() { printf 'event kit_edit {"op": "mode", "on": true}\nwait_log 5000 kit editor: edit mode on\nevent kit_edit {"op": "stop"}\nwait_log 10000 kit editor: the server is Ended (by kitboss)\nsync 3000\n'; }
play() { printf 'event kit_edit {"op": "play"}\nwait_log 10000 kit editor: the server is Running (by kitboss)\nevent kit_edit {"op": "mode", "on": false}\nwait_log 10000 kit editor: edit mode off\nframes 30\n'; }
in_edit() { printf 'event kit_edit {"op": "mode", "on": true}\nwait_log 5000 kit editor: edit mode on\n'; ed "$1"; printf 'event kit_edit {"op": "mode", "on": false}\nwait_log 5000 kit editor: edit mode off\n'; }
seated() { printf 'event kit_use %s\nwait_log 10000 movement %s, seat %s\nframes 60\ndelay 1000\n' "$1" "$2" "$1"; }
pick() # <the dropdown's item>: Add component in the inspector, the item clicked
{
	printf 'click DropDownList "▼" 950 170\ndelay 300\nclick Text "%s" 950 500\nwait_log 5000 kit editor: add %s to\nwait_log 5000 kit editor: state:\nsync 3000\nframes 5\n' "$1" "$1"
}
# ---- Set up, natively: the account, the world, the walker
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
	ed '{"op": "place", "type": "kit/world", "pos": [0, 1, 0]}'
	ed '{"op": "place", "type": "kit/walker", "pos": [0, 1, 0]}'
	printf 'sync 1000\nquit\n'
} > "$t/setup.cmds"
server ""
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" native setup
# 3 world, 4 walker, 5 the hull, 6 a timer alone, 7 the sled's hull, 8 the spies'; 9 the prefab's
# root, 10 its hull; 11 my_car's source, 12 its copy's root, 13 its hull; 14 a free hut's root
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
event kit_edit {"op": "mode", "on": true}
wait_log_any 10000 kit editor: edit mode on
EOF
	ed '{"op": "place", "type": "kit/part", "pos": [0, 1, 4], "params": {"size": [1.8, 0.7, 3.6], "color": "#3060c0"}}'
	echo 'event kit_select 5'
	printf 'frames 5\nscreenshot %s\n' "$t/add_none.png"
	# On and off by the buttons
	pick kit/timer
	printf 'screenshot %s\nclick Button "Remove"\nwait_log 5000 kit editor: remove kit/timer from 5\nsync 3000\nframes 5\nscreenshot %s\n' "$t/add_timer.png" "$t/removed_timer.png"
	pick kit/seat
	printf 'screenshot %s\n' "$t/add_seat.png"
	pick kit/car
	printf 'screenshot %s\n' "$t/add_car.png"
	# Undo of an add and of a remove
	ed '{"op": "add_component", "id": 5, "type": "kit/logic"}'
	ed '{"op": "undo"}'
	ed '{"op": "remove_component", "id": 5, "comp": 1}'
	ed '{"op": "undo"}'
	# The refusals
	ed '{"op": "add_component", "id": 5, "type": "kit/car"}'
	ed '{"op": "add_component", "id": 5, "type": "workbench/sled"}'
	ed '{"op": "remove_component", "id": 5, "comp": 0}'
	ed '{"op": "place", "type": "kit/car", "pos": [0, 1, 4]}'
	ed '{"op": "add_component", "id": 5, "type": "kit/wave"}'
	ed '{"op": "add_component", "id": 5, "type": "kit/door"}'
	ed '{"op": "add_component", "id": 5, "type": "kit/starting_kit"}'
	ed '{"op": "add_component", "id": 2, "type": "kit/seat"}'
	ed '{"op": "place", "type": "kit/timer", "pos": [0, 1, 0]}'
	ed '{"op": "remove_component", "id": 6, "comp": 0}'
	ed '{"op": "add_component", "id": 6, "type": "kit/seat"}'
	# A builder's movement with a seat; spies for the live remove
	ed '{"op": "place", "type": "kit/part", "pos": [2, 1, 8], "params": {"size": [2, 1, 2], "collision": false}}'
	ed '{"op": "add_component", "id": 7, "type": "workbench/sled"}'
	ed '{"op": "add_component", "id": 7, "type": "kit/seat"}'
	ed '{"op": "place", "type": "kit/part", "pos": [-6, 1, 10]}'
	ed '{"op": "add_component", "id": 8, "type": "workbench/ear"}'
	ed '{"op": "add_component", "id": 8, "type": "workbench/spy"}'
	play
	# ---- Driven: W from rest (a sample while it is held), S (two)
	seated 5 kit/car
	cat <<EOF
event kit_body
event kit_body_in 1400
keydown W
delay 1500
keyup W
event kit_body_in 80
event kit_body_in 380
keydown S
delay 450
keyup S
frames 3
screenshot $t/driven.png
event kit_body
keypress F
wait_log 10000 kit: controls: camera first_person, pointer crosshair, movement kit/walker
EOF
	stop
	play
	seated 5 kit/car
	cat <<EOF
event kit_body_in 1400
keydown D
keydown W
delay 1500
keyup W
keyup D
frames 3
screenshot $t/turned.png
event kit_body
keypress F
wait_log 10000 kit: controls: camera first_person, pointer crosshair, movement kit/walker
EOF
	stop
	play
	# ---- Live: the seat and the movement taken from under the driver
	seated 5 kit/car
	in_edit '{"op": "remove_component", "id": 5, "comp": 1}'
	in_edit '{"op": "undo"}'
	seated 5 kit/car
	in_edit '{"op": "remove_component", "id": 5, "comp": 2}'
	in_edit '{"op": "undo"}'
	seated 5 kit/car
	printf 'keypress F\nwait_log 10000 kit: controls: camera first_person, pointer crosshair, movement kit/walker\n'
	# A component's Remove with another's timers running after it
	printf 'delay 300\n'
	in_edit '{"op": "remove_component", "id": 8, "comp": 1}'
	printf 'delay 300\n'
	in_edit '{"op": "undo"}'
	printf 'delay 300\nscreenshot %s\n' "$t/live.png"
	# ---- A builder's movement
	seated 7 workbench/sled
	cat <<EOF
event kit_body
event kit_body_in 400
keydown W
delay 500
keyup W
frames 3
event kit_body
keypress F
wait_log 10000 kit: controls: camera first_person, pointer crosshair, movement kit/walker
EOF
	stop
	# ---- The palette's car and a builder's prefab
	ed '{"op": "place", "prefab": "kit/car", "pos": [3, 1, -2]}'
	ed '{"op": "add_component", "id": 10, "type": "kit/timer"}'
	ed '{"op": "remove_component", "id": 10, "comp": 2}'
	ed '{"op": "place", "type": "kit/part", "pos": [12, 1, 4]}'
	ed '{"op": "add_component", "id": 11, "type": "kit/car"}'
	ed '{"op": "add_component", "id": 11, "type": "kit/seat"}'
	ed '{"op": "save_prefab", "ids": [11], "name": "my_car"}'
	ed '{"op": "place", "prefab": "kitboss/my_car", "pos": [12, 1, 10]}'
	ed '{"op": "set", "id": 13, "comp": 1, "param": "top_speed", "value": 9}'
	ed '{"op": "remove_component", "id": 11, "comp": 1}'
	ed '{"op": "add_component", "id": 11, "type": "kit/car"}'
	ed '{"op": "save_prefab", "ids": [11], "name": "my_car"}'
	# A free voxel object: a wave and a movement ([KIT_VEHICLE_MOVEMENTS]). (14 its root)
	ed '{"op": "place", "prefab": "kit/hut", "pos": [-20, 1, -20], "free": true}'
	ed '{"op": "add_component", "id": 14, "type": "kit/wave"}'
	ed '{"op": "add_component", "id": 14, "type": "kit/car"}'
	printf 'event kit_select 13\nframes 5\nscreenshot %s\n' "$t/built.png"
	play
	seated 10 kit/car
	cat <<EOF
event kit_body
keydown W
delay 400
keyup W
frames 3
screenshot $t/prefab_car.png
event kit_body
keypress F
wait_log 10000 kit: controls: camera first_person, pointer crosshair, movement kit/walker
EOF
	stop
	printf 'sync 3000\nquit\n'
} > "$t/boss.cmds"
if [ -n "$WEB" ]; then
	page boss
else
	BUILDAT_JOIN_NAME=kitboss native boss
fi
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
# ---- Restarted: in the save, a seat again
db=$(find "$USERDIR" -name save.sqlite -path "*/saves/world/*" | head -1)
[ -n "$db" ] || fail "no save.sqlite under $USERDIR"
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
EOF
	printf 'event kit_edit {"op": "mode", "on": true}\nwait_log_any 5000 kit editor: edit mode on\n'
	play
	seated 5 kit/car
	printf 'quit\n'
} > "$t/after.cmds"
server 2
BUILDAT_JOIN_NAME=kitboss native after
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
python3 - "$t" "$db" <<'PY' || fail "components on one entity ($t/boss.log, $t/srv.log)"
import bisect, json, math, re, sqlite3, sys
t, db = sys.argv[1:3]
# Today's car, measured by the same keys at the same place (commit 316b1e65c, native):
# (z, speed along it) with W from rest, on through S and into reverse; (x, z, yaw) with
# D and W from rest; its height at rest
STRAIGHT = [(4.0000, 0.0000), (4.0025, 0.1492), (4.0248, 0.5925), (4.0690, 1.0291), (4.1614, 1.6010), (4.2556, 2.0222), (4.3705, 2.4370), (4.5060, 2.8454), (4.7180, 3.3801), (4.9002, 3.7738), (5.1018, 4.1614), (5.3226, 4.5428), (5.6464, 5.0420), (5.9107, 5.4095), (6.2914, 5.8903), (6.5978, 6.2441), (6.9216, 6.5922), (7.3801, 7.0476), (7.7437, 7.3826), (8.2542, 7.8207), (8.6560, 8.1430), (9.0737, 8.4600), (9.5071, 8.7717), (10.1089, 9.1792), (10.5779, 9.4788), (11.0617, 9.7735), (11.5600, 10.0631), (12.0727, 10.3479), (12.7781, 10.7200), (13.3232, 10.9936), (14.0711, 11.3511)]
BRAKING = [(14.8360, 11.3192), (15.3728, 10.4457), (16.0215, 9.3039), (16.4587, 8.4644), (16.8543, 7.6387), (17.2091, 6.8266), (17.6198, 5.7643), (17.8819, 4.9825), (18.1054, 4.2131), (18.3442, 3.2060), (18.4797, 2.4644), (18.5785, 1.7342), (18.6542, 0.7778)]
TURN = [(0.0000, 4.0000, 0.000), (0.0000, 4.0025, 0.033), (0.0000, 4.0149, 0.194), (0.0006, 4.0690, 0.854), (0.0022, 4.1347, 1.607), (0.0056, 4.2218, 2.554), (0.0118, 4.3296, 3.674), (0.0264, 4.5051, 5.405), (0.0437, 4.6599, 6.864), (0.0679, 4.8338, 8.446), (0.1004, 5.0262, 10.140), (0.1591, 5.3104, 12.559), (0.2164, 5.5431, 14.482), (0.2868, 5.7915, 16.491), (0.3718, 6.0547, 18.580), (0.5100, 6.4264, 21.479), (0.6342, 6.7191, 23.732), (0.7774, 7.0223, 26.049), (0.9408, 7.3345, 28.425), (1.1922, 7.7618, 31.678), (1.4072, 8.0884, 34.179), (1.6458, 8.4183, 36.727), (2.0021, 8.8598, 40.196), (2.2988, 9.1897, 42.847), (2.6213, 9.5162, 45.539), (2.9699, 9.8372, 48.268), (3.3448, 10.1505, 51.034), (3.8857, 10.5525, 54.774), (4.4730, 10.9317, 58.572), (4.9435, 11.1979, 61.456), (5.4390, 11.4460, 64.369), (6.1372, 11.7448, 68.295), (6.6878, 11.9422, 71.270), (7.2603, 12.1143, 74.270), (8.0553, 12.3007, 78.307), (8.6733, 12.4059, 81.360), (9.3081, 12.4792, 84.436), (10.1772, 12.5244, 88.568), (10.8436, 12.5168, 91.691), (11.5199, 12.4720, 94.832), (12.4332, 12.3522, 99.048)]
RIDE = 0.8167
log = open(t + "/boss.log", errors="replace").read()
srv = open(t + "/srv.log", errors="replace").read()
def along(curve, z):
	# (speed squared is near straight in the distance)
	for (z0, v0), (z1, v1) in zip(curve, curve[1:]):
		if z0 <= z <= z1:
			return math.sqrt(v0 * v0 + (v1 * v1 - v0 * v0) * (z - z0) / (z1 - z0))
	raise AssertionError("past the measured curve", z)
# The samples, each a feet line and its vehicle line, by the seat they were in
samples, seat, ride, corr, worst = [], None, 0, 0, 0
for l in log.splitlines():
	m = re.search(r"controls: camera \w+, pointer \w+, movement (\S+?)(?:, seat (\d+))?$", l)
	if m:
		seat, ride = m[2] and int(m[2]), ride + 1
		continue
	m = re.search(r"kit: body at [-\d.,]+, \d+ acks, (\d+) corrections", l)
	if m:
		corr = int(m[1])
		continue
	m = re.search(r"kit: feet at ([-\d.]+),([-\d.]+),([-\d.]+), frame", l)
	if m:
		p = [float(m[k]) for k in (1, 2, 3)]
		continue
	m = re.search(r"kit: vehicle speed ([-\d.]+),([-\d.]+),([-\d.]+), yaw ([-\d.]+)", l)
	if m and seat:
		samples.append({"seat": seat, "ride": ride, "corr": corr, "p": p, "v": [float(m[k]) for k in (1, 2, 3)], "yaw": float(m[4])})
cars = [s for s in samples if s["seat"] == 5]
assert len(cars) >= 6, ("car samples", len(cars))
rest, w, b1, b2, end = cars[0], cars[1], cars[2], cars[3], cars[4]
turned = cars[5]
for s in (rest, w, b1, b2):
	assert abs(s["p"][1] - RIDE) < 0.002, ("the ride's height", s)
got, want = w["v"][2], along(STRAIGHT, w["p"][2])
print("W from rest: %.3f m/s at z %.3f, today's %.3f there" % (got, w["p"][2], want))
assert abs(got - want) < 0.03, (got, want)
# Braking: the speed the second sample has, from the first's over the same way on today's curve
BR = [(z, v) for z, v in BRAKING]
z0 = next(z for (z, v), (z2, v2) in zip(BR, BR[1:]) if v >= b1["v"][2] >= v2)
for (za, va), (zb, vb) in zip(BR, BR[1:]):
	if va >= b1["v"][2] >= vb:
		z0 = za + (zb - za) * (va * va - b1["v"][2] ** 2) / (va * va - vb * vb)
		break
z1 = z0 + b2["p"][2] - b1["p"][2]
for (za, va), (zb, vb) in zip(BR, BR[1:]):
	if za <= z1 <= zb:
		pred = math.sqrt(va * va + (vb * vb - va * va) * (z1 - za) / (zb - za))
		break
print("S: %.3f m/s after %.3f m from %.3f, today's %.3f" % (b2["v"][2], b2["p"][2] - b1["p"][2], b1["v"][2], pred))
assert abs(b2["v"][2] - pred) < 0.03, (b2, pred)
# The turn: on today's path, at its yaw there
x, z = turned["p"][0], turned["p"][2]
best = None
for a, b in zip(TURN, TURN[1:]):
	dx, dz = b[0] - a[0], b[1] - a[1]
	u = max(0, min(1, ((x - a[0]) * dx + (z - a[1]) * dz) / (dx * dx + dz * dz)))
	d = math.hypot(x - a[0] - u * dx, z - a[1] - u * dz)
	if best is None or d < best[0]:
		best = (d, a[2] + u * (b[2] - a[2]))
print("D and W from rest: %.4f m off today's path at (%.3f, %.3f), yaw %.3f, today's %.3f there" % (best[0], x, z, turned["yaw"], best[1]))
assert best[0] < 0.02 and abs(turned["yaw"] - best[1]) < 0.3, (best, turned)
# None while driven
for a, b in zip(samples, samples[1:]):
	if a["ride"] == b["ride"]:
		worst = max(worst, b["corr"] - a["corr"])
print("corrections while driven: %d" % worst)
assert worst == 0, "corrected while driven"
# A builder's movement: 4 m/s for its 400 ms
sled = [s for s in samples if s["seat"] == 7]
assert len(sled) >= 2 and 1 < sled[1]["p"][2] - sled[0]["p"][2] < 2.5, ("the sled", sled)
# The palette's prefab drives
pre = [s for s in samples if s["seat"] == 10]
assert len(pre) >= 2 and pre[-1]["p"][2] - pre[0]["p"][2] > 0.3, ("the prefab's car", pre)
assert abs(pre[0]["p"][1] - RIDE) < 0.002, pre[0]
# The refusals and edits, each said
for w_ in ("entity 5 has a kit/car", "entity 5 has a movement: kit/car", "kit/part has a place", "kit/car has no place",
		"kit/wave goes on a placed prefab's root", 'no component "kit/door"', 'no component "kit/starting_kit"',
		"entity 2 is a scene", "the entity's last component", "kit/seat needs a place: entity 6",
		"entity 10 is built by 9", "added kit/wave to 14", "added kit/car to 14", "added kit/seat to 5", "added kit/car to 5", "removed kit/timer from 5"):
	assert w_ in srv, w_
# The live remove: "ear" before "spy" on 8. Removed once, spy's ticks one stream through it
# and through the undo; spy started once in each round, ear once more for the undo
ears = len(re.findall(r"ear removed", srv))
assert ears == 1, ("ear removed", ears)
at = srv.index("ear removed")
before = [int(n) for n in re.findall(r"spy tick (\d+)", srv[:at])][-1]
after = [int(n) for n in re.findall(r"spy tick (\d+)", srv[at:])]
print("spy ticks %d before the remove, then %d..." % (before, after[0]))
assert after[0] == before + 1 and after[1] == before + 2, (before, after[:3])
tail = srv[at:].split("Stop by kitboss")[0]
assert "ear started" in tail, "the undo starts ear again"
assert "spy started" not in tail, "a second start of spy"
leaves = len(re.findall(r"kitboss leaves the seat of entity 5", srv))
assert leaves >= 5, ("the driver out of the seat", leaves)
# The saves: three components, in the order made; the override by its type
d = sqlite3.connect(db)
ents = {e["id"]: e for e in json.loads(d.execute("select value from store where store='kit' and key='authored'").fetchone()[0])["entities"]}
assert [c["type"] for c in ents[5]["components"]] == ["kit/part", "kit/seat", "kit/car"], ents[5]
assert ents[5]["pos"] == [0, 1, 4], ents[5]["pos"]
assert [c["type"] for c in ents[8]["components"]] == ["kit/part", "workbench/ear", "workbench/spy"], ents[8]
assert [c["type"] for c in ents[10]["components"]] == ["kit/part", "kit/car", "kit/seat"], ents[10]
assert [c["type"] for c in ents[13]["components"]] == ["kit/part", "kit/seat", "kit/car"], ents[13]
c13 = {c["type"]: c for c in ents[13]["components"]}
assert c13["kit/car"]["params"]["top_speed"] == 9 and c13["kit/car"].get("overrides") == ["top_speed"], c13
after_log = open(t + "/after.log", errors="replace").read()
assert "movement kit/car, seat 5" in after_log, "no seat after the restart"
PY
echo "PASS: components on one entity${WEB:+ (web)}"
