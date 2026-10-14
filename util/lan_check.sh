#!/bin/bash
# tier: full
# cost: 90s (2026-10-04)
# covers: builtin/network/network.cpp src/impl/tcpsocket.cpp src/client/app.cpp
# [LAN_DISCOVERY]: a server announces itself on the LAN's group only when
# told to, and a client's list holds a flood of false ones to 32.
#   1. digger with --lan-announce: an announcement with its name and port
#      is heard on 239.255.29.50:29599 within 5 s.
#   2. digger without it: nothing from its port in 5 s.
#   3. 100 false announcements (other ports, control characters in the
#      name) while a client shows the connect screen: the client says its
#      list is full, and the screenshot shows 32 at most.
#   4. [WIN_FIREWALL]: a fresh client holds no socket on the LAN port
#      (Windows' firewall asks about one) until the player opens the
#      connect screen's "This network". From the start once that is in
#      the preferences: 3, by -o.
#
#   util/lan_check.sh    (SHOT=x.png keeps the screenshot)
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
s=
trap '[ -n "$s" ] && kill $s 2>/dev/null; rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
cd "$here/Build"

# hear <port> <seconds>: the first announcement for that port, or nothing
hear(){
	python3 - "$1" "$2" <<'EOF'
import socket, struct, sys, time, json
port, secs = int(sys.argv[1]), float(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
s.bind(("", 29599))
s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
        struct.pack("4s4s", socket.inet_aton("239.255.29.50"),
        socket.inet_aton("0.0.0.0")))
end = time.time() + secs
while time.time() < end:
    s.settimeout(max(0.01, end - time.time()))
    try:
        d, _ = s.recvfrom(1500)
    except socket.timeout:
        break
    try:
        v = json.loads(d)
    except ValueError:
        continue
    if v.get("port") == port:
        print(d.decode())
        break
EOF
}

# A poll, 30 s at most
until_log(){ # file pattern
	for _ in $(seq 300); do grep -aq "$2" "$1" && return 0; sleep 0.1; done
	return 1
}

# start <port> [args]: digger, until it listens
start(){
	local port=$1; shift
	start_server "$t/srv$port.log" "STATUS Listening" 120 "$port" \
		bin/buildat_server -m ../apps/digger -D "$t/srv$port" -l 3 "$@" ||
		fail "digger did not start"
	s=$SERVER_PID
}

# 1
start 29581 --lan-announce "LAN check"
a=$(hear 29581 5)
echo "$a" | grep -q '"name":"LAN check"' || fail "no announcement heard: '$a'"
echo "$a" | grep -q '"app":"digger"' || fail "the app is missing: $a"
kill $s; wait $s 2>/dev/null; s=

# 2
start 29582
a=$(hear 29582 5)
[ -z "$a" ] || fail "announced without --lan-announce: $a"
kill $s; wait $s 2>/dev/null; s=

# 3
printf 'wait_log_any 30000 LAN list full\ndelay 1500\nscreenshot %s/flood.png\nquit\n' \
	"$t" > "$t/seq"
timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/u" -w 1280x720 -u 1 -l 3 -o sound_mute=1 \
	-o lan_discovery=1 -a extension/launch_menu/connect -c @"$t/seq" > "$t/c.log" 2>&1 &
c=$!
until_log "$t/c.log" "Listening for LAN" || fail "the client did not listen ($t/c.log)"
# A round a second: the client's list fills over a few of its frames
python3 - <<'EOF'
import socket, json, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
for r in range(4):
    for p in range(20000, 20100):
        s.sendto(json.dumps({"buildat_lan": 1, "name": "fake\x01\n%d" % p +
                "x" * 200, "app": "../evil", "version": "1", "port": p,
                "players": -5}).encode(), ("239.255.29.50", 29599))
    # a timing: a round a second
    time.sleep(1)
EOF
wait $c
grep -q "LAN list full (32)" "$t/c.log" || fail "the list was not capped ($(grep -i lan "$t/c.log" | tail -3))"
grep -q "Wrote screenshot" "$t/c.log" || fail "no screenshot"
[ -n "${SHOT:-}" ] && cp "$t/flood.png" "$SHOT"
# 4. The sockets on the LAN port of the client (timeout's child), each
# read once the log says the drive is at that point
lan_fds(){ # pid
	ss -Huanp "sport = :29599" 2>/dev/null | grep -c "pid=$(pgrep -P $1),"
}
# The delays hold the client while the shell reads its sockets: the
# first marks the read before This network, the last the one after
printf 'wait_log_any 30000 Join a Buildat server: shown\ndelay 1500\nclick Button "This network"\nwait_log 10000 Listening for LAN\ndelay 1500\nquit\n' > "$t/seq4"
timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/u4" -w 1280x720 -u 1 -l 3 \
	-o sound_mute=1 -a extension/launch_menu/connect -c @"$t/seq4" > "$t/c4.log" 2>&1 &
c=$!
# The first read at the drive's first hold; the second 0.5 s after the
# line (a settle after it)
until_log "$t/c4.log" "command: delay 1500" && before=$(lan_fds $c)
until_log "$t/c4.log" "Listening for LAN games" && sleep 0.5 && after=$(lan_fds $c)
wait $c
grep -q "Command sequence complete" "$t/c4.log" ||
	fail "the drive stopped: $(grep -a "Command sequence\|rror" "$t/c4.log" | tail -2)"
[ "${before:-}" = 0 ] || fail "a fresh client listens on the LAN port (${before:-not read})"
[ -n "${after:-}" ] && [ "$after" != 0 ] ||
	fail "This network did not start the listen ($(grep -a "LAN\|lan_" "$t/c4.log" | tail -2))"
echo "PASS: announced only with --lan-announce; a flood capped at 32; the LAN heard only once the player opened This network"
