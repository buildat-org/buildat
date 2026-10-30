#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-10-30)
# covers: builtin/kit/** apps/sample_kit/** src/wasm/engine.cpp src/server/wasm_module.cpp util/prebuild_wasm.py
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
#   5. The box prebuilt as util/package.sh puts it into an archive's cache
#      (util/prebuild_wasm.py, meta.json's "wasm_box"), named as the
#      server names it; a server with no wasm toolchain runs Kit on it.
# With `local`: sample_kit's server in the page (?local=sample_kit,
# util/build_web_server.sh sample_kit, the box built by
# util/web_server.cmake) in headless Chrome: the button opens the door,
# the runaway is stopped on the browser's wasm, and the button closes it.
#
#   util/kit_runtime_check.sh
#   util/kit_runtime_check.sh local
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
if [ "${1:-}" = local ]; then
	[ -f "$here/web/local/sample_kit/buildat_server.wasm" ] ||
		skip "no web/local/sample_kit (util/build_web_server.sh sample_kit)"
	check_tmp kit_local; t=$CHECK_TMP
	export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9
	# apps/play serves the page, isolated for ?local, and web/local/
	cd "$here/Build"
	BUILDAT_LUANTI_LIST=http://127.0.0.1:9 start_server "$t/play.log" \
			"STATUS Listening" 120 auto bin/buildat_server -m ../apps/play \
			-D "$t/play" -C "$t/play.cache" -W "$here/web" -l 3 ||
		fail "the page's server ($t/play.log)"
	CHECK_PIDS+=($SERVER_PID)
	cat > "$t/steps.json" <<'EOF'
[
	["nav", "${URL}"],
	["waitlog", "local: asking the player's name", 60], ["type", "tester"], ["key", "Enter"],
	["waitlog", "replicated: entity 4 open = false", 120],
	["eval", "'isolated ' + crossOriginIsolated"],
	["key", "b"],
	["waitlog", "replicated: entity 4 open = true", 30],
	["key", "r"],
	["waitlog", "server: .*Entity 7's runaway disabled", 30],
	["key", "b"],
	["waitlog", "replicated: entity 4 open = false", 30]
]
EOF
	WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/?local=sample_kit" \
		"$here/util/web_drive.sh" chrome sample_kit "$t/steps.json" "$t/local" > "$t/drive.log" 2>&1 ||
		{ tail -20 "$t/drive.log"; fail "the drive failed ($t/local)"; }
	page=$t/local/page.log
	grep -a "eval:" "$t/drive.log" | cut -c 1-200
	grep -a "server: .*\(wasm kit\| kit \| main \)" "$page" |
		sed 's/.*server: *//' | cut -c1-140
	grep -q "isolated true" "$t/drive.log" || fail "the page was not cross-origin isolated"
	for want in "server: .*kit: box/ is built with this server" \
			"server: .*sample_kit: at start the counter is 0, the door open false" \
			"server: .*button 3: pressed by player:p" \
			"server: .*door 4: opened by player:p" \
			"server: .*Entity 7's runaway disabled: on_use ran past its budget" \
			"server: .*door 4: closed by player:p"; do
		grep -aq "$want" "$page" || fail "no \"$want\" in $page"
	done
	echo "PASS: sample_kit with its server in the page: the box built with the server, the wiring and the meter on the browser's wasm"
	exit 0
fi
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
echo "ok: state over a restart, the compiled box"

# 5. The box as an archive carries it: util/prebuild_wasm.py names it as
# the server did, and in rccpp_build/wasm/ (an archive's cache/; what a
# boxed server reads as built before, -r) it serves a server with no wasm
# toolchain
h=$(grep -ao "kit: \(built box/ in [0-9]* ms\|box/ is built (cache hit)\): [^ ]*\.wasm" "$s" |
	sed 's|.*/\([0-9a-f]\{40\}\)\.wasm|\1|' | tail -1)
[ -n "$h" ] || fail "no name of the box's .wasm in $s"
em=${EMSDK:-$HOME/emsdk}/upstream/bin
python3 -I "$here/util/prebuild_wasm.py" "$(command -v clang || echo "$em/clang")" \
		"$(command -v wasm-ld || echo "$em/wasm-ld")" "$here/src/interface" \
		"$t/pre" "$here/builtin/kit" > "$t/pre.log" 2>&1 ||
	fail "prebuild_wasm.py failed ($t/pre.log)"
[ -f "$t/pre/$h.wasm" ] || fail "prebuild_wasm.py did not name it $h ($t/pre.log)"
own=$BUILDAT_CACHE_PATH/apps/sample_kit/rccpp_build/wasm/$h.wasm
pre=$t/rccpp_build/wasm/$h.wasm
[ -f "$own" ] || fail "the box is not at $own"
mkdir -p "$(dirname "$pre")" "$t/home"
mv "$own" "$t/own.wasm" && cp "$t/pre/$h.wasm" "$pre" || fail "could not place $pre"
start_server "$t/srv3.log" "sample_kit: at start the counter is|Kit is not hosted" 120 auto \
	env HOME="$t/home" EMSDK="$t/nowhere" RUSTUP_HOME="$t/nowhere" \
	BUILDAT_WASM_CC= BUILDAT_WASM_LD= BUILDAT_CHECK_WASM_INTERPRETER=1 \
	bin/buildat_server -m ../apps/sample_kit -r "$t/rccpp_build" -l 3
CHECK_PIDS+=($SERVER_PID)
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
mv "$t/own.wasm" "$own"
grep -a "No wasm toolchain\|kit: box/\|sample_kit: at start" "$t/srv3.log" | sed "s/^.* [IEW] /  /" | cut -c 1-140
want "$t/srv3.log" "No wasm toolchain" "kit: box/ is in the shared build" \
	"sample_kit: at start the counter is 4"
echo "PASS: Kit's runtime: wiring, client actions and their refusals, replication, a routed voxel write, the budget and a loop cut, state over a restart; the box prebuilt as an archive carries it"
# vim: set noet ts=4 sw=4:
