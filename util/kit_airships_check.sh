#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min, ~4 min with web (2026-11-08)
# covers: apps/workbench/templates/airships/** builtin/kit/types/airship*.json builtin/kit/types/hull.lua builtin/kit/types/wallet.lua builtin/kit/types/wallet.client.lua builtin/kit/types/shop.lua builtin/kit/types/airship.lua builtin/kit/kit.cpp builtin/kit/client_lua/controls.lua builtin/kit/client_lua/move.lua builtin/kit/client_lua/module.lua apps/workbench/main/client_lua/init.lua builtin/kit/types/pause_menu_action.lua builtin/kit/types/terrain_region.lua builtin/kit/client_lua/ui.lua
# [KIT_AIRSHIPS] (kit_plan 4s, stages 1 and 2) The airships template played:
# kitboss joins Red (on Red's island, a kit/terrain_region's voxels), buys a
# skiff and a core at Red's shop, free out of a round ([KIT_AIRSHIPS_2]: his
# wallet's 40 untouched, a note each). He builds on the skiff standing
# on its deck: a voxel placed in front of him, which he then jumps onto (the
# collision rebuilt with it), one dug; takes its seat and flies it, building on
# it while it moves (a cell in its frame, aimed as it moves; each voxel free),
# leaves its seat at Blue's island and takes the pause menu's "To the lobby"
# (kit/pause_menu_action): at the lobby's spawn. kitbob joins Blue (its
# island kit/symmetry's copy of Red's),
# buys his own skiff and is refused building on kitboss's. Three ships changed
# within the same seconds: the shared rebuild budget (one rebuild every 0.5 s
# for all of them) holds. kitcat joins late: he sees the changed cells, buys a
# core and walks from the island onto it and onto kitbob's deck, never dead
# ([KIT_AIRSHIP_CORE_DEATH]: the island's look left out of the server's step
# past 10 m from its middle). Stop
# puts everything back: the ships gone, the wallets' money with them. Then in
# the editor a seed in mid air, mirrored. The World's ground: a 1024 x 1024
# heightmap under the islands.
# Native, or "web": kitboss in a page, kitbob and kitcat native.
# Screenshots with KEEP_TMP=1: $t/*.png
#   util/kit_airships_check.sh [web]
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
check_tmp "kit_airships${WEB:+_web}"; t=$CHECK_TMP
export BUILDAT_JOIN_PASSWORD=checkpass12
cd "$here/Build"
PAGE_STUB="(function(){ var held = null;
 Object.defineProperty(document, 'pointerLockElement', {configurable: true, get: function(){ return held; }});
 function set(e){ held = e; document.dispatchEvent(new Event('pointerlockchange')); }
 HTMLCanvasElement.prototype.requestPointerLock = function(){ if(held !== this) set(this); return Promise.resolve(); };
 document.exitPointerLock = function(){ if(held) set(null); };
 return 'stub'; })()"
# A sequence as a page's steps (kit_ship_check's; a click at the crosshair)
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
		held.append(rest.lower() if len(rest) == 1 else rest)
	elif cmd == "keyup":
		held = []
	elif cmd == "screenshot":
		out.append(["shot", rest])
	elif cmd == "mouse_click":
		out.append(["click", 512, 350, 50, 2 if rest == "right" else 0])
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
body() { printf 'event kit_body\nframes 2\n'; }
# <id> <x> <y> <z> <left|right>: a click at that point of a ship's frame
at() { printf 'event kit_point_obj %s %s %s %s\nframes 3\nmouse_click %s\n' "$@"; }
held() { printf 'keydown %s\ndelay %s\nkeyup %s\nframes 3\n' "$1" "$2" "$1"; }

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

# kitboss: New, "Airships"; Play mode; Red; the shops
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
click Text "Airships"
wait_log 5000 world_menu: template picked
frames 3
click Button "Create"
wait_log_any 60000 player physics enabled
wait_log_any 20000 kit editor: edit rights: yes
wait_log_any 20000 kit editor: edit mode on
sync 3000
frames 10
screenshot $t/edit.png
click Button "Play mode"
wait_log_any 10000 kit editor: the server is Running (by kitboss)
wait_log_any 10000 kit: controls: camera first_person
wait_log_any 10000 your money 40
wait_log_any 10000 purchases free
wait_log_any 60000 heightmap: terrain built: 1024x1024
event kit_use 9
wait_log 10000 the server put the player at
frames 30
EOF
	body
	printf 'look_dir 0 -0.3 1\n'
	shot red
	printf 'event kit_use 22\nwait_log 10000 wallet note: Skiff: free outside a round\n'
	shot bought
	printf 'event kit_use 24\nwait_log 10000 wallet note: Core: free outside a round\n'
	# Two ships changed at once from the island (the budget): the core's side
	# (its seat sits on its top) and the skiff's open stern
	at 42 0 0 -0.5 right
	# (sent with the click, not aimed: a page's clicks come 0.5 s apart)
	printf 'event kit_obuild {"id": 40, "cell": [1, 1, -4], "voxel": "kit/stone", "param": 0, "tint": 0}\n'
	printf 'wait_log_any 10000 object boxes kitown_42.1\nwait_log_any 10000 object boxes kitown_40.1\nevent kit_point_obj\n'
	shot two
	# The skiff's seat (41), then off it onto the deck
	printf 'event kit_use 41\nwait_log 10000 seat 41\nframes 10\n'
	printf 'keypress F\nwait_log 10000 movement kit/walker\nframes 20\n'
	shot deck
	# A voxel placed beside him, one in front of him: he jumps onto that one
	at 40 1 0.5 1 right
	printf 'wait_log 10000 object boxes kitown_40.\n'
	at 40 1 0.5 -2 right
	printf 'wait_log 10000 object boxes kitown_40.\nevent kit_point_obj\nlook_dir 0 0 1\nframes 10\n'
	body
	printf 'keydown Space\nkeydown W\ndelay 250\nkeyup W\nkeyup Space\nframes 60\n'
	body
	shot jumped
	# The first dug again; the core refused
	at 40 1 1.5 1 left
	printf 'wait_log 10000 object boxes kitown_40.\n'
	at 40 0 0.5 0 left
	printf 'wait_log 10000 kit: warning: The core stays\n'
	# Flown to Blue's island, a voxel placed on the way (free)
	printf 'event kit_point_obj\nevent kit_use 41\nwait_log 10000 seat 41\nevent kit_steer -47 17\nframes 150\n'
	at 40 -1 0.5 -1 right
	printf 'wait_log 10000 object boxes kitown_40.\n'
	shot flying
	printf 'event kit_point_obj\n'
	printf 'wait_log 120000 kit: steered to\nevent kit_steer off\nframes 30\n'
	body
	shot parked
	# [KIT_AIRSHIPS_2] Off the seat, the pause menu's To the lobby
	printf 'keypress F\nwait_log 10000 movement kit/walker\nframes 10\n'
	printf 'keypress Escape\nwait_log 5000 pause: the menu shown\nframes 3\n'
	shot menu
	printf 'click Button "To the lobby"\nwait_log 10000 the server put the player at\nframes 30\n'
	body
	shot lobby
	# kitbob and kitcat come and go; then Stop, everything back
	printf 'wait_log 300000 object boxes kitown_46.2\nframes 30\n'
	shot all
	printf 'event kit_edit {"op": "mode", "on": true}\nwait_log 5000 kit editor: edit mode on\n'
	printf 'event kit_edit {"op": "stop"}\nwait_log 10000 kit editor: the server is Ended (by kitboss)\nsync 3000\n'
	printf 'event kit_obj_cell 40 1 1 -2\nframes 2\n'
	printf 'event kit_obj_cell 46 0 0 -1\nframes 2\n'
	shot stopped
	# [KIT_AIRSHIPS_2] A seed in mid air over the heightmap, in Red's half:
	# its image in Blue's
	printf 'event kit_edit {"op": "terrain", "tool": "seed", "on": "voxels", "x": 20, "y": 20, "z": 60, "size": 2, "strength": 2, "stroke": 1}\n'
	printf 'wait_log 5000 kit editor: terrain: seed\n'
	printf 'event kit_cam3d 0 30 20 20 20 60\nframes 30\n'
	shot seed
	printf 'event kit_edit {"op": "play"}\nwait_log 10000 kit editor: the server is Running (by kitboss)\n'
	printf 'frames 60\nevent kit_obj_cell 40 1 1 -2\nframes 2\n'
	printf 'sync 3000\nquit\n'
} > "$t/boss.cmds"
cells() # <id> <x y z>...: each logged as this client has it
{
	local id=$1
	shift
	while [ $# -gt 0 ]; do
		printf 'event kit_obj_cell %s %s %s %s\nframes 2\n' "$id" "$1" "$2" "$3"
		shift 3
	done
}
SHIP40="1 1 1  1 1 -2  1 1 -4  -1 1 -1  0 0 0"
# kitbob, after kitboss parked: Blue, a skiff of his own, built on; refused on
# kitboss's; kitboss's changes and kitcat's later one as he has them
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 20000 your money 40
event kit_use 10
wait_log 10000 the server put the player at
frames 30
event kit_body
frames 2
event kit_use 32
wait_log 10000 wallet note: Skiff: free outside a round
event kit_use 45
wait_log 10000 seat 45
frames 10
keypress F
wait_log 10000 movement kit/walker
frames 20
EOF
	at 44 1 0.5 1 right
	printf 'wait_log 10000 object boxes kitown_44.1\nevent kit_point_obj\n'
	# to his deck's side by kitboss's ship, its core (refused before the core's rule)
	printf 'look_dir -1 0 0\nframes 3\n'
	held W 600
	printf 'event kit_obuild {"id": 40, "cell": [0, 0, 0], "voxel": "air", "param": 0, "tint": 0}\n'
	printf 'wait_log 10000 kit: warning: Not yours\n'
	cells 40 $SHIP40
	cells 42 0 0 -1
	printf 'look_dir -1 -0.2 0.3\n'
	shot bob
	printf 'wait_log 300000 object boxes kitown_46.1\n'
	cells 46 0 0 -1
	printf 'sync 3000\nquit\n'
} > "$t/bob.cmds"
# kitcat, late: Blue; every change as he gets it at his join; a core of his own
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitcat
wait_log_any 60000 player physics enabled
wait_log_any 20000 your money 40
event kit_use 10
wait_log 10000 the server put the player at
EOF
	cells 40 $SHIP40
	cells 42 0 0 -1
	cells 44 1 1 1
	printf 'look_dir -0.8 -0.2 0.6\n'
	shot cat
	printf 'event kit_use 34\nwait_log 10000 wallet note: Core: free outside a round\n'
	at 46 0 0 -0.5 right
	printf 'wait_log 10000 object boxes kitown_46.1\nevent kit_point_obj\nlook_dir 0.3 -0.4 1\n'
	shot cat_core
	# [KIT_AIRSHIP_CORE_DEATH] Over the island's edge onto his core (its helm),
	# back, and onto kitbob's skiff's deck: on them, never dead
	printf 'look_dir 1 0 0\nframes 3\n'; held W 420
	printf 'look_dir 0 0 1\nframes 3\n'; held W 600; printf 'frames 30\n'; body
	printf 'look_dir 0 0 -1\nframes 3\n'; held W 500
	printf 'look_dir -1 0 0\nframes 3\n'; held W 650
	printf 'look_dir 0 0 1\nframes 3\n'; held W 1000; printf 'frames 30\n'; body
	# (kitboss's Stop waits for this one)
	printf 'event kit_obuild {"id": 46, "cell": [0, 1, -1], "voxel": "kit/stone", "param": 0, "tint": 0}\n'
	printf 'wait_log 10000 object boxes kitown_46.2\n'
	printf 'sync 3000\nquit\n'
} > "$t/cat.cmds"
if [ -n "$WEB" ]; then
	page boss &
else
	BUILDAT_JOIN_NAME=kitboss native boss &
fi
boss=$!
until_seen() # <log> <text> <pid> <what>: waits while that client runs
{
	until grep -aqF "$2" "$1" 2>/dev/null; do
		kill -0 "$3" 2>/dev/null || { wait "$3"; fail "$4 ($1, $SRV)"; }
		sleep 0.5
	done
}
# (a page's log is its drive's till it ends)
until_seen "$t/${WEB:+drive_}boss${WEB:+/page}.log" "kit: steered to -47.0" $boss \
	"kitboss's ship did not arrive"
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 native bob &
bob=$!
until_seen "$t/bob.log" "kit: object 42 cell" $bob "kitbob did not get to his checks"
BUILDAT_JOIN_NAME=kitcat BUILDAT_JOIN_CREATE=1 native cat
wait $bob || fail "kitbob's client ($t/bob.log)"
wait $boss || fail "kitboss's client ($t/boss.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
python3 -I - "$t" <<'PY' || fail "the airships ($t/boss.log, $t/srv.log)"
import math, re, sys
t = sys.argv[1]
srv = open(t + "/srv.log", errors="replace").read()
log = {n: open("%s/%s.log" % (t, n), errors="replace").read() for n in ("boss", "bob", "cat")}
def secs(line):
	h, m, s = re.search(r" (\d\d):(\d\d):(\d\d\.\d+) ", line).groups()
	return int(h) * 3600 + int(m) * 60 + float(s)
# Bought (free out of a round), owned
for w in ("sold kit/airship_skiff to kitboss as 40 for 0",
		"sold kit/airship_core to kitboss as 42 for 0", "sold kit/airship_skiff to kitbob as 44 for 0",
		"sold kit/airship_core to kitcat as 46 for 0", "kit/hull 40: owned by kitboss",
		"kitboss takes the seat of entity 41", "kitbob takes the seat of entity 45",
		"[KIT_AIRSHIPS] a build on an object by kitbob refused: Not yours",
		"[KIT_AIRSHIPS] a build on an object by kitboss refused: The core stays",
		"[KIT_AIRSHIPS] kitboss dug kit/stone from entity 40's cell (1,1,1)"):
	assert w in srv, w
# Built on while it moved: the object's place at that build between where it was
# bought and where it parked
places = {}
for m in re.finditer(r"\[KIT_AIRSHIPS\] kitboss placed \S+ on entity 40's cell \(([-\d,]+)\); "
		r"the object at ([-\d.]+),([-\d.]+),([-\d.]+)", srv):
	places[m[1]] = [float(m[k]) for k in (2, 3, 4)]
assert set(places) == {"1,1,1", "1,1,-2", "1,1,-4", "-1,1,-1"}, places
a, b = places["1,1,-2"], places["-1,1,-1"]
end = [float(x) for x in re.search(r"kit: steered to ([-\d.]+) ([-\d.]+)", log["boss"]).groups()]
moved = math.hypot(b[0] - a[0], b[2] - a[2])
left = math.hypot(b[0] - end[0], b[2] - end[1])
print("the skiff: bought at %.1f,%.1f,%.1f; built on at %.1f,%.1f,%.1f on its way, %.1f m "
	"from the start and %.1f m before its end" % tuple(a + b + [moved, left]))
assert moved > 2 and left > 10, (moved, left)
# Collision with a placed voxel: kitboss on the deck, then on top of it
marks = ["red", "before", "jumped", "parked", "lobby"]  # the bodies boss.cmds logs, in order
feet = re.findall(r"kit: feet at ([-\d.]+),([-\d.]+),([-\d.]+), frame (\S+)", log["boss"])
assert len(feet) == len(marks), (len(feet), marks)
f = {k: ([float(x) for x in v[:3]], v[3]) for k, v in zip(marks, feet)}
print("kitboss's feet: on the deck %.3f, after the jump %.3f (frames %s, %s)" % (
	f["before"][0][1], f["jumped"][0][1], f["before"][1], f["jumped"][1]))
assert f["before"][1] == "40" and f["jumped"][1] == "40", f
assert abs(f["jumped"][0][1] - f["before"][0][1] - 1) < 0.15, f
# [KIT_AIRSHIPS_2] Red's island (a kit/terrain_region) walked on, kitbob on
# Blue's (its kit/symmetry copy); "To the lobby" from Blue's island
bob = re.findall(r"kit: feet at ([-\d.]+),([-\d.]+),([-\d.]+), frame (\S+)", log["bob"])
print("on the islands: kitboss %s, kitbob %s; after To the lobby %s" % (f["red"], bob[:1], f["lobby"]))
for (x, y, z), fr in (f["red"], ([float(v) for v in bob[0][:3]], bob[0][3])):
	assert fr == "none" and abs(y - 0.5) < 0.05 and 32 <= abs(x) <= 47 and abs(z) < 13, (x, y, z, fr)
assert x < 0, x
(x, y, z), fr = f["lobby"]
assert fr == "none" and math.hypot(x, z + 2) < 1 and abs(y - 0.5) < 0.05, f["lobby"]
assert f["parked"][0][0] < -20, f["parked"]
assert re.search(r"pause: the items [^\n]*To the lobby", log["boss"]), "no To the lobby in the menu"
assert "kit/pause_menu_action 38: pressed by kitboss" in srv, "the press"
assert "purchases free" in log["boss"], "the wallet not free"
# The ground: the heightmap; the seed and its image
assert "heightmap: terrain built: 1024x1024 samples" in log["boss"]
assert re.search(r"Terrain by kitboss: seed at \(20,20,60\) size 2 strength 2: \d+ columns, [1-9]\d* cells;[^\n]* [1-9]\d* images", srv), "the seed and its image"
# [KIT_AIRSHIP_CORE_DEATH] kitcat over the island's edge: on his core (its helm,
# in the world's frame), then on kitbob's deck (its frame); the server never had
# him elsewhere (a body that fell through the island came back 3 m off and died)
feet = re.findall(r"kit: feet at ([-\d.]+),([-\d.]+),([-\d.]+), frame (\S+)", log["cat"])
print("kitcat's feet: on the core %s, on the skiff %s" % (feet[0] if feet else None, feet[1:]))
assert len(feet) == 2, feet
assert abs(float(feet[0][2]) - 15) < 1 and 0.45 < float(feet[0][1]) < 1.05, feet
assert feet[1][3] == "44" and abs(float(feet[1][1]) - 0.5) < 0.05 and float(feet[1][2]) > 14, feet
corr = [float(x) for x in re.findall(r"kit: the body corrected by ([\d.]+) m", log["cat"])]
assert max(corr, default=0) < 1, corr
assert "kitcat died" not in srv, "kitcat died"
# The budget: one rebuild every 0.5 s at most for all ships together
rb = []
for l in srv.splitlines():
	m = re.search(r"\[KIT_AIRSHIPS\] entity (\d+)'s own voxels rebuilt \(rev (\d+)\): .* (\d+) boxes; "
		r"model ([\d.]+) ms, boxes ([\d.]+) ms; waited (\d+) ms", l)
	if m:
		# (when it started: the line comes after the work)
		rb.append((secs(l) - (float(m[4]) + float(m[5])) / 1000, int(m[1]), int(m[2]), float(m[4]), float(m[5]), int(m[6])))
gaps = [b[0] - a[0] for a, b in zip(rb, rb[1:])]
print("rebuilds: %d of %s; gaps %.3f s at least; model %.1f ms, boxes %.1f ms at most; "
	"waited %d ms at most" % (len(rb), sorted(set(r[1] for r in rb)), min(gaps),
	max(r[3] for r in rb), max(r[4] for r in rb), max(r[5] for r in rb)))
assert {40, 42, 44, 46} <= set(r[1] for r in rb), rb
assert min(gaps) > 0.49, gaps
# The two changed at once: the second waited its turn
i42 = [i for i, r in enumerate(rb) if r[1] == 42][0]
pair = [r for r in rb[max(i42 - 1, 0):i42 + 2] if r[1] in (40, 42)]
assert max(r[5] for r in pair) >= 350, pair
# The cells as kitbob (on at the start) and kitcat (a late joiner) have them
want = {"40 cell 1,1,1": "empty", "40 cell 1,1,-2": "solid", "40 cell 1,1,-4": "solid",
	"40 cell -1,1,-1": "solid", "40 cell 0,0,0": "solid", "42 cell 0,0,-1": "solid"}
for n, extra in (("bob", {"46 cell 0,0,-1": "solid"}), ("cat", {"44 cell 1,1,1": "solid"})):
	got = dict(re.findall(r"kit: object (\d+ cell \S+) (\w+)", log[n]))
	w = dict(want, **extra)
	assert all(got.get(k) == v for k, v in w.items()), (n, got)
# Stop: the ships gone, and with a new round the money back (split on the
# logged lines, not the drive's wait_log echo)
stopped = log["boss"].split(" : kit editor: the server is Ended (by kitboss)")[1]
got = re.findall(r"kit: object (\d+) cell \S+ (\w+)", stopped)
assert got == [("40", "unknown"), ("46", "unknown"), ("40", "unknown")], got
assert "your money 40" in stopped.split(" : kit editor: the server is Running (by kitboss)")[1]
PY
echo "PASS: the airships${WEB:+ (web)}"
# vim: set noet ts=4 sw=4:
