#!/bin/bash
# tier: full
# cost: ~60s (2026-10-18)
# covers: src/client/web/index.html src/client/app_lua.h client/api.lua builtin/accounts/client_lua/accounts.lua
# [WEB_LEFT_DIALOG]: the web page after a leave with no launcher under the
# game. floorplanner in Firefox (util/web_drive.sh, the web client from
# web/): the first admin logs in by the setup code and logs out from the
# Server window's account page; the page says "You logged out." with a
# Reconnect button, and Reconnect reloads it to the login page.
# simplified: Leave the game's "You left the game." is the same path with
# leave()'s default reason, not driven
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/web_left.XXXXXX")
log=$out/drive.log
bash "$here/util/web_drive.sh" firefox floorplanner \
	"$here/util/web_left_dialog.json" "$out" > "$log" 2>&1 ||
	{ echo "FAIL: the drive ($log)"; exit 1; }
grep -q 'status: \\"You logged out\.\\\\n\\\\nReconnect\\"' "$log" &&
	grep -q '"buttons: Reconnect"' "$log" ||
	{ echo "FAIL: no \"You logged out.\" with Reconnect ($log)"; exit 1; }
rm -rf "$out"
echo "PASS: Log out on the web: \"You logged out.\" with Reconnect, which reloads to the login page"
