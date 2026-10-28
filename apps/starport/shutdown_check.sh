#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: ~10 s (2026-10-28)
# covers: src/impl/http.cpp builtin/storage/storage.cpp builtin/accounts/accounts.cpp builtin/starport_announce/starport_announce.cpp apps/hearth/main/main.cpp apps/play/main/main.cpp
# [STARPORT_SHUTDOWN_WAL]: a Starport SIGTERMed while its verifier waits on
# a listed server that accepts and never answers (http_get's two minutes)
# exits within 5 s, its saves closed: no -wal/-shm beside them, and no
# "running" row of accounts' left (the next start's "started again after a
# crash"). A second start and stop the same. Then the other modules whose
# stop joins a thread that may be in HTTP, each stuck on that socket and
# SIGTERMed, out within 5 s: a Hearth announcing to it as its Starport
# (builtin/starport_announce, and Hearth's poller asking its list), and
# apps/play fetching Luanti's list from it.
#
#   apps/starport/shutdown_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9
check_tmp starport_shutdown; t=$CHECK_TMP

# The listed server: a socket that is listened on and never read
python3 -c '
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(50)
print(s.getsockname()[1], flush=True); time.sleep(600)' > "$t/silent" &
CHECK_PIDS+=($!)
wait_for_log "$t/silent" "^[0-9]+$" 10 || fail "no silent listener"
SILENT=$(cat "$t/silent")
export BUILDAT_CONNECT_PORTS=$SILENT

cd "$here/Build"
run(){ # n: start, (announce,) SIGTERM, and what it left
	start_server "$t/sp$1.log" "setup code" 120 auto \
		bin/buildat_server -m ../apps/starport -D "$t/d" -l 3 ||
		fail "the Starport did not start ($t/sp$1.log)"
	CHECK_PIDS+=($SERVER_PID)
	if [ "$1" = 1 ]; then
		curl -s -m 10 -d "{\"port\":$SILENT,\"name\":\"Silent\",\"kind\":\"app\",\"audience\":\"everyone\",\"access\":\"open\",\"descriptors\":{}}" \
			"127.0.0.1:$SERVER_PORT/api/v1/announce" | grep -q '"ok":true' ||
			fail "the announce"
	fi
	# The verifier connected to it and waiting (a start re-checks it)
	for i in $(seq 50); do
		ss -Htn state established "( dport = :$SILENT )" | grep -q . && break
		sleep 0.2
	done
	ss -Htn state established "( dport = :$SILENT )" | grep -q . ||
		fail "the verifier did not connect to the listing"
	kill -TERM $SERVER_PID
	for i in $(seq 25); do kill -0 $SERVER_PID 2>/dev/null || break; sleep 0.2; done
	kill -0 $SERVER_PID 2>/dev/null && fail "start $1: still running 5 s after SIGTERM"
	left=$(find "$t/d" -name "*.sqlite-wal" -o -name "*.sqlite-shm")
	[ -z "$left" ] || fail "start $1 left $left"
	python3 - "$t/d/apps/starport/saves/_server/save.sqlite" <<'EOF' || fail "start $1 left accounts' running row"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
r = c.execute("SELECT 1 FROM store WHERE store='accounts' AND key='running'").fetchone()
c.close()
sys.exit(1 if r else 0)
EOF
	echo "ok: start $1 stopped in $((i / 5)) s, its saves closed"
}
run 1
run 2

conns(){ ss -Htn state established "( dport = :$SILENT )" | wc -l; }
stuck(){ # app what n: started, n requests waiting on the socket, SIGTERMed
	local before; before=$(conns)
	start_server "$t/$1.log" "STATUS Listening" 300 auto \
		bin/buildat_server -m ../apps/$1 -D "$t/$1" -l 3 ||
		fail "$1 did not start ($t/$1.log)"
	CHECK_PIDS+=($SERVER_PID)
	for i in $(seq 50); do
		[ $(($(conns) - before)) -ge $3 ] && break
		sleep 0.2
	done
	[ $(($(conns) - before)) -ge $3 ] ||
		fail "$1: $(($(conns) - before)) requests to the socket, not $3"
	kill -TERM $SERVER_PID
	for i in $(seq 25); do kill -0 $SERVER_PID 2>/dev/null || break; sleep 0.2; done
	kill -0 $SERVER_PID 2>/dev/null && fail "$1: still running 5 s after SIGTERM"
	echo "ok: $1 stopped in $((i / 5)) s with $2 waiting"
}
mkdir -p "$t/hearth/apps/hearth"
echo "{\"starports\": [\"http://127.0.0.1:$SILENT\"], \"name\": \"Stuck\", \"kind\": \"app\", \"audience\": \"everyone\", \"access\": \"open\"}" \
	> "$t/hearth/apps/hearth/starport.json"
stuck hearth "the announce and the list" 2
BUILDAT_LUANTI_LIST=http://127.0.0.1:$SILENT stuck play "Luanti's list" 1
echo "PASS: SIGTERM with HTTP in flight stops each, the Starport's saves closed"
