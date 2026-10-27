#!/bin/bash
# tier: full
# cost: ~75 s (2026-10-27)
# covers: src/server/web/pre.js builtin/network/network_web.cpp src/client/pipe_stream.cpp src/client/web/index.html util/web_server.cmake
# [WEB_LOCAL_SERVER]: hillclimb in the browser with its own server in a
# worker of the page, and no buildat server: web/ served by a static
# server that sends what the buildat server sends with ?local
# (cross-origin isolation), and opened at ?local=hillclimb in Firefox
# (util/web_drive.sh). The client joins over the in-page stream, the car
# is driven past the first turn, and the worker's server says its ticks.
# A reload finds the saves kept in IndexedDB and opens them again. Then
# the buildat server's own serving of the same: the isolation headers
# with ?local and on the local server's files, and not on the page
# without it.
# demo_aggregate likewise, walked a step, when web/local/demo_aggregate/
# is there. Needs web/ (util/build_web.sh) with web/local/hillclimb/
# (util/build_web_server.sh hillclimb).
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
grep -a "frame split" "$page" | tail -2 | cut -c 1-120
grep -q "isolated true" "$t/drive.log" || fail "the page was not cross-origin isolated"
grep -q "Connect succeeded (page:)" "$page" || fail "the client did not join by the page's stream"
grep -a "IndexedDB\|would not open\|cannot be opened\|malformed" "$page" &&
	fail "a /user sync or a save failed"
grep -q "kept: .*/ranking/save.sqlite" "$t/drive.log" ||
	fail "IndexedDB has no ranking save"
echo "the drive: $(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.1f", b - a}') s"

# demo_aggregate's too, when it is built: in, on its feet and walking
if [ -f "$here/web/local/demo_aggregate/buildat_server.wasm" ]; then
	cat > "$t/aggregate.json" << 'JSON'
[
	["nav", "${URL}"],
	["waitlog", "server: .*Client 1 from the page connected", 120],
	["waitlog", "player physics enabled", 120],
	["eval", "'demo_aggregate playable at ' + Math.round(performance.now()) + ' ms'"],
	["holdkey", "w", 1000],
	["waitlog", "server: .*network: [0-9.]+ ticks/s", 15]
]
JSON
	WEB_DRIVE_URL="http://127.0.0.1:$p/?local=demo_aggregate" \
		bash "$here/util/web_drive.sh" firefox demo_aggregate \
		"$t/aggregate.json" "$t/aggregate" > "$t/aggregate.log" 2>&1 ||
		fail "demo_aggregate's drive ($t/aggregate.log: $(tail -2 "$t/aggregate.log" | tr '\n' ' '))"
	grep -a "eval:" "$t/aggregate.log"
	grep -a "server: .*network: .*ticks/s" "$t/aggregate/page.log" | tail -1 | cut -c 9-
else
	echo "no web/local/demo_aggregate: its drive skipped"
fi

# The buildat server's serving: a game of its own, and web/ as it is
cd "$here/Build"
start_server "$t/s.log" "STATUS Listening" 120 auto bin/buildat_server \
	-m ../apps/demo_digger -D "$t/s" -C "$t/s.cache" -W "$here/web" -l 3 ||
	fail "the server ($t/s.log)"
CHECK_PIDS+=($SERVER_PID)
u=http://127.0.0.1:$SERVER_PORT
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
isolated "/" 200 && fail "/ is isolated: the Starport ID's popup loses its opener"
isolated "/local/nothere/buildat_server.js" 404
isolated "/local/hillclimb/index.html" 404
isolated "/local/../index.html" 404
echo "PASS: hillclimb's own server in the page, the car past the first turn, its saves kept over a reload; demo_aggregate's if built; the buildat server isolates ?local and its files only"
