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
#     move it too ([KIT_DROPDOWN_ARROWS_MOVE]).
#
#   util/kit_inspector_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
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
grep -aqF "An edit by kitboss: moved 4" "$t/srv.log" &&
	fail "a key in the open dropdown moved the selection too ($t/srv.log)"
got=$(grep -aoP 'kit: controls: camera \K\w+' "$t/boss.log" | tail -1)
[ "$got" = top_down ] ||
	fail "the camera is ${got:-not set}, not top_down: the pick did not stay ($t/picked.png)"
echo "PASS: Kit's inspector: kit/controls' parameters scroll to Apply; a pick not yet applied stays picked when the inspector is drawn again; a dropdown's keys move no selection"
