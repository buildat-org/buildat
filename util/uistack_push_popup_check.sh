#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~15 s, more with a cold module cache (2026-11-07)
# covers: client/core/uistack/init.lua
# A screen pushed over an open dropdown ([UISTACK_PUSH_POPUP]): the push only
# hides the old top, and the popup is on the UI's root. The popup left open
# stayed modal, so the dialog's Ok could not be clicked. Nothing in the tree
# pushes on its own with a popup open, so a small app does it on an event.
#
#   util/uistack_push_popup_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp uistack_push_popup; t=$CHECK_TMP
cd "$here/Build"
mkdir -p "$t/app/main/client_lua"
cat > "$t/app/main/meta.json" <<'EOF'
{"engine_api": 2, "kind": "check", "disable_cpp": true, "client_main": "init.lua",
 "dependencies": [{"module": "network"}, {"module": "client_lua"}, {"module": "client_data"}]}
EOF
cat > "$t/app/main/client_lua/init.lua" <<'EOF'
local log = buildat.Logger("push_popup")
local magic = require("buildat/extension/urho3d")
local uistack = require("buildat/extension/uistack")
local ui_utils = require("buildat/extension/ui_utils")
local root = uistack.main:push({desc = "under"})
ui_utils.dropdown(root, {"one", "two", "three"}, "one", function() end)
magic.SubscribeToEvent("command_seq:push", function()
	ui_utils.show_message_dialog("pushed", function()
		log:info("push_popup: the dialog closed")
	end)
end)
log:info("push_popup: ready")
EOF
cat > "$t/push.cmds" <<EOF
wait_log_any 60000 push_popup: ready
frames 5
click DropDownList "▼"
wait_log 5000 open
event push
wait_log 5000 closed
frames 5
screenshot $t/pushed.png
click Button "Ok"
wait_log 5000 push_popup: the dialog closed
EOF
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m "$t/app" -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
run_client 60 "$t/push.log" timeout 120 bin/buildat -C "$t/client_cache" \
	-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
	-c @"$t/push.cmds" || fail "a push over an open dropdown ($t/push.log, $t/srv.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
echo "PASS: a push closes an open dropdown, and the new screen's button takes a click"
