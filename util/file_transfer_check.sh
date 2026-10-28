#!/bin/bash
# tier: quick
# cost: ~1 min (2026-10-29)
# covers: builtin/client_file/client_file.cpp builtin/network/network.cpp builtin/network/api.h src/impl/packet_stream.cpp src/impl/tcpsocket.cpp src/interface/select_handler.h src/client/state.cpp apps/file_transfer_check
# [FILE_TRANSFER_LATENCY]: a server's file through util/netsim.py at
# 100 ms each way and 2 MB/s (16000 kbit/s) arrives in about its size over
# the bandwidth and a few round trips, and the game's packets are not held
# behind it: apps/file_transfer_check pings every 50 ms, asks for an 8 MB
# file of incompressible bytes and says how long it took and how the pings
# fared (each answered whenever). Natively, then in headless Chrome (the
# WebSocket path; skipped without web/ or Chrome). Before: 4 KB a delay
# (netsim's own pump), and every ping during a download waited for all of
# it, 3.4 s for this file.
#   util/file_transfer_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp file_transfer; t=$CHECK_TMP
BYTES=8000000 RATE=16000 DELAY=100
BUILDAT_FTC_BYTES=$BYTES start_server "$t/srv.log" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -A 127.0.0.1 \
	-m "$here/apps/file_transfer_check" -D "$t/s" -C "$t/s.cache" -l 3 \
	-W "$here/web" || fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
LINK=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 "$here/util/netsim.py" --listen "$LINK" --to "127.0.0.1:$SERVER_PORT" \
	--delay $DELAY --rate $RATE > "$t/netsim.log" 2>&1 &
CHECK_PIDS+=($!)
wait_for_log "$t/netsim.log" "netsim: listening" 10 || fail "netsim ($t/netsim.log)"

# The file's time against size / bandwidth and six round trips (the ask,
# the announce, the request, the last bytes, slack), and the pings' worst
# against their median before it, with a second to spare: before, the
# worst was the whole download
verdict(){ # name, log
	python3 - "$1" "$2" $BYTES $RATE $DELAY <<'PY'
import re, sys
name, path, size, rate, delay = sys.argv[1], sys.argv[2], *map(float, sys.argv[3:])
log = open(path, errors="replace").read()
t = re.search(r"ftc: the file in ([0-9.]+) s", log)
before = re.search(r"ftc: pings before: \d+ pings, median (\d+) ms", log)
during = re.search(r"ftc: pings during: (\d+) pings, median (\d+) ms, max (\d+) ms", log)
assert t and before and during, "%s: no ftc lines (%s)" % (name, path)
t = float(t.group(1))
bound = size / (rate * 125) + 6 * 2 * delay / 1000
worst = int(during.group(3)) - int(before.group(1))
print("%s: %.0f MB in %.2f s (bound %.2f s); pings %s ms before, during %s" % (
    name, size / 1e6, t, bound, before.group(1), during.group(0).split(": ", 2)[2]))
assert t <= bound, "%s: the file took %.2f s, over %.2f s" % (name, t, bound)
assert worst <= 1000, "%s: a ping waited %d ms over its median" % (name, worst)
PY
}

printf "wait_log 120000 ftc: done\nquit\n" > "$t/cmds"
run_client 60 "$t/native.log" timeout 150 "$here/Build/bin/buildat" -C "$t/c" \
	-D "$t/u" -w 320x240 -l 3 -o sound_mute=1 -s "127.0.0.1:$LINK" \
	-c @"$t/cmds" || fail "the native drive ($t/native.log)"
verdict native "$t/native.log" || fail "native ($t/native.log)"

if [ ! -f "$here/web/buildat.wasm" ] ||
		! command -v "${CHROME:-google-chrome}" > /dev/null; then
	echo "PASS: (native; the web SKIPPED: no web/ or Chrome)"; exit 0
fi
# The server's file is announced at the next connect: a new one per run
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
BUILDAT_FTC_BYTES=$BYTES start_server "$t/srv2.log" "STATUS Listening" 300 \
	"$SERVER_PORT" "$here/Build/bin/buildat_server" -A 127.0.0.1 \
	-m "$here/apps/file_transfer_check" -D "$t/s2" -C "$t/s.cache" -l 3 \
	-W "$here/web" || fail "the second server ($t/srv2.log)"
CHECK_PIDS+=($SERVER_PID)
cat > "$t/steps.json" <<'J'
[
	["nav", "${URL}"],
	["waitlog", "ftc: done", 120]
]
J
WEB_DRIVE_URL="http://127.0.0.1:$LINK/" "$here/util/web_drive.sh" chrome \
	file_transfer_check "$t/steps.json" "$t/web" > "$t/web.log" 2>&1 ||
	fail "the web drive ($t/web.log)"
verdict web "$t/web/page.log" || fail "web ($t/web/page.log)"
echo "PASS: the file near its size over the bandwidth, the pings not held behind it, native and web"
