#!/bin/bash
# tier: full
# cost: ~40s (2026-10-07)
# covers: extensions/luanti_client/settings.lua show_pause, init.lua leave()
# [LUANTI_PAUSE]: luanti_client's pause menu is a screen on the UI stack.
# On a local devtest Luanti server: Escape opens it, the view range is
# picked from its dropdown (120 -> 200, saved), Escape closes it, and a
# quit with it open takes it down with the session (leave() popped the session's root
# from under it before: "Wrong current_top_root").
# Needs luanti in PATH and devtest in the desk's games.
#   util/luanti_pause_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
G="$BUILDAT_USER_PATH/shared/vanilla/games/devtest"
[ -d "$G" ] || { echo "SKIP: no devtest"; exit 0; }
command -v luanti > /dev/null || { echo "SKIP: no luanti"; exit 0; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
t=$(mktemp -d)
s=
trap '[ -n "$s" ] && kill $s 2>/dev/null; [ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "${t:?}"' EXIT
fail(){ echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
mkdir -p "$t/games" "$t/w"
cp -r "$G" "$t/games/"
printf 'gameid = devtest\nbackend = sqlite3\n' > "$t/w/world.mt"
P=30178
LUANTI_GAME_PATH="$t/games" MINETEST_GAME_PATH="$t/games" \
	luanti --server --world "$t/w" --port $P > "$t/srv.log" 2>&1 &
s=$!
for _ in $(seq 150); do
	grep -q "listening on" "$t/srv.log" && break
	kill -0 $s 2>/dev/null || fail "server died ($(tail -3 "$t/srv.log"))"
	sleep 0.2
done
grep -q "listening on" "$t/srv.log" || fail "the server did not come up ($t/srv.log)"
# The address allowed already, as a player's Allow leaves it
mkdir -p "$t/cl"
now=$(date +%s)
echo "\"true\",\"udp://127.0.0.1:$P\",\"\",\"$now\",\"$now\",\"\",\"\",\"\"" \
	> "$t/cl/network_addresses.csv"
# Positions at 800x600. The dropdown's popup waited for by ui_utils'
# "dropdown_<n> open"; its Down and Return a few frames apart, as pressed
cat > "$t/cmds" <<C
wait_log 60000 voxel types have their own textures
wait_log_any 30000 loading: the world is in
delay 500
keypress Escape
wait_log 5000 pause: the menu shown
delay 300
mouse_pos 380 343
mouse_click left
wait_log 5000 dropdown_
# the popup's list takes keys some frames after it opens (a Down 7 ms
# after the line was lost)
delay 500
keypress Down
# the keys' pacing: the list reads the Down a frame before the Return
delay 200
keypress Return
wait_log 5000 view range 200, saved
event scan
keypress Escape
wait_log 5000 pause: closed
delay 300
event scan
keypress Escape
wait_log 5000 pause: the menu shown
quit
C
cd "$here/Build"
BUILDAT_LUANTI_ADDRESS=127.0.0.1:$P BUILDAT_LUANTI_CONNECT=1 BUILDAT_LUANTI_NAME=pausecheck \
	timeout 120 bin/buildat -m luanti_client -D "$t/cl" -w 800x600 -l 3 \
	-o sound_mute=1 -c @"$t/cmds" > "$t/cl.log" 2>&1 ||
	fail "the drive ($t/cl.log): $(grep -a "Command sequence failed" "$t/cl.log" | tail -1)"
grep -aq 'menu "ui_stack_[0-9_.]*: luanti_client pause"' "$t/cl.log" ||
	fail "no pause menu after Escape"
grep -aq '"view_range" : 200' "$t/cl/extensions/luanti_client/settings.json" 2>/dev/null ||
	fail "the view range was not picked"
grep -a 'scan scan: menu' "$t/cl.log" | tail -1 | grep -q '"ui_stack_[0-9_.]*: luanti_client"' ||
	fail "Escape did not close the pause menu"
grep -aq "Wrong current_top_root\|Runtime error" "$t/cl.log" &&
	fail "$(grep -a "Wrong current_top_root\|Runtime error" "$t/cl.log" | head -2)"
echo "PASS: the pause menu opens, picks a view range, closes, and goes with a quit"
