#!/bin/bash
# tier: full
# cost: ~45s (2026-10-04)
# covers: src/client/state.cpp builtin/network/network.cpp builtin/replicate/replicate.cpp
# [CHUNK_RELOAD]: the client reads its socket dry into a 64 MB read-ahead,
# so the server saw an empty queue while the client was minutes behind, and
# replicate's hold-back never engaged: a view range stepped up and down sent
# every chunk's create and remove, played back for minutes after. The client
# now says what it has read and not handled (network:backlog), and
# pending_bytes() counts it.
#
# A client that handles one packet a frame (BUILDAT_PACKET_DRAIN_US) joins a
# minimal world; replicate must hold it back ("peer N held").
#   util/client_backlog_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here/Build"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
t=$(mktemp -d)
srv= cli=
trap '[ -n "$cli" ] && kill $cli 2>/dev/null; [ -n "$srv" ] && kill $srv 2>/dev/null; [ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "${t:?}"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
port=29776
# The whole send radius, so the world is more than replicate's 512 KB
mkdir -p "$t/srv/shared/vanilla"
echo '{"view_range": "200"}' > "$t/srv/shared/vanilla/settings.json"
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=backlog \
start_server "$t/srv.log" "STATUS Listening" 120 "$port" \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla -D "$t/srv" -l 3 ||
	fail "server did not listen"
srv=$SERVER_PID
# The client only stays joined; the server's log says when it is held
printf 'delay 60000\nquit\n' > "$t/seq"
BUILDAT_PACKET_DRAIN_US=1 timeout 90 bin/buildat -o launch_ui=launch_menu -s 127.0.0.1:$port \
	-D "$t/cl" -w 640x480 -u 1 -l 3 -o sound_mute=1 -c @"$t/seq" \
	> "$t/cl.log" 2>&1 &
cli=$!
for _ in $(seq 300); do
	grep -q "replicat.*peer [0-9]* held: [0-9]* bytes" "$t/srv.log" && break
	kill -0 $cli 2>/dev/null || break
	sleep 0.2
done
grep -q "replicat.*peer [0-9]* held: [0-9]* bytes" "$t/srv.log" ||
	fail "a client behind on handling was not held back"
echo "PASS: replicate holds a client that has read more than it has handled"
