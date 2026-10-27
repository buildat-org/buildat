#!/bin/bash
# apps/sample_wasm: [CLIENT_WASM] step 1, the pipeline with a toy module.
# The server builds main/wasm/ to a .wasm at its start and serves it; the
# client validates it, (natively) translates it with wasm2c, compiles and
# loads it, and the app's client_lua calls it: numbers both ways, a
# buffer written, changed and read back, Lua's wrong calls refused, two
# traps (an endless recursion, a read past the memory) and a call after
# them. Natively it runs twice: the first builds on both sides (the
# server's .wasm taken out of the app's cache, the client's cache a fresh
# one), the second finds both built; then a server with no clang and wasm
# linker refuses the module. The times are printed.
#
#   apps/sample_wasm/check.sh          # the native client
#   apps/sample_wasm/check.sh web      # the web client, headless Chrome
#
# tier: quick
# cost: 30s
# covers: src/server/wasm_build.cpp src/lua_bindings/wasm.cpp src/interface/wasm_api.h 3rdparty/wabt/** apps/sample_wasm/** builtin/client_data/**
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp sample_wasm
t=$CHECK_TMP
# The server's builds of this app's wasm/, under the checks' cache
rm -f "$BUILDAT_CACHE_PATH"/apps/sample_wasm/rccpp_build/wasm/*.wasm

# What the client's log has to say about the module, natively and on the web
client_lines()
{
	local log=$1
	# The logger's tag is the name's first eight letters
	grep -aE "sample_w: |wasm main: " "$log" | sed 's/.*\(sample_w: \|wasm main: \)/\1/'
	grep -aq "sample_w: wasm done: ok" "$log" ||
		fail "the module's calls did not all come back right ($log)"
	grep -aq "wasm main: reversed the buffer" "$log" ||
		fail "the module's log line did not reach the client's log"
}

if [ "${1:-}" = web ]; then
	cat > "$t/steps.json" <<'EOF'
[
	["nav", "${URL}"],
	["waitlog", "wasm done:", 120]
]
EOF
	"$here/util/web_drive.sh" chrome sample_wasm "$t/steps.json" "$t/web" > "$t/drive.log" 2>&1 ||
		{ tail -20 "$t/drive.log"; fail "the web drive failed ($t/web)"; }
	grep -a " I wasm    : " "$t/web/server.log" | sed 's/.*wasm    : //'
	client_lines "$t/web/page.log"
	grep -aq "ready (the browser's instance)" "$t/web/page.log" ||
		fail "not the browser's own instance"
	echo "PASS: the web client ran the server-built wasm"
	exit 0
fi

cd "$here/Build"
# One run: a server, a client with the given cache, the module's lines
run()
{
	local n=$1
	start_server "$t/srv$n.log" "Listening at" 120 auto bin/buildat_server \
			-m ../apps/sample_wasm -l 3 || fail "the server did not come up"
	CHECK_PIDS+=($SERVER_PID)
	printf 'wait_log 60000 wasm done:\nquit\n' > "$t/cmds$n.txt"
	run_client 60 "$t/cli$n.log" timeout 120 bin/buildat -C "$t/client_cache" \
			-s localhost:$SERVER_PORT -w 320x240 -l 3 -c @"$t/cmds$n.txt"
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
	echo "-- run $n"
	grep -a " I wasm    : " "$t/srv$n.log" | sed 's/.*wasm    : //'
	client_lines "$t/cli$n.log"
}
run 1
grep -aq "built wasm/ in" "$t/srv1.log" || fail "the server did not build wasm/"
grep -aq "wasm main: compiled in" "$t/cli1.log" || fail "the client did not compile it"
run 2
grep -aq "wasm/ is built (cache hit)" "$t/srv2.log" || fail "the server built wasm/ again"
grep -aq "wasm main: compiled module from the cache" "$t/cli2.log" ||
	fail "the client compiled it again"
# A server with no clang and wasm linker refuses the module, saying so
rm -f "$BUILDAT_CACHE_PATH"/apps/sample_wasm/rccpp_build/wasm/*.wasm
mkdir -p "$t/nohome"
env -u EMSDK -u RUSTUP_HOME -u BUILDAT_WASM_CC -u BUILDAT_WASM_LD \
		HOME="$t/nohome" PATH=/nonexistent /usr/bin/timeout 60 \
		bin/buildat_server -m ../apps/sample_wasm -l 3 -P "$SERVER_PORT" \
		> "$t/srv3.log" 2>&1
grep -aq "has wasm/, and this server has no clang and wasm linker.*the module is refused" \
		"$t/srv3.log" || fail "a server with no toolchain did not refuse the module ($t/srv3.log)"
grep -aq "Listening at" "$t/srv3.log" && fail "a server with no toolchain started the app"
echo "-- run 3, no toolchain"
grep -a " E wasm    : " "$t/srv3.log" | sed 's/.*wasm    : //' | cut -c1-120
echo "PASS: built, compiled, called and trapped; both caches hit on the second run; refused with no toolchain"
