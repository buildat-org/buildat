#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-12)
# covers: apps/vanilla/main/client_lua/menu.lua apps/vanilla/main/client_lua/pause.lua apps/vanilla/main/main.cpp client/api.lua src/client/app_lua.h
# [WORLDS_SELECTED] [PAUSE_WORLDS_LOCAL]: vanilla's worlds screen, saves
# alpha and bravo of the minimal game.
#   1. A launcher=1 server with no world: the right column only its head
#      ("Pick a world on the left") until a row is clicked, then Play.
#   2. The launcher opens bravo; pause, Worlds...: bravo selected and Play
#      shown; Delete... on it refused; Escape back to the game; Worlds...
#      again, a filter matching nothing: no Play; the filter cleared, alpha
#      clicked and Play: the launcher stops bravo's server and alpha is
#      loaded.
# simplified: native only; the public server's pause menu is
# util/vanilla_stop_check.sh's.
#   util/pause_worlds_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp pause_worlds; t=$CHECK_TMP
d=$t/u
for w in alpha bravo; do
	BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=$w start_server "$t/mk_$w.log" \
		"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
		-A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" -C "$t/c" -l 3 ||
		fail "$w ($t/mk_$w.log)"
	wait_for_log "$t/mk_$w.log" "The world is up" 60 || fail "$w not up ($t/mk_$w.log)"
	kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null
	echo "enable_damage = false" >> "$d/apps/vanilla/saves/$w/luanti/world.mt"
	# bravo the later, first on Home's Continue: a time apart a clock with
	# seconds tells
	sleep 1.5
done

# 1.
start_server "$t/s1.log" "STATUS Listening" 120 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" -C "$t/c" -l 3 ||
	fail "the server ($t/s1.log)"
CHECK_PIDS+=($SERVER_PID)
cat > "$t/1.cmds" <<C
wait_log 30000 menu: 2 saves
frames 3
event scan
screenshot $t/none.png
click Button "alpha*"
wait_log 10000 menu: the world alpha shown
delay 300
event scan
screenshot $t/alpha.png
quit
C
timeout 120 "$here/Build/bin/buildat" -D "$t/nu" -C "$t/nc" -s 127.0.0.1:$SERVER_PORT \
	-w 1100x800 -l 3 -o sound_mute=1 -c @"$t/1.cmds" > "$t/1.log" 2>&1
kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null
grep -aq "Command sequence complete" "$t/1.log" || fail "the drive ($t/1.log)"
python3 - "$t/1.log" <<'PY' || fail "the right column ($t/1.log)"
import sys
scans, cur = [], None
for l in open(sys.argv[1], errors="replace"):
    if "event scan" in l and "scan: ui" not in l:
        cur = []; scans.append(cur)
    elif "scan: ui" in l and cur is not None:
        cur.append(l)
assert len(scans) == 2, "%d scans" % len(scans)
has = lambda s, text: any('text "%s"' % text in l for l in s)
assert has(scans[0], "Pick a world on the left"), "no head"
assert not has(scans[0], "Play") and not has(scans[0], "Delete..."), "buttons with nothing selected"
assert any('text "alpha  --' in l for l in scans[1]) and has(scans[1], "Play") and has(scans[1], "Delete..."), "no buttons for alpha"
print("ok: no world selected: the head alone; alpha clicked: its buttons")
PY

# 2. Home's first row (bravo, at 1100x800 from a scan), then the pause menu
cat > "$t/2.cmds" <<C
wait_log_any 20000 , first bravo
frames 3
event scan
click Text "bravo"
wait_log 120000 the server put the player at
wait_log_any 60000 load: the world is in
delay 500
keypress Escape
wait_log 5000 pause: the menu shown
click Button "Worlds..."
wait_log 10000 menu: the running world bravo selected
wait_log 10000 menu: the world bravo shown
delay 300
event scan
screenshot $t/bravo.png
click Button "Delete..."
wait_log 5000 confirm dialog: Move the world
delay 300
click Button "Move to the trash"
wait_log 10000 menu: The world that is running
delay 800
keypress Escape
wait_log 10000 menu: 2 saves
delay 300
keypress Escape
wait_log 5000 pause: back in the game from the worlds
delay 500
event scan
screenshot $t/back.png
keypress Escape
wait_log 5000 pause: the menu shown
click Button "Worlds..."
wait_log 10000 menu: 2 saves
frames 3
click LineEdit "*"
# the click's frames: the field takes the focus in the frames after it
delay 300
text zzz
keypress Return
wait_log 5000 menu: filtered by "zzz"
delay 300
event scan
click LineEdit "*"
# the click's frames: the field takes the focus in the frames after it
delay 300
keypress End
keypress Backspace
keypress Backspace
keypress Backspace
keypress Return
wait_log 5000 menu: filtered by ""
delay 300
click Button "alpha*"
wait_log 10000 menu: the world alpha shown
click Button "Play"
wait_log 60000 save=alpha
wait_log 60000 the server put the player at
wait_log 60000 load: the world is in
delay 500
screenshot $t/alpha_in.png
quit
C
timeout 300 "$here/Build/bin/buildat" -o launch_ui=launch_menu -D "$d" -C "$t/c2" \
	-w 1100x800 -l 3 -o sound_mute=1 -c @"$t/2.cmds" > "$t/2.log" 2>&1
# The client's local server, if it outlived the client
for p in $(pgrep -f "[b]uildat_server .*-D $d"); do kill $p; done
grep -a "menu: \|Command sequence\|launch_save\|Starting local server\|Local server" "$t/2.log" | cut -c1-200
grep -aq "Command sequence complete" "$t/2.log" || fail "the drive ($t/2.log)"
[ "$(grep -ac "Starting local server" "$t/2.log")" = 2 ] || fail "not two local servers ($t/2.log)"
grep -aq "untrusted_launch: opening save alpha" "$t/2.log" || fail "alpha not opened ($t/2.log)"
[ -d "$d/apps/vanilla/saves/bravo" ] || fail "bravo deleted"
python3 - "$t/2.log" <<'PY' || fail "the screens ($t/2.log)"
import sys
scans, cur = [], None
for l in open(sys.argv[1], errors="replace"):
    if "event scan" in l and "scan: ui" not in l:
        cur = []; scans.append(cur)
    elif "scan: ui" in l and cur is not None:
        cur.append(l)
assert len(scans) == 4, "%d scans" % len(scans)
has = lambda s, text: any('text "%s"' % text in l for l in s)
assert any('text "bravo  --' in l for l in scans[1]) and has(scans[1], "Play"), "bravo not selected over the game"
assert not has(scans[2], "Play") and not has(scans[2], "Paused"), "not back in the game"
assert not has(scans[3], "Play"), "Play with the selected row filtered out"
print("ok: bravo selected over the game, Escape back in it, the filter took the buttons")
PY
echo "PASS: the worlds screen's right column follows the selection; a launcher's game's Worlds... selects it, goes back to it and opens another through the launcher"
