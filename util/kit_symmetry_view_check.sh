#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~40 s, ~1 min with web (2026-11-07)
# covers: builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua builtin/kit/client_lua/prefabs.lua builtin/kit/kit.cpp builtin/kit/symmetry.h
# [KIT_SYMMETRY] (kit_plan 7c stage 3) The editor's view of kit/symmetry, in
# Workbench's world project (64 x 64): kit/symmetry 4 at the middle,
# quadrants straight rotational, authored +x+z; under it a kit/part 6 and
# a kit/sign 7 (copies 8 to 13), a kit/sign 5 outside it at -10, -10, a
# copy's text set (an override):
#   - the plan and the 3D view: the two seams, the three other quadrants
#     shaded (sym_plan.png, sym_3d.png);
#   - copy 8 selected: "Copy of" its source and its parameters alone, no
#     Move, parent or Delete (sym_copy.png); "Go to source 6" selects 6;
#   - kit/symmetry 4 selected: its one override and the parity warning of
#     5 (sym_inspector.png).
# Screenshots kept with KEEP_TMP=1: $t/*.png
#   util/kit_symmetry_view_check.sh
#   util/kit_symmetry_view_check.sh web   the same in headless Chrome
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
here=$(cd "$(dirname "$0")/.." && pwd)
WEB=
if [ "${1:-}" = web ]; then
	WEB=1
	command -v "${CHROME:-google-chrome}" > /dev/null || skip "no Chrome"
	[ -f "$here/web/buildat.wasm" ] || skip "no web client (util/build_web.sh)"
else
	[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
fi
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp "kit_symmetry_view${WEB:+_web}"; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss

n=0
edit() # <json>
{
	n=$((n + 1))
	printf 'event kit_edit %s\nwait_log 10000 entities, %d to undo\n' "$1" "$n"
}
sym() # <param> <value>
{
	edit "{\"op\": \"set\", \"id\": 4, \"comp\": 0, \"param\": \"$1\", \"value\": $2}"
}
# What both clients do once in edit mode with the server stopped
{
	edit '{"op": "place", "type": "kit/world", "pos": [0, 1, 0]}'
	edit '{"op": "place", "type": "kit/symmetry", "pos": [0, 1, 0]}'
	edit '{"op": "place", "type": "kit/sign", "pos": [-10, 2, -10]}'
	edit '{"op": "place", "type": "kit/part", "pos": [6, 1, 4], "parent": 4}'
	edit '{"op": "set", "id": 6, "comp": 0, "param": "size", "value": [3, 1, 2]}'
	edit '{"op": "place", "type": "kit/sign", "pos": [10, 2, 10], "parent": 4}'
	sym slices '"quadrants"'
	sym mode '"rotational"'
	sym slice '"+x+z"'
	sym on true
	edit '{"op": "set", "id": 9, "comp": 0, "param": "text", "value": "A copy of its own"}'
	cat <<EOF
event kit_plan 0 0 80 4
wait_log_any 10000 kit editor: the view is 2D
wait_log_any 10000 kit editor: symmetry 4 2 seams, 3 shaded
frames 5
screenshot $t/sym_plan.png
event kit_cam3d 0 40 -52 0 0 0
wait_log_any 10000 kit editor: the view is 3D
frames 5
screenshot $t/sym_3d.png
event kit_select 8
wait_log_any 10000 kit editor: selected 8
frames 5
screenshot $t/sym_copy.png
click Button "Go to source 6"
wait_log_any 10000 kit editor: to copy 8's source 6
event kit_select 4
wait_log_any 10000 kit editor: symmetry 4: 1 override; parity: 1 entities outside it in the other slices, not copied (5)
frames 5
screenshot $t/sym_inspector.png
sync 3000
EOF
} > "$t/body.cmds"

if [ -n "$WEB" ]; then
	python3 -I - "$t/body.cmds" > "$t/body.json" <<'PY' || fail "the page's steps"
import json, re, shlex, sys
out = []
for line in open(sys.argv[1]):
	cmd, _, rest = line.strip().partition(" ")
	if cmd == "event":
		out.append(["event", rest])
	elif cmd in ("wait_log", "wait_log_any"):
		ms, _, text = rest.partition(" ")
		out.append(["waitlog" if cmd == "wait_log" else "waitlog_any", re.escape(text),
				int(ms) / 1000])
	elif cmd in ("frames", "sync"):
		out.append([cmd, int(rest)])
	elif cmd == "screenshot":
		out.append(["shot", rest])
	elif cmd == "click":
		out.append(["click"] + shlex.split(rest))
	else:
		sys.exit("no page's step for: " + line)
json.dump(out, sys.stdout)
PY
	# Registered as the admin by the setup code (kit_cam_min_move_check's)
	python3 -I - "$t/body.json" > "$t/steps.json" <<'PY'
import json, sys
head = [
	["nav", "${URL}"],
	["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
	["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000],
	["selall"], ["frames", 2], ["type", "webboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "${SETUP_CODE}"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Enter"], ["waitlog", "Joined as webboss", 30],
	["waitlog_any", "server window: the page ntfy", 30], ["frames", 3],
	["click", "Button", "Don't add"], ["frames", 3],
	["waitlog", "player physics enabled", 120],
	["waitlog_any", "kit editor: edit rights: yes", 10],
	["event", "kit_edit {\"op\": \"mode\", \"on\": true}"],
	["waitlog_any", "kit editor: edit mode on", 10],
	["event", "kit_edit {\"op\": \"stop\"}"],
	["waitlog", "kit editor: the server is Ended", 10],
]
json.dump(head + json.load(open(sys.argv[1])), sys.stdout)
PY
	WEB_DRIVE_VIEWPORT=1024x700@1 "$here/util/web_drive.sh" chrome workbench \
		"$t/steps.json" "$t/out" > "$t/drive.txt" 2>&1 ||
		fail "the web drive ($(tail -2 "$t/drive.txt"), $t/out)"
	c=$t/out/page.log
else
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
		cat "$t/body.cmds"
		echo quit
	} > "$t/boss.cmds"
	start_server "$t/srv.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
		fail "the server did not come up ($t/srv.log)"
	CHECK_PIDS+=($SERVER_PID)
	wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
	code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
	[ -n "$code" ] || fail "no setup code ($t/srv.log)"
	BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
		run_client 60 "$t/boss.log" timeout 240 bin/buildat -C "$t/client_cache" \
			-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
			-c @"$t/boss.cmds" || fail "the client failed ($t/boss.log, $t/srv.log)"
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
	c=$t/boss.log
fi
grep -a "kit editor: symmetry \|kit editor: to copy\|^  Copy " "$c" | sed 's/^.*kit editor: /  /'
grep -aA1 "kit editor: to copy 8's source 6" "$c" | grep -aq "kit editor: selected 6" ||
	fail "Go to source did not select 6 ($c)"
grep -aqF "  Copy 9 of 7 (slice 1): text = A copy of its own" "$c" ||
	fail "the override not listed ($c)"
for p in sym_plan sym_3d sym_copy sym_inspector; do
	[ -s "$t/$p.png" ] || fail "no screenshot $p ($t)"
done
echo "PASS: symmetry view${WEB:+ (web)}: seams and the shade, a copy read-only with the way to its source, the overrides and parity listed"
# vim: set noet ts=4 sw=4:
