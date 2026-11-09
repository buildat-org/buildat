#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-09)
# covers: builtin/kit/kit.cpp builtin/kit/types/ui_input.lua builtin/kit/client_lua/ui.lua
# [KIT_TEXT_INPUT] A kit/ui_input on Workbench: kitboss (the admin) places a
# kit/ui_panel 3 "Name", in it 4 kit/ui_input "Name:" (max_length 8) and
# 5 kit/ui_text "Said: {value}", 4 entered -> 5 value; in play he clicks
# the field, types "héllo" and Enter: the text says it, and the field gives
# the keys back. A longer line sent as entered (the field itself takes
# no more than 8) is cut at 8 characters, not bytes; one sent for 5 (no
# input) is refused. On the web (headless Chrome)
# a player with an account types into the same field through the page's
# text input: the text says theirs.
#   util/kit_text_input_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_text_input; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
n=0
edit() # <op json>: an edit and its answer
{
	n=$((n + 1))
	printf 'event kit_edit %s\nwait_log 10000 entities, %d to undo\n' "$1" "$n"
}
place() { edit "{\"op\": \"place\", \"type\": \"$1\", \"pos\": [$2, 1, 6]}"; }
set_p() { edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"; }
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
EOF
	place kit/ui_panel 0
	set_p 3 title '"Name"'
	set_p 3 layout '"column"'
	set_p 3 shown true
	place kit/ui_input 1
	edit '{"op": "parent", "id": 4, "parent": 3}'
	set_p 4 label '"Name:"'
	set_p 4 max_length 8
	place kit/ui_text 2
	edit '{"op": "parent", "id": 5, "parent": 3}'
	set_p 5 text '"Said: {value}"'
	edit '{"op": "link", "id": 4, "comp": 0, "output": "entered", "to": 5, "input": "value"}'
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log_any 10000 kit: ui 4 input
frames 10
click LineEdit "kit input 4"
delay 300
text héllo
delay 300
keypress Return
wait_log_any 10000 kit: ui input 4 entered (6 bytes)
wait_log_any 10000 : "Said: héllo"
frames 3
event kit_ui_text 4 abcdéfghij
wait_log_any 10000 : "Said: abcdéfgh"
event kit_ui_text 5 sneaky
frames 10
screenshot @T@/native.png
sync 3000
quit
EOF
} > "$t/kitboss.cmds"
sed -i "s|@T@|$t|g" "$t/kitboss.cmds"
web=""
if command -v "${CHROME:-google-chrome}" > /dev/null && [ -f "$here/web/buildat.wasm" ]; then
	web="-W $here/web"
fi
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 $web \
	--sim-rate "$CHECK_RATE" || fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" \
	run_client 60 "$t/kitboss.log" timeout 180 bin/buildat -C "$t/client_cache" \
	-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 -c @"$t/kitboss.cmds" ||
	fail "kitboss's client failed ($t/kitboss.log, $t/srv.log)"
if [ -n "$web" ]; then
	# An account made by the keys kit_ui_components_check's web part uses
	cat > "$t/web.json" <<'J'
[
 ["nav", "${URL}"],
 ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000],
 ["selall"], ["frames", 2], ["type", "webby"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["key", "Enter"], ["waitlog", "Joined as webby", 30],
 ["waitlog", "player physics enabled", 120],
 ["waitlog_any", "kit: ui 4 input", 30], ["frames", 10],
 ["click", "LineEdit", "kit input 4"], ["frames", 5],
 ["type", "from web"], ["frames", 3], ["key", "Enter"],
 ["waitlog", "kit: ui input 4 entered", 10],
 ["waitlog", ": \"Said: from web\"", 10],
 ["frames", 5], ["shot", "${OUT}/web.png"], ["sync", 3000]
]
J
	WEB_DRIVE_VIEWPORT=1000x600@1 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
		"$here/util/web_drive.sh" chrome workbench "$t/web.json" "$t/drive" \
		> "$t/drive.txt" 2>&1 || fail "the web drive ($(tail -2 "$t/drive.txt"), $t/drive)"
fi
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
b=$t/kitboss.log s=$t/srv.log
grep -aqP "kit/ui_input 4: entered by kitboss: h\\S{1,2}llo$" "$s" ||
	fail "the server did not take kitboss's typed line ($s)"
grep -aqP "kit/ui_input 4: entered by kitboss: abcd\\S{1,2}fgh$" "$s" ||
	fail "the input did not cut the line at 8 characters ($s)"
grep -aq 'A UI text of 5 sneaky from peer .* refused: no such input' "$s" ||
	fail "a line for a text not refused ($s)"
grep -aq "OFF SCREEN" "$b" && fail "a UI component off the screen ($b)"
echo "ok: natively: a typed line reaches the linked text, cut at max_length; a line for no input refused"
if [ -z "$web" ]; then
	echo "PASS: a text input natively (the web skipped: no Chrome or web/); screenshot $t/native.png"
	exit 0
fi
grep -aq "UI input 4 entered by webby" "$s" ||
	fail "the web player's line did not reach the server ($s)"
echo "PASS: a text input natively and on the web; screenshots $t/native.png $t/drive/web.png"
