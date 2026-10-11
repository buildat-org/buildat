#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-11)
# covers: apps/vanilla/main/main.cpp apps/vanilla/main/client_lua/join.lua apps/vanilla/main/client_lua/menu.lua
# [VANILLA_STOP]: an admin stops a public vanilla's world. A public server
# on the minimal game, run as the release runs it (exit 20: start again),
# the admin and a user in its world:
#   - the admin's pause menu, Worlds..., Stop the world...: the user's
#     chat says who stopped it; the user is back on a held page "Stopped
#     by an admin (admin)", which Escape leaves up; its chat sends a line
#     that arrives with no game running;
#   - the admin, back on the world menu, plays the world: the user is in
#     it again with no click.
# simplified: native only.
#   util/vanilla_stop_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp vanilla_stop; t=$CHECK_TMP
trap check_cleanup EXIT
d=$t/u
# The world, made by a start of the launcher's kind
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=w start_server "$t/w0.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" -C "$t/c" -l 3 || fail "the world ($t/w0.log)"
wait_for_log "$t/w0.log" "The world is up" 60 || fail "w at first ($t/w0.log)"
kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null
echo "enable_damage = false" >> "$d/apps/vanilla/saves/w/luanti/world.mt"
echo w > "$d/apps/vanilla/public_world"
# The public server, started again on 20
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
( while :; do
	"$here/Build/bin/buildat_server" -A 127.0.0.1 -P $PORT -m "$here/apps/vanilla" \
		-D "$d" -C "$t/c" -l 3 >> "$t/srv.log" 2>&1
	[ $? = 20 ] || break
	echo "=== restart" >> "$t/srv.log"
done ) &
CHECK_PIDS+=($!)
wait_for_log "$t/srv.log" "setup code" 120 || fail "the public server ($t/srv.log)"
wait_for_log "$t/srv.log" "The world is up" 120 || fail "no world ($t/srv.log)"
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | head -1 | cut -d' ' -f3)
# join <name> <create> <code> <log> <cmds>: through the launcher's connect
# screen, which a restart's goodbye rejoins from (a client started with -s
# has nowhere to go back to)
join(){
	{ printf 'delay 4000\nclick LineEdit "29500"\ndelay 300\nkeypress End\n'
		printf 'keypress Backspace\n%.0s' 1 2 3 4 5
		printf 'text %s\ndelay 300\nclick Button "Join"\n' $PORT
		cat "$5"; } > "$5.full"
	BUILDAT_JOIN_NAME=$1 BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=$2 \
		BUILDAT_JOIN_CODE=$3 timeout 300 "$here/Build/bin/buildat" -o launch_ui=launch_menu \
		-a extension/launch_menu/connect -D "$t/cl_$1" -C "$t/cc_$1" -w 1100x800 -u 1 -l 3 \
		-o sound_mute=1 -c @"$5.full" > "$4" 2>&1
}
# The admin's account first, then the user's (made by the admin's code
# of a plain create)
# The admin's ntfy question answered for good ([ADMIN_NOTIFY])
printf 'wait_log 30000 accounts: ntfy asked\ndelay 1500\nclick Button "Don'"'"'t add"\ndelay 1500\nquit\n' > "$t/a0.cmds"
join admin 1 "$code" "$t/a0.log" "$t/a0.cmds"
grep -aq "Joined as admin" "$t/a0.log" || fail "the admin's account ($t/a0.log)"

cat > "$t/u.cmds" <<C
wait_log 120000 the server put the player at
wait_log 120000 admin stops the server's world
wait_log 60000 join: held: Stopped by an admin (admin)
delay 1000
screenshot $t/held.png
keypress Escape
delay 1000
screenshot $t/held_escape.png
click Button "Chat..."
delay 800
text hello while stopped
keypress Return
wait_log 10000 join: chat: <user> hello while stopped
delay 500
screenshot $t/chat.png
keypress Escape
delay 1000
wait_log 120000 the server put the player at
delay 1000
screenshot $t/back.png
quit
C
cat > "$t/a.cmds" <<C
wait_log 120000 the server put the player at
delay 8000
keypress Escape
delay 1000
click Button "Worlds..."
wait_log 10000 menu:
delay 1000
click Button "Stop the world..."
delay 800
click Button "Stop"
wait_log 60000 menu: 1 saves
delay 15000
screenshot $t/admin_menu.png
click Button "w*"
delay 500
click Button "Play"
wait_log 120000 the server put the player at
delay 4000
quit
C
join user 1 "" "$t/u.log" "$t/u.cmds" &
upid=$!
sleep 3
join admin 0 "" "$t/a.log" "$t/a.cmds"
wait $upid
grep -a "stops\|join: \|Command sequence failed\|reconnect" "$t/u.log" "$t/a.log" | cut -c1-200
grep -a "Command sequence failed" "$t/u.log" "$t/a.log" && fail "a drive"
grep -aq "join: held: Stopped by an admin (admin)" "$t/u.log" || fail "not held ($t/u.log)"
[ "$(grep -ac "vanilla : join: held:" "$t/u.log")" = 2 ] || fail "the held page closed or not back after the chat ($t/u.log)"
grep -aq "join: chat: <user> hello while stopped" "$t/u.log" || fail "the chat ($t/u.log)"
[ "$(grep -ac "the server put the player at" "$t/u.log")" -ge 2 ] || fail "the user not in again ($t/u.log)"
[ "$(grep -c "=== restart" "$t/srv.log")" = 1 ] || fail "not one restart ($t/srv.log)"
echo "PASS: an admin stops the world; the user held with the chat working and back in when the admin plays it"
