#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~15 s, more with a cold module cache (2026-11-09)
# covers: 3rdparty/Urho3D/Source/Urho3D/UI/UIElement.cpp
# An element removed while a DropDownList under it has its popup open
# ([UI_DROPDOWN_REMOVE_CRASH]): the client crashed (SIGSEGV in
# ~DropDownList -> Menu::ShowPopup -> UI::SetModalElement). Nothing in the
# tree removes a box with a dropdown open on its own, so a small app does
# it on an event: the client stays up, the popup is gone (a click on the
# second dropdown opens it).
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
mkdir -p "$t/app/main/client_lua"
cat > "$t/app/main/meta.json" <<'EOF'
{"engine_api": 2, "kind": "check", "disable_cpp": true, "client_main": "init.lua",
 "dependencies": [{"module": "network"}, {"module": "client_lua"}, {"module": "client_data"}]}
EOF
cat > "$t/app/main/client_lua/init.lua" <<'EOF'
local log = buildat.Logger("drop_remove")
local magic = require("buildat/extension/urho3d")
local uistack = require("buildat/extension/uistack")
local ui_utils = require("buildat/extension/ui_utils")
local root = uistack.main:push({desc = "under"})
root:SetLayout(magic.LM_VERTICAL, 20, magic.IntRect(0, 0, 0, 0))
local box = root:CreateChild("UIElement")
box:SetLayout(magic.LM_VERTICAL, 0, magic.IntRect(0, 0, 0, 0))
ui_utils.dropdown(box, {"one", "two", "three"}, "one", function() end)
-- (the one left after: the first, by its place, at 1024x700)
ui_utils.dropdown(root, {"four", "five"}, "four", function() end)
magic.SubscribeToEvent("command_seq:remove", function()
	box:Remove()
	box = nil
	log:info("drop_remove: removed")
end)
log:info("drop_remove: ready")
EOF
cat > "$t/remove.cmds" <<EOF
wait_log_any 60000 drop_remove: ready
frames 5
click DropDownList "▼" 511 327
wait_log 5000 open
event remove
wait_log_any 5000 drop_remove: removed
frames 10
screenshot $t/removed.png
click DropDownList "▼"
wait_log 5000 open
frames 5
quit
EOF
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m "$t/app" -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
run_client 60 "$t/remove.log" timeout 120 bin/buildat -C "$t/client_cache" \
	-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
	-c @"$t/remove.cmds" || fail "a box removed with its dropdown open ($t/remove.log, $t/srv.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
echo "PASS: a box removed with its dropdown's popup open: the client stays up, the popup goes and the next dropdown opens; screenshot $t/removed.png"
