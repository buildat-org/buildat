#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-08)
# covers: apps/workbench/templates/airships/** builtin/kit/types/airship*.json builtin/kit/types/airship.lua builtin/kit/types/engine.lua builtin/kit/types/radar.lua builtin/kit/types/radar.client.lua builtin/kit/types/supply.lua builtin/kit/types/trigger_zone.lua builtin/kit/types/shop.lua builtin/kit/types/wallet.lua builtin/kit/types/wallet.client.lua builtin/kit/types/turret.lua builtin/kit/kit.cpp
# [KIT_AIRSHIPS] (kit_plan 4s, stages 3 to 6) The airships template's round:
# kitboss steps on the arena's pad, the round starts, he is Red. He buys a
# skiff, a gun and a radar, mounts the gun on his deck, stacks two voxels and
# mounts the radar on the upper; the radar shows kitbob's ships. He digs the
# lower voxel: the upper is cut off from the core (debris), the radar on it
# drops. kitbob joins the running round late (Blue), buys a skiff, a core ship
# and an engine; rides his core ship down into the deadly ground zone: the ship
# is lost (a point to Red) and he dies. He flies his skiff, mounts the engine
# (its parts' thrust up: faster), flies it again. kitboss flies near, mans his
# gun and shoots kitbob's engine: the voxel under it goes (the rebuild
# follows), the engine drops. kitbob jumps over his rail into the zone, dies,
# respawns on his pad where his repair crate is: the voxel back. kitboss shoots
# the skiff's core: the ship is lost, Red's second point, Red wins the round.
# Native, or "web": kitboss in a page, kitbob native.
# Screenshots with KEEP_TMP=1: $t/*.png
#   util/kit_airship_fight_check.sh [web]
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
check_tmp "kit_airship_fight${WEB:+_web}"; t=$CHECK_TMP
export BUILDAT_JOIN_PASSWORD=checkpass12
cd "$here/Build"
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
# kit_airships_check's page stub
PAGE_STUB="(function(){ var held = null;
 Object.defineProperty(document, 'pointerLockElement', {configurable: true, get: function(){ return held; }});
 function set(e){ held = e; document.dispatchEvent(new Event('pointerlockchange')); }
 HTMLCanvasElement.prototype.requestPointerLock = function(){ if(held !== this) set(this); return Promise.resolve(); };
 document.exitPointerLock = function(){ if(held) set(null); };
 return 'stub'; })()"
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
	run_client 60 "$t/$1.log" timeout 400 bin/buildat -C "$t/client_cache_$BUILDAT_JOIN_NAME" \
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
# <id> <x> <y> <z> <left|right>: a click at that point of a ship's frame
at() { printf 'event kit_point_obj %s %s %s %s\nframes 3\nmouse_click %s\n' "$@"; }
held() { printf 'keydown %s\ndelay %s\nkeyup %s\nframes 3\n' "$1" "$2" "$1"; }
# The round's entities, in the order bought (the session's ids follow the start's)
BOSS_SHIP=40 BOSS_HELM=41 GUN=42 RADAR=43
BOB_SHIP=44 BOB_HELM=45 BOB_CORE=46 BOB_CORE_HELM=47 ENGINE=48

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

# kitboss: New, "Airships"; Play mode; the arena's pad; Red
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
click Button "Play mode"
wait_log_any 10000 kit editor: the server is Running (by kitboss)
wait_log_any 10000 kit: controls: camera first_person
wait_log_any 10000 your money 40
look_dir 1 0 0
frames 3
EOF
	held W 450
	printf 'wait_log 60000 left | Red 0 : Blue 0\nsync 3000\n'
	shot round
	# A skiff and a gun; the gun on (0,0,2); two voxels on the deck before the
	# helm, (1,1,-1) and (1,2,-1); a radar on the upper's side (all within
	# reach of the helm)
	printf 'event kit_use 22\nwait_log 10000 your money 15\n'
	printf 'event kit_use 25\nwait_log 10000 holding part kit/airship_gun\n'
	printf 'event kit_use %s\nwait_log 10000 seat %s\nframes 10\n' $BOSS_HELM $BOSS_HELM
	printf 'keypress F\nwait_log 10000 movement kit/walker\nframes 20\n'
	at $BOSS_SHIP 0 0.5 2 right
	printf 'wait_log 10000 holding part \n'
	at $BOSS_SHIP 1 0.5 -1 right
	printf 'wait_log 10000 object boxes kitown_%s.\n' $BOSS_SHIP
	at $BOSS_SHIP 1 1.5 -1 right
	printf 'wait_log 10000 object boxes kitown_%s.\nevent kit_point_obj\n' $BOSS_SHIP
	printf 'event kit_use 27\nwait_log 10000 holding part kit/airship_radar\n'
	at $BOSS_SHIP 0.5 2 -1 right
	printf 'wait_log 10000 holding part \nevent kit_point_obj\n'
	printf 'wait_log 120000 radar shown: Radar: kitbob\nlook_dir 0.5 0.1 1\n'
	shot radar
	# Debris: the lower voxel dug from its side, the upper cut off from the
	# core, the radar on it dropped
	at $BOSS_SHIP 1 1 -1.5 left
	printf 'wait_log 10000 object boxes kitown_%s.\nevent kit_point_obj\n' $BOSS_SHIP
	shot debris
	# After kitbob's core ship's loss: near his skiff, the gun
	printf 'wait_log 120000 Red 1 : Blue 0\n'
	printf 'event kit_use %s\nwait_log 10000 seat %s\nevent kit_steer -22 18\n' $BOSS_HELM $BOSS_HELM
	printf 'wait_log 60000 kit: steered to\nevent kit_steer off\nframes 10\n'
	printf 'keypress F\nwait_log 10000 movement kit/walker\nframes 10\n'
	printf 'event kit_use %s\nwait_log 10000 seat %s\nframes 10\n' $GUN $GUN
	printf 'event kit_aim %s 45 3 fire\nwait_log 90000 wallet note: A part dropped: engine\n' $ENGINE
	shot shot_engine
	# kitbob repaired (his crate taken), then his core shot
	printf 'event kit_aim 0\nwait_log 120000 entity 39 shows ""\n'
	# (the repair in the same tick; its rebuild may come before this sees the crate)
	printf 'frames 30\n'
	shot repaired
	printf 'event kit_aim %s 45 3 fire\nwait_log 120000 Red wins\n' $BOB_SHIP
	shot won
	printf 'event kit_aim 0\nwait_log 60000 Last round: Red won\n'
	shot after
	printf 'sync 3000\nquit\n'
} > "$t/boss.cmds"
# kitbob, late: Blue; a skiff, a core ship, an engine
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 20000 your money 40
look_dir 1 0 0
frames 3
EOF
	held W 450
	printf 'wait_log 60000 left | Red 0 : Blue 0\nsync 3000\n'
	printf 'event kit_use 32\nwait_log 10000 your money 15\n'
	printf 'event kit_use 34\nwait_log 10000 your money 5\n'
	printf 'event kit_use 36\nwait_log 10000 holding part kit/airship_engine\n'
	# The core ship down into the deadly zone: lost, and he dies (his pad again)
	printf 'event kit_use %s\nwait_log 10000 seat %s\nframes 10\n' $BOB_CORE_HELM $BOB_CORE_HELM
	printf 'keydown C\nwait_log 30000 wallet note: Your ship was lost\nkeyup C\n'
	printf 'wait_log 30000 the server put the player at\nframes 30\n'
	shot respawned
	# The skiff flown without the engine, the engine mounted on the rail's log
	# (2,1,0), flown with it
	printf 'event kit_use %s\nwait_log 10000 seat %s\nframes 10\n' $BOB_HELM $BOB_HELM
	held W 1200
	held S 1200
	printf 'keypress F\nwait_log 10000 movement kit/walker\nframes 20\n'
	at $BOB_SHIP 2 1.5 0 right
	printf 'wait_log 10000 holding part \nevent kit_point_obj\nframes 10\n'
	shot engine
	printf 'event kit_use %s\nwait_log 10000 seat %s\nframes 10\n' $BOB_HELM $BOB_HELM
	held W 1200
	held S 1200
	printf 'keypress F\nwait_log 10000 movement kit/walker\n'
	# The engine shot off: over the rail into the zone, back on his pad, his
	# crate there repairs the skiff
	printf 'wait_log 120000 wallet note: A part dropped: engine\nlook_dir 1 0 0\nframes 3\n'
	printf 'keydown W\ndelay 300\nkeydown Space\ndelay 600\nkeyup Space\nkeyup W\n'
	printf 'wait_log 30000 the server put the player at\n'
	printf 'frames 30\nlook_dir 0 -0.2 1\n'
	shot bob_repaired
	printf 'wait_log 120000 Last round: Red won\nsync 3000\nquit\n'
} > "$t/bob.cmds"
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
until_seen "$SRV" "kitboss mounted kit/airship_radar" $boss "kitboss did not mount his radar"
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 native bob
wait $boss || fail "kitboss's client ($t/boss.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
python3 -I - "$t" "$BOSS_SHIP $GUN $RADAR $BOB_SHIP $BOB_CORE $ENGINE" <<'PY' || fail "the fight ($t/boss.log, $t/srv.log)"
import re, sys
t = sys.argv[1]
ship, gun, radar, bship, bcore, engine = sys.argv[2].split()
srv = open(t + "/srv.log", errors="replace").read()
log = {n: open("%s/%s.log" % (t, n), errors="replace").read() for n in ("boss", "bob")}
def has(w):
	assert w in srv, w
# Mounted, bought
for w in ("sold kit/airship_skiff to kitboss as %s" % ship, "sold kit/airship_skiff to kitbob as %s" % bship,
		"sold kit/airship_core to kitbob as %s" % bcore,
		"kitboss mounted kit/airship_gun on entity %s's cell (0,1,2) on (0,0,2) as %s" % (ship, gun),
		"kitbob mounted kit/airship_engine on entity %s's cell (2,2,0) on (2,1,0) as %s" % (bship, engine)):
	has(w)
# (on the upper voxel's side)
assert re.search(r"kitboss mounted kit/airship_radar on entity %s's cell \(\S+\) on \(1,2,-1\) as %s" % (ship, radar), srv)
# The radar's contacts
r = re.search(r"radar shown: (Radar: kitbob's ship[^\n]*)", log["boss"])
assert r, "the radar"
print("kitboss's radar:", r[1])
# Debris: the upper voxel cut off, the radar on it dropped
has("[KIT_AIRSHIPS] entity %s: 0 voxels destroyed by kitboss's dig, 1 cut off from the core (debris)" % ship)
has("[KIT_AIRSHIPS] entity %s, mounted on entity %s, drops with its voxel" % (radar, ship))
# Thrust: the parts' sum with the engine, the speed before and after
parts = srv.find("[KIT_AIRSHIPS] entity %s's parts: " % bship)
eng = re.search(r"\[KIT_AIRSHIPS\] entity %s's parts: [^\n]*, 1 engines" % bship, srv)
assert parts >= 0 and eng, "the parts' sum"
lost = srv.find("[KIT_AIRSHIPS] entity %s is lost" % bcore)
def top(a, b):
	return max([float(x) for x in re.findall(r"entity %s flies at ([\d.]+) m/s" % bship, srv[a:b])] or [0])
drop = srv.find("[KIT_AIRSHIPS] entity %s, mounted on entity %s, drops with its voxel" % (engine, bship))
before, after = top(srv.find("[KIT_AIRSHIPS] entity %s's parts" % bship), eng.start()), top(eng.start(), drop)
print("kitbob's skiff: %.2f m/s at most without the engine, %.2f with it (%s)" % (before, after, eng[0]))
assert before > 1 and after > before * 1.3, (before, after)
# Death by touch: the core ship lost, kitbob dead, a point to Red
has("[KIT_AIRSHIPS] entity %s is lost: it touched a deadly zone (the ground kills)" % bcore)
dead = len(re.findall(r"kit/health \d+: died", srv[lost:]))
assert dead >= 2, "kitbob's deaths: %d" % dead
# The engine shot off: its voxel gone, the rebuild after it, the engine dropped
m = re.search(r"kitboss's projectile \d+ hits entity %s's cell \(([-\d,]+)\)" % bship, srv)
assert m, "no hit on kitbob's skiff"
gone = re.search(r"\[KIT_AIRSHIPS\] entity %s: (\d+) voxels destroyed by kitboss's shot" % bship, srv)
assert gone, "no voxel shot"
reb = srv.find("[KIT_AIRSHIPS] entity %s's own voxels rebuilt" % bship, gone.end())
drop = srv.find("[KIT_AIRSHIPS] entity %s, mounted on entity %s, drops with its voxel" % (engine, bship))
assert reb > 0 and drop > 0, (reb, drop)
# Repaired, then its core shot: lost, Red's second point and the round
rep = re.search(r"\[KIT_AIRSHIPS\] entity %s repaired: (\d+) voxels back \(for kitbob\)" % bship, srv)
assert rep and rep.start() > drop, "no repair"
end = srv.find("[KIT_AIRSHIPS] entity %s is lost: kitboss's shot hit its core" % bship)
assert end > rep.start(), "the core"
over = re.findall(r"round over: (.*?) --", srv)
print("hits:", len(re.findall(r"kitboss's projectile \d+ hits entity %s" % bship, srv)),
	"; repaired %s voxels; the round: %s" % (rep[1], over))
assert over and "Red" in over[-1], over
assert "Last round: Red won" in log["bob"]
PY
echo "PASS: an airship fight${WEB:+ (web)}"
# vim: set noet ts=4 sw=4:
