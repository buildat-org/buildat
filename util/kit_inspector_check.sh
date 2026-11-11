#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~30 s, more with a cold module cache (2026-10-31)
# covers: builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua extensions/ui_utils/init.lua
# drives: builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua
# Kit's inspector on Workbench, the admin (kitboss, by the setup code) in
# edit mode with a kit/controls selected (user's playtest, 2026-10-31):
#   - its parameters (more than a 700 px screen holds since [KIT_FEEDBACK_EFFECTS])
#     scroll: the wheel over the labels brings Apply into view, where it is
#     clicked; the body stays near a row's height a parameter (settings_form drew
#     an empty warning line under every field);
#   - a camera picked and not applied stays picked when the inspector is
#     drawn again by an edit's state: the dropdown's Down from "chase"
#     goes to top_down, which Apply sets (it went back to first_person,
#     whose Down is chase);
#   - the keys in an open dropdown are its alone: with the kit/door (4)
#     selected by Tab and one of its dropdowns open, Down and Up do not
#     move it too ([KIT_DROPDOWN_ARROWS_MOVE]);
#   - [KIT_INSPECTOR_REBUILD] the door's placing leaves the inspector as it
#     is (kept over its state), Apply's edit of 3 draws it again;
#   - [KIT_FREE_ROTATION_LEFTOVERS] a kit/part under a turned one: its position
#     fields (composed: long) show at most three decimals, from their start
#     (x -7.4055 showed "4055").
#   - web: [KIT_PHONE_EDITING] in headless Chrome as a phone in portrait
#     (412x915, touch), kit/terrain's inspector scrolled to its end and its
#     width field tapped, a stand-in keyboard (buildatKeyboard.test) of 380:
#     the field and its Apply above the keyboard, the builders' box not under
#     the inspector, Apply reached; the UI scale logged no new value while
#     the field is focused, nor as Tools and the Inspector are swapped.
#
#   util/kit_inspector_check.sh [web]
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if [ "${1:-}" = web ]; then
	command -v "${CHROME:-google-chrome}" > /dev/null && [ -f "$here/web/buildat.wasm" ] ||
		skip "no Chrome or web/"
	check_tmp kit_inspector_web; t=$CHECK_TMP
	cat > "$t/phone.json" <<'J'
[
	["nav", "${URL}?pref=kit_editor_font=100"],
	["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
	["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000],
	["selall"], ["frames", 2], ["type", "webboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "${SETUP_CODE}"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Enter"], ["waitlog", "Joined as webboss", 30],
	["waitlog_any", "server window: the page ntfy", 30], ["frames", 3],
	["tap", "Button", "Don't add"], ["frames", 3],
	["waitlog_any", "world_menu: the list shown, 0 worlds", 30], ["frames", 3],
	["tap", "Button", "New project..."],
	["waitlog", "world_menu: the name screen shown", 10], ["frames", 3],
	["tap", "Button", "Create"],
	["waitlog", "player physics enabled", 120],
	["waitlog_any", "kit editor: edit rights: yes", 10], ["frames", 5],
	["key", "F6"], ["waitlog", "kit editor: state: 1 entities", 20], ["frames", 5],
	["event", "kit_edit {\"op\": \"place\", \"type\": \"kit/terrain\", \"pos\": [0, 1, 0]}"],
	["waitlog", "kit editor: state: 2 entities", 20],
	["event", "kit_select 3"], ["waitlog", "kit editor: selected 3", 10], ["frames", 5],
	["tap", "Button", "Inspector"], ["frames", 10], ["wait", 800],
	["event", "kit_ui_where open"], ["frames", 3],
	["tap", "Button", "Tools"], ["frames", 10],
	["tap", "Button", "Inspector"], ["frames", 10],
	["shot", "${OUT}/inspector.png"],
	["drag", 200, 700, 200, 150, "touch"], ["frames", 5],
	["drag", 200, 700, 200, 150, "touch"], ["frames", 5],
	["tap", "LineEdit", "64", 300, 760], ["frames", 5],
	["eval", "buildatKeyboard.test = 380, 'keyboard'"],
	["waitlog", "kit editor: typing in the inspector", 10],
	["type", "8"], ["frames", 5],
	["shot", "${OUT}/typing.png"],
	["event", "kit_ui_where typing"], ["frames", 3],
	["tap", "Button", "Apply"], ["waitlog", "entities, 2 to undo", 10],
	["eval", "buildatKeyboard.test = null, 'no keyboard'"], ["frames", 5]
]
J
	TOUCH=1 WEB_DRIVE_VIEWPORT=412x915@1 "$here/util/web_drive.sh" chrome workbench "$t/phone.json" "$t/phone" ||
		fail "the web drive as a phone ($t/phone)"
	python3 -I - "$t/phone/page.log" <<'PY' || fail "as a phone: see above ($t/phone/typing.png, $t/phone/page.log)"
import re, sys
lines = open(sys.argv[1], errors="replace").read().splitlines()
def at(s):
    return next(i for i, l in enumerate(lines) if s in l)
# The scale settles in edit mode: at most 2 changes, and back within 0.03
# of where it was. Not "never changes": the root's FitHold is gone, and the
# builders' box and the inspector still flip it once each until their
# compact layout ([KIT_PHONE_EDITING] stage 1)
def scale(l):
    m = re.search(r"UI scale ([\d.]+) \(", l)
    return m and float(m[1])
on = at("kit editor: edit mode on")
was = [scale(l) for l in lines[:on] if scale(l)][-1]
scales = [scale(l) for l in lines[on:] if scale(l)]
assert len(scales) <= 2 and abs((scales or [was])[-1] - was) <= 0.03, \
    f"the UI scale did not settle in edit mode: x{was} then {scales}"
m = re.search(r"typing in the inspector: the field (\d+) to (\d+), its Apply (\d+) to (\d+), "
        r"the view (\d+) to (\d+), the keyboard from (\d+)", "\n".join(lines))
assert m, "no typing line"
f0, f1, a0, a1, v0, v1, kb = map(int, m.groups())
assert v0 <= f0 and f1 <= v1 <= kb, f"the field {f0}-{f1} out of the view {v0}-{v1} or under the keyboard at {kb}"
assert v0 <= a0 and a1 <= v1, f"Apply {a0}-{a1} out of the view {v0}-{v1}"
w = re.search(r"the windows at (.*) \(typing\)", "\n".join(lines))[1]
r = dict((k, list(map(int, v.split()))) for k, v in re.findall(r"(\w+) (\d+ \d+ \d+ \d+)", w))
ins = r["inspector"]
assert "people" not in r or r["people"][1] >= ins[1] + ins[3], f"the builders' box over the inspector: {w}"
print(f"ok: the field {f0}-{f1}, Apply {a0}-{a1}, the keyboard from {kb}; {w}")
PY
	echo "PASS: Kit's inspector as a phone on the web: the typed field and its Apply above the keyboard, clear of the builders' box, the UI scale held ($t/phone/typing.png)"
	exit 0
fi
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_inspector; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_JOIN_PASSWORD=checkpass12 \
	BUILDAT_JOIN_NAME=kitboss
# The camera's dropdown: the inspector's fourth row at 1024x700
cat > "$t/boss.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
event kit_edit {"op": "place", "type": "kit/controls", "pos": [0, 1, 0]}
wait_log 10000 entities, 1 to undo
frames 5
click Button "Entities"
frames 3
click Button "Select"
wait_log 5000 kit editor: selected 3
frames 5
click DropDownList "▼" 965 178
delay 500
keypress Down
keypress Return
wait_log 5000 kit editor: 3/1 camera = chase
event kit_edit {"op": "place", "type": "kit/door", "pos": [3, 1, 3]}
wait_log 10000 entities, 2 to undo
frames 5
click DropDownList "▼" 965 178
delay 500
keypress Down
keypress Return
wait_log 5000 kit editor: 3/1 camera =
frames 3
screenshot @T@/picked.png
mouse_pos 780 400
frames 2
mouse_wheel -1
frames 2
mouse_wheel -1
frames 2
mouse_wheel -1
frames 2
mouse_wheel -1
frames 2
mouse_wheel -1
frames 2
mouse_wheel -1
frames 3
screenshot @T@/scrolled.png
click Button "Apply"
wait_log 10000 entities, 3 to undo
keypress Tab
wait_log 5000 kit editor: selected 4
frames 5
click DropDownList "▼" 965 178
delay 500
keypress Down
keypress Up
keypress Escape
frames 5
event kit_edit {"op": "place", "type": "kit/part", "pos": [0, 1, 6]}
wait_log 10000 entities, 4 to undo
event kit_edit {"op": "move", "id": 5, "pos": [0, 1, 6], "yaw": 37, "pitch": 11}
wait_log 10000 entities, 5 to undo
event kit_edit {"op": "place", "type": "kit/part", "pos": [2, 2, 8], "parent": 5}
wait_log 10000 entities, 6 to undo
event kit_select 6
wait_log_any 5000 kit editor: selected 6
frames 5
event kit_ui_where long
wait_log_any 5000 kit editor: the field position z shows
screenshot @T@/long.png
keypress F6
wait_log_any 10000 kit: controls: camera
EOF
sed -i "s|@T@|$t|g" "$t/boss.cmds"
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	run_client 60 "$t/boss.log" timeout 120 bin/buildat -C "$t/client_cache" \
	-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
	-c @"$t/boss.cmds" || fail "the client failed ($t/boss.log, $t/srv.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
[ "$(grep -acE "ui_utils: dropdown_[0-9]+ open" "$t/boss.log")" -ge 3 ] ||
	fail "the door's dropdown did not open ($t/boss.log)"
# simplified: a fixed bound over today's 1162: room for a few more parameters,
# not for an empty line under each. Many more parameters raise it
tall=$(grep -aoP 'kit editor: the inspector \d+ of \K\d+(?= tall)' "$t/boss.log" | sort -n | tail -1)
[ "${tall:-9999}" -le 1400 ] ||
	fail "the inspector's body is ${tall:-not logged} tall: more than its rows take ($t/boss.log)"
# The state after an edit: kept or drawn again before the next state
kept_after() # <undo count>: 0 when the inspector was kept over that state
{
	awk -v u="entities, $1 to undo" 'BEGIN { r = 1 } index($0, u) { on = 1; next }
		on && /kit editor: state:/ { exit }
		on && /kit editor: the inspector kept over a state/ { r = 0; exit }
		END { exit r }' "$t/boss.log"
}
kept_after 2 || fail "placing the door drew the inspector again ($t/boss.log)"
kept_after 3 && fail "Apply's edit kept the inspector as it was ($t/boss.log)"
grep -aqF "An edit by kitboss: moved 4" "$t/srv.log" &&
	fail "a key in the open dropdown moved the selection too ($t/srv.log)"
# [KIT_FREE_ROTATION_LEFTOVERS] A long position rounded and shown from its start
fields=$(grep -aoP 'the field position \w shows .*' "$t/boss.log")
[ "$(grep -cP '"-?\d+(\.\d{1,3})?" scrolled 0$' <<<"$fields")" = 3 ] &&
	grep -qP '\.\d' <<<"$fields" ||
	fail "the position fields: $(tr '\n' ' ' <<<"$fields") ($t/long.png)"
got=$(grep -aoP 'kit: controls: camera \K\w+' "$t/boss.log" | tail -1)
[ "$got" = top_down ] ||
	fail "the camera is ${got:-not set}, not top_down: the pick did not stay ($t/picked.png)"
echo "PASS: Kit's inspector: kit/controls' parameters scroll to Apply; a pick not yet applied stays picked when the inspector is drawn again; a dropdown's keys move no selection; an unrelated edit keeps the inspector, one of the selected draws it again"
