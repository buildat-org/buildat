#!/bin/bash
# tier: quick
# cost: 40s (a floorplanner server and a client, 2026-10-02)
# covers: extensions/ui_utils/** builtin/accounts/client_lua/** apps/floorplanner/main/client_lua/init.lua
# [MENU_KEYS]: **every menu by the keyboard**. A client joins a local
# floorplanner and goes through its pages with no mouse: the plan picker,
# its menu, My account and Two-step login -- by the arrows, Enter
# pressing; no label has a bracketed letter ([NO_LETTER_KEYS]). What it
# reads is the log ui_utils keeps at -l 4: each page's items, and where
# each arrow went.
#
#   extensions/ui_utils/check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/menu_keys"
rm -rf "$out"; mkdir -p "$out"
cd "$here/Build"
start_server "$out/srv.log" "setup code" 60 29881 \
	bin/buildat_server -m ../apps/floorplanner -D "$out/srv" -l 3 ||
	fail "the server did not start ($out/srv.log)"
port=$SERVER_PORT; srv=$SERVER_PID
trap 'kill -INT "$srv" 2>/dev/null' EXIT
code=$(grep -ao "setup code [A-Z0-9]*" "$out/srv.log" | tail -1 | awk '{print $3}')
# Up from the picker's name field wraps to its last button, Menu...; in
# the menu Down twice to My account..., which is the Server window: Right
# into the page, Down to Two-step login... Each arrow waits for ui_utils's
# "keyboard: to" line (-l 4), each Enter for the page it opens; the half
# seconds are a page's focus put in the frames after its line.
cat > "$out/cmds.txt" <<CMDS
wait_log_any 60000 Plan picker: 
delay 500
keypress up
wait_log 5000 keyboard: to Menu...
keypress return
wait_log 5000 The plan picker's menu shown
delay 500
keypress down
keypress down
wait_log 5000 keyboard: to My account...
keypress return
wait_log 5000 server window: the page
delay 500
keypress right
keypress down
wait_log 5000 keyboard: to Two-step login...
keypress return
delay 500
quit
CMDS
BUILDAT_FP_CREATE=1 BUILDAT_FP_NAME=op BUILDAT_FP_PASSWORD=pw123456 BUILDAT_FP_CODE=$code \
	timeout 90 bin/buildat -o launch_ui=launch_menu -s localhost:$port -D "$out/cli" -w 800x500 -l 4 \
	-c @"$out/cmds.txt" > "$out/cli.log" 2>&1 ||
	fail "the drive ($out/cli.log): $(grep -ao 'Command sequence failed.*' "$out/cli.log" | head -1)"
grep -a "ui_utils: keyboard" "$out/cli.log" | sed 's/.*ui_utils: //' > "$out/keys.txt"
cat "$out/keys.txt"
fail=0
expect() {
	if ! grep -q "$1" "$out/keys.txt"; then
		echo "FAIL: no \"$1\" ($2)"; fail=1
	fi
}
expect "keyboard: to Menu..." "Up wraps from the field to the last button"
expect "keyboard: to My account..." "Down walks the menu"
expect "keyboard: to Two-step login..." "Right into the Server window's page, then Down"
if grep -q "\[[A-Za-z]\]" "$out/keys.txt"; then
	echo "FAIL: a label with a bracketed letter: $(grep "\[[A-Za-z]\]" "$out/keys.txt" | head -1)"
	fail=1
fi
if grep -aq "Crash: SIG\|a button outside its menu" "$out/cli.log"; then
	echo "FAIL: $(grep -a "Crash: SIG\|a button outside" "$out/cli.log" | head -1)"
	fail=1
fi
[ $fail = 0 ] && echo "PASS: the pages are reached and pressed by the keyboard alone"
exit $fail
# vim: set noet ts=4 sw=4:
