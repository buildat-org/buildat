#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-11)
# covers: builtin/accounts/client_lua/accounts.lua
# [KEEP_ON_TOP]: "Keep me logged in" is the login window's first item and
# is kept when toggled. A public vanilla server, a native client through
# the launcher's connect screen: the page's items (the keyboard's order,
# from the log) start with the toggle; toggled and the client closed, the
# next login page reads it on.
# simplified: no Starport ID login here (its keep was already sent as
# the toggle is; util/starport_id_join_check.sh covers that way in)
#   util/keep_on_top_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp keep_on_top; t=$CHECK_TMP
trap check_cleanup EXIT
start_server "$t/srv.log" "STATUS Listening" 60 auto "$here/Build/bin/buildat_server" \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/u" -C "$t/c" -l 3 || fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
# The 300 ms delays are the screen laid out after its line, and a click's
# focus taken before the keys
login(){ # log, then the commands after the login page is up
	{ printf 'wait_log_any 30000 Join a Buildat server: shown\ndelay 300\nclick LineEdit "29500"\ndelay 300\nkeypress End\n'
		printf 'keypress Backspace\n%.0s' 1 2 3 4 5
		printf 'text %s\ndelay 300\nclick Button "Join"\n' $SERVER_PORT
		printf 'wait_log 30000 Keep me logged in|\ndelay 1000\n'
		cat; printf 'quit\n'; } > "$t/cmds"
	timeout 120 "$here/Build/bin/buildat" -o launch_ui=launch_menu \
		-a extension/launch_menu/connect -D "$t/cl" -C "$t/cc" -w 900x700 -u 1 -l 4 \
		-o sound_mute=1 -c @"$t/cmds" > "$1" 2>&1
}
items(){ grep -a "keyboard_page: .*Keep me logged in" "$1" | tail -1 | sed 's/.*keyboard_page: //'; }
printf 'click Button "[ ] Keep me logged in"\ndelay 500\n' | login "$t/1.log" ||
	fail "the drive ($t/1.log): $(grep -a "Command sequence failed" "$t/1.log" | tail -1)"
echo "first: $(items "$t/1.log")"
items "$t/1.log" | grep -q '^\[ \] Keep me logged in|\*LineEdit|' ||
	fail "the toggle is not the first item ($t/1.log)"
printf 'screenshot %s\n' "$t/2.png" | login "$t/2.log" ||
	fail "the drive ($t/2.log): $(grep -a "Command sequence failed" "$t/2.log" | tail -1)"
echo "again: $(items "$t/2.log")"
items "$t/2.log" | grep -q '^\[x\] Keep me logged in|' || fail "not kept ($t/2.log)"
echo "PASS: Keep me logged in first on the login page, and kept when toggled"
