#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-11)
# covers: src/client/wss.cpp src/client/state.cpp
# [JOIN_DRAIN]: the native client over https:// takes in what the link
# carries. Vanilla on VoxeLibre behind a TLS proxy (util/tls_proxy.py, as
# groundzero's 443) and a link of 8 MB/s (util/netsim.py); the native
# client joins https://127.0.0.1 and the world's first 200 chunks are in
# its scene within 15 s of "vanilla client ready" (12.5 s; 42 s with a
# read of one TLS record an update, 2026-10-11). Its TLS log says how the
# bytes came. netsim's --delay holds each 4 KB in turn, 200 KB/s at 20
# ms, so the link is its rate alone.
# Needs mineclone2 in the desk's games.
#   util/join_drain_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
G="$BUILDAT_USER_PATH/shared/vanilla/games/mineclone2"
[ -d "$G" ] || { echo "SKIP: no mineclone2"; exit 0; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp join_drain; t=$CHECK_TMP
trap check_cleanup EXIT
mkdir -p "$t/srv/shared/vanilla/games"
cp -r "$G" "$t/srv/shared/vanilla/games/"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=jd start_server "$t/srv.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/srv" -C "$t/srv.cache" -l 3 ||
	fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
read -r TLS LINK < <(python3 -c 'import socket
s = [socket.socket() for _ in range(2)]
for x in s: x.bind(("127.0.0.1", 0))
print(*(x.getsockname()[1] for x in s))')
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 \
	-addext subjectAltName=IP:127.0.0.1 -keyout "$t/key.pem" \
	-out "$t/cert.pem" 2> /dev/null || fail "openssl"
python3 "$here/util/tls_proxy.py" "$t/cert.pem" "$t/key.pem" \
	"$TLS:127.0.0.1:$SERVER_PORT" > "$t/proxy.log" 2>&1 &
CHECK_PIDS+=($!)
python3 "$here/util/netsim.py" --listen "$LINK" --to "127.0.0.1:$TLS" \
	--delay 0 --rate 64000 > "$t/netsim.log" 2>&1 &
CHECK_PIDS+=($!)
sleep 1
{
	echo "wait_log 120000 vanilla client ready"
	echo "wait_log 60000 load: the world is in"; echo "delay 15000"
	echo quit
} > "$t/cmds"
BUILDAT_CA_FILE=$t/cert.pem run_client 60 "$t/client.log" timeout 240 \
	"$here/Build/bin/buildat" -C "$t/nc" -D "$t/nu" -s "https://127.0.0.1:$LINK" \
	-w 800x450 -l 4 -o sound_mute=1 -c @"$t/cmds"
grep -a "TLS: [0-9]* bytes" "$t/client.log" | sed 's/.*TLS: /TLS: /' | head -3
ready=$(grep -a "vanilla client ready" "$t/client.log" | head -1 | awk '{print $3}')
world=$(grep -aE "settle: [0-9]+ to mesh, ([2-9][0-9]{2}|[0-9]{4,}) chunks in scene" \
	"$t/client.log" | head -1 | awk '{print $3}')
[ -n "$ready" ] && [ -n "$world" ] || fail "no ready ($ready) or no world ($world) ($t/client.log)"
secs=$(python3 -c "import sys
def s(x): h, m, r = x.split(':'); return int(h) * 3600 + int(m) * 60 + float(r)
print('%.1f' % (s('$world') - s('$ready')))")
echo "the world $secs s after the ready"
python3 -c "import sys; sys.exit(0 if $secs < 15 else 1)" ||
	fail "the world came $secs s after the ready ($t/client.log)"
echo "PASS: over TLS at 8 MB/s the world was in the scene $secs s after the ready"
