#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: long
# devtest's /bench_* commands through bench.lua, with a client connected;
# prints the bench lines. See [LUAJIT] in doc/plan/performance_plan.md.
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d "/tmp/buildat_bench.XXXXXX")
cd "$here/Build"
rm -rf $BUILDAT_USER_PATH/apps/vanilla/saves/buildat_test_bench
srv=""; cli=""
trap '[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" >&2 || rm -rf "$tmp"; kill "$cli" 2>/dev/null; kill -INT "$srv" 2>/dev/null' EXIT
BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=buildat_test_bench \
	BUILDAT_LUANTI_LUA="$me/bench.lua" \
	start_server "$tmp/srv.log" "Mods loaded" 200 auto \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla ||
	{ echo "FAIL: the server did not start"; exit 1; }
port=$SERVER_PORT
srv=$SERVER_PID
# The client only keeps a player connected while the server runs the
# bench; the shell watches the server's log and kills it at "bench: done"
{ echo "delay 600000"; echo "quit"; } > "$tmp/cmds.txt"
bin/buildat -s "localhost:$port" -w 640x360 -l 2 -c @"$tmp/cmds.txt" \
	> "$tmp/cli.log" 2>&1 &
cli=$!
for i in $(seq 1 3000); do
	grep -aq "bench: done" "$tmp/srv.log" && break
	kill -0 "$cli" 2>/dev/null || break
	kill -0 "$srv" 2>/dev/null || break
	sleep 0.2
done
grep -a "bench: " "$tmp/srv.log" | sed 's/^.*bench: //'
# **The verdict is that the bench ran** ([CI_RUNS]'s contract,
# 2026-09-25): what a number here should be is the reading this exists
# to give -- a threshold invented here would be a number nobody picked,
# and one that fails on llvmpipe is what [CI_RUNS] (3) forbids. What can
# fail unseen is the run: a fixture that never finished, a client that
# died, a table with no rows.
rows=$(grep -ac "bench: " "$tmp/srv.log")
if ! grep -aq "bench: done" "$tmp/srv.log"; then
	echo "FAIL: the bench did not finish; $rows rows in $tmp/srv.log"
	exit 1
fi
if [ "$rows" -lt 2 ]; then
	echo "FAIL: the bench finished with nothing to say ($rows rows)"
	exit 1
fi
echo "PASS: the bench ran and wrote $rows rows"
exit 0
# vim: set noet ts=4 sw=4:
