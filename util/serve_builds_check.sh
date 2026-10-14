#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-10)
# covers: util/serve_latest_release.sh
# [SERVE_BUILDS]: serve_latest_release.sh with BUILDS_URL, a release of
# this tree serving demo_board_game, and a build host of its own (python).
#   1. 0.0.1: the host answers 202 twice, then a tar of a --compile-only
#      made with another cache: the server starts compiling nothing ("No
#      need to recompile").
#   2. 0.0.2: 422, its log said; the server stays on 0.0.1.
#   3. 0.0.3: a tar with ../x.so: refused, nothing written outside, on
#      0.0.1 still.
#   0. First: a BUILDS_URL that is http to a name, not a private address
#      (127.evil.com, 192.168.1.1.evil.com) or a path that looks like one,
#      stops the script at once ([SEC_RUN5_LEFTOVERS]).
#
#   util/serve_builds_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp serve_builds; t=$CHECK_TMP
for u in http://127.evil.com/b http://192.168.1.1.evil.com http://evil.com/127.0/b; do
	BUILDAT_SERVE_DIR="$t/refused" BUILDS_URL=$u timeout 10 \
		"$here/util/serve_latest_release.sh" demo_board_game 1 "$t/refused_user" > "$t/refused.log" 2>&1
	rc=$?
	[ $rc = 2 ] && grep -q "BUILDS_URL is https" "$t/refused.log" ||
		fail "BUILDS_URL=$u: exit $rc, not refused ($t/refused.log)"
done
echo "ok: BUILDS_URL to a name that looks private refused"
groups=()
trap 'for g in "${groups[@]}"; do kill -- -"$g" 2>/dev/null; done; check_cleanup' EXIT
cd "$here/Build"

# The modules, built with a cache of their own
BUILDAT_CACHE_PATH="$t/tarcache" timeout 600 bin/buildat_server -m ../apps/demo_board_game \
	-D "$t/tu" -l 3 --compile-only > "$t/tar_compile.log" 2>&1 ||
	fail "the compile for the tar ($t/tar_compile.log)"
(cd "$t/tarcache/apps/demo_board_game/rccpp_build" && tar -cf "$t/modules.tar" *.so *.so.hash) ||
	fail "no modules to tar"
python3 -c '
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w") as t:
	i = tarfile.TarInfo("../x.so"); d = b"x"; i.size = len(d)
	t.addfile(i, io.BytesIO(d))
' "$t/evil.tar"

P=$((29700 + RANDOM % 200)) BP=$((P + 1)) HP=$((P + 2))
release(){ # <version>: its tar, and the list with it first
	local r="$t/rel/buildat-$1-check-linux-x86_64-web-precompiled" e
	mkdir -p "$r"
	for e in 3rdparty Build builtin client extensions src VERSION web util apps; do
		ln -s "$here/$e" "$r/$e"
	done
	ln -s Build/bin "$r/bin"
	tar -C "$t/rel" -czf "$r.tar.gz" "$(basename "$r")"
	echo "[{\"browser_download_url\": \"http://127.0.0.1:$HP/$(basename "$r").tar.gz\"}]" \
		> "$t/rel/releases.json"
}
release 0.0.1
setsid python3 -m http.server $HP --bind 127.0.0.1 --directory "$t/rel" \
	> "$t/http.log" 2>&1 &
groups+=($!)
setsid python3 -c '
import sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
asked = {}
class H(BaseHTTPRequestHandler):
	def do_GET(self):
		q = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(self.path).query))
		rel = q.get("release", "")
		n = asked[rel] = asked.get(rel, 0) + 1
		print("ask", n, q, flush=True)
		code, body = 404, b""
		if "-0.0.1-" in rel:
			code = 202 if n <= 2 else 200
			body = open(sys.argv[2], "rb").read() if code == 200 else b""
		elif "-0.0.2-" in rel:
			code, body = 422, b"main.cpp:1: error: a check failing this\n"
		elif "-0.0.3-" in rel:
			code, body = 200, open(sys.argv[3], "rb").read()
		self.send_response(code)
		if code == 202:
			self.send_header("Retry-After", "1")
		self.send_header("Content-Length", str(len(body)))
		self.end_headers()
		self.wfile.write(body)
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
' $BP "$t/modules.tar" "$t/evil.tar" > "$t/builds.log" 2>&1 &
groups+=($!)
setsid env BUILDAT_CACHE_PATH="$t/servecache" BUILDAT_SERVE_DIR="$t/serve" \
	POLL_SECONDS=5 BUILDS_POLL=30 BUILDS_URL="http://127.0.0.1:$BP/build" \
	RELEASES_URL="http://127.0.0.1:$HP/releases.json" \
	"$here/util/serve_latest_release.sh" demo_board_game $P "$t/u" -l 4 > "$t/serve.log" 2>&1 &
groups+=($!)
slog="$t/serve/server-demo_board_game-$P.log"

# 1.
wait_for_log "$slog" "Listening at" 300 || fail "0.0.1 did not start ($t/serve.log)"
grep -q "asked BUILDS_URL for demo_board_game on buildat-0.0.1-.*: building" "$t/serve.log" &&
	grep -q "asked BUILDS_URL for demo_board_game on buildat-0.0.1-.*: ready" "$t/serve.log" ||
	fail "the asks ($t/serve.log)"
[ "$(grep -c "ask " "$t/builds.log")" = 3 ] || fail "asked $(grep -c "ask " "$t/builds.log") times, not 3"
grep -aq "No need to recompile" "$slog" && ! grep -aq "STATUS Compiling" "$slog" ||
	fail "compiled here ($slog)"
echo "ok: 202 twice, then the modules: nothing compiled here"

# 2.
release 0.0.2
wait_for_log "$t/serve.log" "does not compile on buildat-0.0.2" 120 ||
	fail "0.0.2's failure ($t/serve.log)"
grep -q "\[build demo_board_game\] main.cpp:1: error: a check failing this" "$t/serve.log" ||
	fail "the build log not said ($t/serve.log)"
grep -q "starting demo_board_game on port $P on buildat-0.0.2" "$t/serve.log" && fail "0.0.2 started"
echo "ok: a failed build said, 0.0.1 kept"

# 3.
release 0.0.3
wait_for_log "$t/serve.log" "does not compile on buildat-0.0.3" 120 ||
	fail "0.0.3's tar taken ($t/serve.log)"
grep -q "0.0.3-.*: failed (not a tar of modules)" "$t/serve.log" || fail "the refusal ($t/serve.log)"
[ ! -e "$t/servecache/apps/x.so" ] || fail "../x.so written"
curl -s -m 5 "http://127.0.0.1:$P/health" | grep -q . || fail "not serving"
echo "ok: a tar reaching outside refused, 0.0.1 still serving"
echo "PASS"
