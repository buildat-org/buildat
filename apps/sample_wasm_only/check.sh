#!/bin/bash
# apps/sample_wasm_only: [CLIENT_WASM] step 7, a module whose client is
# only the engine's default client_main ("client_main": "wasm") and its
# .wasm, with no Lua of its own. main/wasm/main.c is handed a scene's
# handles in its first event, draws a cube into a node and turns it each
# frame; space changes its colour and sends "main:key", which echo/ (the
# server half) answers with "main:echo", given back to the .wasm as a
# packet event. Its log lines, and two screenshots: the cube drawn
# (orange), then green after the key.
# The same with `rust`: apps/sample_wasm_only_rust, a variant of this app
# whose main/wasm/ is the same module in Rust (buildat_wasm), built by the
# server with cargo; the same log lines and pictures, and two more of its
# calls of the client's classes (buildat_wasm's feature "client": a
# Vector3's length, a Text's text set and read back, Update's payload). Natively each runs
# twice: compiled (the first run moves from the interpreter to the
# compiled module) and with the compiler hidden (the interpreter for
# good). Then a server with no cargo refuses the Rust module, saying so.
#
#   apps/sample_wasm_only/check.sh [rust]        # the native client
#   apps/sample_wasm_only/check.sh web [rust]    # the web client, headless Chrome
#
# tier: quick
# cost: 30s (2026-10-27)
# covers: builtin/client_lua/client_lua/wasm_main.lua builtin/loader/loader.cpp src/server/wasm_build.cpp src/interface/wasm_api.h src/interface/rust/** apps/sample_wasm_only/** apps/sample_wasm_only_rust/**
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
web=0 app=sample_wasm_only
for a in "$@"; do
	case "$a" in
		web) web=1 ;;
		rust) app=sample_wasm_only_rust ;;
		*) echo "usage: $0 [web] [rust]" >&2; exit 2 ;;
	esac
done
if [ $app = sample_wasm_only_rust ]; then
	cargo=$(command -v cargo || echo "$HOME/.cargo/bin/cargo")
	[ -x "$cargo" ] || skip "no cargo"
	[ -d "$("$(dirname "$cargo")/rustc" --print target-libdir --target wasm32-unknown-unknown 2>/dev/null)" ] ||
		skip "no wasm32-unknown-unknown target (rustup target add wasm32-unknown-unknown)"
fi
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp sample_wasm_only
t=$CHECK_TMP

# The cube in a screenshot: the middle of the picture orange (red over
# green), then green
cube_is()
{
	python3 - "$1" "$2" <<'EOF' || fail "$1: the cube is not $2"
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
w, h = im.size
r = g = b = n = 0
for y in range(h * 2 // 5, h * 3 // 5):
	for x in range(w * 2 // 5, w * 3 // 5):
		p = im.getpixel((x, y))
		r, g, b, n = r + p[0], g + p[1], b + p[2], n + 1
r, g, b = r / n, g / n, b / n
print("%s: the middle is %.0f %.0f %.0f" % (sys.argv[1].split("/")[-1], r, g, b))
want = sys.argv[2]
ok = r > 1.3 * g and r > 20 if want == "orange" else g > 1.3 * r and g > 20
sys.exit(0 if ok else 1)
EOF
}

# The module's lines, natively and on the web: the logger's tag is the
# module's name, the client's own "wasm main: "
client_lines()
{
	local log=$1 want
	grep -aE "wasm main: " "$log" | sed 's/.*wasm main: /wasm main: /' | cut -c1-120
	for want in "wasm main: drew a cube, handed nodes: 8" \
			"wasm main: space: the colour is now 1" \
			"wasm main: the server answered echo: colour 1"; do
		grep -aq "$want" "$log" || fail "no \"$want\" in $log"
	done
	# The Rust one also makes calls of the client's classes (buildat_wasm's
	# feature "client", [CLIENT_WASM_BINDINGS])
	if [ $app = sample_wasm_only_rust ]; then
		for want in "wasm main: rust bindings: a Vector3's length 5, a Text reads back: true, its name empty: true" \
				"wasm main: rust bindings: Update's TimeStep > 0: true"; do
			grep -aq "$want" "$log" || fail "no \"$want\" in $log"
		done
	fi
	grep -aE "default client_main|wasm main: trap|frame: " "$log" &&
		fail "the default client_main said something went wrong ($log)"
	return 0
}

if [ $web = 1 ]; then
	cat > "$t/steps.json" <<'EOF'
[
	["nav", "${URL}"],
	["waitlog", "drew a cube", 120],
	["wait", 500],
	["shot", "${OUT}/before.png"],
	["key", "Space"],
	["waitlog", "the server answered echo", 30],
	["wait", 500],
	["shot", "${OUT}/after.png"]
]
EOF
	"$here/util/web_drive.sh" chrome $app "$t/steps.json" "$t/web" > "$t/drive.log" 2>&1 ||
		{ tail -20 "$t/drive.log"; fail "the web drive failed ($t/web)"; }
	grep -a " I wasm    : " "$t/web/server.log" | sed 's/.*wasm    : //'
	client_lines "$t/web/page.log"
	grep -aq "wasm main: ready (the browser's instance)" "$t/web/page.log" ||
		fail "not the browser's own instance"
	grep -aq "key from the client's wasm: 1" "$t/web/server.log" ||
		fail "the server did not get the module's packet"
	cube_is "$t/web/before.png" orange
	cube_is "$t/web/after.png" green
	echo "PASS: $app on the web: drawn by its .wasm through the default client_main, a key answered, packets both ways"
	exit 0
fi

cd "$here/Build"
# One run: a server, a client with the checks' cache for its compiles (and
# the environment given), the module's lines and pictures
run()
{
	local n=$1
	shift
	start_server "$t/srv$n.log" "Listening at" 120 auto bin/buildat_server \
			-m ../apps/$app -l 3 || fail "the server did not come up"
	CHECK_PIDS+=($SERVER_PID)
	cat > "$t/cmds$n.txt" <<EOF
wait_log 60000 drew a cube
delay 500
screenshot $t/before$n.png
keypress space
wait_log 10000 the server answered echo
delay 500
screenshot $t/after$n.png
quit
EOF
	run_client 60 "$t/cli$n.log" timeout 120 env "$@" bin/buildat -C "$t/client_cache" \
			-s localhost:$SERVER_PORT -w 320x240 -l 3 -c @"$t/cmds$n.txt"
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
	echo "-- run $n"
	grep -a " I wasm    : " "$t/srv$n.log" | sed 's/.*wasm    : //'
	client_lines "$t/cli$n.log"
	grep -aq "key from the client's wasm: 1" "$t/srv$n.log" ||
		fail "the server did not get the module's packet"
	cube_is "$t/before$n.png" orange
	cube_is "$t/after$n.png" green
}
run 1
if [ $app = sample_wasm_only_rust ]; then
	grep -aqE "main: (built wasm/ \(Rust\) in|wasm/ is built \(cache hit\))" "$t/srv1.log" ||
		fail "the server did not build the Rust wasm/"
fi
grep -aqE "wasm main: (moved to the compiled module|compiled module from the cache)" "$t/cli1.log" ||
	fail "not compiled in run 1 ($t/cli1.log)"
run 2 BUILDAT_CHECK_WASM_INTERPRETER=1
grep -aq "wasm main: ready (interpreter): no C compiler" "$t/cli2.log" ||
	fail "not the interpreter in run 2 ($t/cli2.log)"
if [ $app = sample_wasm_only_rust ]; then
	# A server with no cargo refuses the module, saying so
	rm -f "$BUILDAT_CACHE_PATH"/apps/$app/rccpp_build/wasm/*.wasm
	mkdir -p "$t/nohome"
	env -u RUSTUP_HOME -u CARGO_HOME -u BUILDAT_CARGO HOME="$t/nohome" \
			PATH=/nonexistent /usr/bin/timeout 60 \
			bin/buildat_server -m ../apps/$app -l 3 -P "$SERVER_PORT" \
			> "$t/srv3.log" 2>&1
	grep -aq "main has wasm/ in Rust, and this server has no cargo" "$t/srv3.log" &&
		grep -aq "main: no wasm; the module is refused" "$t/srv3.log" ||
		fail "a server with no cargo did not refuse the module ($t/srv3.log)"
	grep -aq "Listening at" "$t/srv3.log" && fail "a server with no cargo started the app"
	echo "-- run 3, no cargo"
	grep -a " E wasm    : " "$t/srv3.log" | sed 's/.*wasm    : //' | cut -c1-120
fi
echo "PASS: $app natively, compiled and in the interpreter: drawn by its .wasm through the default client_main, a key answered, packets both ways"
