#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# [SECURITY_RUN_1] phase 4, protocol fuzzing: a vanilla server on a scratch
# user directory with a devtest world running (as the tests start one,
# launcher=1, so the fuzzer is the local peer and every launcher-only door
# is open to it), proto_fuzz.py at it, and the server watched: still
# running, still answering a connect, and its log free of a crash. The
# log and the seed go to local/security/fuzz/proto/.
#
# PUBLIC=1 starts it as a public server (no -u): the fuzzer is then any
# peer on the internet, with no door of the launcher's open. BUILD=asan
# runs Build/asan's server (cmake -DSANITIZE=address there), whose
# runtime-compiled modules are instrumented too. APP=floorplanner runs that
# app instead, and the fuzzer logs in, opens a plan and sends batches and
# plan files built from its schema (proto_fuzz.py). GAME=mineclone2 runs
# vanilla's world on that game (VoxeLibre) instead of devtest.
#
#   util/fuzz/proto_fuzz.sh [seconds] [seed]
set -u
. "$(dirname "$0")/../check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/security/fuzz/proto"
secs=${1:-120}
seed=${2:-$RANDOM}
app=${APP:-vanilla}
game=${GAME:-devtest}
mkdir -p "$out"
user="$out/user"
rm -rf "$user/apps"
mkdir -p "$user/shared/vanilla/games"
[ -d "$user/shared/vanilla/games/$game" ] ||
	cp -r "$BUILDAT_USER_PATH/shared/vanilla/games/$game" "$user/shared/vanilla/games/"
grep -rhoE '"network:packet_received/[a-z_]+:[a-z_0-9]+"' \
	"$here/builtin" "$here/apps" --include=*.cpp |
	sed 's/"network:packet_received\///; s/"//' | sort -u > "$out/names.txt"
# floorplanner's schema: a line per type, its name and then its fields
words=()
if [ "$app" = floorplanner ]; then
	awk 'match($0, /^\t\{"[a-z_]+", \{/){ if(t) print t; t = substr($0, 4, RLENGTH - 7) }
		t && match($0, /^\t\t\{"[a-z_0-9]+",/){ t = t " " substr($0, 5, RLENGTH - 6) }
		END { print t }' "$here/apps/floorplanner/main/main.cpp" > "$out/words.txt"
	words=("$out/words.txt")
fi
port=$(( 29700 + (RANDOM % 90) ))
cd "$here/Build${BUILD:+/$BUILD}"
export ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0:abort_on_error=1}
# A build left behind the tree fuzzes code that is gone: the ASan one
# lacked a fix to the server's logging for a run, 2026-10-03
make -s -j8 > "$out/make.log" 2>&1 ||
	{ echo "the build failed: $out/make.log"; exit 2; }
launch=(-u launcher=1)
[ "${PUBLIC:-}" = 1 ] && launch=()
# A build directory below Build/ is one level deeper than the paths are
# looked for from
[ -n "${BUILD:-}" ] && launch+=(-U "$here/3rdparty/Urho3D" -S "$here"
	-i "$here/src/interface" -C "$out/cache_$BUILD")
# The modules compiled before the clock starts ([COMPILE_ONLY]): a
# compile failure reads as one, not as a server that never came up
bin/buildat_server --compile-only "${launch[@]}" -m "$here/apps/$app" \
	-D "$user" > "$out/compile.log" 2>&1 ||
	{ echo "a module failed to compile: $out/compile.log"; exit 2; }
BUILDAT_LUANTI_GAME=$game BUILDAT_LUANTI_SAVE=proto_$game \
	bin/buildat_server "${launch[@]}" -m "$here/apps/$app" -D "$user" \
	-P "$port" > "$out/srv.log" 2>&1 &
srv=$!
trap 'kill -9 $srv 2>/dev/null' EXIT
for i in $(seq 1 180); do
	grep -aq "Mods loaded\|world is running\|STATUS Listening" "$out/srv.log" && break
	sleep 1
done
sleep 5
echo "$app, seed $seed, port $port, $(wc -l < "$out/names.txt") packet names"
# Only what the server logs from here on: a module compiling at start makes
# the loader wait, which is not two modules waiting for each other
start=$(wc -l < "$out/srv.log")
since() { tail -n +"$((start + 1))" "$out/srv.log"; }
python3 "$here/util/fuzz/proto_fuzz.py" "$port" "$secs" "$out/names.txt" \
	"$seed" "${words[@]}" > "$out/client.log" 2>&1 &
cli=$!
bad=""
while kill -0 $cli 2>/dev/null; do
	sleep 5
	if ! kill -0 $srv 2>/dev/null; then bad="the server exited"; break; fi
	since | grep -aq "Crash: SIG\|AddressSanitizer\|: runtime error" &&
		{ bad="a crash in the log"; break; }
	# Two modules waiting for each other: the server answers a connect
	# and nothing else (accounts and starport_announce, 2026-10-03)
	since | grep -aq "has been waiting [0-9]* s" &&
		{ bad="modules waiting for each other"; break; }
done
wait $cli 2>/dev/null
cat "$out/client.log"
# One peer at full speed waits for the modules rather than queueing in
# memory: unbounded, 10 s of this grew the server by 300 MB. Not under
# ASan, whose quarantine keeps 256 MB of freed memory: a public vanilla
# "grew" 276 MB there and 0 in the ordinary build (2026-10-04)
if [ -z "$bad" ] && [ "${BUILD:-}" = asan ]; then
	echo "a flood from one peer: not measured under ASan"
elif [ -z "$bad" ]; then
	rss0=$(awk '/VmRSS/{print $2}' /proc/$srv/status)
	flood=main:get_saves
	[ "$app" = floorplanner ] && flood=fp:presence
	timeout 10 python3 -c '
import socket, struct, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
p = lambda t, d: struct.pack("<HBI", t, 0, len(d)) + d
v = b"0.7.0"
h = struct.pack("<IIQ", 1, 1, len(v)) + v + struct.pack("<IQ", 2, 0)
s.sendall(p(2, b"\1\1\0" + bytes([len(h)]) + h))
n = sys.argv[2].encode()
s.sendall(p(0, struct.pack("<HI", 100, len(n)) + n))
chunk = p(100, b"") * 5000
while True: s.sendall(chunk)' "$port" "$flood" 2>/dev/null
	grow=$(( ($(awk '/VmRSS/{print $2}' /proc/$srv/status) - rss0) / 1000 ))
	echo "a flood from one peer grew the server by $grow MB"
	[ "$grow" -gt 150 ] && bad="a flood from one peer grew the server by $grow MB"
fi
# One address holds no more than 32 places; from this machine's LAN
# address, which is not loopback
lan=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+')
if [ -z "$bad" ] && [ -n "$lan" ]; then
	held=$(timeout 20 python3 -c '
import socket, sys, time
ss = [socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=3)
		for _ in range(40)]
time.sleep(1.5)
held = 0
for s in ss:
	s.setblocking(False)
	try: held += s.recv(1) != b""
	except BlockingIOError: held += 1
	except OSError: pass
print(held)' "$lan" "$port" 2>/dev/null)
	echo "40 connections from $lan: ${held:-?} held"
	[ "${held:-0}" = 32 ] || bad="40 connections from one address: ${held:-?} held, not 32"
fi
# A peer's bytes reach the log as \xNN: no escape or carriage return of
# the fuzzer's is left for a terminal to run (a log to a file has no
# colours of the logger's own)
if [ -z "$bad" ] && ! python3 -c '
import sys
d = open(sys.argv[1], "rb").read()
sys.exit(1 if b"\x1b" in d or b"\r" in d else 0)' "$out/srv.log"; then
	bad="a control byte from a peer reached the log raw"
fi
# Still answering after it
if [ -z "$bad" ] && ! timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null; then
	bad="the server stopped answering"
fi
# And it stops when asked: a deadlock shows here if nowhere else
if [ -z "$bad" ]; then
	# ASan's VoxeLibre generates a chunk a second, and a stop waits for
	# what is queued: 30 s ran out where the ordinary build took 70 ms
	stop=30; [ "${BUILD:-}" = asan ] && stop=120
	kill $srv 2>/dev/null
	for i in $(seq 1 $stop); do kill -0 $srv 2>/dev/null || break; sleep 1; done
	if kill -0 $srv 2>/dev/null; then
		bad="the server did not stop on SIGTERM in $stop s"
		kill -9 $srv 2>/dev/null
	fi
fi
if [ -n "$bad" ]; then
	echo "FAIL: $bad (seed $seed); $out/srv.log"
	grep -a "Crash: SIG\|AddressSanitizer\|: runtime error\|shutdown requested" "$out/srv.log" | head -5
	exit 1
fi
echo "PASS: the server ran through it and answers"
