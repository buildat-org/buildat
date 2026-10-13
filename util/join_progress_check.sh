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
#     bytes on the way); no Leave since [LOADING_STRIPES]
#     (loading_screen_check's);
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
ns=$!
CHECK_PIDS+=($ns)
for i in $(seq 50); do
	grep -aq "netsim: listening" "$t/netsim.log" && break
	kill -0 $ns 2>/dev/null || fail "netsim ($t/netsim.log)"
	sleep 0.2
done
{
	# VoxeLibre's 67 MB of files take about 230 s at this rate, then the
	# world's first 5 MB and the stop. There is no Leave to wait for since
	# [LOADING_STRIPES]. The 2 s is a settle: the scene's line with chunks.
	echo "wait_log 330000 load: Waiting for the server"
	echo "wait_log 120000 load: the world is in"; echo "delay 2000"
	echo quit
} > "$t/cmds"
L=$t/client.log
# The server stopped after the line's fifth megabyte count, for 25 s
(
	for i in $(seq 1 1500); do
		[ "$(grep -ac "load: Loading the world.* MB" "$L" 2>/dev/null)" -ge 5 ] && break
		sleep 0.2
	done
	kill -STOP $SERVER_PID; date +%s.%N > "$t/stopped"
	# A timing test: the server silent for 25 s, which the line must say
	sleep 25
	kill -CONT $SERVER_PID; date +%s.%N > "$t/continued"
) &
CHECK_PIDS+=($!)
run_client 60 "$L" timeout 400 "$here/Build/bin/buildat" -C "$t/nc" -D "$t/nu" \
	-s "127.0.0.1:$LINK" -w 800x450 -l 3 -o sound_mute=1 -c @"$t/cmds" ||
	fail "the client ($L): $(grep -a "Command sequence failed\|run_client:" "$L" | tail -1)"
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
mb, waiting = [], None
for l in open(sys.argv[1], errors="replace"):
    m = re.search(r"load: Loading the world.* -- ([\d.]+) MB", l)
    if m and at(l) < stopped:
        mb.append((at(l), float(m.group(1))))
    if "vanilla : load: Waiting for the server" in l and waiting is None:
        waiting = at(l)
# Rising at least every 2 s, up to the stop
last_t, last_v = mb[0]
for t, v in mb[1:]:
    if v > last_v:
        last_t, last_v = t, v
    assert t - last_t <= 2.5, "the megabytes stood at %.1f for %.1f s" % (v, t - last_t)
print("the megabytes rose to %.1f in %d lines" % (mb[-1][1], len(mb)))
assert waiting and waiting - stopped <= 13, "waiting %s s after the stop" % (waiting and waiting - stopped)
print("waiting %.1f s after the stop" % (waiting - stopped))
PY
grep -aqE "settle: [0-9]+ to mesh, [1-9][0-9]* chunks in scene" "$L" ||
	fail "no world after the server went on ($L)"
echo "PASS: the loading line's megabytes rise while the world comes; a stopped server reads as waiting; the world comes after"
