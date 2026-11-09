#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1.5 min (2026-11-08)
# covers: builtin/kit/types/environment.lua builtin/kit/client_lua/environment.lua builtin/kit/client_lua/module.lua extensions/sky_render/** apps/workbench/**
# [KIT_FAST_PHYSICAL] (kit_plan 4t) kit/environment's third lighting,
# natively and in headless Chrome. A fresh save, the admin Ended, a flat
# grassland World (no trees), a plate (kit/part) over the ground, the
# root's environment placed: its default is fast_physical, drawn HDR and
# metered with no shadow map and no bloom; then physical (the shadow map
# on), cartoon, and fast_physical again. The lines the client logs for
# each, and the plate's noon shadow under physical alone.
# [KIT_LAMP_PROMPT] A builder's lamp voxel placed with the 3D camera still lit
# within 0.6 s, kitboss's own and kitbob's (a second builder, native), in both
# views; the chunk scans' cost printed.
#   util/kit_fast_physical_check.sh [web]
set -u
. "$(dirname "$0")/check_lib.sh"
check_user
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
WEB=
[ "${1:-}" = web ] && WEB=1
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
[ -z "$WEB" ] || [ -f "$here/web/buildat.wasm" ] || skip "no web build (util/build_web.sh)"
check_tmp "kit_fast_physical${WEB:+_web}"; t=$CHECK_TMP
cd "$here/Build"
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" ${WEB:+-W "$here/web"} ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
n=0
edit() # <json>
{
	n=$((n + 1))
	printf 'event kit_edit %s\nwait_log 10000 entities, %d to undo\n' "$1" "$n"
}
# An edit and the line it brings, waited for from before it is sent
edit_line() # <json> <the line>
{
	n=$((n + 1))
	printf 'event kit_edit %s\nwait_log 30000 %s\n' "$1" "$2"
}
lighting() # <mode> <the line>
{
	edit_line "{\"op\": \"set\", \"id\": 5, \"comp\": 0, \"param\": \"lighting\", \"value\": \"$1\"}" "$2"
}
SKY="12.0 o'clock, sun 1, moon 0, stars 0.00, clouds 0.10 at 120, wind 2.0 toward 180; clear 1.00: light 1.00, fog 1.00, sun through 1.00"
# The plate from above its noon shadow (kit_lighting_check's camera)
shot() # <name>
{
	printf 'event kit_cam3d 10 8 16 10 0.5 7.1\nframes 10\ndelay 1000\nframes 3\nscreenshot %s/%s.png\n' "$t" "$1"
}
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
	edit '{"op": "place", "type": "kit/terrain", "pos": [0, 1, 0]}'
	edit '{"op": "set", "id": 3, "comp": 0, "param": "biome", "value": "grassland"}'
	echo "wait_log_any 30000 kit: World: generated again"
	edit_line '{"op": "set", "id": 3, "comp": 0, "param": "decorations", "value": false}' "kit: World: generated again"
	echo "idle 30000"
	edit '{"op": "place", "type": "kit/part", "pos": [10, 6, 5]}'
	edit '{"op": "set", "id": 4, "comp": 0, "param": "size", "value": [4, 0.5, 4]}'
	edit_line '{"op": "place", "type": "kit/environment", "pos": [0, 1, 0]}' \
		"kit: lighting fast_physical (HDR, metered; no shadow map, no bloom)"
	# The noon sun this check's plate was measured under (the default 15
	# o'clock and north 0 since [KIT_ENV_DEFAULTS])
	edit '{"op": "set", "id": 5, "comp": 0, "param": "time", "value": 12}'
	edit '{"op": "set", "id": 5, "comp": 0, "param": "north", "value": 30}'
	edit_line '{"op": "set", "id": 5, "comp": 0, "param": "cloud_cover", "value": 0.1}' \
		"kit: sky: fast_physical, $SKY, shadows 0"
	shot fast
	lighting physical "kit: sky: physical, $SKY, shadows 1"
	shot physical
	lighting cartoon "kit: sky: cartoon, $SKY, shadows 0"
	shot cartoon
	lighting fast_physical "kit: sky: fast_physical, $SKY, shadows 0"
	# [KIT_LAMP_PROMPT] A lamp placed with the camera still lights at once
	# (the sweep would take up to 3 s), and kitbob's too
	printf 'event kit_edit {"op": "voxel", "name": "lamp", "texture": "kit/sand.png", "light": 14}\nsync 5000\n'
	printf 'event kit_cam3d 10 8 16 10 0.5 7.1\nwait_log_any 10000 kit: lamps: 0 lit about the camera\nframes 10\n'
	edit_line '{"op": "set_voxel", "pos": [10, 7, 13], "voxel": "kitboss/lamp"}' "kit: lamps: 1 lit about the camera"
	printf 'event kit_edit {"op": "builder", "name": "kitbob", "on": true}\n'
	echo "wait_log 120000 kit: lamps: 2 lit about the camera"
	echo quit
} > "$t/boss.cmds"
cat > "$t/bob.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
event kit_edit {"op": "mode", "on": true}
wait_log_any 10000 kit editor: edit mode on
event kit_cam3d 10 8 16 10 0.5 7.1
wait_log_any 30000 kit: lamps: 1 lit about the camera
frames 10
event kit_edit {"op": "set_voxel", "pos": [12, 7, 13], "voxel": "kitboss/lamp"}
wait_log 10000 kit: lamps: 2 lit about the camera
sync 3000
quit
EOF
native() # <name>: its commands in $t/<name>.cmds
{
	run_client 60 "$t/$1.log" timeout 300 bin/buildat -C "$t/client_cache_$BUILDAT_JOIN_NAME" \
		-D "$t/cu_$BUILDAT_JOIN_NAME" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-o lighting=game -c @"$t/$1.cmds" ||
		fail "the client failed ($t/$1.log, $t/srv.log)"
}
# The admin's account, natively (a page gets no admin from a setup code)
cat > "$t/admin.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
sync 3000
quit
EOF
printf 'wait_log_any 60000 Joined as kitbob\nsync 3000\nquit\n' > "$t/bob0.cmds"
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" native admin
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 native bob0
# kitbob once kitboss has made him a builder
(
	wait_for_log "$t/srv.log" "kitboss made builder kitbob" 600 &&
		BUILDAT_JOIN_NAME=kitbob native bob
) &
bob=$!
CHECK_PIDS+=($bob)
c=$t/boss.log
if [ -n "$WEB" ]; then
	# The native sequence as a page's steps; the page asks for the game's
	# lighting (software GL's default is cartoon)
	python3 -I - "$t/boss.cmds" > "$t/boss.json" <<'EOF' ||
import json, re, shlex, sys
# The pointer lock always granted (kit_templates_check's stub): a page
# without it opens the pause menu over the view
STUB = """(function(){ var held = null;
 Object.defineProperty(document, 'pointerLockElement', {configurable: true, get: function(){ return held; }});
 function set(e){ held = e; document.dispatchEvent(new Event('pointerlockchange')); }
 HTMLCanvasElement.prototype.requestPointerLock = function(){ if(held !== this) set(this); return Promise.resolve(); };
 document.exitPointerLock = function(){ if(held) set(null); };
 return 'stub'; })()"""
out = [["nav", "${URL}?scale=0.648148&pref=lighting=game"], ["eval", STUB],
	["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
	["selall"], ["frames", 2], ["type", "kitboss"], ["frames", 2],
	["key", "Tab"], ["frames", 2], ["type", "checkpass12"], ["frames", 2],
	["key", "Enter"], ["waitlog", "Joined as kitboss", 30]]
for line in open(sys.argv[1]):
	cmd, _, rest = line.strip().partition(" ")
	if cmd == "event":
		out.append(["event", rest])
	elif cmd in ("wait_log", "wait_log_any"):
		ms, _, text = rest.partition(" ")
		out.append(["waitlog" if cmd == "wait_log" else "waitlog_any",
			re.escape(text), int(ms) / 1000])
	elif cmd in ("frames", "idle", "sync"):
		out.append([cmd, int(rest)])
	elif cmd == "delay":
		out.append(["wait", int(rest)])
	elif cmd == "keypress":
		out.append(["key", rest])
	elif cmd == "screenshot":
		out.append(["shot", rest])
	elif cmd == "click":
		out.append(["click", *shlex.split(rest)[:2]])
	elif cmd == "quit":
		out.append(["sync", 3000])
	elif cmd:
		sys.exit("no page's step for: " + line)
json.dump(out, sys.stdout)
EOF
		fail "the page's steps"
	WEB_DRIVE_VIEWPORT=1024x700@1 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
		"$here/util/web_drive.sh" chrome workbench "$t/boss.json" "$t/drive" \
		> "$t/drive.txt" 2>&1
	st=$?
	cp "$t/drive/page.log" "$c" 2>/dev/null
	[ $st = 0 ] || fail "the page ($(tail -2 "$t/drive.txt"), $c, $t/srv.log)"
else
	native boss
fi
wait $bob || fail "kitbob ($t/bob.log, $t/srv.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
# [KIT_LAMP_PROMPT] From the edit sent to its lamp lit, in each one's log; the
# chunks' scans' cost
python3 -I - "$c" "$t/bob.log" <<'EOF' || fail "the lamps ($c, $t/bob.log)"
import re, sys
def at(line):
	h, m, s = re.search(r" (\d\d):(\d\d):(\d\d\.\d+) ", line).groups()
	return int(h) * 3600 + int(m) * 60 + float(s)
def first(lines, text, after=0):
	for l in lines:
		if text in l and at(l) >= after:
			return at(l)
	raise SystemExit("not logged: " + text)
boss, bob = [open(f, errors="replace").read().splitlines() for f in sys.argv[1:]]
t0 = first(boss, '{"op": "set_voxel", "pos": [10, 7, 13]')
own = first(boss, "kit: lamps: 1 lit about the camera", t0) - t0
t1 = first(bob, '{"op": "set_voxel", "pos": [12, 7, 13]')
other = first(boss, "kit: lamps: 2 lit about the camera", t1) - t1
bob_own = first(bob, "kit: lamps: 2 lit about the camera", t1) - t1
ms = [float(m) for l in boss for m in re.findall(r"kit: lamps: a chunk's \d+ cells scanned in ([0-9.]+) ms", l)]
print("the lamps lit after %.2f s (kitboss's own), %.2f s (kitbob's in kitboss's view), %.2f s "
	"(kitbob's own); a chunk's scan %.2f..%.2f ms (%d)" % (own, other, bob_own, min(ms), max(ms), len(ms)))
assert max(own, other, bob_own) < 0.6, (own, other, bob_own)
EOF
# The default's line came before the first edit's of the lighting
python3 -I - "$c" <<'EOF' || fail "the lines ($c)"
import sys
log = open(sys.argv[1], errors="replace").read()
i = log.index("kit: lighting fast_physical (HDR, metered; no shadow map, no bloom)")
j = log.index("kit: lighting physical (HDR, metered)", i)
k = log.index("kit: lighting cartoon", j)
log.index("kit: lighting fast_physical (HDR, metered; no shadow map, no bloom)", k)
EOF
echo "ok: fast_physical the default, HDR and metered with no shadow map and no bloom; physical with its shadow map, cartoon, and back"
# The plate's shadow: the frame's middle (the ground under it) over its
# right side (the open ground), rows 4-5 of 16 x 10 cells
shade() # <png>
{
	python3 -I - "$1" <<'EOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("L").resize((16, 10), Image.BOX)
mid = [im.getpixel((x, y)) for y in (4, 5) for x in (7, 8)]
side = [im.getpixel((x, y)) for y in (4, 5) for x in (13, 14, 15)]
print("%.2f" % ((sum(mid) / len(mid)) / max(1, sum(side) / len(side))))
EOF
}
for s in fast physical cartoon; do
	[ -s "$t/$s.png" ] || fail "no shot $s ($c)"
done
sf=$(shade "$t/fast.png") sp=$(shade "$t/physical.png") sc=$(shade "$t/cartoon.png")
awk "BEGIN{exit !($sp < 0.6 && $sf > 0.85 && $sc > 0.85)}" ||
	fail "the plate's shadow: fast_physical $sf, physical $sp, cartoon $sc (the middle over the sides; $t)"
echo "ok: the plate's shadow under physical ($sp of the open ground), none under fast_physical ($sf) nor cartoon ($sc)"
echo "PASS: fast_physical${WEB:+ (web)}: the default, physical without the shadow map and the bloom"
# vim: set noet ts=4 sw=4:
