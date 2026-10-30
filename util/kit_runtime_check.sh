#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-10-30)
# covers: builtin/kit/** apps/sample_kit/** src/wasm/engine.cpp src/server/wasm_module.cpp
# [KIT] stage 2, Kit's runtime, on apps/sample_kit and a scripted client:
#   1. The wiring fires: a client uses the button, which opens the door
#      (its voxel air, its shared "open" replicated to the client), and
#      the door's move reaches the counter, `by` the player all the way.
#   2. Clients act, components react: a use out of range, a use of an
#      entity with nothing usable on it and packets that name a signal are
#      refused or go nowhere; a dig at the door is routed to it, which
#      keeps its voxel.
#   3. The budget: the runaway component is stopped and disabled, and the
#      button and the door go on; the relays' loop is cut and named; a
#      Lua error is logged and the box goes on.
#   4. A restart: the counter's count, the door's state and the runaway's
#      disablement are the save's runtime row, apart from its authored row.
# The first run is the box in WAMR's interpreter alone; the second waits
# for the compiled module (wasm2c's), and has a Lua error and a second
# runaway there.
#
#   util/kit_runtime_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_runtime; t=$CHECK_TMP
save="$BUILDAT_USER_PATH/apps/sample_kit/saves/world"
rm -rf "$save"
cd "$here/Build"

# One server and one client: the client's commands in $t/<n>.cmds
run() # <n> [env...]
{
	local n=$1
	shift
	start_server "$t/srv$n.log" "Listening at" 300 auto env "$@" \
		bin/buildat_server -m ../apps/sample_kit -l 3 ||
		fail "the server did not come up ($t/srv$n.log)"
	CHECK_PIDS+=($SERVER_PID)
	if [ $# = 0 ]; then
		wait_for_log "$t/srv$n.log" "wasm kit: (moved to the compiled module|compiled module from the cache|ready \\(compiled\\))" 300 ||
			fail "the box was not compiled ($t/srv$n.log)"
	fi
	set -- "$n"
	run_client 60 "$t/cli$1.log" timeout 120 bin/buildat -C "$t/client_cache" \
		-s localhost:$SERVER_PORT -w 320x240 -l 3 -c @"$t/$1.cmds" ||
		fail "client $1 failed ($t/cli$1.log, $t/srv$1.log)"
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
	grep -a " kit \| main \| wasm kit" "$t/srv$1.log" |
		sed 's/^.*\(kit\|main\) *: /  /' | cut -c1-140
}
want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}

# Every key's work is seen by the client before the next: the door's
# replicated state after b, and after the rest, which the server takes
# in order, b again
cat > "$t/1.cmds" <<'EOF'
wait_log 60000 replicated: entity 4 open = false
keypress b
wait_log 30000 replicated: entity 4 open = true
keypress f
frames 2
keypress c
frames 2
keypress s
wait_log 10000 sent the signal packets
keypress e
frames 2
keypress r
frames 2
keypress d
frames 2
keypress b
wait_log 60000 replicated: entity 4 open = false
quit
EOF
run 1 BUILDAT_CHECK_WASM_INTERPRETER=1
s=$t/srv1.log
grep -aq "wasm kit: ready (interpreter): no C compiler" "$s" ||
	fail "run 1 is not the interpreter's ($s)"
want "$s" "sample_kit: at start the counter is 0, the door open false" \
	"Entity 3 used by p" "button 3: pressed by player:p" \
	"door 4: opened by player:p" "counter 5: count 1 by player:p" \
	"door 4: closed by player:p" "counter 5: count 2 by player:p" \
	"A use of entity 6 by peer" "refused: out of range" \
	"A use of entity 5 by peer" "refused: no such object" \
	"Entity 7's runaway disabled: on_use ran past its budget" \
	"A signal loop cut: entity" \
	"Entity 10's faulty, on_use: faulty:8: attempt to index local 't' (a nil value)" \
	"sample_kit: a dig at the door: routed to its owner" \
	"door 4: kept its voxel from player:p" \
	"sample_kit: the door's voxel is air"
grep -aq "counter 5: count 3" "$s" && fail "the counter counted a signal a client sent ($s)"
# The Lua error is recovered in the box; only the runaway needs a new one
[ "$(grep -ac "A new box after" "$s")" = 1 ] ||
	fail "not one new box, for the runaway alone ($s)"
grep -a "sample_kit: the door's voxel is" "$s" | sed 's/.*: the/  the/' | tr '\n' ' '
echo
[ "$(grep -a "sample_kit: the door's voxel is" "$s" | tail -1 | sed 's/.* is //')" = stone ] ||
	fail "the door's voxel is not stone at the end ($s)"
echo "ok: the wiring, the refusals, the budget, the loop, the routed write"

# The save's two rows of Kit's
db=$(ls "$save"/*.sqlite 2>/dev/null | head -1)
[ -n "$db" ] || fail "no database in $save"
rows=$(sqlite3 "$db" "SELECT key FROM store WHERE store = 'kit' ORDER BY key" | tr '\n' ' ')
[ "$rows" = "authored runtime " ] || fail "kit's rows are \"$rows\""
sqlite3 "$db" "SELECT value FROM store WHERE store = 'kit' AND key = 'authored'" |
	grep -q '"presses"' && fail "runtime state in the authored row"

cat > "$t/2.cmds" <<'EOF'
wait_log 60000 replicated: entity 4 open = false
keypress b
wait_log 30000 replicated: entity 4 open = true
keypress e
frames 2
keypress h
frames 2
keypress b
wait_log 60000 replicated: entity 4 open = false
quit
EOF
run 2
s=$t/srv2.log
want "$s" "sample_kit: at start the counter is 2, the door open false" \
	"Entity 7's runaway stays disabled" "counter 5: count 3 by player:p" \
	"Entity 10's faulty, on_use: faulty:8: attempt to index local 't' (a nil value)" \
	"Entity 11's runaway disabled: on_use ran past its budget" \
	"counter 5: count 4 by player:p"
[ "$(grep -ac "A new box after" "$s")" = 1 ] ||
	fail "run 2: not one new box, for the runaway alone ($s)"
grep -aq "the composition's first start" "$s" && fail "the composition was read again ($s)"
echo "PASS: Kit's runtime: wiring, client actions and their refusals, replication, a routed voxel write, the budget and a loop cut, state over a restart"
# vim: set noet ts=4 sw=4:
