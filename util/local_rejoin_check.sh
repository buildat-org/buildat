#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-18)
# covers: client/api.lua src/client/app.cpp src/client/app_lua.h builtin/replicate/replicate.cpp
# [LOCAL_REJOIN]: a local game's client rejoins the launcher's own server
# after a goodbye that says the server goes on. skeldat's worlds w1 and w2
# (128, seed 2) made first; the launcher plays w1 from Home's row; the
# pause menu's Worlds... and Play on w2: the client is sent off,
# keeps the local server (no "Stopping local server"), rejoins it within a
# second and is placed in w2; then Close world: sent off again, rejoined,
# and world_menu's list shown. The server has no SIGTERM and no replicate
# "Scene not found".
# simplified: a re-run ([SKELDAT_RERUN]) is the same reload and goodbye,
# not driven here (it needs an ended world)
#   util/local_rejoin_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp local_rejoin; t=$CHECK_TMP
d=$t/u
export BUILDAT_SKELDAT_INTRO=0 BUILDAT_SKELDAT_STARTER=0
for w in w2 w1; do
	BUILDAT_SKELDAT_WORLD=$w BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" \
		start_server "$t/mk_$w.log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" -u launcher=1 \
		-D "$d" -C "$t/c" -l 3 || fail "$w ($t/mk_$w.log)"
	wait_for_log "$t/mk_$w.log" "the world is in" 120 || fail "$w not made ($t/mk_$w.log)"
	kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null
done

# Home's first row, w1 (the later made), played on a local server
placed='wait_log 300000 skeldat: placed at'
worlds='keypress Escape
wait_log 5000 pause: the menu shown
delay 500
click Button "Worlds..."
wait_log 10000 world_menu: the list shown, 2 worlds
delay 500'
cat > "$t/cmds" <<C
wait_log_any 20000 , first w1
delay 1500
click Text "w1"
$placed
delay 1500
$worlds
click Button "w2"
wait_log 5000 world_menu: the list shown
delay 500
expect_error Disconnected from server: The server switches
click Button "Play"
wait_log 30000 Disconnected from server: The server switches to the world w2
wait_log 30000 reconnect: joined
$placed
delay 1500
$worlds
expect_error Disconnected from server: The world w2 was closed
click Button "Close world"
wait_log 30000 Disconnected from server: The world w2 was closed
wait_log 30000 reconnect: joined
wait_log 60000 world_menu: the list shown, 2 worlds
delay 500
quit
C
# The size again: the launcher's server makes the world's sections by it
BUILDAT_SKELDAT_SIZE="1 -1 0" timeout 400 "$here/Build/bin/buildat" -o launch_ui=launch_menu -D "$d" -C "$t/c2" \
	-w 800x600 -l 3 -o sound_mute=1 -c @"$t/cmds" > "$t/log" 2>&1
# The client's local server, if it outlived the client
for p in $(pgrep -f "[b]uildat_server .*-D $d"); do kill $p; done
grep -aq "Command sequence complete" "$t/log" ||
	fail "the drive: $(grep -a "Command sequence failed\|an error the drive" "$t/log" | tail -1) ($t/log)"
n(){ grep -ac "$1" "$t/log"; }
[ "$(n 'Local server kept: it goes on')" = 2 ] ||
	fail "$(n 'Local server kept: it goes on') kept, not 2 ($t/log)"
python3 - "$t/log" <<'PY' || fail "the rejoins ($t/log)"
import sys, re
lines = open(sys.argv[1], errors="replace").read().split("\n")
def ts(l):
    m = re.search(r" (\d\d):(\d\d):(\d\d)\.(\d\d\d) ", l)
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3)) + int(m.group(4)) / 1000
gone = [ts(l) for l in lines if "__state : Disconnected from server: The" in l]
back = [ts(l) for l in lines if "extensio: reconnect: joined" in l]
stops = [i for i, l in enumerate(lines) if "Stopping local server" in l]
quit_at = max(i for i, l in enumerate(lines) if "command: quit" in l)
# the third goodbye is the quit's
assert len(gone) == 3 and len(back) == 2, "%d sent off, %d rejoins" % (len(gone), len(back))
for g, b in zip(gone, back):
    assert 0 <= b - g < 1.5, "rejoined %.2f s after the goodbye" % (b - g)
assert all(i > quit_at for i in stops), "the local server stopped before the quit"
print("ok: two goodbyes, rejoined after %s s" % ", ".join("%.2f" % (b - g) for g, b in zip(gone, back)))
PY
s=$(ls "$t"/c2/*server*.log 2>/dev/null | head -1)
[ -n "$s" ] || fail "no local server log in $t/c2"
grep -aq 'the world "w2" starts' "$s" || fail "w2 did not start ($s)"
grep -aq "no world runs: the world menu" "$s" || fail "w2 not closed ($s)"
[ "$(grep -ac "SIGTERM" "$s")" -le 1 ] ||
	fail "the server had more than the quit's SIGTERM ($s)"
grep -aq "Scene .* not found" "$s" && fail "replicate's Scene not found ($s)"
echo "PASS: a local game's world switch and close rejoin the same server"
