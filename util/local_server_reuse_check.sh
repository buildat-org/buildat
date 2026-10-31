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
# The world the drive makes (the list holds whatever devtest worlds the
# user path has, none in a fresh one), gone before and after
w=$BUILDAT_USER_PATH/apps/vanilla/saves/world_lsr
rm -rf "$w"
trap 'rm -rf "$t" "$w"' EXIT
fail(){ echo "FAIL: $*"; cp "$t/log" /tmp/local_server_reuse.log; exit 1; }

# Apps, then "devt" typed (by text: a keypress types nothing) searches
# devtest's tile, which launches vanilla with menu=worlds,
# luanti_game=devtest. Home's line is "launch_menu: <n> rows in <t> ms",
# a list's "launch_menu: <kind>, <n> rows, by ...". The delays of 2 s at
# most: the screen a line says is up laid out in the frames after it, a
# selection's panel laid out again once its info fills it (a click at
# once hit its "server performance" for Play)
launch='click Button "Apps"
wait_log 10000 rows, by
delay 300
text devt
wait_log 10000 rows for "devt", by
delay 300
keypress Return
wait_log 60000 handle_packet(): main:menu
delay 2000'
# A new world, "world" with "_lsr" typed after it in the name field that
# has the focus, no damage (a fall death makes Escape a respawn), created
# and played; in the world, Escape and the pause menu's "Leave the game"
cat > "$t/cmds" <<C
wait_log_any 20000 rows in
delay 800
$launch
keypress Escape
wait_log 20000 rows in
delay 1500
$launch
click Button "New world..."
delay 500
text _lsr
click Button "[x] Enable damage"
delay 300
click Button "Create and play"
wait_log 150000 load: the world is in
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
