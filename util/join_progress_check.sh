#!/bin/bash
# tier: full
# cost: ~5 min (2026-10-11)
# covers: apps/vanilla/main/client_lua/init.lua src/client/state.cpp
# [JOIN_PROGRESS]: vanilla's "Loading the world" line says what comes.
# Vanilla on VoxeLibre over a link of 300 KB/s (util/netsim.py), the
# native client joining:
#   - the line's megabytes rise at least every 2 s while the world comes;
#   - the server stopped (SIGSTOP) mid-join for 25 s: "Waiting for the
#     server" within 13 s (10 s, the line once a second and the last
#     bytes on the way), and Leave offered from 20 s;
#   - the server going on: the world comes and the line goes.
# simplified: native only; the web client reads the same state.cpp count.
# Needs mineclone2 in the desk's games.
#   util/join_progress_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
G="$BUILDAT_USER_PATH/shared/vanilla/games/mineclone2"
[ -d "$G" ] || { echo "SKIP: no mineclone2"; exit 0; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp join_progress; t=$CHECK_TMP
trap 'kill -CONT $SERVER_PID 2>/dev/null; check_cleanup' EXIT
mkdir -p "$t/srv/shared/vanilla/games"
cp -r "$G" "$t/srv/shared/vanilla/games/"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=jp start_server "$t/srv.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/srv" -C "$t/srv.cache" -l 3 ||
	fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
LINK=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 "$here/util/netsim.py" --listen "$LINK" --to "127.0.0.1:$SERVER_PORT" \
	--delay 0 --rate 2400 > "$t/netsim.log" 2>&1 &
CHECK_PIDS+=($!)
sleep 1
{
	echo "wait_log 180000 load: Waiting [f]or the server"
	echo "wait_log 60000 load: Leave [o]ffered"
	echo "wait_log 300000 settle: [0-9]* to mesh, [1-9][0-9]* chunks in scene"
	echo quit
} > "$t/cmds"
L=$t/client.log
# The server stopped after the line's fifth megabyte count, for 25 s
(
	for i in $(seq 1 300); do
		[ "$(grep -ac "load: Loading the world.* MB" "$L" 2>/dev/null)" -ge 5 ] && break
		sleep 1
	done
	kill -STOP $SERVER_PID; date +%s.%N > "$t/stopped"
	sleep 25
	kill -CONT $SERVER_PID; date +%s.%N > "$t/continued"
) &
CHECK_PIDS+=($!)
run_client 60 "$L" timeout 400 "$here/Build/bin/buildat" -C "$t/nc" -D "$t/nu" \
	-s "127.0.0.1:$LINK" -w 800x450 -l 3 -o sound_mute=1 -c @"$t/cmds"
grep -a "vanilla : load: " "$L" | sed 's/.*load: /load: /' | sed -n '1,3p;$p'
[ -f "$t/stopped" ] || fail "the line never showed five megabyte counts ($L)"
python3 - "$L" "$(cat "$t/stopped")" <<'PY' || fail "the line ($L)"
import re, sys, datetime
stopped = float(sys.argv[2])
day = datetime.datetime.fromtimestamp(stopped).date()
def at(line):
    h, m, s = re.search(r" (\d\d):(\d\d):(\d\d\.\d+) ", line).groups()
    return datetime.datetime.combine(day, datetime.time()).timestamp() + \
        int(h) * 3600 + int(m) * 60 + float(s)
mb, waiting, leave = [], None, None
for l in open(sys.argv[1], errors="replace"):
    m = re.search(r"load: Loading the world.* -- ([\d.]+) MB", l)
    if m and at(l) < stopped:
        mb.append((at(l), float(m.group(1))))
    if "vanilla : load: Waiting for the server" in l and waiting is None:
        waiting = at(l)
    if "vanilla : load: Leave offered" in l and leave is None:
        leave = at(l)
# Rising at least every 2 s, up to the stop
last_t, last_v = mb[0]
for t, v in mb[1:]:
    if v > last_v:
        last_t, last_v = t, v
    assert t - last_t <= 2.5, "the megabytes stood at %.1f for %.1f s" % (v, t - last_t)
print("the megabytes rose to %.1f in %d lines" % (mb[-1][1], len(mb)))
assert waiting and waiting - stopped <= 13, "waiting %s s after the stop" % (waiting and waiting - stopped)
assert leave and leave - stopped >= 19, "Leave %s s after the stop" % (leave and leave - stopped)
print("waiting %.1f s and Leave %.1f s after the stop" % (waiting - stopped, leave - stopped))
PY
grep -aqE "settle: [0-9]+ to mesh, [1-9][0-9]* chunks in scene" "$L" ||
	fail "no world after the server went on ($L)"
echo "PASS: the loading line's megabytes rise while the world comes; a stopped server reads as waiting, then Leave; the world comes after"
