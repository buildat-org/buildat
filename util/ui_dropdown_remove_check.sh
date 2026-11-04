#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~30 s, more with a cold module cache (2026-11-04)
# covers: 3rdparty/Urho3D/Source/Urho3D/UI/UIElement.cpp
# drives: builtin/kit/client_lua/editor.lua
# An element removed while a DropDownList under it has its popup open
# ([UI_DROPDOWN_REMOVE_CRASH]): the client crashed (SIGSEGV in
# ~DropDownList -> Menu::ShowPopup -> UI::SetModalElement). Kit's
# inspector on Workbench, the admin in edit mode, a kit/door (4) selected
# and one of its dropdowns open:
#   - another entity selected: the inspector is drawn again;
#   - the door deleted: the inspector goes;
# both close the popup (it stayed on the screen, over the next
# dropdown), the client stays up and the next dropdown opens.
#
#   util/ui_dropdown_remove_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp ui_dropdown_remove; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_JOIN_PASSWORD=checkpass12 \
	BUILDAT_JOIN_NAME=kitboss
# The door's first dropdown: the inspector's fourth row at 1024x700
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
event kit_edit {"op": "place", "type": "kit/door", "pos": [3, 1, 3]}
wait_log 10000 entities, 2 to undo
frames 5
click Button "Entities"
frames 3
event kit_select 4
frames 5
click DropDownList "▼" 965 178
delay 500
event kit_select 3
frames 10
event kit_select 4
frames 5
click DropDownList "▼" 965 178
delay 500
event kit_edit {"op": "delete", "id": 4}
wait_log 10000 entities, 3 to undo
frames 10
click Button "Entities"
frames 5
event kit_select 3
frames 5
click DropDownList "▼" 965 178
delay 500
keypress Escape
frames 5
EOF
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
# Each removal's popup left on the screen covered the next dropdown's
# click (the client failed there)
[ "$(grep -acE "ui_utils: dropdown_[0-9]+ open" "$t/boss.log")" -ge 3 ] ||
	fail "a dropdown after a removal did not open ($t/boss.log)"
echo "PASS: an element removed with an open DropDownList under it: the popup closes, the client stays up"
