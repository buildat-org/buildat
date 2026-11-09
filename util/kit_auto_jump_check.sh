#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1.5 min (2026-11-09)
# covers: builtin/kit/types/walker.lua builtin/kit/client_lua/move.lua builtin/kit/client_lua/controls.lua builtin/kit/kit.cpp util/web_drive.js
# [KIT_AUTO_JUMP] kit/walker's auto_jump, on a fresh Workbench save (stone):
# a spawner of players (3) at (0, 1, 0) facing +z, a kit/walker (4), a
# platform one voxel high from z 3 to 9 with a wall two high on it at z 8.
# kitboss holds W from the spawner each time (no Jump), his body sampled:
#   1. a touch client (BUILDAT_TOUCH=1), auto_jump touchscreen (the
#      default): up the step onto the platform, stopped by the wall;
#   2. auto_jump off: stopped at the step;
#   3. still off, in the editor's Walk view (edit mode): up the step;
#   4. a desktop client: touchscreen stops at the step, all climbs it.
# Native, or "web": 1-3 in a page as a phone (Chrome).
#   util/kit_auto_jump_check.sh [web]
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
check_tmp kit_auto_jump${WEB:+_web}; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
export BUILDAT_JOIN_PASSWORD=checkpass12
# A sequence as a page's steps: a held key a holdkey
cat > "$t/to_web.py" <<'PY'
import json, re, sys
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
	elif cmd == "keydown":
		held.append(rest.lower() if len(rest) == 1 else rest)
	elif cmd == "keyup":
		held = []
	elif cmd == "quit":
		out.append(["sync", 3000])
	else:
		sys.exit("no page's step for: " + line)
json.dump(out, sys.stdout)
PY
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	${WEB:+-W "$here/web"} ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
native() # <name>
{
	run_client 90 "$t/$1.log" timeout 300 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" || fail "client $1 failed ($t/$1.log, $t/srv.log)"
}
page() # <name>: kitboss's account of old, as a phone
{
	printf '[["nav", "${URL}?scale=0.648148"], ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["selall"], ["frames", 2], ["type", "kitboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Enter"], ["waitlog", "Joined as kitboss", 30], ["frames", 2]]' \
		> "$t/$1.head.json"
	python3 "$t/to_web.py" "$t/$1.cmds" "$t/$1.head.json" > "$t/$1.json" ||
		fail "the steps of $1"
	TOUCH=1 WEB_DRIVE_VIEWPORT=1024x700@1 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
		"$here/util/web_drive.sh" chrome workbench "$t/$1.json" "$t/drive_$1" \
		> "$t/drive_$1.txt" 2>&1
	local st=$?
	cp "$t/drive_$1/page.log" "$t/$1.log" 2>/dev/null
	[ $st = 0 ] || fail "the page's $1 ($(tail -2 "$t/drive_$1.txt"), $t/$1.log, $t/srv.log)"
}
ed() { printf 'event kit_edit %s\nsync 5000\n' "$1"; }
mode() # <on>
{
	printf 'event kit_edit {"op": "mode", "on": %s}\nwait_log_any 10000 kit editor: edit mode %s\n' \
		"$1" "$([ "$1" = true ] && echo on || echo off)"
}
# Stopped, auto_jump set, Running again: kitboss on the spawner, out of
# edit mode
again() # <auto_jump>
{
	mode true
	echo 'event kit_edit {"op": "stop"}'
	echo 'wait_log 10000 kit editor: the server is Ended (by kitboss)'
	ed "{\"op\": \"set\", \"id\": 4, \"comp\": 0, \"param\": \"auto_jump\", \"value\": \"$1\"}"
	echo 'event kit_edit {"op": "play"}'
	echo 'wait_log 10000 kit editor: the server is Running (by kitboss)'
	echo 'wait_log 10000 the server put the player at (0, 1.4, 0)'
	mode false
	echo 'frames 30'
}
walk() # W held, then the body logged
{
	printf 'keydown W\ndelay 1800\nkeyup W\nframes 30\nsync 1000\nevent kit_body\nframes 3\n'
}
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
	ed '{"op": "place", "type": "kit/spawner", "pos": [0, 1, 0]}'
	ed '{"op": "set", "id": 3, "comp": 0, "param": "players", "value": true}'
	ed '{"op": "place", "type": "kit/walker", "pos": [0, 1, 0]}'
	for z in $(seq 3 9); do
		for x in $(seq -2 2); do
			ed "{\"op\": \"set_voxel\", \"pos\": [$x, 1, $z], \"voxel\": \"kit/stone\"}"
		done
	done
	for y in 2 3; do
		for x in $(seq -2 2); do
			ed "{\"op\": \"set_voxel\", \"pos\": [$x, $y, 8], \"voxel\": \"kit/stone\"}"
		done
	done
	echo 'event kit_edit {"op": "play"}'
	echo 'wait_log 10000 kit editor: the server is Running (by kitboss)'
	printf 'sync 3000\nquit\n'
} > "$t/setup.cmds"
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" native setup
# The touch client: 1 touchscreen, 2 off, 3 off in the Walk view
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
EOF
	again touchscreen
	walk
	again off
	walk
	mode true
	echo 'wait_log_any 5000 kit: auto jump on'
	echo 'frames 30'
	walk
	echo 'quit'
} > "$t/touch.cmds"
if [ -n "$WEB" ]; then
	page touch
else
	BUILDAT_TOUCH=1 BUILDAT_JOIN_NAME=kitboss native touch
fi
# The desktop client: touchscreen, then all
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
EOF
	again touchscreen
	walk
	again all
	walk
	echo 'quit'
} > "$t/desk.cmds"
BUILDAT_JOIN_NAME=kitboss native desk
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
python3 -I - "$t" <<'PY' || fail "auto jump ($t/touch.log, $t/desk.log, $t/srv.log)"
import re, sys
t = sys.argv[1]
def bodies(name):
	log = open(t + "/" + name + ".log", errors="replace").read()
	return [tuple(float(v) for v in m) for m in re.findall(
			r"kit: body at ([-0-9.]+),([-0-9.]+),([-0-9.]+), \d+ acks, (\d+) corrections", log)]
touch, desk = bodies("touch"), bodies("desk")
for n, b in zip(("touch touchscreen", "touch off", "touch off, Walk view"), touch):
	print("%s: at %.2f,%.2f,%.2f, %d corrections" % ((n,) + b))
for n, b in zip(("desktop touchscreen", "desktop all"), desk):
	print("%s: at %.2f,%.2f,%.2f, %d corrections" % ((n,) + b))
# The server steps the jump the client chose (its inputs' auto): no
# corrections
assert all(b[3] == 0 for b in touch + desk), (touch, desk)
assert len(touch) == 3 and len(desk) == 2, (touch, desk)
up = lambda b: b[1] > 1.3
# Up the step and on to the wall two high, which stops it
assert up(touch[0]) and 6 < touch[0][2] < 7.5, touch[0]
assert not up(touch[1]) and touch[1][2] < 2.6, touch[1]
assert up(touch[2]), touch[2]
assert not up(desk[0]) and desk[0][2] < 2.6, desk[0]
assert up(desk[1]) and desk[1][2] < 7.5, desk[1]
PY
echo "PASS: auto jump${WEB:+ (web)}: a touch client up a one-voxel step without Jump (not a wall two high), off stops it but in the editor's Walk view, all on a desktop client"
# vim: set noet ts=4 sw=4:
