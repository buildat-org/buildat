#!/bin/bash
# tier: full
# cost: ~2 min (2026-11-06)
# covers: apps/aitta/main/main.cpp src/impl/aitta.cpp src/client/main.cpp src/server/wasm_build.cpp client/core/aitta/init.lua
# [AITTA_NATIVE_WASM]: a release's .wasm that its Aitta built, on a native
# server with no toolchain. On a local (boxed) Aitta and a fake one of
# Python's, nothing past loopback:
#   1. A C++ module with a wasm/ and a server .wasm in C, on an Aitta with
#      no SDK: "web_wasm", "web_native", no "web" or "web_cpp", and no
#      "runs in the browser". apps/sample_rust: "web", as before. A package
#      with no .wasm of its own, a variant, a remix and a world with a
#      module's wasm/ in them are not built; one for the page with no .wasm
#      at all is, as it is ("web", "web_wasm" empty). While a build runs, three more
#      of the author's wait and a fourth is refused, not for the page too.
#   2. `buildat aitta install` with the toolchain hidden: .aitta_wasm/ has
#      each by its sha256; a server with the toolchain hidden starts it and
#      says Aitta built it (Rust too); a client gets the .wasm and runs it.
#      A server that has the toolchain builds from source.
#   3. The client's own install (Apps from Aitta) fetches them, and fetches
#      them again from the list when they are gone. Install clicked twice:
#      one install; Escape then: done after its page went, it leaves it alone.
#   4. A zip with .aitta_wasm, .aitta_from, .aitta_sha256 and .web at its
#      root: refused at publish, dropped at each install, from a file and
#      from an Aitta.
#   5. Off the fake Aitta: a wrong sha256, a path in a name, past 8 MiB and
#      a 404 are each a warning and no file, the install goes through; the
#      server then refuses it saying why; a second install fetches what is
#      listed by then and not the zip again. A directory without .aitta_from
#      never uses .aitta_wasm.
#   6. A .wasm with an import this engine has not, in .aitta_wasm: the
#      client's wasm_load and the server each refuse it, naming the import.
#   7. A release from before all this: looked into at Aitta's start, built
#      when it has a .wasm, "none" when not, and only once.
# Needs clang and a wasm linker, cargo with the wasm32-unknown-unknown target, a
# display for the scripted clients, and Python's cryptography.
#   util/aitta_native_wasm_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
check_user
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
cargo=$(command -v cargo || echo "$HOME/.cargo/bin/cargo")
[ -x "$cargo" ] || skip "no cargo"
[ -d "$("$(dirname "$cargo")/rustc" --print target-libdir --target wasm32-unknown-unknown 2>/dev/null)" ] ||
	skip "no wasm32-unknown-unknown target"
python3 -c 'import cryptography' 2>/dev/null || skip "no python3 cryptography"
check_tmp aitta_native_wasm; t=$CHECK_TMP
b="$here/Build/bin/buildat"
cd "$here/Build"

# The toolchain hidden: a nonexistent path is passed over for PATH and the
# homes, so PATH has every program but these and the homes are empty
mkdir -p "$t/path" "$t/nohome"
IFS=: read -ra dirs <<< "$PATH"
for d in "${dirs[@]}"; do
	for f in "$d"/*; do
		n=${f##*/}
		case $n in clang*|wasm-ld*|ld.lld*|lld*|cargo*|rustc*|rustup*|emcc*) continue ;; esac
		[ -x "$f" ] && [ ! -e "$t/path/$n" ] && ln -s "$f" "$t/path/$n"
	done
done
NT=(env HOME="$t/nohome" EMSDK="$t/nowhere" RUSTUP_HOME="$t/nowhere"
	CARGO_HOME="$t/nowhere" PATH="$t/path" BUILDAT_WASM_CC="$t/nowhere/clang"
	BUILDAT_WASM_LD="$t/nowhere/wasm-ld" BUILDAT_CARGO="$t/nowhere/cargo")

start_server "$t/srv.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 ||
	fail "Aitta did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
aitta_pid=$SERVER_PID
A=http://127.0.0.1:$P
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
# What it builds with, for 6's own .wasm
tools=$(grep -ao "wasm toolchain: .*" "$t/srv.log" | head -1)
[ -n "$tools" ] || skip "no clang and wasm linker"
tools=${tools#wasm toolchain: }
wcc=${tools%%, *} wld=${tools##*, }
case $wld in *rust-lld) wld_args=(-flavor wasm) ;; *) wld_args=() ;; esac
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
fp=tester # dev installs by author
printf 'wait_log_any 30000 admin script: done\nwait_log_any 30000 "id":2,\nquit\n' > "$t/reqs.cmds"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
	BUILDAT_AITTA_CODE=$code \
	BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}
{\"cmd\":\"set_settings\",\"settings\":{\"page_delay\":0}}" \
	timeout 90 "$b" -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$P -c @"$t/reqs.cmds" > "$t/bind.log" 2>&1
grep -aq 'ai: {"id":1,"ok":true' "$t/bind.log" || fail "the bind"

# manifest <dir> <name> [extra keys]: the package's meta.json
manifest(){
	printf '{"author": "tester", "name": "%s", "version": "1.0.0", "engine_api": 2,
		"audience": "everyone", "license_code": "MIT", "license_media": "CC0-1.0",
		"description": "a check"%s}\n' "$2" "${3:-}" > "$1/meta.json"
}
# publish <dir> <name> [extra keys]: manifest, pack, publish; the Aitta's words in pub_<name>.out
publish_only(){
	manifest "$1" "$2" "${3:-}"
	zip=$("$b" aitta pack "$1" "$t/key" "$t/out" 2>/dev/null) || fail "pack $2"
	"$b" aitta publish "$zip" 127.0.0.1:$P > "$t/pub_$2.out" 2>&1
}
publish(){
	publish_only "$@"
	grep -q "listed: tester/$2/1.0.0" "$t/pub_$2.out" || fail "publish $2: $(cat "$t/pub_$2.out")"
}
built(){ # <name> <log>
	wait_for_log "$2" "web build of tester/$1/1.0.0: " 120 || fail "no build of $1 ($2)"
	grep -aq "web build of tester/$1/1.0.0: built" "$2" ||
		fail "$1 was not built: $(grep -a -A20 "web build of tester/$1" "$2" | tail -20)"
}
# The list's release <name> as JSON
release(){
	curl -s "$A/api/v1/aitta/list" | python3 -c "
import json, sys
for r in json.load(sys.stdin)['releases']:
	if r['name'] == '$1': print(json.dumps(r))"
}
# has_web_wasm <name> <names...>: "web_wasm" is these, by their hashes
web_wasm_is(){
	release "$1" > "$t/rel_$1.json"
	python3 - "$t/rel_$1.json" "${@:2}" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
assert sorted(r["web_wasm"]) == sorted(sys.argv[2:]), r
assert r["web_build"] == "built", r
EOF
}
# installed_as_listed <dir> <name>: each file in .aitta_wasm its list's sha256
installed_as_listed(){
	python3 - "$1" "$t/rel_$2.json" <<'EOF'
import hashlib, json, os, sys
r = json.load(open(sys.argv[2]))
d = sys.argv[1] + "/.aitta_wasm"
assert sorted(os.listdir(d)) == sorted(r["web_wasm"]), os.listdir(d)
for n, sha in r["web_wasm"].items():
	assert hashlib.sha256(open(d + "/" + n, "rb").read()).hexdigest() == sha, n
EOF
}

# The native-only package: main in C++ with wasm/ in C, srvw a server .wasm in C
fixture(){
	mkdir -p "$1/main/wasm" "$1/main/client_lua" "$1/srvw/server"
	cp "$here/apps/sample_wasm/main/main.cpp" "$1/main/main.cpp"
	cat > "$1/main/meta.json" <<'EOF'
{"engine_api": 2, "client_main": "init.lua", "dependencies": [{"module": "network"},
	{"module": "client_lua"}, {"module": "client_data"}, {"module": "srvw"}]}
EOF
	cat > "$1/main/wasm/toy.c" <<'EOF'
#include "interface/wasm_api.h"
BUILDAT_WASM_EXPORT int answer(void){ return 42; }
EOF
	cat > "$1/main/client_lua/init.lua" <<'EOF'
local log = buildat.Logger("native")
local m, why = buildat.wasm_load("main")
log:info("WASMSAID " .. (m and tostring(m:call("answer")) or "refused: " .. tostring(why)))
buildat.sub_packet("main:pong", function(data)
	log:info("CPPSAID " .. data)
end)
buildat.send_packet("main:ping", "from the client")
EOF
	echo '{"engine_api": 2, "disable_cpp": true, "server_wasm": {"source": "server", "imports": []}}' \
		> "$1/srvw/meta.json"
	cat > "$1/srvw/server/init.c" <<'EOF'
#include "interface/wasm_server_api.h"
BUILDAT_SERVER_EXPORT void init(void)
{
	static const char s[] = "SERVERWASM up";
	buildat_log(s, sizeof s - 1);
}
EOF
}
# A client on the server just started; its log in <log>
join(){ # <log> <wait>
	printf 'wait_log 60000 %s\nquit\n' "$2" > "$1.cmds"
	run_client 60 "$1" timeout 120 "$b" -C "$t/join_cache" -D "$t/join_user" \
		-s localhost:$SERVER_PORT -w 320x240 -l 3 -o sound_mute=1 -c @"$1.cmds"
}
# A line a command did not echo
said(){ grep -a "$2" "$1" | grep -qv "wait_log"; }
stop_server(){
	kill -INT "$SERVER_PID" 2>/dev/null
	for _ in $(seq 100); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.1; done
	wait "$SERVER_PID" 2>/dev/null
}

# 1. What is built
mkdir -p "$t/rusty"
cp -r "$here/apps/sample_rust/main" "$here/apps/sample_rust/counter" \
	"$here/apps/sample_rust/endless" "$t/rusty/"
rm -rf "$t"/rusty/*/*/target
publish "$t/rusty" rusty

# ... and while its cargo runs, one author's waiting builds (not for the page)
for n in q1 q2 q3 q4; do
	mkdir -p "$t/$n"
	fixture "$t/$n"
	publish_only "$t/$n" "$n"
done
grep -a "web build of tester/rusty/1.0.0: " "$t/srv.log" &&
	fail "rusty's build was over before the queue was filled: this proves nothing"
for n in q1 q2 q3; do
	grep -q "listed: tester/$n/1.0.0" "$t/pub_$n.out" || fail "publish $n: $(cat "$t/pub_$n.out")"
done
grep -q "3 releases of tester wait to be built here already" "$t/pub_q4.out" ||
	fail "a fourth release not for the page was not refused: $(cat "$t/pub_q4.out")"
grep -aq "tester/q1/1.0.0 in the page: no, the module main is C++; its .wasm queued" "$t/srv.log" ||
	fail "q1 not queued for a native server ($t/srv.log)"
echo "ok: a fourth waiting release is refused for these too"
built rusty "$t/srv.log"
for n in q1 q2 q3; do built $n "$t/srv.log"; done

web_wasm_is rusty counter.server.wasm endless.server.wasm main.server.wasm main.wasm ||
	fail "rusty's listing"
python3 - "$t/rel_rusty.json" <<'EOF' || fail "rusty is not in the page ($t/rel_rusty.json)"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["web"] is True and "web_native" not in r, r
EOF
mkdir -p "$t/nativeapp"
fixture "$t/nativeapp"
publish "$t/nativeapp" nativeapp
built nativeapp "$t/srv.log"
web_wasm_is nativeapp main.wasm srvw.server.wasm || fail "nativeapp's listing"
python3 - "$t/rel_nativeapp.json" <<'EOF' || fail "nativeapp said to be in the page ($t/rel_nativeapp.json)"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["web_native"] is True and "web" not in r and "web_cpp" not in r and "web_server" not in r, r
EOF
curl -s "$A/p/tester/nativeapp" | grep -q "tester/nativeapp" || fail "no page of nativeapp"
curl -s "$A/p/tester/nativeapp" | grep -q "runs in the browser\|Play in the browser" &&
	fail "nativeapp's page says it runs in the browser"
curl -s "$A/p/tester/rusty" | grep -q "runs in the browser" || fail "rusty's page does not say it runs in the browser"
echo "ok: built for a native server, and not said to run in the page; a web release as before"

# Not built: no module with a .wasm of its own, whatever its kind
mkdir -p "$t/plain/main" "$t/variant/mine" "$t/remix" "$t/world/world" "$t/world/mod/wasm"
cp "$here/apps/sample_wasm/main/main.cpp" "$t/plain/main/"
echo '{"engine_api": 2, "dependencies": [{"module": "network"}]}' > "$t/plain/main/meta.json"
publish "$t/plain" plain
echo '{"engine_api": 2, "disable_cpp": true}' > "$t/variant/mine/meta.json"
publish "$t/variant" variant ', "base": "tester.plain"'
publish "$t/remix" remix ', "kind": "remix", "base": "tester.plain"'
: > "$t/world/world/save.sqlite"
echo '{"engine_api": 2}' > "$t/world/mod/meta.json"
echo 'int x;' > "$t/world/mod/wasm/x.c"
publish "$t/world" world ', "kind": "world", "app": "tester.plain"'
for n in plain variant remix world; do
	release $n > "$t/rel_$n.json"
	python3 - "$t/rel_$n.json" <<'EOF' || fail "$n is to be built ($t/rel_$n.json)"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["web_build"] == "none" and "web_native" not in r and "web_wasm" not in r, r
EOF
	grep -aq "web build of tester/$n/" "$t/srv.log" && fail "$n was built"
done
echo "ok: a package with no .wasm of its own, a variant, a remix and a world are not built"

# [AITTA_WEB_BUILD_LEFTOVERS] For the page with nothing to build: built as it
# is. Named after nativeapp, which 3. finds first on the page
mkdir -p "$t/pagenowasm/main"
echo '{"engine_api": 2, "disable_cpp": true}' > "$t/pagenowasm/main/meta.json"
publish "$t/pagenowasm" pagenowasm
built pagenowasm "$t/srv.log"
release pagenowasm > "$t/rel_pagenowasm.json"
python3 - "$t/rel_pagenowasm.json" <<'EOF' || fail "pagenowasm is not in the page ($t/rel_pagenowasm.json)"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["web"] is True and r["web_build"] == "built" and r["web_wasm"] == {}, r
EOF
echo "ok: one for the page with no .wasm is built and in the page"

# 2. Installed with the toolchain hidden, and run
"${NT[@]}" "$b" aitta install "$A" tester/nativeapp "$t/u" > "$t/inst.out" 2> "$t/inst.err" ||
	fail "the install: $(cat "$t/inst.err")"
dir=$(cat "$t/inst.out")
[ "$dir" = "$t/u/installed/$fp/nativeapp/1.0.0" ] || fail "installed at $dir"
installed_as_listed "$dir" nativeapp || fail "$dir/.aitta_wasm is not as listed"
grep -q "^warning" "$t/inst.err" && fail "a warning: $(cat "$t/inst.err")"
start_server "$t/nt.log" "Listening at" 180 auto "${NT[@]}" \
	bin/buildat_server -m "$dir" -D "$t/nt" -r "$t/nt_rc" -l 3 ||
	fail "a server with no toolchain did not start it ($t/nt.log)"
CHECK_PIDS+=($SERVER_PID)
grep -aq "No wasm toolchain" "$t/nt.log" || fail "the toolchain was not hidden ($t/nt.log)"
grep -aq "wasm toolchain: " "$t/nt.log" && fail "the toolchain was found ($t/nt.log)"
grep -aq "main: wasm/ was built by the Aitta it came from: $dir/.aitta_wasm/main.wasm" "$t/nt.log" ||
	fail "main's .wasm is not Aitta's ($t/nt.log)"
grep -aq "srvw: server/ was built by the Aitta it came from: $dir/.aitta_wasm/srvw.server.wasm" "$t/nt.log" ||
	fail "srvw's .wasm is not Aitta's ($t/nt.log)"
wait_for_log "$t/nt.log" "SERVERWASM up" 20 || fail "srvw's .wasm did not run ($t/nt.log)"
join "$t/nt_join.log" "CPPSAID"
said "$t/nt_join.log" "WASMSAID 42" || fail "a client did not run Aitta's .wasm ($t/nt_join.log)"
said "$t/nt_join.log" "CPPSAID pong: from the client" || fail "the module's C++ did not answer ($t/nt_join.log)"
stop_server
echo "ok: no toolchain: a server starts it from Aitta's .wasm, a client runs it"

# The toolchain there: from source, as ever
start_server "$t/tc.log" "Listening at" 120 auto \
	bin/buildat_server -m "$dir" -D "$t/tc" -r "$t/tc_rc" -l 3 ||
	fail "a server with the toolchain did not start it ($t/tc.log)"
CHECK_PIDS+=($SERVER_PID)
grep -aq "main: built wasm/ in " "$t/tc.log" || fail "a server with the toolchain did not build it ($t/tc.log)"
grep -aq "was built by the Aitta" "$t/tc.log" && fail "a server with the toolchain took Aitta's ($t/tc.log)"
stop_server
echo "ok: with the toolchain, from source"

# Rust, and a web release run natively
"${NT[@]}" "$b" aitta install "$A" tester/rusty "$t/u" > "$t/inst2.out" 2> "$t/inst2.err" ||
	fail "rusty's install: $(cat "$t/inst2.err")"
rusty=$(cat "$t/inst2.out")
installed_as_listed "$rusty" rusty || fail "$rusty/.aitta_wasm is not as listed"
start_server "$t/nr.log" "Listening at" 180 auto "${NT[@]}" \
	bin/buildat_server -m "$rusty" -D "$t/nr" -r "$t/nr_rc" -l 3 ||
	fail "a server with no toolchain did not start rusty ($t/nr.log)"
CHECK_PIDS+=($SERVER_PID)
for m in "main: wasm/" "main: server/" "counter: server/" "endless: server/"; do
	grep -aq "$m was built by the Aitta it came from" "$t/nr.log" || fail "$m not Aitta's ($t/nr.log)"
done
stop_server
echo "ok: a Rust release too, with no cargo"

# 3. The client's own install, and a later list
mkdir -p "$t/u2"
echo "{\"starports\": [], \"aittas\": [\"$A\"]}" > "$t/u2/starport.json"
now=$(date +%s)
printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","%s","","%s","%s","","",""\n' \
	"$A" "$now" "$now" > "$t/u2/network_addresses.csv"
cat > "$t/gui.cmds" <<EOF
wait_log_any 60000 rows in
text aitta
wait_log 10000 rows for "aitta" in
keypress Return
wait_log 20000 aitta page: tester/nativeapp
delay 500
wait_log_any 5000 aitta panel: tester/nativeapp 1.0.0
click Button "Install"
click Button "Install"
keypress Escape
wait_log 20000 aitta: tester/nativeapp done, its page gone
quit
EOF
timeout 120 "$b" -o launch_ui=launch_menu -D "$t/u2" -C "$t/c_u2" -w 800x600 -l 3 \
	-o sound_mute=1 -c @"$t/gui.cmds" > "$t/gui.log" 2>&1 ||
	fail "the install's drive ($t/gui.log): $(grep -ao 'Command sequence failed.*' "$t/gui.log" | head -1)"
# [AITTA_WEB_BUILD_LEFTOVERS] A double-click: one install; Escape: done
# after its page went, which it leaves alone
[ "$(grep -ac "aitta status: Fetching tester/nativeapp" "$t/gui.log")" = 1 ] &&
	grep -aq "aitta: tester/nativeapp: an install runs already" "$t/gui.log" ||
	fail "a double-click installed twice ($t/gui.log)"
grep -a "was removed" "$t/gui.log" && fail "the install touched its page gone ($t/gui.log)"
installed_as_listed "$t/u2/installed/$fp/nativeapp/1.0.0" nativeapp ||
	fail "the client's install did not fetch them ($t/gui.log)"
mv "$t/u2/installed/$fp/nativeapp/1.0.0/.aitta_wasm" "$t/gui_wasm_was"
cat > "$t/gui2.cmds" <<EOF
wait_log_any 60000 rows in
text aitta
wait_log 10000 rows for "aitta" in
keypress Return
wait_log 20000 main.wasm fetched
wait_log_any 20000 srvw.server.wasm fetched
quit
EOF
timeout 120 "$b" -o launch_ui=launch_menu -D "$t/u2" -C "$t/c_u2" -w 800x600 -l 3 \
	-o sound_mute=1 -c @"$t/gui2.cmds" > "$t/gui2.log" 2>&1 ||
	fail "the second list's drive ($t/gui2.log): $(grep -ao 'Command sequence failed.*' "$t/gui2.log" | head -1)"
installed_as_listed "$t/u2/installed/$fp/nativeapp/1.0.0" nativeapp ||
	fail "the list did not fetch them again ($t/gui2.log)"
echo "ok: the client's install fetches them, and a later list what is missing"

# 4. Planted: zipped and signed here, as pack leaves names under a dot out
rawsign(){ # app key base
python3 - "$@" <<'PY'
import hashlib, io, json, os, sys, zipfile
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils
app, keyfile, base = sys.argv[1:4]
z = io.BytesIO()
with zipfile.ZipFile(z, "w", zipfile.ZIP_DEFLATED) as f:
    for d, _, names in os.walk(app):
        for n in names:
            p = os.path.join(d, n)
            f.write(p, os.path.relpath(p, app))
z = z.getvalue()
k = ec.derive_private_key(int(open(keyfile).read().split()[1], 16), ec.SECP256R1())
sha = hashlib.sha256(z).hexdigest()
h = hashlib.sha256(("aitta-release-1\n" + sha).encode()).digest()
pub = k.public_key().public_bytes(serialization.Encoding.X962,
        serialization.PublicFormat.UncompressedPoint).hex()
sig = k.sign(h, ec.ECDSA(utils.Prehashed(hashes.SHA256()))).hex()
os.makedirs(os.path.dirname(base), exist_ok=True)
open(base + ".zip", "wb").write(z)
open(base + ".sig", "w").write(json.dumps({"format": "aitta-release-1",
        "sha256": sha, "key": pub, "signature": sig}) + "\n")
PY
}
mkdir -p "$t/planted/.aitta_wasm" "$t/planted/.web"
fixture "$t/planted"
manifest "$t/planted" planted
cp "$dir/.aitta_wasm/main.wasm" "$t/planted/.aitta_wasm/main.wasm"
cp "$dir/.aitta_wasm/main.wasm" "$t/planted/.web/main.wasm"
echo "http://planted.invalid" > "$t/planted/.aitta_from"
echo "planted" > "$t/planted/.aitta_sha256"
rawsign "$t/planted" "$t/key" "$t/raw/tester-planted-1.0.0" || fail "the planted release"
"$b" aitta publish "$t/raw/tester-planted-1.0.0.zip" 127.0.0.1:$P > "$t/pub_planted.out" 2>&1
grep -q "at its root: a name under a dot there is an install's" "$t/pub_planted.out" ||
	fail "a planted .aitta_wasm was not refused at publish: $(cat "$t/pub_planted.out")"
[ -z "$(release planted)" ] || fail "the planted release is listed"
"$b" aitta install "$t/raw/tester-planted-1.0.0.zip" "$t/u_file" > "$t/file.out" 2> "$t/file.err" ||
	fail "installing the planted file: $(cat "$t/file.err")"
file_dir=$(cat "$t/file.out")
for n in .aitta_wasm .web .aitta_from; do
	[ -e "$file_dir/$n" ] && fail "$n stayed in $file_dir"
done
[ "$(cat "$file_dir/.aitta_sha256")" = "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$t/raw/tester-planted-1.0.0.sig")" ] ||
	fail ".aitta_sha256 is the package's"
echo "ok: planted names refused at publish and dropped at an install from a file"

# [AITTA_WASM_PAST_REVIEW] A .wasm anywhere in the archive, in any case
mkdir -p "$t/inblob"
fixture "$t/inblob"
manifest "$t/inblob" inblob
for wname in main/client_data/main.wasm main/client_data/MAIN.Wasm \
		main/client_data/other.wasm main/main.wasm stray.wasm; do
	mkdir -p "$(dirname "$t/inblob/$wname")"
	cp "$dir/.aitta_wasm/main.wasm" "$t/inblob/$wname"
	rawsign "$t/inblob" "$t/key" "$t/raw/tester-inblob-1.0.0" || fail "the $wname release"
	"$b" aitta publish "$t/raw/tester-inblob-1.0.0.zip" 127.0.0.1:$P > "$t/pub_inblob.out" 2>&1
	grep -q "the archive has $wname: a release's .wasm is built here" "$t/pub_inblob.out" ||
		fail "$wname was not refused: $(cat "$t/pub_inblob.out")"
	[ -z "$(release inblob)" ] || fail "the $wname release is listed"
	rm -f "$t/inblob/$wname"
done
echo "ok: a .wasm anywhere in the archive refused at publish"

# 5. A fake Aitta: its list, archives and .wasm from a directory, what was
# asked in requests.log
f=$t/fake
mkdir -p "$f/wasm"
cat > "$t/fake.py" <<'PY'
import http.server, os, sys
root, port = sys.argv[1], int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
	def log_message(self, *a): pass
	def do_GET(self):
		with open(root + "/requests.log", "a") as l:
			l.write(self.path + "\n")
		p = self.path.split("?")[0]
		name = p.split("/")[-1]
		path = {"list": root + "/list.json", "info": root + "/info.json"}.get(name)
		if path is None:
			path = root + ("/wasm/" if "/wasm/" in p else "/archive/") + name
		if not os.path.isfile(path):
			self.send_error(404)
			return
		data = open(path, "rb").read()
		self.send_response(200)
		self.send_header("Content-Length", str(len(data)))
		self.end_headers()
		self.wfile.write(data)
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
fake_port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -I "$t/fake.py" "$f" "$fake_port" &
CHECK_PIDS+=($!)
F=http://127.0.0.1:$fake_port
for _ in $(seq 50); do curl -s -o /dev/null "$F/x" && break; sleep 0.1; done
mkdir -p "$f/archive"
sha=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$t/raw/tester-planted-1.0.0.sig")
cp "$t/raw/tester-planted-1.0.0.zip" "$f/archive/$sha.zip"
cp "$t/raw/tester-planted-1.0.0.sig" "$f/archive/$sha.sig"
echo '{"ok": true}' > "$f/info.json"
good=$(sha256sum "$dir/.aitta_wasm/main.wasm" | cut -d' ' -f1)
goods=$(sha256sum "$dir/.aitta_wasm/srvw.server.wasm" | cut -d' ' -f1)
cp "$dir/.aitta_wasm/main.wasm" "$f/wasm/$good.wasm"
cp "$dir/.aitta_wasm/srvw.server.wasm" "$f/wasm/$goods.wasm"
# fake_list <web_wasm as JSON, or nothing>
fake_list(){
	python3 - "$t/raw/tester-planted-1.0.0.sig" "$f/list.json" "${1:-}" <<'EOF'
import json, sys
s = json.load(open(sys.argv[1]))
r = {"author": "tester", "name": "planted", "version": "1.0.0", "time": 1,
	"sha256": s["sha256"], "key": s["key"]}
if sys.argv[3]:
	r["web_wasm"] = json.loads(sys.argv[3])
json.dump({"releases": [r]}, open(sys.argv[2], "w"))
EOF
}
# fake_install <user>: its dir on stdout, the warnings in fake.err
fake_install(){ "${NT[@]}" "$b" aitta install "$F" tester/planted "$1" 2> "$t/fake.err"; }

# Not built yet; its planted names dropped from an Aitta's zip too
fake_list ""
fd=$(fake_install "$t/uf") || fail "the fake's install: $(cat "$t/fake.err")"
for n in .aitta_wasm .web; do
	[ -e "$fd/$n" ] && fail "$n stayed in $fd"
done
[ "$(cat "$fd/.aitta_from")" = "$F" ] || fail ".aitta_from is not the Aitta it came from"
# The server refuses it, saying why
"${NT[@]}" timeout 60 bin/buildat_server -m "$fd" -D "$t/rf" -r "$t/nt_rc" -l 3 -P 0 > "$t/refused.log" 2>&1
grep -aq "srvw: its Aitta's .wasm of server/ is not here" "$t/refused.log" &&
	grep -aq "srvw: no server .wasm; the module is refused" "$t/refused.log" ||
	fail "no refusal, saying why ($t/refused.log)"
# Built by now: a second install fetches it, and not the zip
fake_list "{\"main.wasm\": \"$good\", \"srvw.server.wasm\": \"$goods\"}"
: > "$f/requests.log"
fd2=$(fake_install "$t/uf") || fail "the second install: $(cat "$t/fake.err")"
[ "$fd2" = "$fd" ] || fail "the second install says $fd2"
cmp "$fd/.aitta_wasm/main.wasm" "$f/wasm/$good.wasm" || fail "the second install did not fetch it"
grep -q "\.zip\|\.sig" "$f/requests.log" && fail "the second install fetched the archive again"
: > "$f/requests.log"
fake_install "$t/uf" > /dev/null || fail "the third install"
grep -q "/wasm/" "$f/requests.log" && fail "what it has was fetched again"
grep -q "warning" "$t/fake.err" && fail "the third install warned: $(cat "$t/fake.err")"
echo "ok: a later install fetches what is missing, not the zip, and only that"

# A wrong sha256
cp "$f/wasm/$good.wasm" "$f/wasm/$(printf 'ab%.0s' $(seq 32)).wasm"
fake_list "{\"main.wasm\": \"$(printf 'ab%.0s' $(seq 32))\"}"
fw=$(fake_install "$t/uw") || fail "a wrong sha256 failed the install: $(cat "$t/fake.err")"
grep -q "main.wasm: not the one its Aitta listed" "$t/fake.err" || fail "no warning of the hash: $(cat "$t/fake.err")"
[ -e "$fw/.aitta_wasm/main.wasm" ] && fail "a wrong sha256 was kept"
# A path in a name, a name of another shape, an upper-case hash
fake_list "{\"../../evil.wasm\": \"$good\", \"a/b.wasm\": \"$good\", \"x.so\": \"$good\", \"..wasm\": \"$good\", \"main.wasm\": \"$(echo "$good" | tr a-f A-F)\"}"
fb=$(fake_install "$t/ub") || fail "wrong names failed the install: $(cat "$t/fake.err")"
[ "$(grep -c "names a .wasm wrongly" "$t/fake.err")" = 5 ] || fail "wrong names: $(cat "$t/fake.err")"
[ -e "$t/ub/installed/$fp/planted/evil.wasm" ] && fail "a name left the directory"
[ -n "$(ls -A "$fb/.aitta_wasm" 2>/dev/null)" ] && fail "a wrong name was kept"
# Past the cap, its hash right
head -c $((8 * 1024 * 1024 + 1)) /dev/zero > "$f/wasm/big"
big=$(sha256sum "$f/wasm/big" | cut -d' ' -f1)
mv "$f/wasm/big" "$f/wasm/$big.wasm"
fake_list "{\"main.wasm\": \"$big\"}"
fg=$(fake_install "$t/ug") || fail "past the cap failed the install: $(cat "$t/fake.err")"
grep -q "main.wasm: more than 8388608 bytes" "$t/fake.err" || fail "past the cap: $(cat "$t/fake.err")"
[ -e "$fg/.aitta_wasm/main.wasm" ] && fail "past the cap was kept"
# Absent
fake_list "{\"main.wasm\": \"$(printf 'cd%.0s' $(seq 32))\"}"
fa=$(fake_install "$t/ua") || fail "a 404 failed the install: $(cat "$t/fake.err")"
grep -q "warning: tester/planted 1.0.0: main.wasm: " "$t/fake.err" || fail "a 404: $(cat "$t/fake.err")"
[ -e "$fa/.aitta_wasm/main.wasm" ] && fail "a 404 was kept"
echo "ok: a wrong sha256, a path in a name, past the cap and a 404: a warning and no file, installed"

# Not from an Aitta: .aitta_wasm is not read
cp -r "$dir" "$t/dev_copy"
rm "$t/dev_copy/.aitta_from"
"${NT[@]}" timeout 60 bin/buildat_server -m "$t/dev_copy" -D "$t/dc" -r "$t/nt_rc" -l 3 -P 0 > "$t/dev_copy.log" 2>&1
grep -aq "srvw has server/, and this server has no clang" "$t/dev_copy.log" &&
	grep -aq "srvw: no server .wasm; the module is refused" "$t/dev_copy.log" ||
	fail "a directory without .aitta_from used .aitta_wasm ($t/dev_copy.log)"
grep -aq "was built by the Aitta" "$t/dev_copy.log" && fail "a directory without .aitta_from: Aitta's ($t/dev_copy.log)"
echo "ok: a directory not from an Aitta never uses .aitta_wasm"

# 6. A .wasm from a newer engine, an import this one has not
mkdir -p "$t/newer"
cat > "$t/newer/client.c" <<'EOF'
__attribute__((import_module("env"), import_name("buildat_from_the_future"))) int future(void);
__attribute__((export_name("answer"))) int answer(void){ return future(); }
EOF
cat > "$t/newer/server.c" <<'EOF'
__attribute__((import_module("env"), import_name("buildat_from_the_future"))) int future(void);
__attribute__((export_name("init"))) void init(void){ future(); }
EOF
for x in client server; do
	"$wcc" --target=wasm32 -O2 -nostdlib -ffreestanding -mcpu=mvp -c "$t/newer/$x.c" -o "$t/newer/$x.o" ||
		fail "the newer $x .wasm"
	"$wld" "${wld_args[@]}" --no-entry --export-dynamic --strip-all --max-memory=67108864 "$t/newer/$x.o" -o "$t/newer/$x.wasm" ||
		fail "the newer $x .wasm"
done
cp -r "$dir" "$t/newer_client"
cp "$t/newer/client.wasm" "$t/newer_client/.aitta_wasm/main.wasm"
start_server "$t/nc.log" "Listening at" 180 auto "${NT[@]}" \
	bin/buildat_server -m "$t/newer_client" -D "$t/nc" -r "$t/nt_rc" -l 3 ||
	fail "the newer client .wasm stopped the server ($t/nc.log)"
CHECK_PIDS+=($SERVER_PID)
join "$t/nc_join.log" "CPPSAID"
said "$t/nc_join.log" "WASMSAID refused: .*buildat_from_the_future" ||
	fail "the client's refusal of an unknown import ($t/nc_join.log)"
grep -a "WASMSAID refused" "$t/nc_join.log" | grep -v wait_log | sed 's/^.*WASMSAID/  the client:/' | cut -c1-200
stop_server
cp -r "$dir" "$t/newer_server"
cp "$t/newer/server.wasm" "$t/newer_server/.aitta_wasm/srvw.server.wasm"
"${NT[@]}" timeout 60 bin/buildat_server -m "$t/newer_server" -D "$t/ns" -r "$t/nt_rc" -l 3 -P 0 > "$t/ns.log" 2>&1
grep -aq "srvw: its .wasm is refused: .*buildat_from_the_future" "$t/ns.log" ||
	fail "the server's refusal of an unknown import ($t/ns.log)"
grep -a "srvw: its .wasm is refused" "$t/ns.log" | sed 's/^.*srvw:/  the server: srvw:/' | cut -c1-200
echo "ok: an unknown import is refused where it is loaded, by name"

# 7. Releases from before: their records as an older Aitta left them
kill "$aitta_pid"
for _ in $(seq 100); do kill -0 "$aitta_pid" 2>/dev/null || break; sleep 0.1; done
python3 - "$t/srv/apps/aitta/saves/aitta/save.sqlite" <<'EOF' || fail "the records"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
done = 0
for k, v in db.execute("select key, value from store where store = 'releases'").fetchall():
	if "nativeapp" not in k and "plain" not in k:
		continue
	r = json.loads(v)
	for x in ("web_build", "web_wasm", "web_native"):
		r.pop(x, None)
	db.execute("update store set value = ? where store = 'releases' and key = ?", (json.dumps(r).encode(), k))
	done += 1
assert done == 2, done
db.commit()
EOF
cat "$t/srv.log" > "$t/srv_first.log"
start_server "$t/srv2.log" "setup code|Listening at" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 ||
	fail "Aitta did not start again"
CHECK_PIDS+=($SERVER_PID)
A=http://127.0.0.1:$SERVER_PORT
built nativeapp "$t/srv2.log"
web_wasm_is nativeapp main.wasm srvw.server.wasm || fail "nativeapp's listing after the restart"
for _ in $(seq 100); do
	[ "$(release plain | python3 -c 'import json, sys; print(json.load(sys.stdin).get("web_build"))')" = none ] && break
	sleep 0.1
done
[ "$(release plain | python3 -c 'import json, sys; print(json.load(sys.stdin).get("web_build"))')" = none ] ||
	fail "plain was not looked at ($t/srv2.log)"
grep -aq "web build of tester/plain" "$t/srv2.log" && fail "plain was built after the restart"
echo "ok: a release from before is looked into once at a start, built when it has a .wasm"

echo "PASS: Aitta builds a native-only release's .wasm and does not call it web; a server with no toolchain and a client run them, from the CLI's and the client's install; planted names refused and dropped; wrong ones refused; an unknown import refused by name"
# vim: set noet ts=4 sw=4:
