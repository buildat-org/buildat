#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~40 s (2026-11-08)
# covers: builtin/kit/client_lua/editor.lua builtin/kit/client_lua/controls.lua builtin/kit/kit.cpp
# [KIT_WALK_HERE] The view dropdown's last entry, "Walk here", on a fresh Workbench
# project, the game Running: in Walk it does nothing; in 3D (the camera at 6 8 -6
# looking at 0 1 0) the walker is put under the camera, the walk camera looking as the
# 3D one did, the view Walk, and the 3D camera stays where it was; in 2D (the plan
# at -4 4) the walker on the ground under the plan's middle; in Signals put too.
# (HUD hides the bar: no dropdown to pick from there.) The views by the dropdown
# too (a page's F5 is the browser's).
# Native, or "web": kitboss in a page (the account made natively first).
#   util/kit_walk_here_check.sh [web]
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
check_tmp kit_walk_here${WEB:+_web}; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ${WEB:+-W "$here/web"} ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
pick() # <label>: that entry of the view dropdown (the bar's leftmost)
{
	printf 'click DropDownList "▼" 0 0\ndelay 300\nframes 3\nclick Text "%s"\n' "$1"
}
cat > "$t/admin.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
sync 3000
quit
EOF
cat > "$t/boss.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
event kit_edit {"op": "mode", "on": true}
wait_log_any 10000 kit editor: edit mode on
wait_log_any 10000 kit editor: the server is Running
frames 5
EOF
{
	# (Walk is the view edit mode starts in; picking it again sends nothing)
	pick "Walk here"
	printf 'wait_log 5000 kit editor: walk here: nothing in Walk\nframes 5\nevent kit_body\n'
	printf 'event kit_cam3d 6 8 -6 0 1 0\nframes 5\n'
	pick "Walk here"
	printf 'wait_log 5000 kit editor: walk here from 3D\n'
	printf 'wait_log 5000 the server put the player at\nframes 10\nevent kit_cam_where 3d\n'
	printf 'sync 2000\nframes 30\nevent kit_body\n'
	printf 'event kit_plan -4 4 20 3\nframes 5\n'
	pick "Walk here"
	printf 'wait_log 5000 kit editor: walk here from 2D\n'
	printf 'wait_log 5000 the server put the player at\nsync 2000\nframes 30\nevent kit_body\n'
	pick "Signals (F5)"
	printf 'wait_log 5000 kit editor: the view is Signals\nframes 5\n'
	pick "Walk here"
	printf 'wait_log 5000 kit editor: walk here from Signals\n'
	printf 'wait_log 5000 the server put the player at\nframes 5\n'
	echo "screenshot $t/end.png"
	printf 'sync 2000\nquit\n'
} >> "$t/boss.cmds"
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
native() # <name>
{
	run_client 60 "$t/$1.log" timeout 180 bin/buildat -C "$t/client_cache" -D "$t/cu" \
		-s localhost:$SERVER_PORT -w 1024x700 -l 3 -c @"$t/$1.cmds" ||
		fail "the client $1 ($t/$1.log, $t/srv.log)"
}
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 native admin
if [ -n "$WEB" ]; then
	python3 -I - "$t/boss.cmds" > "$t/boss.json" <<'EOF' || fail "the page's steps"
import json, re, shlex, sys
out = [["nav", "${URL}?scale=0.648148"], ["waitlog", "accounts: the login page shown", 120],
	["wait", 1000], ["selall"], ["frames", 2], ["type", "kitboss"], ["frames", 2],
	["key", "Tab"], ["frames", 2], ["type", "checkpass12"], ["frames", 2],
	["key", "Enter"]]
for line in open(sys.argv[1]):
	cmd, _, rest = line.strip().partition(" ")
	if cmd == "event":
		out.append(["event", rest])
	elif cmd in ("wait_log", "wait_log_any"):
		ms, _, text = rest.partition(" ")
		out.append(["waitlog" if cmd == "wait_log" else "waitlog_any",
			re.escape(text), int(ms) / 1000])
	elif cmd in ("frames", "sync"):
		out.append([cmd, int(rest)])
	elif cmd == "delay":
		out.append(["wait", int(rest)])
	elif cmd == "screenshot":
		out.append(["shot", rest])
	elif cmd == "click":
		a = shlex.split(rest)
		out.append(["click", *a[:2], *map(int, a[2:])])
	elif cmd == "quit":
		out.append(["sync", 3000])
	elif cmd:
		sys.exit("no page's step for: " + line)
json.dump(out, sys.stdout)
EOF
	WEB_DRIVE_VIEWPORT=1024x700@1 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
		"$here/util/web_drive.sh" chrome workbench "$t/boss.json" "$t/drive" \
		> "$t/drive.txt" 2>&1
	st=$?
	cp "$t/drive/page.log" "$t/boss.log" 2>/dev/null
	[ $st = 0 ] || fail "the page ($(tail -2 "$t/drive.txt"), $t/boss.log, $t/srv.log)"
else
	native boss
fi
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
python3 -I - "$t" <<'PY' || fail "walk here ($t/boss.log, $t/srv.log)"
import math, re, sys
t = sys.argv[1]
c = open(t + "/boss.log", errors="replace").read()
srv = open(t + "/srv.log", errors="replace").read()
feet = [tuple(map(float, m)) for m in re.findall(r"kit: feet at ([-0-9.]+),([-0-9.]+),([-0-9.]+)", c)]
here = re.findall(r"kitboss walks here: \(([-0-9.e]+), ([-0-9.e]+), ([-0-9.e]+)\)", srv)
print("feet: %s; asked: %s" % (feet, here))
assert len(here) == 3, here
# Walk: nothing asked before the 3D one
assert c.find("walk here: nothing in Walk") < c.find("walk here from 3D") > 0
# 3D: under the camera (its eye at 8), looking as it did; the 3D camera kept
x, y, z = map(float, here[0])
assert abs(x - 6) < 0.01 and abs(z + 6) < 0.01 and 6 < y < 7, here[0]
m = re.search(r"the walk camera at \S+ \S+ \S+ looking (\S+) (\S+) (\S+) \(3d\)", c)
d = [float(v) for v in m.groups()]
want = [-6 / 11, -7 / 11, 6 / 11]
print("the walk camera looking %s, the 3D one %s" % (d, ["%.3f" % w for w in want]))
assert sum(a * b for a, b in zip(d, want)) > 0.99, d
assert "the 3D camera at 6.00 8.00 -6.00 (3d)" in c
f = feet[1]
assert abs(f[0] - 6) < 0.3 and abs(f[2] + 6) < 0.3, f
# 2D: on the ground under the plan's middle
x, y, z = map(float, here[1])
assert abs(x + 4) < 0.01 and abs(z - 4) < 0.01, here[1]
f = feet[2]
assert abs(f[0] + 4) < 0.3 and abs(f[2] - 4) < 0.3 and abs(f[1] - y) < 0.3, (f, y)
assert "the server is Ended" not in c
PY
echo "PASS: Walk here from 3D, 2D and Signals, nothing in Walk${WEB:+ (web)}"
# vim: set noet ts=4 sw=4:
