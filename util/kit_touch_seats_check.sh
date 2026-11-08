#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1.5 min (2026-11-08)
# covers: builtin/kit/client_lua/controls.lua builtin/kit/types/turret.lua builtin/kit/types/airship.lua util/web_drive.js
# [KIT_TOUCH_SEAT_BUTTONS] A seat's touch buttons (a movement's touch_buttons), on a
# touchscreen (BUILDAT_TOUCH=1): on a fresh Workbench save an airship hull (5) with a
# seat (6) and a turret (7) with its own seat (8) on its deck. kitboss takes the gun's
# seat: the bar is Fire and Exit, Fire held fires at the cooldown (more than one shot);
# Exit by a tap; the airship's seat: Brake, Gas, Up, Down and Exit, Up held climbs,
# Down held sinks (it would hold its altitude, risen, without).
# Native, or "web": kitboss in a page as a phone (Chrome).
#   util/kit_touch_seats_check.sh [web]
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
check_tmp kit_touch_seats${WEB:+_web}; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
export BUILDAT_JOIN_PASSWORD=checkpass12
# A sequence as a page's steps: a finger held on a button a hold
cat > "$t/to_web.py" <<'PY'
import json, re, sys
out, finger = json.load(open(sys.argv[2])), None
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
	elif cmd == "finger_down":
		m = re.fullmatch(r'1 (\w+) "([^"]*)"', rest)
		finger = [m[1], m[2]]
	elif cmd == "delay":
		out.append(["hold", *finger, int(rest)] if finger else ["wait", int(rest)])
	elif cmd == "finger_up":
		finger = None
	elif cmd == "tap":
		m = re.fullmatch(r'(\w+) "([^"]*)"', rest)
		out.append(["tap", m[1], m[2]])
	elif cmd == "screenshot":
		out.append(["shot", rest])
	elif cmd == "quit":
		out.append(["sync", 3000])
	else:
		sys.exit("no page's step for: " + line)
json.dump(out, sys.stdout)
PY
server()
{
	start_server "$t/srv.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
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
seated() { printf 'event kit_use %s\nwait_log 10000 movement %s, seat %s\nframes 10\n' "$1" "$2" "$1"; }
bar() { printf 'wait_log_any 10000 kit: the touch bar: %s\nframes 5\n' "$1"; }
press() { printf 'finger_down 1 Button "%s"\ndelay %s\nfinger_up 1\nframes 5\n' "$1" "$2"; }
# ---- Set up, natively: the account, the hull's prefab, where a body starts
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
	for z in $(seq -40 -31); do
		for x in $(seq 3 8); do
			ed "{\"op\": \"set_voxel\", \"pos\": [$x, 1, $z], \"voxel\": \"kit/stone\"}"
		done
	done
	ed '{"op": "save_prefab", "ids": [], "box": [3, 1, -40, 8, 1, -31], "name": "hull"}'
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
read -r _ by _ < <(grep -aoP 'kit: feet at \K[-0-9.,]+' "$t/setup.log" | tail -1 | tr , ' ')
[ -n "${by:-}" ] || fail "no body's place ($t/setup.log)"
g=$(python3 -c "print(round($by - 0.5))")
# 3 world, 4 walker; 5 the airship, 6 its seat, 7 the turret, 8 its seat; 9 controls,
# 10 the spawner on the deck
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
	ed "{\"op\": \"place\", \"prefab\": \"kitboss/hull\", \"pos\": [4, $((g + 4)), -30], \"free\": true}"
	ed '{"op": "add_component", "id": 5, "type": "kit/airship"}'
	ed "{\"op\": \"place\", \"type\": \"kit/part\", \"parent\": 5, \"pos\": [6, $((g + 5)), -28], \"params\": {\"size\": [0.8, 0.5, 0.8], \"color\": \"#c03030\"}}"
	ed '{"op": "add_component", "id": 6, "type": "kit/seat"}'
	ed "{\"op\": \"place\", \"type\": \"kit/part\", \"parent\": 5, \"pos\": [7, $((g + 5)), -24], \"params\": {\"size\": [0.6, 0.6, 2], \"color\": \"#303030\"}}"
	ed '{"op": "add_component", "id": 7, "type": "kit/turret"}'
	ed "{\"op\": \"place\", \"type\": \"kit/part\", \"parent\": 7, \"pos\": [7, $((g + 5)), -26], \"params\": {\"size\": [0.8, 0.5, 0.8], \"color\": \"#3030c0\"}}"
	ed '{"op": "add_component", "id": 8, "type": "kit/seat"}'
	ed '{"op": "place", "type": "kit/controls", "pos": [0, 1, 0]}'
	ed "{\"op\": \"place\", \"type\": \"kit/spawner\", \"pos\": [6, $((g + 7)), -26]}"
	ed '{"op": "set", "id": 10, "comp": 0, "param": "players", "value": true}'
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
event kit_edit {"op": "mode", "on": false}
wait_log 10000 kit editor: edit mode off
wait_log 20000 kit: the body's frame: 5
EOF
	# ---- The gun: Fire held
	seated 8 kit/turret
	bar "Fire, Exit"
	press Fire 1800
	printf 'sync 3000\ntap Button "Exit"\n'
	printf 'wait_log 10000 kit: controls: camera first_person, pointer crosshair, movement kit/walker\nframes 10\n'
	# ---- The airship: Up held, then Down
	seated 6 kit/airship
	bar "Brake, Gas, Up, Down, Exit"
	printf 'event kit_body\nframes 3\n'
	press Up 1500
	printf 'event kit_body\nframes 3\n'
	# (longer, and sampled after: the body follows its altitude late)
	press Down 2000
	printf 'sync 1000\nevent kit_body\nframes 3\nsync 1000\nevent kit_body\nframes 3\n'
	echo "screenshot $t/airship.png"
	printf 'sync 3000\nquit\n'
} > "$t/boss.cmds"
if [ -n "$WEB" ]; then
	page boss
else
	BUILDAT_TOUCH=1 BUILDAT_JOIN_NAME=kitboss native boss
fi
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
python3 -I - "$t" <<'PY' || fail "the touch buttons ($t/boss.log, $t/srv.log)"
import re, sys
t = sys.argv[1]
srv = open(t + "/srv.log", errors="replace").read()
boss = open(t + "/boss.log", errors="replace").read()
shots = len(re.findall(r"kitboss fires entity 7's kit/turret", srv))
print("Fire held 1.8 s: %d shots" % shots)
assert shots >= 2, shots
ys = [float(y) for y in re.findall(r"kit: body at [-0-9.]+,([-0-9.]+),", boss)][-4:]
print("the airship: %.2f, Up held 1.5 s %.2f, Down held 2 s %.2f, %.2f" % tuple(ys))
assert ys[1] > ys[0] + 1 and ys[3] < ys[2] < ys[1] - 1, ys
PY
echo "PASS: a seat's touch buttons${WEB:+ (web)}"
# vim: set noet ts=4 sw=4:
