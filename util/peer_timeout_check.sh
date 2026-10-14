#!/bin/bash
# tier: full
# cost: 165s (2026-10-04)
# covers: builtin/network/network.cpp src/client/state.cpp src/interface/select_handler.h
# [PEER_TIMEOUT]: a peer the server has not heard from in 60 s is dropped,
# and a client with nothing to say keeps its slot by its keepalive.
#   1. A raw TCP peer that sends nothing: the server closes it at 60 s.
#      [SELECT_BAD_FD]: the drop closed its fd under the select that came
#      next, and the select's failure set the listener aside for good; so
#      the server must still accept after it, and say nothing of select().
#   2. Beside it, a native client on digger, idle for 150 s: still on at
#      the end, and the server dropped nobody else.
#   3. With WEB=firefox or WEB=chrome: the web client (web/, from
#      util/build_web.sh) idle for 150 s on digger, through
#      util/web_drive.sh: the server dropped nobody.
#
#   util/peer_timeout_check.sh    [WEB=firefox]
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
s= c= q=
trap 'for p in $s $c $q; do kill $p 2>/dev/null; done; rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
cd "$here/Build"
P=29583
start_server "$t/srv.log" "STATUS Listening" 60 $P \
	bin/buildat_server -m ../apps/digger -D "$t/srv" -l 3 ||
	fail "digger did not start"
s=$SERVER_PID
# The 150 s idle is the check (as the web drive's wait below)
printf 'delay 150000\nquit\n' > "$t/seq"
timeout 240 bin/buildat -o launch_ui=launch_menu -s localhost:$P -D "$t/u" -w 640x360 -l 3 \
	-o sound_mute=1 -c @"$t/seq" > "$t/c.log" 2>&1 &
c=$!
# 1
raw=$(python3 - $P <<'PY'
import socket, sys, time
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
t0 = time.time()
s.settimeout(120)
try:
    while s.recv(65536):
        pass
except OSError:
    pass
print("%.0f" % (time.time() - t0))
PY
)
[ "$raw" -ge 58 ] && [ "$raw" -le 66 ] || fail "the raw peer went after ${raw} s, not 60"
# simplified: 2 s for the select after the drop to have run; nothing logs it
sleep 2
n0=$(grep -c "connected" "$t/srv.log")
# A peer with no hello logs nothing until it goes: its "disconnected" is
# the line, so it closes at once (the 0.5 s: its byte read before the close)
python3 -c "import socket,sys,time; s=socket.create_connection(('127.0.0.1',$P)); s.sendall(b'\0'); time.sleep(0.5)"
for _ in $(seq 50); do
	[ "$(grep -c "connected" "$t/srv.log")" -gt "$n0" ] && break
	sleep 0.2
done
[ "$(grep -c "connected" "$t/srv.log")" -gt "$n0" ] ||
	fail "nothing accepted after the drop: $(grep -i "select\|fd" "$t/srv.log" | tail -3)"
grep -q "select()\|Ignoring fds" "$t/srv.log" &&
	fail "the drop upset select(): $(grep "select()\|Ignoring fds" "$t/srv.log" | head -2)"
# 2
wait $c || fail "the idle client's run: $(grep -a "Command sequence failed" "$t/c.log" | tail -1)"
grep -q "Disconnected from server" "$t/c.log" &&
	fail "the idle client was cut: $(grep 'Disconnected from server' "$t/c.log")"
grep -q "Connect succeeded" "$t/c.log" || fail "the client never connected"
n=$(grep -c "nothing in 60 s; dropping it" "$t/srv.log")
[ "$n" = 1 ] || fail "the server dropped $n peers for silence, not 1: $(grep 'nothing in 60 s; dropping it' "$t/srv.log")"
web=""
if [ -n "${WEB:-}" ]; then
	# A timing test: the web client idle 150 s, past the server's 60 s
	cat > "$t/steps.json" <<'J'
[["nav", "${URL}"], ["waitlog", "Connect succeeded", 120],
 ["wait", 150000], ["shot", "${OUT}/idle.png"]]
J
	"$here/util/web_drive.sh" "$WEB" digger "$t/steps.json" "$t/web" \
		> "$t/web.log" 2>&1 || fail "the web drive failed: $(tail -3 "$t/web.log")"
	grep -q "nothing in 60 s; dropping it" "$t/web/server.log" &&
		fail "the idle web client was dropped: $(grep 'nothing in 60 s; dropping it' "$t/web/server.log")"
	web="; the $WEB client too"
fi
echo "PASS: a silent peer dropped at ${raw} s and the next accepted; a client idle for 150 s kept$web"
