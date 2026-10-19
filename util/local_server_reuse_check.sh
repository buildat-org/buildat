#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-06)
# covers: src/client/app.cpp extensions/launch_menu/screens.lua apps/vanilla/main/main.cpp
# [SERVER_REUSE]: a vanilla server that holds no world stays when its menu is
# left, and the next launch of vanilla connects to it (launch:reusable) with
# that launch's params (launch:untrusted: devtest's world list, as -u would
# have given). A world opened there makes leaving stop the server again.
# Needs the devtest game in the checks' user path (util/check_lib.sh).
#   util/local_server_reuse_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; cp "$t/log" /tmp/local_server_reuse.log; exit 1; }

# Apps, then "devt" typed (by text: a keypress types nothing) searches
# devtest's tile, which launches vanilla with menu=worlds,
# luanti_game=devtest. Home's line is "launch_menu: <n> rows in <t> ms",
# a list's "launch_menu: <kind>, <n> rows, by ...". The delays of 2 s at
# most: the screen a line says is up laid out in the frames after it, a
# selection's panel laid out again once its info fills it (a click at
# once hit its "server performance" for Play)
launch='mouse_pos 300 374
mouse_click left
wait_log 10000 rows, by
delay 300
text devt
wait_log 10000 rows for "devt", by
delay 300
keypress Return
wait_log 60000 handle_packet(): main:menu
delay 2000'
# The world list's first world, then Play; in the world, Escape and the
# pause menu's "Leave the game" (positions at 800x600, from a scan)
cat > "$t/cmds" <<C
wait_log_any 20000 rows in
delay 800
$launch
keypress Escape
wait_log 20000 rows in
delay 1500
$launch
mouse_pos 270 156
mouse_click left
wait_log 10000 menu: the world
delay 500
click Button "Play"
wait_log 90000 the server put the player
wait_log 60000 scene, 0 undrawn within 2
keypress Escape
wait_log 5000 pause: the menu shown
delay 500
click Button "Leave the game"
wait_log 20000 Local server stopped
quit
C
timeout 240 Build/bin/buildat -o launch_ui=launch_menu -w 800x600 -l 4 \
	-o sound_mute=1 -c @"$t/cmds" > "$t/log" 2>&1 ||
	fail "the drive: $(grep -a "Command sequence failed\|an error the drive" "$t/log" | tail -1)"
n(){ grep -ac "$1" "$t/log"; }
[ "$(n 'Starting local server')" = 1 ] || fail "$(n 'Starting local server') starts, not 1"
[ "$(n 'Reusing the local server')" = 1 ] || fail "the second launch did not reuse it"
[ "$(n 'Local server kept')" = 1 ] || fail "$(n 'Local server kept') keeps, not 1"
# main:menu comes only from the launch param, so the second one is the
# params reaching the reused server
[ "$(grep -ac "V __app   : handle_packet(): main:menu$" "$t/log")" = 2 ] || fail "the reused server did not get the launch"
grep -aq "the server put the player" "$t/log" || fail "no world from the reused server"
grep -aq "Local server stopped" "$t/log" || fail "leaving the world did not stop the server"
echo "PASS: a menu-only vanilla server is reused, and one with a world stops on leave"
