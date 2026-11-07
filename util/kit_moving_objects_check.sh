#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2.5 min, ~3 min with web (2026-11-07)
# covers: builtin/kit/kit.cpp builtin/kit/client_lua/module.lua builtin/kit/client_lua/move.lua builtin/kit/client_lua/controls.lua builtin/kit/client_lua/players.lua builtin/kit/types/prefab_copy.lua builtin/voxel_objects/** apps/workbench/**
# [KIT_MOVING_OBJECTS] A free object's pose as a function of the shared time, on a
# fresh Workbench save: deck 7 rolling, pitching, swinging and heaving round its centre,
# deck 8 on a course, a trigger zone under deck 7; a spawner of players over 7.
#   - kitboss and kitbob arrive by the spawner, and stand and walk on it; kitboss jumps,
#     is put on the course's deck and jumps there. A third, kitcat, joins while it rolls
#     and stands and walks there too.
#   - For each sample of each client: the feet against the deck at the sample's time by
#     this script's own rotations (nothing of kit.cpp's or move.lua's), the node drawn
#     against the same at the drawn time, the other bodies drawn against it. Corrections
#     counted per phase.
#   - The server's Bullet shape straight down from over the deck against the same; the
#     zone entered and left once, walked; at Stop the shape back at rest.
# Native, or "web": kitboss and the late kitcat in pages, kitbob native.
# Screenshots with KEEP_TMP=1: $t/*.png (on the deck, and from the floor at phases)
#   util/kit_moving_objects_check.sh [web]
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
WEB=
[ "${1:-}" = web ] && WEB=1
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_moving_objects${WEB:+_web}; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
export BUILDAT_JOIN_PASSWORD=checkpass12
USERDIR=$t/user
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
out, held = json.load(open(sys.argv[2])), None
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
		held = rest.lower() if len(rest) == 1 else rest
	elif cmd == "keyup":
		held = None
	elif cmd == "screenshot":
		out.append(["shot", rest])
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
# (At the real rate, no --sim-rate: a client's steps go by the wall's clock, the deck's
# time by the game's, and a deck 12 times as fast is no deck anyone walks on)
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
	run_client 90 "$t/$1.log" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" || fail "client $1 failed ($t/$1.log, $t/srv.log)"
}
page() # <name> <login's name>: an account of old for kitboss, a new one for another
{
	local login
	if [ "$2" = kitboss ]; then
		login=' ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["selall"], ["frames", 2], ["type", "kitboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Enter"], ["waitlog", "Joined as kitboss", 30],'
	else
		login=$(web_login_steps "$2") || fail "$login"
	fi
	printf '[["nav", "${URL}?scale=0.648148"], ["eval", %s], %s ["frames", 2]]' \
		"$(printf %s "$PAGE_STUB" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
		"$login" > "$t/$1.head.json"
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
# ---- Set up, natively: the deck's prefab, a walker; where a body starts
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
EOF
	echo 'event kit_edit {"op": "stop"}'
	echo 'wait_log 10000 kit editor: the server is Ended (by kitboss)'
	ed '{"op": "place", "type": "kit/world", "pos": [0, 1, 0]}'
	for z in $(seq -40 -29); do
		for x in $(seq 3 14); do
			vox $x 1 $z
		done
	done
	ed '{"op": "save_prefab", "ids": [], "box": [3, 1, -40, 14, 1, -29], "name": "deck"}'
	ed '{"op": "place", "type": "kit/walker", "pos": [0, 1, 0]}'
	ed '{"op": "place", "type": "kit/controls", "pos": [0, 1, 0]}'
	ed '{"op": "place", "type": "workbench/tele", "pos": [0, 1, -20]}'
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
bx=$(c3 "round($bx * 16) / 16"); by=$(c3 "round($by * 16) / 16"); bz=$(c3 "round($bz * 16) / 16")
echo "the body starts at $bx $by $bz"
# 3 world, 4 walker, 5 controls, 6 tele; 7 the wave's deck, 8 the course's, 9 the
# spawner, 10 the zone on the wave's deck: cells 8..10 of it, its own row and the next
cat > "$t/decks.py" <<PY
import math
BY = $by
PIVOT = [5.5, 0, 5.5]
WAVE = {"wave_roll": 8, "wave_roll_period": 8, "wave_pitch": 5, "wave_pitch_period": 11,
	"wave_yaw": 6, "wave_yaw_period": 13, "wave_heave": 0.5, "wave_heave_period": 6,
	"pivot": PIVOT}
COURSE = {"course": [6, 0, 0], "course_time": 3}
DECKS = {
	7: ([$(c3 "$bx - 5.5"), $(c3 "$by + 4"), $(c3 "$bz - 5.5")], WAVE),
	8: ([$(c3 "$bx + 20"), $(c3 "$by + 2"), $(c3 "$bz - 5.5")], COURSE),
}
PY
in_edit() # <event kit_edit's>: an edit or a try takes edit mode, the game running
{
	printf 'event kit_edit {"op": "mode", "on": true}\nwait_log 5000 kit editor: edit mode on\nevent kit_edit %s\nsync 3000\n' "$1"
	printf 'event kit_edit {"op": "mode", "on": false}\nwait_log 5000 kit editor: edit mode off\n'
}
shake() # <amount>: heard by each client, to go on
{
	in_edit "{\"op\": \"try\", \"id\": 5, \"input\": \"shake\", \"value\": $1}"
}
sample() # <client> <name> <count>: its body as logged, and the others', named in order
{
	local k
	for k in $(seq "$3"); do
		echo "$2" >> "$t/marks_$1.txt"
		printf 'event kit_body\nevent kit_players\ndelay 200\n'
	done
}
walked() # <client> <dir x> <dir z> <ms> <name>
{
	printf 'look_dir %s 0 %s\nframes 2\nkeydown W\n' "$2" "$3"
	sample "$1" "$5" $(($4 / 200))
	printf 'keyup W\ndelay 300\n'
}
jumped() # <client> <name>
{
	sample "$1" "$2_before" 1
	printf 'keydown Space\ndelay 100\nkeyup Space\n'
	sample "$1" "$2_after" 8
}
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
	ed '{"op": "place", "prefab": "kitboss/deck", "pos": [0, 30, -80], "free": true}'
	ed '{"op": "place", "prefab": "kitboss/deck", "pos": [0, 30, -80], "free": true}'
	python3 - "$t" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
from decks import *
for i, (o, m) in DECKS.items():
	print("event kit_edit " + json.dumps({"op": "move", "id": i, "pos": o, "yaw": 0, "pitch": 0, "roll": 0}))
	print("sync 5000")
	for k, v in m.items():
		print("event kit_edit " + json.dumps({"op": "set", "id": i, "comp": 0, "param": k, "value": v}))
		print("sync 5000")
o = DECKS[7][0]
print("event kit_edit " + json.dumps({"op": "place", "type": "kit/spawner",
	"pos": [round(o[0] + 5.5), round(o[1] + 3), round(o[2] + 5.5)]}))
print("sync 5000")
print("event kit_edit " + json.dumps({"op": "set", "id": 9, "comp": 0, "param": "players", "value": True}))
print("sync 5000")
print("event kit_edit " + json.dumps({"op": "place", "type": "kit/trigger_zone", "parent": 7,
	"pos": [round(o[0] + 8), o[1], round(o[2] + 8)]}))
print("sync 5000")
PY
	# Bullet at rest before the round
	ed "{\"op\": \"body_ray\", \"pos\": [$bx, $(c3 "$by + 20"), $bz]}"
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
event kit_edit {"op": "mode", "on": false}
wait_log 10000 kit editor: edit mode off
wait_log 20000 kit: the body's frame: 7
EOF
	# Standing through a wave; the views of it
	printf 'look_dir 1 -0.1 0.3\nframes 5\n'
	sample boss stand 40
	echo "screenshot $t/boss_deck1.png"
	echo "delay 2000"
	echo "screenshot $t/boss_deck2.png"
	echo "delay 2000"
	echo "screenshot $t/boss_deck3.png"
	shake 0.01
	# Walked over it, each way
	walked boss 1 0 600 walk
	walked boss -1 0 1200 walk
	walked boss 1 0 600 walk
	walked boss 0 1 600 walk
	walked boss 0 -1 1200 walk
	walked boss 0 1 600 walk
	sample boss walked 3
	jumped boss jump1
	sample boss after_jump 5
	# Into the zone, a whole wave there, out by the way it came
	walked boss 1 1 1000 to_zone
	sample boss in_zone 40
	walked boss -1 -1 1000 from_zone
	sample boss out_zone 3
	# The server's shape
	printf 'event kit_edit {"op": "mode", "on": true}\nwait_log 5000 kit editor: edit mode on\n'
	python3 - "$bx" "$by" "$bz" <<'PY'
import sys
x, y, z = map(float, sys.argv[1:4])
for k in range(30):
	print('event kit_edit {"op": "body_ray", "pos": [%g, %g, %g]}' % (x + (k % 3) * 3 - 3, y + 20, z + (k % 2) * 4 - 2))
	print("sync 3000")
	print("delay 400")
PY
	printf 'event kit_edit {"op": "mode", "on": false}\nwait_log 5000 kit editor: edit mode off\n'
	# A late joiner: it stands and walks there, the deck well under way; he stands still
	shake 0.03
	echo "wait_log 120000 's body drawn"
	sample boss late_stand 40
	echo "wait_log 120000 's body gone"
	sample boss after_late 5
	# The course's deck
	in_edit "{\"op\": \"try\", \"id\": 6, \"input\": \"go\", \"value\": [$(c3 "$bx + 28.5"), $(c3 "$by + 5"), $bz]}"
	# (landed with no speed on a deck of 2 m/s: it slides to a stand first)
	printf "wait_log 10000 kit: the body's frame: 8\ndelay 1000\n"
	sample boss course 30
	# (three in a row: the course turns every 3 s, at least one has no turn in it)
	jumped boss jump2
	jumped boss jump3
	jumped boss jump4
	walked boss 0 1 400 course_walk
	walked boss 0 -1 400 course_walk
	sample boss course_after 5
	# And off, the wave's deck from the floor
	in_edit "{\"op\": \"try\", \"id\": 6, \"input\": \"go\", \"value\": [$(c3 "$bx + 11"), $(c3 "$by + 1"), $(c3 "$bz")]}"
	printf 'look_dir -1 0.2 0\nframes 10\ndelay 300\n'
	sample boss floor 2
	for k in 1 2 3 4; do
		echo "screenshot $t/floor_view$k.png"
		echo "delay 2000"
	done
	shake 0.05
	# At Stop: at rest, everyone
	printf 'event kit_edit {"op": "mode", "on": true}\nwait_log 5000 kit editor: edit mode on\n'
	printf 'event kit_edit {"op": "stop"}\nwait_log 10000 kit editor: the server is Ended (by kitboss)\nsync 3000\n'
	ed "{\"op\": \"body_ray\", \"pos\": [$bx, $(c3 "$by + 20"), $bz]}"
	printf 'frames 10\nscreenshot %s\nsync 3000\nquit\n' "$t/rest.png"
} > "$t/boss.cmds"
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log 200000 kit: the body's frame: 7
EOF
	sample bob stand 30
	echo "screenshot $t/bob_deck.png"
	echo "wait_log 200000 kit: camera shake 0.01"
	walked bob 0 1 600 walk
	walked bob 0 -1 1200 walk
	walked bob 0 1 600 walk
	walked bob 1 0 600 walk
	walked bob -1 0 1200 walk
	walked bob 1 0 600 walk
	sample bob stand_again 10
	echo "wait_log 200000 kit: camera shake 0.05"
	printf 'sync 1000\nquit\n'
} > "$t/bob.cmds"
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitcat
wait_log_any 60000 player physics enabled
wait_log_any 20000 kit: the body's frame: 7
EOF
	sample cat stand 20
	echo "screenshot $t/cat_deck.png"
	sample cat stand 20
	sample cat stand2 10
	walked cat 1 0 600 walk
	walked cat -1 0 1200 walk
	walked cat 0 1 600 walk
	walked cat 0 -1 1200 walk
	sample cat stand3 10
	printf 'sync 1000\nquit\n'
} > "$t/cat.cmds"
# (bob first: he must be in when it plays; his client quits by its own)
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 native bob &
bob=$!
wait_for_log "$t/bob.log" "player physics enabled" 120 || fail "kitbob did not get in ($t/bob.log)"
if [ -n "$WEB" ]; then
	page boss kitboss &
else
	BUILDAT_JOIN_NAME=kitboss native boss &
fi
boss=$!
wait_for_log "$t/bob.log" "kit: camera shake 0.03" 200 || fail "not to the late joiner ($t/bob.log)"
if [ -n "$WEB" ]; then
	page cat kitcat &
else
	BUILDAT_JOIN_NAME=kitcat BUILDAT_JOIN_CREATE=1 native cat &
fi
cat=$!
wait $cat || fail "kitcat's client ($t/cat.log)"
wait $boss || fail "kitboss's client ($t/boss.log)"
wait $bob || fail "kitbob's client ($t/bob.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
python3 - "$t" <<'PY' || fail "the moving objects ($t/boss.log, $t/srv.log)"
import math, re, sys
t = sys.argv[1]
sys.path.insert(0, t)
from decks import *
# The check's own frames: Urho3D's Quaternion(pitch, yaw, roll) is roll, pitch, yaw
def mul(a, b):
	return [a[0]*b[0]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3], a[0]*b[1]+a[1]*b[0]+a[2]*b[3]-a[3]*b[2],
		a[0]*b[2]-a[1]*b[3]+a[2]*b[0]+a[3]*b[1], a[0]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[0]]
def quat(yaw, pitch, roll):
	def ax(a, i):
		q = [math.cos(math.radians(a) / 2), 0, 0, 0]
		q[i] = math.sin(math.radians(a) / 2)
		return q
	return mul(ax(yaw, 2), mul(ax(pitch, 1), ax(roll, 3)))
def conj(q):
	return [q[0], -q[1], -q[2], -q[3]]
def rot(q, v):
	return mul(mul(q, [0] + list(v)), conj(q))[1:]
def add(a, b):
	return [x + y for x, y in zip(a, b)]
def sub(a, b):
	return [x - y for x, y in zip(a, b)]
def swing(m, name, t_):
	a = m.get("wave_" + name, 0)
	return a * math.sin(2 * math.pi * t_ / m["wave_" + name + "_period"]) if a else 0
def pose(i, t_):
	o, m = DECKS[i]
	W = quat(swing(m, "yaw", t_), swing(m, "pitch", t_), swing(m, "roll", t_))
	piv = m.get("pivot", [0, 0, 0])
	u = 0
	if m.get("course_time"):
		u = (t_ / m["course_time"]) % 2
		u = 2 - u if u > 1 else u
	c = [x * u for x in m.get("course", [0, 0, 0])]
	c[1] += swing(m, "heave", t_)
	return add(o, sub(add(piv, c), rot(W, piv))), W
def local(i, t_, p):
	o, q = pose(i, t_)
	return rot(conj(q), sub(p, o))
def read(name):
	# Samples in order, named; the last of as many as there are names
	names = open("%s/marks_%s.txt" % (t, name)).read().split()
	recs, cur = [], None
	for l in open("%s/%s.log" % (t, name), errors="replace"):
		m = re.search(r"kit: body at [-\d.,]+, (\d+) acks, (\d+) corrections, (\d+) pending, (\d+) jumps", l)
		if m:
			cur = {"acks": int(m[1]), "corr": int(m[2]), "jumps": int(m[4]), "others": []}
			continue
		if cur is None:
			continue
		m = re.search(r"kit: feet at ([-\d.]+),([-\d.]+),([-\d.]+), frame (\w+)", l)
		if m:
			cur["p"] = [float(m[k]) for k in (1, 2, 3)]
			cur["f"] = None if m[4] == "none" else int(m[4])
			continue
		m = re.search(r"kit: moving: stepped at ([-\d.]+), drawn at ([-\d.]+), drawn feet ([-\d.]+),([-\d.]+),([-\d.]+), offset of the shared time ([-\d.]+)(.*)", l)
		if m:
			cur["t"], cur["dt"] = float(m[1]), float(m[2])
			cur["d"] = [float(m[k]) for k in (3, 4, 5)]
			cur["off"] = float(m[6])
			cur["nodes"] = {int(n[0]): ([float(x) for x in n[1].split(",")], [float(x) for x in n[2].split(",")])
				for n in re.findall(r"; (\d+) node ([-\d.,]+) turn ([-\d.,]+)", m[7])}
			recs.append(cur)
			continue
		m = re.search(r"kit: player (\d+) drawn at ([-\d.]+),([-\d.]+),([-\d.]+) .*time ([-\d.]+)", l)
		if m and recs:
			recs[-1]["others"].append((int(m[1]), [float(m[k]) for k in (2, 3, 4)], float(m[5])))
	assert len(recs) >= len(names), (name, len(recs), len(names))
	recs = recs[-len(names):]
	for r, n in zip(recs, names):
		r["name"] = n
	return recs
ALL = {n: read(n) for n in ("boss", "bob", "cat")}
# (while all of them stand: not kitbob's stand_again, kitboss jumps then)
LOOK_PHASES = ("stand", "stand2", "stand3", "late_stand")
worst = {}
ok = True
for name, recs in ALL.items():
	h = dh = dn = dq = 0
	on = 0
	for r in recs:
		for i, (a, q) in r["nodes"].items():
			# (the voxels' model starts half a cell back of the object's cell)
			w = pose(i, r["dt"])[1]
			dn = max(dn, max(abs(x + 0.5) for x in local(i, r["dt"], a)))
			dq = max(dq, abs(1 - abs(sum(x * y for x, y in zip(q, w)))))
		if r["f"]:
			on += 1
			l = local(r["f"], r["t"], r["p"])
			r["l"] = l
			h = max(h, abs(l[1] - 0.5))
			dl = local(r["f"], r["dt"], r["d"])
			r["dl"] = dl
			dh = max(dh, abs(dl[1] - 0.5))
	worst[name] = (h, dh, dn, dq)
	offs = [r["off"] for r in recs]
	print("%s: %d samples, %d on a deck; feet over the deck at the stamp worst %.4f m; drawn feet %.4f; "
		"node %.4f m, turn 1-dot %.1e; time's offset %.3f..%.3f; %d acks, corrections %d" % (name,
		len(recs), on, h, dh, dn, dq, min(offs), max(offs), recs[-1]["acks"], recs[-1]["corr"]))
	# Corrections per phase, in order
	seen, line = [], []
	base = recs[0]["corr"]
	for r in recs:
		if not seen or seen[-1] != r["name"]:
			seen.append(r["name"])
			line.append([r["name"], r["corr"]])
		else:
			line[-1][1] = r["corr"]
	print("  corrections by the phase's end: " + " ".join("%s %d" % (n, c) for n, c in line) + " (from %d)" % base)
# On the deck when asked, it moved under them, they stood in it
def phase(c, n):
	return [r for r in ALL[c] if r["name"] == n]
for c, ns in (("boss", ("stand", "walked", "after_jump", "in_zone", "out_zone", "late_stand", "after_late")),
		("bob", ("stand", "stand_again")), ("cat", ("stand", "stand2", "stand3"))):
	for n in ns:
		rs = phase(c, n)
		assert rs, (c, n)
		assert all(r["f"] == 7 for r in rs), (c, n, [r["f"] for r in rs])
		for k in (0, 2):
			v = [r["l"][k] for r in rs]
			assert max(v) - min(v) < 0.02, ("stood in the deck", c, n, k, min(v), max(v))
		ys = [r["p"][1] for r in rs]
		if len(rs) >= 20:
			assert max(ys) - min(ys) > 0.3, ("carried", c, n, max(ys) - min(ys))
assert all(r["f"] == 8 for r in phase("boss", "course")), "on the course"
xs = [r["p"][0] for r in phase("boss", "course")]
assert max(xs) - min(xs) > 1, ("carried along the course", max(xs) - min(xs))
assert all(abs(r["l"][0] - phase("boss", "course")[0]["l"][0]) < 0.02 for r in phase("boss", "course")), "stood on the course's deck"
# Walked: it went where the keys said, over the deck
for c in ("boss", "bob", "cat"):
	ls = [r["l"] for r in phase(c, "walk") if r["f"] == 7]
	assert len(ls) > 5 and max(l[0] for l in ls) - min(l[0] for l in ls) > 2, (c, "walked")
	assert all(r["f"] == 7 for r in phase(c, "walk")), (c, "off the deck walking")
# Jumps: one up, down near where it left, in the frame
clear = 0
for j, deck in (("jump1", 7), ("jump2", 8), ("jump3", 8), ("jump4", 8)):
	a, ps = phase("boss", j + "_before")[0], phase("boss", j + "_after")
	b = ps[-1]
	air = [r for r in ps if not r["f"]]
	assert air, (j, "never in the air")
	land = ps[ps.index(air[-1]) + 1]
	assert b["jumps"] == a["jumps"] + 1, (j, a["jumps"], b["jumps"])
	assert b["f"] == deck, (j, b["f"])
	gone = math.hypot(b["l"][0] - a["l"][0], b["l"][2] - a["l"][2])
	# A turn of the course under it in the air: the deck went from under it, rightly
	turned = deck == 8 and int(a["t"] / 3) != int(land["t"] / 3)
	print("  %s: landed %.3f m from where it left, in the deck%s" % (j, gone,
		", the course turning under it" if turned else ""))
	if not turned:
		clear += deck == 8
		assert gone < 0.1, (j, gone)
assert clear > 0, "a jump on the course with no turn"
# The others drawn: on the deck's top
for c in ALL:
	worst_o, n, ids = 0, 0, set()
	landed = set()
	for r in ALL[c]:
		if r["name"] not in LOOK_PHASES:
			continue
		for pid, p, tt in r["others"]:
			ids.add(pid)
			l = local(7, tt, p)
			# (from the first on its top: till then held at the spawner, or falling)
			if abs(l[1] - 0.5) < 0.05:
				landed.add(pid)
			if pid in landed:
				worst_o = max(worst_o, abs(l[1] - 0.5))
				n += 1
	print("%s: others drawn on the deck: %d samples of %s, worst height %.4f m" % (c, n, sorted(ids), worst_o))
	assert n > 5, (c, n)
	assert worst_o < 0.1, (c, worst_o)
# What the late joiner draws of a body standing still: where it stands in the deck
stood = phase("boss", "late_stand")[-1]["l"]
far = None
for r in phase("cat", "stand2"):
	for pid, p, tt in r["others"]:
		l = local(7, tt, p)
		d = math.hypot(l[0] - stood[0], l[2] - stood[2])
		far = d if far is None else min(far, d)
print("kitcat draws kitboss %.4f m from where he stands in the deck" % far)
assert far < 0.1, far
# The server's shape
text = open(t + "/srv.log", errors="replace").read()
rays = re.findall(r"Bullet down from \(([-\d.]+),([-\d.]+),([-\d.]+)\) at ([-\d.]+): ([-\d.e]+|nothing)", text)
assert len(rays) == 32, len(rays)
def top(i, t_, x, z):
	o, q = pose(i, t_)
	n = rot(q, [0, 1, 0])
	p = add(o, rot(q, [0, 0.5, 0]))
	return p[1] - (n[0] * (x - p[0]) + n[2] * (z - p[2])) / n[1]
assert all(r[4] != "nothing" for r in rays), "a ray with nothing"
rest1, rest2 = rays[0], rays[-1]
want = DECKS[7][0][1] + 0.5
assert abs(float(rest1[4]) - want) < 1e-3 and abs(float(rest2[4]) - want) < 1e-3, ("at rest", rest1, rest2, want)
errs, ys = [], []
for x, y, z, tt, got in rays[1:-1]:
	e = float(got) - top(7, float(tt), float(x), float(z))
	errs.append(abs(e))
	ys.append(float(got))
print("Bullet against the deck: worst %.4f m over %d rays, it moved %.3f m" % (max(errs), len(errs), max(ys) - min(ys)))
assert max(ys) - min(ys) > 0.3, "Bullet's shape stayed"
assert max(errs) < 0.15, errs
# The zone: entered once and left once, a wave spent in it
ent = len(re.findall(r"Entity 10: kitboss enters its zone", text))
lef = len(re.findall(r"Entity 10: kitboss leaves its zone", text))
print("the zone: entered %d, left %d" % (ent, lef))
assert ent == 1 and lef == 1, (ent, lef)
# The figures' limits
for c, (h, dh, dn, dq) in worst.items():
	assert h < 0.02, (c, "feet", h)
	assert dh < 0.05, (c, "drawn feet", dh)
	# (the log's millisecond at a speed of 2 m/s; the turn's five decimals)
	assert dn < 0.003 and dq < 1e-5, (c, "nodes", dn, dq)
assert all(ALL[c][-1]["corr"] == 0 for c in ALL), {c: ALL[c][-1]["corr"] for c in ALL}
PY
echo "PASS: moving objects${WEB:+ (web)}"
