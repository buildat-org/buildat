#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-12)
# covers: apps/vanilla/main/client_lua/menu.lua
# [WORLD_RELOAD_APPLY]: the in-game worlds screen reloads the running
# world whose options it changed. The minimal game's save alpha, opened
# from the launcher; pause, Worlds...:
#   1. nothing changed: Play, and it goes back to the game (no reload);
#   2. Worlds... again, Creative mode ticked: the button reads "Reload
#      world to apply"; clicked: a second local server, alpha in again,
#      creative_mode = true in its world.mt.
# Another world's Play is pause_worlds_check's.
#   util/world_reload_apply_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp world_reload_apply; t=$CHECK_TMP
d=$t/u
mt=$d/apps/vanilla/saves/alpha/luanti/world.mt
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=alpha start_server "$t/mk.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" -C "$t/c" -l 3 ||
	fail "alpha ($t/mk.log)"
wait_for_log "$t/mk.log" "The world is up" 60 || fail "alpha not up ($t/mk.log)"
kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null
echo "enable_damage = false" >> "$mt"
grep -q "creative_mode = true" "$mt" && fail "alpha creative from the start"

# The Creative mode click relabels Play in its own frame, a scan 300 ms on
cat > "$t/cmds" <<C
wait_log_any 20000 , first alpha
delay 1500
click Text "alpha"
wait_log 120000 the server put the player at
wait_log_any 60000 load: the world is in
delay 500
keypress Escape
wait_log 5000 pause: the menu shown
click Button "Worlds..."
wait_log 10000 menu: the running world alpha selected
wait_log 10000 menu: the world alpha shown
delay 300
event scan
click Button "Play"
wait_log 5000 pause: back in the game from the worlds
delay 300
event scan
keypress Escape
wait_log 5000 pause: the menu shown
click Button "Worlds..."
wait_log 10000 menu: the running world alpha selected
wait_log 10000 menu: the world alpha shown
delay 300
click Button "[ ] Creative mode"
wait_log 5000 menu: Creative mode on for alpha
event scan
click Button "Reload world to apply"
wait_log 60000 the server put the player at
wait_log 60000 load: the world is in
quit
C
timeout 300 "$here/Build/bin/buildat" -o launch_ui=launch_menu -D "$d" -C "$t/c2" \
	-w 1100x800 -l 3 -o sound_mute=1 -c @"$t/cmds" > "$t/c.log" 2>&1
# The client's local server, if it outlived the client
for p in $(pgrep -f "[b]uildat_server .*-D $d"); do kill $p; done
grep -a "menu: launch_save\|Starting local server\|Command sequence complete" "$t/c.log" | cut -c1-160
grep -aq "Command sequence complete" "$t/c.log" || fail "the drive ($t/c.log)"
[ "$(grep -ac "Starting local server" "$t/c.log")" = 2 ] || fail "not two local servers ($t/c.log)"
grep -q "creative_mode = true" "$mt" || fail "creative_mode not in alpha's world.mt"
python3 - "$t/c.log" <<'PY' || fail "the screens ($t/c.log)"
import sys
scans, cur = [], None
for l in open(sys.argv[1], errors="replace"):
    if "event scan" in l and "scan: ui" not in l:
        cur = []; scans.append(cur)
    elif "scan: ui" in l and cur is not None:
        cur.append(l)
assert len(scans) == 3, "%d scans" % len(scans)
has = lambda s, text: any('text "%s"' % text in l for l in s)
assert has(scans[0], "Play") and not has(scans[0], "Reload world to apply"), "unchanged: not Play"
assert not has(scans[1], "Play") and not has(scans[1], "Paused"), "Play did not go back to the game"
assert has(scans[2], "Reload world to apply") and not has(scans[2], "Play"), "changed: not Reload"
print("ok: Play unchanged and back to the game; changed, Reload world to apply")
PY
echo "PASS: a changed running world's Play reloads it with the change; unchanged it goes back"
