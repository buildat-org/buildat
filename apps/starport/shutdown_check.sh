#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: ~10 s (2026-10-28)
# covers: src/impl/http.cpp builtin/storage/storage.cpp builtin/accounts/accounts.cpp
# [STARPORT_SHUTDOWN_WAL]: a Starport SIGTERMed while its verifier waits on
# a listed server that accepts and never answers (http_get's two minutes)
# exits within 5 s, its saves closed: no -wal/-shm beside them, and no
# "running" row of accounts' left (the next start's "started again after a
# crash"). A second start and stop the same.
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
echo "PASS: SIGTERM with a check in flight closes the saves"
