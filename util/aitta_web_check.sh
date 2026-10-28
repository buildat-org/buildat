#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-28)
# covers: apps/aitta/main/main.cpp src/server/confine.cpp src/server/web/pre.js src/server/web/post.js src/client/web/index.html client/core/aitta/init.lua builtin/network/network.cpp util/aitta_cpp_build.py
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
#   2b. A build script leaving a process in a session of its own and a
#      double-forked one: both end with the build.
#   2c. A build script starting processes without end: stopped at the
#      build's cap (64 tasks in its user namespace), the build failed,
#      Aitta answering meanwhile, nothing left.
#   2d. A build script making files without end (to 300000, past the
#      build's 200000): ended by the build's PID 1, which measures the job
#      directory each second (RLIMIT_FSIZE caps one file only).
#   2e. [AITTA_BUILD_MEM] A build script whose processes each touch memory
#      (16 x 96 MiB, past this Aitta's 1024 MiB for a build): ended by the
#      build's PID 1, which measures its processes (no cgroup here), Aitta
#      answering meanwhile, nothing left.
#   3. A package with a C++ module with cxxflags: listed, not in the page.
#   3b. [WEB_LOCAL_AITTA_CPP] A package with a C++ module: Aitta links its
#      own server from the kit (Build-webserver/aitta_kit) in the build's
#      box, checks it against the kit's and lists it ("web_server"), served
#      with CORS and CORP. Refused: EM_ASM, EM_JS, emscripten_run_script,
#      an import the engine has not (emscripten_vibrate), one it has under
#      another type, and an #include of a file outside the package (which
#      Aitta's box reads).
#   4. A play server's page (headless Chrome) with that Aitta in its
#      settings, at #run=tester/rusty: installed, its .wasm fetched and
#      checked, the page at ?local=tester.rusty@1.0.0 runs the engine's
#      server for packages (web/local/_aitta) on it, the client joins it,
#      the cube drawn and a key answered by the server's .wasm on the
#      browser's wasm. Then the C++ package, in headless Chrome and
#      headless WebKit: its own server .wasm run by local/_aitta's .js, its
#      C++ answering the client's packet.
#   5. 2b again where the host gives the build no PID namespace
#      (BUILDAT_BUILD_NO_PIDNS=1): not built, and nothing left. Aitta's
#      records copied to a second one, which has no kit: the C++ package
#      listed, not in the page.
#   6. 2b and 2e on a third Aitta under a systemd user scope with
#      Delegate=yes (where there is one): built in the build's cgroup, the
#      memory probe ended by the cgroup's OOM.
#   7. [AITTA_BUILD_QUEUE] On that Aitta, while a build runs, one author
#      publishes four more (the fourth refused: three wait at most) and
#      another one: the other author's is built next, round-robin, then
#      the first's.
# Needs web/ (util/build_web.sh), web/local/_aitta
# (util/build_web_server.sh "$PWD/src/server/web/_aitta", which makes the
# kit too), cargo with the wasm32-unknown-unknown target, a display for the
# key's bind, and Playwright's WebKit (util/web_drive.sh).
#   util/aitta_web_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
[ -f "$here/web/local/_aitta/buildat_server.wasm" ] ||
	skip "no web/local/_aitta (util/build_web_server.sh \"\$PWD/src/server/web/_aitta\")"
kit=$here/Build-webserver/aitta_kit
[ -f "$kit/kit.json" ] && cmp -s "$kit/ref/buildat_server.js" "$here/web/local/_aitta/buildat_server.js" ||
	skip "no kit of web/local/_aitta's build (util/build_web_server.sh \"\$PWD/src/server/web/_aitta\")"
cargo=$(command -v cargo || echo "$HOME/.cargo/bin/cargo")
[ -x "$cargo" ] || skip "no cargo"
[ -d "$("$(dirname "$cargo")/rustc" --print target-libdir --target wasm32-unknown-unknown 2>/dev/null)" ] ||
	skip "no wasm32-unknown-unknown target"
check_tmp aitta_web; t=$CHECK_TMP
b="$here/Build/bin/buildat"
export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9
trap check_cleanup EXIT

cd "$here/Build"
AITTA_ENV_SECRET=1 BUILDAT_AITTA_CPP_KIT=$kit BUILDAT_BUILD_MEMORY_MIB=1024 start_server "$t/srv.log" "setup code" 60 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 ||
	fail "Aitta did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
aitta_pid=$SERVER_PID
grep -aq "The server is sandboxed" "$t/srv.log" || fail "Aitta is not boxed"
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
"$b" aitta keygen "$t/key2" > "$t/pub2" 2>/dev/null || fail "keygen"
printf 'wait_log_any 30000 admin script: done\nwait_log_any 30000 "id":2,\nquit\n' > "$t/reqs.cmds"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
	BUILDAT_AITTA_CODE=$code BUILDAT_AITTA_ADMIN="add other checkpass2" \
	BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}
{\"cmd\":\"set_settings\",\"settings\":{\"page_delay\":0}}" \
	timeout 90 "$b" -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$P -c @"$t/reqs.cmds" > "$t/bind.log" 2>&1
grep -aq 'ai: {"id":1,"ok":true' "$t/bind.log" || fail "the bind"
# [AITTA_BUILD_QUEUE] A second author, for 2f
printf 'wait_log_any 30000 "id":1,\nquit\n' > "$t/reqs2.cmds"
BUILDAT_AITTA_NAME=other BUILDAT_AITTA_PASSWORD=checkpass2 \
	BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"other\",\"key\":\"$(cat "$t/pub2")\"}" \
	timeout 90 "$b" -o launch_ui=launch_menu -D "$t/cl2" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$P -c @"$t/reqs2.cmds" > "$t/bind2.log" 2>&1
grep -aq 'ai: {"id":1,"ok":true' "$t/bind2.log" || fail "the second author's bind"

# publish <dir> <name> [author key]: the manifest written, packed, published
pack(){
	printf '{"author": "%s", "name": "%s", "version": "1.0.0", "kind": "app",
		"engine_api": 2, "audience": "everyone", "license_code": "MIT",
		"license_media": "CC0-1.0", "description": "a check"}\n' "${3:-tester}" "$2" > "$1/meta.json"
	zip=$("$b" aitta pack "$1" "${4:-$t/key}" "$t/out" 2>/dev/null) || fail "pack $2"
	"$b" aitta publish "$zip" 127.0.0.1:$P > "$t/pub_$2.out" 2>&1
}
publish(){
	pack "$@"
	grep -q "listed: ${3:-tester}/$2/1.0.0" "$t/pub_$2.out" || fail "publish $2: $(cat "$t/pub_$2.out")"
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

# 2b. [AITTA_BUILD_LEFTOVERS] What a build script starts ends with the
# build: a process in a session of its own and a double-forked one, both
# sleeping, are gone once Aitta has the build's result
tok=aitta_linger_${t##*.}
mkdir -p "$t/linger/linger/server/src"
echo '{"engine_api": 2, "disable_cpp": true, "server_wasm": {"source": "server", "imports": []}}' \
	> "$t/linger/linger/meta.json"
sed 's/probe/linger/' "$t/probe/probe/server/Cargo.toml" > "$t/linger/linger/server/Cargo.toml"
cat > "$t/linger/linger/server/build.rs" <<EOF
use std::process::{Command, Stdio};
fn main() {
	for args in [&["-f", "sh", "-c", "sleep 600; :", "${tok}_setsid"][..],
			&["sh", "-c", "(sleep 600; :) &", "${tok}_fork"][..]] {
		let mut c = if args[0] == "-f" { Command::new("setsid") } else { Command::new(args[0]) };
		c.args(if args[0] == "-f" { args } else { &args[1..] });
		c.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
		assert!(c.status().unwrap().success());
	}
}
EOF
cat > "$t/linger/linger/server/src/lib.rs" <<'EOF'
#![no_std]
#[no_mangle]
pub extern "C" fn linger() -> u32 { 1 }
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! { loop {} }
EOF
publish "$t/linger" linger
wait_for_log "$t/srv.log" "web build of tester/linger/1.0.0: " 120 ||
	fail "no web build of linger ($t/srv.log)"
grep -aq "web build of tester/linger/1.0.0: built" "$t/srv.log" ||
	fail "linger was not built: $(grep -a -A20 "web build of tester/linger" "$t/srv.log" | tail -20)"
left=$(pgrep -f "${tok}_" | tr '\n' ' ')
[ -n "$left" ] && { CHECK_PIDS+=($left); fail "the build left processes: $left"; }
echo "ok: what a build script started ended with the build"

# 2c. [AITTA_BUILD_NPROC] A build script that starts processes without
# end (it stops itself at 2000, well past the build's cap, so it cannot
# hurt this machine): refused past the cap, the build fails, Aitta answers
# meanwhile, and nothing of it is left
mkdir -p "$t/forks/forks/server/src"
cp "$t/linger/linger/meta.json" "$t/forks/forks/meta.json"
sed 's/probe/forks/' "$t/probe/probe/server/Cargo.toml" > "$t/forks/forks/server/Cargo.toml"
cat > "$t/forks/forks/server/build.rs" <<EOF
use std::process::{Command, Stdio};
fn main() {
	let mut kids = Vec::new();
	while kids.len() < 2000 {
		match Command::new("sh").args(["-c", "sleep 600; :", "${tok}_bomb"])
				.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn() {
			Ok(c) => kids.push(c),
			Err(e) => panic!("FORKS stopped at {}: {}", kids.len(), e),
		}
	}
}
EOF
sed 's/linger/forks/' "$t/linger/linger/server/src/lib.rs" > "$t/forks/forks/server/src/lib.rs"
publish "$t/forks" forks
for i in $(seq 120); do
	grep -aq "web build of tester/forks/1.0.0: " "$t/srv.log" && break
	curl -s -m 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$P/api/v1/aitta/list" |
		grep -q 200 || fail "Aitta did not answer during the fork bomb's build"
	sleep 1
done
grep -aq "web build of tester/forks/1.0.0: built" "$t/srv.log" &&
	fail "the fork bomb was built: its 2000 processes had no cap"
grep -aq "web build of tester/forks/1.0.0: failed" "$t/srv.log" ||
	fail "no web build of forks ($t/srv.log)"
grep -aom1 "FORKS stopped at [0-9]*: .*" "$t/srv.log" ||
	fail "forks failed, not at the cap: $(grep -a -A20 "web build of tester/forks" "$t/srv.log" | tail -20)"
left=$(pgrep -f "${tok}_" | tr '\n' ' ')
[ -n "$left" ] && { CHECK_PIDS+=($left); fail "the fork bomb left processes: $left"; }
curl -s -m 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$P/api/v1/aitta/list" |
	grep -q 200 || fail "Aitta does not answer after the fork bomb"
echo "ok: a build's processes stop at its cap; the build failed, Aitta answered, nothing left"

# 2d. [WEB_LOCAL_AITTA_CPP] A build script filling its directory: ended
mkdir -p "$t/fill/fill/server/src"
cp "$t/linger/linger/meta.json" "$t/fill/fill/meta.json"
sed 's/probe/fill/' "$t/probe/probe/server/Cargo.toml" > "$t/fill/fill/server/Cargo.toml"
cat > "$t/fill/fill/server/build.rs" <<'EOF2'
fn main() {
	let dir = std::env::var("OUT_DIR").unwrap();
	for i in 0..300000 {
		if std::fs::write(format!("{}/{}", dir, i), b"").is_err() {
			panic!("FILL stopped at {}", i);
		}
	}
	panic!("FILL made all 300000");
}
EOF2
sed 's/linger/fill/' "$t/linger/linger/server/src/lib.rs" > "$t/fill/fill/server/src/lib.rs"
publish "$t/fill" fill
wait_for_log "$t/srv.log" "web build of tester/fill/1.0.0: " 120 ||
	fail "no web build of fill ($t/srv.log)"
grep -aq "the build: its directory went past 3072 MiB or 200000 files; ended" "$t/srv.log" ||
	fail "fill was not ended at its cap: $(grep -a -A20 "web build of tester/fill" "$t/srv.log" | tail -20)"
grep -aq "web build of tester/fill/1.0.0: failed" "$t/srv.log" || fail "fill was built"
grep -aq "FILL made all" "$t/srv.log" && fail "fill made all its files"
echo "ok: a build filling its directory is ended at its cap"

# 2e. [AITTA_BUILD_MEM] A build script whose processes touch memory, 4 MiB
# every 20 ms each, 16 of them to 96 MiB: 1.5 GiB at most (the probe's own
# stop, so a failed cap cannot hurt this machine), past the 1024 MiB this
# Aitta gives a build. It holds it 10 s, then fails by itself.
# mem_probe <name> <server log> <how it is ended>
mem_probe(){
	local avail
	avail=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)
	[ "$avail" -ge 3072 ] || fail "only $avail MiB available: the memory step needs 3 GiB"
	mkdir -p "$t/$1/$1/server/src"
	cp "$t/linger/linger/meta.json" "$t/$1/$1/meta.json"
	sed "s/probe/$1/" "$t/probe/probe/server/Cargo.toml" > "$t/$1/$1/server/Cargo.toml"
	cat > "$t/$1/$1/server/build.rs" <<EOF2
use std::process::{Command, Stdio};
fn main() {
	let me = std::env::args().next().unwrap();
	if std::env::var("MEM_CHILD").is_ok() {
		let mut held = Vec::new();
		for _ in 0..24 {
			held.push(vec![1u8; 4 << 20]);
			std::thread::sleep(std::time::Duration::from_millis(20));
		}
		std::thread::sleep(std::time::Duration::from_secs(600));
		return;
	}
	let mut kids = Vec::new();
	for _ in 0..16 {
		kids.push(Command::new(&me).env("MEM_CHILD", "1").arg("${tok}_mem")
			.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null())
			.spawn().unwrap());
	}
	std::thread::sleep(std::time::Duration::from_secs(10));
	panic!("MEM held 16 x 96 MiB for 10 s");
}
EOF2
	sed "s/linger/$1/" "$t/linger/linger/server/src/lib.rs" > "$t/$1/$1/server/src/lib.rs"
	publish "$t/$1" $1
	for i in $(seq 120); do
		grep -aq "web build of tester/$1/1.0.0: " "$2" && break
		curl -s -m 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$P/api/v1/aitta/list" |
			grep -q 200 || fail "Aitta did not answer during $1's build"
		sleep 1
	done
	grep -aq "web build of tester/$1/1.0.0: failed" "$2" ||
		fail "$1 was not ended: $(grep -a -A20 "web build of tester/$1" "$2" | tail -20)"
	grep -aq "MEM held" "$2" && fail "$1 held 1.5 GiB: its memory had no cap"
	grep -aom1 "the build: its processes went past 1024 MiB$3" "$2" ||
		fail "$1 failed, not at its memory: $(grep -a -A20 "web build of tester/$1" "$2" | tail -20)"
	left=$(pgrep -f "${tok}_mem" | tr '\n' ' ')
	[ -n "$left" ] && { CHECK_PIDS+=($left); fail "$1 left processes: $left"; }
	curl -s -m 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$P/api/v1/aitta/list" |
		grep -q 200 || fail "Aitta does not answer after $1"
}
mem_probe mem "$t/srv.log" " ([0-9]* MiB); ended"
echo "ok: a build whose processes touch memory is ended at the build's total; Aitta answered, nothing left"

# 3.
mkdir -p "$t/cpp/main/client_lua"
cat > "$t/cpp/main/main.cpp" <<'EOF2'
// The check's C++ server module: says hello, answers the client's ping
#include "interface/module.h"
#include "interface/server.h"
#include "network/api.h"
#include "core/log.h"
#include <map>
#include <stdexcept>
// EVIL_TOP
#define MODULE "main"
namespace main_ {
struct Module: public interface::Module
{
	interface::Server *m_server;
	std::map<ss_, int> m_count;
	Module(interface::Server *server): interface::Module(MODULE), m_server(server) {}
	void init()
	{
		log_i(MODULE, "CPPSERVER hello from the release's C++");
		// EVIL_INIT
		sub(m_server, "network:packet_received/main:ping", &Module::on_ping);
	}
	void on_ping(const network::Packet &packet)
	{
		int n = 0;
		try {
			throw std::runtime_error("caught");
		} catch(std::exception &e){
			n = ++m_count[e.what()];
		}
		network::send(m_server, packet.sender, "main:pong",
				"pong "+packet.data.substr(0, 40)+" "+std::to_string(n));
	}
};
extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
EOF2
cat > "$t/cpp/main/client_lua/init.lua" <<'EOF2'
local log = buildat.Logger("cpp")
buildat.sub_packet("main:pong", function(data)
	log:info("CPPPONG " .. data)
end)
buildat.send_packet("main:ping", "from the page")
EOF2
echo '{"engine_api": 2, "client_main": "init.lua", "dependencies": [{"module": "network"},
	{"module": "client_lua"}, {"module": "client_data"}]}' > "$t/cpp/main/meta.json"
mkdir -p "$t/flags"
cp -r "$t/cpp/main" "$t/flags/"
echo '{"engine_api": 2, "cxxflags": "-DX", "dependencies": [{"module": "network"}]}' \
	> "$t/flags/main/meta.json"
publish "$t/flags" flags
grep -aq "tester/flags/1.0.0 in the page: no, the module main has cxxflags" "$t/srv.log" ||
	fail "the C++ package with cxxflags not refused for the page ($t/srv.log)"
release flags | grep -q '"web"\|"web_cpp"' && fail "the C++ package with cxxflags has a web build"
echo "ok: a package whose C++ has flags of its own is listed, not in the page"

# 3b. [WEB_LOCAL_AITTA_CPP] Its own server, and the refusals: each a copy
# of cpp with a line put in. "outside" includes a file of Aitta's (by its
# path, which a publisher would guess), valid C++, readable outside the box
printf '#define OUTSIDE_SECRET "leaked"\n' > "$t/srv/apps/aitta/outside.h"
cat "$t/srv/apps/aitta/outside.h" > /dev/null || fail "outside.h is not readable here"
evil(){
	mkdir -p "$t/$1"
	cp -r "$t/cpp/main" "$t/$1/"
	python3 - "$t/$1/main/main.cpp" "$2" "$3" <<'EOF2'
import sys
p, top, init = sys.argv[1:4]
s = open(p).read().replace("// EVIL_TOP", top).replace("// EVIL_INIT", init)
open(p, "w").write(s)
EOF2
}
evil emasm "#include <emscripten.h>" 'EM_ASM({ console.log("EVIL EM_ASM"); });'
evil emjs "#include <emscripten.h>
EM_JS(void, evil_js, (), { console.log('EVIL EM_JS'); });" "evil_js();"
evil runscript "#include <emscripten.h>" 'emscripten_run_script("console.log(1)");'
evil vibrate "#include <emscripten/html5.h>" "emscripten_vibrate(1);"
evil sig 'extern "C" __attribute__((import_module("env"), import_name("emscripten_date_now"))) int evil_now(int);' \
	'log_i(MODULE, "%i", evil_now(1));'
evil outside "#include \"$t/srv/apps/aitta/outside.h\"" 'log_i(MODULE, "%s", OUTSIDE_SECRET);'
# One at a time: Aitta takes 30 uploads a minute from an address
for n in cpp emasm emjs runscript vibrate sig outside; do
	publish "$t/$n" $n
	wait_for_log "$t/srv.log" "web build of tester/$n/1.0.0: " 300 ||
		fail "no web build of $n ($t/srv.log)"
done
grep -aq "web build of tester/cpp/1.0.0: built" "$t/srv.log" ||
	fail "cpp's server was not built: $(grep -a -A30 "web build of tester/cpp" "$t/srv.log" | tail -30)"
release cpp > "$t/cpp.json"
python3 - "$t/cpp.json" "$(sha256sum < "$here/web/local/_aitta/buildat_server.js" | cut -d' ' -f1)" \
		> "$t/cpp.list" <<'EOF2' || fail "cpp's listing ($t/cpp.json)"
import json, sys
r = json.load(open(sys.argv[1]))
s = r["web_server"]
assert r["web_cpp"] is True and "web" not in r and r["web_build"] == "built" and r["web_wasm"] == {}, r
assert s["js"] == sys.argv[2] and isinstance(s["shift"], int) and len(s["wasm"]) == 64, s
print(s["wasm"], s["shift"])
EOF2
read -r sha shift < "$t/cpp.list"
curl -s -D "$t/h" -o "$t/cpp.wasm" "http://127.0.0.1:$P/api/v1/aitta/wasm/$sha.wasm"
tr -d '\r' < "$t/h" > "$t/h2"
grep -qi "^Access-Control-Allow-Origin: \*" "$t/h2" &&
	grep -qi "^Cross-Origin-Resource-Policy: cross-origin" "$t/h2" ||
	fail "cpp's server: not served for an isolated page ($(cat "$t/h2"))"
[ "$(sha256sum < "$t/cpp.wasm" | cut -d' ' -f1)" = "$sha" ] || fail "cpp's server is not $sha"
echo "ok: cpp's server linked at publish ($(stat -c %s "$t/cpp.wasm") bytes, EM_ASM moved by $shift), listed and served"
refused(){
	grep -aq "web build of tester/$1/1.0.0: failed" "$t/srv.log" ||
		fail "$1 was not refused: $(grep -a -A10 "web build of tester/$1" "$t/srv.log" | tail -10)"
	grep -aq "$2" "$t/srv.log" || fail "$1: no \"$2\" in $t/srv.log"
	release "$1" | grep -q '"web"\|"web_cpp"' && fail "$1 has a web build"
	echo "ok: $1 refused: $(grep -aom1 "$2.*" "$t/srv.log" | cut -c1-120)"
}
refused emasm "web build of tester/emasm/1.0.0: its server: refused: its .js is not the engine's"
refused emjs "web build of tester/emjs/1.0.0: its server: refused: it imports env.evil_js"
refused runscript "web build of tester/runscript/1.0.0: its server: refused: it imports env.emscripten_run_script,"
refused vibrate "web build of tester/vibrate/1.0.0: its server: refused: it imports env.emscripten_vibrate,"
refused sig "web build of tester/sig/1.0.0: its server: refused: it imports env.emscripten_date_now,"
refused outside "outside.h.*\(Permission denied\|not found\)"
grep -aq "web build of tester/outside/1.0.0: its server: refused" "$t/srv.log" &&
	fail "outside was linked: the include read past the box"

# 4.
BUILDAT_LUANTI_LIST=http://127.0.0.1:9 start_server "$t/play.log" "Listening at" 120 auto \
	bin/buildat_server -m ../apps/play -D "$t/play" -C "$t/play.cache" -W "$here/web" -l 3 ||
	fail "the play server did not start"
CHECK_PIDS+=($SERVER_PID)
PP=$SERVER_PORT
play_pid=$SERVER_PID
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
echo "ok: rusty played in the page (Chrome)"
# The C++ package, in each browser (its own storage: installed afresh)
for browser in chrome webkit; do
	cat > "$t/steps_cpp.json" <<J
[["nav", "http://127.0.0.1:$PP/"],
 ["waitlog", "launch_menu", 90],
 ["eval", "$set_js"],
 ["nav", "http://127.0.0.1:$PP/?again#run=tester/cpp"],
 ["waitlog", "Asking the user about", 90],
 ["wait", 1000],
 ["key", "Enter"],
 ["waitlog", "local: asking the player's name", 60],
 ["type", "tester"],
 ["key", "Enter"],
 ["waitlog", "local: tester.cpp@1.0.0 has its own server .wasm", 60],
 ["eval", "'isolated ' + crossOriginIsolated + ' at ' + location.search"],
 ["waitlog", "CPPSERVER hello", 120],
 ["waitlog", "CPPPONG pong from the page 1", 60]]
J
	PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1 \
	NODE_PATH=$HOME/.local/share/playwright-node/node_modules \
	WEB_DRIVE_URL=http://127.0.0.1:$PP "$here/util/web_drive.sh" $browser play \
		"$t/steps_cpp.json" "$t/web_cpp_$browser" > "$t/web_cpp_$browser.out" 2>&1 ||
		fail "the $browser drive of cpp ($(tail -3 "$t/web_cpp_$browser.out"); $t/web_cpp_$browser)"
	page=$t/web_cpp_$browser/page.log
	grep -q "isolated true at ?local=tester.cpp%401.0.0" "$t/web_cpp_$browser.out" ||
		fail "$browser: not the package's isolated page"
	for want in "server: .*Loading module main from /installed/tester/cpp/1.0.0/main" \
			"server: .*CPPSERVER hello from the release's C++" \
			"CPPPONG pong from the page 1"; do
		grep -aq "$want" "$page" || fail "$browser: no \"$want\" in $page"
	done
	grep -aq "No EM_ASM constant\|aborted" "$page" && fail "$browser: $(grep -a "No EM_ASM\|aborted" "$page" | head -3)"
	echo "ok: cpp played in the page ($browser): its own server, its C++ answering"
done
# 5. 2b where the host gives a build no PID namespace: the same Aitta,
# its records copied, refusing the build
kill $aitta_pid $play_pid
for p in $aitta_pid $play_pid; do
	for i in $(seq 50); do kill -0 $p 2>/dev/null || break; sleep 0.2; done
done
cp -a "$t/srv" "$t/srv2"
BUILDAT_BUILD_NO_PIDNS=1 start_server "$t/srv2.log" "Listening at" 60 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv2" -l 3 ||
	fail "the second Aitta did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
publish "$t/linger" linger2
wait_for_log "$t/srv2.log" "web build of tester/linger2/1.0.0: " 120 ||
	fail "no web build of linger2 ($t/srv2.log)"
grep -aq "web build of tester/linger2/1.0.0: failed" "$t/srv2.log" &&
	grep -aq "no PID namespace for it" "$t/srv2.log" ||
	fail "linger2 was not refused for want of a PID namespace ($t/srv2.log)"
left=$(pgrep -f "${tok}_" | tr '\n' ' ')
[ -n "$left" ] && { CHECK_PIDS+=($left); fail "linger2 left processes: $left"; }
echo "ok: without a PID namespace nothing is built"
publish "$t/cpp" cpp2
grep -aq "tester/cpp2/1.0.0 in the page: no, the module main is C++" "$t/srv2.log" ||
	fail "the C++ package not refused for the page without a kit ($t/srv2.log)"
release cpp2 | grep -q '"web"\|"web_cpp"' && fail "cpp2 has a web build without a kit"
echo "ok: without a kit a package with C++ is listed, not in the page"
# 6. [AITTA_BUILD_MEM] 2e under a systemd user scope with Delegate=yes (as
# under a unit with Delegate=): the build in a cgroup of its own, a
# build made in it, and the memory probe ended by the cgroup's OOM
kill $SERVER_PID
for i in $(seq 50); do kill -0 $SERVER_PID 2>/dev/null || break; sleep 0.2; done
cp -a "$t/srv" "$t/srv3"
scope=()
systemd-run --user --scope -q -p Delegate=yes true 2>/dev/null &&
	scope=(systemd-run --user --scope -q -p Delegate=yes)
BUILDAT_BUILD_MEMORY_MIB=1024 start_server "$t/srv3.log" "Listening at" 60 auto \
	"${scope[@]}" bin/buildat_server -m ../apps/aitta -D "$t/srv3" -l 3 ||
	fail "the third Aitta did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
if [ -n "${scope[*]}" ]; then
	grep -aq "A build's cgroup: .*/build (memory.max 1024 MiB, pids.max 64)" "$t/srv3.log" ||
		fail "no cgroup for a build under Delegate=yes ($t/srv3.log)"
	publish "$t/linger" linger3
	wait_for_log "$t/srv3.log" "web build of tester/linger3/1.0.0: " 120 ||
		fail "no web build of linger3 ($t/srv3.log)"
	grep -aq "web build of tester/linger3/1.0.0: built" "$t/srv3.log" ||
		fail "linger3 was not built in the cgroup: $(grep -a -A20 "web build of tester/linger3" "$t/srv3.log" | tail -20)"
	left=$(pgrep -f "${tok}_" | tr '\n' ' ')
	[ -n "$left" ] && { CHECK_PIDS+=($left); fail "linger3 left processes: $left"; }
	mem_probe mem3 "$t/srv3.log" " (its cgroup's OOM); ended"
	echo "ok: under Delegate=yes a build runs in its own cgroup, and its memory is ended by the cgroup"
else
	echo "no systemd user scope with Delegate=yes here: step 6 not run"
fi
# 7. [AITTA_BUILD_QUEUE] On the third Aitta (a fresh count of uploads:
# Aitta takes 30 a minute from a network). The gate's build waits for a
# file the check puts in its job directory (TMPDIR is <job>/tmp);
# meanwhile tester queues q1..q4 (q4 refused) and other queues oq. Built
# next: oq, then q1..q3
mkdir -p "$t/gate/gate/server/src"
cp "$t/linger/linger/meta.json" "$t/gate/gate/meta.json"
sed 's/probe/gate/' "$t/probe/probe/server/Cargo.toml" > "$t/gate/gate/server/Cargo.toml"
cat > "$t/gate/gate/server/build.rs" <<'EOF2'
fn main() {
	let go = format!("{}/../go", std::env::var("TMPDIR").unwrap());
	for _ in 0..2400 {
		if std::path::Path::new(&go).exists() { return; }
		std::thread::sleep(std::time::Duration::from_millis(50));
	}
	panic!("GATE never opened");
}
EOF2
sed 's/linger/gate/' "$t/linger/linger/server/src/lib.rs" > "$t/gate/gate/server/src/lib.rs"
publish "$t/gate" gate
gate_job="buildat_server --build-wasm [^ ]*/web_$(sha256sum < "$zip" | cut -d' ' -f1)"
wait_for_log "$t/srv3.log" "$gate_job" 60 || fail "the gate's build did not start"
job=$(grep -aom1 -e "$gate_job" "$t/srv3.log" | cut -d' ' -f3)
for n in q1 q2 q3 q4 oq; do
	mkdir -p "$t/$n"
	cp -r "$t/linger/linger" "$t/$n/$n"
	for f in Cargo.toml src/lib.rs; do
		sed "s/linger/$n/" "$t/linger/linger/server/$f" > "$t/$n/$n/server/$f"
	done
	echo 'fn main() {}' > "$t/$n/$n/server/build.rs"
done
for n in q1 q2 q3; do publish "$t/$n" $n; done
pack "$t/q4" q4
grep -q "3 releases of tester wait to be built for the page here already" "$t/pub_q4.out" ||
	fail "q4 was not refused: $(cat "$t/pub_q4.out")"
publish "$t/oq" oq other "$t/key2"
touch "$job/go"
wait_for_log "$t/srv3.log" "web build of tester/q3/1.0.0: " 120 || fail "no web build of q3"
order=$(grep -ao "web build of [a-z]*/[a-z0-9]*/1.0.0: [a-z]*" "$t/srv3.log" |
	sed -n '/gate/,$p' | cut -d' ' -f4,5 | tr '\n' ' ')
echo "built in order: $order"
[ "$order" = "tester/gate/1.0.0: built other/oq/1.0.0: built tester/q1/1.0.0: built tester/q2/1.0.0: built tester/q3/1.0.0: built " ] ||
	fail "not round-robin by author: $order"
echo "ok: one author's builds wait three at most, and another's single build is next"

echo "PASS: Aitta builds a release's .wasm and its C++ server at publish in a box that reaches nothing else, lists and serves them for the page, refuses C++ with flags, embedded JS or imports the engine has not, and C++ without a kit; ends every process a build leaves and a build past its memory total (measured, or its cgroup under Delegate=yes); builds taken round-robin by author, three waiting at most; the page installs the release and runs it with the engine's server for packages (its own .wasm for C++, Chrome and WebKit), the client joined and the server answered"
