#!/bin/bash
# apps/sample_rust: [SERVER_WASM] a module in Rust on both sides. main/'s
# server half is a .wasm (meta.json's "server_wasm", main/server/), its
# client the engine's default client_main with main/wasm/, both built by
# the server with cargo and sharing main/shared/. Space in the client
# sends "main:key"; the server's .wasm bumps counter/'s count (a call
# between wasm modules; the count in counter/'s own storage) and answers
# "main:move", which moves the client's cube. The server's .wasm also
# sets voxels in a world of its scene and reads them back. endless/'s
# init() never returns: the meter stops it and the server goes on.
#
# Natively: two runs, the count going on from the first in the second (the
# storage survived the restart), the cube's place in a screenshot before
# and after a key; util/prebuild_wasm.py naming main's .wasm as the server
# does, and touching main/server/ leaving the client .wasm's name as it was
# while touching main/shared/ changes it; then a module whose .wasm imports what its meta.json
# does not grant is refused, by name, and a server with no cargo refuses
# the Rust modules, by name. With `web`: the same keys in the web client, headless
# Chrome, against a native server.
#
#   apps/sample_rust/check.sh        # the native client
#   apps/sample_rust/check.sh web    # the web client
#
# tier: quick
# cost: 40s (2026-10-28)
# covers: src/server/wasm_module.cpp src/server/wasm_imports.h src/server/wasm_build.cpp src/server/state.cpp src/wasm/** src/interface/wasm_server_api.h src/interface/rust/** builtin/loader/loader.cpp util/prebuild_wasm.py
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
web=0
for a in "$@"; do
	case "$a" in
		web) web=1 ;;
		*) echo "usage: $0 [web]" >&2; exit 2 ;;
	esac
done
cargo=$(command -v cargo || echo "$HOME/.cargo/bin/cargo")
[ -x "$cargo" ] || skip "no cargo"
[ -d "$("$(dirname "$cargo")/rustc" --print target-libdir --target wasm32-unknown-unknown 2>/dev/null)" ] ||
	skip "no wasm32-unknown-unknown target (rustup target add wasm32-unknown-unknown)"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp sample_rust
t=$CHECK_TMP

# The cube's middle (orange pixels') x in a screenshot, in pixels
cube_x()
{
	python3 - "$1" <<'EOF' || fail "$1: no cube in it"
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
w, h = im.size
xs = [x for y in range(0, h, 2) for x in range(w)
		if (lambda p: p[0] > 1.3 * p[1] and p[0] > 60)(im.getpixel((x, y)))]
if not xs:
	sys.exit(1)
print(sum(xs) // len(xs))
EOF
}

# The server's lines a run needs: voxels read back, the endless module
# stopped, and a key answered after it
server_lines()
{
	local log=$1 want
	grep -a " wasm    : wasm \(main\|counter\|endless\): " "$log" |
		sed 's/.*wasm    : //' | cut -c1-120
	for want in "wasm main: voxels: 32 read back, 17 of them rock" \
			"wasm endless: stopped: init ran past its budget" \
			"wasm main: key from peer "; do
		grep -aq "$want" "$log" || fail "no \"$want\" in $log"
	done
	grep -a "wasm \(main\|counter\): .*trap" "$log" && fail "a trap in $log"
	return 0
}

if [ $web = 1 ]; then
	cat > "$t/steps.json" <<'EOF'
[
	["nav", "${URL}"],
	["waitlog", "drew a cube", 120],
	["key", "Space"],
	["waitlog", "moved: count", 30],
	["wait", 500],
	["shot", "${OUT}/after.png"]
]
EOF
	"$here/util/web_drive.sh" chrome sample_rust "$t/steps.json" "$t/web" > "$t/drive.log" 2>&1 ||
		{ tail -20 "$t/drive.log"; fail "the web drive failed ($t/web)"; }
	server_lines "$t/web/server.log"
	grep -a "wasm main: " "$t/web/page.log" | sed 's/.*wasm main: /wasm main: /' | cut -c1-120
	grep -aq "wasm main: ready (the browser's instance)" "$t/web/page.log" ||
		fail "not the browser's own instance"
	grep -aq "wasm main: moved: count " "$t/web/page.log" || fail "the cube was not moved"
	cube_x "$t/web/after.png" > /dev/null
	echo "PASS: sample_rust on the web: a key to the server's .wasm, its answer moving the cube"
	exit 0
fi

cd "$here/Build"
# One run: keys pressed, each answered; the counts the server gave
run()
{
	local n=$1 keys=$2 k cmds=
	for k in $(seq "$keys"); do
		cmds+="keypress space
wait_log 10000 moved: count
delay 300
screenshot $t/after$n.$k.png
"
	done
	start_server "$t/srv$n.log" "Listening at" 180 auto bin/buildat_server \
			-m ../apps/sample_rust -l 3 || fail "the server did not come up"
	CHECK_PIDS+=($SERVER_PID)
	cat > "$t/cmds$n.txt" <<EOF
wait_log 60000 drew a cube
delay 300
screenshot $t/before$n.png
${cmds}quit
EOF
	run_client 60 "$t/cli$n.log" timeout 120 bin/buildat -C "$t/client_cache" \
			-s localhost:$SERVER_PORT -w 320x240 -l 3 -c @"$t/cmds$n.txt"
	# The endless module is stopped by now, or by the server's next second
	wait_for_log "$t/srv$n.log" "wasm endless: stopped" 10
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
	echo "-- run $n"
	server_lines "$t/srv$n.log"
	grep -a "wasm main: " "$t/cli$n.log" | sed 's/.*wasm main: /wasm main: /' | cut -c1-120
	[ "$(grep -ac "wasm main: moved: count" "$t/cli$n.log")" = "$keys" ] ||
		fail "not $keys moves in $t/cli$n.log"
}
count_after()
{
	grep -a "wasm main: key from peer" "$1" | tail -1 | sed 's/.*count \([0-9]*\),.*/\1/'
}

run 1 2
c1=$(count_after "$t/srv1.log")
# The cube moved with each key: x -1.5, 0, 1.5 in turn, so each key moves it
x0=$(cube_x "$t/before1.png") x1=$(cube_x "$t/after1.1.png") x2=$(cube_x "$t/after1.2.png")
echo "the cube's x in pixels: $x0, $x1, $x2"
[ "$x0" != "$x1" ] && [ "$x1" != "$x2" ] || fail "the cube did not move ($x0, $x1, $x2)"

run 2 1
grep -aq "counter: the count is $c1\$" "$t/srv2.log" ||
	fail "counter did not start at $c1 after the restart ($t/srv2.log)"
[ "$(count_after "$t/srv2.log")" = $((c1 + 1)) ] ||
	fail "the count after the restart is not $((c1 + 1)) ($t/srv2.log)"

# [SERVER_WASM_CLIENT_REHASH] A .wasm's name (its key's hash) in a server
# log: main's wasm/ or server/
wasm_name()
{
	grep -a "wasm    : main: \(built $2/ (Rust) in [0-9]* ms\|$2/ is built (cache hit)\): " "$1" |
		sed 's|.*/\([0-9a-f]\{40\}\)\.wasm.*|\1|' | tail -1
}
w1=$(wasm_name "$t/srv1.log" wasm) s1=$(wasm_name "$t/srv1.log" server)
[ -n "$w1" ] && [ -n "$s1" ] || fail "no wasm/ or server/ name in $t/srv1.log"
# util/prebuild_wasm.py names them as the server does
python3 -I "$here/util/prebuild_wasm.py" none none "$here/src/interface" "$t/pre" \
		"$here/apps/sample_rust/main" > "$t/pre.log" 2>&1 || fail "prebuild_wasm.py failed ($t/pre.log)"
[ -f "$t/pre/$w1.wasm" ] && [ -f "$t/pre/$s1.wasm" ] ||
	fail "prebuild_wasm.py's names are not the server's $w1, $s1 ($t/pre.log)"
# A copy of the app with one crate's source touched: server/ leaves the
# client's .wasm as it was (no client fetches it again), shared/ does not
touched()
{
	rm -rf "$t/app"
	cp -r "$here/apps/sample_rust" "$t/app"
	echo "// touched" >> "$t/app/main/$1/src/lib.rs"
	start_server "$t/srv_$1.log" "Listening at" 180 auto bin/buildat_server \
			-m "$t/app" -l 3 ||
		{ kill -INT "$SERVER_PID" 2>/dev/null; echo "no server ($t/srv_$1.log)" >&2; return 1; }
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
	wasm_name "$t/srv_$1.log" wasm
}
w_server=$(touched server) w_shared=$(touched shared)
echo "-- client .wasm: $w1, server/ touched $w_server, shared/ touched $w_shared"
[ "$w_server" = "$w1" ] || fail "touching server/ changed the client's .wasm ($t/srv_server.log)"
[ -n "$w_shared" ] && [ "$w_shared" != "$w1" ] ||
	fail "touching shared/ did not change the client's .wasm ($t/srv_shared.log)"

# A module importing what its meta.json does not grant: refused, by name,
# and the server does not start the app
mkdir -p "$t/ungranted/bad/server/src"
cat > "$t/ungranted/bad/meta.json" <<'EOF'
{"engine_api": 2, "disable_cpp": true, "server_wasm": {"source": "server", "imports": ["events"]}}
EOF
cat > "$t/ungranted/bad/server/Cargo.toml" <<'EOF'
[package]
name = "bad"
version = "0.1.0"
edition = "2021"
[lib]
crate-type = ["cdylib"]
[dependencies]
buildat_wasm_server = "0.1"
EOF
cat > "$t/ungranted/bad/server/src/lib.rs" <<'EOF'
#![no_std]
#[no_mangle]
pub extern "C" fn init() {
	buildat_wasm_server::storage_set(b"k", b"v");
}
EOF
/usr/bin/timeout 120 bin/buildat_server -m "$t/ungranted" -l 3 -P "$SERVER_PORT" > "$t/srv3.log" 2>&1
grep -aq 'bad: its .wasm is refused: imports buildat.storage_set, which meta.json does not grant ("server_wasm": {"imports": \["storage"\]})' "$t/srv3.log" ||
	fail "the ungranted import was not refused by name ($t/srv3.log)"
grep -aq "Listening at" "$t/srv3.log" && fail "a server started an app with a refused module"
echo "-- run 3, an ungranted import"
grep -a "bad: its .wasm is refused" "$t/srv3.log" | sed 's/.*wasm    : //' | cut -c1-160

# A server with no cargo refuses the app's Rust modules, by name
rm -f "$BUILDAT_CACHE_PATH"/apps/sample_rust/rccpp_build/wasm/*.wasm
mkdir -p "$t/nohome"
env -u RUSTUP_HOME -u CARGO_HOME -u BUILDAT_CARGO HOME="$t/nohome" \
		PATH=/nonexistent /usr/bin/timeout 120 \
		bin/buildat_server -m ../apps/sample_rust -l 3 -P "$SERVER_PORT" > "$t/srv4.log" 2>&1
grep -aq "has server/ in Rust, and this server has no cargo" "$t/srv4.log" &&
	grep -aq "no server .wasm; the module is refused" "$t/srv4.log" ||
	fail "a server with no cargo did not refuse the module ($t/srv4.log)"
grep -aq "Listening at" "$t/srv4.log" && fail "a server with no cargo started the app"
echo "-- run 4, no cargo"
grep -a " E wasm    : " "$t/srv4.log" | sed 's/.*wasm    : //' | cut -c1-120 | head -3
echo "PASS: sample_rust: Rust on both sides, a key answered by the server's .wasm through a call to another, its count kept across a restart, voxels set, an endless init() stopped while the server goes on, an ungranted import and a missing cargo refused by name"
