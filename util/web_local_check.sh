#!/bin/bash
# tier: full
# cost: ~95 s, ~2.5 min with demo_aggregate and skeldat (2026-10-28)
# covers: util/web_drive.js client/launch_grid.lua src/server/web/pre.js builtin/world_menu/world_menu.cpp builtin/network/network_web.cpp src/client/pipe_stream.cpp src/client/web/index.html util/web_server.cmake
# [WEB_LOCAL_SERVER]: hillclimb in the browser with its own server in a
# worker of the page, and no buildat server: web/ served by a static
# server that sends what the buildat server sends with ?local
# (cross-origin isolation), and opened at ?local=hillclimb in Firefox
# (util/web_drive.sh). The client joins over the in-page stream, the car
# is driven past the first turn, and the worker's server says its ticks.
# A reload finds the saves kept in IndexedDB and opens them again; the
# isolated page runs the client with threads (buildat_mt), and the same
# drive runs in WebKit where Playwright's is installed. Then
# the buildat server's own serving of the same: the isolation headers
# on the play page and /starport_signin, the local server's files and
# buildat_mt.js, and not on the page with ?isolated=0; and a page with no game (apps/play's) given the apps for
# its launch menu; an app whose meta.json needs more than the browser gives
# (a fixture made here): the page's notice, and "Start anyway" starts it.
# demo_aggregate (walked a second, its position line moved) and skeldat (a
# world made in its menu, walked 2 voxels) are driven as hillclimb when
# web/local/<app>/ is there. Needs web/ (util/build_web.sh) with
# web/local/hillclimb/ (util/build_web_server.sh hillclimb).
#   util/web_local_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$here/web/local/hillclimb/buildat_server.wasm" ] ||
	skip "no web/local/hillclimb (util/build_web_server.sh hillclimb)"
check_tmp web_local; t=$CHECK_TMP
export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9

cat > "$t/static.py" << 'PY'
# web/ as files, isolated as the buildat server isolates ?local's page
import functools, http.server, sys
class H(http.server.SimpleHTTPRequestHandler):
	extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
			".wasm": "application/wasm", ".js": "application/javascript"}
	def end_headers(self):
		self.send_header("Cross-Origin-Opener-Policy", "same-origin")
		self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
		self.send_header("Cross-Origin-Resource-Policy", "same-origin")
		super().end_headers()
	def log_message(self, *a):
		pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])),
		functools.partial(H, directory=sys.argv[2])).serve_forever()
PY
for _ in $(seq 50); do
	p=$((29700 + RANDOM % 300))
	port_taken $p || break
done
python3 "$t/static.py" $p "$here/web" &
CHECK_PIDS+=($!)
for _ in $(seq 50); do port_taken $p && break; sleep 0.1; done
start=$(date +%s.%N)
WEB_DRIVE_URL="http://127.0.0.1:$p/?local=hillclimb&frame_split=1" \
	bash "$here/util/web_drive.sh" firefox hillclimb \
	"$here/util/web_local.json" "$t/web" > "$t/drive.log" 2>&1 ||
	fail "the drive ($t/drive.log: $(tail -2 "$t/drive.log" | tr '\n' ' '))"
end=$(date +%s.%N)
page=$t/web/page.log
grep -a "eval:" "$t/drive.log" | cut -c 1-300
grep -a "server: .*network: .*ticks/s" "$page" | tail -3 | cut -c 9-
# [WEB_LOCAL_MEMORY] The worker's malloc in use, ~140 MiB (2026-10-27,
# flat over 10 minutes); a no-op delete linked in once took it to the 2 GiB
# cap in seconds
used=$(grep -ao "MiB, [0-9]* MiB in use" "$page" | tail -1 | awk '{print $2}')
[ -n "$used" ] && [ "$used" -lt 512 ] ||
	fail "the server's memory in use: ${used:-not logged} MiB, not under 512"
grep -a "frame split" "$page" | tail -2 | cut -c 1-120
grep -q "isolated true" "$t/drive.log" || fail "the page was not cross-origin isolated"
grep -q "Connect succeeded (page:)" "$page" || fail "the client did not join by the page's stream"
grep -a "IndexedDB\|would not open\|cannot be opened\|malformed" "$page" &&
	fail "a /user sync or a save failed"
grep -q "kept: .*/ranking/save.sqlite" "$t/drive.log" ||
	fail "IndexedDB has no ranking save"
echo "the drive: $(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.1f", b - a}') s"
# [WEB_MESH_OFF_THREAD] An isolated page runs the client with threads
if [ -f "$here/web/buildat_mt.js" ]; then
	grep -aq "threads: [0-9]* mesh workers" "$page" ||
		fail "the isolated page did not run the client with threads ($page)"
fi
# And the same drive in WebKit, Safari's engine (iOS has no other), where
# Playwright's is installed
if [ -d "${PLAYWRIGHT_NODE:-$HOME/.local/share/playwright-node}/node_modules/playwright" ]; then
	WEB_DRIVE_URL="http://127.0.0.1:$p/?local=hillclimb&frame_split=1" \
		bash "$here/util/web_drive.sh" webkit hillclimb \
		"$here/util/web_local.json" "$t/webkit" > "$t/webkit.log" 2>&1 ||
		fail "the WebKit drive ($t/webkit.log: $(tail -2 "$t/webkit.log" | tr '\n' ' '))"
	grep -q "isolated true" "$t/webkit.log" || fail "WebKit's page was not cross-origin isolated"
	[ ! -f "$here/web/buildat_mt.js" ] ||
		grep -aq "threads: [0-9]* mesh workers" "$t/webkit/page.log" ||
		fail "WebKit's isolated page did not run the client with threads"
	echo "WebKit: $(grep -a "threads: " "$t/webkit/page.log" | head -1)"
fi

# demo_aggregate's too, when it is built: in, on its feet and walking
if [ -f "$here/web/local/demo_aggregate/buildat_server.wasm" ]; then
	cat > "$t/aggregate.json" << 'JSON'
[
	["nav", "${URL}"],
	["waitlog", "local: asking the player's name", 60], ["type", "tester"], ["key", "Enter"],
	["waitlog", "server: .*Client 1 from the page connected", 120],
	["waitlog", "player physics enabled", 120],
	["waitlog", "demo_dig: player at", 10],
	["eval", "'demo_aggregate playable at ' + Math.round(performance.now()) + ' ms'"],
	["holdkey", "w", 1000],
	["waitlog", "demo_dig: player at", 15],
	["waitlog", "server: .*network: [0-9.]+ ticks/s", 15]
]
JSON
	WEB_DRIVE_URL="http://127.0.0.1:$p/?local=demo_aggregate" \
		bash "$here/util/web_drive.sh" firefox demo_aggregate \
		"$t/aggregate.json" "$t/aggregate" > "$t/aggregate.log" 2>&1 ||
		fail "demo_aggregate's drive ($t/aggregate.log: $(tail -2 "$t/aggregate.log" | tr '\n' ' '))"
	grep -a "eval:" "$t/aggregate.log"
	grep -a "server: .*network: .*ticks/s" "$t/aggregate/page.log" | tail -1 | cut -c 9-
	# [AGGREGATE_WEB_WALK] The walk, from the client's position lines (the
	# server is not told it): the first two, a second of W apart
	grep -ao "player at ([-0-9., ]*)" "$t/aggregate/page.log" | head -2 > "$t/walk"
	cat "$t/walk"
	python3 - "$t/walk" <<'PY' || fail "demo_aggregate's player did not walk a voxel"
import re, sys
a, b = [list(map(float, re.findall(r"-?[0-9.]+", l))) for l in open(sys.argv[1])]
sys.exit(0 if ((a[0] - b[0]) ** 2 + (a[2] - b[2]) ** 2) ** 0.5 > 1 else 1)
PY
else
	echo "no web/local/demo_aggregate: its drive skipped"
fi

# skeldat's, when it is built: a new world made in the world menu, the
# player in it walking 2 voxels. 1200x800 places the buttons; the pointer
# lock is apps/skeldat/web_spawn_check.sh's stand-in.
if [ -f "$here/web/local/skeldat/buildat_server.wasm" ]; then
	cat > "$t/skeldat.json" << 'JSON'
[
	["nav", "${URL}"],
	["waitlog", "local: asking the player's name", 60], ["type", "tester"], ["key", "Enter"],
	["eval", "(function(){ var held = null; Object.defineProperty(document, 'pointerLockElement', {configurable: true, get: function(){ return held; }}); function set(e){ held = e; document.dispatchEvent(new Event('pointerlockchange')); } HTMLCanvasElement.prototype.requestPointerLock = function(){ if(held !== this) set(this); return Promise.resolve(); }; document.exitPointerLock = function(){ if(held) set(null); }; return 'stub'; })()"],
	["waitlog", "world_menu: the list shown", 120], ["wait", 500],
	["click", 362, 725], ["waitlog", "world_menu: the name screen shown", 10],
	["wait", 500], ["click", 580, 514],
	["waitlog", "pause: how to play shown", 240],
	["eval", "'skeldat playable at ' + Math.round(performance.now()) + ' ms'"],
	["wait", 1000], ["click", 600, 653], ["waitlog", "pause: the menu closed", 10],
	["holdkey", "w", 3000], ["waitlog", "skeldat: walked 2 from the placing", 10],
	["waitlog", "server: .*network: [0-9.]+ ticks/s", 15],
	["eval", "new Promise(r => { const q = indexedDB.open('/user'); q.onerror = () => r('no IndexedDB'); q.onsuccess = () => { const g = q.result.transaction('FILE_DATA').objectStore('FILE_DATA').getAll(); g.onsuccess = () => r('skeldat kept ' + Math.round(g.result.reduce((n, e) => n + (e.contents ? e.contents.length : 0), 0) / 1024) + ' kB'); }; })"]
]
JSON
	WEB_DRIVE_VIEWPORT=1200x800 WEB_DRIVE_URL="http://127.0.0.1:$p/?local=skeldat" \
		bash "$here/util/web_drive.sh" firefox skeldat \
		"$t/skeldat.json" "$t/skeldat" > "$t/skeldat.log" 2>&1 ||
		fail "skeldat's drive ($t/skeldat.log: $(tail -2 "$t/skeldat.log" | tr '\n' ' '))"
	grep -a "eval:" "$t/skeldat.log" | grep -v stub
	grep -a "server: .*network: .*ticks/s" "$t/skeldat/page.log" | tail -1 | cut -c 9-
else
	echo "no web/local/skeldat: its drive skipped"
fi

# [WASM_MAIN_WEB_PATHS] apps/sample_wasm_only(_rust), when built: a module
# whose client is only the default client_main ("client_main": "wasm") and
# its .wasm, C and Rust, built by util/web_server.cmake; the cube drawn, a
# key sent to the worker's server and its answer back
for app in sample_wasm_only sample_wasm_only_rust; do
	if [ ! -f "$here/web/local/$app/buildat_server.wasm" ]; then
		echo "no web/local/$app: its drive skipped"
		continue
	fi
	cat > "$t/$app.json" << 'JSON'
[
	["nav", "${URL}"],
	["waitlog", "local: asking the player's name", 60], ["type", "tester"], ["key", "Enter"],
	["waitlog", "wasm main: drew a cube", 120],
	["key", "Space"],
	["waitlog", "wasm main: the server answered echo: colour 1", 30]
]
JSON
	WEB_DRIVE_URL="http://127.0.0.1:$p/?local=$app" \
		bash "$here/util/web_drive.sh" firefox $app \
		"$t/$app.json" "$t/$app" > "$t/$app.log" 2>&1 ||
		fail "$app's drive ($t/$app.log: $(tail -2 "$t/$app.log" | tr '\n' ' '))"
	grep -aq "wasm main: ready (the browser's instance)" "$t/$app/page.log" ||
		fail "$app: not the browser's own instance"
	grep -aq "server: .*key from the client's wasm: 1" "$t/$app/page.log" ||
		fail "$app: the worker's server did not get the module's packet"
	grep -aE "default client_main|wasm main: trap" "$t/$app/page.log" &&
		fail "$app: the default client_main said something went wrong"
	echo "$app: drawn by its .wasm, a key answered by the worker's server"
done

# The buildat server's serving: a page with no game (apps/play's), and
# web/ as it is
cd "$here/Build"
BUILDAT_LUANTI_LIST=http://127.0.0.1:9 \
	start_server "$t/s.log" "STATUS Listening" 120 auto bin/buildat_server \
	-m ../apps/play -D "$t/s" -C "$t/s.cache" -W "$here/web" -l 3 ||
	fail "the server ($t/s.log)"
CHECK_PIDS+=($SERVER_PID)
u=http://127.0.0.1:$SERVER_PORT
# Its page lists the apps it may run for the launch menu
curl -s -m 10 "$u/" | grep -q "var local_apps = \[.*'hillclimb'" ||
	fail "the page does not offer hillclimb to the launch menu"
isolated()
{
	curl -s --path-as-is -m 10 -D - -o /dev/null "$u$1" | tr -d '\r' > "$t/h"
	grep -q "^HTTP/1.1 $2" "$t/h" || fail "$1: not $2 ($(head -1 "$t/h"))"
	grep -qi "^Cross-Origin-Opener-Policy: same-origin" "$t/h" &&
		grep -qi "^Cross-Origin-Embedder-Policy: require-corp" "$t/h"
}
isolated "/?local=hillclimb" 200 || fail "/?local=hillclimb is not isolated"
isolated "/local/hillclimb/buildat_server.js" 200 ||
	fail "the local server's script is not isolated"
isolated "/local/hillclimb/buildat_server.wasm" 200 || fail "the wasm is not isolated"
# [WEB_ISOLATED_SIGNIN] the play page by default, unless it opts out,
# and the threaded client's script, which its workers load
isolated "/" 200 || fail "/ is not isolated"
isolated "/?isolated=1" 200 || fail "/?isolated=1 is not isolated"
isolated "/?isolated=0" 200 && fail "/?isolated=0 is isolated"
isolated "/starport_signin" 200 || fail "/starport_signin is not isolated"
[ ! -f "$here/web/buildat_mt.js" ] || isolated "/buildat_mt.js" 200 ||
	fail "buildat_mt.js is not sent with the isolation headers"
isolated "/local/nothere/buildat_server.js" 404
isolated "/local/hillclimb/index.html" 404
isolated "/local/../index.html" 404

# [WEB_MESH_REST] An app whose meta.json "needs" more than the browser
# gives (a fixture: apps/sample_ui with needs past any maximum the page
# asks for): the page says so and starts nothing until "Start anyway"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
cp -r "$here/apps/sample_ui" "$t/needs_app"
printf '{"engine_api": 2, "needs": {"memory_mb": 4096, "mesh_threads": 64}}\n' \
	> "$t/needs_app/meta.json"
start_server "$t/needs.log" "STATUS Listening" 120 auto bin/buildat_server \
	-m "$t/needs_app" -D "$t/needs" -C "$t/s.cache" -W "$here/web" -l 3 ||
	fail "the server for the needs fixture ($t/needs.log)"
CHECK_PIDS+=($SERVER_PID)
cat > "$t/needs.json" << 'JSON'
[
	["nav", "${URL}"],
	["waitlog", "needs: lack of memory_mb, mesh_threads", 30],
	["until", "/This game needs memory up to 4096 MB [\\s\\S]*Start anyway$/.test(document.getElementById('status').textContent) && !document.querySelector('script[src^=\"buildat\"]')", 5],
	["click", 600, 375],
	["waitlog", "sample_ui/init.lua loaded", 60]
]
JSON
WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
	bash "$here/util/web_drive.sh" chrome sample_ui \
	"$t/needs.json" "$t/needs_drive" > "$t/needs_drive.log" 2>&1 ||
	fail "the needs notice's drive ($t/needs_drive.log: $(tail -2 "$t/needs_drive.log" | tr '\n' ' '))"
echo "PASS: hillclimb's own server in the page, the car past the first turn, its saves kept over a reload; demo_aggregate's and skeldat's if built; the buildat server offers the apps to a page with no game and isolates the play page unless ?isolated=0, and ?local's files; an app that needs more than the browser gives is said to and starts anyway"
