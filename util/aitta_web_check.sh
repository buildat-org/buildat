#!/bin/bash
# tier: full
# cost: ~25 s (2026-10-28)
# covers: apps/aitta/main/main.cpp src/server/confine.cpp src/server/web/pre.js src/client/web/index.html client/core/aitta/init.lua builtin/network/network.cpp
# [WEB_LOCAL_AITTA]: a package whose server modules are .wasm, published
# to a local (boxed) Aitta and played in the page.
#   1. apps/sample_rust published as tester/rusty: Aitta builds its .wasm
#      from the release's source, in the build's box, and lists it with
#      "web" and four .wasm, served with CORS and CORP, each its sha256.
#   2. A hostile package whose build script reads a file in Aitta's own
#      directory, /etc/passwd, /proc and Aitta's environment, writes into
#      Aitta's directory, and opens a TCP and a UDP socket (all of which
#      Aitta's box lets Aitta do but the TCP): each refused, which its
#      .wasm says.
#   3. A package with a C++ module: listed, not in the page.
#   4. A play server's page (headless Chrome) with that Aitta in its
#      settings, at #run=tester/rusty: installed, its .wasm fetched and
#      checked, the page at ?local=tester.rusty@1.0.0 runs the engine's
#      server for packages (web/local/_aitta) on it, the client joins it,
#      the cube drawn and a key answered by the server's .wasm on the
#      browser's wasm.
# Needs web/ (util/build_web.sh), web/local/_aitta
# (util/build_web_server.sh "$PWD/src/server/web/_aitta"), cargo with the
# wasm32-unknown-unknown target, and a display for the key's bind.
#   util/aitta_web_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
[ -f "$here/web/local/_aitta/buildat_server.wasm" ] ||
	skip "no web/local/_aitta (util/build_web_server.sh \"\$PWD/src/server/web/_aitta\")"
cargo=$(command -v cargo || echo "$HOME/.cargo/bin/cargo")
[ -x "$cargo" ] || skip "no cargo"
[ -d "$("$(dirname "$cargo")/rustc" --print target-libdir --target wasm32-unknown-unknown 2>/dev/null)" ] ||
	skip "no wasm32-unknown-unknown target"
check_tmp aitta_web; t=$CHECK_TMP
b="$here/Build/bin/buildat"
export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9
trap check_cleanup EXIT

cd "$here/Build"
AITTA_ENV_SECRET=1 start_server "$t/srv.log" "setup code" 60 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 ||
	fail "Aitta did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
grep -aq "The server is sandboxed" "$t/srv.log" || fail "Aitta is not boxed"
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
printf 'wait_log_any 30000 "id":2,\nquit\n' > "$t/reqs.cmds"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
	BUILDAT_AITTA_CODE=$code \
	BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}
{\"cmd\":\"set_settings\",\"settings\":{\"page_delay\":0}}" \
	timeout 90 "$b" -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$P -c @"$t/reqs.cmds" > "$t/bind.log" 2>&1
grep -aq 'ai: {"id":1,"ok":true' "$t/bind.log" || fail "the bind"

# publish <dir> <name>: the manifest written, packed, published
publish(){
	printf '{"author": "tester", "name": "%s", "version": "1.0.0", "kind": "app",
		"engine_api": 2, "audience": "everyone", "license_code": "MIT",
		"license_media": "CC0-1.0", "description": "a check"}\n' "$2" > "$1/meta.json"
	zip=$("$b" aitta pack "$1" "$t/key" "$t/out" 2>/dev/null) || fail "pack $2"
	"$b" aitta publish "$zip" 127.0.0.1:$P > "$t/pub_$2.out" 2>&1
	grep -q "listed: tester/$2/1.0.0" "$t/pub_$2.out" || fail "publish $2: $(cat "$t/pub_$2.out")"
}
# The list's release <name> as JSON
release(){
	curl -s "http://127.0.0.1:$P/api/v1/aitta/list" | python3 -c "
import json, sys
for r in json.load(sys.stdin)['releases']:
	if r['name'] == '$1': print(json.dumps(r))"
}

# 1.
mkdir -p "$t/rusty"
cp -r "$here/apps/sample_rust/main" "$here/apps/sample_rust/counter" \
	"$here/apps/sample_rust/endless" "$t/rusty/"
rm -rf "$t"/rusty/*/*/target
publish "$t/rusty" rusty
wait_for_log "$t/srv.log" "web build of tester/rusty/1.0.0: " 120 ||
	fail "no web build of rusty ($t/srv.log)"
grep -a "web build of tester/rusty/1.0.0: built" "$t/srv.log" ||
	fail "rusty's .wasm were not built: $(grep -a -A20 "web build of tester/rusty" "$t/srv.log" | tail -20)"
release rusty > "$t/rusty.json"
python3 - "$t/rusty.json" > "$t/wasm.list" <<'EOF' || fail "rusty's listing ($t/rusty.json)"
import json, sys
r = json.load(open(sys.argv[1]))
w = r["web_wasm"]
assert r["web"] is True and r["web_build"] == "built", r
assert sorted(w) == ["counter.server.wasm", "endless.server.wasm",
	"main.server.wasm", "main.wasm"], w
for k, v in sorted(w.items()):
	print(k, v)
EOF
cat "$t/wasm.list"
while read -r name sha; do
	curl -s -D "$t/h" -o "$t/$name" "http://127.0.0.1:$P/api/v1/aitta/wasm/$sha.wasm"
	tr -d '\r' < "$t/h" > "$t/h2"
	grep -qi "^Access-Control-Allow-Origin: \*" "$t/h2" &&
		grep -qi "^Cross-Origin-Resource-Policy: cross-origin" "$t/h2" &&
		grep -qi "^Content-Type: application/wasm" "$t/h2" ||
		fail "$name: not served for an isolated page ($(cat "$t/h2"))"
	[ "$(sha256sum < "$t/$name" | cut -d' ' -f1)" = "$sha" ] || fail "$name is not $sha"
done < "$t/wasm.list"
curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$P/api/v1/aitta/wasm/$(printf '%064d' 0).wasm" |
	grep -q 404 || fail "a .wasm no release names was served"
echo "ok: rusty's four .wasm built at publish, listed and served with CORS and CORP"

# 2. The build script's reach, written into the .wasm it builds: what
# Aitta's own box lets Aitta read and write (its records' directory, /etc,
# /proc, UDP) is not the build's
echo "the secret outside the build" > "$t/srv/apps/aitta/secret"
mkdir -p "$t/probe/probe/server/src"
echo '{"engine_api": 2, "disable_cpp": true, "server_wasm": {"source": "server", "imports": []}}' \
	> "$t/probe/probe/meta.json"
printf '%s\n%s\n' "$t/srv/apps/aitta/secret" "$t/srv/apps/aitta/written_by_build" \
	> "$t/probe/probe/server/paths.txt"
cat > "$t/probe/probe/server/Cargo.toml" <<'EOF'
[package]
name = "probe"
version = "0.1.0"
edition = "2021"
build = "build.rs"

[lib]
crate-type = ["cdylib"]
EOF
cat > "$t/probe/probe/server/build.rs" <<'EOF'
use std::io::Write;
fn main() {
	let dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
	let paths = std::fs::read_to_string(format!("{}/paths.txt", dir)).unwrap();
	let mut lines = paths.lines();
	let (secret, outside) = (lines.next().unwrap(), lines.next().unwrap());
	let r = |ok: bool| if ok { "allowed" } else { "refused" };
	let read = std::fs::read(secret).is_ok();
	let passwd = std::fs::read("/etc/passwd").is_ok();
	let proc_ = std::fs::read("/proc/self/environ").is_ok();
	let write = std::fs::write(outside, b"x").is_ok();
	let tcp = std::net::TcpStream::connect("127.0.0.1:80").is_ok() ||
		std::net::TcpListener::bind("127.0.0.1:0").is_ok();
	let udp = std::net::UdpSocket::bind("127.0.0.1:0").is_ok();
	let env = std::env::var("AITTA_ENV_SECRET").is_ok();
	let leaked = std::fs::read_to_string(secret).unwrap_or_default();
	let out = format!("{}/probe.rs", std::env::var("OUT_DIR").unwrap());
	let mut f = std::fs::File::create(out).unwrap();
	write!(f, "pub static REACH: &[u8] = b\"REACH read {} passwd {} proc {} write {} tcp {} udp {} env {} [{}]\";",
		r(read), r(passwd), r(proc_), r(write), r(tcp), r(udp), r(env), leaked.trim()).unwrap();
}
EOF
cat > "$t/probe/probe/server/src/lib.rs" <<'EOF'
#![no_std]
include!(concat!(env!("OUT_DIR"), "/probe.rs"));
#[no_mangle]
pub extern "C" fn probe() -> u32 { REACH.as_ptr() as u32 + REACH.len() as u32 }
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! { loop {} }
EOF
publish "$t/probe" probe
wait_for_log "$t/srv.log" "web build of tester/probe/1.0.0: " 120 ||
	fail "no web build of probe ($t/srv.log)"
grep -aq "web build of tester/probe/1.0.0: built" "$t/srv.log" ||
	fail "probe was not built: $(grep -a -A20 "web build of tester/probe" "$t/srv.log" | tail -20)"
sha=$(release probe | python3 -c "import json, sys; print(json.load(sys.stdin)['web_wasm']['probe.server.wasm'])")
curl -s -o "$t/probe.wasm" "http://127.0.0.1:$P/api/v1/aitta/wasm/$sha.wasm"
said=$(grep -ao "REACH [a-z ]*\[[^]]*\]" "$t/probe.wasm")
echo "the build script: $said"
[ "$said" = "REACH read refused passwd refused proc refused write refused tcp refused udp refused env refused []" ] ||
	fail "the build reached past its box: $said"
[ -e "$t/srv/apps/aitta/written_by_build" ] && fail "the build wrote outside its box"
echo "ok: a build script reads, writes and connects nowhere outside its box"

# 3.
mkdir -p "$t/cpp"
cp -r "$here/apps/sample_module_calls/test1" "$t/cpp/"
publish "$t/cpp" cpp
grep -aq "tester/cpp/1.0.0 in the page: no, the module test1 is C++" "$t/srv.log" ||
	fail "the C++ package not refused for the page ($t/srv.log)"
release cpp | grep -q '"web"' && fail "the C++ package has a web build"
echo "ok: a package with C++ is listed, not in the page"

# 4.
BUILDAT_LUANTI_LIST=http://127.0.0.1:9 start_server "$t/play.log" "Listening at" 120 auto \
	bin/buildat_server -m ../apps/play -D "$t/play" -C "$t/play.cache" -W "$here/web" -l 3 ||
	fail "the play server did not start"
CHECK_PIDS+=($SERVER_PID)
PP=$SERVER_PORT
curl -s "http://127.0.0.1:$PP/" | grep -q "var local_apps = \[.*_aitta" &&
	fail "the page offers the engine's _aitta as an app"
set_js="FS.writeFile('/buildat/user/starport.json', JSON.stringify({aittas: ['http://127.0.0.1:$P'], filters: {unreviewed: true}})); new Promise(r => Module.buildatSave(() => r('set')))"
cat > "$t/steps.json" <<J
[["nav", "http://127.0.0.1:$PP/"],
 ["waitlog", "launch_menu", 90],
 ["eval", "$set_js"],
 ["nav", "http://127.0.0.1:$PP/?again#run=tester/rusty"],
 ["waitlog", "Asking the user about", 90],
 ["wait", 1000],
 ["key", "Enter"],
 ["waitlog", "local: asking the player's name", 60],
 ["type", "tester"],
 ["key", "Enter"],
 ["waitlog", "local: tester.rusty@1.0.0, [0-9]+ files, 4 .wasm", 60],
 ["eval", "'isolated ' + crossOriginIsolated + ' at ' + location.search"],
 ["waitlog", "drew a cube", 120],
 ["key", "Space"],
 ["waitlog", "moved: count", 30]]
J
WEB_DRIVE_URL=http://127.0.0.1:$PP "$here/util/web_drive.sh" chrome play \
	"$t/steps.json" "$t/web" > "$t/web.out" 2>&1 ||
	fail "the web drive ($(tail -3 "$t/web.out"); $t/web)"
page=$t/web/page.log
grep -a "eval:" "$t/web.out" | cut -c 1-200
grep -a "server: .*wasm \(main\|counter\|endless\): " "$page" | sed 's/.*wasm    : //' | cut -c1-120
grep -q "isolated true at ?local=tester.rusty%401.0.0" "$t/web.out" ||
	fail "not the package's isolated page"
for want in "server: .*Loading module main from /installed/tester/rusty/1.0.0/main" \
		"server: .*wasm main: ready (the browser's instance)" \
		"server: .*wasm endless: stopped: init ran past its budget" \
		"server: .*wasm main: key from peer 1: count 1"; do
	grep -aq "$want" "$page" || fail "no \"$want\" in $page"
done
echo "PASS: Aitta builds a release's .wasm at publish in a box that reaches nothing else, lists and serves them for the page, refuses C++ for it; the page installs the release and runs it with the engine's server for packages, the client joined and a key answered"
