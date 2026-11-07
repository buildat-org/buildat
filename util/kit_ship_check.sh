#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min, ~4 min with web (2026-11-07)
# covers: apps/workbench/templates/ship/** builtin/kit/types/ship.prefab.json builtin/kit/types/turret.lua builtin/kit/types/sea_vessel.lua builtin/kit/types/wave.lua builtin/kit/kit.cpp builtin/kit/client_lua/controls.lua builtin/kit/client_lua/module.lua builtin/kit/client_lua/hands.lua builtin/kit/client_lua/move.lua
# [KIT_SHIP] (kit_plan 4r7) The ship template played through: New's "Ship", opened in
# edit mode, played by three: kitboss the captain at the wheel, kitbob the gunner at
# the cannon's seat (its aim by "event kit_aim", its shots Space), kitcat walking the
# rolling deck. The five mines sunk, sailed back into the harbour: "Well sailed!".
# [KIT_SHIP_VIEW] The gunner's chase view not pulled in by the ship, the sail faded in
# the captain's view. Measured: the deck's roll, the ship's speed, the walker's corrections and height
# over the deck, the shots fired and the hits.
# Native, or "web": kitboss in a page, kitbob and kitcat native.
# Screenshots with KEEP_TMP=1: $t/*.png
#   util/kit_ship_check.sh [web]
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
WEB=
if [ "${1:-}" = web ]; then
	WEB=1
	command -v "${CHROME:-google-chrome}" > /dev/null || skip "no Chrome"
	[ -f "$here/web/buildat.wasm" ] || skip "no web client (util/build_web.sh)"
fi
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp "kit_ship${WEB:+_web}"; t=$CHECK_TMP
export BUILDAT_JOIN_PASSWORD=checkpass12
cd "$here/Build"
PAGE_STUB="(function(){ var held = null;
 Object.defineProperty(document, 'pointerLockElement', {configurable: true, get: function(){ return held; }});
 function set(e){ held = e; document.dispatchEvent(new Event('pointerlockchange')); }
 HTMLCanvasElement.prototype.requestPointerLock = function(){ if(held !== this) set(this); return Promise.resolve(); };
 document.exitPointerLock = function(){ if(held) set(null); };
 return 'stub'; })()"
# A sequence as a page's steps (kit_templates_check's, held keys as kit_vehicle_movements')
cat > "$t/to_web.py" <<'PY'
import json, math, re, shlex, sys
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
	elif cmd in ("frames", "sync"):
		out.append([cmd, int(rest)])
	elif cmd == "delay":
		out.append(["holdkey", held, int(rest)] if held else ["wait", int(rest)])
	elif cmd == "keypress":
		out.append(["key", rest.lower() if len(rest) == 1 else rest])
	elif cmd == "keydown":
		held.append(rest.lower() if len(rest) == 1 else (" " if rest == "Space" else rest))
	elif cmd == "keyup":
		held = []
	elif cmd == "screenshot":
		out.append(["shot", rest])
	elif cmd == "click":
		a = shlex.split(rest)
		out.append(["click", *a[:2], *map(int, a[2:])])
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
	SRV=$t/srv.log
	start_server "$SRV" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 4 \
		${WEB:+-W "$here/web"} ||
		fail "the server did not come up ($SRV)"
	CHECK_PIDS+=($SERVER_PID)
}
native() # <name>: commands in $t/<name>.cmds; BUILDAT_JOIN_* its login
{
	run_client 60 "$t/$1.log" timeout 300 bin/buildat -C "$t/client_cache_$BUILDAT_JOIN_NAME" \
		-D "$t/cu_$BUILDAT_JOIN_NAME" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" || fail "client $1 ($t/$1.log, $SRV)"
}
page() # <name>: kitboss's
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
	[ $st = 0 ] || fail "the page's $1 ($(tail -2 "$t/drive_$1.txt"), $t/$1.log, $SRV)"
}
shot() { printf 'frames 10\nscreenshot %s\n' "$t/$1.png"; }
up() { printf 'wait_log_any %s shown: "%s\n' "${2:-15000}" "$1"; }
seated() { printf 'event kit_use %s\nwait_log 10000 movement %s, seat %s\nframes 10\n' "$1" "$2" "$1"; }
leave() { printf 'keypress F\nwait_log 10000 kit: controls: camera first_person, pointer crosshair, movement kit/walker\nframes 10\n'; }
held() { printf 'keydown %s\ndelay %s\nkeyup %s\nframes 3\n' "$1" "$2" "$1"; }
sample() # <client> <name> <count>: its body as logged, named in order
{
	local k
	for k in $(seq "$3"); do
		echo "$2" >> "$t/marks_$1.txt"
		printf 'event kit_body\ndelay 200\n'
	done
}
walk() # <client> <key> <ms> <name>: the key held, sampled
{
	echo "keydown $2"
	sample "$1" "$4" $(($3 / 200))
	echo "keyup $2"
}

# The admin's account and open registration, natively, on a fresh server
server
wait_for_log "$SRV" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SRV" | head -1)
[ -n "$code" ] || fail "no setup code ($SRV)"
cat > "$t/admin.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 30000 world_menu: the list shown
sync 3000
quit
EOF
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" native admin

# kitboss: New, "Ship", the tools; Play mode; the wheel
{
	cat <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 world_menu: the list shown
frames 3
click Button "New project..."
wait_log 5000 world_menu: the name screen shown
frames 3
click DropDownList "▼"
delay 300
frames 3
click Text "Ship"
wait_log 5000 world_menu: template picked
frames 3
screenshot $t/new_picked.png
click Button "Create"
wait_log_any 60000 player physics enabled
wait_log_any 20000 kit editor: edit rights: yes
wait_log_any 20000 kit editor: edit mode on
delay 1500
sync 3000
frames 10
screenshot $t/edit.png
keypress F2
wait_log 5000 kit editor: the view is
frames 10
screenshot $t/edit_3d.png
keypress F3
wait_log 5000 kit editor: the view is
frames 5
click Button "Play mode"
wait_log_any 10000 kit editor: the server is Running (by kitboss)
wait_log_any 10000 kit: controls: camera first_person
wait_log_any 20000 kit: the body's frame: 10
frames 10
look_dir 0 0 1
EOF
	shot deck
	sample boss stand 3
	seated 11 kit/sea_vessel
	shot wheel
	# Two mines down from the start, out among the other three
	up "Mines sunk: 2 / 5" 240000
	printf 'event kit_steer 0 4\nwait_log 60000 kit: steered to\n'
	sample boss out 3
	shot out
	# All five: home into the harbour
	up "Mines sunk: 5 / 5" 240000
	up "Sail back to the harbour" 5000
	printf 'event kit_steer 0 -32\n'
	sample boss sailing 10
	shot sailing
	printf 'wait_log 90000 kit: steered to\n'
	up "Well sailed!" 30000
	shot home
	printf 'event kit_steer off\n'
	leave
	sample boss home 3
	printf 'sync 3000\nquit\n'
} > "$t/boss.cmds"
# kitbob, the gunner: to the cannon's seat, each mine in turn
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 20000 kit: the body's frame: 10
frames 10
look_dir 0.22 0 1
EOF
	held W 900
	seated 13 kit/turret
	shot gunner
	for m in 1 2 3 4 5; do
		printf 'event kit_aim %s 45 3 fire\n' $((29 + m))
		up "Mines sunk: $m / 5" 120000
		printf 'event kit_body\n'
		[ $m = 1 ] && shot sunk1
	done
	printf 'event kit_aim 0\n'
	leave
	up "Well sailed!" 150000
	shot bob_home
	printf 'sync 3000\nquit\n'
} > "$t/bob.cmds"
# kitcat, crew: walks the deck while it sails out, rides it back
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitcat
wait_log_any 60000 player physics enabled
wait_log_any 20000 kit: the body's frame: 10
frames 10
EOF
	sample cat stand 5
	up "Mines sunk: 2 / 5" 240000
	for k in 1 2 3; do
		printf 'look_dir 0 0 1\nframes 2\n'
		walk cat W 600 walk
		printf 'look_dir 0 0 -1\nframes 2\n'
		walk cat W 600 walk
		printf 'look_dir 1 0 0\nframes 2\n'
		walk cat W 600 walk
		printf 'look_dir -1 0 0\nframes 2\n'
		walk cat W 600 walk
	done
	sample cat stand2 10
	printf 'look_dir 0.3 -0.3 1\n'
	shot cat_deck
	up "Sail back to the harbour" 240000
	sample cat back 20
	up "Well sailed!" 150000
	sample cat home 3
	printf 'sync 3000\nquit\n'
} > "$t/cat.cmds"
if [ -n "$WEB" ]; then
	page boss &
else
	BUILDAT_JOIN_NAME=kitboss native boss &
fi
boss=$!
wait_for_log "$SRV" "kitboss takes the seat of entity 11" 300 ||
	fail "the captain did not take the wheel ($t/boss.log, $SRV)"
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 native bob &
bob=$!
wait_for_log "$SRV" "kitbob takes the seat of entity 13" 120 ||
	fail "the gunner did not take the cannon ($t/bob.log, $SRV)"
BUILDAT_JOIN_NAME=kitcat BUILDAT_JOIN_CREATE=1 native cat &
cat=$!
wait $cat || fail "kitcat's client ($t/cat.log)"
wait $bob || fail "kitbob's client ($t/bob.log)"
wait $boss || fail "kitboss's client ($t/boss.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
python3 -I - "$t" <<'PY' || fail "the ship ($t/boss.log, $t/srv.log)"
import math, re, sys
t = sys.argv[1]
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
			cur = {"t": secs(l), "acks": int(m[1]), "corr": int(m[2]), "nodes": {}}
			out.append(cur)
			continue
		m = re.search(r"kit: feet at ([-0-9.]+),([-0-9.]+),([-0-9.]+), frame (\S+)", l)
		if m and cur:
			cur["p"], cur["frame"] = [float(m[k]) for k in (1, 2, 3)], m[4]
		if "kit: moving:" in l and cur:
			cur["drawn"] = [float(x) for x in re.search(
				r"drawn feet ([-0-9.]+),([-0-9.]+),([-0-9.]+)", l).groups()]
			for m in re.finditer(r"(\d+) node ([-0-9.]+),([-0-9.]+),([-0-9.]+) turn "
					r"([-0-9.]+),([-0-9.]+),([-0-9.]+),([-0-9.]+)", l):
				cur["nodes"][int(m[1])] = ([float(m[k]) for k in (2, 3, 4)],
					[float(m[k]) for k in (5, 6, 7, 8)])
	assert len(out) == len(marks), (name, len(out), len(marks))
	for s, k in zip(out, marks):
		s["mark"] = k
	return out
S = {n: samples(n) for n in ("boss", "cat")}
for w in ("the project from the template ship", "kitboss takes the seat of entity 11",
		"kitbob takes the seat of entity 13", "Entity 10's kit/sea_vessel steps in play",
		"Entity 12's kit/turret steps in play"):
	assert w in srv, w
# The gun: its shots, the mines hit, the goals
shots = len(re.findall(r"kitbob fires entity 12's kit/turret", srv))
hits = re.findall(r"kitbob's projectile \d+ hits entity (\d+)", srv)
print("the gun: %d shots, %d hits: %s" % (shots, len(hits), " ".join(hits)))
assert sorted(set(int(h) for h in hits)) == [30, 31, 32, 33, 34], hits
assert len(re.findall(r"kit/goal 43: done", srv)) == 1, "the mines' goal"
assert len(re.findall(r"kit/goal 44: done", srv)) == 1, "the harbour's goal"
# [KIT_SHIP_VIEW] The gunner's view close over the gun, never pulled in by the ship's
# rails or mast; the sail faded in the captain's view ahead
bob = open(t + "/bob.log", errors="replace").read()
cams = [float(x) for x in re.findall(r"kit: camera ([0-9.]+) m behind", bob)]
print("the gunner's camera: %s m behind" % " ".join("%.2f" % c for c in cams))
assert len(cams) >= 5 and min(cams) > 2.4, cams
assert "kit: entity 14 drawn faded (in the view)" in open(t + "/boss.log", errors="replace").read()
# The deck as kitcat and kitboss drew it: its roll and pitch, how far it sailed
rolls, pitches, places = [], [], []
for s in S["cat"] + S["boss"]:
	if 10 in s["nodes"]:
		p, q = s["nodes"][10]
		fw, side = rot(q, [0, 0, 1]), rot(q, [1, 0, 0])
		pitches.append(math.degrees(math.asin(max(-1, min(1, -fw[1])))))
		rolls.append(math.degrees(math.asin(max(-1, min(1, side[1])))))
		places.append((s["t"], p))
print("the deck: roll %.1f..%.1f, pitch %.1f..%.1f degrees, %d samples" %
	(min(rolls), max(rolls), min(pitches), max(pitches), len(rolls)))
assert max(rolls) - min(rolls) > 4 and max(pitches) - min(pitches) > 1.5, (rolls, pitches)
places.sort()
far = max(math.hypot(p[0] - places[0][1][0], p[2] - places[0][1][2]) for _, p in places)
speed = max(math.hypot(b[1][0] - a[1][0], b[1][2] - a[1][2]) / (b[0] - a[0])
	for a, b in zip(places, places[1:]) if b[0] - a[0] > 0.1)
print("the ship: %.1f m at most from where it was first drawn, %.2f m/s at most" % (far, speed))
assert far > 25, far
# kitcat on the sailing deck: always on it, his feet on its top, his corrections
ss = [s for s in S["cat"] if s["mark"] in ("walk", "stand2", "back")]
frames = set(s["frame"] for s in ss)
over = []
for s in ss:
	if 10 in s["nodes"] and "drawn" in s:
		p, q = s["nodes"][10]
		# the node at the voxels' corner, (-3.5, -1.5, -8.5) in the ship; the deck's top
		# 1.5 over the ship's place
		l = rot([q[0], -q[1], -q[2], -q[3]], [a - b for a, b in zip(s["drawn"], p)])
		over.append(l[1] - 1.5 - 1.5)
print("kitcat on the deck: %d samples, frames %s, feet over the deck %.4f..%.4f m, "
	"%d corrections in %d acks" % (len(ss), sorted(frames), min(over), max(over),
	ss[-1]["corr"] - ss[0]["corr"], ss[-1]["acks"] - ss[0]["acks"]))
assert frames == {"10"}, frames
assert max(abs(h) for h in over) < 0.05, over
PY
echo "PASS: the ship${WEB:+ (web)}"
# vim: set noet ts=4 sw=4:
